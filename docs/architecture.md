# ETAF Architecture

This document is the normative architecture contract for ETAF. It defines the concepts, ownership, public grammar, and lowering path. Implementation status and follow-up work belong in [`implementation-plan.en.md`](architecture.md); user-facing recipes belong in [`user-guide.en.md`](manual.md).

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
  (text :font-weight 'bold "Hello")
  (text
   :color "#687386"
   (expr (if ready "Ready" "Waiting")))))
```

An attribute appearing after a child is invalid because the two regions may
not be interleaved.

`etaf-view` is the sole public structural constructor. The macro reads View forms structurally and produces a normalized View value; `etaf-render` lowers a pure View, and `etaf-mount` gives a View a retained Runtime and buffer.

### 3.1 Quote and evaluation

The rule is simple:

1. Structural View positions are not quoted. This includes `etaf-view`, Hosts, Component calls, children, slot forms, and static Component styles.
2. Elisp expression positions follow normal Elisp evaluation. This includes attribute values, `:key`, `:on-*`, `:use`, `expr`, `:bindings`, `:setup`, Context values, Behavior constructors, and Actions.

```elisp
(etaf-view
 (text
  :color (if dark "#F4F6FB" "#1F2328")
  (expr label)))

(etaf-view
 (column
  (expr
   (when open
     (etaf-view
      (text :font-weight 'bold "Details"))))))
```

`'bold` is an ordinary Elisp literal symbol. `'(text "Details")` is ordinary data, not a View; use `(etaf-view (text "Details"))` when an Elisp expression must construct a View. ETAF does not run `eval` on quoted View data and does not add separate literal/eval nodes.

Attribute values do not need an `expr` wrapper. `expr` exists only because the child region is structural and needs one explicit bridge to arbitrary Elisp.

### 3.2 Expression semantics

`expr` accepts exactly one property and no children:

```elisp
(expr ELISP-EXPRESSION)
```

It evaluates the expression, then accepts a string, typed View, proper typed
View sequence, or `nil`. It creates no Ebox wrapper, identity, lifecycle,
watcher, or effect. `if`, `when`, `cond`, `let`, `mapcar`, `cl-loop`, and other
Elisp forms remain ordinary Elisp inside the form.

The current core has no file-facing `.etaf` pair loader. `etaf-define-component` is the structure/style/behavior unit: its View defines structure, `:styles` owns presentation rules, and `:bindings` owns retained values and `:setup` initializes lifecycle behavior. A future `.etaf` single-file component format belongs in a compiler layer that lowers into this same public View and Component contract; it is not a second runtime grammar.

## 4. Components

The public definition macro has four keywords.  Choose exactly one frontend;
the other two clauses are optional:

```text
(etaf-define-component NAME (&key PROPS)
  DOCSTRING?
  :bindings ((NAME INITIALIZER) ...)
  :setup INITIALIZATION-FORM
  :view VIEW
  :styles (RULE...))

(etaf-define-component NAME (&key PROPS)
  DOCSTRING?
  :bindings ((NAME INITIALIZER) ...)
  :setup INITIALIZATION-FORM
  :render ORDINARY-ELISP
  :styles (RULE...))
```

`:view` and `:render` are mutually exclusive and exactly one is required.
`:render` is ordinary Elisp and may return `etaf-view` or a programmatically
built `etaf-node`. Both share View compilation, prop validation, and slot
projection; `:render` adds no second representation or state model.
`:bindings`, `:setup` and `:styles` are optional and may each appear once. Props are the only declared business inputs; ordinary trailing children and named slots are normalized separately into the Component's slot collection.

The Component definition is the current structure/style/behavior boundary. Keep retained handles in `:bindings` and lifecycle work in `:setup`; keep static presentation in `:styles`. A future `.etaf` SFC compiler may produce these definitions, but the Runtime does not load `.etaf` files directly.

### 4.1 Stateless and stateful forms

```elisp
(etaf-define-component status-label (&key label)
  "Render a status label."
  :view
  (text
   :font-weight 'bold
   (expr label)))
```

```elisp
(etaf-define-component disclosure (&key title)
  "Render a retained disclosure."
  :bindings ((open (etaf-ref nil)))
  :view
  (column
   (text
    :role 'button
    :on-press
    (lambda () (setf (etaf-value open) (not (etaf-value open))))
    (expr (if (etaf-value open) "Hide" "Show")))
   (expr
    (when (etaf-value open)
      (etaf-view (text (expr title)))))))
```

Pure rendering and mounted input evaluation share default resolution and the
optional `:validate` phase. The validator receives resolved lexical props before
instance initialization or tracked input publication. It does not own state or
resources; live ref reads remain in rendering to preserve their dependency
ownership. `etaf-check-prop` provides shared, bounded input error messages to
Component validators and ordinary UI helpers.

Named bindings and optional setup share instance initialization and Scope. The
macro stores initial values in declaration order and builds each render's lexical
environment from those same values and the current props. The existing `etaf-state`
accessor is only available without named bindings; otherwise setup results are ignored. Reorder retains the
instance and its bindings; rejected initialization and unmount use the same resource
cleanup path, without a second state graph.

Instance-local Host names map to opaque symbols in the Component instance.
`etaf-local-ref` allocates them during setup; retained instances keep the mapping,
while replacement creates a fresh mapping. The handle uses the same Host identity
path as an explicit `:ref`. Ebox owns committed geometry lookup and disappearance;
ETAF adds no parallel target index. Literal application addresses remain explicit.

`etaf-prop` gives setup a stable computed source backed by the Component semantic
inputs, without duplicating authoritative mutable state. Candidate prop changes
invalidate dependent computations and retained descendant render effects. A
candidate journal preserves affected cache values and dependency edges; rejection
restores those edges and makes caches recompute from committed props and live
application refs. Successful publication discards the journal and notifies reactive
subscribers. Instance Scope and semantic ownership checks reject disposed sources.

Input default values belong to the committed Component semantic record. A
candidate resolves missing inputs before setup/render and copies only the
property container, preserving supplied and default object identities. Newly
resolved defaults become authoritative with the same publication as the output;
rollback discards them. See the [manual](manual.md#4-define-a-component) for evaluation
and ownership rules.

Business prop values, tracked prop sources and keyed iteration items share the
reactive shallow equality rule. Input plists and item indexes retain application
values by identity instead of taking deep copies. Whole-tree and local input
updates therefore accept the same replacement objects; a stable key preserves
the instance while its output and callbacks receive the current item.

`:key` is stable identity metadata, not a business prop. On a Component call it selects the retained Component instance within the sibling scope; on a Host it is forwarded as the Ebox node key. If a render candidate fails, the Runtime restores the previous instance, handlers, behaviors, and buffer.

Component calls use the exact registered definition name. The registry creates no automatic prefix or `-view` aliases. Official catalog Components use names such as `etaf-button`; an application may explicitly define its own Component under any valid unoccupied name.

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
 (slot :name 'header (text :font-weight 'bold "Account settings"))
 (text "Card body"))
```

Inside a Component View, the default outlet and its fallback are:

```elisp
(slot)
(slot (text :color "#687386" "No content"))
```

The explicit normalized spelling is:

```elisp
(slot :name 'default (text :color "#687386" "No content"))
```

Named slot names are stable non-keyword symbols. Strings, numbers, variables, and runtime expressions are rejected because a slot name is part of retained structure. A named input may appear only once. An explicitly empty input `(slot :name 'header)` suppresses the outlet fallback. Slot forms do not create Ebox wrappers.

Inside a Component, `slot` projects content. In a Component call's child region, `slot :name` contributes content. The compiler uses the same normalized slot representation for both roles.

Every Component retains one semantic output Range, regardless of whether it
produces zero, one or several roots. Slot reads remain dependencies of its render
effect; neither output cardinality nor slot access introduces a physical container.
Component identity and lifecycle are independent of the current output shape.

The final semantic generation owns output composition. Range snapshots are derived
caches; descendant changes invalidate enclosing snapshots without eagerly
lowering those ancestors again. A snapshot is composed from the corresponding
committed or candidate generation only when a publication or composition needs
that Range's canonical input. An invalidation carries no captured runtime or
old generation, and follows the same artifact promotion and rollback lifecycle
as a materialized snapshot. Adjacent semantic
Ranges share a physical Ebox child list, while a Host starts an independent child
layout. Publication uses Ebox's committed Range addresses, or its root operation
when no enclosing child Range is published. It composes the final candidate output
without rerunning application effects or adding another Component artifact store.

Authored slot expressions retain their author's props, state, and Context across
the entire projected subtree. A Component created in that subtree owns its own
props, state, styles, and Scope, inheriting Context from the slot author. The
receiver's own fallback, ordinary children, and View-producing callbacks use
the receiver environment instead. Table/Grid cell callbacks keep the same
ordinary rule: their Context is the consuming Table/Grid location.

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

ETAF's Renderer is the only framework module that lowers View semantics into Ebox nodes, properties, and Host queries; `etaf-render-port.el` is the only module that probes the versioned Ebox framework SPI and selects a publication route. Both use only public Ebox APIs, while Runtime reads the already-selected immutable port instead of guessing the Ebox version. Ebox does not know about Components, slots, Actions, Context, Behaviors, or Data.

Reactive Host property changes lower only the previous and next Host declarations
into Ebox's general candidate property operation. Ebox retains content and children
and combines their updates with Component and Range replacements. ETAF does not
classify paint changes or rebuild a subtree because a property affects layout or
native interaction; those consequences belong to Ebox's publication pipeline.

The public View grammar does not accept raw Ebox Nodes. Framework integrations construct canonical TextNode and BoxNode values through Ebox's typed integration port, while ordinary ETAF applications stay on Hosts and Components. This keeps measurement, identity, and rollback ownership inside one lowering path.

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

Queued semantic ancestors run before their descendants. A conditional Range
resolves attachment before a child input or render can stage an update.
Independent owners retain stable effect priority and ID order; the existing
generation graph supplies ancestry without a separate scheduling authority.

Before publication, attachment follows the final candidate parent/child edges
to Root. Staged descendants of a detached branch lose their effects, Host
contributions and publication edits; staging alone cannot preserve lifetime.
Reused Component records follow the same retirement even when their unchanged
graph subtree was not copied into the candidate. Generation construction must
not retain those records after their descendants have been removed.
Slot updates retain their physical parent independently of their lexical owner.
Existing Component scopes retire after successful publication, while speculative
instances that never attach are disposed without mounted/unmounted callbacks.

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

`etaf-behavior-create` accepts the reserved `:install` attribute for an optional zero-argument installer. The installer may return a cleanup function; `etaf-current-behavior-context` returns an opaque installation context; `etaf-behavior-context-info` exposes its Runtime, effective Host reference and installation-time semantic props. These facts do not authorize candidate input. Installer state is disposed on replacement, candidate rollback or owner unmount; committed state remains authoritative until successful publication.

Native help, pointer and hover-paint declarations pass unchanged into Ebox
canonical interaction facts, including explicit nil inheritance barriers.
Component root forwarding uses the same path as direct Hosts. Ebox owns
validation, native property projection and hover painting; ETAF adds no
hover target registry or alternate cascade.

Host press and drag bindings lower to Ebox native keymaps alongside canonical source
facts. A bounded per-Runtime cache holds dispatch maps that look up committed
handlers, so callback replacement does not retain candidate closures. Disabled
and callbackless control boundaries emit explicit nil maps. Ebox resolves visible
position ownership; ETAF no longer scans Host bounds to select activation targets.
Tab index and disabled declarations are published as Ebox interaction facts.
Ebox derives disabled selector state from those facts; ETAF keeps no separate
selector-state projection. Mounted focus supplies :focus through the same
Ebox cascade and atomic publication; pure component rendering has no focus.
Generated press and drag tracking supplies :active through the same source
projection. Component rules consume it directly; Runtime adds no pressed-state
field. Pointer activation runs after Ebox clears the state.
Ebox owns the focus identity, navigation order, visibility, point retention and
rollback. ETAF's focus APIs translate Runtime context and preserve their public
error conditions; Runtime stores no focus field and no longer scans or sorts
Host candidates or wraps flushes to repair point. The mounted Ebox buffer mode
owns default input bindings and keyboard focus precedence, including coincident
parent/child positions. ETAF has no independent input mode or target override;
its native callback simply dispatches the selected committed Host handler.

Ebox owns the complete native drag loop and retains the pointer target. ETAF
dispatches each gesture phase separately through its ordinary event batch,
allowing reactive motion to publish while the button is held. Runtime caches
maps by Host and enabled event capabilities; every phase reads the committed
handler. A native terminal cancellation may reach a retained disabled Host,
while removal or unmount stops application delivery. No gesture coordinates,
tracking loop or second target index is maintained by ETAF.

ETAF's `etaf-draggable` and `etaf-resizable` Behaviors are reusable adapters
above this input boundary. They consume the gesture callback, write only
caller-owned writable refs, and let the existing reactive Host property path
publish incremental geometry updates. Draggable supports axis selection;
resizable supports edge selection, opposite-edge preservation, and numeric
minimum/maximum constraints. A caller may provide a pure delta conversion when
its logical units differ from Ebox pixels. These Behaviors own no window state,
stacking policy, maximize/minimize mode, or pointer loop. UI Components and
applications compose them with title bars and handles, while a desktop
application owns window lifecycle and ordering.

Aggregate-state applications may use `etaf-draggable-controlled` and
`etaf-resizable-controlled`: a read function supplies the committed geometry
plist and an `on-change` callback accepts the next detached plist.  These
variants retain only transient gesture origins and avoid a second persistent
geometry store.

Interaction composition is deterministic.  An explicit Host `:on-*` callback
runs first, followed by Behavior callbacks in declaration order; an error
short-circuits the remaining callbacks.  For non-event attributes the explicit
Host value wins, otherwise the first declaring Behavior wins. Behavior names
must be unique on one Host before any installer runs. Stable installer identity
is reused, and every installed cleanup runs exactly once. Events dispatch only
to the exact Host reference: ETAF has no capture or bubble phase.

Action names should be application- or feature-prefixed symbols. Duplicate
registration is an error by default. `etaf-action-redefine-run` is the explicit
authoring/reload boundary; replacement affects future name-based dispatch and
does not flush a mounted Runtime.

Runtime events are dispatched through `etaf-dispatch-event`, and focus/hit testing use public Ebox Host-reference queries through `etaf-activate`, `etaf-focus`, `etaf-focus-next`, `etaf-host-ref-bounds`, and `etaf-host-ref-position`.

## 9. Context, Theme, Data, and Resource

### 9.1 Context and Theme

Context is an inherited Component Scope environment:

<!-- etaf-example: context -->
```elisp
(require 'etaf)

(etaf-define-component service-consumer ()
  "Read the inherited service."
  :bindings ((service (etaf-inject 'service nil t)))
  :view (text (expr (format "Service: %s" (etaf-value service)))))

(etaf-define-component service-provider ()
  "Provide a reactive service to its own child Component."
  :setup
  (let ((service (etaf-ref "demo-service")))
    (etaf-provide 'service service)
    service)
  :view (service-consumer))

(etaf-mount "*etaf-context*" (etaf-view (service-provider)))
```

Keys are stable ordinary symbols. The nearest ancestor wins; a missing required
key signals `etaf-context-error`. Root-authored slots retain the root's empty
Context throughout their subtree. Migration from the former accidental receiver
inheritance requires declaring consumers in the provider's own View or calling
an ordinary View-producing callback there. Projected slots continue to use their
author's environment. Theme follows this same Context ancestry and contains a
property plist:

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

Palette resolution remains a Theme concern, not a UI catalog concern. Core
provides `etaf-theme-resolve-palette` for explicit light/dark semantic pairs
in application-owned data. Resolution returns an ordinary Theme plist without
a global registry. `etaf-ui` consumes `:ui-*` semantic tokens and does not
depend on renderer palette names or private Ebox state.

When a static Component rule needs one Theme value, use
`etaf-theme-token`; ETAF resolves the deferred token at the style boundary so
the rule remains static for retained Hosts.

Theme defaults lower to immutable Ebox scopes at UA origin, rooted on their Host.
ECSS owns their precedence, including importance and inheritance. Host updates
resolve author props and defaults separately before candidate publication; deferred
ECSS values bypass concrete Ebox paint slots after Ebox schema validation.

Each Component instance owns an immutable Ebox scope identity. Hosts mark
membership; topmost owned Hosts independently mount rule revisions at author
origin. Physical ancestor ownership identifies roots through transparent ranges
and forests. Retained slices keep membership when roots revise Theme-dependent
rules. ECSS performs matching and cascade on canonical tree relations. Slot
projections and public code-slot accessors preserve the caller's ownership and
Context; fallback retains the consumer's ownership. These facts never require
an additional visual container.

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

`:load` is required and receives `QUERY`, `PAGE`, and `PAGE-SIZE`; it returns a plist with `:items` and optional `:total`, `:page`, and `:page-size`. `:mutate` and `:dispose` are optional. Load and mutation callbacks return ordinary synchronous results or an `etaf-async` descriptor. Data and Resource share request start, single completion, invalidation, cancellation and timeout. Data continues to own collections, paging, selection and read-side reconciliation. Unknown external outcomes never imply rollback; retrying a committed mutation refreshes without repeating the write.

`etaf-data-controller` owns query, pagination, items, total, status, error, selection, request generation, and disposal. `etaf-data-memory-source` is the built-in source used for examples and tests. Storage packages are concrete sources; SQLite is not a core assumption and an ORM, when used, remains outside ETAF's data model.

### 9.3 Resource and error boundary

`etaf-resource` owns synchronous or asynchronous loading within a Scope. It starts `idle`; requests report `loading` or `refreshing` with a retained successful value, then `success`, `error` or `cancelled`. A synchronous resource remains straightforward:

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

The shared request invalidates before external cancellation, releases owner callbacks and prevents late completion from publishing. Resource exclusively owns successful values and `etaf-resource-result` cleanup, including the first discarded late result. Data exclusively owns its accepted collection and external write certainty; cancelling a wait does not undo a write. See the [user guide](manual.md#11-resource-and-raw-ebox) for adapters and native timer examples.

 `etaf-error-boundary-run` is an explicit function boundary: it handles errors raised by its body and leaves unrelated errors visible. Resource and Data state are projected into ordinary `expr` branches rather than special Error or Loading nodes.

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

etaf-db → etaf
  └── database backends (currently typed SQLite Data Source)

etaf-playground → etaf
  └── optionally etaf-ui for catalog examples
```

`etaf-ui` is the official ready-made Component catalog. Its public user concept is Component; files are maintainer boundaries. Controls, Widgets, and DataGrid are not parallel runtime types, and DataGrid is simply a compound Component built from the same View, props, slots, events, and Data contracts.

`etaf-db` owns database backend integration through the core Data Source capability contract. Its current SQLite backend owns schema declarations, identifier validation, connections, pagination and mutations. Data Controllers and their reactive lifecycle remain in ETAF core. SQLite-specific constructors keep their `etaf-sqlite-*` names within the single `etaf-db` package entry.

`ebox-playground`, `etaf-playground`, `etaf-ui`, and `etaf-db` are independently loadable sibling packages. `ebox-playground` uses only Ebox public APIs and never loads ETAF. `etaf-playground` uses ETAF public APIs and optionally loads `etaf-ui`; it never depends on `ebox-playground`. Core packages do not load any optional package automatically.

Database backends belong to `etaf-db`; SQLite is the only implemented backend. REST, file and other non-database integrations may implement `etaf-data-source` independently. There is no additional generic adapter layer or duplicate source protocol.

## 11. Retained publication and fixed-point safety

Mounted Component, expr, slot, fragment, raw, inline, and Root owners publish
through one outer reactive dispatch. A local owner evaluates into a candidate
generation and Ebox logical replacement; disjoint owners are coalesced into
one Ebox publication. The Root owner is the only complete-root adapter.

The sole mutable pointer to the committed semantic generation belongs to
`etaf-generation-authority`. Public handler and Host-property queries read that
generation directly. Same-named Runtime hash tables are one-way compatibility
mirrors rebuilt from the generation; they neither authorize queries nor write
back into it. The migration-only `legacy`, `project`, and `shadow` routes prove
projection equivalence and rollback safety without introducing a second
committed truth.

At process bootstrap, `etaf-render-port` requires Ebox framework SPI v3 with
`ebox-publication/v1` and snapshots exactly one immutable port. A missing,
malformed, or incompatible provider fails closed before any Runtime is mounted.
Ebox owns retained publication, transaction participation and final-accept
markers. ETAF uses those public contracts without a second publication provider
or compatibility route. A mounted or in-flight Runtime never switches ports.

Each semantic candidate captures the expected generation, semantic token, and
instance/resource/artifact/route store versions. The render path stages one CAS
inside the Ebox framework callback and restores it through the same inverse
journal on failure. A semantic-only change runs that CAS under ETAF ownership
without creating an Ebox publication or revision. Mirror projection and obsolete
route cleanup after CAS are postcommit work and cannot reverse the committed
token if they fail. Such failures are retained in the retirement diagnostic
journal and re-signaled with the same committed trailer used by lifecycle
failures; they never re-enter semantic rollback.

Each mounted Runtime also owns a distinct Host authority containing `state /
opaque token / version`. The initial framework stage enters only a
provisional state and registers a fixed-slot Ebox final marker; the Host becomes
attached only when buffer final accept succeeds. Public lookup, events, and
source routes validate both attached state and token. Detach invalidates the
token at one O(1) boundary before removing registries, routes, Component scopes,
or Behaviors, so cleanup volume or failure cannot revive the old Host.

Lifecycle callbacks and structural cleanup run after that commit boundary in
an `etaf-retirement-journal`. Every entry has a stable identity, ordering key,
attempt count, policy, and terminal state. Public mounted, updated, and
unmounted callbacks are run once; the first public failure abandons later
public callbacks while structural cleanup continues. Idempotent framework
cleanup has a bounded retry count, and contained cleanup records diagnostics
without changing the committed generation, Ebox revision, or Host authority.
Completed journals are retained separately from committed outcomes on the
Runtime, with a bounded history.

When an explicit operation must expose a postcommit callback failure, ETAF
re-signals the original condition symbol and preserves its original data as a
prefix. It appends one fixed `:etaf-condition-trailer/v1` datum containing the
operation, outcome, generation, Ebox revision, and diagnostic-journal IDs.
`etaf-condition-postcommit-info` validates and reads that trailer, so callers
can distinguish “committed, then callback failed” from a rollback failure.
The buffer-kill path drains or contains retirement work but never throws a
retirement condition from the kill hook.

Reactive publication is coordinated by an explicit `etaf-scheduler-context`.
The context owns the source and Runtime FIFOs, their dedupe sets, effect claims,
turn and projection epochs, nesting/busy state, fault diagnostics, and cost
counters; it does not own Component, resource, or generation state. Existing
callers use `etaf-scheduler-default-context`, while a mount may supply
`:scheduler-context` to isolate its dispatch authority. Scopes, Effects, and
opaque Runtime routes inherit and retain that context.

One logical projection groups every changed source by its live subscriber
contexts in one subscriber-table scan before draining. Source propagation
settles across all touched contexts before any Runtime callback publishes.
Within a context, each source and Effect is delivered once per scheduler turn,
and multiple changed sources enqueue a Runtime once. A reentrant write to an
already delivered source is deferred to the next turn; a per-context turn
budget contains cross-context cycles with reusable fault diagnostics. A source
wave snapshots the current FIFO, so newly discovered distinct sources consume
another budgeted turn and cannot monopolize one drain. Dedupe in one context
never suppresses another, and registry/token/Host validation filters stale
Runtime routes before fan-out.

Runtime callbacks are detached as a turn, so a lifecycle write enters the
following turn. One failing callback is retained as the context fault only
after every later callback in that detached turn has run. Data success/error
multi-ref publication and event/action callbacks use this same projection
boundary, while the legacy facade continues through the default context. Data
source failures update the Controller error state; a later projection/render
failure propagates unchanged and cannot be reclassified as a source failure.
Runtime operation reports include both the local context deltas and full
cross-context projection summaries for source
delivery, subscriber visits, effect work, Runtime work, stale drops, turns,
and faults.

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

Add a new public concept only when an existing owner cannot express the behavior, the new owner can state identity/lifecycle/error/rollback rules, and a public-path test can prove it. This keeps the model small while retaining full Elisp expressiveness.
