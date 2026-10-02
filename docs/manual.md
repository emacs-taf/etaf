# etaf Manual

ETAF builds text applications from one small vocabulary: `View`, `Component`, props, children, reactive state, and Ebox rendering. Start with `etaf-view` and `etaf-mount`; add `:bindings` for local handles and `:setup` for lifecycle work.

## 1. Install and load

ETAF depends on the independent Ebox package. During development, put the core checkouts on `load-path` and load the one public ETAF entry:

```elisp
(add-to-list 'load-path "/path/to/github/ecss")
(add-to-list 'load-path "/path/to/github/ebox")
(add-to-list 'load-path "/path/to/github/etaf")
(require 'etaf)
```

The package entry loads the core View, Component, Runtime, reactive, Context, Data, Resource, event, Behavior, and Action APIs. `etaf-ui`, `etaf-db`, and the two Playgrounds are independent optional packages; loading `etaf` does not load them.

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

### Native application windows

A native text application owns the window from which it opens.  After
`etaf-mount`, bind `display-buffer-overriding-action` to
`((display-buffer-same-window))` around `pop-to-buffer`; do not let a user's
`display-buffer` rules split the frame into a playground-style side pane.

Reserve one clear line at the top of the root View.  Count this padding as
chrome in page and row-budget constants; on a short window render fewer content
rows rather than clipping the first line.

To request pending work explicitly, call `(etaf-runtime-flush runtime)`.
Its return value is now the **integer committed Ebox revision**, replacing the
previous Ebox-node return type. Busy or batched work may remain pending; the
returned revision identifies the publication currently visible to readers.
Calls inside an active Ebox transaction fail before requesting work, since
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
environment. Unmounted Runtime and active Ebox transaction queries fail.

The obsolete `etaf-runtime-root-node` getter remains read-compatible through
this O(N) query and returns the current single root. Runtime no longer stores a
root mirror. Migrate consumers to `etaf-runtime-snapshot` so the canonical input
retains the root's matching source facts; do not treat the obsolete getter as a
cheap field read or use it as a mutation target.

The current core has no direct `.etaf` loader. `etaf-define-component` is the structure/style/behavior unit: use its View for structure, `:styles` for static presentation, and `:bindings` for retained values and `:setup` for lifecycle work. A future `.etaf` SFC belongs to a compiler layer that emits this same Component contract; it is not a second Runtime entry point.

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

Host metadata also feeds the shared Ebox/ECSS selector subjects. `:class` and
`:id` use Ebox normalization; a non-nil `:role` and every explicitly supplied
`:aria-*` property become selector attributes. Values retain their Elisp meaning:
ARIA nil remains present and compares as `nil`, and t compares as `t`, using ECSS's
normal attribute formatting. Ebox derives the `disabled` state from a true
`:disabled` interaction input; nil removes it. These facts follow successful reactive publication and remain unchanged
when a candidate fails. Structural selectors use the rendered Host tree.
`:selector-attributes` and `:selector-state` are reserved adapter facts, not View
properties. Use the semantic properties above to declare Host metadata.

```elisp
(ebox-selector-query-all
 (etaf-render
  (etaf-view
   (column :role 'group
     (text :role 'checkbox :disabled t :aria-checked nil "Option"))))
 "[role=group] > text[role=checkbox]:disabled[aria-checked=nil]")
;; Returns one matching Host handle.
```

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
| `:bindings` | Named values initialized once in order, accessible directly in setup, View and callbacks |
| `:setup` | Optional one-time lifecycle work; with named bindings its result is ignored |
| `:validate` | Optional ordinary Elisp checking resolved props before initialization or input publication |
| `:styles` | Optional static scoped style declaration |

There is no separate declaration block for children, slots, events, or variants. Props are declared with `(&key ...)`; children and slots are implicit content.

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

For component-specific input constraints, add an optional `:validate` form:

```elisp
(require 'etaf)
(etaf-define-component rated-label (&key (rating 0))
  :validate (etaf-check-prop :rating rating
                            (and (integerp rating) (<= 0 rating 5))
                            "an integer from 0 to 5")
  :view (text (expr (format "Rating: %s" rating))))

(etaf-mount "*Rating*" (etaf-view (rated-label :rating 3)))
```

Validation uses resolved lexical props on pure rendering, initial mount and
subsequent input evaluation. Keep it pure and safe to repeat; instance bindings,
state, slots and lifecycle are unavailable. Check passed reactive handles by
their public type here, keeping live value reads and value-dependent checks in
the rendering expressions that use them. Rejected updates retain published
inputs and callbacks; they do not undo the caller's business ref write.
`etaf-check-prop` reports the component, property, received value and expectation,
abbreviating large values. Ordinary helpers outside `:validate` supply its
optional component name explicitly. See the [public API](../etaf.el) for details.

## 5. Local state and lifecycle

