# ETAF

ETAF 在独立的 [Ebox](../ebox) 布局与渲染引擎上，使用可复用的 Component 构建文本应用。

从 `etaf-view` 和 `etaf-mount` 开始。`(name :property value ... child ...)`
中属性在前、子节点在后，属性值是普通 Elisp。求值下面完整例子，切换到
`*etaf-hello*`，即可激活 “Say hello”：

<!-- etaf-example: hello -->
```elisp
;;; -*- lexical-binding: t; -*-
(require 'etaf)

(etaf-mount
 "*etaf-hello*"
 (etaf-view
  (column
    (text :font-weight 'bold "Hello")
    (box :ref 'hello :role 'button :tab-index 0
         :on-press (lambda () (message "Hello ETAF"))
      "Say hello"))))
```

Component 通过声明的 props 接收业务输入，通过 slot 接收内容。调用时使用
`etaf-define-component` 中的准确名称，注册表不会自动生成 alias。
`(expr FORM)` 执行一个子节点表达式：结构位置可以返回 nil、字符串、typed
Host 或 Component View，或这些值组成的 proper sequence；`text` 内的表达式必须返回字符串。

<!-- etaf-example: card -->
```elisp
;;; -*- lexical-binding: t; -*-
(require 'etaf)

(etaf-define-component demo-card (&key title)
  :view
  (column
    (text :font-weight 'bold (expr title))
    (slot)
    (slot :name 'footer)))

(etaf-mount
 "*etaf-card*"
 (etaf-view
  (demo-card :title "Account"
    (text "Connected")
    (slot :name 'footer (text "Footer")))))
```

组件拥有状态时才增加 `:setup`，它对每个保留的实例执行一次。
`:render` 使用普通 Elisp 捕获句柄，再返回 `etaf-view`；更短的 `:view`
形式编译为同一种 View 模型。

<!-- etaf-example: counter -->
```elisp
;;; -*- lexical-binding: t; -*-
(require 'etaf)

(etaf-define-component demo-counter ()
  :setup (etaf-ref 0)
  :render
  (let ((count (etaf-state)))
    (etaf-view
     (column
       (text (expr (format "Count: %d" (etaf-value count))))
       (box :ref 'increment :role 'button :tab-index 0
            :on-press (lambda () (cl-incf (etaf-value count)))
         "Increment")))))

(etaf-mount "*etaf-counter*" (etaf-view (demo-counter)))
```

把 `etaf-value` 放在需要更新的属性或 `expr` 内，保留局部更新边界。
事件回调捕获普通词法变量，`etaf-state` 在 render 时读取。可复用应用代码放进
启用 lexical-binding 的 `.el` 文件。程序化构造 View 时也可使用 `etaf-node`。
Context、Data、Behavior 和命名 Action 按需学习，简单回调不需要注册 Action。

加载 `(require 'etaf-ui)` 后，使用 `etaf-button` 等准确目录名称。
Core 不加载 `.etaf` 文件；Playground 将它们作为 inert 结构，由其显式的 companion
注册入口管理可执行 Elisp。

## 性能记录面板

ETAF 提供一个独立、按需加载、与具体应用无关的性能记录器。它消费 Runtime
公共 observer 报告，不使用 advice 或私有跨包探针。Event、Action、mount、flush
和 unmount 等 Runtime operation 会自动记录；同一 operation 内的 Ebox、TP、Data、
Resource 和 SQLite 等 provider 阶段按 sequence 关联到同一条记录。

```elisp
(require 'etaf-performance)
;; 在已挂载 ETAF Runtime 的 buffer 中：
(etaf-performance-mode 1)
;; 正常操作任意已挂载的 ETAF 应用。
(etaf-performance-show)
```

交互采集时先执行 `M-x etaf-performance-clear`，复现一组操作后，在面板按
`c`（或执行 `M-x etaf-performance-copy-report`）即可把完整报告复制到剪贴板；
按 `w`（或执行 `M-x etaf-performance-export`）可保存为 `.eld` 文件。报告包含
Emacs/显示环境、电源来源、低功耗模式、native JIT 状态、系统负载、分组
p50/p95/max、每次 operation、GC 增量和有序 provider 阶段；面板 header 也显示
同一环境信息，避免把整机降频误判成某个包的热点。

`*ETAF Performance*` 面板会显示 operation ID、generation 变化、总耗时、GC
增量，以及 flat provider 阶段的顺序和各自耗时。provider 阶段可能重叠，因此
不会伪装成 exclusive/self 时间。记录数量由 `etaf-performance-max-records`
限制；关闭 mode 只会解除当前 Runtime 的 observer，不修改任何函数。
`etaf-performance-summary` 会按需计算 operation 的 p50/p95/max，
`etaf-performance-operation-stage-summary` 则按 provider category 汇总单次
operation 的 flat 阶段。`etaf-performance-records` 返回 operation/stage 的防御性
快照，调用方修改返回值不会改写已保留的历史。
向 `etaf-performance-records` 传入 observer 报告中的数字 runtime ID，可以隔离
同名 buffer 重建前后的记录。summary/report 函数省略参数时读取全部历史，
显式传入 `nil` 时保持空结果。导出的环境是生成报告时的状态，不是每次历史操作
的状态；同步 operation 耗时也不等于物理输入到画面呈现的延迟。逐次 GUI 条件
检查使用 [scripts/README.md](scripts/README.md) 中的测量入口。

没有内置公共边界的任意操作，可以使用
`etaf-performance-call-operation` 或 `etaf-performance-with-operation`
包裹；它们直接委托同一个 Runtime operation 边界，不建立第二套计时器。

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

先安装 ECSS 0.1.0 与 TP 2.0.0，再安装 Ebox 3.0.0，最后安装 ETAF 0.2.1。
ETAF 会直接声明 TP 依赖，因为 Host final-accept authority 使用 TP transaction
contract。渲染要求 Ebox framework SPI v2；provider 缺失、格式错误或不兼容时，
ETAF 会在 bootstrap 阶段 fail closed。

ETAF 为当前 Emacs 进程 snapshot 一个不可变的 v2 render port。按依赖顺序升级时，
也接受 Ebox 过渡期的 TP 双能力 manifest，因为其中包含所需的 v2 协议；ETAF
不会调用已经退役的 v1 capability。

开发时先把同级 Ebox 检出目录加入 `load-path`：

```elisp
(add-to-list 'load-path "/path/to/github/ecss")
(add-to-list 'load-path "/path/to/github/tp")
(add-to-list 'load-path "/path/to/github/ebox")
(add-to-list 'load-path "/path/to/github/etaf")
(require 'etaf)
```

运行完整本地门禁：

```sh
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
```

核心门禁会编译实现、运行 core/Data/Resource 测试，并检查文档和 API 边界。还应在同级 `etaf-ui`、`etaf-sqlite`、`etaf-playground` 和 `ebox-playground` 仓库分别运行 `make check`；它们都不会被 core facade 自动加载。
