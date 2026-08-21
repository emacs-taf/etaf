# ETAF 架构

本文是 ETAF 的规范性架构契约，定义概念、职责、公共语法和 lowering 路径。实现状态与后续工作写在 [`implementation-plan.zh.md`](implementation-plan.zh.md)，面向用户的使用方式写在 [`user-guide.zh.md`](user-guide.zh.md)。

## 1. 设计结果

ETAF 是面向文本应用的统一 View 与 Component 层。Elisp 仍然是完整的计算语言，Ebox 仍然是负责可测量布局和文本渲染的底层引擎。

```text
应用
  → Runtime / 响应式状态 / Action / Data
  → Component(props, 局部 Scope)
  → View
  → Renderer
  → Ebox Node
  → measure → layout → paint → commit
  → Emacs buffer
```

设计有五条不变量：

- 所有可见结构都使用同一种 `NAME + 属性 + 子节点` 形状。
- 每项能力只有一个 owner：View 负责结构，Component 负责复用，Runtime 负责生命周期，响应式状态负责失效，Ebox 负责几何和发布。
- 上层复用下层契约，不复制下层逻辑，也不引入平行概念。
- 计算在 Elisp 表达式位置中完成，不伪装成另一类视觉节点。
- 渲染候选失败时，绝不会替换上一次已提交的 buffer。

## 2. 用户需要学习的模型

| 概念 | 它是什么 | 它负责什么 |
| --- | --- | --- |
| View | 规范化后的界面描述 | Host、Component 调用、文本和子结构 |
| Host | 固定的结构性 View 名称 | 核心文本或布局语义 |
| Component | 可复用的 View 生产者 | Props、可选局部 Scope、slot 和生命周期 |
| Runtime | 一次挂载的应用运行 | 渲染、事件、调度、提交、回滚和释放 |
| Ebox Node | 更底层的可渲染对象 | 几何、布局、surface、滚动和 buffer 发布 |

以下是机制，不是额外的视觉节点类型：

- `expr` 计算一个子节点位置的表达式。
- `slot` 读写同一个 Component slot 集合。
- `Behavior` 安装可复用的非视觉交互能力。
- `Action` 命名业务状态变更入口。
- `Effect` 管理订阅和外部同步。
- `watch` 观察响应式状态。
- `Context` 提供继承的依赖。
- `Data` 管理应用数据状态和数据源请求。
- `raw-ebox` 是 ETAF/Ebox 边界上的明确底层出口。

## 3. 统一 View 语法

每个 Host 和 Component 调用都使用一种形状：

```text
(NAME ATTRIBUTE* CHILD*)
ATTRIBUTE = :KEY VALUE
```

属性必须在第一个子节点之前全部结束。子节点可以是字符串、规范化 View、`nil`，或者由 `expr` 返回的序列。

```elisp
(etaf-view
 (column
  :class "welcome"
  (text :face 'bold "Hello")
  (text
   :color "#687386"
   (expr :value (if ready "Ready" "Waiting")))))
```

属性出现在子节点之后时，属性区和子节点区被交错，属于非法结构。

`etaf-view` 是唯一的公共结构构造入口。宏在结构位置读取 View form 并生成规范化 View 值；`etaf-render` 负责纯 View 的 lowering，`etaf-mount` 为 View 建立有状态 Runtime 并发布到 buffer。

### 3.1 quote 与求值

规则只有两条：

1. 结构性 View 位置不需要 quote，包括 `etaf-view`、Host、Component 调用、子节点、slot 和静态 Component styles。
2. Elisp 表达式位置遵循普通 Elisp 求值，包括属性值、`:key`、`:on-*`、`:use`、`expr :value`、`:setup`、Context 值、Behavior 构造器、Action 以及 `raw-ebox :value`。

```elisp
(etaf-view
 (text
  :face (if dark 'light 'dark)
  (expr :value label)))

(etaf-view
 (column
  (expr
   :value
   (when open
     (etaf-view
      (text :face 'bold "Details"))))))
```

`'bold` 是普通 Elisp 字面量 symbol。`'(text "Details")` 只是普通数据，不是 View；当 Elisp 表达式需要构造 View 时，使用 `(etaf-view (text "Details"))`。ETAF 不会对被 quote 的 View 数据再次 `eval`，也不增加单独的 literal/eval 节点。

