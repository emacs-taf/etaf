# ETAF User Guide

ETAF builds text applications from one small vocabulary: `View`, `Component`, props, children, reactive state, and Ebox rendering. Start with `etaf-view` and `etaf-mount`; add `:setup` only when a Component needs local state or lifecycle.

## 1. Install and load

ETAF depends on the independent Ebox package. During development, put the core checkouts on `load-path` and load the one public ETAF entry:

```elisp
(add-to-list 'load-path "/path/to/github/ecss")
(add-to-list 'load-path "/path/to/github/tp")
(add-to-list 'load-path "/path/to/github/ebox")
(add-to-list 'load-path "/path/to/github/etaf")
(require 'etaf)
```

The package entry loads the core View, Component, Runtime, reactive, Context, Data, Resource, event, Behavior, and Action APIs. `etaf-ui`, `etaf-sqlite`, and the two Playgrounds are independent optional packages; loading `etaf` does not load them.

## 2. The first View

Every structural form is:

```elisp
(NAME :property value ... child ...)
```

Properties come first and children come last. `etaf-view` receives an unquoted structural form:

```elisp
(etaf-view
 (column
  (text :font-weight 'bold "Hello")
  (text :color "#687386" "Welcome to ETAF")))
```

Mount it into an Emacs buffer:

```elisp
(etaf-mount
 "*etaf-hello*"
 (etaf-view
  (column
   (text :font-weight 'bold "Hello")
   (text "This is a text application."))))
```

`etaf-mount` returns the buffer. The same call replaces an existing Runtime mounted in that buffer after disposing it. To dispose it explicitly:

```elisp
(etaf-unmount (etaf-runtime-for-buffer "*etaf-hello*"))
```

Headless hosts or callers that already know the final layout context can pass
it with the optional third argument.  The first Ebox publication then uses
that viewport directly instead of immediately rerendering:

```elisp
(etaf-mount buffer view
            '(:viewport-width 1200 :viewport-height 48))
```

`etaf-render` is useful for pure, stateless rendering or tests:

```elisp
(ebox-render
 (etaf-render
  (etaf-view (text :font-weight 'bold "Pure View"))))
```

Use `etaf-mount` whenever a View contains a stateful Component, reactive data, events, or lifecycle.

To request pending work explicitly, call `(etaf-runtime-flush runtime)`.
Its return value is now the **integer committed Ebox revision**, replacing the
previous Ebox-node return type. Busy or batched work may remain pending; the
returned revision identifies the publication currently visible to readers.
Calls inside an active Ebox/TP transaction fail before requesting work, since
that transaction's revision may still be provisional. Ordinary flushes do not
export a tree or force a Root rebuild.

For a current tree and its matching source facts, request an explicit snapshot:

```elisp
(let* ((runtime (etaf-runtime-for-buffer "*etaf-hello*"))
       (snapshot (etaf-runtime-snapshot runtime)))
  (list (plist-get snapshot :revision)
        (plist-get snapshot :mount-id)
        (ebox-render (plist-get snapshot :input))))
```

The snapshot contains `:input` (a canonical Ebox input), `:revision`, and
`:mount-id` (the identity of this mount). Exporting costs O(N) and detaches
ordinary mutable node payload; it does not drain pending work, evaluate
Components, publish, or increment the revision. The input remains usable after
later commits or unmount. Opaque capabilities such as callbacks keep their
identity; the query does not freeze external capabilities or the display
environment. Unmounted Runtime and active Ebox/TP transaction queries fail.

The obsolete `etaf-runtime-root-node` getter remains read-compatible through
this O(N) query and returns the current single root. Runtime no longer stores a
root mirror. Migrate consumers to `etaf-runtime-snapshot` so the canonical input
retains the root's matching source facts; do not treat the obsolete getter as a
cheap field read or use it as a mutation target.

The current core has no direct `.etaf` loader. `etaf-define-component` is the structure/style/behavior unit: use its View for structure, `:styles` for static presentation, and `:setup` for retained state, Actions, and lifecycle. A future `.etaf` SFC belongs to a compiler layer that emits this same Component contract; it is not a second Runtime entry point.

