# etaf 使用手册

ETAF 使用一套很小的词汇构建文本应用：`View`、`Component`、props、children、响应式状态和 Ebox 渲染。先学习 `etaf-view` 与 `etaf-mount`；需要局部句柄时增加 `:bindings`，生命周期工作放入 `:setup`。

## 1. 安装与加载

ETAF 依赖独立的 Ebox 包。开发时把核心检出目录放入 `load-path`，然后只加载 ETAF 的公共入口：

```elisp
(add-to-list 'load-path "/path/to/github/ecss")
(add-to-list 'load-path "/path/to/github/tp")
(add-to-list 'load-path "/path/to/github/ebox")
(add-to-list 'load-path "/path/to/github/etaf")
(require 'etaf)
```

这个入口会加载核心 View、Component、Runtime、reactive、Context、Data、Resource、事件、Behavior 和 Action API。`etaf-ui`、`etaf-db` 和两个 Playground 都是独立的可选包；加载 `etaf` 不会自动加载它们。

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

需要显式请求处理待办更新时，调用 `(etaf-runtime-flush runtime)`。
它现在返回 **Ebox 已提交 revision 整数**，不再返回旧版的 Ebox 节点。
Runtime 忙碌或仍处于批处理时，更新可能继续等待；返回值标识此刻读者可见的
发布版本。活动 Ebox/TP 事务内的调用会在请求更新之前报错，因为事务中的
revision 可能尚未提交。普通 flush 不导出整棵树，也不强制重建 Root。

需要当前树及其配套 source facts 时，显式获取快照：

```elisp
(let* ((runtime (etaf-runtime-for-buffer "*etaf-hello*"))
       (snapshot (etaf-runtime-snapshot runtime)))
  (list (plist-get snapshot :revision)
        (plist-get snapshot :mount-id)
        (ebox-render (plist-get snapshot :input))))
```

快照包含 `:input`（canonical Ebox input）、`:revision` 和 `:mount-id`
（本次挂载的身份）。导出成本为 O(N)，会分离节点的普通可变数据；它不处理
待办更新，不求值 Component，不发布，也不增加 revision。input 在后续提交或
卸载后仍可使用。callback 等不透明能力保持身份，查询不会冻结这些外部能力或
显示环境。对未挂载 Runtime 或在活动 Ebox/TP 事务内查询会报错。

已废弃的 `etaf-runtime-root-node` getter 通过上述 O(N) 查询保留读取兼容性，
返回当前唯一根节点；Runtime 不再保存根节点镜像。请迁移到
`etaf-runtime-snapshot`，保留 canonical input 中与根节点配套的 source facts；
不要再把旧 getter 当作低成本字段读取或写入目标。

当前 core 不直接加载 `.etaf`。`etaf-define-component` 是结构/样式/行为单元：用 View 定义结构，用 `:styles` 放静态 presentation，用 `:bindings` 管理保留值，用 `:setup` 管理生命周期。未来 `.etaf` SFC 属于把结果编译成同一套 Component 契约的 compiler layer，而不是第二个 Runtime 入口。

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

`expr` 只接受一个普通 Elisp form，不能有结构子节点。在结构子节点位置，返回值
可以是字符串、typed Host 或 Component View、这些值组成的 proper sequence 或 `nil`。
在 `text` Host 内，表达式必须返回字符串。`if`、`when`、`cond`、`let`、`mapcar` 和
`cl-loop` 仍是普通 Elisp。

quote 只有普通 Elisp 的含义：

- 结构性 View form 不要 quote。
- 字面量 symbol 和数据列表在 Elisp 需要时才 quote。
- Elisp 表达式需要构造 View 时，在其中使用 `(etaf-view ...)`。

例如 `'bold` 是 `:font-weight` 的 symbol 值，而 `'(text "data")` 只是数据，不会渲染。动态 View 必须写成 `(etaf-view (text "data"))`。

间距由布局 Host 决定：`row` 与 `column` 使用 `:item-gap`，例如
`(row :item-gap 1 ...)`；`flex` 与 `grid` 使用 `:gap`。切换 Host 时也要选择
对应的间距属性，两者不是可互换的 alias。例如将 `(row :gap 1 ...)` 改为
`(row :item-gap 1 ...)`。

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

Host 元数据也会传给共享的 Ebox/ECSS selector subject。`:class` 与 `:id` 使用
Ebox 归一化；非 nil 的 `:role` 和显式提供的每个 `:aria-*` 属性成为选择器属性。
值保留 Elisp 语义：ARIA nil 仍是存在的属性，按 ECSS 属性格式化规则与 `nil`
比较，t 与 `t` 比较。Ebox 从同一交互输入 `:disabled` 派生 `disabled` 状态，nil 移除状态。
这些事实随成功的响应式发布更新，失败候选保留旧事实。结构选择器使用渲染的
Host 树。`:selector-attributes` 与 `:selector-state` 是保留的适配事实，不是
View 属性；通过上述语义属性声明 Host 元数据。

```elisp
(ebox-selector-query-all
 (etaf-render
  (etaf-view
   (column :role 'group
     (text :role 'checkbox :disabled t :aria-checked nil "Option"))))
 "[role=group] > text[role=checkbox]:disabled[aria-checked=nil]")
;; Returns one matching Host handle.
```

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

