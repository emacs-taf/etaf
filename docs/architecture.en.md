# ETAF Architecture

This document is the normative architecture contract for ETAF. It defines the concepts, ownership, public grammar, and lowering path. Implementation status and follow-up work belong in [`implementation-plan.en.md`](implementation-plan.en.md); user-facing recipes belong in [`user-guide.en.md`](user-guide.en.md).

## 1. Design result

ETAF is one View and Component layer for text applications. Elisp remains the complete computation language, while Ebox remains the measurable layout and text-rendering engine.

```text
Application
  → Runtime / reactive state / Action / Data
  → Component(props, local Scope)
  → View
  → Renderer
  → Ebox Node
  → measure → layout → paint → commit
  → Emacs buffer
```

The design has five invariants:

- Every visible structure uses the same `NAME + attributes + children` shape.
- Every capability has one owner: View for structure, Component for reuse, Runtime for lifetime, reactive state for invalidation, and Ebox for geometry and publication.
- Upper layers reuse lower-layer contracts instead of introducing parallel concepts.
- Computation is ordinary Elisp in expression positions; it is never disguised as another visual node family.
- A failed render candidate never replaces the last committed buffer.

## 2. The model users learn

| Concept | What it is | What it owns |
| --- | --- | --- |
| View | A normalized interface description | Hosts, Component calls, text, and child structure |
| Host | A fixed structural View name | Core text or layout meaning |
| Component | A reusable View producer | Props, optional local Scope, slots, and lifecycle |
| Runtime | One mounted application | Rendering, events, scheduling, commit, rollback, and disposal |
| Ebox Node | The lower-level renderable object | Geometry, layout, surfaces, scrolling, and buffer publication |

These are mechanisms rather than additional visual node types:

- `expr` evaluates one child expression.
- `slot` reads or contributes to the one Component slot collection.
- `Behavior` installs reusable non-visual interaction.
- `Action` names a business mutation entry.
- `Effect` owns subscriptions and external synchronization.
- `watch` observes reactive state.
- `Context` provides inherited dependencies.
- `Data` owns application-data state and source requests.
- `raw-ebox` is the explicit low-level escape at the ETAF/Ebox boundary.

## 3. The unified View grammar

Every Host and Component call has one shape:

```text
(NAME ATTRIBUTE* CHILD*)
ATTRIBUTE = :KEY VALUE
```

Properties must be complete before the first child. A child can be a string, a normalized View, `nil`, or a sequence returned through `expr`.

```elisp
(etaf-view
 (column
  :class "welcome"
  (text :face 'bold "Hello")
  (text
   :color "#687386"
   (expr :value (if ready "Ready" "Waiting")))))
```

An attribute appearing after a child is invalid because the two regions may
not be interleaved.

`etaf-view` is the sole public structural constructor. The macro reads View forms structurally and produces a normalized View value; `etaf-render` lowers a pure View, and `etaf-mount` gives a View a retained Runtime and buffer.

### 3.1 Quote and evaluation

The rule is simple:

1. Structural View positions are not quoted. This includes `etaf-view`, Hosts, Component calls, children, slot forms, and static Component styles.
2. Elisp expression positions follow normal Elisp evaluation. This includes attribute values, `:key`, `:on-*`, `:use`, `expr :value`, `:setup`, Context values, Behavior constructors, Actions, and `raw-ebox :value`.

```elisp
(etaf-view
 (text
  :face (if dark 'light 'dark)
  (expr :value label)))

(etaf-view
 (column
  (expr
   :value
   (when open
     (etaf-view
      (text :face 'bold "Details"))))))
```

`'bold` is an ordinary Elisp literal symbol. `'(text "Details")` is ordinary data, not a View; use `(etaf-view (text "Details"))` when an Elisp expression must construct a View. ETAF does not run `eval` on quoted View data and does not add separate literal/eval nodes.

Attribute values do not need an `expr` wrapper. `expr` exists only because the child region is structural and needs one explicit bridge to arbitrary Elisp.

