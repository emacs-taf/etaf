# ETAF Module Responsibilities and Target Architecture (Design Proposal, Not Implemented)

> Status: design proposal. This document does not describe the currently delivered API.
> Current behavior remains defined by
> [`architecture.en.md`](../architecture.en.md),
> [`user-guide.en.md`](../user-guide.en.md), and passing tests.

This document defines only the target model, module owners, dependency direction, and
completion criteria. Implementation order belongs in a separate delivery plan;
historical names and compatibility policy do not shape the target architecture.

User mental cost is a hard constraint of this proposal: one capability has one canonical
name and one recommended spelling. Internal algorithms, backend nodes, wrappers, and
compatibility aliases must not become peer public concepts. Ordinary applications need
to learn only Text, Box, and Component; Fragment, layout details, and lower-level
packages enter through progressive disclosure.

## 1. Final Model

The ETAF/Ebox representation pipeline is layered by responsibility:

```text
AuthorView
  ↓ parse / desugar / string normalization
NormalizedView = Text | Box | Fragment | ComponentCall
  ↓ ETAF Runtime resolves ComponentCall
Resolved candidate + computed properties
  ├─ structure/geometry impact
  │    ↓ Fragment projection preserves RangeAnchors
  │  CanonicalEboxInput = Forest<TextNode | BoxNode> + RangeAnchors
  │    ↓ Ebox measure / layout
  │  LayoutPlan → GeometryPatch
  │
  └─ paint impact
       ↓ source-specific contribution adapter
       (ETAF: etaf-theme-tp; standalone Ebox: ebox-surface-tp)
     TP ContributionPlan → PaintPatch

GeometryPatch and PaintPatch join the existing TP transaction
  ↓ Emacs adapter commit / rollback
Published generation
```

These layers are not competing trees, nor do they repeatedly materialize the same tree.
Each lowering step consumes the identity, computed properties, and child order already
retained by the preceding layer; no fact is parsed or derived twice. LayoutPlan and
ContributionPlan are independent derivations of the same candidate transaction. A
paint-only path neither constructs CanonicalEboxInput nor runs layout. The two paths
join at the existing transaction participant. Plans own neither author identity nor DSL
nodes.

Illegal canonical node states must be unrepresentable:

```text
TextNode = {
  value: String,
  measurementProps,
  sourceHandle,
  eboxNodeId
}

BoxNode = {
  outer: inline | block,
  layout: Normal | RowConfig | ColumnConfig | FlexConfig | GridConfig,
  geometryProps,
  parentParticipationProps,
  children: [TextNode | BoxNode],
  sourceHandle,
  eboxNodeId
}
```

TextNode has no children, outer, or layout. BoxNode has no content or value. A BoxNode
stores its participation fields, but only its direct parent formatting context may
validate and interpret them.

`sourceHandle` is an opaque handle owned by the source layer: on the ETAF path it points
to a Runtime Text/Box/Range source; on the standalone Ebox DSL path it points to an Ebox
author source. `eboxNodeId` identifies only a retained Ebox geometry node. The
Renderer/surface retains the mapping between them. Ebox reconciliation must not assume
ownership of Component, Fragment, Range, or lifecycle identity.

The primary concepts a user needs to understand are only `Text`, `Box`, and `Component`.
`Fragment` is advanced structural syntax; `Host` is an internal Renderer term; and
`Ebox Node` is a backend object. None constitutes a second component model.

The complete NormalizedView shape is:

```text
View = Text
     | Box
     | Fragment
     | ComponentCall
```

Author syntax and normalized View are separate layers. ETAF and Ebox share this visual
author syntax:

```text
AuthorNode = String
           | TextForm
           | BoxForm
           | RowSugar
           | ColumnSugar
           | FlexSugar
           | GridSugar
```

`String` normalizes to Text. The five Box forms normalize to Box with the corresponding
typed Layout. Form names do not enter Runtime identity, diff, style, layout, or paint
protocols. ETAF additionally provides Fragment, ComponentCall, `expr`, and `slot`; the
Ebox DSL does not own those semantics.

