# ETAF Component 定义：目标设计

> 状态：已完成架构审查的目标设计，尚未实现。
>
> 本文只定义目标公共契约，不代表当前版本已经支持这些写法。当前实现差距见
> “实现状态与迁移”一节。审查通过并完成代码、测试、GUI 与性能门禁后，稳定内容
> 才能进入用户指南。

本文只拥有 **Component 作者语法和作者可见语义**。属性 owner、跨包依赖、
transaction 权限、Ebox/TP/Rust 边界仍以
[module-boundaries.zh.md](module-boundaries.zh.md) 为准；本文只引用，不复制第二套
系统规范。本文的 DSL 选择取代旧 capability-expansion 草案中的 Structural Expr
方向；对应计划和测试规格必须原子更新后才能实施。

## 1. 目标

ETAF 只保留一种 Component 语义模型，但允许用户用两种严格分开的方式定义它：

1. **DSL 模式**：类似 Vue template，结构由 tag、attribute、slot 和少量编译指令表达；
2. **代码模式**：类似 React render function，结构由普通 Elisp 和唯一节点构造函数
   `etaf-node` 表达。

两种写法只是两个 authoring frontend。它们产生同一种规范 View IR，共用同一个：

- Component Registry；
- props 与 slots 契约；
- retained Component identity；
- reactive Scope；
- Context 与 Theme；
- lifecycle；
- Range/Fragment；
- Runtime generation；
- Ebox lowering；
- TP/Emacs 原子提交与回滚。

不能因为支持两种写法而产生两套 Component、两套节点、两条 Runtime 或两种生命周期。

## 2. 最小心智模型

用户只需先理解五个概念：

1. **Component**：可复用、可保留状态和生命周期的语义单元；
2. **Host**：真正参与文本、盒模型和布局的视觉节点；
3. **props**：父级传入的只读输入；
4. **state**：Component 实例自己保留的状态；
5. **children/slots**：父级交给 Component 的子内容。

然后二选一：

```text
喜欢声明式模板  → :view DSL
喜欢完整 Elisp   → :render + etaf-node
```

普通用户不需要理解 Ebox node id、TP object、buffer text property、compiler block、
Runtime generation 或 Rust tape。

## 3. 唯一 Component 定义外壳

两种模式都使用同一个定义入口：

```elisp
(etaf-define-component NAME (&key PROP ...)
  [DOCSTRING]
  [:setup SETUP-FORM]
  (:view VIEW-FORM | :render RENDER-FORM)
  [:styles STYLES-FORM])
```

规则：

- `NAME` 是 Component Registry 中的准确 symbol；
- props 只使用 `(&key PROP ...)` 声明；
- `:view` 与 `:render` 必须且只能出现一个；
- `:setup` 只初始化实例；返回值通过显式函数 `etaf-state` 读取，不能返回 render
  function；
- `:styles` 是可选静态 Component stylesheet；
- 未知、重复或不完整 clause 在定义时直接报错；
- 不存在根据返回值猜测定义模式的行为。

推荐固定按下面的顺序书写：

```text
docstring → :setup → :view/:render → :styles
```

解析器可以按 keyword 识别 clause，但正式示例只展示这一种顺序。

## 4. Component 名称与命名空间

Component tag 属于 ETAF Component Registry，不属于 Elisp function namespace。

```elisp
(etaf-define-component book-detail (&key book)
  :view
  (box (expr (book-title book))))

(defun book-detail (book)
  ;; 普通 Elisp function；不会改变上面的 Component tag。
  ...)
```

在 DSL 的 View 位置中，`(book-detail ...)` 永远查 Component Registry；在普通 Elisp
函数位置中，`(book-detail value)` 永远调用 Elisp function。ETAF 不使用 `fboundp`、
load order 或返回值猜测二者。

Registry 中的重复 Component name 是错误。框架/库作者应使用明确前缀或 namespaced
symbol；受控应用可以使用短名。核心不自动删除 `etaf-` 前缀，也不根据当前已加载
function 生成 alias，因为这种行为会让同一源码随加载顺序改变语义。

## 5. DSL 模式：`:view`

### 5.1 基本定义

```elisp
(etaf-define-component status-card (&key title message)
  "Render one status card."
  :view
  (column :class '(status-card)
    (text :class '(status-card__title) (expr title))
    (box :class '(status-card__body)
      (expr message))))
```

Component 的 `:view` 本身就是 DSL 编译边界，里面不再套 `etaf-view`。

### 5.2 DSL 的唯一结构

```elisp
(TAG :PROPERTY VALUE ... CHILD ...)
```

规则：

