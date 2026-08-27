# ETAF 模块职责与目标架构（设计提案，未实现）

> 状态：设计提案。本文不描述当前已交付 API。当前行为仍以
> [`architecture.zh.md`](../architecture.zh.md)、[`user-guide.zh.md`](../user-guide.zh.md)
> 和通过的测试为准。

本文只定义目标模型、模块 owner、依赖方向和完成条件。实现顺序属于单独的
实施计划；历史名称和兼容策略不参与目标架构设计。

用户心智成本是本提案的硬约束：同一能力只有一个 canonical identity、规范名称和
推荐写法；少量 alias 只能是 parse-time 输入糖，不能成为并列公共概念。内部算法、
后端节点、wrapper 和兼容别名不能作为并列公共概念。普通应用只需学习
Text、Box、Component；Fragment、布局细节和底层包通过渐进披露进入。

## 0. 设计决策摘要

普通 ETAF 用户只学习 Text、Box、Component，以及下面的结构 form：

```elisp
"plain text"
(text PROPS "styled text")
(box PROPS CHILD...)
(row PROPS CHILD...)
(column PROPS CHILD...)
(flex PROPS CHILD...)
(grid PROPS CHILD...)
```

`row/column/flex/grid` 都只是 Box 的布局形式。用户属性分为 metadata、语义/事件、
视觉样式和 parent participation；采用语义一致的标准 CSS 名称、少量明确的
ETAF/Ebox 个性属性和少量 parse-time alias。用户不接触 Ebox/TP/Emacs backend。

独立 Ebox 用户通过 `ebox-build` 使用相同视觉 form 的 inert data syntax，但没有
Component、Fragment、expr、slot 或 lifecycle。

框架集成者只使用 typed Text/Box constructors、LayoutConfig、render 和 commit
边界；不重新拼 DSL，不重新执行 cascade，不生成 Emacs text properties。

内部执行只有四层：

```text
Author API
  → Canonical Model
  → Render Plan (Ebox geometry + TP paint + ETAF semantics)
  → Emacs Adapter commit
```

核心 owner 不变：ETAF Runtime 拥有 identity/lifecycle/reactivity；ECSS 拥有
selector/cascade/computed style；Ebox 拥有 measurement/geometry；TP 拥有 paint
priority/transaction；最终 adapter 才拥有 `face`、`display`、`keymap` 等 Emacs
text properties。

普通用户文档不出现 NormalizedView、PropertyDefinition、ProjectionPlan、node ID、
RangeAnchor 或 TP slot。框架 integration reference 才描述 typed constructors；
只有内部架构章节描述 facts、plans、patches 和 journals。

## 1. 最终模型

ETAF/Ebox 的表示链按职责分层：

```text
AuthorView
  ↓ parse / desugar / string normalization
NormalizedView = Text | Box | Fragment | ComponentCall
  ↓ ETAF Runtime resolves ComponentCall
Resolved candidate + source facts
  ↓ 当前 surface 只选择一个 style adapter
  ETAF Style Adapter | Ebox Standalone Style Adapter
  ↓ ECSS selector / cascade / inheritance（恰好一次）
Computed property facts + impact sets
  ├─ structure/geometry impact
  │    ↓ Fragment projection preserves RangeAnchors
  │  CanonicalEboxInput = Forest<TextNode | BoxNode> + RangeAnchors
  │    ↓ Ebox measure / layout
  │  LayoutPlan → GeometryPatch
  │
  └─ paint impact
       ↓ shared property projector
     TP ContributionPlan → PaintPatch

GeometryPatch and PaintPatch join the existing TP transaction
  ↓ Emacs adapter commit / rollback
Published generation
```

这些层不是相互竞争或重复 materialize 的树。每次 lowering 只消费上层已经保留的
identity、computed properties 和 child 顺序；同一事实不重复解析或推导。
LayoutPlan 与 ContributionPlan 是同一候选事务的独立派生产物；paint-only path 不
构造 CanonicalEboxInput 或运行 layout。两条路径在现有 transaction participant
汇合。plan 不拥有作者 identity，也不是 DSL 节点。

Canonical node 的非法状态必须不可表达：

```text
TextNode = {
  value: String,
  measurementProps,
  sourceHandle,
  eboxNodeId
}

BoxNode = {
  outer: inline | block,
  layout: Normal | RowConfig | ColumnConfig | FlexConfig | GridConfig,
  geometryProps,
  parentParticipationProps,
  children: [TextNode | BoxNode],
  sourceHandle,
  eboxNodeId
}
```

TextNode 没有 children/outer/layout；BoxNode 没有 content/value。participation 字段
存储在 BoxNode，但只有直接父 formatting context 可以验证和解释它。

`sourceHandle` 是来源层拥有的 opaque handle：ETAF 路径指向 Runtime
Text/Box/Range source，独立 Ebox DSL 路径指向 Ebox author source。`eboxNodeId` 只
标识 Ebox retained geometry node。Renderer/surface 保留二者映射；Ebox reconciliation
不得接管 Component、Fragment、Range 或 lifecycle identity。

用户需要理解的主要概念只有 `Text`、`Box` 和 `Component`。`Fragment` 是高级
结构语法；`Host` 是 Renderer 内部术语；`Ebox Node` 是后端对象，都不构成第二套
组件模型。

NormalizedView 的完整形状是：

```text
View = Text
     | Box
     | Fragment
     | ComponentCall
```

作者语法和规范化 View 不是同一层。ETAF 与 Ebox 的视觉作者语法共享：

```text
AuthorNode = String
           | TextForm
           | BoxForm
           | RowSugar
           | ColumnSugar
           | FlexSugar
           | GridSugar
```

`String` 规范化为 Text；五个 Box form 规范化为带对应 typed Layout 的 Box。form
名称不进入
Runtime identity、diff、style、layout 或 paint 协议。ETAF 另外增加 Fragment、
ComponentCall、`expr` 和 `slot`；Ebox DSL 不拥有这些语义。

两层作者语法共享结构词汇和规范化结果，不要求共享求值环境：ETAF property 是
Elisp expression；`.ebox` DSL 是数据 form。quote 和 expression 的差异只属于
parser，不产生两套 canonical schema。

Flex/Grid item 是 material child Box 在父 formatting context 中获得的角色，不是
另一种 View 或父子边类型。participation 属性存储在 child Box，合法性、计算和
dirty propagation 由直接父 Flex/Grid Box 拥有。

