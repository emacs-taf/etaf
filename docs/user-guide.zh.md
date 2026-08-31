# ETAF 用户使用指南

ETAF 使用一套很小的词汇构建文本应用：`View`、`Component`、props、children、响应式状态和 Ebox 渲染。先学习 `etaf-view` 与 `etaf-mount`；只有 Component 需要局部状态或生命周期时才增加 `:setup`。

## 1. 安装与加载

ETAF 依赖独立的 Ebox 包。开发时把核心检出目录放入 `load-path`，然后只加载 ETAF 的公共入口：

```elisp
(add-to-list 'load-path "/path/to/github/ebox")
(add-to-list 'load-path "/path/to/github/etaf")
(require 'etaf)
```

这个入口会加载核心 View、Component、Runtime、reactive、Context、Data、Resource、事件、Behavior 和 Action API。`etaf-ui`、`etaf-sqlite` 和两个 Playground 都是独立的可选包；加载 `etaf` 不会自动加载它们。

## 2. 第一个 View

所有结构都使用：

```elisp
(NAME :property value ... child ...)
```

属性在前，子节点在后。`etaf-view` 接收不带 quote 的结构 form：

```elisp
(etaf-view
 (column
  (text :font-weight 'bold "Hello")
  (text :color "#687386" "Welcome to ETAF")))
```

把它挂载到 Emacs buffer：

```elisp
(etaf-mount
 "*etaf-hello*"
 (etaf-view
  (column
   (text :font-weight 'bold "Hello")
   (text "This is a text application."))))
```

`etaf-mount` 返回 buffer。同一个调用会先释放该 buffer 中已有的 Runtime，再挂载新的 View。需要显式释放时：

```elisp
(etaf-unmount (etaf-runtime-for-buffer "*etaf-hello*"))
```

Headless host 或已经知道最终布局上下文的调用方，可以通过可选第三个参数传入
初始 viewport。这样第一次 Ebox publication 会直接使用最终尺寸，不需要紧接着
再 rerender：

```elisp
(etaf-mount buffer view
            '(:viewport-width 1200 :viewport-height 48))
```

纯渲染或测试可以使用 `etaf-render`：

```elisp
(ebox-render
 (etaf-render
  (etaf-view (text :font-weight 'bold "Pure View"))))
```

View 含有状态型 Component、响应式数据、事件或生命周期时，使用 `etaf-mount`。

当前 core 不直接加载 `.etaf`。`etaf-define-component` 是结构/样式/行为单元：用 View 定义结构，用 `:styles` 放静态 presentation，用 `:setup` 管理 retained state、Action 和生命周期。未来 `.etaf` SFC 属于把结果编译成同一套 Component 契约的 compiler layer，而不是第二个 Runtime 入口。

## 3. 属性与子节点

属性值就是普通 Elisp 表达式，不需要额外的 `expr`：

```elisp
(let ((dark t)
      (label "Theme"))
  (etaf-view
   (text
    :color (if dark "#F4F6FB" "#1F2328")
    :background-color "#20242B"
    (expr label))))
```

子节点区是结构语法。`expr` 是执行普通 Elisp 的唯一明确桥接：

```elisp
(etaf-view
 (column
  (expr (if loading "Loading..." "Ready"))
  (expr
   (when open
     (etaf-view (text :font-style 'italic "Details"))))))
```

`expr` 只接受一个普通 Elisp form，不能有结构子节点。返回值可以是字符串、typed
View、typed View proper sequence 或 `nil`。`if`、`when`、`cond`、`let`、`mapcar` 和
`cl-loop` 仍是普通 Elisp。

quote 只有普通 Elisp 的含义：

- 结构性 View form 不要 quote。
- 字面量 symbol 和数据列表在 Elisp 需要时才 quote。
- Elisp 表达式需要构造 View 时，在其中使用 `(etaf-view ...)`。

例如 `'bold` 是 `:font-weight` 的 symbol 值，而 `'(text "data")` 只是数据，不会渲染。动态 View 必须写成 `(etaf-view (text "data"))`。

核心 `grid` Host 用于二维布局：

```elisp
(etaf-mount
 "*etaf-grid*"
 (etaf-view
  (grid
   :width '(640)
   :grid-template-columns '((200) (fr 1))
   :grid-template-rows '(1 1)
   :gap '(1 (12))
   (text :font-weight 'bold "Name")
   (text "Value")
   (text "Ada")
   (text "Lovelace"))))
```