- 所有属性必须位于所有 child 之前；
- `TAG` 必须是 Registry 中的 Host 或 Component；
- Host/Component 位置不执行同名 Elisp function；
- property value 是普通 Elisp value expression；
- child 位置只接受字符串、nil、DSL node、slot 或 `(expr FORM)`；
- DSL node 不 quote；被 quote 的 list 只是数据，不会变成 View；
- raw list、vector 或任意 Elisp control form 不能直接充当 child。

### 5.3 属性值仍是普通 Elisp

```elisp
(box :width '(viewport)
     :color (if active "#ffffff" "#777777")
     :on-press (lambda () (select-item item-id))
     :key (book-id book)
  ...)
```

这里：

- `'(viewport)` 遵循普通 Elisp quote；
- `(if ...)` 是属性值表达式；
- `(select-item ...)` 是 callback 中的 Elisp function；
- `(book-id book)` 是计算 key 的 Elisp function；
- 只有最外层 `(box ...)` 处于 DSL View 位置。

### 5.4 Core Host

目标 core Host 只有：

| Host | 作用 |
| --- | --- |
| `text` | 显式 Text；需要文本属性时使用。 |
| `box` | 普通 Box；默认 Normal layout。 |
| `row` | Box + Row layout 的作者糖。 |
| `column` | Box + Column layout 的作者糖。 |
| `flex` | Box + Flex layout 的作者糖。 |
| `grid` | Box + Grid layout 的作者糖。 |
| `fragment` | 无视觉几何的透明 child group/Range。 |

普通字符串 child 自动规范化为 Text：

```elisp
(box "Hello")
```

等价于没有额外 Text 属性的：

```elisp
(box (text "Hello"))
```

需要 color、font、ref 或其他 Text 能力时显式写 `text`。`fragment` 不参与布局，
不伪装成 Box，也不引入公开 `flow`、`spacer`、`item` 或 `grid-item` 节点。

视觉属性的完整 schema、适用 Host、alias、shorthand 和 ParentParticipation 由
[module-boundaries.zh.md](module-boundaries.zh.md) 的统一 property schema 单独定义；
本文不复制第二份属性表。

### 5.5 文本插值：`expr`

DSL 中唯一的动态文本桥接是：

```elisp
(expr FORM)
```

例如：

```elisp
(text (expr (concat "Selected: "
                    (plist-get selected-book :title))))
```

`expr` 的目标契约：

- 没有 `:value`；
- 没有 attrs 或 children；
- `FORM` 是普通 Elisp；
- 结果只能是 nil、string 或 propertized string；
- nil 表示空文本；
- 不能返回 View、Component、Fragment 或 node sequence；
- 不能承担 selection、loop、key 或 lifecycle；
- property value 已经是 Elisp value position，不使用 `expr`。

因此 `expr` 只对应模板文本插值，不再是结构逃生口。

### 5.6 结构指令

DSL 第一版只保留四个 compiler-owned directive：

```text
:if
:else-if
:else
:for
```

以及已有 identity metadata：

```text
:key
```

#### 条件

```elisp
(column
  (book-detail :if selected-book :book selected-book)
  (empty-detail :else t))
```

```elisp
(column
  (loading-view :if loading-p)
  (error-view :else-if error :error error)
  (book-list :else t :books books))
```

规则：

- `:else` 的值必须是 literal `t`；
- `:else-if`/`:else` 必须直接相邻地跟在同级 `:if` 后；
- chain 不能跨 Fragment、Component、slot 或 opaque boundary；
- 缺少最终 `:else` 等价于空 arm；
- branch 切换只有在新 generation 成功后才释放旧 arm；
- 失败时恢复原 arm、identity、文本与属性。

#### 循环

```elisp
(column
  (book-row :for (book books)
            :key (book-id book)
            :book book))
```

规则：

- 语法固定为 `:for (ITEM ITEMS)`；
- `ITEMS` 每次 update 只求值一次；
- `ITEM` 只在该 node 的 key、props、children 和 interpolation 中可见；
- `:key` 必填；
- key 只能是非 nil symbol、integer 或防御性复制的 string；
- key 用 `equal` 比较；
- float、隐式 index key、重复 key 在 candidate mutation 前报错；
- 任一 branch directive（`:if`、`:else-if`、`:else`）都不能与 `:for` 出现在同一
  node；所有组合都是 compile error，没有隐藏优先级；
- 多 node item 使用 `fragment`，不增加视觉 Box。

`:if`、`:else-if`、`:else`、`:for` 在 compiler lowering 后被移除，Component props、
ECSS、Ebox、TP 和 Emacs adapter 都看不到 directive。

第一版不加入 custom directive registry、`:show`、`:await`、`:model`、`:memo`、
transition 或其他 convenience。它们只有经过独立真实场景证明后才能新增。

## 6. 代码模式：`:render`

### 6.1 基本定义

代码模式的 render body 是普通 Elisp：

