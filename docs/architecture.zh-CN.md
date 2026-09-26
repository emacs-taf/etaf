# ETAF 架构

本文是 ETAF 的规范性架构契约，定义概念、职责、公共语法和 lowering 路径。实现状态与后续工作写在 [`implementation-plan.zh.md`](architecture.zh-CN.md)，面向用户的使用方式写在 [`user-guide.zh.md`](manual.zh-CN.md)。

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
  (text :font-weight 'bold "Hello")
  (text
   :color "#687386"
   (expr (if ready "Ready" "Waiting")))))
```

属性出现在子节点之后时，属性区和子节点区被交错，属于非法结构。

`etaf-view` 是唯一的公共结构构造入口。宏在结构位置读取 View form 并生成规范化 View 值；`etaf-render` 负责纯 View 的 lowering，`etaf-mount` 为 View 建立有状态 Runtime 并发布到 buffer。

### 3.1 quote 与求值

规则只有两条：

1. 结构性 View 位置不需要 quote，包括 `etaf-view`、Host、Component 调用、子节点、slot 和静态 Component styles。
2. Elisp 表达式位置遵循普通 Elisp 求值，包括属性值、`:key`、`:on-*`、`:use`、`expr`、`:setup`、Context 值、Behavior 构造器和 Action。

```elisp
(etaf-view
 (text
  :color (if dark "#F4F6FB" "#1F2328")
  (expr label)))