`expr` 和 `slot` 是计算/投影机制，不是视觉节点。目标公共 View 不接受原始 Ebox
节点；缺失的渲染能力必须先形成有类型、有 identity/impact 契约的 View/Ebox 能力，
不能通过 opaque escape 绕过框架语义。

## 2. Text、Box 与 Fragment

### 2.1 Text

`Text` 是文本叶子，负责：

- 恰好一个求值后为字符串的 payload；
- 字体、前景/背景、下划线等文本 paint；
- 文字测量、换行和文本对齐的输入；
- 可选 identity、语义和事件属性。

`Text` 固定为 inline，不公开 `:outer`。它没有 View children，不能嵌套 Text，
也不能建立任何布局上下文。多个 styled runs 是相邻的多个 Text，而不是一棵 Text
子树。需要 block participation、padding、border、尺寸或子布局时，使用外层 Box。

两个作者入口的 Text grammar 精确区分求值能力：

```text
ETAF TextForm = (text TEXT-PROP VALUE)
VALUE         = String | (expr :value Expr<String>)

Ebox TextForm = (text TEXT-PROP String)
```

所有属性键值对必须位于唯一 payload 之前。零个、多个、嵌套 Text 或非字符串
payload 都报错。裸字符串只是无属性 Text 的语法糖，在所有位置只有这一种解释。

### 2.2 Box 的两个正交轴

`Box` 同时拥有一个外部参与方式和一个内部布局方式：

```text
:outer  = inline | block
layout = Normal | RowConfig | ColumnConfig | FlexConfig | GridConfig
```

- `:outer`：这个 Box 如何参与父级的 `normal` 布局；
- `layout` variant：这个 Box 如何排列自己的子节点。

默认值是：

```text
Box  :outer block  :layout Normal
Text :fixed inline
```

作者层不公开 `:layout` 属性，而由 form 名唯一选择 layout：

```elisp
(box ...)                 ; Normal
(row ...)                 ; RowConfig
(column ...)              ; ColumnConfig
(flex ...)                ; FlexConfig
(grid ...)                ; GridConfig
```

因此 inline-flex 写为 `(flex :outer 'inline ...)`，不是新节点类型。`:outer` 是所有
Box author form 的公共属性；layout config 由对应 form 的闭集属性构造。需要动态
切换 layout 时，由 `expr` 选择不同 View form，而不是把 `:layout` 当普通动态样式。
Canonical Box 使用 typed Layout variant；不公开 `:inner` 或 Ebox
`(:display (block flow))` 后端表示。

### 2.3 normal 的明确范围

`normal` 是一个真实但刻意收敛的布局上下文：

- 连续的 inline `Text` 或 inline `Box` 进入同一行流并按可用宽度换行；
- block `Box` 从新行开始并形成独立块；
- block 前后的 inline 行会在块边界结束；
- 子节点顺序保持稳定。

目标不实现完整浏览器 CSS：没有 float、table、absolute/fixed positioning、
run-in、list-item 或任意匿名盒规则。Ebox 可以把 `normal` 映射为内部 flow
算法，但 `flow` 不是 ETAF 公共词汇。

当父级 Layout 是 Row/Column/Flex/Grid 时，父算法直接拥有子项
位置；子项的 `:outer` 不改变排列顺序。`:outer` 只决定节点进入 `normal` 父级时
是 inline 还是 block。

### 2.4 其他布局模式

| 模式 | 职责 |
| --- | --- |
| `row` | 简单水平顺序布局，不执行 Flex 空间分配 |
| `column` | 简单垂直顺序布局，不执行 Flex 空间分配 |
| `flex` | Flex sizing、direction、wrap、alignment 和 gap |
| `grid` | 二维轨道、放置、跨度和 gap |

这些都是 `Box` 的 Layout variant，不是 Component，也不注册 `row`、`column`、
`flex` 或 `grid` 的第二套 Runtime 节点名称。作者 form 的规范化映射唯一：

```text
box    → Box(layout = Normal)
row    → Box(layout = RowConfig)
column → Box(layout = ColumnConfig)
flex   → Box(layout = FlexConfig)
grid   → Box(layout = GridConfig)
```

ETAF 与 Ebox 共享这五个 Box author form。所谓“layout form”只表示输入拼写和
对应 config schema，不表示保留 Host、node type 或运行时分派。

上表是唯一规范性 lowering 表。Ebox 拥有 canonical Layout variant 和 config
schema；ETAF parser 只处理自己的 Elisp 求值并选择同名 variant，不复制取值规则。
两个入口必须通过跨接口 conformance 测试证明同一结构产生相同 canonical shape、
computed defaults 和错误。

### 2.5 Ebox DSL 的基础节点与语法糖

ETAF View 和 Ebox DSL 是两层不同接口，但共享同一个视觉作者语法：Text 是文本
叶子，Box 是结构/几何容器。Ebox DSL 的完整视觉语法是：

```elisp
"plain text"
(text TEXT-PROPS "styled text")
(box BOX-PROPS CHILD...)
(row BOX-PROPS CHILD...)
(column BOX-PROPS CHILD...)
(flex BOX-PROPS CHILD...)
(grid BOX-PROPS CHILD...)
```

字符串始终规范化为 Text；`text` 只接受文本内容和 Text 属性；`box` 只接受
children 和 Box 属性。Ebox DSL 不接受 `:content`，因此不存在“字符串有时是
Box content、有时又是 child”的双重解释。空 `(box :width ... :height ...)` 是
合法的空几何容器。

`ebox-build` 是作者 DSL 的 parse/desugar 入口。程序化公共端口使用两个 typed
constructor：`ebox-text-create` 构造 TextNode，`ebox-box-create` 接收一个 typed
Layout variant 并构造 BoxNode。constructor 不接受作者 form 或扁平的跨 layout
属性袋；ETAF Renderer 直接调用它们，不重新拼 DSL。

