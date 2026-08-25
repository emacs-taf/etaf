# ETAF 模块职责与目标架构（设计提案，未实现）

> 状态：设计提案。本文不是当前公共 API 或已交付实现的规范；当前可用契约仍以
> [`architecture.zh.md`](../architecture.zh.md)、[`user-guide.zh.md`](../user-guide.zh.md)
> 和实际测试为准。

本文把 ETAF、Ebox、ECSS、TP、`etaf-ui`、`etaf-sqlite`、性能工具和两个
Playground 的职责收敛成一份待评审的边界提案。它描述的是从零设计时应保持的
模型，不是把当前实现中的每个文件名当成架构真相。

文中标有“目标”的部分是后续演进方向；除非代码、测试和基准同时完成，不能
把目标 API 描述成已经交付的功能。提案没有自动授权实现，也不改变当前 Host
注册表、View 语法或包依赖。

## 1. 最小稳定模型

ETAF 需要区分四种表示，而不是把它们都叫作“组件”或“box”：

```text
Component 语义与所有权
    ↓
Text / Box View 结构
    ↓
Ebox 几何与渲染计划
    ↓
TP / Emacs 最终提交
```

### 1.1 公共概念

用户只需要学习三个主要概念：

| 概念 | 稳定职责 | 不负责的事情 |
| --- | --- | --- |
| `Text` | 文本内容、字体、inline text properties、换行入口 | 子树布局、业务状态、生命周期 |
| `Box` | 尺寸、背景、边框、padding、子节点和布局 | Component identity、Data、Action |
| `Component` | 可复用语义、props、slot、状态、Context、Action、生命周期 | 像素测量和布局算法 |

`Host` 是 Renderer 内部用于称呼可直接降低到后端的原语，不是用户需要额外
学习的第三套视觉分类。`Ebox Node` 则是更底层的几何/渲染对象；它可以由一个
`Text`、一个 `Box`，或一棵 Component 子树产生。

### 1.2 Text 与 Box 的关系

CSS 中所有最终可见元素都会产生 box，但 CSS 生成的 box、ETAF 的 View 原语和
Ebox 的后端节点不是同一棵树。`inline` 和 `block` 描述盒子参与父布局的方式；
`flex` 和 `grid` 描述盒子内部如何排列子节点。

因此 ETAF 不应该把 `inline`、`block`、`flex`、`grid` 都做成 Component。目标
公共模型是：

```text
View = Text(content, typography)
     | Box(layout, surface, children)
     | ComponentCall(props, slots)
```

目标中的 `Box` 布局模式是封闭集合：

```text
flow | row | column | flex | grid
```

语义映射大致为：

| CSS 语义 | ETAF 目标表达 |
| --- | --- |
| inline text/run | `text` |
| block flow | `(box :layout 'flow ...)` |
| horizontal layout | `(box :layout 'row ...)` |
| flex container | `(box :layout 'flex ...)` |
| grid container | `(box :layout 'grid ...)` |

完整的 `inline-flex` 这类组合属于“外部参与方式 + 内部布局方式”两个轴。当前
文本应用不需要把完整 CSS `display` 矩阵暴露给用户；未来若 Ebox 确实需要，
应增加正交属性，而不是增加 `inline` Component。

### 1.3 子节点与后端 content

目标 ETAF 语法只保留一个内容模型：子节点。

```elisp
(box "this is text")
```

等价于：

```elisp
(box (text "this is text"))
```

需要文本属性时显式写 `text`：

```elisp
(box
 :padding '(1 2)
 (text :face 'bold "Title"))
```

ETAF 公共语法不增加 `(box :content "...")`。`:content` 是 Ebox 后端构造器
（例如 `ebox-create`）的内部字段；Renderer 可以把 `text` 降低为后端 content，
但不能把后端字段反向暴露成第二套 ETAF 子树模型。这样可以自然混合字符串、
Text、Box、Component 和 slot，也不会产生 content 与 children 的优先级歧义。

