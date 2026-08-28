# ETAF 实施计划

本文是独立 `etaf` 仓库的维护者执行文档。[`architecture.zh.md`](architecture.zh.md) 是公共架构契约，[`user-guide.zh.md`](user-guide.zh.md) 是用户使用契约。本文记录交付顺序、职责、验证和有边界的后续工作。

## 1. 完成规则

只有同时满足以下条件，里程碑才算完成：

1. 公共路径真实存在，而不只是私有 helper。
2. 公共路径同时有成功测试和失败测试。
3. 受影响文件无 warning 地完成 byte compile。
4. 公共契约发生变化时，同步更新中英文文档。
5. 候选渲染失败时，不破坏上一次已经提交的 Runtime 或 buffer。

当下面的强制里程碑全部通过时，统一架构的实施完成。第一版官方 UI 目录、Grid 布局、SQLite source 和两个独立 Playground 已作为同级包交付；未来的 Component、数据源和异步集成都是增量工作，必须复用已经冻结的契约，不能扩大 core 词汇。

## 2. 里程碑状态

| 里程碑 | 已交付职责 | 证据 |
| --- | --- | --- |
| P0 grammar | 统一 View 形状、属性优先解析、`etaf-view`、`expr :value`、核心 Host、alias | `tests/etaf-tests.el` 结构和语法测试 |
| P1 Component | `:view`、`:setup`、props、默认/命名 slot、retained instance、生命周期、`:key`、raw Ebox 出口 | Component、slot、mount、prop 更新、raw node、rollback 测试 |
| P2 Runtime | ref、computed、effect、watch、Scope cleanup、Context、Theme、Behavior、事件、focus、Action | 挂载事件/focus、响应式失败回滚和 cleanup 测试 |
| P3 presentation | 作用域样式、selector、Theme 优先级、inline text runs、Resource 和 error boundary | 样式、Theme、文本 surface、Resource、error 测试 |
| P4 application | core Data Controller、memory source、selection、mutation、Grid Host、官方 UI 目录、DataGrid、SQLite source 和两个独立 Playground | core Data/Grid 测试以及四个同级包的 `make check` |
| Quality gates | 独立包入口、无 warning 编译、checkdoc、公共 API 测试和文档契约 | core `make check` 加 `etaf-ui`、`etaf-sqlite`、`etaf-playground`、`ebox-playground` 的检查 |

## 3. 职责地图

| 文件 | 稳定职责 | 不应负责 |
| --- | --- | --- |
| `etaf-view.el` | 结构语法、View 值、slot 规范化、表达式边界、Component 注册表 | Ebox 调用、buffer 写入、生命周期、业务状态 |
| `etaf-component.el` | `etaf-define-component`、prop 声明、定义级样式验证 | Runtime 调度或 Ebox lowering |
| `etaf-reactive.el` | ref、computed、effect、watch、effect Scope、cleanup | View 语法或 buffer 发布 |
| `etaf-context.el` | 继承 Context 和 Theme 默认值 | 全局 service 注册表或视觉节点 |
| `etaf-runtime.el` | retained instance、候选协调、提交/回滚、生命周期、Behavior 安装 | Ebox 私有状态或业务数据 schema |
| `etaf-renderer.el` | 唯一 ETAF 到 Ebox 的公共边界、样式、文本 lowering、raw 出口 | Component 生命周期和数据请求 |
| `etaf-behavior.el` | 非视觉 `:use` Behavior spec 和 installer | 视觉节点或直接修改 buffer |
| `etaf-events.el` | 事件 dispatch、Host 引用命中、activate、focus | 业务变更策略 |
| `etaf-actions.el` | 命名 Action 注册表和 Runtime dispatch | View 构造或 presentation |
| `etaf-resource.el` | Scope 所有的同步 loader 状态和 error boundary | 第二套异步/task 对象模型 |
| `etaf-data.el` | source capability、controller 状态、分页、mutation、selection | 数据库专用代码或存储假设 |
| 同级 `etaf-ui/etaf-ui.el` | 一个官方 Component 目录，包括复合 DataGrid | 第二套 Control/Widget/Component 分类 |
| 同级 `etaf-playground/etaf-playground.el` | 只使用公共 API 的 ETAF 示例和可选目录入口 | Ebox 私有 API 或 `ebox-playground` 依赖 |
| 同级 `etaf-sqlite/etaf-sqlite.el` | 类型化 SQLite Data Source 和事务边界 | Data Controller 状态或通用 ORM 层 |
| 同级 `ebox-playground/ebox-playground.el` | 只使用公共 Ebox API 的布局示例 | ETAF API 或 Ebox 私有 API |
| `etaf.el` | 一个 core facade 和本地包路径优先级 | 自动加载可选 UI 或 Playground |

不要为了获得更短的文件名而拆文件。只有稳定职责、生命周期、外部边界或发行边界发生转移时才拆分。

## 4. 已冻结的公共契约

### 4.1 View 与求值

- 唯一结构形式是 `(NAME :PROPERTY VALUE ... CHILD ...)`。
- 所有属性必须先于所有子节点。
- 属性值是普通 Elisp 表达式。
- 唯一的子节点计算桥接是 `(expr :value ELISP-EXPRESSION)`。
- Elisp 返回动态 View 时，在 `expr` 中用 `(etaf-view ...)` 构造；被 quote 的结构数据永远不会被执行。
- 六个可见 Host form 是 `text`、`box`、`row`、`column`、`flex`、`grid`；`fragment`、`slot`、`expr` 是透明的框架结构。
- View 作者 DSL 不提供 raw Ebox 逃生口；框架集成在作者 DSL 之外使用 Ebox evaluated typed-constructor 端口。