调用时使用传给 `etaf-define-component` 的准确名称：

```elisp
(etaf-view (status-label :label "Connected"))
```

注册表不会自动生成 alias。定义为 `etaf-status-label` 的组件必须使用这个准确名称；上面的 `status-label` 是本节自己显式定义的名称。加载 `etaf-ui` 后，官方目录使用 `etaf-button`、`etaf-checkbox` 等准确名称。

定义宏只接受这些关键字：

| 关键字 | 作用 |
| --- | --- |
| `:view` | 声明式 View frontend，与 `:render` 互斥 |
| `:render` | 普通 Elisp 返回一个 typed View，通常使用 `etaf-view`；程序化构造也可使用 `etaf-node` |
| `:bindings` | 按顺序初始化一次的命名值，setup、View 与回调直接使用 |
| `:setup` | 可选的一次性生命周期工作；有命名绑定时忽略返回值 |
| `:styles` | 可选的静态作用域样式声明 |

没有单独的 children、slot、event 或 variant 声明块。业务 props 通过 `(&key ...)` 声明，children 和 slot 是隐式内容。

Props 支持 `(&key NAME (NAME DEFAULT) ...)`。实例首次缺少对应输入时求值
DEFAULT；显式 nil 属于已传入的值。默认值按声明顺序解析，表达式可读取前面的
props。成功发布后，实例保留默认值直到替换或卸载，期间调用方暂时传入覆盖值
不会丢弃默认值。失败候选不发布新求值的默认值，因此表达式必须可以重试，不能
执行外部写入；有清理需求的资源放在 setup 中。可变默认值用 `list` 或 `vector`
构造，不要共享引用的常量对象。纯 `etaf-render` 没有保留实例，每次调用重新
解析默认值。

```elisp
(etaf-define-component titled-card (&key (title "Untitled"))
  :view (text (expr (or title "No title"))))
```

## 5. 局部状态与生命周期

用 `:bindings` 声明稳定句柄，在 `:setup` 注册生命周期工作：

```elisp
(etaf-define-component counter (&key title)
  "Render a retained counter."
  :bindings ((count (etaf-ref 0))
             (initial-title title))
  :setup
  (progn
    (etaf-on-mounted (lambda () (message "%s mounted" initial-title)))
    (etaf-on-unmounted (lambda () (message "%s unmounted" initial-title))))
  :view
  (column
    (text :font-weight 'bold (expr title))
    (text (expr (format "Count: %d" (etaf-value count))))
    (text :role 'button :tab-index 0
          :on-press (lambda () (cl-incf (etaf-value count)))
      "Increment")))
```

`:bindings` 按 `let*` 顺序在每个保留实例中初始化一次，可引用初始 props 和前面的
绑定。名字不能重复或遮蔽声明的 prop。可选 `:setup` 在其后执行，两个视图入口和
回调直接引用保留值，不再需要打包和拆包。重排保留身份；失败的初始化、实例替换
及卸载按原有 Scope 生命周期清理 computed、watch、资源和局部引用。
`setq` 只改变当前词法变量，不替换实例保存的值；可变业务值应使用 ref。
`etaf-on-mounted`、`etaf-on-updated` 和 `etaf-on-unmounted` 注册实例生命周期回调。
有命名绑定时忽略 setup 的返回值，直接使用命名值，不能再调用 `etaf-state`。
进阶接口 `etaf-state` 仅用于没有命名绑定的组件，在渲染时读取其显式 setup
返回值（含 nil）。它不是事件时的接口。

`:view` 和 `:render` 共用编译、slot 投影与 prop 校验。声明的 props 是每次求值的
词法快照，延后执行的回调可直接使用 `title`，无需额外的 `let`。更新成功发布后
安装捕获新 props 的回调；候选失败保留旧回调。Setup 闭包保留初始 props。
传入的 ref 保留原有身份，在回调中通过 `etaf-value` 读取实时值；普通值不会
被深复制或自动变成响应式来源。把 `etaf-value` 保留在
需要更新的属性或 `expr` 内；提取句柄
不需要提前读取它的值。含有持久闭包的组件代码放在启用 lexical-binding 的 `.el`
文件中。简单本地回调不需要定义 Action。

若 setup 中创建的 computed 或 watch 需要跟随后续输入，在 setup 调用
`etaf-prop` 取得来源，再用 `etaf-value` 显式读取：

```elisp
(etaf-define-component greeting (&key (name "World"))
  :bindings ((input (etaf-prop 'name))
             (greeting (etaf-computed
                        (lambda () (concat "Hello, " (etaf-value input))))))
  :view (text (expr (etaf-value greeting))))

(let ((name (etaf-ref "Ada")))
  (etaf-mount (get-buffer-create "*Greeting*")
              (etaf-view (greeting :name (etaf-value name))))
  (setf (etaf-value name) "Grace"))
```

来源在组件实例内保持同一身份，包含解析后的默认值。它是只读、浅响应式的：
原地修改传入对象不会通知订阅者。候选渲染读取候选输入，其他时刻读取已提交
输入。watch 在成功发布后收到变化，回调可以查询更新后的 buffer；设置立即
执行的 watch 仍会在 setup 首次运行。更新失败恢复已提交输入及派生依赖，
不会撤销业务 ref 的写入。组件拥有来源及 setup 中的计算与 watch；卸载会
停止它们，释放后读取 prop 来源会报错。普通 setup prop 变量仍捕获初始值。

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