`:class`、`:id` 和作者 `:key` 都属于来源层，但 `:key` 是 identity fact，不能进入
visual source。独立 Ebox DSL 与 ETAF View 都产生同构的 StyleSourceFact；每个 surface
只能选择一个 adapter 调用 ECSS。ETAF surface 由 ETAF Style Adapter 拥有 Component
scope 的装配和 stylesheet 生命周期，独立 Ebox surface 由 Ebox Standalone Style
Adapter 拥有；两者复用同一个 ECSS 实现、同一个 Ebox property registry/projector，
不会在同一 surface 上运行两次 cascade。`:id` 的同一 parsed fact 可以并行投影到
ETAF semantic metadata，但不能因此重新解析或重新 cascade。

typed Text/Box constructor 只接收 opaque `sourceHandle` 与已经计算完成的 owned facts，
不接收或保存 `:class/:id/:key`；Ebox measurement/layout core 也不读取 source metadata。
StyleEnvironment 属于当前 surface/runtime，不能实现为 process-global stylesheet 或
metadata table。

目标公共端口不保留无 kind 的 `(ebox-create :content ...)`。若运行时为了性能把
Text payload 融合进相邻 Box 存储，该优化只能发生在 canonical Text identity、
range 和 impact 已建立之后，并且必须可逆地保留这些事实；私有存储编码不能成为
作者或程序化公共 API。Range descriptor 同样是增量后端协议，不是 DSL 节点。

五个 Box author form 必须在 DSL 边界立即、无状态地构造对应 typed Layout variant，
不能建立不同的 node type、identity、缓存、验证或渲染分支。任何作者 form 都拒绝
`:layout`；layout-specific 属性只由对应 form 接受。

当前 DSL 的其他 tag 必须明确分类，不能与基础节点并列：

| 当前 tag | 分类 | 目标表达 |
| --- | --- | --- |
| `ebox` | `box` 的兼容别名 | 删除，统一写 `box` |
| `spacer` | 空 Box 便捷糖 | 删除，使用无 children 的 `box` |
| `row` | Box layout form | 保留并构造 RowConfig |
| `column` | Box layout form | 保留并构造 ColumnConfig |
| `flex` | Box layout form | 保留并构造 FlexConfig |
| `grid` | Box layout form | 保留并构造 GridConfig |
| `item` | Flex wrapper/糖 | 删除；participation 属性直接写在 child Box |
| `grid-item` | Grid wrapper/糖 | 删除；placement 属性直接写在 child Box |

Flex/Grid 直接 child 自动取得 item 角色；item 不是节点类型。需要非默认参与方式时，
唯一推荐路径是显式 child Box：

```elisp
(flex
  (box :flex-grow 1 "Flexible")
  "Fixed")

(grid
  (box :grid-column '(1 :span 2) "Header")
  (box "Body"))
```

participation/placement 属性存储在 child Box，但只由直接父 Flex/Grid 验证和消费；
出现在错误父级时必须报错。属性变化使父布局 owner 进入 geometry path，但不改变
child Component/Text 的 identity、lifecycle 或 paint ownership。直接 Text 使用
默认 item 参数；需要非默认参数时显式包 Box。

目标 Ebox DSL 删除 `ebox`、`spacer`、`item` 和 `grid-item`，保留 Text、Box 与
四个布局糖。布局算法仍由 Ebox 分别实现，但 canonical 视觉节点只保留
TextNode/BoxNode；作者语法、canonical tree、layout plan 和运行时存储是不同层次。

### 2.6 Fragment

`Fragment` 是无视觉 wrapper 的结构 Range：

- 可以承载零个、一个或多个兄弟 View；
- 不产生 Box、尺寸、背景或布局上下文；
- Runtime 可以为其保留稳定 Range identity 并局部替换；
- 只接受子节点和可选稳定 `:key`，不接受视觉/事件属性。

Fragment resolution 不把 Range identity 丢掉。它把 material children 按顺序 splice
进 CanonicalEboxInput forest，同时产生 `{range-id, before, after}` RangeAnchor；空
Fragment 仍有可插入锚点，根 Fragment 可以对应零个或多个 forest roots。Range
identity 由 ETAF Runtime 拥有；Ebox 只消费 descriptor 来形成局部 geometry patch，
RangeAnchor 不是视觉 node，也不参与测量。

Component call 本身没有 `:outer` 或 Layout。它的根 Text/Box 决定如何参与父级
布局；返回 Fragment 的透明 Component 可以产生多个兄弟节点，因此不存在单一的
“Component 外部盒子”。

### 2.7 字符串、content 与空 Box

Box 子节点中的字符串规范化为 Text：

```elisp
(box "this is text")
```

等价于：

```elisp
(box (text "this is text"))
```

ETAF 与 Ebox 作者 DSL 都不提供 `(box :content "...")`。`:content` 只属于
现有未类型化运行时存储，目标公共程序化端口也不保留它。把 `:content` 暴露给
作者 DSL 或 canonical constructor 都会重新制造 content 与 Text children 两套模型。

ETAF 也不提供 `spacer` 类型。没有子节点的 Box 就是空 Box。

## 3. 属性契约

属性是闭集，并按 owner 验证；未知属性和不适用组合必须报错。

| Owner | 属性类别 | 代表属性 |
| --- | --- | --- |
| ETAF Runtime metadata | identity/语义/事件/Behavior | `:key`、`:ref`、`:role`、`:aria-*`、`:on-*`、`:use` |
| ECSS author style source | selector/inline declarations | `:class`、`:id`、style declarations |
| Ebox TextNode | canonical 文本测量 | font metrics、wrap policy、intrinsic constraints |
| Ebox BoxNode | 外部/内部布局 | `:outer`、typed Layout variant |
| Ebox BoxNode | 几何 | width/height/min/max、margin、padding、border widths、box sizing、overflow |
| Flex container | 布局 | `:flex-direction`、`:flex-wrap`、`:justify-content`、`:align-items`、`:align-content`、`:gap` |
| Flex child Box | 父级参与 | `:order`、`:flex-grow`、`:flex-shrink`、`:flex-basis`、`:align-self` |
| Grid container | 布局 | track templates、auto flow、gap、item/content alignment |
| Grid child Box | 父级参与 | `:grid-row`、`:grid-column`、row/column span、self alignment |
| TP contribution | paint | color/background、underline/overline、border paint、visibility paint |

规则：

- impact 是集合，不是互斥枚举；
- `:key` 属于 identity，不是视觉属性；
- `:class` 只进入 ECSS selector；`:id` 是一个 author input，可同时投影到 ECSS
  selector 和语义 metadata，但不能由两个模块分别定义含义；
