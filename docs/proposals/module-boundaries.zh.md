# ETAF 模块职责与目标架构（设计提案，未实现）

> 状态：设计提案。本文不描述当前已交付 API。当前行为仍以
> [`architecture.zh.md`](../architecture.zh.md)、[`user-guide.zh.md`](../user-guide.zh.md)
> 和通过的测试为准。

本文只定义目标模型、模块 owner、依赖方向和完成条件。实现顺序属于单独的
实施计划；历史名称和兼容策略不参与目标架构设计。

## 1. 最终模型

ETAF 的表示链只有四层：

```text
Component 语义与所有权
    ↓
View：Text / Box / Fragment
    ↓
Ebox：测量、布局、几何 patch
    ↓
TP + Emacs adapter：paint 与最终提交
```

用户需要理解的主要概念只有 `Text`、`Box` 和 `Component`。`Fragment` 是高级
结构语法；`Host` 是 Renderer 内部术语；`Ebox Node` 是后端对象，都不构成第二套
组件模型。

规范化 View 的完整形状是：

```text
View = Text
     | Box
     | Fragment
     | ComponentCall
```

`expr` 和 `slot` 是计算/投影机制，不是视觉节点。目标公共 View 不接受原始 Ebox
节点；缺失的渲染能力必须先形成有类型、有 identity/impact 契约的 View/Ebox 能力，
不能通过 opaque escape 绕过框架语义。

## 2. Text、Box 与 Fragment

### 2.1 Text

`Text` 是文本叶子，负责：

- 字符串和 inline Text runs；
- 字体、前景/背景、下划线等文本 paint；
- 文字测量、换行和文本对齐的输入；
- 可选 identity、语义和事件属性。

`Text` 默认 `:outer 'inline`。它不能拥有 Box、Component 或任意布局子节点，也
不能建立 `row`、`column`、`flex` 或 `grid` 上下文。需要 padding、border、尺寸
或子布局时，在外层使用 `Box`。

### 2.2 Box 的两个正交轴

`Box` 同时拥有一个外部参与方式和一个内部布局方式：

```text
:outer  = inline | block
:layout = normal | row | column | flex | grid
```

- `:outer`：这个 Box 如何参与父级的 `normal` 布局；
- `:layout`：这个 Box 如何排列自己的子节点。

默认值是：

```text
Box  :outer block  :layout normal
Text :outer inline
```

`inline-flex` 是两个轴的组合，不是新的节点类型：

```elisp
(box :outer 'inline :layout 'flex ...)
```

公开 API 使用 `:outer` 和 `:layout`。不公开 `:inner`，也不要求用户写 Ebox 的
`(:display (block flow))` 一类后端表示。

### 2.3 normal 的明确范围

`normal` 是一个真实但刻意收敛的布局上下文：

- 连续的 inline `Text` 或 inline `Box` 进入同一行流并按可用宽度换行；
- block `Box` 从新行开始并形成独立块；
- block 前后的 inline 行会在块边界结束；
- 子节点顺序保持稳定。

目标不实现完整浏览器 CSS：没有 float、table、absolute/fixed positioning、
run-in、list-item 或任意匿名盒规则。Ebox 可以把 `normal` 映射为内部 flow
算法，但 `flow` 不是 ETAF 公共词汇。

当父级 `:layout` 是 `row`、`column`、`flex` 或 `grid` 时，父算法直接拥有子项
位置；子项的 `:outer` 不改变排列顺序。`:outer` 只决定节点进入 `normal` 父级时
是 inline 还是 block。

### 2.4 其他布局模式

| 模式 | 职责 |
| --- | --- |
| `row` | 简单水平顺序布局，不执行 Flex 空间分配 |
| `column` | 简单垂直顺序布局，不执行 Flex 空间分配 |
| `flex` | Flex sizing、direction、wrap、alignment 和 gap |
| `grid` | 二维轨道、放置、跨度和 gap |

这些都是 `Box` 的 layout mode，不是 Component，也不注册 `row`、`column`、
`flex` 或 `grid` 的第二套 Runtime 节点名称。目标 API 只有规范写法：

```elisp
(box :layout 'row ...)
(box :layout 'column ...)
(box :layout 'flex ...)
(box :layout 'grid ...)
```

### 2.5 Fragment

`Fragment` 是无视觉 wrapper 的结构 Range：

- 可以承载零个、一个或多个兄弟 View；
- 不产生 Box、尺寸、背景或布局上下文；
- Runtime 可以为其保留稳定 Range identity 并局部替换；
- 只接受子节点和可选稳定 `:key`，不接受视觉/事件属性。

Component call 本身没有 `:outer` 或 `:layout`。它的根 Text/Box 决定如何参与父级
布局；返回 Fragment 的透明 Component 可以产生多个兄弟节点，因此不存在单一的
“Component 外部盒子”。

### 2.6 字符串、content 与空 Box

Box 子节点中的字符串规范化为 Text：

```elisp
(box "this is text")
```

等价于：

```elisp
(box (text "this is text"))
```

ETAF 不提供 `(box :content "...")`。`:content` 只属于 Ebox 后端构造器；暴露它
会制造 content 与 children 两套结构模型。

ETAF 也不提供 `spacer` 类型。没有子节点的 Box 就是空 Box。

## 3. 属性契约

属性是闭集，并按 owner 验证；未知属性和不适用组合必须报错。