```elisp
(etaf-define-component book-list (&key books selected-book)
  :render
  (let ((children
         (append
          (when selected-book
            (list
             (etaf-node
              'book-detail
              (list :book selected-book)
              nil)))
          (mapcar
           (lambda (book)
             (etaf-node
              'book-row
              (list :key (book-id book)
                    :book book)
              nil))
           books))))
    (etaf-node 'column nil children)))
```

这里的 `let`、`when`、`append`、`mapcar`、`lambda` 和 `book-id` 全部是普通 Elisp。
ETAF compiler 不把它们解释成 DSL。

### 6.2 唯一节点构造函数

代码模式只用一个公共节点构造函数：

```elisp
(etaf-node TAG PROPS CHILDREN &optional NAMED-SLOTS)
```

参数契约：

- `TAG`：准确的 Host/Component Registry symbol；
- `PROPS`：已经求值的 keyword/value plist，或 nil；
- `CHILDREN`：已经求值的 child list，或 nil；
- `NAMED-SLOTS`：只供 Component call 使用的 `(NAME . CHILD-LIST)` alist；
- 返回经过验证、带当前 View IR ABI 的 typed View value。

示例：

```elisp
(etaf-node 'box
           (list :padding 1 :background-color "#20242a")
           (list "Hello"))
```

```elisp
(etaf-node 'panel
           (list :key panel-id)
           default-children
           (list (cons 'header header-children)
                 (cons 'actions action-children)))
```

`etaf-node` 的约束：

- 它是普通 function，不是 macro；
- `TAG` 通常要 quote，因为它是 Elisp symbol value；
- 它不接收 DSL source list；
- `PROPS` 中不接受 `:if`、`:else-if`、`:else`、`:for`；
- 条件与循环直接使用 Elisp；
- 动态文本直接使用 string，不使用 `expr`；
- string child 自动规范化为 Text；
- nil child 被忽略；
- raw source list、任意 object 或未验证 sequence 被拒绝；
- named slots 只能用于 Component，Host 收到它时报错；
- Component 的 `:key` 是 identity metadata，不传入业务 props。

多根结果显式使用 Fragment：

```elisp
(etaf-node 'fragment nil nodes)
```

不允许 render body 直接返回一个 node list，因为“一个 View”与“多个 siblings”必须
有不同类型，不能再次依靠 list 形状猜测。

### 6.3 Render 结果

`:render` 只能返回：

```text
nil | string/propertized-string | one typed View value
```

需要多个 sibling 时返回 Fragment。不能返回：

- DSL source form；
- quoted/quasiquoted View list；
- node vector/list；
- Ebox node；
- buffer string patch；
- render closure。

严格分离发生在 Component 的**定义边界**：`:render` body 不写 DSL source form，
`:view` body 不写普通结构 control。已经由独立 helper 返回的、通过 ABI validator 的
typed View 可以被代码模式组合；Runtime 不保存 frontend provenance，也不反向猜测
这个 typed value 最初由 macro 还是 function 构造。给共享 IR 增加 provenance 只为
禁止 helper 组合会制造第二种无业务价值的身份，因此不采用。

### 6.4 纯 render 纪律

代码模式允许完整 Elisp control flow，但 render 必须是框架意义上的纯计算：

- 可以读取 props、`(etaf-state)` 返回对象中的 ref/computed、Context、Theme 和
  Resource/Data state；
- 可以调用无副作用 helper；
- 可以创建短生命周期 typed View value；
- 不能写 ref、发 Action、修改 Data、注册 Effect/lifecycle、mount/unmount 或写 buffer；
- 不能在 render 中创建需要 cleanup 的长期资源；
- Runtime 应在 render phase 拒绝可检测的 mutation，而不是让副作用重复执行。

需要副作用、订阅或 cleanup 的代码放进 `:setup`、event callback、Action、Behavior、
watch/effect 或 Resource/Data owner。

### 6.5 Unkeyed 与 keyed identity

代码模式没有 DSL compiler 的静态 call-site token。未加 `:key` 的 sibling 按父级、
ordinal 与 tag 参与 identity；固定结构可以使用它。任何可能插入、删除或重排的
collection 都必须使用稳定 `:key`，否则状态按位置迁移属于作者错误。

ETAF 不根据 `mapcar`、`cl-loop` 或返回 list 猜测“这是动态列表”，也不偷偷生成
index key。

## 7. Props

```elisp
(etaf-define-component user-card (&key user compact on-open)
  ...)
```

规则：