### 3.2 Expression semantics

`expr` accepts exactly one property and no children:

```elisp
(expr :value ELISP-EXPRESSION)
```

It evaluates the expression, then accepts a string, View, sequence, or `nil`. It creates no Ebox wrapper, identity, lifecycle, watcher, or effect. `if`, `when`, `cond`, `let`, `mapcar`, `cl-loop`, and other Elisp forms remain ordinary Elisp inside `:value`.

The current core has no file-facing `.etaf` pair loader. `etaf-define-component` is the structure/style/behavior unit: its View defines structure, `:styles` owns presentation rules, and `:setup` owns retained state, events, and lifecycle behavior. A future `.etaf` single-file component format belongs in a compiler layer that lowers into this same public View and Component contract; it is not a second runtime grammar.

## 4. Components

The public definition macro has exactly three keywords:

```elisp
(etaf-define-component NAME (&key PROPS)
  DOCSTRING?
  :view VIEW
  :styles (styles RULE...))

(etaf-define-component NAME (&key PROPS)
  DOCSTRING?
  :setup SETUP
  :styles (styles RULE...))
```

`:view` and `:setup` are mutually exclusive. `:styles` is optional and may appear once. Props are the only declared business inputs; ordinary trailing children and named slots are normalized separately into the Component's slot collection.

The Component definition is the current structure/style/behavior boundary. Keep dynamic state, Action callbacks, and lifecycle work in `:setup`; keep static presentation in `:styles`. A future `.etaf` SFC compiler may produce these definitions, but the Runtime does not load `.etaf` files directly.

### 4.1 Stateless and stateful forms

```elisp
(etaf-define-component status-label (&key label)
  "Render a status label."
  :view
  (text
   :face 'bold
   (expr :value label)))
```

```elisp
(etaf-define-component disclosure (&key title)
  "Render a retained disclosure."
  :setup
  (let ((open (etaf-ref nil)))
    (lambda ()
      (etaf-view
       (column
        (text
         :role 'button
         :on-press
         (lambda ()
           (setf (etaf-value open)
                 (not (etaf-value open))))
         (expr :value (if (etaf-value open) "Hide" "Show")))
        (expr
         :value
         (when (etaf-value open)
           (etaf-view (text (expr :value title))))))))))
```

`:setup` runs once for a retained Component instance and must return a zero-argument render function. Re-render reads current props and refs without rerunning setup. Setup is the owner for local refs, computed values, watches, Effects, and cleanup registration.

`:key` is stable identity metadata, not a business prop. On a Component call it selects the retained Component instance within the sibling scope; on a Host or `raw-ebox` it is forwarded as the Ebox node key. If a render candidate fails, the Runtime restores the previous instance, handlers, behaviors, and buffer.

In View syntax, canonical Component names may omit the `etaf-` prefix. If the short name would collide with an Elisp function, special form, or Host, the registry assigns a semantic `-view` alias. Ordinary Elisp APIs such as `etaf-value`, `etaf-ref`, and `etaf-mount` always keep their prefix.

## 5. Children and slots

All Component content is one slot collection:

```text
slots.default = ordinary trailing children
slots.NAME    = named slot content
```

Children are the convenient authoring form of the anonymous/default slot; they are not a second content model and do not appear in the business `&key` declaration.

Trailing children fill the default slot:

```elisp
(card
 :title "Account"
 (text "Card body"))
```

Named content uses the same structural shape:

```elisp
(card
 :title "Account"
 (slot :name 'header (text :face 'bold "Account settings"))
 (text "Card body"))
```

Inside a Component View, the default outlet and its fallback are:

```elisp
(slot)
(slot (text :face 'shadow "No content"))
```

The explicit normalized spelling is:

```elisp
(slot :name 'default (text :face 'shadow "No content"))
```

Named slot names are stable non-keyword symbols. Strings, numbers, variables, and runtime expressions are rejected because a slot name is part of retained structure. A named input may appear only once. An explicitly empty input `(slot :name 'header)` suppresses the outlet fallback. Slot forms do not create Ebox wrappers.