## 3. Properties and children

Attribute values are ordinary Elisp expressions. They do not need an extra `expr` wrapper:

```elisp
(let ((dark t)
      (label "Theme"))
  (etaf-view
   (text
    :color (if dark "#F4F6FB" "#1F2328")
    :background-color "#20242B"
    (expr label))))
```

The child region is structural. `expr` is the one explicit bridge for ordinary Elisp computation:

```elisp
(etaf-view
 (column
  (expr (if loading "Loading..." "Ready"))
  (expr
   (when open
     (etaf-view (text :font-style 'italic "Details"))))))
```

`expr` accepts exactly one ordinary Elisp form and no structural children. Its
result in structural child positions can be a string, typed Host or Component
View, a proper sequence of these values, or `nil`. Inside a `text` Host an
expression must return a string.
`if`, `when`, `cond`, `let`, `mapcar`, and `cl-loop` remain normal Elisp.

Quote has one ordinary Elisp meaning:

- Do not quote structural View forms.
- Quote literal symbols and data lists when Elisp requires data.
- Use `(etaf-view ...)` inside an expression when the expression must construct a View.

For example, `'bold` is the `:font-weight` symbol, while `'(text "data")` is only data and will not render. A dynamic View must be written as `(etaf-view (text "data"))`.

Spacing follows the layout Host: `row` and `column` use `:item-gap`, for
example `(row :item-gap 1 ...)`; `flex` and `grid` use `:gap`. Changing the Host
also changes which spacing property to use; these are not interchangeable
aliases. For example, migrate `(row :gap 1 ...)` to `(row :item-gap 1 ...)`.

The core `grid` Host is the two-dimensional layout choice:

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

Use `auto`, `min-content`, `max-content`, `(fr FACTOR)`, `(minmax MIN MAX)`, and `(repeat COUNT TRACK-LIST)` in track templates. `:grid-auto-columns` and `:grid-auto-rows` size implicit tracks; `:grid-auto-flow` accepts `row` or `column`. Children may use `:grid-column`, `:grid-row`, `:grid-column-span`, and `:grid-row-span`; Ebox performs measurement, placement, and item/content alignment. The optional native backend falls back to the Elisp Ebox renderer for Grid trees.

## 4. Define a Component

The beginner form is a stateless `:view` Component:

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

Use the exact name supplied to `etaf-define-component`:

```elisp
(etaf-view (status-label :label "Connected"))
```

The registry creates no automatic aliases. A Component defined as `etaf-status-label` must be called by that exact name; the `status-label` above is the name explicitly defined in this guide. Official catalog names are `etaf-button`, `etaf-checkbox`, and so on, after requiring `etaf-ui`.

The definition macro accepts only these keywords:

| Keyword | Meaning |
| --- | --- |
| `:view` | Declarative View frontend; mutually exclusive with `:render` |
| `:render` | Ordinary Elisp returning one typed View, usually with `etaf-view`; programmatic builders may use `etaf-node` |
| `:setup` | Optional one-time initialization returning opaque state read with `etaf-state` |
| `:styles` | Optional static scoped style declaration |

There is no separate declaration block for children, slots, events, state, or variants. Props are declared with `(&key ...)`; children and slots are implicit content.

## 5. Local state and lifecycle

Use `:setup` when the Component owns local state:

```elisp
(etaf-define-component counter (&key title)
  "Render a retained counter."
  :setup
  (let ((count (etaf-ref 0))
        (initial-title title))
    (etaf-on-mounted
     (lambda () (message "%s mounted" initial-title)))
    (etaf-on-unmounted
     (lambda () (message "%s unmounted" initial-title)))
    count)
  :render
  (let ((count (etaf-state))
        (caption title))
    (etaf-view
     (column
       (text :font-weight 'bold (expr caption))
       (text (expr (format "Count: %d" (etaf-value count))))
       (text :role 'button :tab-index 0
             :on-press (lambda () (cl-incf (etaf-value count)))
         "Increment")))))
```