- 声明只接受普通 symbol；
- 每个 prop 对应同名 keyword，例如 `user` 对应 `:user`；
- 未传 prop 的值为 nil；
- 未声明为业务 prop、也不属于统一 Host schema 的名称在调用边界报错；
- 重复 prop、重复 canonical Host property domain、奇数 plist 在调用边界报错；
- props 在一次 render 中是只读 snapshot；
- prop 更新不重新运行 setup，只触发依赖它的 render/patch；
- `:key` 和 directive 不会进入 Component 业务 props；
- Component 显式声明的同名属性优先归入业务 props；其他合法 Ebox style/layout 属性
  与 ETAF Host metadata 归入独立 attrs，并只透传到单一根 Host；
- 第一版不增加另一套 required/default/type schema。需要校验时在 setup 或普通 helper
  中显式完成，后续只有真实重复证据才能扩展 prop declaration。

在 `:view` 和 `:render` 中，声明的 prop symbol 绑定到当前 Component input，不依赖
同名全局变量。局部 `:for` item 不能与 prop 重名。

### 7.1 输入 namespace

同一 keyword plist 在解析时按 node kind 使用一个确定的 namespace：

| 输入 | Host | Component | Fragment | `etaf-node` 代码模式 |
| --- | --- | --- | --- | --- |
| `:if/:else-if/:else/:for` | DSL directive | DSL directive | DSL directive | 全部拒绝 |
| `:key` | framework identity | framework identity | framework identity | 同一 identity 规则 |
| Host schema property/metadata | 按 Host schema | 显式同名 prop 消费，否则进入 root attrs | 拒绝 | 按实际 TAG kind |
| declared Component prop | 不适用 | 接受 | 拒绝 | 按实际 TAG kind |

Component prop declaration 禁止 `key`、`if`、`else-if`、`else`、`for`。
directive 在业务 prop 验证前剥离；`:key` 单独进入 framework identity。剩余输入
只通过统一 Ebox/ETAF Host schema 判定 attrs，不能由组件库复制属性白名单。

### 7.2 单根 Host attrs 透传

Component 调用输入规范化为四个互不重叠的域：

```text
declared props | Host attrs | :key | slots
```

attrs 遵守下面的不变量：

- 单一根 Host：attrs 应用到该 Host；
- 单一根 Component：attrs 沿根 Component 链继续传递；若下游显式声明同名 prop，
  则由下游消费；
- string 根：先规范化为 Text，再应用 attrs；
- nil、slot projection 或 Fragment/多根结果：存在 attrs 时精确报错，不能猜目标；
- `class` 合并并去重；
- Ebox style/layout attrs 先按 canonical property domain 去重，调用方值覆盖组件视觉
  默认值；
- `role`、`ref`、`disabled`、`:on-*` 等 Runtime metadata 若与根 Host 已有值冲突，
  精确报错；需要由 Component 管理的 metadata 应声明为业务 prop；
- attrs 在调用方 Component 环境中求值，不能泄漏到被调用 Component 的 setup、
  `etaf-state` 或业务 props；
- 实际根 Host 仍通过 `ebox-style-property-accepted-p` 验证适用域，例如 Text 根不能
  接收 Box padding。

这条规则对应前端的 single-root fallthrough attribute，但 ETAF 只接受已注册的
Host schema 名称；任意未知 keyword 仍然是错误。

所有 Host、Component、Fragment、DSL `:for` item 与 `etaf-node` 使用同一 key
契约：key 必须是非 nil symbol、integer 或 string；string 在 author boundary
防御性复制；比较函数固定为 `equal`；float、mutable composite 和 duplicate key
在 candidate mutation 前报错。

## 8. Setup 与 State

### 8.1 Stateful DSL Component

```elisp
(etaf-define-component counter (&key initial-value)
  :setup
  (etaf-ref (or initial-value 0))
  :view
  (column
    (text
     (expr
      (number-to-string (etaf-value (etaf-state)))))
    (box
        :on-press
        (let ((count (etaf-state)))
          (lambda ()
            (setf (etaf-value count)
                  (1+ (etaf-value count)))))
      "Increment")))
```

### 8.2 Stateful code Component

```elisp
(etaf-define-component counter (&key initial-value)
  :setup
  (etaf-ref (or initial-value 0))
  :render
  (let ((count (etaf-state)))
    (etaf-node
     'column nil
     (list
      (number-to-string (etaf-value count))
      (etaf-node
       'box
       (list :on-press
             (lambda ()
               (setf (etaf-value count)
                     (1+ (etaf-value count)))))
       (list "Increment"))))))
```

### 8.3 多个状态：返回一个显式 model

`:setup` 永远只返回一个值。Component 有多个 ref/computed/resource 时，把它们放进
一个普通 Elisp model；ETAF 不自动解构字段，也不注入字段名。

小型 Component 推荐使用 plist：

