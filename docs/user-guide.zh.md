# ETAF 用户使用指南

ETAF 使用一套很小的词汇构建文本应用：`View`、`Component`、props、children、响应式状态和 Ebox 渲染。先学习 `etaf-view` 与 `etaf-mount`；只有 Component 需要局部状态或生命周期时才增加 `:setup`。

## 1. 安装与加载

ETAF 依赖独立的 Ebox 包。开发时把两个检出目录放入 `load-path`，然后只加载 ETAF 的公共入口：

```elisp
(add-to-list 'load-path "/path/to/github/emacs-box")
(add-to-list 'load-path "/path/to/github/etaf")
(require 'etaf)
```

这个入口会加载核心 View、Component、Runtime、reactive、Context、Data、Resource、事件、Behavior 和 Action API。`etaf-ui` 与两个 Playground 都是可选模块；加载 `etaf` 不会自动加载它们。

## 2. 第一个 View

所有结构都使用：

```elisp
(NAME :property value ... child ...)
```

属性在前，子节点在后。`etaf-view` 接收不带 quote 的结构 form：

```elisp
(etaf-view
 (column
  (text :face 'bold "Hello")
  (text :color "#687386" "Welcome to ETAF")))
```

把它挂载到 Emacs buffer：

```elisp
(etaf-mount
 "*etaf-hello*"
 (etaf-view
  (column
   (text :face 'bold "Hello")
   (text "This is a text application."))))
```

`etaf-mount` 返回 buffer。同一个调用会先释放该 buffer 中已有的 Runtime，再挂载新的 View。需要显式释放时：

```elisp
(etaf-unmount (etaf-runtime-for-buffer "*etaf-hello*"))
```

纯渲染或测试可以使用 `etaf-render`：

```elisp
(ebox-render
 (etaf-render
  (etaf-view (text :face 'bold "Pure View"))))
```

View 含有状态型 Component、响应式数据、事件或生命周期时，使用 `etaf-mount`。

## 3. 属性与子节点

属性值就是普通 Elisp 表达式，不需要额外的 `expr`：

```elisp
(let ((dark t)
      (label "Theme"))
  (etaf-view
   (text
    :face (if dark 'light 'dark)
    :color "#F4F6FB"
    (expr :value label))))
```

子节点区是结构语法。`expr` 是执行普通 Elisp 的唯一明确桥接：

```elisp
(etaf-view
 (column
  (expr :value (if loading "Loading..." "Ready"))
  (expr
   :value
   (when open
     (etaf-view (text :face 'italic "Details"))))))
```

`expr` 只接受 `:value`，不能有子节点。返回值可以是字符串、View、序列或 `nil`。`if`、`when`、`cond`、`let`、`mapcar` 和 `cl-loop` 仍然是 value 中的普通 Elisp。

quote 只有普通 Elisp 的含义：

- 结构性 View form 不要 quote。
- 字面量 symbol 和数据列表在 Elisp 需要时才 quote。
- Elisp 表达式需要构造 View 时，在其中使用 `(etaf-view ...)`。

例如 `'bold` 是 face symbol，而 `'(text "data")` 只是数据，不会渲染。动态 View 必须写成 `(etaf-view (text "data"))`。

## 4. 定义 Component

入门形式是无状态的 `:view` Component：

```elisp
(etaf-define-component status-label (&key label)
  "Render a status label."
  :view
  (text
   :face 'bold
   (expr :value label)))

(etaf-mount
 "*etaf-status*"
 (etaf-view
  (status-label :label "Connected")))
```

Component 的规范名称可以带 `etaf-` 前缀：

```elisp
(etaf-view (etaf-status-label :label "Connected"))
```

在 View 位置，ETAF 也会注册短 alias `status-label`。如果短名称会与 Elisp 冲突，注册表会使用以 `-view` 结尾的语义 alias。这个规则只作用于 View 名称；普通函数仍然保留前缀。

定义宏只接受这些关键字：

| 关键字 | 作用 |
| --- | --- |
| `:view` | 无状态 Component 的 View 生产者，与 `:setup` 互斥 |
| `:setup` | 一次性初始化，返回零参数 render 函数 |
| `:styles` | 可选的静态作用域样式声明 |

没有单独的 children、slot、event、state 或 variant 声明块。业务 props 通过 `(&key ...)` 声明，children 和 slot 是隐式内容。

## 5. 局部状态与生命周期

Component 自己拥有状态时使用 `:setup`：

```elisp
(etaf-define-component counter (&key title)
  "Render a retained counter."
  :setup
  (let ((count (etaf-ref 0)))
    (etaf-on-mounted
     (lambda () (message "%s mounted" title)))
    (etaf-on-unmounted
     (lambda () (message "%s unmounted" title)))
    (lambda ()
      (etaf-view
       (column
        (text :face 'bold (expr :value title))
        (text (expr :value (format "Count: %d" (etaf-value count))))
        (text
         :role 'button
         :on-press (lambda () (cl-incf (etaf-value count)))
         "Increment"))))))
```

