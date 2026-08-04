# ETAF 实施计划

本文是独立 `etaf` 仓库的开发计划。架构契约见 [`architecture.zh.md`](architecture.zh.md)；本文记录实施顺序、验证方式和明确的缺口。

## 1. 里程碑

| 里程碑 | 范围 | 完成证据 |
| --- | --- | --- |
| P0 | 统一语法、`etaf-view`、`expr`、无状态 `:view`、核心 Host、Ebox 桥接 | 宏展开失败测试、ERT 契约测试、字节编译、挂载 smoke test |
| P1 | slot collection、`:setup`、Component Scope、ref、生命周期、raw Ebox escape | 公共 Component 测试覆盖 setup-once、props、slot、销毁和回滚 |
| P2 | Context、Behavior、focus/event 协议、Action、Effect、watch | 真实挂载事件路径、清理测试、身份和失败测试 |
| P3 | ECSS 样式、主题、行内文本、resource/error boundary | 样式顺序、文本 surface、异步恢复和 buffer 发布测试 |
| P4 | Data 能力、`etaf-ui`、数据源、Playground、按用例增加布局能力 | 独立加载扫描、包测试、应用示例和 CI |

## 2. P0 已交付切片

- 独立包仓库位于 `/Users/geekinney/IPARA/3-RESOURCES/emacs/config/github/etaf`。
- 当前 checkout 阶段唯一依赖是同级 Ebox 包。
- `etaf-view.el` 负责结构解析以及唯一的 `expr :value` 桥接。
- `etaf-component.el` 负责无状态 `:view` 定义和上下文别名。
- `etaf-renderer.el` 是唯一调用 Ebox 的模块，只使用 Ebox 公共构造和发布 API。
- 核心 Host 保持最小且无样式：`text`、`fragment`、`container`、`row`、`column`、`stack`、`flex`、`spacer`。
- 属性/子节点顺序、普通 Elisp 求值边界、表达式结果、Component props、别名冲突和挂载都由 `tests/etaf-tests.el` 覆盖。

## 3. P1 顺序

1. 固定 Component 调用和 slot collection 的内部表示。
2. 实现 `(slot)`、`(slot FALLBACK...)` 默认 slot 投影，再实现 `(slot :name 'NAME CHILD...)` 具名 slot。
3. 将末尾 children 和具名 slot 声明归一化为同一个 collection；拒绝动态、字符串、数字和 keyword slot 名称。
4. 将 `:setup` 实现为只执行一次的普通 Elisp，建立 retained Component Scope 并返回零参数 render 函数。
5. 增加具有稳定身份的 ref 和 computed，并支持 props 更新而不重新运行 setup。
6. 在加入状态型应用示例之前，补齐明确的生命周期和失败候选销毁。
7. 在普通 View 路径稳定后，加入带命名空间的 `raw-ebox :value` 后端逃生口。

P1 不得增加第二个 Template 入口、Variant 定义模型、`text` 的位置参数例外或基于 quote 的 View 约定。

## 4. P2–P4 依赖顺序

- Context 依赖 retained Component Scope 以及最近祖先的所有权规则。
- Behavior 依赖稳定 Host 身份、事件、ref、Effect 和销毁流程。
- Action 是业务变更，不得变成 View 节点或展示回调。
- Effect 负责外部同步和清理；`watch` 仍是 Behavior 或 Effect 可以使用的响应式原语。
- ECSS 和状态样式依赖冻结的 Ebox 属性边界以及文本 surface 映射。
- Data 是 ETAF core 能力；SQLite、PostgreSQL、MySQL、REST、文件和 ORM 都是可选的具体数据源包。
- `etaf-ui` 是一个官方 Component catalog；源码拆分只是维护边界，不是用户概念；DataGrid 是普通复合 Component。
- `ebox-playground` 只依赖 Ebox；`etaf-playground` 依赖 ETAF，并可选依赖 `etaf-ui`；二者互不依赖。

## 5. 验证门禁

每个里程碑都必须先通过最小相关门禁，才能进入下一个边界：

```sh
make compile EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make test EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
```

P0 还要求对错误语法产生干净的宏展开失败，并走真实的 `etaf-mount` 路径。P1 增加 setup/slot 生命周期测试；P2 增加挂载事件和清理路径；P3 增加文本 surface 和发布测试；P4 增加包边界扫描、独立加载和应用 smoke test。

只有辅助函数通过不算里程碑完成：必须同时验证公共宏展开、Component 构造、renderer 降级和 buffer 发布。

## 6. 停止条件

不得重新引入 `etaf-template`、Variant、公共 Control/Widget 分类、作为必需平级包的 `etaf-data`、抽象 `etaf-adapters` 或第二个公共 View 构造入口。在真实应用提供测量、布局和发布契约之前，不实现 Grid、Overlay 或完整 CSS 克隆。