```elisp
(etaf-define-component counter (&key initial-value)
  :setup
  (let ((count (etaf-ref (or initial-value 0)))
        (step (etaf-ref 1)))
    (list :count count :step step))
  :view
  (column
    (text
     (expr
      (let ((count (plist-get (etaf-state) :count)))
        (number-to-string (etaf-value count)))))
    (box
        :on-press
        (let* ((model (etaf-state))
               (count (plist-get model :count))
               (step (plist-get model :step)))
          (lambda ()
            (setf (etaf-value count)
                  (+ (etaf-value count) (etaf-value step)))))
      "Increment")))
```

完整数据流是：

```text
:setup
→ 返回 (:count COUNT-REF :step STEP-REF)
→ etaf-state 取得整个 model
→ plist-get 取得指定 ref
→ etaf-value 取得 ref 当前值
```

复杂或复用的 Component 可以主动定义 struct，但定义必须与使用一起展示：

```elisp
(cl-defstruct
    (counter-model (:constructor counter-model-create))
  count
  step)

(etaf-define-component counter (&key initial-value)
  :setup
  (counter-model-create
   :count (etaf-ref (or initial-value 0))
   :step (etaf-ref 1))
  :render
  (let* ((model (etaf-state))
         (count (counter-model-count model))
         (step (counter-model-step model)))
    (etaf-node
     'text nil
     (list (format "%s (+%s)"
                   (etaf-value count)
                   (etaf-value step))))))
```

`counter-model-create`、`counter-model-count`、`counter-model-step` 明确由紧邻的
`cl-defstruct` 定义产生，不是 ETAF API。ETAF 不增加 `(etaf-state :count)` 之类的
plist-only shortcut，也不自动注入 `count`/`step`；这样 state 可以同样是 ref、plist、
struct、Data Controller、Resource 或应用自己的任意 model。

### 8.4 Setup 语义

- setup 是普通 Elisp form，不是第二种 DSL；
- 每个 retained Component identity 只运行一次；
- setup 的返回值就是该实例的 opaque state；
- Runtime 不解析、复制或按 plist 约定解释 state；
- `etaf-state` 在当前 Component 的 `:view`/`:render` 求值期间返回 setup 的准确结果；
- Runtime 单独记录 Component 是否定义 setup；setup 合法返回 nil 时，`etaf-state`
  成功返回 nil，不能把 nil 当作“没有 setup”的 sentinel；
- 没有 setup 或在 Component render context 之外调用 `etaf-state` 会精确报错；
- ETAF 不注入裸 `state` variable，也不按返回对象的字段名自动注入变量；
- prop 更新不重新执行 setup；
- setup 中直接读取的 prop 是初始化 snapshot，普通 lexical closure 也保留这个初始值；
- setup callback 不会在未来执行时隐式恢复“当前 prop 环境”；
- 需要当前 prop 的 event callback 应在每次 `:view`/`:render` 中显式闭包当前值，或
  调用 state 中接受当前值作为参数的 action；
- setup 不读取或保留 slot projection；slots 只在 `:view`/`:render` 阶段读取；
- setup 失败时不创建可见实例；候选失败时释放候选 Scope；
- setup 不返回 render function，不包含 `etaf-view`，也不调用 `etaf-node` 构造结构。

最简单的 state 可以直接是一个 ref，如上例。需要多个值时可以返回普通 plist 或
用户自己明确定义的 `cl-defstruct`；若使用 struct，文档必须同时展示它的定义，并
说明 constructor/accessor 来自该定义，不能把生成函数当作不言自明的框架 API。
reactive value 放在 `etaf-ref`/`etaf-computed` 中。Runtime 不要求某一种业务数据结构。

## 9. Reactivity 与 Scope

Component setup 可以组合现有响应式能力：

| 能力 | API |
| --- | --- |
| 可写状态 | `etaf-ref`、`etaf-value`、`setf`/`etaf-set-value` |
| 派生状态 | `etaf-computed` |
| 精确观察 | `etaf-watch` |
| 自动依赖 Effect | `etaf-watch-effect` |
| 子 Scope | `etaf-effect-scope`、`etaf-scope-run`、`etaf-scope-stop` |
| cleanup | `etaf-on-scope-dispose` |

不变量：

- reactive source 有稳定 owner；
- render 只订阅实际读取的 source；
- 一次 Action/event 中的多次写入合并为一个 Runtime batch；
- Component 被成功移除后停止其 Scope；
- candidate 回滚不能停止仍属于旧 generation 的 Scope；
- setup、watch、effect 与 resource cleanup 各执行准确一次。

## 10. Children 与 Slots

### 10.1 默认 slot

调用方 trailing children 自动进入 `default` slot：

```elisp
(panel
  (text "Body"))
```

Component DSL 中投影：

```elisp
(box (slot))
```

带 fallback：

```elisp
(box (slot (text "Empty")))
```

### 10.2 Named slot

调用方：