(etaf-view
 (column
  (expr
   (when open
     (etaf-view
      (text :font-weight 'bold "Details"))))))
```

`'bold` 是普通 Elisp 字面量 symbol。`'(text "Details")` 只是普通数据，不是 View；当 Elisp 表达式需要构造 View 时，使用 `(etaf-view (text "Details"))`。ETAF 不会对被 quote 的 View 数据再次 `eval`，也不增加单独的 literal/eval 节点。

属性值不需要 `expr` 包装。`expr` 只因为子节点区是结构语法，需要一个明确的桥接点来执行任意 Elisp。

### 3.2 expr 语义

`expr` 只接受一个属性且不能有子节点：

```elisp
(expr ELISP-EXPRESSION)
```

它执行表达式，然后接受字符串、typed View、typed View proper sequence 或 `nil`。
它不创建 Ebox wrapper、identity、生命周期、watch 或 effect。`if`、`when`、`cond`、
`let`、`mapcar`、`cl-loop` 等仍是 form 中的普通 Elisp。

当前 core 没有面向文件的 `.etaf` pair loader。`etaf-define-component` 才是结构/样式/行为单元：View 定义结构，`:styles` 负责 presentation，`:bindings` 负责保留值，`:setup` 初始化生命周期行为。未来的 `.etaf` SFC 属于把结果 lowering 到同一套公共 View/Component 契约的 compiler layer，而不是第二套 Runtime 语法。

## 4. Component

公共定义宏有四个关键字。两个 frontend 必须二选一，另外两个 clause 可选：

```text
(etaf-define-component NAME (&key PROPS)
  DOCSTRING?
  :bindings ((NAME INITIALIZER) ...)
  :setup INITIALIZATION-FORM
  :view VIEW
  :styles (RULE...))

(etaf-define-component NAME (&key PROPS)
  DOCSTRING?
  :bindings ((NAME INITIALIZER) ...)
  :setup INITIALIZATION-FORM
  :render ORDINARY-ELISP
  :styles (RULE...))
```

`:view` 和 `:render` 互斥且必须恰好出现一个。`:render` 是普通 Elisp，可以返回
`etaf-view` 或程序化构造的 `etaf-node`；两者共用 View 编译、prop 校验与 slot
投影，不增加另一套表示或状态模型。`:bindings`、`:setup` 与 `:styles` 可选且各最多出现一次。Props 是唯一需要声明的业务输入；普通尾部子节点和命名 slot 会被规范化为 Component 的 slot 集合。

Component definition 是当前结构/样式/行为边界：保留句柄放进 `:bindings`，生命周期工作放进 `:setup`，静态 presentation 放进 `:styles`。未来 `.etaf` SFC compiler 可以生成这些 definition，但 Runtime 不会直接加载 `.etaf` 文件。

### 4.1 无状态与状态型形式

```elisp
(etaf-define-component status-label (&key label)
  "Render a status label."
  :view
  (text
   :font-weight 'bold
   (expr label)))
```

```elisp
(etaf-define-component disclosure (&key title)
  "Render a retained disclosure."
  :bindings ((open (etaf-ref nil)))
  :view
  (column
   (text
    :role 'button
    :on-press
    (lambda () (setf (etaf-value open) (not (etaf-value open))))
    (expr (if (etaf-value open) "Hide" "Show")))
   (expr
    (when (etaf-value open)
      (etaf-view (text (expr title)))))))
```

命名绑定与可选 setup 共用实例初始化和 Scope。宏把初始值按声明顺序保存到实例，
每次渲染重新建立引用这些值的词法环境；声明 props 则使用本次输入。原有
`etaf-state` 仅用于无命名绑定的组件；有绑定时忽略 setup 返回值。重排保留实例及绑定；初始化失败和
卸载使用同一资源清理路径，不引入第二套状态图。

Component 实例保存内部 Host 名称到不透明符号的映射。`etaf-local-ref` 在
setup 分配句柄，保留实例保持映射，替换实例重新分配。句柄与显式 `:ref`
使用同一条宿主身份路径。Ebox 负责已提交几何查询及节点消失，ETAF 不新增
另一份目标索引；字面量应用地址仍需明确提供。

`etaf-prop` 向 setup 提供由 Component semantic 输入支持的稳定 computed 来源，
不复制一份可变权威状态。候选属性变化使派生计算及保留的后代渲染 effect
失效。候选日志保存受影响的缓存和依赖边；拒绝发布时恢复依赖边，缓存重新
根据已提交 props 与实时业务 ref 求值。发布成功后丢弃日志并通知响应式
订阅者。实例 Scope 与 semantic 所有权校验阻止读取已释放来源。

纯渲染与挂载输入求值共用默认值解析和可选的 `:validate` 阶段。校验器在实例
初始化或可跟踪输入发布前读取解析后的词法 props，不持有状态或资源；实时 ref
读取仍归渲染表达式所有，保持依赖归属。`etaf-check-prop` 为组件校验器和普通
UI 辅助函数提供统一、限制值显示深度的输入错误信息。

输入默认值由已提交的 Component semantic record 持有。候选在 setup/render 前
解析缺省输入，只复制属性容器，保留传入值及默认值的对象身份。新默认值与
画面一同发布，回滚时丢弃；求值及所有权约定见[用户手册](manual.zh-CN.md)。

业务 props、可跟踪属性来源与 keyed 迭代项共用响应式层的浅比较规则。输入 plist
和数据项索引保留应用值的对象身份，不保存深复制的值。整树与局部输入更新因此
接受相同的对象替换；稳定 key 保留实例，其输出和回调使用当前数据项。

`:key` 是稳定的 identity metadata，不是业务 prop。放在 Component 调用上时，它选择同级作用域内要保留的 Component instance；放在 Host 上时，它会作为 Ebox node key 向下传递。候选渲染失败时，Runtime 恢复旧 instance、handlers、Behaviors 和 buffer。

Component 调用使用定义时准确注册的名称，注册表不会自动生成省略前缀或 `-view` alias。官方目录组件使用 `etaf-button` 等名称；应用可以显式使用任何合法且尚未占用的名称定义自己的组件。

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
 (slot :name 'header (text :font-weight 'bold "Account settings"))
 (text "Card body"))
```

在 Component View 内，默认 outlet 以及 fallback 写法是：

```elisp
(slot)
(slot (text :color "#687386" "No content"))
```

完整的内部规范写法是：

```elisp
(slot :name 'default (text :color "#687386" "No content"))
```

对用户来说，优先使用前两个简写；只有需要明确名字时才写 `:name`。Slot 名称必须是稳定的、非 keyword 的 symbol。字符串、数字、变量和运行时表达式都会被拒绝，因为 slot 名称属于 retained 结构。同名输入只能出现一次。显式空输入 `(slot :name 'header)` 会抑制 outlet fallback。Slot form 不创建 Ebox wrapper。

在 Component 内，`slot` 表示投影；在 Component 调用的子节点区，带 `:name` 的 `slot` 表示贡献内容。编译器对两种位置使用同一个规范化 slot 表示。

每个组件都保留一个语义输出 Range，无论当前产生零个、一个还是多个根。slot 读取
仍归组件渲染 effect 负责；输出数量和 slot 访问都不会引入物理容器。组件的身份与
生命周期独立于当前输出形态。

最终语义代负责输出组合。Range 快照属于派生缓存，后代变化只使外层快照失效，
不立即重新转换这些祖先的完整输出。只有发布或组合需要该 Range 的规范输入时，
才从对应的已提交代或候选代生成快照。失效标记不捕获 Runtime 或旧语义代，沿用
已生成快照的提升与回滚生命周期。
相邻语义 Range 共用物理 Ebox 子列表，Host 则开启独立的子布局。发布使用 Ebox
已提交的 Range 地址；没有外层子 Range 地址时使用根更新操作。发布从最终候选
输出组合，不重新执行应用 effect，也不维护另一份组件产物存储。

Slot 中作者写下的表达式在整个投影子树中保留作者的 props、state 和 Context。
其中创建的 Component 拥有自己的 props、state、styles 和 Scope，但其 Context
从 slot 作者环境继承。接收方自己定义的 fallback、普通子节点和产生 View 的
callback 使用接收方环境。Table/Grid 的 cell callback 遵循相同的普通规则：
Context 来自消费它的 Table/Grid 所在位置。

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

ETAF 的 Renderer 是唯一把 View 语义 lower 为 Ebox 节点、属性与 Host 查询的框架模块；`etaf-render-port.el` 是唯一探测 versioned Ebox framework SPI 并选择发布路径的模块。两者都只使用 Ebox 公共 API，Runtime 只读取已经选定的 immutable port，不再自行猜测 Ebox 版本。Ebox 不理解 Component、slot、Action、Context、Behavior 或 Data。

响应式 Host 属性变化只把前后两代 Host 声明转换为 Ebox 通用候选属性操作。
Ebox 保留内容与子节点，并将其更新与 Component、Range 替换组合。ETAF
不判断变化是否仅涉及绘制，也不因为属性影响布局或原生交互而重建子树；
这些后果由 Ebox 的发布流程处理。

公共 View 语法不接受裸 Ebox Node。框架集成层通过 Ebox 的 typed integration port 构造规范的 TextNode 和 BoxNode；普通 ETAF 应用只使用 Host 与 Component。这样 measurement、identity 和 rollback 始终由同一条 lowering 路径负责。

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

`etaf-batch` 与 `etaf-call-with-batch` 暴露 Event、Action 和 Data 发布共用的
投影边界。ref 写入立即生效，通知和 Runtime 工作在最外层同步批处理结束时
执行。执行体报错或退出仍会处理已写入状态，且原始条件优先于通知或发布失败。
这个边界只在 Emacs 主事件循环中组织工作，不拥有业务状态，不回滚写入，
不提供跨 Runtime 事务，也不延伸到稍后运行的异步回调。

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

排队的语义祖先先于后代运行。条件 Range 在子组件输入或渲染产生候选之前确定
其挂载关系，避免已移除的组件因排队更新而重新进入已提交代。独立 owner 保留
稳定的 effect 优先级与 ID 顺序；祖先关系来自已有 generation 图，不增加调度权威。

发布前，挂载关系沿最终候选的父子边追溯到 Root。已脱离分支的候选后代连同其
effect、Host 贡献和发布指令一起移除，计算过候选并不代表实例仍然存活。
复用的 Component 记录同样参与清理，即使其未变化的图子树没有复制到候选中。
构建下一代时，不能在后代已移除后保留这些组件记录。
slot 局部更新保留物理父节点，与词法所有者分别维护。已有组件的 scope 在成功
发布后释放；从未挂载的候选实例直接释放，不运行 mounted/unmounted 回调。

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

`etaf-behavior-create` 接受保留的 `:install` 属性，用于可选的零参数 installer。Installer 可以返回 cleanup；`etaf-current-behavior-context` 返回不透明安装上下文，`etaf-behavior-context-info` 查询其 Runtime、实际 Host 引用及安装时语义属性。这些信息不授予候选输入权。替换、候选回滚或 owner 卸载时释放 installer 状态；成功发布之前，已提交状态仍是权威。

原生帮助、指针与悬停绘制声明直接传给 Ebox 的规范交互事实，包括显式 nil
继承屏障。组件根属性透传与直接 Host 使用同一路径。Ebox 负责验证、原生属性
投影和悬停绘制；ETAF 不增加悬停目标表或第二套层叠算法。

Host press 和 drag 绑定与规范 source 事实一起降为 Ebox 原生 keymap。每个 Runtime 的有界
缓存保留查找已提交 handler 的分发 map，替换回调不会调用候选闭包。禁用和无回调的
控件边界发布显式 nil map。Ebox 解析可见位置归属；ETAF 不再扫描 Host bounds
选择激活目标。Tab index 和禁用声明发布为 Ebox 交互事实；Ebox 从中派生禁用选择器状态，
ETAF 不维护独立的 selector-state 投影。挂载焦点的 `:focus` 也由 Ebox 经同一
cascade 原子发布，纯组件渲染不带焦点状态。生成的按下与拖动跟踪通过同一 source
投影提供 `:active`，组件规则直接使用它，Runtime 不保存按下状态字段。指针激活
在 Ebox 清除该状态后运行。焦点身份、导航顺序、可见性、
point 保持与回滚均由 Ebox 管理。ETAF 的焦点 API 转换 Runtime 上下文并保持公开错误条件，
Runtime 不再保存焦点字段、扫描排序 Host 候选或包装 flush 来修正 point。挂载的 Ebox
buffer mode 管理默认输入绑定和键盘焦点优先级，包括父子位置重合的情况。ETAF 不再
有独立输入模式或目标覆盖；原生回调只分派所选 Host 已提交的 handler。

Ebox 持有完整的原生拖动循环并保持指针目标。ETAF 分别将每个手势阶段交给普通
事件批处理，因此按住按钮时也能持续发布响应式位置。Runtime 按 Host 和启用的
事件能力缓存 keymap，每个阶段读取已提交的 handler。存续但被禁用的 Host 可以
收到原生取消阶段；移除或卸载后不再调用应用回调。ETAF 不保存手势坐标、跟踪
循环或第二份目标索引。

ETAF 的 `etaf-draggable` 与 `etaf-resizable` 是位于该输入边界之上的可复用
Behavior。它们消费手势 callback，只写调用方拥有的可写 ref，再沿已有响应式 Host
属性路径发布增量几何。Draggable 支持轴选择；Resizable 支持边选择、相对边保持以及
数值最小/最大约束。调用方可以提供纯 delta 转换函数，将 Ebox 像素转换为自己的逻辑
单位。这些 Behavior 不拥有窗口状态、堆叠策略、最大化/最小化模式或指针循环；UI
组件和应用组合标题栏、手柄等视觉结构，桌面应用负责窗口生命周期和排序。

把窗口事实保存在一个聚合记录中的应用可以使用
`etaf-draggable-controlled` 与 `etaf-resizable-controlled`：`read` 提供已提交的几何
plist，`on-change` 接收下一份脱离式 plist。这两个变体只保留手势起点，不增加第二份
持久几何状态。

需要高频显示投影的应用可以在更新受控状态后调用
`etaf-runtime-update-host-geometry`。ETAF 将公开 Host 引用解析到 retained provider
区域，再委托 Ebox 的类型化几何增量发布；拖拽策略和应用的权威状态仍归调用方所有。
下一次普通 Runtime 发布仍负责一致性校准和恢复。

交互组合是确定的：显式 Host `:on-*` callback 先运行，然后按声明顺序运行 Behavior
callback；任一错误会 short-circuit 后续 callback。非事件属性由显式 Host 值优先，
否则第一个声明该属性的 Behavior 获胜（first-wins）。同一 Host 的 Behavior name 必须在任何
installer 运行前保持唯一。稳定 installer identity 会复用，每个已安装 cleanup
exactly-once。事件只 dispatch 给准确 Host ref；ETAF 没有 capture 或 bubble 阶段。

Action name 应使用 application/feature-prefixed symbol。重复注册默认报错。
`etaf-action-redefine-run` 是显式 authoring/reload 边界；替换只影响未来按 name 的
dispatch，不会 flush 已挂载 Runtime。

Runtime 事件通过 `etaf-dispatch-event` 进入；命中测试和 focus 通过 Ebox Host 引用查询，并由 `etaf-activate`、`etaf-focus`、`etaf-focus-next`、`etaf-host-ref-bounds` 和 `etaf-host-ref-position` 提供公共入口。

## 9. Context、Theme、Data 与 Resource

### 9.1 Context 与 Theme

Context 是继承的 Component Scope 环境：

<!-- etaf-example: context -->
```elisp
(require 'etaf)

(etaf-define-component service-consumer ()
  "Read the inherited service."
  :bindings ((service (etaf-inject 'service nil t)))
  :view (text (expr (format "Service: %s" (etaf-value service)))))

(etaf-define-component service-provider ()
  "Provide a reactive service to its own child Component."
  :setup
  (let ((service (etaf-ref "demo-service")))
    (etaf-provide 'service service)
    service)
  :view (service-consumer))

(etaf-mount "*etaf-context*" (etaf-view (service-provider)))
```

key 使用稳定的普通 symbol。最近的祖先优先，缺失的 required key 触发
`etaf-context-error`。在根位置编写的 slot 内容及其子树保留根的空 Context。
迁移旧版本中意外继承接收方 Context 的用法时，应把消费者写进 provider 自己的
View，或在那里调用普通的 View-producing callback。投影的 slot 继续使用作者
环境。Theme 遵循同一套 Context 继承关系，内容是属性 plist：

<!-- etaf-example: theme -->
```elisp
(require 'etaf)

(etaf-define-component themed-shell ()
  "Provide semantic colors to its own View."
  :setup
  (etaf-theme-provide
   '(:text-color "#F4F6FB" :surface-color "#202634"))
  :view
  (text :ref 'themed-content
        :color (etaf-theme-token :text-color)
        :background-color (etaf-theme-token :surface-color)
        "Themed content"))

(etaf-mount "*etaf-theme*" (etaf-view (themed-shell)))
```

Palette 解析属于 Theme，而不是 UI 目录。core 提供
`etaf-theme-resolve-palette` 解析应用持有的显式亮/暗语义 pair，返回普通
Theme plist，不需要全局 registry。`etaf-ui` 只消费 `:ui-*` 语义 token，
不依赖渲染器 palette 名称，也不访问 Ebox 私有状态。

静态 Component 规则如果需要读取一个 Theme 值，应使用 `etaf-theme-token`；
ETAF 会在样式边界解析这个延迟 token，使 retained Host 仍然走静态样式路径。

Theme 默认值降为根位于当前 Host 的不可变 Ebox UA 作用域；ECSS 负责其优先级、
importance 和继承。Host 更新分别解析 author 属性与默认值，再进入候选发布。
延迟 ECSS 值通过 Ebox schema 校验后，保留到层叠计算，不进入具体 Ebox paint slot。

每个 Component instance 拥有不可变 Ebox 作用域身份。Host 标记成员归属，最上层的
自有 Host 分别以 author 来源挂载规则版本；物理祖先归属使透明 Range 和 forest
仍能识别各根。根上的 Theme 规则更新时，保留片段无需改写成员身份。ECSS 在规范
节点关系上执行匹配与层叠。slot projection 与公开代码 slot accessor 保留 caller
的归属及 Context，fallback 保留消费组件归属；这些事实不增加可见容器。

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

`:load` 必选，接收 `QUERY`、`PAGE` 和 `PAGE-SIZE`，返回带 `:items` 的 plist，可选 `:total`、`:page` 和 `:page-size`。`:mutate` 和 `:dispose` 可选。加载和变更回调可直接返回同步结果，或返回 `etaf-async` 描述的原生异步操作。Data 与 Resource 共用请求的启动、单次完成、失效、取消和超时机制；Data 仍独占集合、分页、选择和写入后刷新。外部结果未知时不推断回滚，已提交写入的刷新重试只调用读取。

`etaf-data-controller` 负责 query、分页、items、total、status、error、selection、request generation 和释放。`etaf-data-memory-source` 是示例和测试使用的内存 source。存储包只是具体 source；SQLite 不是 core 前提，ORM 也保持在 ETAF 数据模型之外。

### 9.3 Resource 与 Error Boundary

`etaf-resource` 管理 Scope 所有的同步或异步 loader。未启动时为 `idle`；请求中的 `loading` 与保留成功值的 `refreshing` 区分，完成后为 `success`、`error` 或 `cancelled`。例如同步资源：

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

共享请求先失效再取消外部任务，释放 owner 回调并使晚到结果不能重新发布。Resource 独占成功值及 `etaf-resource-result` 的 cleanup；取消后的首次晚到结果也释放 cleanup。Data 独占已接受的集合和写入确定性，取消等待不撤销外部写入。使用及原生定时器示例见[用户指南](manual.zh-CN.md#11-resource-与-raw-ebox)。

`etaf-error-boundary-run` 是明确的函数边界：它处理 body 抛出的错误，让边界外的错误保持可见。Resource 和 Data 状态通过普通 `expr` 分支投影，不增加专门的 Error 或 Loading 节点。

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

etaf-db → etaf
  └── 数据库后端（目前为类型化 SQLite Data Source）

etaf-playground → etaf
  └── 展示官方 Component 时可选依赖 etaf-ui
```

`etaf-ui` 是官方现成 Component 目录。用户只需要理解 Component；文件只是维护者边界。Controls、Widgets 和 DataGrid 不是平行的 Runtime 类型，DataGrid 只是由同一套 View、props、slot、事件和 Data 契约构成的复合 Component。

`etaf-db` 通过核心 Data Source capability 契约提供数据库后端接入。目前的 SQLite 后端负责 schema 声明、标识符校验、连接、分页和 mutation；Data Controller 及其响应式生命周期仍属于 ETAF core。SQLite 专用构造函数保留 `etaf-sqlite-*` 名称，通过唯一的 `etaf-db` 包入口加载。

`ebox-playground`、`etaf-playground`、`etaf-ui` 和 `etaf-db` 都是可以独立加载的同级包。`ebox-playground` 只使用 Ebox 公共 API，不加载 ETAF；`etaf-playground` 使用 ETAF 公共 API，并且只在展示官方组件时可选加载 `etaf-ui`，不依赖 `ebox-playground`。核心包不会自动加载任何可选包。

数据库后端由 `etaf-db` 承担，目前只实现 SQLite。REST、文件等非数据库集成可以独立实现 `etaf-data-source`，不增加通用 adapter 层或重复的数据源协议。

## 11. 保留式发布与 fixed-point 安全

mounted Component、expr、slot、fragment、raw、inline 和 Root owner 都经过同一
个外层 reactive dispatch。局部 owner 先生成 candidate generation 和 Ebox logical
replacement；不相交 owner 会合并为一次 Ebox publication。只有 Root owner
可以进入 complete-root adapter。

独立响应式 Host 属性及单表达式 Text Host 使用预备执行路径。View 编译器
提供属性与 inline 程序；挂载或普通发布后、公共生命周期回调前，Runtime
遍历当前 live generation 一次，把已经登记的响应式 primitive 程序绑定进一个
待编译成员池。绑定不求值应用 getter，也不构造未使用的 computed 分支。把成员
池编译进 Ebox 保留场景才是昂贵的一半，因此它由 idle timer 执行，或在该
generation 第一次全 primitive flush 需要 cohort 时按需执行；先到达的结构性
发布直接丢弃待编译池。Ebox 的准备报告排除不支持的成员，其余成员共享稳定
cohort 与 binding capability。未知成员或失效 capability 使用普通发布，由其
控制面边界重建绑定；输入分发不会为含结构性工作的队列编译 cohort。

同一 cohort 覆盖几何、绘制、native hover-content、单表达式 Text、已知 class
变体、固定边框形状的颜色及 Ebox 实际度量证明允许的 normal/bold 变化。class
变体按编译 Host 程序归集 generation 中已有或过去接受的值；普通 lowering 与
冷变体表都把 ETAF 的空白字符串/递归列表/symbol 语法转为 canonical token。
热写入仅查表并使用提供方值向量，语义与 public props 保留原始作者值；这是投影，
不增加状态权威。

热分发只把 dirty effect id 映射到保留的索引，求值该成员，并消费其求值完成时
捕获的依赖版本。observer 的较新写入及仍 dirty 的 computed 保留排队。单个
几何更新也使用同一 cohort，不再通过另一个操作重新绑定并使 focus cohort 失效。
既有 primitive 绑定表还能证明整批没有结构 owner，此时 settlement 跳过祖先链
并复用已绑定的 Component 环境。已接纳更新不重建 View、属性 plist 或结构候选。

全部 getter 成功后才 stage cohort。一次成对 stage 写入所有变化成员，仅推进
一次语义 generation/token；rollback 逆序恢复成员。成功的 inline 变化对每个
词法 Component owner 触发一次 updated。没有 Context 依赖的 hover-content
程序归属 Host effect，但通过同一依赖版本向量的子集索引保留原 Component 的
update 参与；canonical native 值的私有 `:interactions` 主链与 public flat props
同时绑定。有 Context 依赖的 hover 保留或退回原 render owner，新的 Context
计算缓存不会提前生效。有 hook 的 owner 使用既有 postcommit
retirement journal，hook 失败不会撤销已发布 cohort。普通发布使旧计划失效。
新依赖、Context/Theme 参与、不支持属性的变化、多段文本、提供方拒绝的文本尺寸
及结构更新仍使用普通候选路径。

结构 generation 拥有预备的可变标量单元。Ebox 的成对 stage 同时推进这些单元、
语义 generation 数字与 authority token；拒绝时恢复旧值及产物有效性。
实例、资源和路由成员未变化时，其 store version 保持不变。标量发布可以保留
generation 对象身份，因此完成判断使用公共 generation 数字或 Ebox revision。
Host 属性查询返回新的 plist 主链，显式 Runtime snapshot 继续脱离内部可变数据。
结构协调读取当前已提交单元，两条执行路径始终共享一份语义权威。

已提交 semantic generation 的唯一 mutable pointer 由
`etaf-generation-authority` 持有。handler 与 Host-prop 等公共查询直接读取该
generation；Runtime 中同名 hash table 只是由 generation 单向重建的兼容 mirror，
既不能独立授权查询，也不能反向改写 generation。迁移期的
`legacy`/`project`/`shadow` 路由只用于证明投影等价与安全回退，不增加第二份
committed truth。

进程 bootstrap 时，`etaf-render-port` 要求 Ebox framework SPI v3 与
`ebox-publication/v1`，并 snapshot 唯一的不可变 port。provider 缺失、格式错误或
不兼容都会在 Runtime mount 前 fail closed。Ebox 拥有 retained publication、
transaction participant 和 final-accept marker；ETAF 通过这些公共契约集成，
不引入第二个 publication provider 或兼容路由。mounted 或 in-flight Runtime
绝不会切换 port。

每个结构 semantic candidate 同时捕获 expected generation、semantic token，以及
instance/resource/artifact/route store versions。render 路径在 Ebox framework
stage 中暂存一次 CAS，失败时由同一个 inverse journal 恢复；没有可见 Ebox
变化的 semantic-only 路径由 ETAF 自己执行同一 CAS，不创建 Ebox publication 或 revision。CAS 后的 mirror 与旧 route 清理属于 postcommit，失败不能反向恢复已提交
token；这类失败会写入 retirement diagnostic journal，并用与 lifecycle failure
相同的 committed trailer 重新 signal，绝不会重新进入 semantic rollback。

每个 mounted Runtime 还拥有独立的 Host authority：`state / opaque token /
version`。initial framework stage 只进入 provisional state，并向 Ebox 注册固定
slot final marker；只有 buffer final accept 成功时 Host 才成为 attached。公开
lookup、event 和 source route 同时校验 attached state 与 token。detach 先在 O(1)
边界让 token 失效，再清理 registry、routes、Component scopes 和 Behaviors；因此
cleanup 数量或错误不能让旧 Host 重新获得 authority。

lifecycle callback 与结构 cleanup 在该 commit boundary 之后进入
`etaf-retirement-journal`。每个 entry 都有稳定 identity、ordering key、attempt
count、policy 与 terminal state。mounted、updated、unmounted 等公开 callback
只运行一次；第一个公开 callback 失败后，后续公开 callback 标记为 abandoned，
但结构 cleanup 继续。可幂等的框架 cleanup 只做有上限的重试；contained cleanup
只写 diagnostics，不改变已提交 generation、Ebox revision 或 Host authority。
Runtime 以有界历史保存已完成 journal，且它们与 committed outcome 分离。

当显式操作需要向调用者暴露 postcommit callback 错误时，ETAF 会用原 condition
symbol 重新 signal，并逐项保留原 condition data 前缀；末尾只追加一个固定
`:etaf-condition-trailer/v1` datum，其中包含 operation、outcome、generation、
Ebox revision 与 diagnostic-journal ID。`etaf-condition-postcommit-info` 会校验并
读取该 trailer，让调用者机械区分“已经提交、随后 callback 失败”和 rollback
failure。buffer-kill 路径会 drain 或 contain retirement 工作，但绝不会从 kill
hook 抛 retirement condition。

Reactive publication 由显式 `etaf-scheduler-context` 协调。context 拥有 source
与 Runtime FIFO、对应 dedupe set、effect claim、turn/projection epoch、
nesting/busy 状态、fault diagnostics 与成本计数器；它不拥有 Component、
resource 或 generation state。既有调用者继续使用
`etaf-scheduler-default-context`，mount 也可以传入 `:scheduler-context` 隔离
dispatch authority。Scope、Effect 与 opaque Runtime route 会继承并保留该
context。

一次 logical projection 会先按 live subscriber context 对所有 changed source
在一次 subscriber-table scan 中分组；所有已触及 context 的 source propagation
都稳定后，Runtime callback 才能 publish。在同一 context 中，每个 source 与
Effect 每个 scheduler turn 只 delivery 一次，多个 changed source 也只 enqueue
同一 Runtime 一次。已经 delivery 的 source 若重入写入，会延后到下一个 turn；
per-context turn budget 会包含跨 context cycle，并留下可复用的 fault diagnostics。
每个 source wave 都会 snapshot 当前 FIFO，因此 wave 中发现的不同 source 必须在
下一个受预算约束的 turn 执行，不能垄断一次 drain。context A 的 dedupe 不会压制
context B；registry/token/Host 校验会在 fan-out 前过滤 stale Runtime route。

Runtime callback 先作为一个完整 turn detach，因此 lifecycle write 会进入下一个
turn。Runtime 在分配 candidate 前，先求值 source 通知目标的 computed 输入，
与 committed output 编译时记录的依赖版本比较。输入相等的目标直接退出队列，
不渲染或发布；只访问已排队目标的直接依赖路径，不求值无消费需求的分支。
显式 candidate input、Context 与 retry 工作仍保留。prepared Host 成功发布后
原位刷新同一依赖版本向量；普通 candidate rollback 保留旧版本。
排队的结构 owner 先于后代计算处理；owner 已变化时，后代沿用普通生命周期
顺序。getter 使用消费者的 committed Component 环境；ambient Context
读取在更改 computed cache 前退回普通渲染，以保留 candidate Context 依赖收集。
某个 callback 失败时，scheduler 会先执行该 detached turn 中剩余 callback，
再把首个 condition 记录为 context fault。Data success/error 的 multi-ref
publication 与 event/action callback 都复用同一个 projection boundary，legacy
façade 则继续走 default context。Data source failure 会更新 Controller error state；
之后发生的 projection/render failure 保持原 condition，不能被重新归类为 source
failure。Runtime operation report 同时携带本 context delta 与完整 cross-context
projection summary，覆盖 source delivery、
subscriber visit、effect work、Runtime work、stale drop、turn 与 fault。

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

只有在现有 owner 无法表达、能够明确 identity/lifecycle/error/rollback 规则，并且可以用公共路径测试证明时，才增加新的公共概念。这样既保留完整的 Elisp 表达能力，又让用户模型保持干净。