属性值不需要 `expr` 包装。`expr` 只因为子节点区是结构语法，需要一个明确的桥接点来执行任意 Elisp。

### 3.2 expr 语义

`expr` 只接受一个属性且不能有子节点：

```elisp
(expr :value ELISP-EXPRESSION)
```

它执行表达式，然后接受字符串、View、View 序列或 `nil`。它不创建 Ebox wrapper、identity、生命周期、watch 或 effect。`if`、`when`、`cond`、`let`、`mapcar`、`cl-loop` 等 Elisp 形式仍然只是 `:value` 中的普通 Elisp。

当前 core 没有面向文件的 `.etaf` pair loader。`etaf-define-component` 才是结构/样式/行为单元：View 定义结构，`:styles` 负责 presentation，`:setup` 负责 retained state、事件和生命周期行为。未来的 `.etaf` SFC 属于把结果 lowering 到同一套公共 View/Component 契约的 compiler layer，而不是第二套 Runtime 语法。

## 4. Component

公共定义宏只有三个关键字：

```elisp
(etaf-define-component NAME (&key PROPS)
  DOCSTRING?
  :view VIEW
  :styles (styles RULE...))

(etaf-define-component NAME (&key PROPS)
  DOCSTRING?
  :setup SETUP
  :styles (styles RULE...))
```

`:view` 和 `:setup` 互斥；`:styles` 可选且最多出现一次。Props 是唯一需要声明的业务输入；普通尾部子节点和命名 slot 会被规范化为 Component 的 slot 集合。

Component definition 是当前结构/样式/行为边界：动态状态、Action callback 和生命周期工作放进 `:setup`，静态 presentation 放进 `:styles`。未来 `.etaf` SFC compiler 可以生成这些 definition，但 Runtime 不会直接加载 `.etaf` 文件。

### 4.1 无状态与状态型形式

```elisp
(etaf-define-component status-label (&key label)
  "Render a status label."
  :view
  (text
   :face 'bold
   (expr :value label)))
```

```elisp
(etaf-define-component disclosure (&key title)
  "Render a retained disclosure."
  :setup
  (let ((open (etaf-ref nil)))
    (lambda ()
      (etaf-view
       (column
        (text
         :role 'button
         :on-press
         (lambda ()
           (setf (etaf-value open)
                 (not (etaf-value open))))
         (expr :value (if (etaf-value open) "Hide" "Show")))
        (expr
         :value
         (when (etaf-value open)
           (etaf-view (text (expr :value title))))))))))
```

`:setup` 对一个 retained Component instance 只运行一次，并且必须返回零参数 render 函数。重新渲染读取当前 props 和 ref，不重新运行 setup。setup 负责局部 ref、computed、watch、Effect 和 cleanup 的创建。

`:key` 是稳定的 identity metadata，不是业务 prop。放在 Component 调用上时，它选择同级作用域内要保留的 Component instance；放在 Host 或 `raw-ebox` 上时，它会作为 Ebox node key 向下传递。候选渲染失败时，Runtime 恢复旧 instance、handlers、Behaviors 和 buffer。

在 View 语法中，Component 的规范名称可以省略 `etaf-` 前缀。如果短名称会与 Elisp 函数、special form 或 Host 冲突，注册表会分配语义明确的 `-view` alias。普通 Elisp API，例如 `etaf-value`、`etaf-ref` 和 `etaf-mount`，始终保留前缀。

## 5. children 与 slot

所有 Component 内容都是同一个 slot 集合：

```text
slots.default = 普通尾部子节点
slots.NAME    = 命名 slot 内容
```

children 只是匿名/默认 slot 的便捷写法，不是第二套内容模型，也不需要出现在业务 `&key` 声明中。

尾部子节点自动填充默认 slot：

```elisp
(card
 :title "Account"
 (text "Card body"))
```

命名内容使用同样的结构形状：

```elisp
(card
 :title "Account"
 (slot :name 'header (text :face 'bold "Account settings"))
 (text "Card body"))
```

在 Component View 内，默认 outlet 以及 fallback 写法是：

```elisp
(slot)
(slot (text :face 'shadow "No content"))
```

完整的内部规范写法是：

```elisp
(slot :name 'default (text :face 'shadow "No content"))
```