The two author syntaxes share structural vocabulary and normalized results, but need not
share an evaluation environment: ETAF properties are Elisp expressions; the `.ebox` DSL
uses data forms. Quoting and expression differences belong only to their parsers and do
not create two canonical schemas.

A Flex/Grid item is the role a material child Box acquires in its parent formatting
context. It is neither another View nor a parent-child edge type. Participation
properties are stored on the child Box; their direct parent Flex/Grid Box owns
validation, computation, and dirty propagation.

`expr` and `slot` are computation/projection mechanisms, not visual nodes. The target
public View does not accept raw Ebox nodes. A missing rendering capability must first
become a typed View/Ebox capability with identity and impact contracts; it must not
bypass framework semantics through an opaque escape hatch.

## 2. Text, Box, and Fragment

### 2.1 Text

`Text` is a text leaf responsible for:

- exactly one payload that evaluates to a string;
- text paint such as font, foreground/background, and underline;
- text measurement, wrapping, and text-alignment input;
- optional identity, semantic, and event properties.

`Text` is always inline and does not expose `:outer`. It has no View children, cannot
nest Text, and cannot establish any layout context. Multiple styled runs are adjacent
Text nodes, not a Text subtree. Use an outer Box when block participation, padding,
border, dimensions, or child layout is required.

The Text grammars for the two authoring entry points differ precisely in evaluation
capability:

```text
ETAF TextForm = (text TEXT-PROP VALUE)
VALUE         = String | (expr :value Expr<String>)

Ebox TextForm = (text TEXT-PROP String)
```

All property key-value pairs must precede the one payload. Zero payloads, multiple
payloads, nested Text, or a non-string payload are errors. A bare string is only sugar
for an unstyled Text and has this one interpretation in every position.

### 2.2 The Two Orthogonal Box Axes

`Box` has both an external participation mode and an internal layout mode:

```text
:outer  = inline | block
layout = Normal | RowConfig | ColumnConfig | FlexConfig | GridConfig
```

- `:outer`: how this Box participates in its parent's `normal` layout;
- `layout` variant: how this Box arranges its own children.

The defaults are:

```text
Box  :outer block  :layout Normal
Text :fixed inline
```

The author layer does not expose a `:layout` property. Instead, exactly one layout is
selected by the form name:

```elisp
(box ...)                 ; Normal
(row ...)                 ; RowConfig
(column ...)              ; ColumnConfig
(flex ...)                ; FlexConfig
(grid ...)                ; GridConfig
```

Inline flex is therefore written `(flex :outer 'inline ...)`, not represented as a new
node type. `:outer` is a common property of every Box author form; each form's closed
property set constructs its corresponding layout config. To switch layout dynamically,
use `expr` to choose between View forms rather than treating `:layout` as an ordinary
dynamic style. Canonical Box uses a typed Layout variant; it does not expose `:inner` or
Ebox's backend representation `(:display (block flow))`.

### 2.3 Explicit Scope of normal

`normal` is a real but deliberately bounded layout context:

- consecutive inline `Text` or inline `Box` nodes enter one line flow and wrap to the
  available width;
- a block `Box` begins on a new line and establishes an independent block;
- inline lines before and after a block end at the block boundary;
- child order remains stable.

The target does not implement full browser CSS: it has no floats, tables,
absolute/fixed positioning, run-in, list-item, or arbitrary anonymous-box rules. Ebox
may map `normal` to an internal flow algorithm, but `flow` is not public ETAF vocabulary.

When the parent Layout is Row, Column, Flex, or Grid, the parent algorithm directly owns
child placement; a child's `:outer` does not change ordering. `:outer` determines inline
or block participation only when a node enters a `normal` parent.

### 2.4 Other Layout Modes

| Mode | Responsibility |
| --- | --- |
| `row` | simple horizontal sequential layout without Flex space distribution |
| `column` | simple vertical sequential layout without Flex space distribution |
| `flex` | Flex sizing, direction, wrapping, alignment, and gaps |
| `grid` | two-dimensional tracks, placement, spans, and gaps |