### 4.2 Component 与 slot

- `etaf-define-component` 只接受 `:view`、`:setup` 和可选 `:styles`。
- `:view` 与 `:setup` 互斥。
- `:setup` 对每个 retained identity 只运行一次，返回零参数 render 函数。
- Props 更新只重新 render，不重新运行 setup。
- 尾部 children 是 `slots.default`；命名 slot 输入使用 `(slot :name 'NAME CHILD...)`。
- 默认 outlet 简写是 `(slot)` 或 `(slot FALLBACK...)`。
- Slot name 只能是稳定的、非 keyword 的 symbol。
- `:key` 是 identity metadata，不是业务 prop：Component 调用用它选择 retained identity，Host 则把同一个解析后的事实投影到 Ebox source index。

### 4.3 Runtime 与非视觉能力

- ref、computed、watch、Effect 和 cleanup 使用同一套响应式 Scope 模型。
- Context 继承自 retained Component instance；Theme 是 Context 中的属性 plist。
- `:on-*` 是局部 callback；Action 是命名变更；Behavior 是可复用的 `:use` bundle；Effect 是订阅/cleanup owner。
- 事件和 focus 通过 Runtime 以及 Ebox 公共 Host 引用 API 进入。
- Data 是 ETAF core 能力。Source 有必选 `:load` 和可选 `:mutate`/`:dispose`。
- Resource 是 Scope 所有的同步 loader；core 不引入 task/promise 抽象。

改变这些契约之一时，必须先审查架构文档，再开始实现。不要为了兼容而增加第二种写法。

## 5. 验证矩阵

| 表面 | 命令或测试 | 证明内容 |
| --- | --- | --- |
| 包加载 | `make load EMACS=...` | 公共 facade 能使用同级 Ebox 包加载 |
| Byte compile | `make compile EMACS=...` | 所有发行实现文件无 warning 编译 |
| Core 行为 | `tests/etaf-tests.el` | grammar、Component、Runtime、reactive、Context、样式、事件、Action、raw 出口 |
| Resource 行为 | `tests/etaf-resource-tests.el` | loading、error、替换 cleanup、Scope 释放、显式边界 |
| Data 行为 | `tests/etaf-data-tests.el` | query、分页、规范化、mutation、selection、error、stop |
| UI 行为 | `tests/etaf-ui-tests.el` | Button、Checkbox、Panel slot、响应式 DataGrid 投影 |
| Playground 行为 | `tests/etaf-playground-tests.el` | 只使用 ETAF 公共 API 的挂载和事件路径 |
| 文档 | `tests/etaf-docs-tests.el` | 成对文件、当前命名、无过时公共入口、无 Ebox 私有调用 |
| 全量门禁 | `make check EMACS=...` | 编译、全部 ERT 和文档契约一起通过 |

事件和 Runtime 问题必须用真实公共 dispatch 路径测试。纯 helper 测试不能替代挂载测试。

## 6. 代码变更 review 清单

开始改代码前：

1. 写清行为 owner 以及从 View 到 Ebox 的数据流。
2. 搜索已有测试和兄弟模块，确认没有重复的公共路径。
3. 行为缺失或错误时，先写最小的失败回归测试。
4. 增加 helper 前，先尝试删除重复抽象。

实现过程中：

- View 值保持纯，把 buffer 变更放在 Runtime/Ebox 发布边界。
- cleanup 必须挂在创建该 resource 的 Scope 上。
- 让内部错误暴露出来，只在明确的 loader 或应用边界捕获。
- 用 `:key` 保持重复序列的结构 identity。
- 保持样式优先级和属性/子节点顺序确定。
- 可选包不能被 core facade 自动加载。

交付前：

- 阅读完整 diff。
- 运行 `make check` 并检查全部输出。
- 只使用本地 ETAF 和同级 Ebox 路径运行一次全新 `make load`。
- 扫描实现文件中的 `ebox--` 和其他不应跨边界的私有调用。
- 公共契约变化时同步更新两种语言的文档。
- 一个聚焦且已验证的修改完成后再开始下一个里程碑。

## 7. 有边界的后续工作

下面都是扩展路线，不是 core 概念缺失：

| 扩展 | 必须冻结的契约 | 安全的实现方向 |
| --- | --- | --- |
| 外部异步数据 | 具体 source 定义 callback、generation、取消和 error owner | 放在具体 source 包，或增加窄化的 Data capability；不要增加通用 task 层级 |
| 更多 UI Component | 既有 props/children/slot/event/Behavior 契约 | 在 `etaf-ui` 增加普通 Component，并通过 Runtime 测试 |
| 数据库 source | 已冻结的 `etaf-data-source` capability plist | `etaf-sqlite` 已交付；只有真实用例才增加具体 PostgreSQL/REST/文件/ORM source 包 |
| 更丰富布局 | 完整的 Ebox measurement/layout/publication 契约 | Grid 已交付；未来先扩展 Ebox，再通过 Host 或 Component 暴露 |
| Playground 可视化工具 | 公共 inspection 和 reporting API | 扩展 `etaf-playground`，不与 Ebox Playground 耦合 |

每个扩展都必须配套测试和文档。如果确实需要新的公共名词，先更新 `architecture.en.md` 与 `architecture.zh.md`，再更新本文和用户指南。

## 8. 停止条件

当一个里程碑的公共路径、回滚行为、测试、编译、加载和成对文档都完成时停止该里程碑。不要因为某个可选集成尚未存在就扩大 core 模型，也不要创建第二套渲染语法、第二种 Component 模型，或让用户必须学习的额外 Runtime 包边界。