Setup 对 retained instance 只执行一次，返回的 render 函数在更新时重复运行。`etaf-on-mounted`、`etaf-on-updated` 和 `etaf-on-unmounted` 注册该 Component 的生命周期 callback。Scope 释放时会自动停止响应式 effect 并运行 cleanup。

响应式 API 只有一套模型：

```elisp
(let* ((count (etaf-ref 0))
       (double (etaf-computed
                (lambda () (* 2 (etaf-value count))))))
  (etaf-watch count
              (lambda (new old)
                (message "%s → %s" old new)))
  (setf (etaf-value count) 1)
  (etaf-value double))
```

如果函数形式更清楚，可以使用 `etaf-set-value`。`etaf-watch-effect` 用于响应式副作用，并且可以返回 cleanup：

```elisp
(etaf-watch-effect
 (lambda ()
   (message "Count is %s" (etaf-value count))
   (lambda () (message "Stop observing count"))))
```

在 Component setup 中，effect 和 watch 属于 Component Scope。在 Component 外部，需要用 `etaf-effect-scope` 和 `etaf-scope-run` 明确创建 Scope。

## 6. children 与 slot

普通尾部子节点就是匿名/默认 slot：

```elisp
(etaf-define-component panel (&key title)
  "Render a titled panel."
  :view
  (column
   (text :face 'bold (expr :value title))
   (slot (text :face 'shadow "No content"))))

(etaf-view
 (panel
  :title "Account"
  (text "Account body")))
```

命名 slot 使用 `:name`，并且必须是稳定的、非 keyword 的 symbol：

```elisp
(etaf-define-component card (&key title)
  "Render a card with a header slot."
  :view
  (column
   (slot :name 'header
         (text :face 'bold (expr :value title)))
   (slot (text :face 'shadow "No body"))))

(etaf-view
 (card
  :title "Account"
  (slot :name 'header (text "Account settings"))
  (text "Body")))
```

默认 slot 的两个用户简写是 `(slot)` 和 `(slot FALLBACK...)`。内部统一形式是 `(slot :name 'default FALLBACK...)`。调用处的普通子节点填充 `default`；命名内容写成 `(slot :name 'header CHILD...)`。显式空的 `(slot :name 'header)` 会抑制 fallback。字符串、数字、变量和运行时表达式都不是合法 slot name。

## 7. 样式与 Theme

静态 Component 样式只有一种声明形式：

```elisp
(etaf-define-component styled-card ()
  "Render a small styled card."
  :styles
  (styles
   ("&"
    :padding (1 2)
    :border ((1) solid "#687386"))
   (".title" :face bold)
   (".danger" :color "#FF6B6B"))
  :view
  (column
   :class "card"
   (text :class "title" "Title")
   (slot)))
```

外层 `styles` 是静态 Component metadata。每条规则是 `("SELECTOR" :PROPERTY VALUE...)`；`(1 2)` 和 `bold` 在样式中是数据，不需要 quote。普通 View 属性仍遵循 Elisp 规则，字面量列表通常需要 quote。

优先级固定为：

```text
显式 Host 属性 > Component :styles > 继承的 Theme 默认值
```

Theme 是 Context 的便捷形式，不是另一个 Runtime 对象：

```elisp
(etaf-define-component themed-shell ()
  "Provide default text colors to a subtree."
  :setup
  (progn
    (etaf-theme-provide
     '(:color "#F4F6FB" :bgcolor "#202634"))
    (lambda () (etaf-view (slot)))))
```

## 8. 事件、Action、Behavior 与 focus

一次局部事件使用 `:on-*` 属性：

```elisp
(text
 :ref 'save
 :role 'button
 :on-press (lambda () (message "Saved"))
 "Save")
```

Runtime 会按 Host 引用保存 handler。测试和集成可以直接 dispatch：

```elisp
(let ((runtime (etaf-runtime-for-buffer "*etaf-status*")))
  (etaf-dispatch-event runtime 'save 'press))
```

命名的业务变更使用 Action：

```elisp
(etaf-action-define save-record (runtime record)
  "Save RECORD through the application boundary."
  (ignore runtime)
  (message "Saving %S" record))

(text
 :role 'button
 :on-press (lambda () (etaf-dispatch 'save-record record))
 "Save")
```

Action 函数第一个参数是 Runtime。`etaf-dispatch` 必须在挂载的 Runtime 中运行，或者把 Runtime 作为第一个参数显式传入。

Behavior 用来打包可复用的非视觉属性和 cleanup：

```elisp
(text
 :use (list (etaf-focusable))
 :role 'button
 "Focusable text")
```