- color/background 等不改变 metrics 的贡献属于 paint-only；
- font family/size/weight 等 metric 属性属于 geometry + paint；
- padding、border width 等属于 geometry + paint；
- `:outer`、Layout variant 属于 structure + geometry；
- Flex/Grid participation 存储在 child Box，但变化时只使对应父布局 owner geometry dirty；
- ECSS cascade 输出必须保留上述 impact set；
- ETAF/Ebox candidate normalization 只解析一次 author plist 并产生 canonical
  declarations/metadata facts；ECSS 只计算一次 computed facts；projection 再按
  owner/impact 交给 Runtime、Ebox 和 TP，各 owner 不重新解析原 plist；
- border/font 等 multi-impact fact 可以同时投影 geometry 与 paint 字段，但 computed
  value 只 materialize 一次，不在 Ebox node 中复制 paint-only 状态；
- TP 只消费已经解析的 paint contribution，不判断布局合法性；
- 结构属性变化必须事务性重建对应布局上下文，不能走 paint-only 快速路径。

验证分成两个确定阶段：

1. normalization 做 form-local schema 校验。`box` 只接受 Normal/Common Box 属性；
   `flex` 才接受 Flex container config；`grid` 才接受 Grid container config；其他
   layout-specific 属性立即报错。
2. Component/Fragment resolution 与 ECSS cascade 完成后，Ebox 在 candidate final
   tree 上做 parent-context 校验。Flex participation（grow/shrink/basis/order/self
   alignment）只允许在直接父 Flex 的 child Box，Grid placement/self alignment
   只允许在直接父 Grid 的 child Box；root 或错误父级报错。

同一个 Box 可以内部建立一种 Layout、外部参与另一种父 Layout，例如 Grid 下的
`(flex :grid-column ... )`；这是两个正交字段，不是属性混用。动态事务同时改变父
Layout 和 child participation 时只验证最终 candidate，任何失败保留上一代。与
浏览器对不适用 CSS 属性常采取 no-effect 不同，本框架不静默忽略无效组合。

### 3.1 作者 form 的规范属性组合

下面的组合是规范性公共 schema；shorthand 在进入 canonical registry 时立即展开，
不产生第二套 owner 或 impact 规则。

```text
SharedSourceMetadata = :key :class :id
ETAFOnlyMetadata     = :ref :role :aria-* :on-* :use
ETAFSourceMetadata   = SharedSourceMetadata + ETAFOnlyMetadata
EboxSourceMetadata   = SharedSourceMetadata

TextStyle =
  :font-family :font-size :font-weight :font-style
  :color :background-color
  :text-decoration-line :text-decoration-color :text-decoration-style

BoxFrame =
  :outer
  :width/:min-width/:max-width
  :height/:min-height/:max-height
  :box-sizing
  margin/padding shorthands and logical/physical longhands
  border shorthands and width/style/color longhands
  :wrap-mode (word | char | kp | none)
  :overflow :visibility
  inherited standard text style source such as font/color
  non-inherited surface source such as :background-color

NormalConfig = :text-align

RowConfig = :item-gap :cross-align
ColumnConfig = :item-gap :cross-align

FlexConfig =
  :flex-direction :flex-wrap :flex-flow
  :justify-content :align-items :align-content
  :gap :row-gap :column-gap

GridConfig =
  :grid-template-columns :grid-template-rows
  :grid-auto-columns :grid-auto-rows :grid-auto-flow
  :justify-items :align-items :justify-content :align-content
  :gap :row-gap :column-gap

FlexParticipation =
  :order :flex :flex-grow :flex-shrink :flex-basis :align-self

GridParticipation =
  :order :grid-column :grid-row :align-self :justify-self
```

六个视觉 form 只通过组合产生：

```text
text   = SurfaceSourceMetadata + TextStyle + one String
box    = SurfaceSourceMetadata + BoxFrame + NormalConfig + ParentParticipation + children
row    = SurfaceSourceMetadata + BoxFrame + RowConfig + ParentParticipation + children
column = SurfaceSourceMetadata + BoxFrame + ColumnConfig + ParentParticipation + children
flex   = SurfaceSourceMetadata + BoxFrame + FlexConfig + ParentParticipation + children
grid   = SurfaceSourceMetadata + BoxFrame + GridConfig + ParentParticipation + children
```

`SurfaceSourceMetadata` 在 ETAF surface 取 ETAFSourceMetadata，在独立 Ebox surface
取 EboxSourceMetadata。`:item-gap` 与 `:cross-align` 是 Ebox Row/Column extension，
不是 CSS `gap`/`align-items`；前者沿主轴插入固定间距，后者值为
`start|center|end|stretch` 并控制 cross axis。Flex/Grid 的 `:gap` 保持标准 CSS
shorthand 语义，同时展开 row-gap 和 column-gap。

`ParentParticipation` 由最终直接父级选择为 Default、FlexParticipation 或
GridParticipation；同一个 candidate 不能同时携带互斥的 Flex-only 与 Grid-only
字段。Text 不接受 BoxFrame、LayoutConfig 或 Participation；需要这些能力时显式包
Box。Ebox DSL 不接受 ETAFOnlyMetadata。

### 3.2 命名层与后端投影

作者层名称分为 CSS、ETAF、Ebox 和 optional Emacs-adapter 四个 namespace。只有
适用对象、值 grammar、默认/继承、impact 和可观察行为与 CSS 一致或是明确子集时，
才采用标准 CSS 名称；概念相近但语义不同的能力保留精确的 ETAF/Ebox 名称，不能
为了熟悉感使用错误的标准名称。

目标公共 API 对历史/后端名称分类处理：

```text
:bgcolor          → exact alias of :background-color
:font-height      → removed from core; optional Emacs adapter source only
:font-slant       → exact alias of :font-style with identical value grammar
:border-top-p     → retained Ebox boolean shorthand for top width/style
:grid-column-span → Ebox positive-integer shorthand for :grid-column (span N)
:grid-row-span    → Ebox positive-integer shorthand for :grid-row (span N)
:face             → not a core canonical property
:display          → private Ebox/Emacs lowering field
:content          → private legacy runtime storage field
```