These are `Box` Layout variants, not Components, and they do not register a second set
of Runtime node names for `row`, `column`, `flex`, or `grid`. Author forms have exactly
one normalization mapping:

```text
box    → Box(layout = Normal)
row    → Box(layout = RowConfig)
column → Box(layout = ColumnConfig)
flex   → Box(layout = FlexConfig)
grid   → Box(layout = GridConfig)
```

ETAF and Ebox share these five Box author forms. The term “layout form” denotes only an
input spelling and its config schema; it does not imply a retained Host, node type, or
runtime dispatch.

The table above is the only normative lowering table. Ebox owns the canonical Layout
variants and config schemas. The ETAF parser evaluates Elisp and selects the variant
with the same name; it does not duplicate value rules. Cross-interface conformance tests
must prove that the two entry points produce the same canonical shape, computed defaults,
and errors for the same structure.

### 2.5 Ebox DSL Primitives and Sugar

ETAF View and the Ebox DSL are separate interfaces, but they share one visual author
syntax: Text is the text leaf, and Box is the structural/geometric container. The
complete visual syntax of the Ebox DSL is:

```elisp
"plain text"
(text TEXT-PROPS "styled text")
(box BOX-PROPS CHILD...)
(row BOX-PROPS CHILD...)
(column BOX-PROPS CHILD...)
(flex BOX-PROPS CHILD...)
(grid BOX-PROPS CHILD...)
```

A string always normalizes to Text. `text` accepts only textual content and Text
properties; `box` accepts only children and Box properties. The Ebox DSL does not accept
`:content`, so a string is never ambiguous between “Box content” and “child.” An empty
`(box :width ... :height ...)` is a valid empty geometry container.

`ebox-build` is the parse/desugar entry point for the author DSL. The public
programmatic port provides two typed constructors: `ebox-text-create` constructs a
TextNode, while `ebox-box-create` accepts a typed Layout variant and constructs a
BoxNode. Constructors accept neither author forms nor a flat bag of properties spanning
multiple layouts. The ETAF Renderer calls them directly; it does not reconstruct DSL.

The target public port does not retain untyped `(ebox-create :content ...)`. If the
runtime fuses a Text payload into adjacent Box storage for performance, that optimization
may occur only after canonical Text identity, range, and impact have been established,
and it must reversibly preserve those facts. A private storage encoding must not become
an author or public programmatic API. A Range descriptor is likewise an incremental
backend protocol, not a DSL node.

At the DSL boundary, each of the five Box author forms must immediately and statelessly
construct its typed Layout variant. They must not establish distinct node types,
identities, caches, validation paths, or rendering branches. Every author form rejects
`:layout`; layout-specific properties are accepted only by the corresponding form.

Other current DSL tags must be classified explicitly rather than presented beside the
primitives:

| Current tag | Classification | Target expression |
| --- | --- | --- |
| `ebox` | compatibility alias for `box` | remove; always write `box` |
| `spacer` | empty-Box convenience sugar | remove; use a childless `box` |
| `row` | Box layout form | retain and construct RowConfig |
| `column` | Box layout form | retain and construct ColumnConfig |
| `flex` | Box layout form | retain and construct FlexConfig |
| `grid` | Box layout form | retain and construct GridConfig |
| `item` | Flex wrapper/sugar | remove; put participation properties directly on the child Box |
| `grid-item` | Grid wrapper/sugar | remove; put placement properties directly on the child Box |

A direct child of Flex/Grid automatically acquires the item role; item is not a node
type. The only recommended path for nondefault participation is an explicit child Box:

```elisp
(flex
  (box :flex-grow 1 "Flexible")
  "Fixed")

(grid
  (box :grid-column '(1 :span 2) "Header")
  (box "Body"))
```

Participation/placement properties are stored on the child Box, but only its direct
parent Flex/Grid validates and consumes them; they must be rejected under the wrong
parent. A property change sends the parent layout owner through the geometry path, but
does not change the child Component/Text identity, lifecycle, or paint ownership. A
direct Text uses default item parameters; wrap it in an explicit Box when nondefault
parameters are needed.

