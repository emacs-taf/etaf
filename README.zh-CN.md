# ETAF

ETAF 是构建在独立 [Ebox](../emacs-box) 布局与渲染引擎之上的小型文本应用框架。

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

## 文档

- [English Architecture](docs/architecture.en.md) · [中文架构](docs/architecture.zh.md)
- [English User Guide](docs/user-guide.en.md) · [中文用户指南](docs/user-guide.zh.md)
- [English Implementation Plan](docs/implementation-plan.en.md) · [中文实施计划](docs/implementation-plan.zh.md)

## 加载与验证

开发时先把同级 Ebox 检出目录加入 `load-path`：

```elisp
(add-to-list 'load-path "/path/to/github/emacs-box")
(add-to-list 'load-path "/path/to/github/etaf")
(require 'etaf)
```

运行完整本地门禁：

```sh
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
```

门禁会编译实现、运行 core/Data/Resource/UI/Playground 测试，并检查文档和 API 边界。`etaf-ui` 与 `etaf-playground` 是可选模块，不会被 core facade 自动加载。