Declare stable handles with `:bindings`, then register lifecycle work in `:setup`:

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

`:bindings` initializes once in `let*` order per retained instance, with access
to initial props and earlier bindings. Names cannot repeat or shadow declared
props. Optional `:setup` runs afterward; both View frontends and callbacks use
the retained values directly. Reorder keeps their identities. Failed initialization,
replacement and unmount dispose computed values, watches, resources and local
references through the existing Component Scope. `setq` changes only the current
lexical variable, not the stored instance value; use refs for mutable business state.
`etaf-on-mounted`, `etaf-on-updated`, and `etaf-on-unmounted` register instance hooks.
With named bindings, setup is initialization work and its return value is ignored.
The advanced `etaf-state` accessor is reserved for Components without named
bindings: it reads their explicit setup result (including nil) during rendering.
Ordinary application code should refer to bindings directly.

Lifecycle callbacks run inside their owning Runtime operation.  Use
`etaf-current-runtime` to obtain that owner and
`etaf-runtime-buffer` to address its mounted buffer; `current-buffer` may be
the caller's buffer when `etaf-mount` was given a buffer name.

`:view` and `:render` share compilation, slot projection, and prop validation.
Declared props are lexical snapshots of each evaluation: a deferred callback
can directly use `title`, without an extra `let`. Successfully published updates
install callbacks with the new props; a rejected candidate preserves the old
callbacks. Setup closures retain initial props. A prop containing a ref keeps
that exact ref, so `etaf-value` in a callback reads its current value; ordinary
values are not deep-copied or made reactive.
Business props and keyed list items use the same shallow equality rule as refs.
Replacing a list, vector, function or other object updates the retained child
even when the new object's contents compare equal. The key preserves the child's
state and focus; it does not preserve callbacks to an old input object. Mutating
an existing object in place does not notify dependents.
Keep reactive `etaf-value` reads inside the property or `expr` that needs the
update; extracting a handle does not require reading its value early. Component
code with retained closures belongs in an `.el` file with lexical binding.
Simple local callbacks need no Action definition.

For a computed value or watch created in setup to follow later inputs, obtain
an `etaf-prop` source during setup. Read it explicitly with `etaf-value`:

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

Computed values use the same shallow equality rule as refs; `:test` can supply
a different comparison, such as `equal` for a derived list. Before mounted
consumers render, their observed computed inputs settle. If every input keeps
its previous value, the existing publication and update lifecycle remain
unchanged. Computations without mounted or active observer demand remain lazy.
Getters reading ambient Context follow ordinary rendering to preserve Context
tracking. Capture an injected reactive source during setup and read that source
inside the getter when the computation only depends on its reactive value.
A getter or comparison failure preserves the displayed output and pending
Runtime work; after correcting the cause, `etaf-runtime-flush` retries it.

Use `etaf-set-value` when a function form is clearer than `setf`. To derive a
replacement from the current value, use `etaf-update-value` with an ordinary
function. For lists, vectors and records, return a replacement; mutating an
object in place does not notify subscribers. Copy only the parts you change:

```elisp
(let ((task (etaf-ref '(:title "Draft" :done nil))))
  (etaf-update-value
   task (lambda (old done) (plist-put (copy-sequence old) :done done)) t)
  (etaf-value task))
```

The updater runs once with the current value and any extra arguments. It must
not mutate the old object or perform external effects. An updater error leaves
the ref unchanged; a rendering failure after the write keeps the application
value, as other ref writes do. Use it in events or ordinary application code,
not during rendering. It uses the same shallow equality and batching rules.

Use `etaf-batch` when ordinary application code changes several related refs.
Existing watches and mounted Runtimes observe the completed batch; refs are
immediately readable inside it. Nested batches, including batches inside Event
or Action callbacks, join the outer scope. `etaf-call-with-batch` accepts a
zero-argument function for callers that already have a callback. Both return
the body's result after pending reactive work finishes.

```elisp
(let ((x (etaf-ref 0))
      (y (etaf-ref 0))
      observed)
  (let ((stop (etaf-watch
               (lambda () (list (etaf-value x) (etaf-value y)))
               (lambda (new _old) (setq observed new)))))
    (unwind-protect
        (progn
          (etaf-batch
            (etaf-set-value x 3)
            (etaf-set-value y 4))
          observed)                    ; => (3 4)
      (funcall stop))))
```

A batch groups notifications; it does not roll back application writes or
make publication across Runtimes atomic. If the body signals an error or quit,
pending reactive work still drains, then the original condition is re-signaled.
If the body succeeds and draining fails, the drain condition signals. Published
output follows each Runtime's normal failure and recovery contract. Call from
synchronous application code on the main Emacs event loop, outside rendering;
a later timer, process or other asynchronous callback needs its own batch.
The caller continues to own refs, watches and Runtime lifetimes.