`:wrap-mode` 不与 CSS `white-space`、`overflow-wrap`、`word-break` 或 `line-break`
等价，因此保留为 Ebox namespace 的唯一公共名称，值限定为 `word`、`char`、`kp`、
`none`。`char` 在实现中按完整字素簇断行，避免拆开组合字符；`kp` 使用
Knuth–Plass 段落排版。如果未来实现完整且语义一致的 CSS 属性，应以一次明确迁移替换它，而不是
长期同时保留两套名称。

`:wrap-mode` 只由 Box 作者声明，表示该 Box 内容的软换行策略；Text form 不接受
它。计算阶段把 Box 的策略继承为 Text 测量输入，Text 负责执行断行，但不拥有第二
条作者配置路径。`none` 只禁止自动软换行，显式换行仍保留；排版后的越界由独立的
`:overflow` 决定，不能用 wrap 语义暗示裁剪或滚动。

标准 CSS shorthand 只有一套展开规则，例如 `:margin`、`:padding`、`:border`、
`:gap`、`:flex`、`:flex-flow`、`:grid-column` 和 `:grid-row`。canonical registry 使用
namespaced ID（例如 `ebox/font-size`、`ebox/background-color`）；作者只写 keyword，
不会看到内部 ID。

每个定义显式记录命名领域与标准关系：

```text
PropertyDefinition {
  authorName
  canonicalId
  aliases
  namespace: css | etaf | ebox | emacs-adapter
  standardReference
  semanticSubset
  acceptedContexts
  valueGrammar
  initial
  inherits
  impactSet
  owner
  projections
}
```

alias 必须与 canonical property 的 context、value grammar、owner、impact 和 projection
完全相同，且不能转换 value；需要一对多展开的是 shorthand，需要解析后端复合值的
是 adapter source。alias 在 parse 入口立即解析为 canonicalId，computed style、
cache、diff、Ebox、TP 和 Rust 都不再看到它。PropertyDefinition 注册时拒绝
canonical/alias collision；同一声明同时写 canonical 与 alias（或重复 alias）直接
报错，不采用隐式 last-wins。source spelling 只可保存在 diagnostics provenance。

属性参考把 alias 列在 canonical property 下，例如：

```text
background-color
  Canonical: :background-color
  Aliases:   :bgcolor
```

不把 `bgcolor` 单独列成第二个功能。第一阶段 alias 由 owning package 的 schema
注册，不开放 process-global 用户 alias；上层包若需要 alias，必须限制在自己的
schema scope，不能污染全局 Ebox visual property domain。

`:border-top-p` 不是 alias，而是保留的 Ebox boolean shorthand：`t` 展开为
`:border-top-width 1` + `:border-top-style solid`，`nil` 展开为 width 0 + style none；
颜色由 `:border-top-color`/`:border-color`/默认前景提供。需要完整控制时使用标准
`:border-top` 或 longhands。同一声明混写 `:border-top-p` 与其 width/style 输出必须
报错；不同 cascade source 仍按 ECSS 正常覆盖。

`:grid-column-span`/`:grid-row-span` 同样不是 alias；它们只接受正整数并分别展开
为对应 Grid shorthand 的 `span N` value，与 `:grid-column`/`:grid-row` 在同一声明
混写时报错。`:font-slant` 只有在值 grammar 与 `:font-style` 完全相同时才作为 exact
alias；`:font-height` 的 Emacs face-height 语义不冒充 CSS `font-size`。

Emacs text property 名称 `face`、`display`、`keymap`、`mouse-face`、`help-echo`、
`invisible`、`line-prefix`、`wrap-prefix` 和 sticky properties 只属于最终 adapter。
Ebox core、ETAF Runtime、ECSS 和 Rust 都不直接生成或消费这些名字。若需要复用
named Emacs face，只能由可选 adapter 提供显式 `:emacs-face` source input，立即
解析为标准 font/paint facts 并计算 impact；原始 face symbol 不进入 canonical IR。

一次典型投影是：

```text
:font-weight bold
  → ebox/font-weight, impact {geometry, paint}
  → Ebox Text measurement weight
  + TP face-weight contribution
  → Emacs adapter emits face :weight

:width 120
  → ebox/width, impact {geometry}
  → Ebox GeometryPatch
  → Emacs adapter may emit display space width
```

### 3.3 统一属性事实与投影层

统一层不是 `author keyword → Emacs text property` 的直接字典。一项属性可能同时
影响测量与 paint，多项属性也可能合并为一个 Emacs `face`；布局结果产生的
`display` 又可能没有直接作者属性。内部阶段必须区分：

```text
CanonicalDeclaration {
  propertyId
  specifiedValue
  sourceSpelling
  sourceProvenance
}

SelectorSubjectFact {
  classes
  id
  sourceHandle
  sourceProvenance
}

StyleSourceFact {
  sourceHandle
  selectorSubjectFact
  declarations
  scopeHandle
  provenance
}

StyleEnvironment {
  stylesheet
  schemaSet
  scopeIndex
  computedCache
}

RuntimeMetadataFact {
  propertyId
  value
  sourceHandle
}

ComputedPropertyFact {
  propertyId
  computedValue
  winningProvenance
  impactSet
  sourceHandle
}

ProjectionPlan {
  metadataFacts
  measurementFacts
  geometryFacts
  paintFacts
}
```

normalization 对 author input 只解析一次，并同时产生 immutable
CanonicalDeclaration、SelectorSubjectFact 和 RuntimeMetadataFact。`:class/:id` 不
进入 CSS declarations；SelectorSubjectFact 在 cascade 前直接构造 ECSS subject。
`:id` 的同一个 parsed source value 由 selector 与 semantic projection 共享，不各自
重读 plist。ETAF Style Adapter 与 Ebox Standalone Style Adapter 产生同构
StyleSourceFact，但一个 surface 只由其中一个 adapter 组装 StyleEnvironment；ECSS
cascade/inheritance 接收 SelectorSubjectFact + declarations，产生
immutable ComputedPropertyFact。`:key`、`:ref`、`:on-*` 等不进入 ECSS，只进入
RuntimeMetadataFact。这里的“一次 materialize”指每个阶段只生成一次自己的
immutable artifact，不是让同一对象跨阶段变异。

纯 property projector 在 cascade 后消费 computed style facts 与 metadata facts，按
PropertyDefinition 的 owner/impact/projections 生成 ProjectionPlan，各 consumer
引用同一 fact，不重新解析或复制 computed value。TP paint projector 是唯一把
paintFacts 转为 ContributionPlan 的模块；ETAF semantic projector 把 metadataFacts
转为 Runtime/SemanticPlan。