轨道模板支持 `auto`、`min-content`、`max-content`、`(fr FACTOR)`、`(minmax MIN MAX)` 和 `(repeat COUNT TRACK-LIST)`。`:grid-auto-columns` 与 `:grid-auto-rows` 负责隐式轨道尺寸；`:grid-auto-flow` 支持 `row` 或 `column`。子节点可以使用 `:grid-column`、`:grid-row`、`:grid-column-span` 和 `:grid-row-span`；测量、放置以及 item/content 对齐由 Ebox 完成。可选 native backend 不支持 Grid 时会回退到 Elisp Ebox renderer。

## 4. 定义 Component

入门形式是无状态的 `:view` Component：

```elisp
(etaf-define-component status-label (&key label)
  "Render a status label."
  :view
  (text
   :font-weight 'bold
   (expr label)))

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
| `:view` | 声明式 View frontend，与 `:render` 互斥 |
| `:render` | 普通 Elisp frontend，通过 `etaf-node` 返回一个 typed View |
| `:setup` | 可选的一次性初始化，返回由 `etaf-state` 读取的 opaque 状态 |
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
    count)
  :view
  (column
   (text :font-weight 'bold (expr title))
   (text (expr (format "Count: %d" (etaf-value (etaf-state)))))
   (text
    :role 'button
    :on-press
    (let ((count (etaf-state)))
      (lambda () (cl-incf (etaf-value count))))
    "Increment")))
```

Setup 对 retained instance 只执行一次，返回一个 opaque 状态值。选定的 `:view` 或
`:render` frontend 在更新时运行，并通过 `etaf-state` 读取这个准确值。
`etaf-on-mounted`、`etaf-on-updated` 和 `etaf-on-unmounted` 注册该 Component 的生命周期
callback。Scope 释放时会自动停止响应式 effect 并运行 cleanup。

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
   (text :font-weight 'bold (expr title))
   (slot (text :color "#687386" "No content"))))

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
         (text :font-weight 'bold (expr title)))
   (slot (text :color "#687386" "No body"))))