`etaf-watch-effect` is for a reactive side effect and can return a cleanup function:

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

Use a `fragment` when a Component groups content without owning its layout:

```elisp
(etaf-define-component content-group ()
  :view (fragment (slot)))

(etaf-view
 (row
  (text "Left")
  (content-group (text "A") (text "B"))
  (text "Right")))
```

All four texts participate in the enclosing Row. Mounted Components preserve
this layout while retaining their children's state and identity. Programmatic
composition with `(etaf-node 'fragment nil (etaf-current-slot 'default))` has
the same behavior. Declare a Row, Column, Flex or Grid inside the Component
when it should own a layout container.

A Component can return nil, one View or a fragment on different renders.
Its bindings and Scope live until the Component itself is removed. A keyed
child keeps its state and focus while present in the same output group;
removing that child releases its instance. Returning nil removes the output
without unmounting the Component that produced it.

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

Ordinary property expressions can construct ECSS declaration values. Box layout
configuration and outer display are projected by Ebox; `ecss-important`,
`ecss-wide-value` and `ecss-var` values reach layout after cascade computation.
Reactive property replacements use the same path and invalid candidates preserve
the committed display. This does not execute constructors in static `.ecss` data.
Context-dependent shorthand substitution retains Ebox's documented limitations.

```elisp
(require 'ecss)
(etaf-mount
 "*etaf-layout-values*"
 (etaf-view
  (flex :flex-direction (ecss-important 'column)
    (box "One")
    (box "Two"))))
```

Static Component styles use one declaration form:

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

The `:styles` field is a static ordered rule list without a wrapper. Its rules have the shape `("SELECTOR" :PROPERTY VALUE...)`; values such as `(1 2)` and `bold` are style data and do not need quote. In an ordinary View attribute, values still follow Elisp rules, so a literal list would normally be quoted.

Theme token declarations validate property facts when defined and actual values
after contextual resolution. Unknown properties fail before installation; an
invalid resolved value fails publication through the Ebox schema.

Theme defaults are Ebox scope declarations at ECSS UA origin. Normal author
properties override normal defaults; importance and inheritance follow ECSS,
including UA-important declarations winning over author-important declarations.
Changing a reactive Theme republishes these defaults without converting them to
inline properties. Unknown Theme keys remain Context tokens.

Component rules enter Ebox at author origin. ECSS computes specificity, rule
order, importance, structural selectors, custom properties and inheritance.
Later rules win ties. Normal inline declarations outrank normal component rules;
important rules can override normal inline values. A nil Host property is omitted.
Use `&` or `:scope` for each component root, including every root of a fragment
or forest; ordinary selectors match strict descendants. For example, a root
class rule is `&.selected`, while `.selected` targets owned descendants.

Styles are scoped to the Component that authored a View node. A parent rule does not enter a nested Component's internals; content supplied through a caller slot keeps the caller scope, while a Component's own slot fallback keeps the child scope.
`etaf-current-slot` and `etaf-current-slots` return composable child values that
retain this caller ownership. Pass, append or wrap them as View children; treat
the values as opaque rather than inspecting their internal representation.

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
Theme toggle independent from the Emacs frame. The palette is ordinary
application-owned data; no global registry or renderer palette names are needed.
Pass the resolved Theme plist to `etaf-theme-provide`, including the `:ui-*`
tokens used by the UI catalog.

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

