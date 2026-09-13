# etaf Manual

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

Props accept `(&key NAME (NAME DEFAULT) ...)`. Missing inputs evaluate their
DEFAULT expression on first use by an instance; explicit nil is a supplied
value. Defaults are resolved in declaration order and may read earlier props.
A successful publication retains those default values until the instance is
replaced or unmounted, even if a caller temporarily supplies an override.
Failed candidates do not publish newly evaluated defaults. Default expressions
must be safe to retry and must not perform external writes; use setup for
owned resources. Construct mutable defaults with `list` or `vector` rather than
sharing a quoted object. Pure `etaf-render` has no retained instance and resolves
defaults anew on each call.

```elisp
(etaf-define-component titled-card (&key (title "Untitled"))
  :view (text (expr (or title "No title"))))
```

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
Declared props are lexical snapshots of each evaluation: a deferred callback
can directly use `title`, without an extra `let`. Successfully published updates
install callbacks with the new props; a rejected candidate preserves the old
callbacks. Setup closures retain initial props. A prop containing a ref keeps
that exact ref, so `etaf-value` in a callback reads its current value; ordinary
values are not deep-copied or made reactive.
Use ordinary `let`/`let*` to capture state handles for callbacks. `etaf-state`
is a render-time accessor, not an event-time accessor.
Keep reactive `etaf-value` reads inside the property or `expr` that needs the
update; extracting a handle does not require reading its value early. Component
code with retained closures belongs in an `.el` file with lexical binding.
Simple local callbacks need no Action definition.

For a computed value or watch created in setup to follow later inputs, obtain
an `etaf-prop` source during setup. Read it explicitly with `etaf-value`:

```elisp
(etaf-define-component greeting (&key (name "World"))
  :setup
  (let ((input (etaf-prop 'name)))
    (etaf-computed (lambda () (concat "Hello, " (etaf-value input)))))
  :view (text (expr (etaf-value (etaf-state)))))

(let ((name (etaf-ref "Ada")))
  (etaf-mount (get-buffer-create "*Greeting*")
              (etaf-view (greeting :name (etaf-value name))))
  (setf (etaf-value name) "Grace"))
```

The source is stable within its Component instance and includes resolved defaults.
It is read-only and shallow: mutating a supplied object in place does not notify
subscribers. Candidate rendering reads candidate inputs; later reads use committed
inputs. Watches receive changes after successful publication, so their callbacks
can inspect the updated buffer. An immediate watch still runs initially in setup.
A rejected update restores committed input and derived dependency tracking; it does
not undo writes to application refs. The Component owns the source and its setup
computations/watches; unmount stops them, and reading the prop source after disposal
signals an error. Plain setup prop variables continue to capture initial values.

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

Inside Component setup, effects and watches belong to the Component Scope and
stop automatically on unmount. Standalone integrations create a Scope with
`etaf-effect-scope`, enter it with `etaf-scope-run`, and release it in
`unwind-protect` with `etaf-scope-stop`. A parent owns its child scopes unless
`:detached t` is supplied. Detached scopes must be stopped by their caller.
Register external cleanup with `etaf-on-scope-dispose` inside an active scope.
Stopping first disables the scope, then stops children and effects and runs
cleanup in reverse registration order. Cleanup errors and quits are collected
and returned, so inspect that result if cleanup failures need reporting.
Repeated stop is harmless; entering or registering cleanup in a stopped scope
fails. These operations run outside View rendering.

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
                         (let* ((context (etaf-current-behavior-context))
                                (info (etaf-behavior-context-info context))
                                (target (plist-get info :host-ref)))
                           (message "Behavior installed for %S" target)
                           (lambda ()
                             (message "Behavior removed for %S" target))))))))