The target Ebox DSL removes `ebox`, `spacer`, `item`, and `grid-item`, retaining Text,
Box, and the four layout sugars. Ebox still implements the layout algorithms separately,
but the canonical visual nodes remain only TextNode and BoxNode. Author syntax, canonical
tree, layout plan, and runtime storage are separate layers.

### 2.6 Fragment

`Fragment` is a nonvisual structural Range:

- it may carry zero, one, or many sibling Views;
- it creates no Box, dimensions, background, or layout context;
- Runtime may retain a stable Range identity for it and replace it locally;
- it accepts only children and an optional stable `:key`, not visual or event properties.

Fragment resolution does not discard Range identity. It splices material children into
the CanonicalEboxInput forest in order while producing a `{range-id, before, after}`
RangeAnchor. An empty Fragment still has an insertion anchor; a root Fragment may map to
zero or multiple forest roots. ETAF Runtime owns Range identity. Ebox consumes only the
descriptor to produce a local geometry patch. RangeAnchor is not a visual node and does
not participate in measurement.

A Component call itself has neither `:outer` nor Layout. Its root Text/Box determines
how it participates in parent layout. A transparent Component that returns a Fragment
may produce multiple siblings, so there is no single “Component outer box.”

### 2.7 Strings, Content, and Empty Boxes

A string child of a Box normalizes to Text:

```elisp
(box "this is text")
```

is equivalent to:

```elisp
(box (text "this is text"))
```

Neither the ETAF nor Ebox author DSL provides `(box :content "...")`. `:content` belongs
only to the existing untyped runtime storage; the target public programmatic port does
not retain it either. Exposing `:content` through the author DSL or a canonical
constructor would recreate two models—content and Text children.

ETAF also provides no `spacer` type. A Box with no children is an empty Box.

## 3. Property Contract

Properties form closed sets and are validated by owner. Unknown properties and
inapplicable combinations are errors.

| Owner | Property category | Representative properties |
| --- | --- | --- |
| ETAF Runtime metadata | identity/semantics/events/Behavior | `:key`, `:ref`, `:role`, `:aria-*`, `:on-*`, `:use` |
| ECSS author style source | selector/inline declarations | `:class`, `:id`, style declarations |
| Ebox TextNode | canonical text measurement | font metrics, wrap policy, intrinsic constraints |
| Ebox BoxNode | external/internal layout | `:outer`, typed Layout variant |
| Ebox BoxNode | geometry | width/height/min/max, margin, padding, border widths, box sizing, overflow |
| Flex container | layout | `:flex-direction`, `:flex-wrap`, `:justify-content`, `:align-items`, `:align-content`, `:gap` |
| Flex child Box | parent participation | `:order`, `:flex-grow`, `:flex-shrink`, `:flex-basis`, `:align-self` |
| Grid container | layout | track templates, auto flow, gaps, item/content alignment |
| Grid child Box | parent participation | `:grid-row`, `:grid-column`, row/column spans, self alignment |
| TP contribution | paint | color/background, underline/overline, border paint, visibility paint |

Rules:

- impact is a set, not a mutually exclusive enumeration;
- `:key` belongs to identity, not visual properties;
- `:class` enters only the ECSS selector; `:id` is one author input that may project to
  both the ECSS selector and semantic metadata, but two modules must not define its
  meaning independently;
- contributions such as color/background that do not alter metrics are paint-only;
- metric properties such as font family/size/weight are geometry + paint;
- padding, border width, and similar properties are geometry + paint;
- `:outer` and the Layout variant are structure + geometry;
- Flex/Grid participation is stored on the child Box, but a change dirties only the
  corresponding parent layout owner for geometry;
- ECSS cascade output must retain the impact set above;
- the ETAF/Ebox candidate normalization pipeline parses each property fact once, then
  passes it by owner/impact to Runtime metadata, ECSS, Ebox geometry, and the appropriate
  TP adapter; owners do not reparse the original plist;