Native primary-button presses publish `:active` while held. Component styles
can declare `("&:active" :color "#ff0000")` alongside their ordinary rules.
Ebox owns the state and keeps it through reactive drag updates; release clears
it before `:on-press` runs. Keyboard activation and explicit dispatch do not
create held-pointer state. See [Ebox interaction semantics](https://gitea.gklazycat.heiyu.space/geekinney/ebox/src/branch/main/docs/manual.md#native-node-interaction).

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
business writes. `:on-press-capture` is an explicit ancestor hook: after a
target `press` callback succeeds, ETAF invokes capture hooks from the nearest
committed Host toward the root. It is intended for shell policies such as
raising a window when a nested control is pressed; ordinary `:on-press`
callbacks do not bubble implicitly. Inside a capture callback,
`(etaf-event-target-within-p 'panel)` tells whether the pressed Host is the
`panel` Host or one of its descendants, so a shell root can close an open
panel when the press landed anywhere else. A root `:on-press` covers presses
on its non-interactive surface; there the target is the root itself.

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

A list `:key` preserves the Component instance, including its local handles,
across reorder. The handle does not contain a business value. A failed candidate
keeps its committed Host target; removal makes bounds and position queries return
nil. Recreating a disposed Component allocates new handles even with the same key.
A handle must identify only one mounted Host. Explicit literal `:ref` symbols
remain application-wide addresses and must be unique within the Runtime.

`etaf-host-ref-bounds` and `etaf-host-ref-position` expose the public Ebox hit-test boundary. `etaf-dispatch-event` accepts an optional payload flag when the callback needs one argument.

Mounted enabled press handlers publish Ebox native node keymaps for RET, SPC
and primary mouse activation. `ebox-activate` and Ebox interaction navigation
can operate on these Hosts directly. Disabled or callbackless controls publish
an explicit hit barrier, so activation never falls through to an ancestor.
Native clicks preserve point and window selection unless the handler changes
them. Native keyboard activation retains an explicitly focused Host when its
position coincides with a nested child.

Hosts and Component root attributes also accept Ebox `:help-echo`, `:pointer`
and `:hover-style`. For example, add `:pointer 'hand :help-echo "Save changes"
:hover-style '(:text-decoration-line underline)` to a Button or Host.
A Host with a press or drag callback already defaults to the hand pointer, and
a `slider` with `:on-drag` to the horizontal drag pointer, so `:pointer` is only
needed to choose another shape or to request an explicit nil.
Help may be a native `(window object position)` function, which Emacs calls
when requesting help. Hover accepts Ebox color and text-decoration paint;
geometry remains ordinary style. Omitted capabilities inherit, while explicit
nil blocks inheritance. These capabilities work on non-activating text too.
They follow Ebox native ownership and do not add a hover callback or selector
state in ETAF. See the [Ebox native capability contract](https://gitea.gklazycat.heiyu.space/geekinney/ebox/src/branch/main/docs/manual.md#native-node-interaction) for values and painting boundaries.

ETAF lowers `:tab-index` and `:disabled` to Ebox's committed interaction facts.
`etaf-focus`, `etaf-focused-host-ref` and next/previous navigation operate Ebox's
single buffer focus; direct `ebox-focus` calls are immediately visible through
ETAF and vice versa. No Runtime focus copy or separate navigation list exists.
`(etaf-focus-within runtime panel)` selects the first eligible stop in a
panel's committed subtree. A third argument of 1 or -1 cycles forward or
backward inside it; zero queries whether current focus belongs to the panel.
Menus and dialogs can bind their navigation keys to this shared operation.
It installs no persistent trap and uses Ebox's painted visibility and identity.

Calling `etaf-focus` without a Host reference selects the first eligible stop,
leaving existing focus unchanged if none exists. Explicit invalid or disabled
Host targets still signal `etaf-event-error`. Component `:styles` can match
`:focus` through the same Ebox cascade, for example `("&:focus" :color "#ff0000")`
for a focused component root. Focus paint and layout follow accepted reactive
updates; pure rendering has no mounted focus. Rules that make a newly requested
focus target inaccessible reject the operation and preserve the old view.

Focus follows source identity through reorder and accepted layout changes.
Published hiding, disabling or removal clears focus; subsequent navigation
restarts at the first/last eligible stop. A negative or absent tab index skips
navigation but permits explicit focus and does not clear a surviving target.
Point follows layout only while it remains at the target's first visible
character. After manual movement, Ebox retains the numeric position clamped to
the accessible buffer. Publication rejection restores focus and point. Each
buffer has its own focus, shared by its windows; operations do not select one.
Unmount releases the shared focus. See the [Ebox interaction contract](https://gitea.gklazycat.heiyu.space/geekinney/ebox/src/branch/main/docs/manual.md#native-node-interaction).

Mounted buffers use Ebox's `ebox-buffer-mode` for TAB and Shift-TAB/backtab
cyclic navigation and RET/return activation. Ebox also chooses logical focus
for generated activation bindings at overlapping positions; mouse events use
the clicked target. `etaf-activate` delegates to the same Ebox entry. ETAF only
runs the chosen Host's committed handler within its application event batch.
Unmount releases Ebox's buffer bindings. Customize `ebox-buffer-mode-map`
after requiring Ebox to change shared bindings; no ETAF input mode is needed.

For direct manipulation, declare `:on-drag` on a Host. It receives the shared
Ebox gesture and runs once per phase in an ordinary reactive event batch:

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
        "Drag horizontally")
   (text (expr (format "X: %d" (etaf-value x))))))