使用 `etaf-define-behavior` 定义应用 Behavior；只使用一次的交互不需要定义 Behavior，直接使用 `:on-*`。`etaf-toggleable` 可用于 controlled value。Behavior 不是视觉节点，也不直接编辑 buffer。

如果需要可复用的 installer，可以把产生 cleanup 的部分放到保留的 `:install` 属性中：

```elisp
(etaf-define-behavior traced-focus (&rest attributes)
  "Install a Behavior with a visible lifecycle trace."
  (apply #'etaf-behavior-create
         'traced-focus
         (append attributes
                 (list :install
                       (lambda ()
                         (message "Behavior installed")
                         (lambda ()
                           (message "Behavior removed")))))))
```

Installer 需要 Runtime 或 Host path 时，可以调用 `etaf-current-behavior-context`。Behavior 被替换时，旧 cleanup 会在新状态成为当前状态前运行。

Focus 和 hit testing 是 Runtime 操作：

```elisp
(let ((runtime (etaf-runtime-for-buffer "*etaf-status*")))
  (etaf-focus-next runtime)
  (etaf-activate runtime))
```

`etaf-host-ref-bounds` 和 `etaf-host-ref-position` 暴露公共的 Ebox hit-test 边界。`etaf-dispatch-event` 支持可选 payload 标记，用于给 callback 传入一个参数。

## 9. Context / Provide / Inject

Context 适合跨多层共享依赖，不适合普通 label：

```elisp
(etaf-define-component application-shell ()
  "Provide a service to descendants."
  :setup
  (let ((service (etaf-ref "demo-service")))
    (etaf-provide 'service service)
    (lambda () (etaf-view (slot)))))

(etaf-define-component service-label ()
  "Read the inherited service."
  :setup
  (let ((service (etaf-inject 'service nil t)))
    (lambda ()
      (etaf-view
       (text (expr :value (format "Service: %s" (etaf-value service)))))))

(etaf-mount
 "*etaf-context*"
 (etaf-view (application-shell (service-label))))
```

Context key 是稳定的普通 symbol，最近的祖先优先。`etaf-inject` 对可选依赖返回 default，对必需但缺失的依赖触发 `etaf-context-error`。注入的 ref 或 computed 保留自身响应式 identity。

## 10. Data Controller 与 DataGrid

Data 已经是 ETAF core 能力。Data Source 实现一个小的 source 契约：

```elisp
(setq source
      (etaf-data-source
       :load (lambda (query page page-size)
               (ignore query)
               (let ((rows '((:id 1 :name "Ada")
                             (:id 2 :name "Grace"))))
                 (list :items rows
                       :total (length rows)
                       :page page
                       :page-size page-size)))
       :mutate (lambda (operation payload)
                  (ignore operation payload)
                  t)
       :dispose (lambda () nil)))
```

官方 UI Component 使用和用户 Component 相同的 controlled-prop 模型：

```elisp
(require 'etaf-ui)

(let ((done (etaf-ref nil)))
  (etaf-mount
   "*etaf-checkbox*"
   (etaf-view
    (etaf-checkbox
     :checked (etaf-value done)
     :label "Done"
     :on-change (lambda (next)
                  (setf (etaf-value done) next))))))
```

Component 发出 next value；ref 由调用方拥有，并在下一次 render 提供当前值。

`:load` 接收 query 和分页参数，返回带 `:items` 的 plist；`:mutate` 和 `:dispose` 可选。内置 memory source 适合本地示例：

```elisp
(setq source
      (etaf-data-memory-source
       '((:id 1 :name "Ada")
         (:id 2 :name "Grace"))
       :id-key :id))
(setq controller
      (etaf-data-controller source :page-size 10 :auto-load t))
```

Controller 通过 `etaf-data-items`、`etaf-data-status`、`etaf-data-error`、`etaf-data-total`、`etaf-data-query`、`etaf-data-page`、`etaf-data-page-size` 和 `etaf-data-selection` 暴露响应式 ref。操作使用 `etaf-data-load`、`etaf-data-reload`、`etaf-data-mutate`、`etaf-data-set-query`、`etaf-data-next-page`、`etaf-data-previous-page`、`etaf-data-select` 和 `etaf-data-stop`。

官方 DataGrid 是普通 Component：

```elisp
(require 'etaf-ui)

(etaf-mount
 "*etaf-grid*"
 (etaf-view
  (etaf-data-grid
   :controller controller
   :columns '((:key :id :label "ID")
              (:key :name :label "Name"))
   :row-key (lambda (row) (plist-get row :id)))))

(etaf-data-mutate controller 'insert '(:id 3 :name "Alan"))
```

DataGrid 要求 `:row-key` 对每一行返回非 nil 的稳定标量。它通过普通 Host 和 slot 投影 loading、error、empty、header、rows 和 footer，不是第二种 data 或 Component 模型。