Inside a Component, `slot` projects content. In a Component call's child region, `slot :name` contributes content. The compiler uses the same normalized slot representation for both roles.

## 6. Core Hosts and Ebox

ETAF core intentionally provides only minimal, unstyled Hosts:

```text
text · fragment · container · row · column · stack · flex · grid · spacer
```

| Host | Meaning | Lowering direction |
| --- | --- | --- |
| `text` | A text surface with optional inline runs | Ebox box/content |
| `fragment` | Children without a visual wrapper | Flattened child sequence |
| `container` | Neutral child container | Ebox column/container path |
| `row` | Horizontal children | Ebox row layout |
| `column` | Vertical children | Ebox column layout |
| `stack` | A structural composition container | Ebox container path |
| `flex` | Flex-distributed children | Ebox flex layout |
| `grid` | Two-dimensional tracks, placement, and spans | Ebox Grid formatting context |
| `spacer` | Intentional empty geometry | Ebox spacer |

Strings are the smallest text View and lower to Ebox content. Nested `text` Views in a text-compatible position become propertized inline runs; a non-text child falls back to normal layout lowering. Text, View Hosts, Components, and Ebox Nodes are therefore successive representations, not competing element classes.

`grid` reuses Ebox's public two-dimensional layout contract. Its properties include track templates, `auto`/fractional/`minmax` tracks, gaps, row/column placement, spans, auto-flow, and item alignment. Ebox owns track measurement and placement; ETAF only maps the `grid` Host into that node. Ebox's optional native reflow backend is not required for correctness; a Grid tree uses the ordinary Ebox renderer when that backend does not support the node.

ETAF's Renderer is the only framework module that calls Ebox. It uses Ebox public constructors, property readers, host-reference queries, and publication APIs. Ebox does not know about Components, slots, Actions, Context, Behaviors, or Data.

`raw-ebox` is the one deliberate escape:

```elisp
(etaf-view
 (raw-ebox
  :key 'backend-row
  :value (ebox-create :content "Low-level")))
```

It accepts only `:value` and optional `:key`. The returned Ebox Node remains opaque and does not receive Component props, slots, events, or Behaviors. Using it transfers measurement, identity, rollback, and backend responsibility to the caller.

## 7. Runtime and reactive state

Runtime mount is transactional:

```text
create Runtime
  → setup retained Components
  → render View candidate
  → lower and publish Ebox candidate
  → promote handlers, instances, and Behaviors
  → run mounted/updated lifecycle
```

An update follows the same path. Reactive refs and computed values invalidate the render effect; the Runtime scheduler flushes synchronously at the current boundary. A render write is rejected with `etaf-render-write-error`; mutate state from an event, Action, Effect, or watch callback.

Rendering, lowering, and Ebox publication form the rollback boundary. If one of those candidate steps fails, the last committed tree remains active. Lifecycle and cleanup callbacks run after the retained state is promoted and publication has completed; their errors remain visible and do not pretend to roll back an already published Ebox tree.

The reactive API is one model:

```elisp
(let* ((count (etaf-ref 0))
       (double (etaf-computed
                (lambda () (* 2 (etaf-value count))))))
  (etaf-watch count
              (lambda (new old)
                (message "%s → %s" old new)))
  (etaf-watch-effect
   (lambda ()
     (message "double=%s" (etaf-value double)))))
```

`etaf-effect-scope` owns effects and cleanup. Component setup automatically runs inside a Component Scope; disposing the Component stops child scopes, watchers, and resource cleanup.

## 8. Behavior, events, Actions, and Effects

```text
on-xx   = one local callback attribute
Action  = one named business mutation entry
Effect  = one subscription/external-sync owner
Behavior = a reusable bundle installed on a Host or Component
```

Use a local callback for one interaction:

```elisp
(text
 :role 'button
 :on-press (lambda () (message "Opened"))
 "Open")
```