Registry 不是 process-global 万能表。每个 owning package 提供 immutable
SchemaRegistry，并遵守同一个 schema protocol；一个 surface 组合成 SurfaceSchemaSet：

```text
ETAF SurfaceSchemaSet = ETAF registry + Ebox registry
Ebox SurfaceSchemaSet = Ebox registry
ETAF + Emacs adapter  = ETAF registry + Ebox registry + adapter registry
```

每个 canonicalId 只有一个 owning definition；canonical/alias collision 在
SchemaSet composition 时检查。这样既没有反向依赖，也没有重复事实源。

逻辑模块保持小而完整：

- package property schema：package-scoped PropertyDefinition registry；
- SurfaceSchemaSet：无冲突组合各 package registry；
- property normalizer：author name、shorthand、value grammar；
- property projector：computed/metadata facts → backend-neutral ProjectionPlan；
- Ebox layout projector：measurement/geometry facts → LayoutPlan；
- TP paint projector：paint facts → ContributionPlan；
- ETAF semantic projector：metadata facts → Runtime/SemanticPlan；
- Emacs adapter：GeometryPatch + PaintPatch + SemanticPlan → text-property operations。

因此 Ebox canonical node 不保存 paint-only 字段，TP 不保存 geometry，Emacs adapter
不重新解释 CSS，Rust 只接收 canonical facts/plans 而不接收 `face`、`display` 或
Elisp plist。调试与性能工具必须能显示完整链路，例如：

```text
:font-weight
→ ebox/font-weight
→ {geometry, paint}
→ measurement/font-weight + paint/font-weight
→ face :weight
```

## 4. 模块 owner

### 4.1 ETAF Core

`etaf-view`：

- 定义并规范化 Text、Box、Fragment 和 ComponentCall；
- 将字符串规范化为 Text；
- 将 `row`、`column`、`flex`、`grid` 作者糖规范化为 Box；
- 验证属性闭集、slot、`:key` 和表达式边界；
- 不测量、不布局、不写 buffer。

`etaf-component`：

- 定义 Component props、`:view`、`:setup`、`:styles`；
- 不调度 Runtime，不调用 Ebox。

`etaf-runtime`：

- 拥有 Component/Fragment/Range identity、响应式依赖、Context、Theme、Action、
  Behavior、Data、Resource 和 lifecycle；
- 拥有 candidate generation、事务、提交授权、回滚和释放；
- 决定变化影响哪个 Component、Range、结构属性或 paint contribution；
- 不计算像素和布局。

`etaf-renderer`：

- 是唯一 ETAF → Ebox 的 lowering adapter；
- 消费 ETAF Style Adapter 已产生的 computed/projection facts，把 structure/geometry
  projection 转换为 CanonicalEboxInput forest、RangeAnchors 与 typed Ebox facts；
- 不重新运行 selector/cascade，也不复制第二份 computed visual properties；
- 不执行 Component lifecycle，不访问 Ebox 私有状态。

`etaf-style`（逻辑模块，可与发行包同仓）：

- 拥有 Component style scope 的装配、每个 Runtime/Surface 独立的 StyleEnvironment
  及其生命周期；
- 使用 Ebox 公开的 property registry/projector，直接调用 ECSS 完成 ETAF surface
  唯一一次 cascade；
- 不测量、不布局、不写 buffer，也不拥有 Runtime commit authority。

`etaf-theme-tp`：

- 只是可选的 TP palette → ETAF semantic Theme token/value adapter；
- 不生成 ContributionPlan，不参与 selector/cascade，也不拥有 paint 提交权限。

Theme 的语义 token 和继承属于 ETAF Context。TP 不拥有“暗色主题”等业务意义。

### 4.2 Ebox

Ebox 拥有：

- Ebox DSL 的 String/Text/Box 规范化和布局糖展开；
- Ebox canonical property registry 及 computed fact → geometry/paint fact 的纯 projector；
- 仅供独立 Ebox surface 使用的 Standalone Style Adapter；该 adapter 直接调用 ECSS，
  但 ETAF typed path 必须绕过它，不能运行第二次 cascade；
- child Box participation 的上下文验证、父布局消费和 dirty propagation；
- typed TextNode/BoxNode constructor 及 canonical 属性 schema；
- Text 测量、换行和行布局；
- `normal`、`row`、`column`、`flex`、`grid` 几何算法；
- width/height、box model、overflow、scroll、viewport；
- 稳定 Ebox node identity、geometry snapshot 和结构 patch plan。

Ebox 不理解 Component、slot、Context、Action、Behavior、Data 或 Resource，也不
决定 paint contribution 的优先级。

ETAF Style Adapter 与 Ebox Standalone Style Adapter 共用同一个纯 property projector；
前者处理 ETAF Theme/Component/state/inline provenance，后者处理独立 Ebox inline/
stylesheet provenance。两者不在同一 surface 并存，不把 paint-only 属性塞回
CanonicalEboxInput，也不拥有 TP priority、journal 或 commit authority。

`ebox-build` 独占作者 form 的 parse/desugar；`ebox-text-create` 与
`ebox-box-create` 接收已经求值的 canonical 参数，只验证 typed node invariant。
三者最终消费同一个 canonical property schema 并进入同一条布局实现。ETAF
Renderer 直接调用 typed programmatic port，不能重新拼 DSL 再触发一次解析。
现有无 kind 的 `ebox-create :content` 不属于目标公共端口。

逻辑边界：

```text
ebox-core   纯测量、布局、快照和结构 patch
ebox-emacs  字体/窗口能力、buffer 位置和结构提交
```

这不要求立即拆成两个发行包，但纯布局和 Emacs 副作用必须能独立测试。

CanonicalEboxInput forest 经测量产生 LayoutPlan；plan 只包含本次候选所需的测量结果、
坐标、尺寸、布局 owner 和 geometry delta。它不新增作者可见 node type，不拥有
Component/Text/Box identity，提交或回滚结束后可被保留为下一次增量输入或释放。

### 4.3 ECSS

ECSS 拥有 selector、cascade、继承和 computed properties。输出必须携带属性的
structure/geometry/paint impact；ECSS 不执行布局，也不写 buffer。