Setup runs once for the retained instance and returns one opaque state value.
The selected `:view` or `:render` frontend runs on each update and reads that
exact value with `etaf-state`. `etaf-on-mounted`, `etaf-on-updated`, and
`etaf-on-unmounted` register lifecycle callbacks for that Component instance.
Scope disposal automatically stops reactive effects and cleanup.

`:view` and `:render` share compilation, slot projection, and prop validation.
Use ordinary `let`/`let*` to capture state handles or current prop values for
callbacks. `etaf-state` is a render-time accessor, not an event-time accessor.
Keep reactive `etaf-value` reads inside the property or `expr` that needs the
update; extracting a handle does not require reading its value early. Component
code with retained closures belongs in an `.el` file with lexical binding.
Simple local callbacks need no Action definition.

The small reactive API is:

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

Use `etaf-set-value` when a function form is clearer than `setf`. `etaf-watch-effect` is for a reactive side effect and can return a cleanup function:

```elisp
(etaf-watch-effect
 (lambda ()
   (message "Count is %s" (etaf-value count))
   (lambda () (message "Stop observing count"))))
```

Inside Component setup, effects and watches belong to the Component Scope. Outside a Component, create a Scope explicitly with `etaf-effect-scope` and `etaf-scope-run`.

## 6. Children and slots

Trailing children are the anonymous/default slot:

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

Named slots use `:name` and must use a stable non-keyword symbol:

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

The two default-slot shorthands are `(slot)` and `(slot FALLBACK...)`. The normalized spelling is `(slot :name 'default FALLBACK...)`. At a call site, ordinary children fill `default`; a named input uses `(slot :name 'header CHILD...)`. An explicit empty `(slot :name 'header)` suppresses the fallback. Strings, numbers, variables, and runtime expressions are not valid slot names.

Slot expressions keep their author's props, state, and Context throughout the
projected subtree. Components created inside that subtree still own their own
props, state, styles, and Scope; they inherit Context from the slot author's
environment. A receiving Component does not inject its own Context into caller
content. Its fallback, ordinary children, and View-producing callbacks use its
own environment. A Table/Grid cell callback likewise runs in the consuming
Table/Grid's Context.

`expr` may return a typed View or a proper sequence of typed Views at a
structural boundary.  It never exposes or accepts ETAF's private structs.  The
same Component can combine a keyed `:for`, a structural expression, and a
named footer slot:

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

## 7. Styles and themes

Static Component styles use one declaration form:

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

The outer `styles` form is static Component metadata. Its rules have the shape `("SELECTOR" :PROPERTY VALUE...)`; values such as `(1 2)` and `bold` are style data and do not need quote. In an ordinary View attribute, values still follow Elisp rules, so a literal list would normally be quoted.

Precedence is fixed:

```text
explicit Host properties > Component :styles > inherited Theme defaults
```

Within one Component style scope, the first matching declaration fills an
unspecified Host property; later rules do not overwrite that resolved default.
A non-nil Host property remains protected, and a nil Host property is treated
as omitted and may receive the Component or Theme default. Use explicit Host
props or distinct properties when a variant needs a deliberate override.

Styles are scoped to the Component that authored a View node. A parent rule does not enter a nested Component's internals; content supplied through a caller slot keeps the caller scope, while a Component's own slot fallback keeps the child scope.

Theme is a Context convenience, not another runtime object:

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

For a light/dark application palette, keep the semantic roles in one palette
plist and resolve it explicitly with
`(etaf-theme-resolve-palette palette 'light)` or `'dark`. This keeps an app
Theme toggle independent from the Emacs frame. The optional `etaf-theme-tp`
adapter can translate TP palette registry entries into the same ETAF Theme
contract; `etaf-ui` and the core Runtime do not depend on TP palette names.

Static Component styles can defer one value to the inherited Theme with
`(etaf-theme-token :token-key)`. ETAF resolves that token while lowering the
style scope, so repeated retained Hosts can reuse the static style path rather
than each carrying a dynamic inline property.