```

Pass `etaf-current-behavior-context` to `etaf-behavior-context-info` inside
an installer to obtain its Runtime, effective Host reference and semantic
installation properties. The context is an installation snapshot, not a live
Host lookup or proof of successful publication. It remains readable during and
after cleanup. Query committed properties with `etaf-runtime-host-props-for`
and the returned Runtime/reference after publication; do not use installation
facts to activate provisional input. The returned containers are fresh, while
contained values retain identity and must be treated as read-only.

Behavior equality keeps function and reactive-value identity with `eq`; a new
installer closure requests replacement. A stable specification and Host
reference reuse the installation even when unrelated Host properties change;
its context keeps the original installation facts. Replacement resources are
staged and become authoritative only when the generation commits. Old cleanup
runs after successful publication; rollback cleans the candidate and preserves
the old installation. Return cleanup from the installer for every acquired
resource, and release it on replacement, rollback or unmount. Behavior-owned
resources must not receive input from a candidate before publication.

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

Most Hosts need no explicit `:ref`: ETAF generates their identities. When a
reusable Component needs to address an internal Host, allocate an `etaf-local-ref`
in setup and pass the handle to `:ref`. Equal names reuse a handle within that
instance; separate instances may all name their internal button `button` safely.
Use a callback or prop to expose the handle deliberately:

```elisp
(etaf-define-component local-button (&key label on-ready on-press)
  :setup
  (let ((target (etaf-local-ref 'button)))
    (etaf-on-mounted (lambda () (funcall on-ready target)))
    target)
  :view
  (box :ref (etaf-state) :role 'button :tab-index 0 :on-press on-press
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

A list `:key` preserves the Component instance, including its local handles,
across reorder. The handle does not contain a business value. A failed candidate
keeps its committed Host target; removal makes bounds and position queries return
nil. Recreating a disposed Component allocates new handles even with the same key.
A handle must identify only one mounted Host. Explicit literal `:ref` symbols
remain application-wide addresses and must be unique within the Runtime.

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

Read a captured Resource loader failure with `(etaf-resource-error resource)`;
this returns condition data or nil directly and tracks Resource state. Data's
reader returns a ref instead: `(etaf-value (etaf-data-error controller))` reads
the captured Data failure. These readers do not signal the captured failure
again; treat their results as read-only. Data load operations can still signal
the original source error while recording it.

The same symbols also name error conditions for invalid Resource or Data
operations. Use `condition-case` to catch those operation failures; their names
do not change how the reader functions are called. For example, reloading a
disposed Resource signals `etaf-resource-error`. Loader failures are stored as
state, while cleanup/type errors remain visible. `etaf-error-boundary-run`
handles only errors raised by its function body:

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
(require 'etaf)
(etaf-counter-example-open)
```

The counter example demonstrates retained state, computed values, Events, Actions, and focusable Hosts. `etaf-data-example-open` demonstrates mounted Data loading, query, selection, mutation, and explicit controller disposal. `etaf-resource-example-open` demonstrates deferred Resource loading, visible error state, reload cleanup, and Scope disposal. See [`README.md`](../README.md) for the ownership rules each example is designed to teach.

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
(require 'etaf)
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
use [the GUI action measurement entry](../README.md)
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

## Example patterns

These examples are executable applications, not documentation fragments. They use only the public `etaf` facade and deliberately avoid `etaf-ui` so the core framework boundary remains independently runnable.

| Example | Public command | Practice demonstrated |
| --- | --- | --- |
| Retained counter | `M-x etaf-counter-example-open` | Component-owned refs, computed state, focusable Hosts, Event → Action → Runtime updates |
| Task controller | `M-x etaf-data-example-open` | Data Controller ownership, mounted loading, query, selection, mutation, and unmount cleanup |
| Resource health | `M-x etaf-resource-example-open` | Deferred Resource loading, visible error state, reload cleanup, and Scope disposal |

During checkout development, add Ebox, ETAF, and this directory to `load-path`:

```elisp
(add-to-list 'load-path "/path/to/github/ebox")
(add-to-list 'load-path "/path/to/github/etaf")
(add-to-list 'load-path "/path/to/github/etaf/examples")

(require 'etaf)
(etaf-counter-example-open)
```

Replace the feature and open command with `etaf-data-example` / `etaf-data-example-open` or `etaf-resource-example` / `etaf-resource-example-open` for the other applications. Every example has a corresponding `-close` command that unmounts its Runtime before killing the buffer.

## Why these are the preferred patterns

- Keep writes out of render functions. Events and Actions mutate refs or Data Controllers; rendering only reads state.
- Create owned services during Component setup, start state-changing work from `etaf-on-mounted`, and release detached controllers from `etaf-on-unmounted`.
- Let Resource Scope cleanup own loaded values. Do not catch loader errors and invent plausible defaults; render the Resource error state explicitly.
- Use stable Host refs, semantic roles, and `etaf-focusable` so the same installed event path works for keyboard integration and tests.
- Keep examples compact and visually structured, but never introduce example-only rendering APIs or private `etaf--*` / `ebox--*` calls.

Run `make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs` from the repository root. The gate byte-compiles these files, checks their docstrings and public boundaries, and drives their mounted interaction paths.


## GUI verification tools

For an already running Emacs, use its existing server through `emacsclient`.
Load the checkout and call the example entry point in an explicit buffer, show
that buffer in the existing graphical frame, and capture only that owned
window. Preserve the user's font and chrome. Do not start another daemon or
frame for this workflow. Preserve application focus so the user can keep working
in other apps. The `emacsclient-render-capture` skill supplies buffer selection
without activation and before/after target guards.

This directory also owns reusable verification mechanisms; application
scenarios live in their respective example repositories:

- `emacs-gui-verifier.el` defines `Scenario`, ordered `Action`, run-local
  `Context`, checkpoint sequencing, assertions, completion, and fail-closed
  evidence finalization. Its `etaf-gui-verifier-measure-action` entry records
  callback wall/CPU/GC time and GUI conditions without taking application focus.
- `benchmark-ebox-resize.el` drives continuous pixel-width sweeps of any
  existing mounted Ebox buffer, including ETAF apps, without taking over its
  observer. See the existing-server entry below.
- The legacy isolated runner `run-emacs-gui-verification.sh` owns one named daemon, explicit load paths,
  external application activation, recorder lifecycle, driver loading, report
  generation, and exact cleanup.
- `record-emacs-window.swift` uses macOS 15 ScreenCaptureKit to record only the
  frame owned by the supplied Emacs PID. It follows replacement window IDs and
  rejects changed pixel mappings. Its desktop-independent window filter works
  without activating Emacs. Its canvas is fixed at recording start:
  when the scenario includes resize, prepare the largest tested frame before
  starting the recorder. Smaller windows retain native pixels with padding;
  a window larger than the original canvas invalidates the recording.
- `capture-emacs-window.sh` supplies window-only checkpoint screenshots and
  rejects missing, ambiguous, or changing frame identities without activating
  Emacs. The runner compiles
  the video helper using the system Swift compiler; no package install is needed.

Concrete repositories provide adapter files that construct a Scenario and an
entry function. They can run through the existing server. The following command
instead starts the legacy isolated environment; use it only when that separate
environment is explicitly intended:

```sh
scripts/run-emacs-gui-verification.sh run ADAPTER.el ENTRY \
  --load-path /path/to/provider \
  --run-dir /private/tmp/my-gui-run
```

In that isolated runner, fresh captures remain `INCOMPLETE` until their selected images
and contact sheet are reviewed. Finalize the same evidence directory with:

```sh
scripts/run-emacs-gui-verification.sh review /private/tmp/my-gui-run
```

Only `VERDICT=PASS` completes that runner's evidence bundle. An existing-server
run reports its actual interaction assertions and inspected screenshots
separately. A failed recorder is never evidence of continuous capture, and
neither screenshots nor recording establish an operation latency bound.

For an existing server, take a background screenshot with the observed process ID:

```sh
ETAF_GUI_CAPTURE_PID=12345 scripts/capture-emacs-window.sh -x /tmp/app-checkpoint.png
```

Keep the target frame open and non-minimized. Validate a known content change in
before/after pixels to establish fresh background rendering. Hidden, minimized,
off-Space and locked-session behavior is not covered by this procedure. Background
Lisp callbacks and runtime timing do not require application activation; report
them as background measurements, separately from foreground input-to-display
latency. Use Emacs-local operations while another app is active, not global input.

## Measuring an existing GUI action

Reuse `etaf-gui-verifier-measure-action` with the adapter's Context and Action:

```elisp
;; Prepare the target control and fixture before entering the measured callback.
(etaf-gui-verifier-measure-action context action t)
(car (etaf-gui-verifier-context-measurements context))
```

The final `t` requires an already selected foreground target. It rejects a
background, hidden, unknown or wrong target before running the action, and
invalidates a sample if focus, target, font or geometry changes. It never raises
Emacs. Omit that argument for background functional work; those samples are
explicitly labeled and must not be reported as foreground latency.

Timing covers exactly `Action.execute`, excluding target inspection,
checkpoints and the verifier's intentional settle waits. Keep fixture setup,
control lookup and focus navigation outside an activation measurement. If the
chosen boundary includes an explicit `redisplay`, put that call in `execute`
and describe the boundary accordingly. Returning from redisplay still does not
prove compositor presentation. Each record says `presentation_measured=nil`.

Context retains every measurement, including first use, warmups, failures and
rejections. Failed callbacks retain their own timing and original condition;
rejections have no duration. Checkpoints export only the most recent record.
Report the full sample count and all-sample maximum as well as any explicitly
labeled steady-state statistics. Compare identical payload/page size, viewport,
loaded code, recording mode and foreground class; do not discard a slow group
because another run is faster. For provider traces, scope `etaf-performance-records` by its numeric observer
runtime ID, not buffer name, which can be reused after unmount. Pass the selected
records explicitly to summary/export functions: an empty selection stays empty.
Check operation IDs/counts as well as runtime ID when sampling the same mounted
instance again; the recorder's bounded history is not a per-run sample store.

## Continuous resize on the existing server

Use this entry for resize performance investigations.
First show the intended buffer in the user's existing foreground GUI frame.
Preserve its font and chrome. Compile changed product modules before loading
them; `make compile` in this repository also compiles the benchmark tool.

```sh
emacsclient --eval '(progn
  (load "/path/to/etaf/benchmarks/benchmark-ebox-resize.elc" nil t t)
  (ebox-resize-benchmark-start "*Your app*" 480 1400
    :step 32 :rounds 3 :output "/tmp/resize-run-1.eldata"))'
```

The bounds are outer-frame pixels. Every round goes from narrow to wide and
back, including both endpoints even when the step does not divide the range.
The last measured request returns to the initial width. Consecutive equal
widths are omitted because they request no resize; no warmup or slow sample is
dropped. The function returns immediately. Poll or cancel this owned run with:

```elisp
(ebox-resize-benchmark-status)
(ebox-resize-benchmark-cancel)
```

`:delay` (default 0.01 seconds) runs between completed publications;
`:timeout` (default 5 seconds) bounds startup, publication and final settling.
The tool waits for a preceding render's GC lease to end before recording the
baseline, and for its own run's lease to end before accepting the final result.
Unsupported sizes,
changed targets/focus/font/height, publication failures and cancellation produce
invalid/incomplete evidence. Advice and timers are removed on success, error,
quit and timeout. Failure leaves the last applied width; it does not fight a
user's subsequent window changes. No server, frame, application buffer, observer, profiler
or GC policy is created/replaced to make the benchmark pass.

Use a **new output path** each time. UTF-8 `.eldata` reports retain all requests,
all completed samples, actual published dimensions, node/text counts, GC,
per-operation CPU time, code origins and hashes. Optional `:phases '(FUNCTIONS…)`
records inclusive phase durations for loaded `ebox-`, `tp-` and `etaf-` provider
functions. The driver and outer publication boundary cannot be selected as
phases; nested durations must not be summed.
Publication timing ends when the real public Ebox viewport call returns.
Request→publication also includes event-loop delivery. Neither metric proves
compositor presentation, absence of flicker, or every interaction's correctness;
use the existing visual scenario/capture tools for those claims.

`:valid t` requires complete correctly attributed publication coverage.
`:within-limit t` additionally requires **every** request→publication sample to
meet `:limit-ms` (default 50). Inspect p95 **and** max, including GC samples.
Compare payload counts at matching widths before making speedup claims. A
different page size/content or loaded version is a different baseline.

Code origins and disk hashes alone cannot establish when a running function was
loaded. After recompilation, `:reload-files '("/checkout/ebox/ebox-viewport.elc" …)`
explicitly loads the chosen fresh bytecode before instrumentation. `:code`
contains every explicitly loaded file's canonical path, source/bytecode hashes
and load result, plus observed core function and benchmark driver origins;
matching origins are marked `:reloaded t`. Choose the affected modules; do not reload
application component declarations blindly. Without this option, report code
origin observations separately from independent evidence of a fresh GUI load.

Run the tool's regression checks with `make test`; they also
run in the full `make check` gate. Application-specific data setup and interaction
assertions remain in the example repositories, not this resize driver.

## Provider contracts

ETAF selects its renderer through the public [Ebox framework SPI](https://gitea.gklazycat.heiyu.space/geekinney/ebox/src/branch/main/docs/manual.md#framework-integration-contract). Ebox owns that interface contract; application Components use the ETAF View and lifecycle APIs documented here.