对用户来说，优先使用前两个简写；只有需要明确名字时才写 `:name`。Slot 名称必须是稳定的、非 keyword 的 symbol。字符串、数字、变量和运行时表达式都会被拒绝，因为 slot 名称属于 retained 结构。同名输入只能出现一次。显式空输入 `(slot :name 'header)` 会抑制 outlet fallback。Slot form 不创建 Ebox wrapper。

在 Component 内，`slot` 表示投影；在 Component 调用的子节点区，带 `:name` 的 `slot` 表示贡献内容。编译器对两种位置使用同一个规范化 slot 表示。

## 6. Core Host 与 Ebox

ETAF core 只提供最小且无样式的 Host：

```text
text · fragment · container · row · column · stack · flex · grid · spacer
```

| Host | 作者看到的含义 | lowering 方向 |
| --- | --- | --- |
| `text` | 带可选 inline runs 的文本 surface | Ebox box/content |
| `fragment` | 不增加视觉 wrapper 的子节点集合 | 展平的子节点序列 |
| `container` | 中性的子节点容器 | Ebox container/column 路径 |
| `row` | 水平排列子节点 | Ebox row layout |
| `column` | 垂直排列子节点 | Ebox column layout |
| `stack` | 结构性的组合容器 | Ebox container 路径 |
| `flex` | 通过 flex 分配空间 | Ebox flex layout |
| `grid` | 二维轨道、放置和跨度 | Ebox Grid formatting context |
| `spacer` | 有意表达的空几何 | Ebox spacer |

字符串是最小的文本 View，会降低为 Ebox content。text 中兼容的嵌套 text 会成为带 text properties 的 inline run；非文本子节点则回到普通布局 lowering。因此 Text、View Host、Component 和 Ebox Node 是连续的表示层，而不是三棵相互竞争的树。

`grid` 复用 Ebox 的公共二维布局契约，支持轨道模板、`auto`/分数/`minmax` 轨道、间距、行列放置、跨度、自动流向和 item 对齐。轨道测量和放置由 Ebox 负责；ETAF 只把 `grid` Host 映射到这个节点。Ebox 的可选 native reflow 后端不参与正确性保证；如果该后端不支持 Grid，Grid 树会使用普通 Ebox 渲染器。

ETAF 的 Renderer 是唯一调用 Ebox 的框架模块，并且只使用 Ebox 公共构造器、属性读取器、Host 引用查询和发布 API。Ebox 不理解 Component、slot、Action、Context、Behavior 或 Data。

`raw-ebox` 是唯一明确的底层出口：

```elisp
(etaf-view
 (raw-ebox
  :key 'backend-row
  :value (ebox-create :content "Low-level")))
```

它只接受 `:value` 和可选的 `:key`。返回的 Ebox Node 保持 opaque，不获得 Component props、slot、事件或 Behavior 语义。使用它意味着调用方承担 measurement、identity、rollback 和 backend 契约。

## 7. Runtime 与响应式状态

Runtime 的挂载是事务性的：

```text
创建 Runtime
  → 建立 retained Component scope
  → 渲染 View 候选
  → lowering 并发布 Ebox 候选
  → 提升 handlers、instances 和 Behaviors
  → 运行 mounted/updated 生命周期
```

更新使用同一条路径。响应式 ref 和 computed 让 render effect 失效；Runtime scheduler 在当前边界同步 flush。渲染阶段写入状态会触发 `etaf-render-write-error`；状态应在事件、Action、Effect 或 watch callback 中改变。

渲染、lowering 和 Ebox 发布构成回滚边界。如果候选步骤之一失败，上一棵已提交的树仍保持 active。生命周期和 cleanup callback 在 retained state 提升且发布完成后运行；它们的错误会保持可见，但不会假装回滚已经发布的 Ebox tree。

响应式 API 只有一套模型：

```elisp
(let* ((count (etaf-ref 0))
       (double (etaf-computed
                (lambda () (* 2 (etaf-value count))))))
  (etaf-watch count
              (lambda (new old)
                (message "%s → %s" old new)))
  (etaf-watch-effect
   (lambda ()
     (message "double=%s" (etaf-value double)))))
```

`etaf-effect-scope` 负责 effects 和 cleanup。Component setup 自动运行在 Component Scope 内；Component 释放时，会停止子 scope、watcher 和 resource cleanup。