## 8. Events, Actions, Behaviors, and focus

One local event uses an `:on-*` property:

```elisp
(text
 :ref 'save
 :role 'button
 :on-press (lambda () (message "Saved"))
 "Save")
```

The Runtime stores handlers by Host reference. Tests and integrations can dispatch directly:

```elisp
(let ((runtime (etaf-runtime-for-buffer "*etaf-status*")))
  (etaf-dispatch-event runtime 'save 'press))
```

Named business mutations use Actions:

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

The Action function receives Runtime first. `etaf-dispatch` must run inside a mounted Runtime or receive an explicit Runtime as its first argument.

Behaviors package reusable non-visual attributes and cleanup:

```elisp
(text
 :use (list (etaf-focusable))
 :role 'button
 "Focusable text")
```

Define application Behaviors with `etaf-define-behavior`; use a local `:on-*` callback when the interaction is used only once. `etaf-toggleable` is available for controlled value changes. A Behavior never becomes a visual node and never directly edits a buffer.

For a reusable installer, reserve `:install` for the cleanup-producing part of the Behavior:

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

The installer can call `etaf-current-behavior-context` when it needs the current Runtime or Host path. Replacing the Behavior runs the old cleanup before the new state becomes current. Behavior equality keeps function and reactive-value identity with `eq`; a newly-created installer closure is therefore a deliberate replacement, not an accidental reuse. The replacement is staged under the mounted resource registry and becomes authoritative only when its generation commits.

<a id="interaction-migration"></a>

Root event forwarding is additive: the internal business handler runs first,
then extra wrapper callbacks from inner to outer, then Behaviors in declaration
order. Each declaration runs once. For a Checkbox, `:on-change` still receives
the next boolean before an added `:on-press` observer. A callback error
short-circuits the remaining callbacks; UI rollback does not undo external
business writes. Dispatch targets one exact Host, with no capture or bubble.

Wrapper `:use` lists concatenate; duplicate Behavior names fail before any
installer runs. Non-event Behavior defaults retain first-wins order after Host
attributes, except `:disabled`, which combines with OR. Inner and outer disabled
inputs are recomputed on every update: callers can further disable a control,
and clearing the outer input enables it only when its inner input is also nil.
Disabled Hosts reject `etaf-dispatch-event` and `etaf-focus` with
`etaf-event-error`. Their input Behaviors are not installed; a committed disable
cleans up installed resources, and re-enabling installs them again.

Hit testing selects the deepest interaction boundary before checking whether
it is enabled. Clicking a disabled cell button does not activate its parent
row, including when their bounds coincide. Ordinary non-interactive row text
can still select the row; explicitly focusing the row can activate its action.

Migration: an extra root `:on-*` callback now appends instead of replacing the
existing action. To define a different business action, use the Component's
explicit business callback prop or define a Component with that behavior.
Fallthrough cannot change an existing `:role` or owned aria state such as
`:aria-checked` to a conflicting value; that signals a Component input error.
Expose an intentional semantic variation as a business prop. Caller-provided
`:aria-label` and `:aria-description` can still override accessible text.

Use application- or feature-prefixed Action names. Duplicate Action
registration is an error. During deliberate reload, wrap the replacement in
`etaf-action-redefine-run`; it changes future name-based dispatch without
flushing the mounted Runtime.

Focus and hit testing are Runtime operations:

```elisp
(let ((runtime (etaf-runtime-for-buffer "*etaf-status*")))
  (etaf-focus-next runtime)
  (etaf-activate runtime))
```

`etaf-host-ref-bounds` and `etaf-host-ref-position` expose the public Ebox hit-test boundary. `etaf-dispatch-event` accepts an optional payload flag when the callback needs one argument.

Mounted buffers enable `etaf-input-mode` automatically. `TAB` focuses the next Host, `Shift-TAB`/backtab focuses the previous Host, `RET` activates the focused Host, and `mouse-1` activates the Host at the click position. Focus ordering sorts numeric `:tab-index` first and uses live buffer position as the stable tie-breaker; moving focus also moves point to that Host. Unmounting disables the input mode.