(etaf-view
 (card
  :title "Account"
  (slot :name 'header (text "Account settings"))
  (text "Body")))
```

默认 slot 的两个用户简写是 `(slot)` 和 `(slot FALLBACK...)`。内部统一形式是 `(slot :name 'default FALLBACK...)`。调用处的普通子节点填充 `default`；命名内容写成 `(slot :name 'header CHILD...)`。显式空的 `(slot :name 'header)` 会抑制 fallback。字符串、数字、变量和运行时表达式都不是合法 slot name。

在结构边界，`expr` 可以返回 typed View 或 typed View 的 proper sequence，但它不暴露、
也不接受 ETAF 私有 struct。同一个 Component 可以组合 keyed `:for`、结构表达式和
命名 footer slot：

```elisp
(etaf-define-component etaf-docs-collection-card (&key items footer-view)
  "Render keyed rows, one dynamic typed View, and a footer slot."
  :view
  (column
   (row :for (item items) :key (car item)
    (text (expr (cdr item))))
   (expr footer-view)
   (slot :name 'footer (text "No footer"))))
```

## 7. 样式与 Theme

静态 Component 样式只有一种声明形式：

```elisp
(etaf-define-component styled-card ()
  "Render a small styled card."
  :styles
  (styles
   ("&"
    :padding (1 2)
    :border (1 solid "#687386"))
   (".title" :font-weight bold)
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

在同一个 Component 样式作用域内，第一条匹配声明会填充尚未指定的 Host
属性；后续规则不会覆盖已经解析出的默认值。非 nil 的 Host 属性始终受
保护，nil Host 属性按省略处理，可以接收 Component 或 Theme 默认值。若
variant 需要明确覆盖，应使用显式 Host 属性或不同的属性键。

样式作用域归属于创建 View node 的 Component。父组件规则不会进入嵌套 Component 的内部；调用者通过 slot 提供的内容保留 caller scope，Component 自己定义的 slot fallback 保留 child scope。

Theme 是 Context 的便捷形式，不是另一个 Runtime 对象：

```elisp
(etaf-define-component themed-shell ()
  "Provide default text colors to a subtree."
  :setup
  (etaf-theme-provide
   '(:color "#F4F6FB" :bgcolor "#202634"))
  :view (slot))
```

如果应用有亮/暗两套 palette，应把语义 role 集中放在一份 palette plist 中，
再显式调用 `(etaf-theme-resolve-palette palette 'light)` 或 `'dark`。这样应用的
Theme toggle 不依赖 Emacs frame。可选的 `etaf-theme-tp` adapter 可以把 TP 的
palette registry 转换为同一份 ETAF Theme contract；`etaf-ui` 和 core Runtime
都不依赖 TP palette 名称。

静态 Component 样式可以用 `(etaf-theme-token :token-key)` 延迟读取继承的
Theme。ETAF 会在 lowering 样式作用域时解析它，使重复的 retained Host 复用静态
样式路径，而不是每个 Host 都携带一个动态 inline 属性。

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

Installer 需要 Runtime 或 Host path 时，可以调用 `etaf-current-behavior-context`。Behavior 被替换时，旧 cleanup 会在新状态成为当前状态前运行。Behavior equality 对 function 和 reactive value 使用 `eq`；因此新建的 installer closure 会被视为有意替换，而不是错误复用。替换状态先以 mounted resource registry 的 staged resource 保存，generation commit 后才成为 authority。

组合规则固定：Host callback 先于 Behavior callback，Behavior 按声明顺序运行，callback
error 会 short-circuit 剩余 callback。非事件属性先由 Host 获胜，否则由第一个
Behavior 获胜（first-wins）。重复 Behavior name 在 installer 前失败；稳定 installer 会复用，每个
已安装 cleanup exactly-once。dispatch 只命中准确 Host，不存在 capture 或 bubble。

Action name 使用 application/feature-prefixed symbol；重复 Action 注册默认报错。显式
reload 用 `etaf-action-redefine-run` 包住替换，它只改变未来按 name 的 dispatch，不会
flush 已挂载 Runtime。

Focus 和 hit testing 是 Runtime 操作：

```elisp
(let ((runtime (etaf-runtime-for-buffer "*etaf-status*")))
  (etaf-focus-next runtime)
  (etaf-activate runtime))
```

`etaf-host-ref-bounds` 和 `etaf-host-ref-position` 暴露公共的 Ebox hit-test 边界。`etaf-dispatch-event` 支持可选 payload 标记，用于给 callback 传入一个参数。

挂载后的 buffer 会自动启用 `etaf-input-mode`：`TAB` 聚焦下一个 Host，`Shift-TAB`/backtab 聚焦上一个 Host，`RET` 激活当前焦点 Host，`mouse-1` 在点击位置激活 Host。焦点顺序先按数字 `:tab-index`，相同 index 再按 live buffer position 稳定排序；移动焦点也会移动 point。卸载时会禁用该输入 mode。

## 9. Context / Provide / Inject

Context 适合跨多层共享依赖，不适合普通 label：

```elisp
(etaf-define-component application-shell ()
  "Provide a service to descendants."
  :setup
  (let ((service (etaf-ref "demo-service")))
    (etaf-provide 'service service)
    service)
  :view (slot))

(etaf-define-component service-label ()
  "Read the inherited service."
  :setup (etaf-inject 'service nil t)
  :view
  (text (expr (format "Service: %s" (etaf-value (etaf-state))))))

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

Controller 通过 `etaf-data-items`、`etaf-data-status`、`etaf-data-error`、`etaf-data-total`、`etaf-data-query`、`etaf-data-page`、`etaf-data-page-size` 和 `etaf-data-selection` 暴露响应式 ref。操作使用 `etaf-data-load`、`etaf-data-reload`、`etaf-data-mutate`、`etaf-data-set-query`、`etaf-data-next-page`、`etaf-data-previous-page`、`etaf-data-select`（追加式多选）、`etaf-data-select-one`（互斥单选）、`etaf-data-selected-item` 和 `etaf-data-stop`。当 Controller 的 `:auto-load` 为 nil 时，命令式的 next/previous 也会自动 reload；`:auto-load t` 时仍由 reactive effect 负责 reload，避免重复请求。

`etaf-data-selected-ref` 会为某个 row identity 返回稳定的 boolean ref；只有该
identity 进入或离开主 selection 时它才会变化，应用直接写
`etaf-data-selection` 时也一样。DataGrid 默认把这些 ref 与 keyed retained row
owner 配合使用，因此单选变化只会使旧行和新行失效，而不是整个可见页。
selection 由 Controller 外部拥有时，仍可使用自定义 `:row-selected-p`。稳定 identity
继续来自必选的 `:row-key`；DataGrid 没有第二个 selection-key prop。

`etaf-data-controller` 支持用于稳定选中行查找的 `:item-key`。在 Component
setup 中创建时，它的内部 effect Scope 会自动归当前 Component Scope 所有；如果
需要接入其他显式 owner，可以传入 `:owner-scope`。`etaf-data-mutate` 会在 reload
成功后返回 source 的变更结果，因此存储适配器可以直接暴露插入 id 或 changes，
不需要应用层再维护一条专用通道。

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

详情视图应使用 `(etaf-data-selected-item controller)`，不要在每个页面重复写
identity 匹配。source 可以返回类似 `(:operation insert :id 3 :changes 1
:value ...)` 的规范化变更 plist；ETAF 会在刷新 controller 的同时保留这个结果。

DataGrid 要求 `:row-key` 对每一行返回非 nil 的稳定标量。它通过普通 Host 和 slot 投影 loading、error、empty、header、rows 和 footer，不是第二种 data 或 Component 模型。

存储不绑定 SQLite。PostgreSQL、REST、文件或 ORM 集成都应该提供同样契约的具体 Data Source；它们是可选集成，不改变 ETAF 的用户模型。

独立的 `etaf-sqlite` 包是第一个具体存储 source：

```elisp
(require 'etaf-sqlite)

(let* ((table (etaf-sqlite-table
               'tasks
               (list (etaf-sqlite-column :id "id"
                                         :type 'integer :primary t)
                     (etaf-sqlite-column :title "title" :type 'text))
               :id))
       (database (etaf-sqlite-database "tasks.sqlite" table))
       (source (etaf-sqlite-source database)))
  (etaf-sqlite-initialize database)
  (let ((controller (etaf-data-controller source :auto-load t)))
    (etaf-data-mutate controller 'insert
                       '(:id 1 :title "Write the guide."))
    (message "%S" (etaf-value (etaf-data-items controller)))
    (etaf-data-stop controller)))
```

这个包使用 Emacs 内置 SQLite 能力，有意不增加 ORM 层。其他存储包应直接实现 `etaf-data-source`。

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

公共 View 语法只接受 Host 和 Component，不接受裸 Ebox Node。需要更低层端口的框架集成直接使用 Ebox typed TextNode 和 BoxNode constructor；应用 View 始终走普通 Host/Component lowering 路径。

## 12. Playgrounds

如果需要小型、可复制的 core 模式，可以加载 `examples/` 中的可执行应用：

```elisp
(add-to-list 'load-path "/path/to/github/etaf/examples")
(require 'etaf-counter-example)
(etaf-counter-example-open)
```

计数器示例演示保留式状态、computed 值、Event、Action 和可聚焦 Host。`etaf-data-example-open` 演示 mounted 后的 Data 加载、查询、选择、变更和显式 controller 释放。`etaf-resource-example-open` 演示延迟 Resource 加载、可见错误状态、reload cleanup 与 Scope 释放。每个示例要教授的所有权规则见 [`examples/README.zh-CN.md`](../examples/README.zh-CN.md)。

独立的 ETAF Playground 是一个完整的 ETAF 应用示例：

```elisp
(require 'etaf-playground)
(etaf-playground-open)
```

需要展示官方目录时：

```elisp
(etaf-playground-open-ui)
```

`etaf-playground-close` 会卸载并删除默认 Playground buffer。它与 `ebox-playground` 独立，核心 ETAF 不会自动加载任一 Playground。

独立的 Ebox Playground 用来展示底层布局契约：

```elisp
(require 'ebox-playground)
(ebox-playground-open)
```

它只依赖 Ebox。检查 Ebox Box 和 Grid 布局时使用它；检查 Component、Runtime、Data 和官方目录时使用 `etaf-playground`。

## 13. 性能记录

对任意应用负载启用通用记录器，然后打开普通的 `tabulated-list-mode` 面板：

```elisp
(require 'etaf-performance)
;; 在已挂载 ETAF Runtime 的 buffer 中：
(etaf-performance-mode 1)
(etaf-performance-show)
```

正式复现前执行 `M-x etaf-performance-clear`。复现后在面板按 `c`，或者执行
`M-x etaf-performance-copy-report`，可把环境、汇总、operation、GC 和阶段数据
完整复制到剪贴板；按 `w` 或执行 `M-x etaf-performance-export` 可导出 `.eld`
文件。报告和面板 header 还会显示电源来源、低功耗模式、native JIT 状态与系统
负载。这两种报告都可以直接发送给分析者。

记录器只消费 Runtime 的公共 observer 报告，不安装 advice。Runtime 的 Event、
Action、mount、flush 和 unmount 会创建有界 operation 记录；同一 operation 内，
Ebox、TP、Data、Resource 与 SQLite 可以贡献按 sequence 排列的 flat provider
阶段。阶段可能重叠，因此不声称 exclusive/self 时间；error 和 quit 会先被记录，
再保持原条件继续抛出。

`etaf-performance-summary` 只在请求时计算分组后的 p50/p95/max；
`etaf-performance-operation-stage-summary` 会按 provider category 汇总某条记录
中的 flat 阶段。`etaf-performance-records` 返回 operation/stage 的防御性快照，
调用方修改返回值不会影响保留的历史。

没有经过内置公共边界的应用操作可以使用
`etaf-performance-call-operation`/`etaf-performance-with-operation`；它们直接委托
同一个 Runtime operation 边界。采集结束后关闭 mode，只解除当前 Runtime 的
observer，不修改任何函数。

## 14. 公共 API 速查

| API 家族 | 主要入口 | 何时使用 |
| --- | --- | --- |
| View 与 Runtime | `etaf-view`、`etaf-render`、`etaf-mount`、`etaf-unmount`、`etaf-runtime-flush` | 构建、渲染、挂载或显式 flush 应用 |
| Component | `etaf-define-component`、`etaf-current-prop`、`etaf-current-slots`、`etaf-component-set-styles`、`etaf-component-redefine-run` | 复用 View、保留局部状态、设置 authoring 样式或显式重载代码 |
| 响应式状态 | `etaf-ref`、`etaf-value`、`etaf-set-value`、`etaf-computed` | 保存或派生状态 |
| 响应式 effect | `etaf-watch`、`etaf-watch-effect`、`etaf-effect-scope`、`etaf-scope-run` | 观察状态或同步外部资源 |
| 生命周期 | `etaf-on-mounted`、`etaf-on-updated`、`etaf-on-unmounted` | 绑定 Component 生命周期工作 |
| Context | `etaf-provide`、`etaf-inject`、`etaf-theme-provide`、`etaf-theme-token`、`etaf-theme-resolve-palette`、`etaf-theme-current-mode` | 跨层级共享依赖并解析语义 Theme palette |
| 事件与 focus | `etaf-dispatch-event`、`etaf-activate`、`etaf-focus`、`etaf-focus-next`、`etaf-focus-previous`、`etaf-input-mode` | 进入交互 Runtime |
| Action | `etaf-action-define`、`etaf-dispatch` | 命名和复用业务变更 |
| Behavior | `etaf-behavior-create`、`etaf-define-behavior`、`etaf-current-behavior-context`、`etaf-focusable`、`etaf-toggleable` | 复用非视觉交互 bundle |
| Data | `etaf-data-source`、`etaf-data-controller`、`etaf-data-memory-source`、`etaf-data-*` | 查询、分页、变更、选择、解析选中项和停止数据 |
| Resource | `etaf-resource`、`etaf-resource-result`、`etaf-error-boundary-run` | 管理 loader 状态和 cleanup |
| 官方 UI | `require 'etaf-ui`、`etaf-button`、`etaf-checkbox`、`etaf-number-input`、`etaf-label`、`etaf-panel`、`etaf-data-grid` | 使用现成 Component |
| Playground | `etaf-playground-open`、`etaf-playground-open-ui`、`etaf-playground-close`、`ebox-playground-open`、`ebox-playground-close` | 探索对应层 |
| 性能分析 | `etaf-performance-start`、`etaf-performance-stop`、`etaf-performance-mode`、`etaf-performance-show`、`etaf-performance-copy-report`、`etaf-performance-export`、`etaf-performance-environment-data`、`etaf-performance-records`、`etaf-performance-summary`、`etaf-performance-operation-stage-summary`、`etaf-performance-call-operation`、`etaf-performance-with-operation` | 通过公共 observer 定位通用 operation 的耗时并分享报告 |

大多数应用一开始只需要 `etaf-view`、`etaf-mount`、`etaf-define-component`、`etaf-ref` 和事件 callback。其余 API 都是可选能力，不是理解核心语法的前置条件。

## 15. 常见错误

- 所有属性必须放在第一个子节点之前。
- 使用 `:font-weight 'bold`，不要使用 `:font-weight :bold`；weight 是 Elisp symbol 值，不是属性 keyword。
- 结构性 View form 不要 quote。
- `if`、`when`、`let`、`mapcar` 或 Elisp 返回 typed View 时，使用 `(expr FORM)`。
- 默认 outlet 使用 `(slot)` 或 `(slot FALLBACK...)`；命名内容使用 `:name 'header`。
- 不要在 render 中写状态；使用事件、Action、watch callback 或 Effect。
- 产品级控件使用 `etaf-ui` Component；core Host 只是结构基础。
- owner 不再需要时，停止 Data Controller 并卸载 Runtime。

对于保留式更新，建议保持 pair 结构：`.etaf` 只放静态 shell，同名 `.el` companion
负责 state、Component 和 action。响应式写入会合并为一次 generation publication；
发布失败可以在同一旧状态上重试，non-converging effect 会报告错误，不会让界面
持续占用事件循环。
