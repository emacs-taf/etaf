# ETAF 架构

本文定义目标架构，是公共概念和职责边界的契约，不是变更日志。

## 1. 唯一的降级路径

```text
Application
  → Runtime / State / Action / Data
  → Component(props, local scope)
  → View
  → ETAF Renderer
  → Ebox Node
  → measure → layout → paint → commit
  → Emacs buffer
```

ETAF 描述应用结构和行为；Ebox 是底层引擎，负责把可测量的 Node 树转换为文本 surface，并原子地发布这些 surface。每个新的 ETAF 功能都必须在这条路径上拥有唯一职责归属。

## 2. 用户需要理解的四个概念

### View

View 是结果的结构描述。View 可以是 Host 调用、Component 调用、字符串文本叶子、`nil`，或者这些值组成的序列。

### Component

Component 是复用边界。它接收 props，可选地拥有局部 Scope，并产生 View。Component 不是另一种 Ebox Node，也不应因为“可复用”就增加新的 renderer 分支。

### Node

Node 是 Ebox 的可测量、可渲染模型。Ebox 负责几何、盒模型、布局、surface 属性、滚动、运行时身份和 buffer 发布。ETAF 不把 Component 语义、slot、Action 或事件塞进 Ebox 属性。

### Runtime

Runtime 负责挂载、调度、状态失效、事件边界、提交协调、回滚和销毁。Runtime 是应用边界，不是另一种 View 节点。

## 3. 统一的 View 语法

所有 Host 和 Component 调用都使用同一种形状：

```elisp
(NAME ATTRIBUTE* CHILD*)
```

属性是 `:KEY VALUE`；子节点是 View、字符串、`nil`，或通过 `expr` 产生的序列。属性区必须在子节点区之前完整结束：

```elisp
(text :face 'bold :color "#F4F6FB" "Hello")
```

下面的写法非法，因为属性区和子节点区交错：

```elisp
(text "Hello" :face 'bold)
```

核心 Host 和公共 Component 都遵循同一规则；`text` 没有另一套“位置参数作为内容”的特殊约定。

## 4. Elisp 求值边界

编译器读取结构位置中的 View，不要求对 View 使用 quote：

```elisp
(etaf-view (text "Hello"))
```

属性值是普通 Elisp 表达式位置：

```elisp
(etaf-view
 (text :face (if dark 'light 'dark) "Theme"))
```

子节点区只有一个明确的计算桥接：

```elisp
(expr :value (if checked "☑" "☐"))
```

`expr` 只接受 `:value`。`if`、`when`、`cond`、`let`、`mapcar` 及其他 Elisp 形式仍然是该 value 内的普通 Elisp；ETAF 不增加单独的 `if`、循环或计算节点类别。

表达式要返回 View 时，显式构造它：

```elisp
(expr
 :value
 (when open
   (etaf-view (text :face 'bold "Details"))))
```

`'(text "Details")` 是数据，不是 View。因此 quote 既不是全局禁止，也不是第二套 View 编译器。

## 5. Component

公共定义模型只有入门形式和高级形式：

```elisp
(etaf-define-component NAME (&key PROPS)
  :view VIEW)

(etaf-define-component NAME (&key PROPS)
  :setup SETUP)
```

`:view` 是结构语法，不需要 quote；`:setup` 是普通 Elisp，用于建立 Component Scope 并返回零参数 render 函数；普通 Elisp 产生 View 时使用 `etaf-view`。`:view` 与 `:setup` 互斥。组件静态样式使用独立的定义元数据入口 `:styles (styles RULE...)`；styles 不是第三种渲染模型。

Props 和 children 的职责不同。Props 是 Component 声明的命名输入；末尾 children 和具名 slot 组成同一个 slot collection，而不是隐藏的第二套 Component 参数表。该 collection 在 Component 边界统一归一化并投影。

在 View 语法中，公共 Component 可以省略 `etaf-` 前缀；普通 Elisp API，如 `etaf-value`、`etaf-ref`、`etaf-mount`，保留前缀。别名解析只发生在结构位置；发生冲突时使用 `list-view` 这样的语义别名，不覆盖 Elisp 的 `list`。

## 6. 核心 Host 与官方 Component

ETAF 核心只包含最小的、无样式 Host：

```text
text · fragment · container · row · column · stack · flex · spacer
```

这些名字表达结构布局和文本 surface。Button、Checkbox、Input、Dialog、DataGrid 等产品级控件都是独立 `etaf-ui` 包提供的普通 Component。核心的可按压能力通过 `:role`、`:on-press` 等语义属性表达，不建立与 `etaf-ui` Button 竞争的核心 Button Host。

字符串是最小文本 View，会降级为带 content 的 Ebox box；`text` 是用于样式和语义属性的显式文本 Host，不是另一种 Ebox Node 家族。

## 7. 非视觉能力

这些机制扩展同一个 Component/Host 边界，但不建立平行的视觉节点类别：

| 机制 | 职责 | 入口 |
| --- | --- | --- |
| `on-xx` | 一个局部事件回调 | Host/Component 属性 |
| Action | 有名字、可测试的业务变更 | Action 定义和 dispatch |
| Effect | 外部同步、订阅和清理 | Scope 中的 Effect |
| Behavior | 可复用的非视觉能力集合 | `:use` 属性 |
| watch | 响应式失效原语 | Reactive API 或 Behavior |
| Context | 继承的 Scope 值 | Provide / Inject |
| Data | 请求、状态、取消和错误归属 | Core data API |

`expr` 负责计算子节点值，不拥有身份、生命周期、订阅、buffer 写入或 Effect。Behavior 可以使用事件、ref、Effect 和 watch，但自身不会变成 View 节点。

## 8. 包职责

```text
ebox
  └── 可选的 ebox-playground

etaf → ebox
  ├── reactive / state / action / effect / data / ECSS
  └── 纯 .etaf compiler

etaf-ui → etaf
etaf-playground → etaf（展示官方 Component 时再依赖 etaf-ui）
```

Ebox 不理解 Component、slot、Action、Context 或 data。ETAF 只通过 renderer 边界和 Ebox 公共 API 使用 Ebox。`etaf-data` 是 core 能力，不是用户必须额外安装的平级包。数据库和外部集成使用明确的数据源包，例如 `etaf-sqlite`；不需要抽象的公共 `etaf-adapters` 层。

两个 Playground 都是独立的可选工具：`ebox-playground` 只使用 Ebox；`etaf-playground` 使用 ETAF 公共 API，绝不调用 Ebox Playground 或 Ebox 私有函数。

## 9. 扩展规则

应用层功能优先使用 Component、Behavior、Action、Effect、Context 值或 data source。只有当功能确实改变测量、布局、surface 绘制、滚动或发布，并且已经定义好 signature、dirty 分类、渲染、回滚和测试责任时，才增加 Ebox 属性或 Node。这样既保持用户模型小而统一，又通过普通表达式位置和 Runtime API 保留 Elisp 的图灵完备能力。
