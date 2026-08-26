# ETAF Module Responsibilities and Target Architecture (Unimplemented Proposal)

> Status: design proposal. This is not the delivered API. Current behavior remains
> defined by [`architecture.en.md`](../architecture.en.md),
> [`user-guide.en.md`](../user-guide.en.md), and passing tests.

This document defines only the target model, module owners, dependency direction, and
completion criteria. Delivery sequencing belongs in a separate implementation plan;
historical names and compatibility do not shape the target architecture.

## 1. Final model

```text
Component semantics and ownership
    ↓
View: Text / Box / Fragment
    ↓
Ebox: measurement, layout, geometry patches
    ↓
TP + Emacs adapter: paint and final submission
```

The main public concepts are `Text`, `Box`, and `Component`. `Fragment` is advanced
structure, `Host` is an internal Renderer term, and an Ebox Node is a backend object.

The complete normalized View shape is:

```text
View = Text
     | Box
     | Fragment
     | ComponentCall
     | RawEbox
```

`expr` and `slot` are computation/projection mechanisms, not visual nodes. `RawEbox`
is an opaque low-level escape and does not inherit normal View semantics.

## 2. Text, Box, and Fragment

### 2.1 Text

Text is a leaf that owns strings and inline Text runs, typography/paint, text
measurement and wrapping input, and optional identity/semantic/event properties.

Text defaults to `:outer 'inline`. It cannot own Box/Component children or establish
row, column, flex, or grid layout. Use an outer Box for padding, border, dimensions, or
child layout.

### 2.2 Box axes

```text
:outer  = inline | block
:layout = normal | row | column | flex | grid
```

`:outer` controls participation in a parent normal layout. `:layout` controls child
layout. Defaults are `Box: block/normal` and `Text: inline`.

```elisp
(box :outer 'inline :layout 'flex ...)
```

This is inline-flex: an orthogonal combination, not another node type. ETAF exposes
`:outer` and `:layout`, not `:inner` or Ebox's raw display-pair representation.

### 2.3 Bounded normal layout

Normal layout supports only:

- consecutive inline Text/Box nodes in one wrapping line flow;
- block Boxes starting a new independent block;
- stable child order and block boundaries ending adjacent inline lines.

It does not implement full browser CSS: no floats, tables, absolute/fixed positioning,
run-in, list-item, or arbitrary anonymous-box rules. Ebox may map `normal` to an
internal flow algorithm; `flow` is not ETAF vocabulary.

For row, column, flex, or grid parents, the parent algorithm owns item placement and a
child's `:outer` does not change ordering. `:outer` is consumed only by a normal parent.

### 2.4 Other layout modes

| Mode | Responsibility |
| --- | --- |
| `row` | simple horizontal order without Flex distribution |
| `column` | simple vertical order without Flex distribution |
| `flex` | Flex sizing, direction, wrapping, alignment, and gaps |
| `grid` | two-dimensional tracks, placement, spans, and gaps |

They are Box modes, not Components or alternate Runtime node names. The only canonical
surface is `(box :layout 'MODE ...)`; core provides no layout-name aliases.

### 2.5 Fragment

Fragment is a nonvisual structural Range. It may contain zero, one, or many sibling
Views, creates no Box or layout context, and may carry only a stable `:key` plus
children. Runtime may retain and replace its Range independently.

A Component call has no fixed outer/layout properties. Its root Text/Box determines
participation. A transparent Component returning a Fragment may have multiple roots.

### 2.6 Strings, content, and empty Boxes

Strings under a Box normalize to Text, so `(box "text")` equals
`(box (text "text"))`. ETAF does not expose `(box :content ...)`; `:content` remains an
Ebox backend field. ETAF also has no spacer type: a childless Box is an empty Box.

## 3. Property contract

Properties form closed, owner-specific schemas. Unknown or inapplicable combinations
fail explicitly.

| Owner | Category | Representative properties |
| --- | --- | --- |
| Text | outer participation | `:outer` |
| Text | text/paint | `:face`, `:color`, `:bgcolor`, `:wrap-mode`, `:text-align` |
| Box | outer/inner layout | `:outer`, `:layout` |
| Box | geometry/surface | width/height/min/max, margin, padding, border, box sizing, overflow |
| Flex container/item | layout/participation | direction, wrap, alignment, gap, grow/shrink/basis/order |
| Grid container/item | layout/participation | tracks, auto flow, placement, spans, alignment, gap |
| Text/Box | identity/semantics | `:key`, `:ref`, class/id/role/ARIA/events/Behaviors |

Key rules:

- `:key` is identity metadata, not paint;
- outer/layout/layout-specific properties have structure/geometry impact;
- color/background/typography have paint impact;
- ECSS preserves that impact classification;
- TP consumes resolved paint contributions only;
- structural changes transactionally replace the required layout context.

## 4. Module owners

### ETAF Core

`etaf-view` owns normalized View shapes, string-to-Text normalization, closed property
schemas, slots, keys, and expression boundaries. It does not measure, lay out, or write
buffers.

`etaf-component` owns Component props and `:view`/`:setup`/`:styles` definitions. It
does not schedule Runtime or call Ebox.