- a multi-impact fact such as border or font may project to both geometry and paint
  fields, but its computed value materializes only once and paint-only state is not
  duplicated in the Ebox node;
- TP consumes only already-parsed paint contributions and does not determine layout
  validity;
- a structural property change must transactionally rebuild the corresponding layout
  context and cannot take the paint-only fast path.

Validation has two deterministic phases:

1. Normalization performs form-local schema validation. `box` accepts only
   Normal/Common Box properties; only `flex` accepts Flex container config; only `grid`
   accepts Grid container config. Other layout-specific properties fail immediately.
2. After Component/Fragment resolution and ECSS cascade, Ebox performs parent-context
   validation on the candidate final tree. Flex participation
   (grow/shrink/basis/order/self alignment) is allowed only on a child Box whose direct
   parent is Flex. Grid placement/self alignment is allowed only on a child Box whose
   direct parent is Grid. A root or wrong parent is an error.

The same Box may establish one Layout internally while participating in a different
parent Layout externally—for example, `(flex :grid-column ... )` under Grid. These are
two orthogonal fields, not a property conflict. When a dynamic transaction changes both
parent Layout and child participation, only the final candidate is validated; any
failure preserves the previous generation. Unlike browsers, which commonly treat an
inapplicable CSS property as having no effect, this framework does not silently ignore
invalid combinations.

## 4. Module Owners

### 4.1 ETAF Core

`etaf-view`:

- defines and normalizes Text, Box, Fragment, and ComponentCall;
- normalizes strings to Text;
- normalizes the `row`, `column`, `flex`, and `grid` author sugars to Box;
- validates closed property sets, slots, `:key`, and expression boundaries;
- does not measure, lay out, or write buffers.

`etaf-component`:

- defines Component props, `:view`, `:setup`, and `:styles`;
- does not schedule Runtime or call Ebox.

`etaf-runtime`:

- owns Component/Fragment/Range identity, reactive dependencies, Context, Theme, Action,
  Behavior, Data, Resource, and lifecycle;
- owns candidate generation, transactions, commit authority, rollback, and disposal;
- decides which Component, Range, structural property, or paint contribution a change
  affects;
- does not compute pixels or layout.

`etaf-renderer`:

- is the only ETAF → Ebox lowering adapter;
- converts the structure/geometry projection of ResolvedView into a
  CanonicalEboxInput forest, RangeAnchors, and typed measurement/geometry properties;
- does not execute Component lifecycle or access Ebox private state.

`etaf-theme-tp`:

- is the only adapter from ETAF/ECSS computed paint contributions to TP;
- produces ContributionPlan without measuring, laying out, or owning TP priority/commit
  authority;
- does not call `etaf-renderer` geometry lowering for a paint-only candidate.

Theme semantic tokens and inheritance belong to ETAF Context. TP does not own business
meaning such as “dark theme.”

### 4.2 Ebox

Ebox owns:

- normalization of String/Text/Box and layout-sugar expansion in the Ebox DSL;
- contextual validation, parent-layout consumption, and dirty propagation of child Box
  participation;
- typed TextNode/BoxNode constructors and canonical property schemas;
- text measurement, wrapping, and line layout;
- the `normal`, `row`, `column`, `flex`, and `grid` geometry algorithms;
- width/height, the box model, overflow, scrolling, and viewport behavior;
- stable Ebox node identity, geometry snapshots, and structural patch plans.

Ebox does not understand Component, slot, Context, Action, Behavior, Data, or Resource,
and does not determine paint-contribution priority.

Author paint from the standalone Ebox DSL is projected by the `ebox-surface` TP adapter
into an inline ContributionPlan. It and ETAF's `etaf-theme-tp` are two source adapters
that consume the same public TP contribution contract. Neither puts paint-only
properties back into CanonicalEboxInput, nor owns TP priority, journal, or commit
authority.

`ebox-build` exclusively owns parsing/desugaring author forms. `ebox-text-create` and
`ebox-box-create` accept already evaluated canonical parameters and validate only typed
node invariants. All three ultimately consume the same canonical property schema and
enter the same layout implementation. The ETAF Renderer calls the typed programmatic
port directly; it must not reconstruct DSL and trigger a second parse. Existing untyped
`ebox-create :content` is not part of the target public port.