如果函数形式更清楚，可以使用 `etaf-set-value`。需要根据当前值生成新值时，
使用 `etaf-update-value` 和普通函数。列表、向量等采用替换更新；原地修改
对象不会通知订阅者。只复制需要修改的部分：

```elisp
(let ((task (etaf-ref '(:title "Draft" :done nil))))
  (etaf-update-value
   task (lambda (old done) (plist-put (copy-sequence old) :done done)) t)
  (etaf-value task))
```

更新函数执行一次，接收当前值与额外参数。它不得原地修改旧对象或执行外部
副作用。函数报错时 ref 保持原值；写入之后若渲染失败，业务值仍然保留，
与其他 ref 写入一致。在事件或普通应用代码中使用，不能在渲染中调用。
它沿用现有浅比较与批处理规则，不引入深层代理或自动复制。

`etaf-watch-effect` 用于响应式副作用，并且可以返回 cleanup：

```elisp
(etaf-watch-effect
 (lambda ()
   (message "Count is %s" (etaf-value count))
   (lambda () (message "Stop observing count"))))
```

Component setup 中的 effect 和 watch 由 Component Scope 持有，卸载时自动停止。
独立集成使用 `etaf-effect-scope` 创建、`etaf-scope-run` 进入 scope，并在
`unwind-protect` 中调用 `etaf-scope-stop` 释放。子 scope 默认由父 scope 持有；
`:detached t` 创建的独立 scope 必须由调用方停止。在活动 scope 内通过
`etaf-on-scope-dispose` 注册外部资源的清理函数。
停止时先使 scope 失效，再停止子 scope 和 effect，最后按注册的逆序运行清理。
清理中的 error 和 quit 会被收集并返回，不会中断其他清理；需要报告失败时检查
返回值。重复停止无副作用；停止后的 scope 不能再次进入或注册清理。这些操作
应在 View 渲染之外执行。

```elisp
(let ((scope (etaf-effect-scope :detached t))
      (count (etaf-ref 0)))
  (unwind-protect
      (etaf-scope-run
       scope
       (lambda ()
         (etaf-watch-effect
          (lambda () (message "Count: %s" (etaf-value count))))
         (etaf-on-scope-dispose (lambda () (message "Released")))
         (etaf-set-value count 1)))
    (when-let* ((errors (etaf-scope-stop scope)))
      (message "Scope cleanup conditions: %S" errors))))
```


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

Slot 中作者写下的表达式在整个投影子树中保留作者的 props、state 和 Context。
其中创建的 Component 仍有自己的 props、state、styles 和 Scope，其 Context 从
slot 作者环境继承。接收 slot 的 Component 不会把自己的 Context 注入调用者内容。
它自己定义的 fallback、普通子节点，以及产生 View 的 callback 使用接收方环境。
Table/Grid 的 cell callback 同样使用消费它的 Table/Grid 所在位置的 Context。

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

普通属性表达式可构造 ECSS 声明值。Box 布局配置与 outer display 由 Ebox 投影；
`ecss-important`、`ecss-wide-value` 和 `ecss-var` 值经过层叠计算后才进入布局。
响应式属性替换使用同一路径，无效候选保留已提交显示。静态 `.ecss` 数据不会因此
执行构造函数；依赖上下文的简写替换仍受 Ebox 已记录的限制约束。

```elisp
(require 'ecss)
(etaf-mount
 "*etaf-layout-values*"
 (etaf-view
  (flex :flex-direction (ecss-important 'column)
    (box "One")
    (box "Two"))))
```

静态 Component 样式只有一种声明形式：