## 2. 模块职责

下面的边界是“谁拥有完整规则”的判断标准。调用别的模块的公开契约不等于拥有
那个模块的职责。

### 2.1 ETAF Core

#### `etaf-view`

拥有：

- `Text`、`Box`、Component call、Fragment 的结构语法和规范化 View 值；
- 属性优先解析和 `expr :value` 求值边界；
- props、`key` 和 slot 的静态形状验证；
- Component 注册表与 View 名称解析。

不拥有：

- 字宽、像素、布局、滚动和 buffer 写入；
- Component 生命周期和 Runtime 调度；
- 业务数据、数据库、UI 控件实现。

#### `etaf-component`

拥有：

- `etaf-define-component`；
- `:view`、`:setup`、`:styles` 定义边界；
- props 和静态 Component style 的声明验证。

不拥有：

- Ebox 私有节点；
- Data 请求、数据库连接或全局 UI 控件目录。

#### `etaf-runtime`

拥有：

- Component identity、`:key`、retained instance；
- ref、computed、effect、watch 和 Scope cleanup；
- Context、Theme、Action、Behavior、Data、Resource 的生命周期；
- 依赖失效、候选 generation、提交、回滚和调度；
- 将变化定位到 Component、Range、Host 属性或 Paint contribution。

不拥有：

- 字体测量、flex/grid 算法、像素布局；
- Ebox 私有状态；
- SQLite、HTTP 或某个示例的业务规则。

#### `etaf-renderer`

拥有：

- 唯一的 ETAF View → Ebox 公共 lowering 边界；
- Text、Box、Component 输出到 Ebox 公共构造器的转换；
- 把已解析的 style/theme/property contribution 传给下游；
- 明确的 `raw-ebox` 低层出口。

不拥有：

- Component setup/lifecycle 的所有权；
- Ebox 的测量和布局实现；
- Data 查询或应用 Action。

### 2.2 Ebox

Ebox 是布局和渲染引擎，不是 ETAF Component Runtime。

拥有：

- 文本测量、字宽、换行和内容高度；
- flow、row、column、flex、grid 的几何算法；
- padding、border、surface、overflow、scroll 和 viewport 几何；
- 稳定的布局快照、节点 identity、增量几何更新；
- 从布局结果到后端可提交 Render/Paint plan 的转换。

不拥有：

- Component、props、slot、Context、Action、Behavior、Data、Resource；
- 应用语义或 UI 控件分类；
- ETAF 的响应式依赖图。

`row`、`column`、`flex`、`grid` 即使在 ETAF 目标 API 中统一为
`box :layout ...`，Ebox 内部仍然可以保留不同的布局上下文和算法。统一的是
上层表达，不是把不同几何问题硬塞进一个无差别函数。

逻辑上可以继续拆为两个边界：

```text
ebox-core       纯测量、布局、快照和 Render plan
ebox-emacs      字体/窗口能力、Ebox Node 到 Emacs buffer 的提交适配
```

这两个边界不一定现在就变成两个发行包，但不能让布局算法和 Emacs buffer 副作用
混在同一个职责中。

### 2.3 ECSS

拥有：

- selector 解析和匹配；
- style declaration、cascade、继承和 computed style；
- 把静态规则转换为可复用、可验证的样式中间产物。

不拥有：

- Component state、slot、Action；
- 字宽、布局或 Ebox Node；
- Emacs text property 的提交和回滚。

ECSS 决定“某个结构节点应该得到哪些样式值”，不决定“这些像素如何排布”。

### 2.4 TP

拥有：

- Emacs text property / paint slot 的分层；
- Theme、Component、state、inline 等 Paint contribution 的优先级合并；
- 原子应用、journal、rollback 和已提交层的复用。

不拥有：

- CSS selector/cascade；
- 布局测量、祖先证明或文字换行；
- Component 和 Data。