`etaf-runtime` owns Component/Fragment/Range identity, reactive dependencies, Context,
Theme, Actions, Behaviors, Data, Resources, lifecycle, candidate generations, commit
authority, rollback, and disposal. It does not compute pixels.

`etaf-renderer` is the only ETAF-to-Ebox lowering adapter. It consumes normalized View
and computed properties without accessing Ebox private state.

Theme token meaning and inheritance belong to ETAF Context, not TP.

### Ebox

Ebox owns Text measurement/wrapping/line layout, normal/row/column/flex/grid geometry,
the box model, overflow/scroll/viewport behavior, stable Ebox node identity, geometry
snapshots, and structural patch plans. It does not know Component semantics or paint
contribution priority.

Logical boundaries:

```text
ebox-core   pure measurement, layout, snapshots, structural patches
ebox-emacs  font/window capabilities, buffer positions, structural submission
```

These need not become separate distribution packages immediately, but must remain
independently testable.

### ECSS

ECSS owns selectors, cascade, inheritance, and computed properties. Its output retains
structure/geometry/paint impact. ECSS does not run layout or write buffers.

### TP and commit boundary

TP owns paint-contribution priority, paint-operation merging, Emacs text-property
journaling, application, and rollback.

```text
ETAF Runtime creates a candidate and owns commit authority
    ↓
Ebox stages structural/geometry patches
    ↓
TP stages paint patches
    ↓
Emacs adapter atomically applies both
    ↓
ETAF Runtime promotes the generation; failure rolls participants back
```

Ebox does not own TP priority, TP does not own layout, and neither participant may
promote a Runtime generation.

### Upper packages

| Package | Owns | Does not own |
| --- | --- | --- |
| `etaf-ui` | ordinary reusable Components | another Runtime or layout engine |
| `etaf-sqlite` | SQLite Data Source and its transactions/disposal | Data Controller or UI |
| `etaf-performance` | application-neutral operations/stages/statistics/reports | example semantics or scheduling authority |
| `ebox-playground` | public Ebox examples/verification | ETAF |
| `etaf-playground` | ETAF/UI/SQLite composition examples and tooling | core protocols |

`etaf-performance` is a separate optional package. No measured package depends on it;
it observes only public boundaries. A Playground `.etaf` manifest belongs to the
Playground. Any future general compiler must lower to the same View/Component contract.

## 5. Dependency direction

```text
etaf-ui ─────────────▶ ETAF Core ─────────────▶ Ebox public port
etaf-sqlite ─────────▶ ETAF Data contract
etaf-playground ─────▶ ETAF + optional UI/SQLite
ebox-playground ─────▶ Ebox only
etaf-performance ────▶ public observation boundaries only

ETAF Renderer ───────▶ ECSS computed properties
ETAF Runtime  ───────▶ Ebox/TP transaction participants
```

Reverse dependencies are forbidden: Ebox never depends on ETAF, TP never parses View,
ECSS never writes buffers, UI never calls Ebox private APIs, SQLite never knows UI, and
Playgrounds never inject protocols into core.

## 6. Rust and Elisp

Boundaries precede implementation language. Deterministic kernels may move to Rust only
after contracts and equivalence tests are stable:

```text
Rust candidates:
  normalized View validation and structural diff over opaque stable IDs
  ECSS cascade
  Text-measurement input processing and Ebox layout
  pure geometry/paint patch computation

Elisp / Emacs:
  user Components, refs, Context, Actions, Data, Resources, lifecycle
  database and external I/O
  Emacs events, font/window capabilities, and final submission
```

Component identity, dependency ownership, TP priority, and generation authority do not
move merely because a kernel is written in Rust. Elisp must not repeat Rust diff,
cascade, layout, or text scans.

## 7. Correctness and performance invariants

- View, computed properties, geometry snapshots, and paint contributions materialize
  once per transaction;
- Text paint changes do not execute unrelated Components or layout;
- outer/layout/geometry changes affect only the required layout owner;
- Fragment/slot/list changes replace only their Range;
- Ebox/TP/Emacs participant failure preserves the last committed generation;
- resize uses current window facts immediately, without hidden debouncing semantics;
- instrumentation does not change the measured path.

Final gates cover structural equivalence, legal/illegal outer-layout combinations,
normal inline/block behavior, row/column/flex/grid GUI behavior, Component roots and
Fragments, style/Theme/TP priority and rollback, continuous Research Shelf/Flex
reference resize, and p95/max at or below 50ms in fixed real scenarios.

## 8. Current gap and non-goals

Current code still registers `text`, `fragment`, `container`, `row`, `column`, `stack`,
`flex`, `grid`, and `spacer`. Target `box`, `:outer`, and `:layout 'normal` are not
implemented.

This is a clean redesign: old Host names and old `.etaf` sources need not continue to
run, and no long-lived compatibility layer is added. Formal architecture/user docs must
not present target syntax as delivered before implementation is complete.

Non-goals:

- full browser CSS;
- spacer, public flow, or `(box :content ...)`;
- layout modes as Components or alternate Runtime nodes;
- old Host aliases or optional layout shorthand in core;
- core protocols owned by Playground/UI/database packages;
- App precompilation without measured compile cost and runtime benefit.