## 9. Context / Provide / Inject

Use Context for a dependency shared across component depth, not for ordinary props:

<!-- etaf-example: context -->
```elisp
(require 'etaf)

(etaf-define-component service-label ()
  "Read the inherited service."
  :setup (etaf-inject 'service nil t)
  :view
  (text (expr (format "Service: %s" (etaf-value (etaf-state))))))

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

Context keys are ordinary stable symbols. The nearest ancestor wins. `etaf-inject` returns its default for an optional dependency and signals `etaf-context-error` for a required missing dependency. A provided ref or computed value keeps its reactive identity.

Migration: root-authored slot content retains the root's empty Context, including
nested Components. It no longer accidentally receives the slot receiver's
providers or Theme. Put a consumer in the provider's own View, as above, or
accept an ordinary View-producing callback and call it there when the consumer
must use the provider's Context. Use slots when content should retain its
author's Context.

## 10. Data Controllers and DataGrid

Data is included in ETAF core. A source implements the small source contract:

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

Official UI Components use the same controlled-prop model as user Components:

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

The Component emits the next value; the caller owns the ref and supplies the current value on the next render.

`:load` receives query and page parameters and returns a plist containing `:items`. `:mutate` and `:dispose` are optional. The built-in memory source is convenient for local applications:

```elisp
(setq source
      (etaf-data-memory-source
       '((:id 1 :name "Ada")
         (:id 2 :name "Grace"))
       :id-key :id))
(setq controller
      (etaf-data-controller source :page-size 10 :auto-load t))
