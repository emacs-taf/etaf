# ETAF

ETAF 是构建在独立 Ebox 布局与渲染引擎之上的文本应用框架。

公共模型刻意保持很小：

- `View` 描述 Host 和 Component 调用。
- `Component` 根据 props 产生 View。
- `Ebox` 负责测量、布局、绘制和发布结果。

所有结构都使用同一种形状：

```elisp
(name :property value ... child ...)
```

属性必须全部位于前面，子节点必须全部位于后面。属性值就是普通 Elisp 表达式；子节点中唯一的可执行桥接是 `expr`：

```elisp
(etaf-view
 (column
  (text :face 'bold "Hello")
  (text (expr :value (if ready "Ready" "Waiting")))))
```

使用 `:view` 定义无状态 Component：

```elisp
(etaf-define-component status-label (&key label)
  "Render a status label."
  :view
  (text :face 'bold (expr :value label)))

(etaf-mount
 "*etaf-demo*"
 (etaf-view
  (status-label :label "Connected")))
```

`etaf-view` 是唯一公共 View 构造入口。View 结构和 Component 的 `:view` 都不需要 quote；quote 仍然是普通 Elisp 数据语法，例如用 `'bold` 表示 face 符号。普通 Elisp 表达式返回 Renderable 时，必须在 `expr` 中使用未 quote 的 `(etaf-view ...)` 构造它。

## 开发检出

开发时先把同级的 Ebox 检出目录加入 `load-path`：

```elisp
(add-to-list 'load-path "/path/to/github/emacs-box")
(add-to-list 'load-path "/path/to/github/etaf")
(require 'etaf)
```

包元数据声明 Ebox `1.0.1` 为运行时依赖。ETAF 不调用 Ebox 私有函数。

## 第一阶段范围

当前仓库建立并测试 P0 语法、`etaf-view`、`expr`、无状态 `:view` Component、核心 Host（`text`、`fragment`、`container`、`row`、`column`、`stack`、`flex`、`spacer`）以及 Ebox 挂载桥接。状态型 `:setup`、slot、styles、Context、Behavior、事件、Action、数据和增量 Component 协调将在后续里程碑实现；暂未实现的子句会显式报错。

运行聚焦检查：

```sh
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
```

目标架构和分阶段开发工作分别见 [`docs/architecture.zh.md`](docs/architecture.zh.md) 与 [`docs/implementation-plan.zh.md`](docs/implementation-plan.zh.md)，英文版本与中文版本并列维护。