## 8. Behavior、事件、Action 与 Effect

```text
on-xx    = 一个局部事件属性
Action   = 一个命名的业务变更入口
Effect   = 一个订阅/外部同步 owner
Behavior = 安装多个非视觉能力的可复用 bundle
```

一次性的交互直接使用 callback：

```elisp
(text
 :role 'button
 :on-press (lambda () (message "Opened"))
 "Open")
```

当变更需要命名并被多个入口复用时，使用 `etaf-action-define` 和 `etaf-dispatch`。当多个 Host 需要同一套非视觉能力时，使用 `etaf-define-behavior` 或 `etaf-behavior-create`，并通过 `:use` 安装。Behavior 不是 View 节点，也不直接修改 buffer。

`etaf-behavior-create` 接受保留的 `:install` 属性，用于可选的零参数 installer。Installer 可以返回 cleanup；运行期间可通过 `etaf-current-behavior-context` 读取当前 Runtime、结构路径和 Host props。Behavior 被替换或 owner 卸载时，installer 状态会被释放。

Runtime 事件通过 `etaf-dispatch-event` 进入；命中测试和 focus 通过 Ebox Host 引用查询，并由 `etaf-activate`、`etaf-focus`、`etaf-focus-next`、`etaf-host-ref-bounds` 和 `etaf-host-ref-position` 提供公共入口。

## 9. Context、Theme、Data 与 Resource

### 9.1 Context 与 Theme

Context 是继承的 Component Scope 环境：

```elisp
(etaf-define-component service-provider ()
  "Provide a reactive service to descendants."
  :setup
  (let ((service (etaf-ref "demo-service")))
    (etaf-provide 'service service)
    (lambda () (etaf-view (slot)))))

(etaf-define-component service-consumer ()
  "Read the inherited service."
  :setup
  (let ((service (etaf-inject 'service nil t)))
    (lambda ()
      (etaf-view (text (expr :value (etaf-value service)))))))

(etaf-view (service-provider (service-consumer)))
```

key 使用稳定的普通 symbol。最近的祖先优先，缺失的 required key 触发 `etaf-context-error`。Theme 是一个 Context value，内容是属性 plist：

```elisp
(etaf-define-component themed-shell ()
  "Provide default text colors to a subtree."
  :setup
  (progn
    (etaf-theme-provide
     '(:color "#F4F6FB" :bgcolor "#202634"))
    (lambda () (etaf-view (slot)))))
```

显式 Host props 覆盖 Component styles，Component styles 覆盖 Theme defaults。

样式所有权跟随创建每个 View node 的 Component。嵌套 Component 是样式边界：父规则不会穿透其内部。调用者提供的 slot 内容使用 caller scope，子组件自有的 fallback 内容保留在 child scope。

### 9.2 Data

Data 是 ETAF core 能力，不是需要用户额外学习的第二套框架。Data Source 是一个小的 capability plist：

```elisp
(etaf-data-source
 :load (lambda (query page page-size)
         (ignore query page page-size)
         (let ((rows '((:id 1 :name "Ada"))))
           (list :items rows :total (length rows))))
 :mutate (lambda (operation payload)
           (ignore operation payload)
           t)
 :dispose (lambda () t))
```

`:load` 必选，接收 `QUERY`、`PAGE` 和 `PAGE-SIZE`，返回带 `:items` 的 plist，可选 `:total`、`:page` 和 `:page-size`。`:mutate` 和 `:dispose` 可选。核心边界刻意是同步的，因此不需要 Promise、Task 或 Executor 概念；外部 callback 型集成可以通过同一套响应式 ref 或 Resource 边界发布结果。

`etaf-data-controller` 负责 query、分页、items、total、status、error、selection、request generation 和释放。`etaf-data-memory-source` 是示例和测试使用的内存 source。存储包只是具体 source；SQLite 不是 core 前提，ORM 也保持在 ETAF 数据模型之外。

### 9.3 Resource 与 Error Boundary

`etaf-resource` 是 Scope 所有的同步 loader，拥有响应式的 `loading`、`success` 和 `error` 状态：