Logical boundaries:

```text
ebox-core   pure measurement, layout, snapshots, and structural patches
ebox-emacs  font/window capabilities, buffer positions, and structural commit
```

These boundaries need not immediately become two distribution packages, but pure
layout and Emacs side effects must be independently testable.

Measuring the CanonicalEboxInput forest produces a LayoutPlan. The plan contains only
measurement results, coordinates, dimensions, layout owners, and geometry deltas needed
by the candidate. It introduces no author-visible node type and owns no
Component/Text/Box identity. After commit or rollback, it may be retained as input to
the next incremental update or released.

### 4.3 ECSS

ECSS owns selectors, cascade, inheritance, and computed properties. Its output must
carry each property's structure/geometry/paint impact. ECSS neither performs layout nor
writes buffers.

### 4.4 TP and the Commit Boundary

TP owns:

- the priority of paint contributions from Theme, Component style, state, inline style,
  and other sources;
- paint-operation merging;
- the Emacs text-property journal, apply, and rollback.

The authority order for one update is fixed:

```text
ETAF Runtime creates the candidate and owns commit authority
    ↓
Ebox candidate stage produces the structure/geometry patch
    ↓
Ebox surface adds a rollback-capable participant to the existing TP transaction
    ↓
TP precommits paint; Ebox commit publishes the Emacs surface
    ↓
Only after all succeed does ETAF Runtime promote the generation
Any failure rolls back through the existing Ebox/TP/Runtime journals
```

Ebox does not own TP paint priority; TP does not own node layout; neither may promote a
Runtime generation independently. The target introduces no second cross-package
coordinator. The existing transaction participant is the sole mechanism aligning the
Ebox surface with TP/Emacs commit.

### 4.5 Upper-Level Packages

| Package | Owns | Does not own |
| --- | --- | --- |
| `etaf-ui` | ordinary Components such as Button, Checkbox, Label, Panel, and DataGrid | a second Widget Runtime or layout engine |
| `etaf-sqlite` | SQLite Data Source, queries, mutations, transactions, and disposal | Data Controller, View, or UI |
| `etaf-performance` | application-neutral operations/stages, environment, statistics, and reports | example semantics, layout rules, or scheduling authority |
| `ebox-playground` | examples and verification of the public Ebox layout API | ETAF |
| `etaf-playground` | ETAF/UI/SQLite composition examples, loading commands, and status display | Core syntax, Runtime, or performance protocols |

`etaf-performance` is an independent optional package. ETAF, Ebox, TP, and SQLite do not
depend on it; it observes and correlates stages only through public boundaries.

The Playground `.etaf` manifest belongs to the Playground. If a general compiler exists
in the future, it must lower to the same View/Component contract and must not create a
second Runtime.

## 5. Dependency Direction

```text
etaf-ui ─────────────▶ ETAF Core ─────────────▶ Ebox public port
etaf-sqlite ─────────▶ ETAF Data contract
etaf-playground ─────▶ ETAF + optional UI/SQLite
ebox-playground ─────▶ Ebox only
etaf-performance ────▶ public observation boundaries only

ETAF Renderer ───────▶ ECSS computed properties
Ebox style pipeline ─▶ ECSS computed-properties port
ETAF Runtime  ───────▶ Ebox/TP transaction participants
etaf-theme-tp ───────▶ TP contribution contract
Ebox surface ────────▶ TP inline contribution + transaction participant
```

Reverse dependencies are forbidden: Ebox does not depend on ETAF; TP does not parse
View; ECSS does not write buffers; UI does not call Ebox private functions; SQLite does
not know UI; and Playground does not inject protocols into Core.

## 6. Rust and Elisp

Module boundaries precede implementation language. Deterministic computation moves to
Rust only after interfaces and equivalence tests are frozen:

```text
Rust candidates:
  normalized View validation and structural diff (over opaque stable IDs only)
  ECSS cascade
  Text measurement input processing and Ebox layout
  pure-data computation of geometry/paint patches

Elisp / Emacs:
  execute user Components, refs, Context, Action, Data, Resource, and lifecycle
  database and external I/O
  Emacs events, font/window capabilities, and final commit
```

Component identity, dependency ownership, TP priority, and generation authority do not
move merely because implementation moves to Rust. Rust may at most compute side-effect-
free candidate paint operations; TP continues to own contribution slots, priority,
journaling, and commit/rollback. Elisp does not repeat diff, cascade, layout, or text
scans already completed by Rust.

## 7. Correctness and Performance Invariants

- View, computed properties, geometry snapshots, and paint contributions each
  materialize once per transaction;
- a Text paint-only contribution change neither executes unrelated Components nor runs
  layout;
- changes to `:outer`, the Layout variant, or geometry run only the affected layout
  owner;
- Fragment/slot/list changes replace only the corresponding Range;
- failure of any Ebox/TP/Emacs participant preserves the previous committed generation;
- resize reflows immediately from current window facts and does not change interaction
  semantics through hidden debouncing;
- the performance recorder does not change the measured path.

The final gates must cover:

- structural equivalence of Text/Box/Fragment;
- strings normalize only to Text, and both author DSLs reject `box :content`;
- Text is always inline and has exactly one string payload; nested, empty, or multiple
  payloads are errors;
- canonical shape, defaults, and errors of the five ETAF/Ebox Box forms agree across
  interfaces;
- the five Box author forms each produce their one corresponding Layout, and every
  author `:layout` is an error;
- Flex/Grid participation is permitted only on a child Box under the matching parent;
  the wrong context reports a precise error;
- a participation change runs only the parent layout and does not rebuild child identity
  or lifecycle;
- typed Text/Box constructors reject mutually exclusive fields and layout sugar, and
  share their result with `ebox-build`;
- CanonicalEboxInput contains no paint-only fields; the ETAF and standalone Ebox paint
  adapters each project exactly once;
- sourceHandle and eboxNodeId have independent lifetimes, and reconciliation does not
  change source identity;
- legal and failing `outer × layout` combinations;
- GUI behavior of normal inline/block, row, column, flex, and grid;
- layout participation of Component roots and transparent Fragments;
- empty, single-root, and multi-root Fragments all retain RangeAnchor and support local
  replacement;
- a paint-only candidate does not construct LayoutPlan, while geometry and paint patches
  join in the existing transaction;
- style/Theme/TP priority and transactional rollback;
- continuous resize of Research Shelf and Flex reference;
- both p95 and max at or below 50 ms in fixed real scenarios.

## 8. Current Implementation Gaps and Non-Goals

The current code still registers `text`, `fragment`, `container`, `row`, `column`,
`stack`, `flex`, `grid`, and `spacer`, and provides `raw-ebox`. Target `box`, `:outer`,
and typed Layout are not yet implemented; the target public View also does not retain
`raw-ebox`.

The current Ebox DSL still encodes `box :content` and bare strings directly as untyped
`ebox-create :content`, and constructs `item` and `grid-item` as runtime wrappers. The
target adds an explicit TextNode/BoxNode canonical IR and typed constructors; retains
Text, Box, and the five Box author forms; and removes `:content` from author/public
constructor syntax as well as removing `ebox`, `spacer`, `item`, and `grid-item`.

This is a clean redesign. It does not require old Host names or old `.etaf` files to
continue working, and it adds no long-lived compatibility layer. Until implementation
is complete, the formal architecture and user guide must not describe target syntax as
the current API.

Non-goals:

- implementing full browser CSS;
- providing `spacer`, public `flow`, or `(box :content ...)` in the author DSL;
- making Flex/Grid item an author node, visual wrapper, or independent identity;
- allowing applications to inject raw Ebox Nodes into View;
- making layout modes Components or a second set of Runtime nodes;
- retaining old Host aliases or optional shorthand spellings in Core;
- allowing Playground, UI, or database packages to own Core protocols;
- adding App precompilation artifacts before real compile cost and runtime benefit exist.