TP 应接收精确的 Paint operations，不应该为了换一个背景色重新推导整棵 View
或重新执行所有 Component。

### 2.5 `etaf-ui`

拥有官方可复用 Component，例如：

- Button；
- Checkbox；
- Label；
- Panel；
- Number input；
- DataGrid；
- Pagination。

这些控件使用 ETAF 的 props、slot、事件、Behavior、Theme 和 Data 契约。它们
不是第二套 Widget/Control/Component 模型，也不应该实现自己的 Runtime 或布局
引擎。

### 2.6 `etaf-sqlite`

拥有：

- SQLite 连接、schema、查询、分页和 mutation；
- 参数和标识符校验；
- 具体 Data Source 的事务和 dispose 边界。

不拥有：

- ETAF Data Controller 状态机；
- View、Component、DataGrid 或 playground UI。

其他数据库、REST、文件和 ORM 集成也应实现同一个具体 Data Source capability，
但使用各自明确的包名，不引入一个笼统的 `etaf-adapters` 层。

### 2.7 性能工具

性能记录器必须是应用无关的逻辑模块（当前可以先作为 ETAF 中的独立子模块，
未来再决定是否单独发行）。它拥有：

- operation、stage、父子关系和 generation 记录；
- p50/p95/max、GC、环境信息和跨包阶段关联；
- 公共 Event、Action、mount、flush、Data、Resource、viewport 边界的探针；
- 报告、复制和导出。

它不拥有：

- Research Shelf 或任何示例名称；
- 应用状态或布局规则；
- 为了采样而改变正常渲染路径。

Playground 只能展示这个工具，不能定义它的核心协议。

### 2.8 两个 Playground

`ebox-playground`：

- 只验证 Ebox 的布局、测量、重排和性能；
- 只依赖 Ebox 公共 API；
- 不加载 ETAF、Component、Data Controller 或 UI 目录。

`etaf-playground`：

- 验证 ETAF 的 Component、Runtime、Data、UI 和交互组合；
- 可以选择加载 `etaf-ui` 和 `etaf-sqlite`；
- 提供 `.etaf` 示例加载、快捷键和状态展示；
- 不拥有 ETAF 的核心语法、Runtime 或性能记录协议。

`.etaf` 静态文件如果只是 Playground manifest，就属于 Playground；它不是 ETAF
Core 的 Runtime 入口。未来若增加通用 `.etaf` compiler，compiler 必须把结果
降低到同一套 Text/Box/Component 契约，不能创建第二套 Runtime。

## 3. 依赖方向

目标依赖图如下：

```text
                         ┌──────────────┐
                         │ etaf-performance │
                         │ optional observer│
                         └──────┬───────┘
                                │ public probes only
                                ▼
┌────────────┐       ┌────────────────────┐       ┌──────────────┐
│  etaf-ui   │──────▶│      ETAF Core     │──────▶│ Ebox public  │
└────────────┘       │ View/Component/RT │       │ layout port  │
                     └─────────┬──────────┘       └──────┬───────┘
                               │                         │
                     ┌─────────▼─────────┐       ┌──────▼───────┐
                     │ ECSS / TP adapters│       │ Ebox backend │
                     └───────────────────┘       │  / Emacs    │
                                                 └──────────────┘

etaf-sqlite ─────▶ ETAF Data Source contract
etaf-playground ─▶ ETAF + optional etaf-ui + optional etaf-sqlite
ebox-playground ─▶ Ebox public API only
```

约束：

- Ebox 不向上依赖 ETAF；
- TP 不解析 View，也不调用 Component；
- ECSS 不写 buffer；
- `etaf-ui` 不调用 Ebox 私有函数；
- `etaf-sqlite` 不知道任何 UI；
- Playground 不向 core 反向注入示例协议；
- 性能工具通过公开边界观察各包，不让被测包依赖某个示例。

## 4. Rust 与 Elisp 的切分

目标不是把所有代码机械地翻译成 Rust，而是把确定性计算和环境副作用分开。