```elisp
(let* ((filename "README.md")
       (resource
        (etaf-resource
         (lambda ()
           (with-temp-buffer
             (insert-file-contents filename)
             (buffer-string)))))
       (stop
        (etaf-watch-effect
         (lambda ()
           (message "resource=%s" (etaf-resource-status resource))))))
  (unwind-protect
      (etaf-resource-value resource)
    (funcall stop)
    (etaf-resource-dispose resource)))
```

`etaf-resource-result` 为替换和释放提供 cleanup。`etaf-error-boundary-run` 是明确的函数边界：它处理 body 抛出的错误，让边界外的错误保持可见。Resource 和 Data 状态通过普通 `expr` 分支投影，不增加专门的 Error 或 Loading 节点。

## 10. 官方 UI 与包边界

正式的可复用界面概念只有 Component：

```text
ebox
  └── 可选的 ebox-playground

etaf → ebox
  ├── View / Component / Runtime
  ├── reactive / Action / Effect / Data
  └── Renderer

etaf-ui → etaf
  └── 官方 Button、Checkbox、Label、Panel、DataGrid 等 Component

etaf-sqlite → etaf
  └── 类型化 SQLite Data Source

etaf-playground → etaf
  └── 展示官方 Component 时可选依赖 etaf-ui
```

`etaf-ui` 是官方现成 Component 目录。用户只需要理解 Component；文件只是维护者边界。Controls、Widgets 和 DataGrid 不是平行的 Runtime 类型，DataGrid 只是由同一套 View、props、slot、事件和 Data 契约构成的复合 Component。

`etaf-sqlite` 是具体的数据源包，负责 schema 声明、标识符校验、连接、分页和 mutation；`etaf-data` 仍然属于 ETAF core。PostgreSQL、REST、文件和 ORM 集成可以在独立包中实现同一个 source capability，不增加 `etaf-adapters` 概念。

`ebox-playground`、`etaf-playground`、`etaf-ui` 和 `etaf-sqlite` 都是可以独立加载的同级包。`ebox-playground` 只使用 Ebox 公共 API，不加载 ETAF；`etaf-playground` 使用 ETAF 公共 API，并且只在展示官方组件时可选加载 `etaf-ui`，不依赖 `ebox-playground`。核心包不会自动加载任何可选包。

可选存储集成应使用具体名称，例如 SQLite 或 PostgreSQL source。通用 adapter 包无法拥有稳定的行为，只会增加用户需要记忆的名称，因此不属于公共模型。

## 11. 保留式发布与 fixed-point 安全

mounted Component、expr、slot、fragment、raw、inline 和 Root owner 都经过同一
个外层 reactive dispatch。局部 owner 先生成 candidate generation 和 Ebox logical
replacement；不相交 owner 会合并为一次 TP/Ebox publication。只有 Root owner
可以进入 complete-root adapter。

每次 Runtime flush 都记录 candidate-aware effect tuple：其中包含 generation id、
effect→source 边和 source version，以及 candidate input/context/output facts 的
immutable semantic-node stamp。重复 tuple 会报告有序的 effect/edge path；step
bound 从 candidate nodes、dependency edges 和 source entries 推导，不再是任意
固定倍率阈值。rollback 会丢弃本次 flush 的 stamp，因此同一个失败状态可以作为
新的 transaction 重试。

Behavior installer 使用 target-specific identity：reactive value 和 function 用
`eq`，普通 scalar attribute 才使用 value equality。每个已安装 Behavior 都获得
稳定的 `(mount-epoch resource-id)` 地址；generation membership 与 Runtime resource
registry 决定当前 authority。失败 candidate 只移除 staged Behavior resource，并
执行受 containment 保护的 cleanup。

## 12. 拓展规则

增加新能力前，优先选择最小的既有 owner：

| 需求 | Owner |
| --- | --- |
| 可复用的视觉组合 | Component 或普通 View helper |
| 一个子节点计算 | `expr` |
| 局部派生值 | `etaf-computed` |
| 可复用交互 | Behavior |
| 命名变更 | Action |
| 跨层级依赖 | Context |
| 请求或变更状态 | Data / Resource |
| 几何或布局算法 | Ebox |
| 低层 backend 出口 | `raw-ebox` |

只有在现有 owner 无法表达、能够明确 identity/lifecycle/error/rollback 规则，并且可以用公共路径测试证明时，才增加新的公共概念。这样既保留完整的 Elisp 表达能力，又让用户模型保持干净。