存储不绑定 SQLite。PostgreSQL、REST、文件或 ORM 集成都应该提供同样契约的具体 Data Source；它们是可选集成，不改变 ETAF 的用户模型。

## 11. Resource 与 raw Ebox

Resource 是 Scope 所有的同步 loader：

```elisp
(let ((resource
       (etaf-resource
        (lambda ()
          (etaf-resource-result
           "loaded"
           :cleanup (lambda () (message "resource released")))))))
  (message "%s: %s"
           (etaf-resource-status resource)
           (etaf-resource-value resource))
  (etaf-resource-dispose resource))
```

Loader 错误会保存在 `etaf-resource-error`；cleanup/type 错误保持可见。`etaf-error-boundary-run` 只处理它的 function body 抛出的错误：

```elisp
(etaf-error-boundary-run
 (lambda ()
   (let ((filename "README.md"))
     (with-temp-buffer
       (insert-file-contents filename)
       (buffer-string))))
 (lambda (condition)
   (message "Read failed: %S" condition)
   nil))
```

唯一的低层出口是 `raw-ebox`：

```elisp
(etaf-view
 (raw-ebox
  :key 'manual-node
  :value (ebox-create :content "Backend node")))
```

只有普通 Host 和 Component lowering 无法表达真实 Ebox 需求时才使用它；返回的 Node 对 ETAF 语义保持 opaque。

## 12. Playground

可选的 core Playground 是一个完整的 ETAF 应用示例：

```elisp
(require 'etaf-playground)
(etaf-playground-open)
```

需要展示官方目录时：

```elisp
(etaf-playground-open-ui)
```

`etaf-playground-close` 会卸载并删除默认 Playground buffer。它与 `ebox-playground` 独立，核心 ETAF 不会自动加载任一 Playground。

## 13. 公共 API 速查

| API 家族 | 主要入口 | 何时使用 |
| --- | --- | --- |
| View 与 Runtime | `etaf-view`、`etaf-render`、`etaf-mount`、`etaf-unmount`、`etaf-runtime-flush` | 构建、渲染、挂载或显式 flush 应用 |
| Component | `etaf-define-component`、`etaf-current-prop`、`etaf-current-slots` | 复用 View 或保留局部状态 |
| 响应式状态 | `etaf-ref`、`etaf-value`、`etaf-set-value`、`etaf-computed` | 保存或派生状态 |
| 响应式 effect | `etaf-watch`、`etaf-watch-effect`、`etaf-effect-scope`、`etaf-scope-run` | 观察状态或同步外部资源 |
| 生命周期 | `etaf-on-mounted`、`etaf-on-updated`、`etaf-on-unmounted` | 绑定 Component 生命周期工作 |
| Context | `etaf-provide`、`etaf-inject`、`etaf-theme-provide` | 跨层级共享依赖 |
| 事件与 focus | `etaf-dispatch-event`、`etaf-activate`、`etaf-focus`、`etaf-focus-next` | 进入交互 Runtime |
| Action | `etaf-action-define`、`etaf-dispatch` | 命名和复用业务变更 |
| Behavior | `etaf-behavior-create`、`etaf-define-behavior`、`etaf-current-behavior-context`、`etaf-focusable`、`etaf-toggleable` | 复用非视觉交互 bundle |
| Data | `etaf-data-source`、`etaf-data-controller`、`etaf-data-memory-source`、`etaf-data-*` | 查询、分页、变更、选择和停止数据 |
| Resource | `etaf-resource`、`etaf-resource-result`、`etaf-error-boundary-run` | 管理 loader 状态和 cleanup |
| 官方 UI | `require 'etaf-ui`、`etaf-button`、`etaf-checkbox`、`etaf-label`、`etaf-panel`、`etaf-data-grid` | 使用现成 Component |
| Playground | `etaf-playground-open`、`etaf-playground-open-ui`、`etaf-playground-close` | 探索框架 |

大多数应用一开始只需要 `etaf-view`、`etaf-mount`、`etaf-define-component`、`etaf-ref` 和事件 callback。其余 API 都是可选能力，不是理解核心语法的前置条件。

## 14. 常见错误

- 所有属性必须放在第一个子节点之前。
- 使用 `:face 'bold`，不要使用 `:face :bold`；face 是 Elisp symbol 值，不是属性 keyword。
- 结构性 View form 不要 quote。
- `if`、`when`、`let`、`mapcar` 或 Elisp 返回 View 时，使用 `expr :value`。
- 默认 outlet 使用 `(slot)` 或 `(slot FALLBACK...)`；命名内容使用 `:name 'header`。
- 不要在 render 中写状态；使用事件、Action、watch callback 或 Effect。
- 产品级控件使用 `etaf-ui` Component；core Host 只是结构基础。
- owner 不再需要时，停止 Data Controller 并卸载 Runtime。