```

The controller exposes reactive refs through `etaf-data-items`, `etaf-data-status`, `etaf-data-error`, `etaf-data-total`, `etaf-data-query`, `etaf-data-page`, `etaf-data-page-size`, and `etaf-data-selection`. Use `etaf-data-load`, `etaf-data-reload`, `etaf-data-mutate`, `etaf-data-set-query`, `etaf-data-next-page`, `etaf-data-previous-page`, `etaf-data-select` (additive multi-select), `etaf-data-select-one` (exclusive single-select), `etaf-data-selected-item`, and `etaf-data-stop` for operations. The imperative next/previous commands also reload a Controller whose `:auto-load` is nil; `:auto-load t` keeps reload ownership with the reactive effect.

`etaf-data-selected-ref` returns one stable boolean ref for a row identity.  It
updates only when that identity enters or leaves the main selection, including
when application code writes `etaf-data-selection` directly.  The default
DataGrid path uses these refs with keyed retained row owners, so a single-select
change invalidates the old and new rows rather than the complete visible page.
Custom `:row-selected-p` remains available when selection is owned outside the
Controller. Stable identity still comes from the required `:row-key`; there is
no second selection-key DataGrid prop.

`etaf-data-controller` accepts `:item-key` for stable selected-row lookup. When
created inside a Component setup, its internal effect Scope is owned by the
current Component Scope automatically; pass `:owner-scope` when integrating a
controller with another explicit owner. `etaf-data-mutate` returns the source
mutation result after the reload succeeds, so a storage adapter can expose an
inserted id or change count without another application-specific channel.

The official DataGrid is a normal Component:

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

For a selected record, use `(etaf-data-selected-item controller)` rather than
duplicating identity matching in every detail view. A source may return a
normalized mutation plist such as `(:operation insert :id 3 :changes 1
:value ...)`; ETAF preserves that value while it refreshes the controller.

DataGrid requires `:row-key` to return a non-nil stable scalar for every row. It projects loading, error, empty, header, rows, and footer through ordinary Hosts and slots. It is not a second data or Component model.

Storage is not tied to SQLite. A PostgreSQL, REST, file, or ORM integration should expose a concrete Data Source with the same contract. Such an integration is optional and does not change the ETAF user model.

The independent `etaf-sqlite` package is the first concrete storage source:

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

This package uses Emacs' built-in SQLite support and deliberately does not add an ORM layer. Other storage packages should implement `etaf-data-source` directly.

## 11. Resource and raw Ebox

Use a Resource for a Scope-owned synchronous loader:

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

Loader errors are stored in `etaf-resource-error`; cleanup/type errors remain visible. `etaf-error-boundary-run` handles only errors raised by its function body:

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

The public View grammar accepts Hosts and Components, not raw Ebox Nodes. Framework integrations that need the lower-level port use Ebox's typed TextNode and BoxNode constructors directly; application Views remain on the normal Host and Component lowering path.

## 12. Playgrounds

For small copyable core patterns, load one of the executable applications in `examples/`:

```elisp
(add-to-list 'load-path "/path/to/github/etaf/examples")
(require 'etaf-counter-example)
(etaf-counter-example-open)
```

The counter example demonstrates retained state, computed values, Events, Actions, and focusable Hosts. `etaf-data-example-open` demonstrates mounted Data loading, query, selection, mutation, and explicit controller disposal. `etaf-resource-example-open` demonstrates deferred Resource loading, visible error state, reload cleanup, and Scope disposal. See [`examples/README.md`](../examples/README.md) for the ownership rules each example is designed to teach.

The independent ETAF playground is a complete ETAF application example:

```elisp
(require 'etaf-playground)
(etaf-playground-open)
```

The core playground depends only on ETAF. To include the official catalog:

```elisp
(etaf-playground-open-ui)
```

`etaf-playground-close` unmounts and kills the default playground buffer. It is independent of `ebox-playground`; neither package is loaded by core ETAF.

The independent Ebox playground demonstrates the lower-level layout contract:

```elisp
(require 'ebox-playground)
(ebox-playground-open)
```

It depends only on Ebox. Use it when inspecting Ebox boxes and Grid layout; use `etaf-playground` when inspecting Components, Runtime, Data, and the official catalog.

## 13. Performance records

Enable the generic recorder around any application workload, then open its
ordinary `tabulated-list-mode` panel:

```elisp
(require 'etaf-performance)
;; In a buffer with a mounted ETAF Runtime:
(etaf-performance-mode 1)
(etaf-performance-show)
```

Run `M-x etaf-performance-clear` before the measured reproduction.  Afterwards,
press `c` in the panel, or run `M-x etaf-performance-copy-report`, to copy the
environment, summary, operation, GC, and stage data.  Press `w`, or run
`M-x etaf-performance-export`, to save the same portable report as an `.eld`
file.  The report and panel header include power source, low-power mode,
native-JIT state, and system load alongside the ordinary Emacs/display
environment.

The recorder only consumes public Runtime observer reports and installs no
advice.  Runtime Event, Action, mount, flush, and unmount boundaries create
bounded operation records.  Ebox, TP, Data, Resource, and SQLite may contribute
flat provider stages, ordered by sequence, inside the same operation.  Stages
may overlap and are therefore not reported as exclusive/self time; failures and
quits are recorded and then re-signaled unchanged.

`etaf-performance-summary` calculates grouped p50/p95/max statistics only when
requested.  `etaf-performance-operation-stage-summary` groups the flat stages
of one recorded operation by provider category.  `etaf-performance-records`
returns defensive operation and stage snapshots; caller mutation cannot alter
retained history.
Its optional numeric runtime ID selects the identity from observer reports,
including history from a retired mount whose buffer name has since been reused.
Summary and report functions read all retained records when their argument is
omitted; explicit `nil` keeps an empty selection empty. The report's environment
is observed at export time, not at every recorded operation. Runtime durations
end at synchronous return and do not certify input-to-presentation latency;
use [the GUI action measurement entry](../scripts/README.md#measuring-an-existing-gui-action)
to record per-action foreground/target conditions and callback wall/CPU/GC time.

Use `etaf-performance-call-operation` or `etaf-performance-with-operation` for
application work that does not enter through a built-in public boundary.  Both
delegate to the same Runtime operation boundary.  Disable the mode when the
capture is complete; this only detaches the Runtime observer and does not
rewrite any function.

## 14. Public API map

| API family | Main entry points | Use it when |
| --- | --- | --- |
| View and Runtime | `etaf-view`, `etaf-render`, `etaf-mount`, `etaf-unmount`, `etaf-runtime-flush`, `etaf-runtime-snapshot` | Build, render, mount, flush, or explicitly export the committed application |
| Components | `etaf-define-component`, `etaf-current-prop`, `etaf-current-slots`, `etaf-component-set-styles`, `etaf-component-redefine-run` | Share a View, retain local state, style an authoring surface, or deliberately reload code |
| Reactive state | `etaf-ref`, `etaf-value`, `etaf-set-value`, `etaf-computed` | Store or derive state |
| Reactive effects | `etaf-watch`, `etaf-watch-effect`, `etaf-effect-scope`, `etaf-scope-run` | Observe state or synchronize external resources |
| Lifecycle | `etaf-on-mounted`, `etaf-on-updated`, `etaf-on-unmounted` | Attach Component lifecycle work |
| Context | `etaf-provide`, `etaf-inject`, `etaf-theme-provide`, `etaf-theme-token`, `etaf-theme-resolve-palette`, `etaf-theme-current-mode` | Share ambient dependencies and resolve semantic Theme palettes |
| Events and focus | `etaf-dispatch-event`, `etaf-activate`, `etaf-focus`, `etaf-focus-next`, `etaf-focus-previous`, `etaf-input-mode` | Enter interactive Runtime behavior |
| Actions | `etaf-action-define`, `etaf-dispatch` | Name and reuse business mutations |
| Behaviors | `etaf-behavior-create`, `etaf-define-behavior`, `etaf-current-behavior-context`, `etaf-focusable`, `etaf-toggleable` | Reuse non-visual interaction bundles |
| Data | `etaf-data-source`, `etaf-data-controller`, `etaf-data-memory-source`, `etaf-data-*` | Query, paginate, mutate, select, resolve the selected item, and stop data |
| Resource | `etaf-resource`, `etaf-resource-result`, `etaf-error-boundary-run` | Own loader state and cleanup |
| Official UI | `require 'etaf-ui`, `etaf-button`, `etaf-checkbox`, `etaf-number-input`, `etaf-label`, `etaf-panel`, `etaf-data-grid` | Use ready-made Components |
| Playground | `etaf-playground-open`, `etaf-playground-open-ui`, `etaf-playground-close`, `ebox-playground-open`, `ebox-playground-close` | Explore the corresponding layer interactively |
| Performance | `etaf-performance-start`, `etaf-performance-stop`, `etaf-performance-mode`, `etaf-performance-show`, `etaf-performance-copy-report`, `etaf-performance-export`, `etaf-performance-environment-data`, `etaf-performance-records`, `etaf-performance-summary`, `etaf-performance-operation-stage-summary`, `etaf-performance-call-operation`, `etaf-performance-with-operation` | Attribute generic operation latency through public observers and share reports |

Most applications need only `etaf-view`, `etaf-mount`, `etaf-define-component`, `etaf-ref`, and event callbacks at first. The remaining APIs are additive capabilities, not prerequisites for understanding the core grammar.

## 15. Common mistakes

- Put every property before the first child.
- Use `:font-weight 'bold`, not `:font-weight :bold`; the weight is an Elisp symbol value, not a property keyword.
- Do not quote a structural View form.
- Use `(expr FORM)` for `if`, `when`, `let`, `mapcar`, or a typed View returned by ordinary Elisp.
- Use `(slot)` or `(slot FALLBACK...)` for the default outlet; use `:name 'header` for named slot content.
- Keep writes out of rendering; use an event, Action, watch callback, or Effect.
- Use `etaf-ui` Components for product controls; core Hosts are the structural foundation.
- Stop a Data Controller and unmount a Runtime when their owner is no longer needed.

Ordinary applications define and mount Components from lexical-binding `.el`
files. The optional Playground uses inert `.etaf` structure plus an explicitly
registered `.el` companion; core does not discover or execute that pair.
Reactive writes within a batch publish one generation. Failed publication is
retryable, and a non-converging effect is reported instead of keeping the UI busy.