```elisp
(panel
  (slot :name 'header
    (text "Books"))
  (slot :name 'actions
    (box :on-press on-add "Add"))
  (text "Body"))
```

Component：

```elisp
(column
  (slot :name 'header)
  (slot)
  (slot :name 'actions))
```

代码模式调用 Component 时，`etaf-node` 的第四个参数传 named-slot alist；代码模式
读取当前 slots 时使用 `etaf-current-slot`/`etaf-current-slots`，返回规范 child list。

Slot 规则：

- name 是 quoted、稳定、非 keyword symbol；
- 默认 slot 不能同时由 trailing children 和显式 named input 提供；
- 同名 slot input 不能重复；
- slot 内容的语义 owner 是调用方，projection 位置属于接收方；
- projection 移动、Component 更新与 rollback 不能改变 caller-owned identity；
- slot 不是 Box，不引入布局。

## 11. Styles、class 与 id

```elisp
(etaf-define-component card (&key title)
  :view
  (column :class '(card)
    (text :class '(card__title) (expr title))
    (slot))
  :styles
  (styles
    (".card" :padding 1 :background-color "#20242a")
    (".card__title" :font-weight bold)))
```

契约：

- `:styles` 是 definition-owned static source；
- selector/cascade/inheritance 只由 ECSS 运行一次；
- `:class`/`:id` 是 selector source metadata，不是 CSS declaration；
- inline style、Component stylesheet、Theme/state contribution 最终进入同一 computed
  property/projection pipeline；
- Ebox/TP 不重新运行第二次 cascade；
- alias 在 parse 时归一化，后端只看到 canonical property ID；
- `etaf-component-set-styles` 只服务显式 authoring/hot-reload 工具，不隐式刷新全部
  Runtime。

## 12. Events、Action 与 Behavior

### 12.1 局部 callback

Host 的 `:on-*` metadata 接受 function：

```elisp
(box :ref 'save-button
     :on-press (lambda () (save-document document))
  "Save")
```

callback 属于当前 Runtime/Component identity，由 `etaf-dispatch-event`、
`etaf-activate` 或对应输入适配器调用。它不进入 ECSS 或 Ebox layout property。

### 12.2 Action

跨 Component 的命名业务变更使用：

```text
etaf-action-define
etaf-action-register
etaf-dispatch
etaf-action-undefine
```

Action 是变更边界，不是 Component、Host 或 directive。

### 12.3 Behavior

可复用交互属性 bundle 使用：

```text
etaf-define-behavior
etaf-behavior-create
etaf-focusable
etaf-toggleable
```

Host 通过 `:use` 安装 Behavior。Behavior 可以组合 callback、ref、focus 等语义，
不能创建第二套 Widget Runtime。

## 13. Context 与 Theme

setup 中通过：

```text
etaf-provide / etaf-inject
etaf-theme-provide
etaf-theme-defaults
etaf-theme-value
etaf-theme-token
```

组合非视觉依赖和 Theme token。

规则：

- Context 沿 Component identity tree 继承；
- provider 属于一个 retained Component Scope；
- Theme 是 Context 中的语义值，不是 TP palette 的业务别名；
- `etaf-theme-tp` 只是可选 palette adapter；
- View/render 读取 Theme 形成依赖；
- Theme 更新只影响实际读取 token/property 的 owner；
- 不因为 Theme 改变而默认重跑所有 Component。

## 14. Lifecycle

setup 中注册：

```text
etaf-on-mounted
etaf-on-updated
etaf-on-unmounted
etaf-on-scope-dispose
```

精确顺序：

```text
candidate setup
→ candidate render/lower
→ Ebox/TP 原子提交
→ generation promotion
→ mounted/updated callback
```

移除时：

```text
successful replacement/removal
→ unmounted
→ Scope/resource cleanup
```

失败 candidate 不触发旧实例 unmounted；observer、updated callback 或应用 callback
不能取得 transaction commit 权限。生命周期 callback 不在纯 render 中注册。

Lifecycle hook 发生在 generation promotion 之后，因此 hook error **不能回滚已经提交
的 buffer/generation**。mounted/updated hook error 被 Runtime error reporter 包含并继续
执行其余 postcommit 工作；unmounted hook error 也被包含，Scope/Resource cleanup
始终通过 `unwind-protect` 完成，不能被 hook 中断。

## 15. Resource、Data 与存储

Component 本身不实现数据库或异步调度。setup 只组合 owner 已明确的能力：

- `etaf-resource`：Component Scope 所有的 load/value/error/cleanup；
- `etaf-data-controller`：query/page/items/selection/mutation 状态；
- `etaf-sqlite` 或未来 `etaf-db` provider：I/O 与事务；
- Component View/render：读取状态并显示 UI。

典型 state：