```elisp
(etaf-define-component styled-card ()
  "Render a small styled card."
  :styles
  (("&"
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

`:styles` 字段直接接收静态有序规则列表，不加包装。每条规则是 `("SELECTOR" :PROPERTY VALUE...)`；`(1 2)` 和 `bold` 在样式中是数据，不需要 quote。普通 View 属性仍遵循 Elisp 规则，字面量列表通常需要 quote。

Theme token 声明在定义时校验属性事实，在上下文解析后校验实际值。未知属性
在安装前报错；解析出非法值时，Ebox schema 阻止发布。

Theme 默认值作为 ECSS UA 来源的作用域声明进入 Ebox。普通 author 属性覆盖
普通默认值；importance 和继承遵循 ECSS，包括 UA-important 高于 author-important。
响应式主题变化会重新发布默认声明，不会将其转换为行内属性。未知 Theme 键仍是
Context token。

Component 规则以 author 来源进入 Ebox，由 ECSS 处理 specificity、规则顺序、
importance、结构选择器、custom property 与继承。同等条件下后面的规则获胜。
普通行内声明高于普通组件规则；important 规则可以覆盖普通行内值。nil Host 属性
按省略处理。使用 `&` 或 `:scope` 匹配组件根，包括 fragment/forest 的每个根；
普通选择器只匹配严格后代。例如根 class 规则写作 `&.selected`，`.selected` 匹配
属于该组件的后代。

样式作用域归属于创建 View node 的 Component。父组件规则不会进入嵌套 Component 的内部；调用者通过 slot 提供的内容保留 caller scope，Component 自己定义的 slot fallback 保留 child scope。
`etaf-current-slot` 和 `etaf-current-slots` 返回保留 caller 归属的可组合 child 值。
可以传递、append 或包入 View children；将这些值视为 opaque，不检查内部表示。

Theme 是 Context 的便捷形式，不是另一个 Runtime 对象：

<!-- etaf-example: theme -->
```elisp
(require 'etaf)

(etaf-define-component themed-shell ()
  "Provide semantic colors to its own View."
  :setup
  (etaf-theme-provide
   '(:text-color "#F4F6FB" :surface-color "#202634"))
  :view
  (text :ref 'themed-content
        :color (etaf-theme-token :text-color)
        :background-color (etaf-theme-token :surface-color)
        "Themed content"))

(etaf-mount "*etaf-theme*" (etaf-view (themed-shell)))
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

原生主按钮按住期间会发布 `:active`。组件可在普通 `:styles` 规则中声明
`("&:active" :color "#ff0000")`。Ebox 负责产生状态并在响应式拖动更新中保持它，
释放时先清除状态再调用 `:on-press`。键盘激活与显式 dispatch 不产生按住状态。
完整语义见 [Ebox 原生交互](https://gitea.gklazycat.heiyu.space/geekinney/ebox/src/branch/main/docs/manual.zh-CN.md)。

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
                         (let* ((context (etaf-current-behavior-context))
                                (info (etaf-behavior-context-info context))
                                (target (plist-get info :host-ref)))
                           (message "Behavior installed for %S" target)
                           (lambda ()
                             (message "Behavior removed for %S" target))))))))
```

Installer 内将 `etaf-current-behavior-context` 交给 `etaf-behavior-context-info`，
即可查询 Runtime、实际 Host 引用和安装时的语义属性。上下文是安装快照，
不是实时 Host 查询，也不证明候选已经发布；清理期间及之后仍可读取。发布后
用返回的 Runtime/引用调用 `etaf-runtime-host-props-for` 查询已提交属性，不能
用候选安装信息提前激活输入。返回的容器是新建的，其中的值保持身份并应视为只读。

Behavior equality 对 function 和 reactive value 使用 `eq`，新 installer 闭包
表示替换。规格和 Host 引用稳定时，其他 Host 属性变化可以复用安装，其上下文
保留原安装信息。替换资源先暂存，generation 成功发布后才成为权威；旧 cleanup
在成功发布后运行，回滚只清理候选并保留旧安装。Installer 应为取得的每项资源
返回 cleanup，以便替换、回滚或卸载时释放；候选资源不得在发布前接收输入。

<a id="interaction-migration"></a>

根事件透传采用追加规则：内部业务 handler 最先运行（first），然后是由内到外
wrapper 附加的 callback，最后是按声明顺序运行的 Behavior。每个声明位置执行
一次。Checkbox 的 `:on-change` 仍先收到下一个布尔值，附加的 `:on-press`
观察回调随后运行。callback 报错会 short-circuit 剩余回调；UI 回滚不会撤销外部
业务写入。dispatch 只命中准确 Host，不存在 capture 或 bubble。

wrapper 的 `:use` 列表顺序连接，重复 Behavior name 在任何 installer 运行前报错。
非事件 Behavior 默认值仍由 Host 优先、其余 first-wins；`:disabled` 则取 OR。
每次更新都重新计算内外禁用输入：调用方可进一步禁用控件；解除外层禁用时，只有
内部也为 nil 才能启用。禁用 Host 的 `etaf-dispatch-event` 和 `etaf-focus` 会抛出
`etaf-event-error`。禁用时不安装输入 Behavior；提交禁用时清理已安装资源，重新启用
时再安装。

命中测试先选择最深的交互边界，再检查是否启用。点击禁用 cell 按钮不会激活父行，
即使按钮与行的 bounds 相同。普通非交互行文本仍可选择该行；显式聚焦行后也可触发
行动作。

迁移时注意：附加的根 `:on-*` 现在追加执行，不再覆盖原动作。需要不同业务动作时，
使用组件显式公开的业务 callback prop，或定义具有该行为的组件。透传属性不能把
已有的 `:role` 或 `:aria-checked` 等归组件所有的 aria 状态改成冲突值，否则报
Component 输入错误；有意提供语义变体时应公开业务 prop。调用方仍可覆盖
`:aria-label` 与 `:aria-description` 的可访问性文字。

Action name 使用 application/feature-prefixed symbol；重复 Action 注册默认报错。显式
reload 用 `etaf-action-redefine-run` 包住替换，它只改变未来按 name 的 dispatch，不会
flush 已挂载 Runtime。

Focus 和 hit testing 是 Runtime 操作：

```elisp
(let ((runtime (etaf-runtime-for-buffer "*etaf-status*")))
  (etaf-focus-next runtime)
  (etaf-activate runtime))