### 4.4 TP 与提交边界

TP 拥有：

- Theme、Component style、state、inline 等 paint contribution 的优先级；
- paint operation 合并；
- Emacs text property journal、apply 和 rollback。

一次更新的权限顺序固定为：

```text
ETAF Runtime 创建 candidate 并拥有提交授权
    ↓
Ebox candidate stage 结构/几何 patch
    ↓
Ebox surface 把 rollback-capable participant 加入现有 TP transaction
    ↓
TP precommit paint；Ebox commit 发布 Emacs surface
    ↓
全部成功后 ETAF Runtime 提升 generation
任一步失败则沿现有 Ebox/TP/Runtime journal 回滚
```

Ebox 不拥有 TP paint 优先级；TP 不拥有节点布局；两者都不能自行提升 Runtime
generation。目标不新增第二个跨包 coordinator；现有 transaction participant 就是
Ebox surface 与 TP/Emacs 提交对齐的唯一机制。

### 4.5 上层包

| 包 | 拥有 | 不拥有 |
| --- | --- | --- |
| `etaf-ui` | Button、Checkbox、Label、Panel、DataGrid 等普通 Component | 第二套 Widget Runtime、布局引擎 |
| `etaf-sqlite` | SQLite Data Source、查询、mutation、事务和 dispose | Data Controller、View、UI |
| `etaf-performance` | 应用无关 operation/stage、环境、统计和报告 | 示例语义、布局规则、调度权限 |
| `ebox-playground` | Ebox 公共布局 API 示例与验证 | ETAF |
| `etaf-playground` | ETAF/UI/SQLite 组合示例、加载命令和状态展示 | Core 语法、Runtime、性能协议 |

`etaf-performance` 是独立可选包。ETAF、Ebox、TP 和 SQLite 不依赖它；它只通过
公开边界观察和关联阶段。

Playground 的 `.etaf` manifest 属于 Playground。未来通用 compiler 若存在，必须
降低到同一套 View/Component 契约，不得创建第二套 Runtime。

### 4.6 按使用者分层的公共面

- 普通 ETAF 用户只使用 `etaf-view`、Component、Text/Box form、ETAF metadata/
  events、canonical CSS-aligned properties，以及明确列出的 ETAF/Ebox extensions
  （如 `:outer`、`:wrap-mode`）和 parse-time aliases；不调用 Ebox/TP/Emacs adapter。
- 独立 Ebox 用户通过 `ebox-build` 使用同一视觉结构词汇的 inert data form；不拥有
  Component、slot、expr 或 lifecycle。
- 框架集成者使用 `ebox-text-create`、`ebox-box-create`、typed LayoutConfig、
  RangeAnchor 和 TP contribution contract；不重新拼 DSL、不传 shorthand、不运行
  第二次 cascade。typed constructor 只接收 opaque `sourceHandle`，不接收来源层
  `:class/:id/:key`。
- optional Emacs adapter 是显式 opt-in 的独立 schema namespace；只有加载 adapter
  的 surface 才接受 `:emacs-face`，否则 normalization 精确报未知 namespace/property。
- `ebox--*`、`etaf--*`、`tp--*`、`:ebox-type`、`:node-id`、`:region-id`、Emacs
  text properties 和 runtime storage fields 全部私有。

用户指南只描述第一层；Ebox DSL 指南描述第二层；integration reference 描述第三层；
架构文档才描述 canonical IR、identity owner、impact projection 和 commit protocol。

## 5. 依赖方向

```text
etaf-ui ─────────────▶ ETAF Core ─────────────▶ Ebox public port
etaf-sqlite ─────────▶ ETAF Data contract
etaf-playground ─────▶ ETAF + optional UI/SQLite
ebox-playground ─────▶ Ebox only
etaf-performance ────▶ public observation boundaries only

ETAF Style Adapter ──▶ ECSS + Ebox property registry/projector
Ebox Standalone Style Adapter ─▶ ECSS + same registry/projector
ETAF Renderer ───────▶ Ebox typed core port
ETAF Runtime  ───────▶ Ebox/TP transaction participants
etaf-theme-tp ───────▶ ETAF semantic Theme values only
Ebox surface ────────▶ TP contribution + transaction participant
```

禁止反向依赖：Ebox 不依赖 ETAF；TP 不解析 View；ECSS 不写 buffer；UI 不调用
Ebox 私有函数；SQLite 不知道 UI；Playground 不向 Core 注入协议。

## 6. Rust 与 Elisp

模块边界先于实现语言。只有接口和等价性测试冻结后，确定性计算才迁移到 Rust：

```text
Rust 候选：
  规范化 View 的验证与结构 diff（只处理 opaque stable IDs）
  ECSS cascade
  Text 测量输入处理与 Ebox 布局
  geometry/paint patch 的纯数据计算

Elisp / Emacs：
  执行用户 Component、ref、Context、Action、Data、Resource、lifecycle
  数据库和外部 I/O
  Emacs 事件、字体/窗口能力和最终提交
```

Component identity、依赖所有权、TP 优先级和 generation authority 不因 Rust 化而
转移。Rust 最多计算无副作用的候选 paint operations；TP 继续拥有 contribution
slot、优先级、journal 和 commit/rollback。Elisp 不重复 Rust 已经完成的 diff、
cascade、布局或文字扫描。

## 7. 正确性与性能不变量

- 同一事务中的 View、computed properties、geometry snapshot 和 paint contribution
  各 materialize 一次；
- Text 的 paint-only contribution 改变不执行无关 Component，也不运行布局；
- `:outer`、Layout variant 或几何改变只运行受影响的布局 owner；
- Fragment/slot/list 变化只替换对应 Range；
- Ebox/TP/Emacs 任一 participant 失败时保留上一代已提交状态；
- resize 使用当前窗口事实立即重排，不以隐藏 debounce 改变交互语义；
- 性能记录器不改变被测路径。

最终门禁必须覆盖：

- Text/Box/Fragment 结构等价；
- package registries 组合 SurfaceSchemaSet 时拒绝 canonical/alias collision；
- exact alias 在 normalization 后消失，shorthand 唯一展开且与 owned outputs 混写报错；
- optional adapter namespace 只有显式 opt-in surface 接受，未加载时精确报错；
- CanonicalDeclaration、SelectorSubjectFact、RuntimeMetadataFact 和
  ComputedPropertyFact 分阶段 immutable，selector subject 在 cascade 前只生成一次；