```elisp
(cl-defstruct shelf-state data selected-book)
```

setup 创建 controller/resource 并把它放入 state；DSL/代码 render 通过公共 accessor
读取。unmount 由 Scope/owner cleanup，不由 View node 自己关闭数据库。

第一版不增加 `:await`、Resource directive、Promise node 或数据库专用 Component。
异步 Request、cancel 和 stale-result 语义必须先在 Resource/Data owner 中冻结，再决定
是否需要新的作者语法。

## 16. Error 与回滚

### 16.1 Precommit failure

Component 的 setup、render、directive、property expression、lowering 或 Ebox/TP
precommit 失败时：

- 当前成功 generation、buffer 文本、文本属性和 identity 保持不变；
- candidate 中新建的 Scope/Resource 被释放；
- 旧 arm/list/order 继续有效；
- framework publish/rollback 仍由 Runtime/Ebox/TP transaction participant 控制；
- observer 只读，不能授权 commit；
- 失败不能通过退化成 full-root、跳过属性或吞掉 lifecycle 来“恢复”。

### 16.2 Postcommit failure

mounted/updated/unmounted hook 和只读 observer 在 promotion 后运行。它们的 error：

- 不回滚已经成功的 generation；
- 不阻止其余 hook、observer 或 cleanup；
- 进入统一 Runtime diagnostic/error reporter；
- 不获得重新发布或修改 transaction decision 的权限。

event/Action callback 的 mutation 与 error 原子性由 Runtime Action transaction 契约
单独定义，不能与 lifecycle postcommit error 混为一类。

`etaf-error-boundary-run` 只是同步函数调用边界。它不是结构性 subtree boundary；在
candidate checkpoint、fallback failure、cleanup 和 retry identity 没有独立证明前，
不伪装成模板 error-boundary directive。

## 17. Root 使用与 mount

DSL root：

```elisp
(etaf-mount
 "*books*"
 (etaf-view
   (books-app :database database)))
```

代码 root：

```elisp
(etaf-mount
 "*books*"
 (etaf-node 'books-app
            (list :database database)
            nil))
```

卸载：

```elisp
(etaf-unmount runtime)
```

`.etaf`、Playground、未来 SFC compiler 或普通 `.el` 只能生成这两个公共入口之一，
不能创建第二套文件 Runtime、companion execution protocol 或隐式 mount 语义。

## 18. 编译、IR 与性能

### 18.1 DSL

`etaf-view`/`:view` 在 macro/compiler boundary：

- 解析 tag、attrs、slots、directive 和 interpolation；
- 生成 versioned `etaf-view-blueprint/2`；
- 静态结构提前验证；
- directive lowering 为已有 Branch/KeyedSequence/Range block；
- Runtime 只填动态洞并验证 ABI。

### 18.2 代码模式

`:render` 是普通 Elisp；每次需要 render 时运行用户代码，`etaf-node` 立即构造同一
ABI 的 typed View value。Runtime 不 eval raw list，也不把它重新送进 DSL compiler。

### 18.3 共同要求

- 两种模式共享一个 bounded IR validator；
- 同一输入只 materialize 一次；
- 下游保留 stable identity、dependency、Range、layout proof 和 paint contribution；
- DSL 静态 blueprint 与代码 View value 进入同一 retained reconciliation；
- keyed list 允许一次 O(n) key/order certification，下游为 O(changed+moves)；
- 不允许每层重新扫描 O(all)；
- 旧 ABI、旧 builder 或 stale `.elc/.eln` 必须给出 clean-rebuild error，不能静默兼容；
- 两种模式都必须通过真实 GUI p95/max ≤ 50ms 门禁。

## 19. 严格禁止的混写

下面全部是定义错误：

```elisp
;; 同时选择两个 frontend
:view   (column ...)
:render (etaf-node 'column nil nil)
```

```elisp
;; setup 返回 render closure
:setup (lambda () (etaf-view (column ...)))
```

```elisp
;; :render 定义边界直接嵌 DSL source
:render (etaf-view (column ...))
```

```elisp
;; DSL child 里直接写 Elisp control
:view (column (mapcar #'make-row books))
```

```elisp
;; expr 返回结构
:view (column (expr (etaf-node 'book-row nil nil)))
```

```elisp
;; etaf-node 使用 directive
(etaf-node 'book-row
           (list :for (list 'book books))
           nil)
```

```elisp
;; 代码 render 返回 raw node list
:render (mapcar #'make-row books)
```

这些错误不能通过 runtime 猜测、quote 规则、兼容 wrapper 或 load order 自动修复。
普通 helper 返回的已验证 typed View 可以在代码模式中复用；这不是第二套 author
grammar，也不要求 IR 保存 frontend provenance。

## 20. 两种模式的完整对照