(etaf-mount "*Draggable card*" (etaf-view (draggable-card)))
```

`origin` is the position captured when the gesture starts; Ebox supplies the
pointer displacement. Movement and release each publish before more input is
read. The currently committed Host handler receives each phase, including a
terminal cancellation when a retained target becomes disabled. Removed or
unmounted Hosts no longer receive application callbacks. Ebox owns target
retention, window coordinates and the native tracking loop; ETAF stores none
of those facts. With both `:on-press` and `:on-drag`, press handles keyboard
activation and drag owns the primary mouse sequence. See the
[Ebox gesture contract](https://gitea.gklazycat.heiyu.space/geekinney/ebox/src/branch/main/ebox.el)
for payload fields and the same-window GUI support boundary.

Reusable geometry Behaviors apply the same gesture to caller-owned reactive
values.  They are useful to UI components and applications that need a common
move or resize interaction while keeping window policy in the application:

```elisp
(etaf-define-component movable-panel ()
  :bindings ((x (etaf-ref 4)) (y (etaf-ref 2))
             (move (etaf-draggable
                    :x x :y y
                    :delta (lambda (gesture)
                             (let ((d (plist-get gesture :delta)))
                               (cons (car d)
                                     (/ (cdr d) (float (frame-char-height)))))))))
  :view
  (box :ref 'panel :position 'absolute
       :left (list 'px (etaf-value x))
       :top (list 'lh (etaf-value y))
       :use (list move)
       "Panel"))
```

`etaf-draggable` accepts `:x`, `:y`, and an optional `:axis` of `x`, `y`, or
`both`.  It writes the coordinate refs on move and end; cancellation leaves
the last accepted values.  `etaf-resizable` accepts `:width`, `:height`,
optional `:x`/`:y`, an `:edges` list of `left`, `right`, `top`, and `bottom`,
and numeric min/max constraints.  Left/top edges move the coordinate ref to
keep the opposite edge fixed.  Both constructors accept optional lifecycle
callbacks.  The optional `:delta` function converts the Ebox pixel delta into
the caller's units, which is useful for vertical line-based sizes.  Behavior
constructors only update refs; Ebox retains the gesture and ETAF publishes the
result through the normal incremental render path.  They do not implement
window ordering, maximize/minimize state, or desktop policy.

When an application stores all window facts in one aggregate record, use
`etaf-draggable-controlled` or `etaf-resizable-controlled`.  Their `read`
function returns the current geometry plist and `on-change` receives the next
detached plist; the Behavior keeps only the transient gesture origin.  This
avoids mirroring an application's `x/y/width/height` refs while preserving the
same edge constraints, cancellation and logical-unit delta conversion.

Keep reactive geometry reads in the Host property expressions that use them,
as in the `movable-panel` example. Mounting and ordinary publication prepare the
registered reactive primitive bindings before later input; unused computations
are not evaluated for preparation. Related geometry, color, background,
hover-content, class, border color, font weight, visibility and sole-expression
text changes can share one prepared publication. Use `etaf-batch` for related writes;
ordinary refs, computed values and View properties remain the authoring API.
ETAF manages the reusable execution plans. Unsupported geometry, changed
dependencies and structural changes retain the ordinary publication path.
A prepared Host binding publishes only when Ebox can address the Host in a
retained scene.  That scene is anchored at an absolutely positioned Host with
inline `left`/`top`/`z-index`; the changed Host must sit at or below the
anchor in the Ebox tree, and the chain between them must not pass another
absolutely positioned Host, because the first absolute ancestor is chosen as
the anchor.  A screen whose controls or rows should update in place therefore
belongs in a relative stage with absolutely positioned panels, and each fast
Host inside one of those panels; ordinary flex and box nesting below the
panel is fine, including a Component subtree.  The rendering Component must
not read the reactive source itself: pass the ref or computed object down as
a property and read it inside the Host expression.  A source read during the
Component render subscribes the render, so the write repaints the view and the
prepared binding is never reached.  Keep display-only state in separate
sources next to the aggregate state that drives structure.  A prepared
binding also needs a value whose declaration already exists in the published
source: an absent paint or visibility declaration (a background the Host
never set, say) cannot acquire a slot, so give the Host a concrete default
when it must switch between two values.  The first
publication that needs a panel's scene builds it (tens of milliseconds); each
later change in the same scene publishes prepared bindings, and an ordinary
publication of that buffer invalidates the scene, so a control that should
stay fast must not also write state the view renders.  A prepared publication
advances the committed generation without rebuilding a semantic candidate,
which is what an application benchmark can measure to tell it apart from the
fallback.  Hang the retained panels directly on the root plane, or on a plane
whose composition the ledger records: a canvas is prepared from those planes,
and an anchor below an intermediate flow plane that the ledger does not
record cannot be prepared once another canvas has published.  Keep the
anchors' flow ancestors as simple as the screen allows.
A reactive Theme does not block preparation: Theme tokens and component
style sources guard the binding by version, so a Host styled through
`etaf-theme-token` keeps its prepared geometry, paint and visibility
bindings; changing the Theme itself repaints through ordinary publication.
A `:color` or `:background-color` expression may return an `etaf-theme-token`
(for example an active/inactive accent): the prepared write publishes the
token's paint slot once ordinary publication has painted that token.
A Host property expression keeps its prepared binding only while it reads
the same reactive sources on every evaluation: read every source first, then
branch on the values, rather than letting `cond` or `and` short-circuit past
a source, because a dependency set that differs from the prepared one
falls back to ordinary publication.
Text may change width inside a fixed allocation admitted by
[Ebox's prepared-update contract](https://gitea.gklazycat.heiyu.space/geekinney/ebox/src/branch/main/ebox.el);
text or rich-text changes whose allocation and ownership cannot be proved use
ordinary publication. Known finite class values, border-color changes that keep
the same width/style, and normal/bold changes can participate when Ebox proves
their selector and measured geometry constraints. New class values and
unsupported paint changes retain ordinary publication. Class strings, symbols
and nested lists keep their ordinary meaning and their raw public Host value.
Inline and reactive native hover-content changes preserve Component update hooks,
which run once per successful publication after all members are visible.
Semantic Host properties and Ebox geometry commit together, and rejected values
leave the previous display queryable while application refs keep their writes.
Use `etaf-runtime-generation` or `etaf-runtime-flush` for committed revision
checks; the opaque current generation object can retain its identity during
geometry updates. Explicit `etaf-runtime-snapshot` exports remain detached.

Create these controlled Behaviors once in a retained `:bindings` owner (or in
another retained owner), and pass the resulting spec through the View.  Do not
construct one in `:render`: each render creates new callback closures, so the
runtime correctly treats it as a new Behavior lifecycle.  If a parent renders
after a move publishes geometry, that new spec has no active gesture origin and
the following move/end phase cannot continue the original gesture.  Stable
bindings keep the transient origin while the aggregate `read`/`on-change`
state remains application-owned.  This contract avoids global caches and
cannot safely be inferred from handler source or closure contents.

An application that owns aggregate geometry can use
`etaf-runtime-update-host-geometry` for a high-frequency display projection.
It takes a mounted Runtime, a committed ETAF Host reference, and Ebox geometry
facts such as `:left`, `:top`, `:width`, `:height`, and `:z-index`.  ETAF resolves
the Host's retained provider region and performs the typed incremental Ebox
publication; it does not implement drag policy or replace the caller's state.
Update the controlled state first and ensure the next ordinary ETAF render
supplies the same geometry.  A stale or removed Host can be recovered by the
caller's normal state publication path; invalid geometry signals
`etaf-runtime-error` without a partial update.
Use `etaf-runtime-update-host-geometries` with an alist when several Hosts,
such as the old and new focused windows, must change in one Ebox publication.
A single-Host update uses Ebox's retained prepared geometry and is the fast
path for repeated moves; it resolves the Host's Ebox region by the `:id`
string the caller published, so name it (`:id` mirrors `:ref`).  Multi-Host
updates fall back to the ordinary geometry batch.

```elisp
(etaf-runtime-update-host-geometry
 (etaf-runtime-for-buffer "*desktop*") 'panel
 :left '(px 24) :top '(lh 3) :width '(px 320) :height '(lh 12))
```

For custom native input inside an event callback, use `etaf-call-with-input`.
It supplies the current committed event target to Ebox's input boundary:

```elisp
(etaf-mount "*native-input*"
            (etaf-view
             (box :role 'button :tab-index 0
                  :on-press
                  (lambda ()
                    (message "Accepted: %s"
                             (etaf-call-with-input (lambda () (read-string "Title: ")))))
              "Edit title")))
```

The reader owns native editing; apply its result after return. Error and quit
propagate. Ebox cancels a result whose mounted target is no longer valid and
restores focus when possible. The function requires an active Host event and
cannot run while rendering; no Runtime lookup, manual focus flag or second
input registry is needed. UI TextInput, NumberInput and Select use this path.
See the [Ebox native interaction contract](https://gitea.gklazycat.heiyu.space/geekinney/ebox/src/branch/main/docs/manual.md#native-node-interaction).

## 9. Context / Provide / Inject

Use Context for a dependency shared across component depth, not for ordinary props:

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

To adapt an existing source, read its supported capabilities with
`etaf-data-source-capabilities`, replace the callbacks you need, and construct
one new source. For example, this adds native asynchronous delivery to reads
while retaining the memory source's mutation and identity behavior:

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
;; Later: (etaf-data-stop controller)
```

Use lexical binding for retained callbacks. The snapshot is a fresh plist, not
another store or a second owner. Keep the provider's disposal callback and do
not give the original and adapted source separate Controllers. Preserve v1/v2
mutation results; only a provider with evidence may declare a write rolled back.

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

The independent `etaf-db` package provides database backends for ETAF. SQLite
is the currently supported backend, using the explicit `etaf-sqlite-*` API:

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

The SQLite backend uses Emacs' built-in SQLite support. Database backends
produce the existing `etaf-data-source` capabilities; ETAF DB does not add a
second controller or ORM. See the [ETAF DB manual](https://gitea.gklazycat.heiyu.space/geekinney/etaf-db/src/branch/main/docs/manual.md)
for its supported storage workflow.

A list that changes slowly is better shown from a cache and revalidated in the
background.  `etaf-list-cache` owns that policy, so every application refreshes
the same way:

```elisp
(setq cache (etaf-list-cache-create :interval 120))
(etaf-list-cache-put cache :shelf rows total)
(etaf-list-cache-entry cache :shelf)       ; (:rows ROWS :total TOTAL :at TIME)
(etaf-list-cache-stale-p cache :shelf)     ; fresh for INTERVAL seconds
(etaf-list-cache-unchanged-p cache :shelf rows total)
(etaf-list-cache-arm cache
                     (lambda ()
                       (when-let* ((ready (etaf-list-cache-next cache '(:shelf :reading))))
                         (etaf-list-cache-set-busy cache t)
                         (load-list ready)))
                     :interval 15)
(etaf-list-cache-disarm cache)             ; when the session is disposed
```

Show the cached rows first, then compare a fresh reply and repaint only when
`etaf-list-cache-unchanged-p` says it differs.  `etaf-list-cache-next` returns
the stalest list, or one that was never loaded, one at a time, and stays quiet
inside the grace period after arming; pass an explicit INTERVAL when the
freshness belongs to the application's own configuration.

Report every load through the cache: `etaf-list-cache-note-success` after a
reply and `etaf-list-cache-note-failure` with the backend's error code after a
failure.  Failures then back off (the interval, then double, capped at the
cache's `max-backoff`) and a code that needs a human (`auth`, `blocked`) pauses
background refreshes until a load succeeds again.  When the backend offers a
version token, keep it with `(etaf-list-cache-put cache key rows total
:version token)`, send it with the next conditional request and answer a
not-modified reply with `etaf-list-cache-touch`, which refreshes the entry
without a repaint.

## 11. Resource and raw Ebox

Use a Resource for a Scope-owned value and optional cleanup. A synchronous loader remains simple:

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

Resource and Data loaders can return `etaf-async` to start native timer or process
work after the loader returns. Its start function receives `resolve` and `reject`,
and returns nil or a cancellation function. Resolve with the ordinary result;
reject with Emacs condition data. Complete each operation once. The framework
ignores obsolete or duplicate completion and releases owner callbacks on cancel,
timeout and disposal. An adapter without cancellation still cannot revive an old
request. This is a loader adapter, not a standalone promise.

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

A deferred Resource starts `idle`. First load uses `loading`; `:keep-value t`
retains the last successful value during `refreshing`, failure and cancellation.
Without that option reload clears and cleans the old value immediately. Success
replaces and cleans it; unmount cleans the last value. The first result arriving
after cancellation is discarded with its cleanup. Reload retries explicitly.
`:timeout` is nil or positive seconds of asynchronous waiting; it cannot interrupt
a blocking loader. Cancellation records `etaf-async-cancelled`, timeout records
`etaf-async-timeout`; neither disposes the owner.

The same adapter works in Data `:load`, `:mutate` and `:mutate-v2`. Resolve a load
with its page plist. Data retains accepted items while refreshing or after a failed
or cancelled read; its status ref distinguishes `idle`, `loading`, `refreshing`,
`success`, `error` and `cancelled`. `etaf-data-cancel` invalidates pending work;
`etaf-data-stop` also releases the source. Each Controller owns its source lifecycle.
Detached owners require explicit disposal. `etaf-data-source-load-page` only accepts
synchronous results and rejects an async descriptor without starting it.

Async loads and mutations return nil while pending: observe the status ref and
read `etaf-data-mutation-outcome`, which also tracks its own reactive changes.
A pending write reports `:pending-p t` with
`external-unknown` certainty. A v1 successful result means `committed`; v2 reports
`:certainty` as `committed`, `rolled-back` or `external-unknown`, with `:result` for
commit or `:error` condition data for rollback. Cancellation, timeout and generic
rejection do not prove rollback. A second pending write is rejected. A new read
supersedes the pending request, including a write, whose outcome becomes unknown.

After a known commit, Data refreshes automatically. A synchronous write can return
its result while an asynchronous refresh remains pending. Failed refresh preserves
the committed outcome; use `etaf-data-retry-reconciliation` to retry only the read,
and `etaf-data-reconciliation-state` to observe recovery. Unknown and rolled-back
writes are never automatically replayed. Example recovery:

```elisp
;; In a callback, using an existing controller whose view observes its status:
(when (eq (plist-get (etaf-data-mutation-outcome controller) :certainty) 'committed)
  (etaf-data-retry-reconciliation controller))
```

Synchronous Data source failures are recorded and signaled to their caller.
Asynchronous source failures are recorded; rendering/publication failures still
signal from the completion callback. Do not catch those failures in an adapter and
reinterpret them as IO errors. Unmount invalidates completion without pretending
that an external write was undone.

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

The Resource example has a repeatable GUI scenario in
`scripts/resource-gui-scenarios.el`. From the existing graphical Emacs, add the
package's `scripts/` directory to `load-path`, require `resource-gui-scenarios`,
and call `(etaf-resource-gui-run "/tmp/resource-gui-run" t)` with a fresh evidence
directory. It drives native RET, waits on visible postconditions and saves
screenshots plus `result.json`. Review the images. Its callback timings cover
request initiation, not asynchronous completion or foreground presentation.

## 12. Playgrounds

For small copyable core patterns, load one of the executable applications in `examples/`:

```elisp
(add-to-list 'load-path "/path/to/github/etaf/examples")
(require 'etaf)
(etaf-counter-example-open)
```

The counter example demonstrates retained state, computed values, Events, Actions, and focusable Hosts. `etaf-data-example-open` demonstrates mounted Data loading, query, selection, mutation, and explicit controller disposal. `etaf-resource-example-open` demonstrates native asynchronous loading, retained refresh, cancellation, visible error state and Scope disposal. See [`README.md`](../README.md) for the ownership rules each example is designed to teach.

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
bounded operation records.  Ebox rendering and publication, Data, Resource, and SQLite may contribute
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
For automated consumers, `etaf-performance-report-data` returns the portable
plist directly. Select the required operations by their runtime/buffer identity
without clearing unrelated recordings; keep overlapping provider totals separate.
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
| Events and focus | `etaf-dispatch-event`, `etaf-activate`, `etaf-focus`, `etaf-focus-next`, `etaf-focus-previous` | Enter interactive Runtime behavior |
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
- Centre a row's contents by justifying the row with those items as its direct
  children.  A nested Flex child fills the row's main axis, leaving the parent's
  `:justify-content` no free space to distribute, so a row that centres a bare
  box does not centre the same boxes wrapped in an extra `(flex ...)`; justify
  that wrapper instead, or drop it.

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
in other apps. The `emacs-agent-control` skill supplies buffer selection and
window-only captures without taking application focus; the engine's own
checkpoints keep the before/after target-buffer guards.

When verifying icon-heavy layouts or changing fonts, remember that `etaf-runtime-viewport` reports HEIGHT as the window line count, so applications lay out by rows.
A row's pixel height is the largest font box among its glyphs.
Missing glyphs can fall back from PragmataPro 16px through LXGW WenKai 16px to Sarasa Mono SC 18px or Arial Unicode MS 19px.
A text-style variation selector (U+FE0E) can pick a still taller fallback such as HanaMinA.
A bold symbol can select Sarasa Bold at 18px, and `line-height` can only increase that height.
A few tall rows make canvas pixels exceed the window and clip bottom content, such as a status bar.
Keep rows within `frame-char-height`: prefer CJK glyph icons (locally 16px in normal and bold), leave symbols unbolded, and avoid inline `:font-size`.
Check a real frame with `line-pixel-height`; scenarios assert it mechanically with `etaf-gui-verifier-line-height-assertions` and settle a resize with `etaf-gui-verifier-canvas-filled-p`.

This directory also owns reusable verification mechanisms; application
scenarios live in their respective example repositories:

- `emacs-gui-verifier.el` defines `Scenario`, ordered `Action`, run-local
  `Context`, checkpoint sequencing, assertions, completion, and fail-closed
  evidence writing. `etaf-gui-verifier-run` writes `manifest.jsonl`, window
  screenshots and an atomic `result.json` directly, without a skill dependency.
  False assertions, callback errors, unsettled actions and unavailable captures
  fail the run; an existing manifest or result is never overwritten. A `passed`
  result means the scenario's functional assertions passed: its `visual_review`
  remains `required` and `foreground_latency` remains `not-certified`.
  Its `etaf-gui-verifier-measure-action` entry records
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
entry function. They can run through the existing server. Load the engine and
adapter from their checkout, then schedule the adapter's entry on a timer;
this lets the client request return while the scenario yields between actions.
Poll the fresh directory's `result.json` for `running`, `passed` or `failed`,
then inspect failed checkpoints and the saved images. Screenshot actions require
one visible graphical frame and one selected target window, with no active
minibuffer. They preserve application focus and reject a target change during
capture. `make tool-check` runs the portable scenario/evidence contracts and is
included in `make check`. On macOS, `make gui-tool-check` additionally checks
the window capture and recorder commands using the system Swift SDK.

The following command
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
before/after pixels to establish fresh background rendering. Measure an
application's painted canvas width from the screenshot itself: scan one row for
the background-colour boundary and divide that pixel column by the frame's
character width. The longest buffer line is not that measurement: trailing
padding is not always written into the buffer, so a short line can sit inside a
full-width viewport and a line-length reading looks like a shrunken render.
Hidden, minimized,
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
records inclusive phase durations for loaded `ebox-` and `etaf-` provider
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