适合 Rust 纯计算核心的内容：

- Text/Box Render IR 的验证和规范化；
- keyed diff、identity matching 和 patch batch；
- ECSS selector/cascade/computed-style 计算；
- 字符宽度、换行、flow/flex/grid 测量和布局；
- geometry snapshot、layout impact 和 paint contribution merge。

保留在 Elisp/Emacs 适配层的内容：

- 执行用户定义的 Component 函数；
- ref、Context、Action、Data、Resource 和 lifecycle callback；
- Emacs 事件、窗口、字体能力和 buffer 提交；
- 调用 Rust 核心并提交返回的 patch/paint plan。

Elisp 不应再次实现 Rust 已经计算过的布局、cascade、diff 或文字扫描；Rust 也不
应读取 Emacs buffer 或理解 Component slot 语义。

## 5. 性能与正确性不变量

模块增加不能把一次局部变化升级成多次全量遍历。必须保持：

- 一次事务中的稳定 identity、依赖、布局快照和 Paint contribution 只 materialize
  一次；
- Text paint 改变不重新执行无关 Component，不重新做布局；
- Box 几何改变只触发受影响的布局 owner；
- Component 状态/slot/列表拓扑改变只执行拥有该结构的 Component；
- Ebox 失败或 TP 提交失败时保留上一代已提交结果；
- 快速路径必须是普通正确路径的严格子集，并且能验证失败后精确回退；
- 性能工具本身不能改变被测应用的调度和布局路径。

真实 GUI 场景仍然是最终证据。固定场景在功能、文本属性、identity、生命周期和
回滚语义不缩水的前提下，p95 和 max 都必须满足项目的 50ms 目标；单独的微基准
不能替代跨包验证。

## 6. 当前实现与目标模型的关系

当前 ETAF Core 的 Host 注册表仍包含：

```text
text · fragment · container · row · column · stack · flex · grid · spacer
```

当前 Renderer 直接把这些名称映射到 Ebox 构造器；Ebox Playground 也直接使用
自己的布局 API。这是当前兼容表面，不是最终用户必须记忆的最佳词汇。

目标演进方向是：

```text
Text + Box(layout)
    ↑
row/column/flex/grid 作为编译期或语法级简写
    ↑
旧 container/stack 名称只作为兼容别名
```

这些简写不能通过 `etaf-define-component` 实现，否则每个布局节点都会被迫获得
Component 的 identity、scope、slot 和调度边界。它们应直接降低为 Ebox 布局节点。

目标模型尚未交付前，不得修改现有 Host 语法后再把未验证的 `box` 描述成已完成。

## 7. 有边界的演进顺序

如果开始实现目标模型，只做下面这个最小顺序：

1. 增加 `Box` 的规范化 View 形状和字符串子节点规则；
2. 只验证 `layout='column` 的 `box` 到 Ebox lowering；
3. 将 `row` 作为无 Component 开销的语法别名接入；
4. 分别验证 `flex` 和 `grid` 的模式属性、布局结果和增量路径；
5. 保留旧名称兼容，并用 Research Shelf 与 Flex reference 做 GUI 回归；
6. 只有全部公共测试和真实性能门禁通过，才更新用户指南为 `text + box`。

任何一步不能证明结果等价或性能收益，就删除该实验，不继续堆下一层抽象。

## 8. 明确不做的事情

- 不把 `button`、`panel`、`data-grid` 等业务控件塞进 Ebox；
- 不把 `row`、`column`、`flex`、`grid` 做成 Runtime Component；
- 不在 ETAF 公共层引入 `box :content` 第二套内容模型；
- 不让 TP 重新扫描布局或重新调和所有颜色；
- 不让 Playground 拥有通用框架协议；
- 不为了“预编译”而新增没有长编译时间和真实运行时收益的中间产物；
- 不为了减少名词而合并 Component、Text、Box、Ebox Node、Paint slot 等不同所有权
  和生命周期概念。
