# ETAF 最佳实践示例

这些示例是可执行应用，而不是文档片段。它们只使用公开的 `etaf` facade，并刻意不依赖 `etaf-ui`，从而保证核心框架边界可以独立运行。

| 示例 | 公开命令 | 演示的实践 |
| --- | --- | --- |
| 保留式计数器 | `M-x etaf-counter-example-open` | Component 自有 ref、computed 状态、可聚焦 Host、Event → Action → Runtime 更新 |
| 任务控制器 | `M-x etaf-data-example-open` | Data Controller 所有权、mounted 后加载、查询、选择、变更与 unmount 清理 |
| Resource 健康状态 | `M-x etaf-resource-example-open` | 延迟 Resource 加载、可见错误状态、reload 清理与 Scope 释放 |

在检出目录中开发时，把 Ebox、ETAF 和本目录加入 `load-path`：

```elisp
(add-to-list 'load-path "/path/to/github/ebox")
(add-to-list 'load-path "/path/to/github/etaf")
(add-to-list 'load-path "/path/to/github/etaf/examples")

(require 'etaf-counter-example)
(etaf-counter-example-open)
```

另外两个应用分别替换为 `etaf-data-example` / `etaf-data-example-open` 和 `etaf-resource-example` / `etaf-resource-example-open`。每个示例都有对应的 `-close` 命令，会先卸载 Runtime，再销毁 buffer。

## 为什么推荐这些模式

- render 函数中不写状态。Event 与 Action 负责修改 ref 或 Data Controller；render 只读取状态。
- 在 Component setup 中创建自有服务，从 `etaf-on-mounted` 启动会修改状态的工作，并用 `etaf-on-unmounted` 释放 detached controller。
- 让 Resource Scope cleanup 管理已加载值。不要捕获加载错误后伪造一个看似合理的默认值；应明确渲染 Resource error 状态。
- 使用稳定的 Host ref、语义 role 和 `etaf-focusable`，让键盘集成与测试驱动同一条已安装事件路径。
- 示例应紧凑且有清晰视觉结构，但不能引入示例专用渲染 API，也不能调用私有 `etaf--*` / `ebox--*` 符号。

在仓库根目录运行 `make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs`。门禁会编译这些文件、检查 docstring 与公开边界，并驱动真实挂载后的交互路径。