| Owner | 属性类别 | 代表属性 |
| --- | --- | --- |
| Text | 外部参与 | `:outer` |
| Text | 文本/paint | `:face`、`:color`、`:bgcolor`、`:wrap-mode`、`:text-align` |
| Box | 外部/内部布局 | `:outer`、`:layout` |
| Box | 几何/表面 | `:width`、`:height`、`:min-*`、`:max-*`、`:margin`、`:padding`、`:border`、`:box-sizing`、`:overflow` |
| Flex container | 布局 | `:flex-direction`、`:flex-wrap`、`:justify-content`、`:align-items`、`:align-content`、`:gap` |
| Flex item | 父级参与 | `:order`、`:flex-grow`、`:flex-shrink`、`:flex-basis`、`:align-self` |
| Grid container | 布局 | track templates、auto flow、gap、item/content alignment |
| Grid item | 父级参与 | `:grid-row`、`:grid-column`、row/column span |
| Text/Box | identity/语义 | `:key`、`:ref`、`:class`、`:id`、`:role`、`:aria-*`、`:on-*`、`:use` |

规则：

- `:key` 是 identity metadata，不是视觉属性；
- `:outer`、`:layout` 和 layout-specific 属性属于 structure/geometry impact；
- color、background、typography 等属于 paint impact；
- ECSS 可以解析上述属性，但必须保留 impact 分类；
- TP 只消费已经解析的 paint contribution，不判断布局合法性；
- 结构属性变化必须事务性重建对应布局上下文，不能走 paint-only 快速路径。

## 4. 模块 owner

### 4.1 ETAF Core

`etaf-view`：

- 定义并规范化 Text、Box、Fragment 和 ComponentCall；
- 将字符串规范化为 Text；
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
- 把规范化 View 和 computed properties 转换为 Ebox 输入；
- 不执行 Component lifecycle，不访问 Ebox 私有状态。

Theme 的语义 token 和继承属于 ETAF Context。TP 不拥有“暗色主题”等业务意义。

### 4.2 Ebox

Ebox 拥有：

- Text 测量、换行和行布局；
- `normal`、`row`、`column`、`flex`、`grid` 几何算法；
- width/height、box model、overflow、scroll、viewport；
- 稳定 Ebox node identity、geometry snapshot 和结构 patch plan。

Ebox 不理解 Component、slot、Context、Action、Behavior、Data 或 Resource，也不
决定 paint contribution 的优先级。

逻辑边界：

```text
ebox-core   纯测量、布局、快照和结构 patch
ebox-emacs  字体/窗口能力、buffer 位置和结构提交
```

这不要求立即拆成两个发行包，但纯布局和 Emacs 副作用必须能独立测试。

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
Ebox stage 结构/几何 patch
    ↓
TP stage paint patch
    ↓
Emacs adapter 原子应用两个 patch
    ↓
ETAF Runtime 提升 generation；失败则回滚参与者
```

Ebox 不拥有 TP paint 优先级；TP 不拥有节点布局；两者都不能自行提升 Runtime
generation。

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

## 5. 依赖方向

```text
etaf-ui ─────────────▶ ETAF Core ─────────────▶ Ebox public port
etaf-sqlite ─────────▶ ETAF Data contract
etaf-playground ─────▶ ETAF + optional UI/SQLite
ebox-playground ─────▶ Ebox only
etaf-performance ────▶ public observation boundaries only

ETAF Renderer ───────▶ ECSS computed properties
ETAF Runtime  ───────▶ Ebox/TP transaction participants
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
转移。Elisp 不重复 Rust 已经完成的 diff、cascade、布局或文字扫描。

## 7. 正确性与性能不变量

- 同一事务中的 View、computed properties、geometry snapshot 和 paint contribution
  各 materialize 一次；
- Text paint 改变不执行无关 Component，也不运行布局；
- `:outer`、`:layout` 或几何改变只运行受影响的布局 owner；
- Fragment/slot/list 变化只替换对应 Range；
- Ebox/TP/Emacs 任一 participant 失败时保留上一代已提交状态；
- resize 使用当前窗口事实立即重排，不以隐藏 debounce 改变交互语义；
- 性能记录器不改变被测路径。

最终门禁必须覆盖：

- Text/Box/Fragment 结构等价；
- `outer × layout` 合法组合和失败组合；
- normal inline/block、row、column、flex、grid 的 GUI 行为；
- Component root 与透明 Fragment 的布局参与；
- style/Theme/TP 优先级和事务回滚；
- Research Shelf 与 Flex reference 的连续 resize；
- 固定真实场景 p95 和 max 均不超过 50ms。

## 8. 当前实现差距与非目标

当前代码仍注册 `text`、`fragment`、`container`、`row`、`column`、`stack`、
`flex`、`grid` 和 `spacer`，并提供 `raw-ebox`；目标 `box`、`:outer`、
`:layout 'normal` 尚未实现，目标公共 View 也不保留 `raw-ebox`。

这是干净重设计，不要求旧 Host 名称或旧 `.etaf` 文件继续运行，也不增加长期
兼容层。实现完成前，正式架构和用户指南不得把目标语法描述成当前 API。

非目标：

- 不实现完整浏览器 CSS；
- 不提供 `spacer`、公共 `flow` 或 `(box :content ...)`；
- 不允许应用把原始 Ebox Node 注入 View；
- 不把布局模式做成 Component 或第二套 Runtime 节点；
- 不在 Core 中保留旧 Host alias 或可选短写法；
- 不让 Playground、UI 或数据库包拥有 Core 协议；
- 不在没有真实编译成本和运行时收益前增加 App 预编译产物。
