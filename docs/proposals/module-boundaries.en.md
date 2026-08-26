# ETAF Module Responsibilities and Target Architecture (Unimplemented Proposal)

> Status: design proposal. This is not the current public API or a delivered
> implementation. The current contract remains [`architecture.en.md`](../architecture.en.md),
> [`user-guide.en.md`](../user-guide.en.md), and the passing tests.

This proposal defines clean-slate ownership boundaries for ETAF, Ebox, ECSS,
TP, `etaf-ui`, `etaf-sqlite`, the performance recorder, and both Playgrounds. It
describes the target architecture; current compatibility names are not treated as
the architecture itself.

The target parts below are not delivered API until code, tests, and real benchmarks
prove them. This proposal does not change the current Host registry, View grammar,
or package dependencies.

## 1. Minimal stable model

ETAF has four representations:

```text
Component semantics and ownership
    ↓
Text / Box View structure
    ↓
Ebox geometry and render plan
    ↓
TP / Emacs final submission
```

The public concepts are:

| Concept | Owns | Does not own |
| --- | --- | --- |
| `Text` | text content, typography, inline properties, wrapping input | subtree layout, business state, lifecycle |
| `Box` | size, surface, children, and layout | Component identity, Data, Actions |
| `Component` | reusable semantics, props, slots, state, Context, Actions, lifecycle | pixel measurement and layout algorithms |

`Host` is an internal Renderer term for a primitive lowered to a backend. It is not a
third public visual taxonomy. An `Ebox Node` is a lower-level geometry/render object.

ETAF should keep two orthogonal Box properties instead of turning these concepts into
Components:

```text
:outer  = inline | block
:layout = normal | row | column | flex | grid
```

`:outer` describes how the Box participates in its parent's ordinary layout;
`:layout` describes how the Box arranges its own children. `normal` is the clearer
user-facing name for ordinary content layout; the Renderer may lower it to Ebox's
internal ordinary-content path.

The target View model is:

```text
View = Text(content, typography)
     | Box(layout, surface, children)
     | ComponentCall(props, slots)
```

The Box inner-layout modes exposed by the target ETAF API are a closed set:

```text
normal | row | column | flex | grid
```

A plain Box defaults to `:outer 'block :layout 'normal`; it does not silently become a
column. Use `:layout 'column` for vertical stacking, or choose `row`, `flex`, or `grid`
explicitly. Text defaults to inline content in normal layout and owns text measurement,
wrapping, and inline runs.

The mapping is:

| CSS meaning | Target ETAF expression |
| --- | --- |
| ordinary block content | `(box :outer 'block :layout 'normal ...)` |
| ordinary inline content | `(box :outer 'inline :layout 'normal ...)` |
| vertical stacking | `(box :layout 'column ...)` |
| horizontal layout | `(box :layout 'row ...)` |
| flex container | `(box :layout 'flex ...)` |
| grid container | `(box :layout 'grid ...)` |

`inline-flex` is the direct orthogonal combination:

```elisp
(box :outer 'inline :layout 'flex ...)
```

A Component call has no fixed `:outer` or `:layout`; its root Text/Box output decides
how it participates in the parent. A transparent Component may return siblings and
therefore has no single outer Box.

`(box "text")` is shorthand for `(box (text "text"))`. ETAF must not expose
`(box :content "text")`; `:content` remains an Ebox backend field.

ETAF also does not define a public `spacer` type. A Box with no children is an empty
Box; Ebox may use an empty-node representation or private helper, but users do not
need another visual category.

Box properties remain grouped by owner rather than becoming one unconstrained plist:

| Group | Properties | Purpose |
| --- | --- | --- |
| structure | `:outer`, `:layout`, `:key` | participation, child layout, identity |
| geometry/surface | `:width`, `:height`, min/max, `:margin`, `:padding`, `:border`, `:box-sizing`, `:overflow` | size and surface |
| text | `:face`, `:color`, `:bgcolor`, `:wrap-mode`, `:text-align` | typography and text paint |
| flex item | `:order`, `:flex-grow`, `:flex-shrink`, `:flex-basis`, `:align-self` | valid under a Flex parent |
| grid item | `:grid-row`, `:grid-column`, spans | valid under a Grid parent |
| semantics/interaction | `:class`, `:id`, `:role`, `:ref`, `:aria-*`, `:on-*`, `:use` | Runtime events, Behaviors, and queries |

`:outer` and `:layout` are geometry/structure properties, not TP paint slots. ECSS may
resolve them, but Ebox validates the final combination and owns the layout result.

