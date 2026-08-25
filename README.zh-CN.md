# ETAF

ETAF 是构建在独立 [Ebox](../ebox) 布局与渲染引擎之上的小型文本应用框架。

完整的公共模型是：

```text
Component(props, Scope) → View → Renderer → Ebox Node → Emacs buffer
```

所有可见结构都使用一种形式：

```elisp
(name :property value ... child ...)
```

子节点中唯一的计算桥接是 `expr :value`；属性值则是普通 Elisp 表达式。

```elisp
(etaf-view
 (column
  (text :face 'bold "Hello")
  (text
   :color "#687386"
   (expr :value (if ready "Ready" "Waiting")))))
```

定义 Component：

```elisp
(etaf-define-component status-label (&key label)
  "Render a status label."
  :view
  (text :face 'bold (expr :value label)))

(etaf-mount
 "*etaf-demo*"
 (etaf-view (status-label :label "Connected")))
```

`etaf-view` 是唯一的公共 View 构造入口。结构 form 不使用 quote；quote 仍然是普通 Elisp 数据语法，例如 `'bold`。普通 Elisp 返回 View 时，必须在 `expr` 中显式使用 `(etaf-view ...)` 构造它。

## 性能记录面板

ETAF 内置了一个按需启用、与具体应用无关的性能记录器。它自动识别公共
Event、Action、mount、flush、focus、Data、Resource 和 viewport 操作；当
Ebox、TP、SQLite 等包已加载时，还会把这些包的粗粒度阶段关联到同一个
operation。

```elisp
(etaf-performance-mode 1)
;; 正常操作任意已挂载的 ETAF 应用。
(etaf-performance-show)
```

交互采集时先执行 `M-x etaf-performance-clear`，复现一组操作后，在面板按
`c`（或执行 `M-x etaf-performance-copy-report`）即可把完整报告复制到剪贴板；
按 `w`（或执行 `M-x etaf-performance-export`）可保存为 `.eld` 文件。报告包含
Emacs/显示环境、电源来源、低功耗模式、系统负载、分组 p50/p95/max、每次
operation、GC 增量和嵌套阶段；面板 header 也显示同一环境信息，避免把整机降频
误判成某个包的热点。

`*ETAF Performance*` 面板会显示 operation ID 与父 operation、generation
变化、总耗时、GC 增量，以及嵌套阶段的 inclusive/self 耗时。记录数量由
`etaf-performance-max-records` 限制；关闭 mode 会移除全部记录 advice。
`etaf-performance-summary` 会按需计算 operation 的 p50/p95/max，
`etaf-performance-operation-stage-summary` 则按 exclusive 耗时排列单次
operation 的包级阶段。

默认注册表刻意只记录包级粗边界，避免分析工具明显改变被测应用。任意包或
应用可以临时增加更细的探针，不需要绑定某个示例：

```elisp
(etaf-performance-register-stage
 'my-package-expensive-step 'application 'expensive-step)
```

没有内置公共边界的任意操作，可以使用
`etaf-performance-call-operation` 或 `etaf-performance-with-operation`
包裹。

## 可执行示例

[`examples/`](examples/README.zh-CN.md) 目录包含三个只依赖 core 的最佳实践应用：保留式状态与 Action、Data Controller 所有权，以及 Resource 错误/清理 lifecycle。`make check` 会编译它们，并通过已挂载的公开事件路径驱动交互。

```elisp
(add-to-list 'load-path "/path/to/github/etaf/examples")
(require 'etaf-counter-example)
(etaf-counter-example-open)
```

## 文档

- [English Architecture](docs/architecture.en.md) · [中文架构](docs/architecture.zh.md)
- [English User Guide](docs/user-guide.en.md) · [中文用户指南](docs/user-guide.zh.md)
- [English Implementation Plan](docs/implementation-plan.en.md) · [中文实施计划](docs/implementation-plan.zh.md)
- [Module-boundary proposal (unimplemented)](docs/proposals/module-boundaries.en.md) · [模块边界提案（未实现）](docs/proposals/module-boundaries.zh.md)
- [English Best-practice Examples](examples/README.md) · [中文示例](examples/README.zh-CN.md)

## 独立包

| 包 | 职责 |
| --- | --- |
| [`etaf-ui`](../etaf-ui/README.md) | 官方 Component 目录：Button、Checkbox、Label、Panel 和 DataGrid。 |
| [`etaf-sqlite`](../etaf-sqlite/README.md) | 具体 SQLite Data Source；Data Controller 仍属于 ETAF core。 |
| [`etaf-playground`](../etaf-playground/README.md) | ETAF 示例；只有请求官方目录示例时才加载 UI 包。 |
| [`ebox-playground`](../ebox-playground/README.md) | 只使用 Ebox 的布局示例，与 ETAF 独立。 |

没有单独需要安装的 `etaf-data`：Data 是 ETAF 核心能力。也没有笼统的 `etaf-adapters` 包：其他数据库、服务、文件或 ORM 应使用明确名称的具体 Data Source 包实现同一契约。

## 加载与验证

ECSS 0.1.0 与 TP 1.0.0 是互相独立的包，安装顺序任意；两者都安装后再安装 Ebox 2.0.0，最后安装 ETAF。ETAF 只使用 Ebox 2.0 的公共渲染契约。

开发时先把同级 Ebox 检出目录加入 `load-path`：

```elisp
(add-to-list 'load-path "/path/to/github/ebox")
(add-to-list 'load-path "/path/to/github/etaf")
(require 'etaf)
```

运行完整本地门禁：

```sh
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
```

核心门禁会编译实现、运行 core/Data/Resource 测试，并检查文档和 API 边界。还应在同级 `etaf-ui`、`etaf-sqlite`、`etaf-playground` 和 `ebox-playground` 仓库分别运行 `make check`；它们都不会被 core facade 自动加载。