- ProjectionPlan 只含 paintFacts，只有 TP projector 能产生 ContributionPlan；
- Row/Column 只接受 `:item-gap/:cross-align` extension，不借用 CSS
  `:gap/:align-items` 的不同语义；
- geometry+paint 等 multi-impact computed value 只 materialize 一次并被两路引用；
- 字符串只规范化为 Text，两个作者 DSL 都拒绝 `box :content`；
- Text 固定 inline 且恰好一个字符串 payload；嵌套/空/多 payload 均报错；
- ETAF/Ebox 五个 Box form 的 canonical shape、defaults 和错误跨接口一致；
- 五个 Box author form 产生唯一对应 Layout，任何作者 `:layout` 均报错；
- Flex/Grid participation 只允许在匹配父级的 child Box；错误上下文精确报错；
- participation 变化只运行父布局，不重建 child identity/lifecycle；
- typed Text/Box constructors 拒绝互斥字段和布局糖，并与 `ebox-build` 共享结果；
- CanonicalEboxInput 不含 paint-only 字段；ETAF 与独立 Ebox paint adapter 各自只投影一次；
- sourceHandle 与 eboxNodeId 生命周期独立，reconciliation 不改变来源 identity；
- `outer × layout` 合法组合和失败组合；
- normal inline/block、row、column、flex、grid 的 GUI 行为；
- Component root 与透明 Fragment 的布局参与；
- 空/单根/多根 Fragment 都保留 RangeAnchor 并可局部替换；
- paint-only candidate 不构造 LayoutPlan，geometry 与 paint patch 在现有事务汇合；
- style/Theme/TP 优先级和事务回滚；
- Research Shelf 与 Flex reference 的连续 resize；
- 固定真实场景 p95 和 max 均不超过 50ms。

## 8. 当前实现差距与非目标

当前代码仍注册 `text`、`fragment`、`container`、`row`、`column`、`stack`、
`flex`、`grid` 和 `spacer`，并提供 `raw-ebox`；目标 `box`、`:outer`、
typed Layout 尚未实现，目标公共 View 也不保留 `raw-ebox`。

当前 Ebox DSL 仍把 `box :content` 和裸字符串直接编码为无类型
`ebox-create :content`，并把 `item`、`grid-item` 构造成运行时 wrapper。目标新增
明确的 TextNode/BoxNode canonical IR 与 typed constructors，保留 Text、Box 和
五个 Box author form；删除 `:content` 作者/公共 constructor 语法以及 `ebox`、`spacer`、
`item`、`grid-item`。

### 8.1 原子迁移顺序与门禁

本迁移不采用逐个 tag 的长期兼容路线。当前已验证基线为 Ebox `6d9f2a4` 与
Ebox Playground `f571c89`；任何未提交实验都不构成功能或性能基线。实施按以下
依赖顺序推进，并且 author boundary 的切断作为一个跨仓原子目标提交：

1. 先补齐 typed core：Normal 支持零个或多个 inline/block child；Row/Column 完整
   实现 `:item-gap/:cross-align`；Normal/Row/Column/Flex/Grid 都由一个 BoxNode 加
   typed LayoutConfig 表达。Text 可以作为 Flex/Grid 直接 child 并使用默认
   participation，但不能携带非默认 participation。
2. `ebox-build` 一次切换到唯一 grammar：String、`text`、`box`、`row`、`column`、
   `flex`、`grid`。五个 Box form 直接构造 typed Box/LayoutConfig；删除
   `ebox/spacer/item/grid-item`，拒绝 author `:content/:layout` 和 raw runtime node。
3. 同一次目标删除完整 legacy public creation surface：`ebox-create`、
   `ebox-concat/ebox-stack/ebox-spacer/ebox-grid-fr`、旧
   `ebox-row/ebox-column/ebox-flex/ebox-grid` constructor 的 public/autoload 身份，
   以及相应 public inventory、帮助、README、文档和示例。仍被后端需要的 lowering
   可以暂时私有存在，但不得成为 canonical output、公共概念或第二条作者路径。
4. 同步迁移全部实际消费者：Ebox、ETAF、ETAF UI、Ebox Playground、ETAF
   Playground 及其 README、文档、示例和测试。公共材料与示例不得出现
   `:ebox-content-node`、`:display`、`:ebox-type` 等私有后端字段。

验证采用最小而有判定力的矩阵，不为 legacy 行为复制同义测试：一组表驱动 grammar
与 negative contract 覆盖七个入口、五种 Layout、Normal 多 child、Text 默认参与、
wrong-parent；复用已有 identity、final-candidate、commit/rollback 门禁；删除只证明
旧 wrapper/alias 的测试。

每个候选先跑定向测试，再跑所有受影响仓库的完整静态/测试门禁。GUI 连续 resize
逐步检查无非预期 full-root fallback，最终文本与全部文本属性等同 fresh render，且
稳定 identity 不丢失。性能比较在同一 Emacs、frame、宽度序列和操作序列下，对已
提交基线与候选交错采样：每个操作先 warm up 5 次，再各测至少 30 次；使用通用
recorder 比较 operation、跨包 stage、p95 与 max。受影响真实场景的 p95 与 max
均不得超过 50ms，任何 stage 的可复现退化都必须先定位根因。任一功能、GUI 或
性能门禁失败时停止提交，不增加 compatibility 分支或大量同义测试。

这是干净重设计，不要求旧 Host 名称或旧 `.etaf` 文件继续运行，也不增加长期
兼容层。实现完成前，正式架构和用户指南不得把目标语法描述成当前 API。

非目标：

- 不实现完整浏览器 CSS；
- 作者 DSL 不提供 `spacer`、公共 `flow` 或 `(box :content ...)`；
- 不把 Flex/Grid item 做成作者节点、视觉 wrapper 或独立 identity；
- 不允许应用把原始 Ebox Node 注入 View；
- 不把布局模式做成 Component 或第二套 Runtime 节点；
- 不在 Core 中保留旧 Host/layout-form alias；property alias 只服从 3.2 的统一机制；
- 不让 Playground、UI 或数据库包拥有 Core 协议；
- 不在没有真实编译成本和运行时收益前增加 App 预编译产物。