| 问题 | DSL `:view` | 代码 `:render` |
| --- | --- | --- |
| node | `(box ...)` | `(etaf-node 'box PROPS CHILDREN)` |
| Component call | `(book-row :book book)` | `(etaf-node 'book-row (list :book book) nil)` |
| 条件 | `:if/:else-if/:else` | `if/when/cond` |
| 循环 | `:for (item items)` + `:key` | `mapcar`/`cl-loop` + node `:key` |
| 动态文本 | `(expr FORM)` | 普通 string expression |
| 多根 | `(fragment ...)` | `(etaf-node 'fragment nil nodes)` |
| 默认 slot 输入 | trailing children | `CHILDREN` 参数 |
| named slot 输入 | `(slot :name 'x ...)` | `NAMED-SLOTS` 参数 |
| slot projection | `(slot ...)` | `etaf-current-slot` |
| property value | 普通 Elisp expression | 已求值 plist value |
| quote | node 不 quote；value 按 Elisp | 全部按普通 Elisp |
| tag resolution | Component/Host Registry | Component/Host Registry |
| Elisp function resolution | 仅 value/expr/callback | 普通函数位置 |
| topology compiler | 是 | 否 |
| Runtime/identity/lifecycle | 同一套 | 同一套 |

## 21. 实现状态与迁移

截至本文创建时，当前代码的真实状态是：

| 能力 | 当前状态 | 目标动作 |
| --- | --- | --- |
| `etaf-define-component :view` | 已实现 | 按新 DSL grammar 收敛。 |
| `:setup` | 已实现，但返回零参数 render function | 删除旧语义；改为只返回 state。 |
| `etaf-state` | 未实现 | 新增 setup result 的唯一显式 accessor。 |
| `:render` | 未实现 | 新增严格代码 frontend。 |
| `etaf-node` | 未实现 | 新增唯一普通函数节点构造器。 |
| `(expr :value FORM)` | 当前实现 | 删除；只保留 `(expr FORM)` 文本插值。 |
| `:if/:else-if/:else/:for` | 未实现 | 由 compiler lowering，Runtime 不接收 directive。 |
| Component alias | 当前会参考 `fboundp` 自动生成 | 删除 load-order-dependent alias；只用准确 registry name。 |
| 单根 Host attrs | 已实现最小纵向切片 | 继续迁移 etaf-ui，删除重复视觉 props 声明。 |
| Host | 当前已有 text/box/fragment/row/column/flex/grid | 保持最小闭集。 |
| props/slots/styles/reactivity/lifecycle | 已有主体能力 | 迁移到共同 ComponentDefinition，不复制实现。 |

这是一次 clean migration，不保留以下 compatibility：

- setup-return-render；
- `(expr :value ...)`；
- 结构 Expr；
- load-order-dependent Component alias；
- raw quoted View list；
- `:render` 定义边界中的直接 DSL wrapper；
- DSL 中的任意 direct-child Elisp。

## 22. 落地门禁

实现只有同时满足下面条件才算完成：

1. definition parser 精确拒绝混写、未知 clause、重复/保留 prop；
2. DSL 与代码模式生成同一版本 typed View IR；
3. 同名 Elisp function/variable 的新增、删除和加载顺序不改变 tag 语义；
4. props、single-root attrs、default/named slot、styles、Context、Theme、events、Behavior
   全部等价；多根 attrs 精确拒绝；
5. setup-once、prop update、mounted/updated/unmounted、Scope cleanup 等价；
6. branch 与 keyed list 的 insert/delete/reorder 保留正确 identity；
7. injected failure 完整恢复 generation、文本、文本属性、Range 与 lifecycle；
8. stale bytecode/IR 只有 clean-rebuild error，没有兼容成功路径；
9. Research Shelf 同时用 DSL 与至少一个代码 Component 证明真实组合能力；
10. `research-shelf.etaf`、`flex-reference.ebox`、`grid-reference.ebox` GUI 无告警、
    渲染正确；
11. resize、scroll、row、page、filter、theme、add、reload 的固定场景 p95 与 max
    都不超过 50ms；
12. 文档、tests、byte/native compile、dependency boundaries 全部通过后才迁入正式
    API reference。

## 23. 最终决策摘要

```text
一个 Component 模型
├── DSL frontend:    :view + tag/directive/expr
└── Code frontend:   :render + ordinary Elisp + etaf-node

共享：props + setup/etaf-state + slots + styles + reactive Scope
    + Context/Theme + events/Action/Behavior + lifecycle
    + Resource/Data + identity/Range + atomic rollback
```

核心约束是：

> DSL 负责声明结构；代码模式负责用普通 Elisp计算结构；两者都只产生同一种 typed
> View，不互相嵌套，不通过猜测跨越边界。