Ebox may keep an outer/inner display representation internally; the public split is
the explicit `:outer` and `:layout` contract.

## 2. Module responsibilities

### ETAF Core

`etaf-view` owns the View grammar, Text/Box/Component-call normalization, property
and slot shape validation, expression boundaries, and Component registration. It does
not measure pixels, lay out nodes, write buffers, or implement business data.

`etaf-component` owns `etaf-define-component`, `:view`, `:setup`, `:styles`, and
definition validation. It does not own Runtime scheduling or Ebox nodes.

`etaf-runtime` owns retained identity, reactive refs/computed/effects/watchers, Scope
cleanup, Context/Theme, Actions, Behaviors, Data, Resources, lifecycle, invalidation,
transactions, commit, and rollback. It does not own pixel layout or Ebox private state.

`etaf-renderer` is the only ETAF-to-Ebox lowering boundary. It translates Text, Box,
and Component output to public Ebox constructors and carries resolved style/paint
contributions downstream. It does not own Component lifecycle or data requests.

### Ebox

Ebox is the layout and rendering engine, not the ETAF Component Runtime. It owns text
measurement, wrapping, row/column/flex/grid geometry,
surface/scroll geometry,
stable layout snapshots, and render/paint plans. It does not know Components, slots,
Context, Actions, Behaviors, Data, or Resources.

Logically it has two boundaries:

```text
ebox-core       pure measurement, layout, snapshots, and render plans
ebox-emacs      font/window capabilities and Emacs buffer submission
```

They need not be separate distribution packages immediately, but geometry and Emacs
side effects must not become one responsibility.

### ECSS and TP

ECSS owns selectors, declarations, cascade, inheritance, and computed styles. It does
not own Runtime state, layout, or buffer writes.

TP owns layered Emacs text-property/paint slots, priority merging, atomic application,
journaling, and rollback. It does not parse selectors, measure layout, or execute
Components.

### Optional/application packages

`etaf-ui` owns reusable Button, Checkbox, Label, Panel, Number input, DataGrid, and
Pagination Components. It does not implement another Runtime or layout engine.

`etaf-sqlite` owns SQLite connections, schema/query/mutation validation, paging, and
Data Source disposal. It does not own Data Controller state or UI.

The performance recorder owns application-neutral operation/stage records, summaries,
environment context, and export. It observes public boundaries and never embeds a
Playground name or changes the measured render path.

`ebox-playground` only validates public Ebox layout APIs. `etaf-playground` validates
ETAF composition and may optionally load `etaf-ui` and `etaf-sqlite`; neither Playground
owns framework protocols. A static `.etaf` manifest belongs to the Playground unless a
future compiler lowers it to the same Text/Box/Component contract.

## 3. Dependency direction

```text
etaf-ui ───────▶ ETAF Core ───────▶ Ebox public layout port
etaf-sqlite ──▶ ETAF Data contract
etaf-playground ─▶ ETAF + optional UI/SQLite
ebox-playground ─▶ Ebox public API only
performance ───▶ public probes only
```

Ebox never depends upward on ETAF. TP never parses View trees. ECSS never writes
buffers. UI never calls private Ebox functions. SQLite never knows UI. Playgrounds
never inject example protocols into core.

## 4. Rust and Elisp split

Rust is for deterministic, environment-independent computation: normalized Render IR,
keyed diff/patch, ECSS cascade, text measurement/wrapping, ordinary Box/flex/grid layout,
geometry snapshots, and paint-contribution merging.

Elisp/Emacs owns user Component execution, refs, Context, Actions, Data, Resources,
lifecycle callbacks, Emacs events/windows/fonts, and final patch submission. Elisp must
not reimplement Rust layout/cascade/diff; Rust must not read Emacs buffers or understand
Component slots.

## 5. Invariants and evolution

One transaction materializes stable identity, dependencies, layout snapshots, and paint
contributions once. Text paint changes do not rerun unrelated Components or layout.
Box geometry changes affect only the required layout owner. Component state/slot/list
changes affect only the owner of that structure. Failed Ebox/TP candidates preserve the
last committed result.

The clean public direction is `Text + Box(layout) + Component`. If concise syntax is
needed, `row`/`column`/`flex`/`grid` may be introduced as new compiler sugar, but they
are not compatibility aliases and must not become Runtime Components. `fragment` is
transparent structure. `spacer` and `flow` are not public ETAF types; the target Ebox
may replace the current `(block flow)` marker with ordinary Box/Text paths instead of
retaining a separate flow branch. The redesign does not preserve the old Host registry
names or add a compatibility layer. This target is not implemented merely by documenting it.