Use `etaf-action-define` and `etaf-dispatch` when the mutation is named and shared. Use `etaf-define-behavior` or `etaf-behavior-create` when several Hosts need the same non-visual capability. Attach Behaviors with `:use`; a Behavior never becomes a View node and never writes the buffer directly.

`etaf-behavior-create` accepts the reserved `:install` attribute for an optional zero-argument installer. The installer may return a cleanup function; `etaf-current-behavior-context` exposes the current Runtime, structural path, and Host props while it runs. Installer state is disposed when the Behavior is replaced or its owner is unmounted.

Runtime events are dispatched through `etaf-dispatch-event`, and focus/hit testing use public Ebox Host-reference queries through `etaf-activate`, `etaf-focus`, `etaf-focus-next`, `etaf-host-ref-bounds`, and `etaf-host-ref-position`.

## 9. Context, Theme, Data, and Resource

### 9.1 Context and Theme

Context is an inherited Component Scope environment:

```elisp
(etaf-define-component service-provider ()
  "Provide a reactive service to descendants."
  :setup
  (let ((service (etaf-ref "demo-service")))
    (etaf-provide 'service service)
    (lambda () (etaf-view (slot)))))

(etaf-define-component service-consumer ()
  "Read the inherited service."
  :setup
  (let ((service (etaf-inject 'service nil t)))
    (lambda ()
      (etaf-view (text (expr :value (etaf-value service)))))))

(etaf-view (service-provider (service-consumer)))
```

Keys are stable ordinary symbols. The nearest ancestor wins; a missing required key signals `etaf-context-error`. Theme is a Context value containing a property plist:

```elisp
(etaf-define-component themed-shell ()
  "Provide default text colors to a subtree."
  :setup
  (progn
    (etaf-theme-provide
     '(:color "#F4F6FB" :bgcolor "#202634"))
    (lambda () (etaf-view (slot)))))
```

Palette resolution remains a Theme concern, not a UI catalog concern. Core
provides `etaf-theme-resolve-palette` for explicit light/dark semantic pairs;
the optional `etaf-theme-tp` file is the only bridge allowed to read TP's
renderer-level palette registry. `etaf-ui` consumes `:ui-*` semantic tokens and
does not depend on TP names or private Ebox/TP state.

When a static Component rule needs one Theme value, use
`etaf-theme-token`; ETAF resolves the deferred token at the style boundary so
the rule remains static for retained Hosts.

Explicit Host props override Component styles, and Component styles override Theme defaults.

Style ownership follows the Component that authored each View node. A nested Component is a style boundary: parent rules do not penetrate its internals. Caller-provided slot content is rendered with the caller scope, while a child's own fallback content remains in the child scope.

### 9.2 Data

Data is a core ETAF capability, not a second framework package. A Data Source is a small capability plist:

```elisp
(etaf-data-source
 :load (lambda (query page page-size)
         (ignore query page page-size)
         (let ((rows '((:id 1 :name "Ada"))))
           (list :items rows :total (length rows))))
 :mutate (lambda (operation payload)
           (ignore operation payload)
           t)
 :dispose (lambda () t))
```

`:load` is required and receives `QUERY`, `PAGE`, and `PAGE-SIZE`; it returns a plist with `:items` and optional `:total`, `:page`, and `:page-size`. `:mutate` and `:dispose` are optional. The core boundary is synchronous so it does not need a Promise, Task, or Executor concept. External callback-based integrations can publish their result through the same reactive refs or a Resource boundary.

`etaf-data-controller` owns query, pagination, items, total, status, error, selection, request generation, and disposal. `etaf-data-memory-source` is the built-in source used for examples and tests. Storage packages are concrete sources; SQLite is not a core assumption and an ORM, when used, remains outside ETAF's data model.

### 9.3 Resource and error boundary

`etaf-resource` is a Scope-owned synchronous loader with reactive `loading`, `success`, and `error` state:

