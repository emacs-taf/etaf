# 可执行 core 示例

## 决策

Core 最佳实践示例作为普通可加载 Elisp 文件放在 `examples/` 中，每个文件只负责一种应用职责，并提供公开的 open/close 命令对。它们只依赖 ETAF core，并由仓库常规门禁编译和执行交互测试。

## 原因

README 片段只能证明语法，不能证明 lifecycle 所有权或已安装 Runtime 的 dispatch 路径。单个大型 playground 可以展示广度，却难以看清状态、数据加载和清理分别属于哪一层。小型可执行应用能让这些边界保持可见，并在示例偏离框架契约时让测试真正失败。

Data Controller 与 Resource 在 Component setup 中创建，但从 mounted lifecycle 启动会修改状态的加载。这个区别很重要，因为 render 阶段被明确设置为写保护。Detached Data Controller 在 unmount 时显式停止；Resource 值继续由所属 Scope cleanup 管理。

## 未采用方案

- 依赖 `etaf-ui` 会让 core 示例继承尚未完成的组件目录迁移，并模糊独立包边界。
- 增加共享示例框架或 theme 模块会在复用不足时制造间接层；三个小应用可以各自拥有克制的展示样式。
- 捕获 loader 错误并返回展示默认值会隐藏 Resource error 契约，而不是教授它。

## 后续影响

新的 core 示例只有在讲清一种独立的公开所有权规则、包含真实 mounted 交互测试，并且不调用 ETAF/Ebox 私有 API 时才应加入。更广泛的完整应用展示继续属于 `etaf-playground`。