```

大多数 Host 无需显式 `:ref`，ETAF 会生成身份。可复用组件需要定位内部 Host
时，在 setup 调用 `etaf-local-ref`，把句柄传给 `:ref`。同一实例内同名调用
返回相同句柄；不同实例都可把内部按钮命名为 `button`，互不冲突。通过回调
或 prop 有意对外暴露句柄：

```elisp
(etaf-define-component local-button (&key label on-ready on-press)
  :bindings ((target (etaf-local-ref 'button)))
  :setup (etaf-on-mounted (lambda () (funcall on-ready target)))
  :view
  (box :ref target :role 'button :tab-index 0 :on-press on-press
    (text (expr label))))

(let (target)
  (let ((buffer
         (etaf-mount
          (get-buffer-create "*Local button*")
          (etaf-view
           (local-button :label "Run"
                         :on-ready (lambda (ref) (setq target ref))
                         :on-press (lambda () (message "Running")))))))
    (etaf-focus (etaf-runtime-for-buffer buffer) target)))
```

列表 `:key` 在重排时保留组件实例及其局部句柄；句柄不保存业务状态。候选
失败保留已提交 Host 目标，移除后 bounds/position 查询返回 nil。已释放的
组件重新创建时，即使 key 相同，也会得到新句柄。一个句柄只能指向一个已
挂载 Host。显式字面量 `:ref` 符号仍是应用地址，在同一 Runtime 内必须唯一。

`etaf-host-ref-bounds` 和 `etaf-host-ref-position` 暴露公共的 Ebox hit-test 边界。`etaf-dispatch-event` 支持可选 payload 标记，用于给 callback 传入一个参数。

启用的 press handler 以 Ebox 原生节点 keymap 发布，支持 RET、SPC 和主鼠标按键。
`ebox-activate` 与 Ebox 交互导航可以直接操作这些 Host。禁用或无回调控件发布显式
命中屏障，避免激活祖先。原生点击保留 point 和窗口选择，除非 handler 主动改变它们。
原生键盘激活在父子位置重合时仍尊重显式焦点。

Host 与组件根属性也支持 Ebox 的 `:help-echo`、`:pointer` 和 `:hover-style`。
例如，可为按钮或 Host 增加 `:pointer 'hand :help-echo "保存修改"
:hover-style '(:text-decoration-line underline)`。帮助值也可以是原生
`(window object position)` 函数，由 Emacs 在请求帮助时调用。悬停支持 Ebox 的颜色
与文本装饰绘制，几何仍使用普通样式。省略能力时继承，显式 nil 阻止继承；普通
非交互文本也可使用。这些能力遵循 Ebox 原生所有权，不产生 ETAF 悬停回调或
选择器状态。取值与绘制范围见 [Ebox 原生能力契约](https://gitea.gklazycat.heiyu.space/geekinney/ebox/src/branch/main/docs/manual.zh-CN.md#native-node-interaction)。

ETAF 把 `:tab-index` 与 `:disabled` 转为 Ebox 已提交的交互事实。`etaf-focus`、
`etaf-focused-host-ref` 以及前后导航操作同一个 Ebox buffer 焦点；直接调用
`ebox-focus` 的结果立即在 ETAF 中可见，反之亦然。Runtime 不保留焦点副本或独立导航表。
`etaf-focus` 省略 Host 引用时选择第一个有效停靠点，没有停靠点则保持原焦点；显式
无效或禁用目标仍抛出 `etaf-event-error`。组件 `:styles` 可以通过同一 Ebox cascade
匹配 `:focus`，例如 `("&:focus" :color "#ff0000")` 为获得焦点的组件根设置颜色。
焦点绘制与布局随已接受的响应式更新保持一致，纯渲染不带挂载焦点。规则让新请求的
目标不可访问时，焦点设置失败并保留旧画面。

焦点跟随 source identity 经过重排与已接受的布局变化。发布隐藏、禁用或删除会清空
焦点，后续导航从首个／末个有效停靠点开始。负值或缺失的 tab index 跳过导航，仍允许
显式焦点，也不会清空存续目标。point 仍在目标首个可见字符时才跟随布局；手动移开后，
Ebox 保留其数值位置并限制在可访问范围内。发布被拒绝时恢复焦点和 point。每个 buffer
有独立焦点，同一 buffer 的窗口共享它；操作不选择窗口。卸载释放共享焦点，详见
[Ebox 交互契约](https://gitea.gklazycat.heiyu.space/geekinney/ebox/src/branch/main/docs/manual.zh-CN.md#native-node-interaction)。

挂载 buffer 使用 Ebox 的 `ebox-buffer-mode` 提供 TAB 与 Shift-TAB/backtab 循环
导航、RET/return 激活。位置重合时，Ebox 为生成的激活绑定选择逻辑焦点；鼠标事件
使用点击目标。`etaf-activate` 委托给同一个 Ebox 入口，ETAF 只在应用事件批处理中
执行所选 Host 已提交的 handler。卸载释放 Ebox buffer 绑定。require Ebox 后可配置
`ebox-buffer-mode-map` 修改共享按键，不需要 ETAF 输入模式。

直接操纵界面时，在 Host 上声明 `:on-drag`，接收共享 Ebox 手势。每个阶段
单独进入普通响应式事件批处理：

```elisp
(etaf-define-component draggable-card ()
  :bindings ((x (etaf-ref 0)) (origin (etaf-ref 0)))
  :view
  (column :width '(ch 60)
   (box :position 'relative :left (list 'px (etaf-value x))
        :on-drag (lambda (gesture)
                   (pcase (plist-get gesture :phase)
                     ('start (setf (etaf-value origin) (etaf-value x)))
                     ((or 'move 'end)
                      (setf (etaf-value x)
                            (+ (etaf-value origin) (car (plist-get gesture :delta)))))))
        "水平拖动")
   (text (expr (format "X: %d" (etaf-value x))))))

(etaf-mount "*Draggable card*" (etaf-view (draggable-card)))
```

`origin` 是本次手势开始时的位置，Ebox 提供指针位移。移动与释放各自完成发布
后再读取输入。每个阶段使用当前已提交的 Host 回调；存续目标被禁用时可收到
最后的取消阶段，移除或卸载后不再调用应用回调。Ebox 管理目标保持、窗口坐标
和原生跟踪，ETAF 不保存这些事实。同时声明 `:on-press` 与 `:on-drag` 时，
press 处理键盘激活，drag 持有主鼠标按钮序列。字段和同一 GUI 窗口的支持边界
见 [Ebox 手势契约](https://gitea.gklazycat.heiyu.space/geekinney/ebox/src/branch/main/ebox.el)。

事件回调需要自定义原生输入时，使用 `etaf-call-with-input`。它把当前已提交
事件目标交给 Ebox 的输入边界，不要求应用查找 Runtime、维护存活标志或恢复焦点。

```elisp
(etaf-mount "*native-input*"
            (etaf-view
             (box :role 'button :tab-index 0
                  :on-press
                  (lambda ()
                    (message "已接受：%s"
                             (etaf-call-with-input (lambda () (read-string "标题：")))))
              "编辑标题")))
```

reader 管理原生编辑，调用返回后再应用结果。错误与 quit 继续传播；所属挂载
目标失效时 Ebox 取消结果，入口有效时恢复焦点。该接口需要活动 Host 事件，
不能在渲染时调用。UI TextInput、NumberInput 和 Select 共用此路径。详细所有权
见 [Ebox 原生交互契约](https://gitea.gklazycat.heiyu.space/geekinney/ebox/src/branch/main/docs/manual.md#native-node-interaction)。

## 9. Context / Provide / Inject

Context 适合跨多层共享依赖，不适合普通 label：

<!-- etaf-example: context -->
```elisp
(require 'etaf)

(etaf-define-component service-label ()
  "Read the inherited service."
  :bindings ((service (etaf-inject 'service nil t)))
  :view
  (text (expr (format "Service: %s" (etaf-value service)))))

(etaf-define-component application-shell ()
  "Provide a service to its own child Component."
  :setup
  (let ((service (etaf-ref "demo-service")))
    (etaf-provide 'service service)
    service)
  :view (service-label))

(etaf-mount
 "*etaf-context*"
 (etaf-view (application-shell)))
```

Context key 是稳定的普通 symbol，最近的祖先优先。`etaf-inject` 对可选依赖返回 default，对必需但缺失的依赖触发 `etaf-context-error`。注入的 ref 或 computed 保留自身响应式 identity。

迁移：在根位置编写的 slot 内容保留根的空 Context，其中的嵌套 Component 也
不会意外接收 slot 接收方的 provider 或 Theme。若消费者需要 provider 的
Context，应像上例一样写在 provider 自己的 View 中；需要外部定制时，可接收
普通的 View-producing callback 并在该位置调用。内容需要保留作者 Context 时
使用 slot。

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

适配已有数据源时，通过 `etaf-data-source-capabilities` 读取公开能力，替换需要
包装的回调，再构建一个数据源。例如，异步交付读取结果，同时保留内存源的写入
和身份规则：

```elisp
(let* ((capabilities (etaf-data-source-capabilities
                      (etaf-data-memory-source '((:id 1 :name "Ada")) :id-key :id)))
       (load (plist-get capabilities :load)))
  (setf (plist-get capabilities :load)
        (lambda (&rest args)
          (let ((result (apply load args)))
            (etaf-async
             (lambda (resolve _reject)
               (let ((timer (run-at-time 0.05 nil resolve result)))
                 (lambda () (cancel-timer timer))))))))
  (setq controller (etaf-data-controller (apply #'etaf-data-source capabilities))))
(etaf-data-load controller)
;; 完成后：(etaf-data-stop controller)
```

保留回调的代码使用 lexical binding。能力快照是独立的 plist，不是第二份存储或
另一个所有者。保留提供方的 dispose 回调，不要为原始源和适配源分别创建 Controller。
保持 v1/v2 写入结果契约；只有具备证据的提供方才能声明写入已回滚。

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

独立的 `etaf-db` 包为 ETAF 提供数据库后端，目前支持 SQLite，
使用明确的 `etaf-sqlite-*` 后端 API：

```elisp
(require 'etaf-db)

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

SQLite 后端使用 Emacs 内置 SQLite 能力。数据库后端提供既有的
`etaf-data-source` capability；ETAF DB 不增加第二套 Controller 或 ORM。
支持的存储流程见 [ETAF DB 手册](https://gitea.gklazycat.heiyu.space/geekinney/etaf-db/src/branch/main/docs/manual.zh-CN.md)。

## 11. Resource 与 raw Ebox

Resource 管理 Scope 所有的值及可选 cleanup。同步 loader 的用法如下：

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

Resource 与 Data 的 loader 可以返回 `etaf-async`，由框架启动原生定时器或进程。
它的启动函数接收 `resolve`、`reject`，返回 nil 或取消函数。成功时 resolve 普通
加载结果，失败时 reject Emacs condition 数据；每次操作只完成一次。框架使旧请求
失效、忽略重复完成，并在取消、超时和释放时移除 owner 回调。即使外部操作不能
取消，旧请求也不能重新发布。这是 loader 适配入口，不是独立 Promise。

```elisp
;;; -*- lexical-binding: t; -*-
(require 'etaf)
(etaf-define-component delayed-greeting ()
  :bindings
  ((resource
    (etaf-resource
     (lambda ()
       (etaf-async
        (lambda (resolve _reject)
          (let ((timer (run-at-time 0.2 nil resolve "Hello")))
            (lambda () (cancel-timer timer))))))
     :immediate nil :keep-value t :timeout 2)))
  :setup (etaf-on-mounted (lambda () (etaf-resource-load resource)))
  :view
  (column
    (text (expr (format "%s: %s" (etaf-resource-status resource)
                        (or (etaf-resource-value resource) "Waiting"))))
    (box :role 'button :tab-index 0
         :on-press (lambda () (etaf-resource-load resource)) "Reload")
    (box :role 'button :tab-index 0
         :on-press (lambda () (etaf-resource-cancel resource)) "Cancel")))
(etaf-mount "*delayed-greeting*" (etaf-view (delayed-greeting)))
```

延迟 Resource 初始为 `idle`，首次加载为 `loading`。`:keep-value t` 在 `refreshing`、
失败和取消后保留最近的成功值；不设置时，重载立即清空并释放旧值。成功替换和卸载
都会调用相应 cleanup；取消后首次晚到的结果也会被丢弃并清理。重载即显式重试。
`:timeout` 为 nil 或正数秒，只限制异步等待，不能中断阻塞 loader。取消记录
`etaf-async-cancelled`，超时记录 `etaf-async-timeout`，两者都不会释放 owner。

Data 的 `:load`、`:mutate`、`:mutate-v2` 使用同一适配器。加载 resolve 页面 plist。
Data 在刷新、读取失败或取消后保留已接受的集合，状态 ref 区分 `idle`、`loading`、
`refreshing`、`success`、`error`、`cancelled`。`etaf-data-cancel` 使当前请求失效；
`etaf-data-stop` 还释放数据源。每个 Controller 独占数据源生命周期；detached owner
必须显式释放。`etaf-data-source-load-page` 只接受同步结果，遇到异步描述时不启动操作
并抛出错误。

异步加载和写入尚未完成时返回 nil；视图观察状态 ref，再读取
`etaf-data-mutation-outcome`（读取本身也跟踪写入状态变化）。等待中的写入为 `:pending-p t`、`external-unknown`。
v1 成功结果代表 `committed`；v2 的 `:certainty` 为 `committed`、`rolled-back` 或
`external-unknown`，提交附带 `:result`，回滚附带 `:error` condition。取消、超时或
普通拒绝不证明外部写入回滚。等待写入时拒绝第二次写入；新的读取会替换当前请求，
其中被替换的等待中写入会记录为结果未知。

已知写入提交后，Data 自动刷新。同步写入可以返回结果，同时其异步刷新仍在等待。
刷新失败保留已提交事实；`etaf-data-retry-reconciliation` 只重试读取，
`etaf-data-reconciliation-state` 显示恢复状态。未知或回滚的写入不会自动重放：

```elisp
;; 在回调中使用已有 controller；视图同时观察它的 status ref：
(when (eq (plist-get (etaf-data-mutation-outcome controller) :certainty) 'committed)
  (etaf-data-retry-reconciliation controller))
```

同步 Data 数据源错误记录后向调用者抛出；异步数据源错误记录在状态中。渲染和发布错误
仍从完成回调抛出，适配器不能把它们重新解释成 IO 失败。卸载使完成回调失效，不代表
撤销已经发生的外部写入。

使用 `(etaf-resource-error resource)` 读取 Resource 捕获的 loader 错误，直接
返回 condition 数据或 nil，并跟踪 Resource 状态。Data 的读取函数返回 ref，
用 `(etaf-value (etaf-data-error controller))` 取得其中的错误。这些读取操作
不会重新抛出捕获的错误；返回值应视为只读。Data 加载操作本身仍可能在记录错误
后抛出原始数据源错误。

这两个符号同时也是无效 Resource/Data 操作的错误条件名。用 `condition-case`
捕获操作失败；这不改变同名读取函数的调用方式。例如重新加载已释放的 Resource
会抛出 `etaf-resource-error`。Loader 错误存入状态，cleanup/type 错误保持可见。
`etaf-error-boundary-run` 只处理它的 function body 抛出的错误：

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

Resource 示例的稳定 GUI 流程位于 `scripts/resource-gui-scenarios.el`。
在现有图形 Emacs 中将包的 `scripts/` 加入 `load-path`，require
`resource-gui-scenarios`，再调用 `(etaf-resource-gui-run "/tmp/resource-gui-run" t)`，
证据目录须未使用过。它通过原生 RET 操作，等待可见结果，保存截图及 `result.json`。
须检查截图；回调计时只覆盖请求启动，不包含异步完成发布或前台呈现延迟。

## 12. Playgrounds

如果需要小型、可复制的 core 模式，可以加载 `examples/` 中的可执行应用：

```elisp
(add-to-list 'load-path "/path/to/github/etaf/examples")
(require 'etaf)
(etaf-counter-example-open)
```

计数器示例演示保留式状态、computed 值、Event、Action 和可聚焦 Host。`etaf-data-example-open` 演示 mounted 后的 Data 加载、查询、选择、变更和显式 controller 释放。`etaf-resource-example-open` 演示原生异步加载、保留旧值刷新、取消、可见错误状态与 Scope 释放。每个示例要教授的所有权规则见 [`README.zh-CN.md`](../README.zh-CN.md)。

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
(require 'etaf)
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
该函数可选的数字 runtime ID 来自 observer 报告，可隔离 buffer 同名重建前后的
记录。summary/report 函数省略参数时读取全部历史，显式传入 `nil` 时保持空结果。
报告中的环境是导出时观测的状态，不是每次历史操作的状态。Runtime 耗时截至
同步调用返回，不能证明输入到画面呈现的延迟；逐次前后台、目标与回调 wall/CPU/GC
检查使用[GUI action 测量入口](../README.md)。

没有经过内置公共边界的应用操作可以使用
`etaf-performance-call-operation`/`etaf-performance-with-operation`；它们直接委托
同一个 Runtime operation 边界。采集结束后关闭 mode，只解除当前 Runtime 的
observer，不修改任何函数。

## 14. 公共 API 速查

| API 家族 | 主要入口 | 何时使用 |
| --- | --- | --- |
| View 与 Runtime | `etaf-view`、`etaf-render`、`etaf-mount`、`etaf-unmount`、`etaf-runtime-flush`、`etaf-runtime-snapshot` | 构建、渲染、挂载、flush 或显式导出已提交应用 |
| Component | `etaf-define-component`、`etaf-current-prop`、`etaf-current-slots`、`etaf-component-set-styles`、`etaf-component-redefine-run` | 复用 View、保留局部状态、设置 authoring 样式或显式重载代码 |
| 响应式状态 | `etaf-ref`、`etaf-value`、`etaf-set-value`、`etaf-computed` | 保存或派生状态 |
| 响应式 effect | `etaf-watch`、`etaf-watch-effect`、`etaf-effect-scope`、`etaf-scope-run` | 观察状态或同步外部资源 |
| 生命周期 | `etaf-on-mounted`、`etaf-on-updated`、`etaf-on-unmounted` | 绑定 Component 生命周期工作 |
| Context | `etaf-provide`、`etaf-inject`、`etaf-theme-provide`、`etaf-theme-token`、`etaf-theme-resolve-palette`、`etaf-theme-current-mode` | 跨层级共享依赖并解析语义 Theme palette |
| 事件与 focus | `etaf-dispatch-event`、`etaf-activate`、`etaf-focus`、`etaf-focus-next`、`etaf-focus-previous` | 进入交互 Runtime |
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

普通应用在启用 lexical-binding 的 `.el` 文件中定义并挂载 Component。可选的
Playground 使用 inert `.etaf` 结构与显式注册的 `.el` companion；core 不会自动
发现或执行这组文件。同一 batch 内的响应式写入合并为一次 generation publication；
发布失败可以重试，non-converging effect 会报告错误，不会持续占用事件循环。

## 示例组织

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

(require 'etaf)
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

## GUI 场景验收工具

`scripts/emacs-gui-verifier.el` 接受应用仓库提供的 Scenario 和 Action，
在已有 Emacs server 中依次执行动作、等待可观察结果并记录断言。
`etaf-gui-verifier-run` 直接写入 `manifest.jsonl`、窗口截图和原子更新的
`result.json`，不再依赖外部 skill 才能保存证据。加载检出目录中的引擎与
场景适配器后，通过定时器调用场景入口，让客户端请求及时返回；轮询新证据
目录中的 `result.json`，直到 `running` 变为 `passed` 或 `failed`。

断言为假、动作报错、等待超时或截图不可用都会失败；已有结果不会被覆盖。
`passed` 仅表示场景功能断言通过，`visual_review` 仍为 `required`，
`foreground_latency` 仍为 `not-certified`。检查失败检查点和实际截图，
不要用回调耗时或截图替代前台性能验收。

截图要求一个可见图形 frame、一个选中的目标 window，且没有活动 minibuffer。
工具保持应用焦点，截图期间目标变化会失败。`make check` 包含可移植的
`make tool-check` 场景与证据契约检查；macOS 上另运行 `make gui-tool-check`，
使用系统 Swift SDK 检查截图和录制命令。完整测量边界见[英文 GUI 指南](manual.md#measuring-an-existing-gui-action)。

## 提供方契约

ETAF 通过公共 [Ebox framework SPI](https://gitea.gklazycat.heiyu.space/geekinney/ebox/src/branch/main/docs/manual.zh-CN.md#框架集成契约) 选择渲染能力，该契约由 Ebox 维护。应用 Component 使用本手册中的 ETAF View 和生命周期 API。