```elisp
(let* ((filename "README.md")
       (resource
        (etaf-resource
         (lambda ()
           (with-temp-buffer
             (insert-file-contents filename)
             (buffer-string)))))
       (stop
        (etaf-watch-effect
         (lambda ()
           (message "resource=%s" (etaf-resource-status resource))))))
  (unwind-protect
      (etaf-resource-value resource)
    (funcall stop)
    (etaf-resource-dispose resource)))
```

`etaf-resource-result` adds replacement/disposal cleanup. `etaf-error-boundary-run` is an explicit function boundary: it handles errors raised by its body and leaves unrelated errors visible. Resource and Data state are projected into ordinary `expr` branches rather than special Error or Loading nodes.

## 10. Official UI and package boundaries

There is one formal reusable interface concept: Component.

```text
ebox
  └── optional ebox-playground

etaf → ebox
  ├── View / Component / Runtime
  ├── reactive / Action / Effect / Data
  └── Renderer

etaf-ui → etaf
  └── official Button, Checkbox, Label, Panel, DataGrid, ... Components

etaf-sqlite → etaf
  └── typed SQLite Data Source

etaf-playground → etaf
  └── optionally etaf-ui for catalog examples
```

`etaf-ui` is the official ready-made Component catalog. Its public user concept is Component; files are maintainer boundaries. Controls, Widgets, and DataGrid are not parallel runtime types, and DataGrid is simply a compound Component built from the same View, props, slots, events, and Data contracts.

`etaf-sqlite` is a concrete source package. It owns schema declarations, identifier validation, connections, pagination, and mutations; `etaf-data` remains part of ETAF core. PostgreSQL, REST, file, and ORM integrations may implement the same source capability in separate packages without adding an `etaf-adapters` concept.

`ebox-playground`, `etaf-playground`, `etaf-ui`, and `etaf-sqlite` are independently loadable sibling packages. `ebox-playground` uses only Ebox public APIs and never loads ETAF. `etaf-playground` uses ETAF public APIs and optionally loads `etaf-ui`; it never depends on `ebox-playground`. Core packages do not load any optional package automatically.

Optional storage integrations should use explicit package names such as a concrete SQLite or PostgreSQL source. A generic adapter package would add a name without owning a stable behavior, so it is not part of the public model.

## 11. Retained publication and fixed-point safety

Mounted Component, expr, slot, fragment, raw, inline, and Root owners publish
through one outer reactive dispatch. A local owner evaluates into a candidate
generation and Ebox logical replacement; disjoint owners are coalesced into
one TP/Ebox publication. The Root owner is the only complete-root adapter.

Each Runtime flush records a candidate-aware effect tuple containing the
generation id, effect-to-source edges and source versions, plus an immutable
semantic-node stamp for candidate input/context/output facts. A repeated tuple
reports the ordered effect/edge path of the non-converging graph. The flush
bound is derived from candidate nodes, dependency edges, and source entries;
it is not a fixed multiplier of an arbitrary threshold. Rollback discards the
flush-local stamps, so the same failed state can be retried as a new
transaction.

Behavior installers use target-specific identity: reactive values and
functions are compared with `eq`, while scalar attributes use value equality.
Each installed Behavior also receives a stable `(mount-epoch resource-id)`
address. Generation membership and the Runtime resource registry determine
which installer is authoritative; a failed candidate removes only its staged
Behavior resource and runs its contained cleanup.

## 12. Extension rule

Before adding a new concept, choose the smallest existing owner:

| Need | Owner |
| --- | --- |
| Reusable visual composition | Component or ordinary View helper |
| One computed child | `expr` |
| Local derived value | `etaf-computed` |
| Reusable interaction | Behavior |
| Named mutation | Action |
| Cross-depth dependency | Context |
| Request or mutation state | Data / Resource |
| Geometry or layout algorithm | Ebox |
| Low-level backend escape | `raw-ebox` |

Add a new public concept only when an existing owner cannot express the behavior, the new owner can state identity/lifecycle/error/rollback rules, and a public-path test can prove it. This keeps the model small while retaining full Elisp expressiveness.
