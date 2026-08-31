# ETAF Module Responsibilities and Target Architecture (Design Proposal, Not Implemented)

> Status: design proposal. This document does not describe the currently delivered API.
> Current behavior remains defined by
> [`architecture.en.md`](../architecture.en.md),
> [`user-guide.en.md`](../user-guide.en.md), and passing tests.

This document defines only the target model, module owners, dependency direction, and
completion criteria. Implementation order belongs in a separate delivery plan;
historical names and compatibility policy do not shape the target architecture.

User mental cost is a hard constraint of this proposal: one capability has one canonical
identity, canonical name, and recommended spelling. A small set of aliases may exist
only as parse-time input sugar and must not become peer public concepts. Internal
algorithms, backend nodes, wrappers, and compatibility aliases must not become peer
public concepts. Ordinary applications need to learn only Text, Box, and Component;
Fragment, layout details, and lower-level packages enter through progressive disclosure.

## 0. Design Decision Summary

Ordinary ETAF users learn only Text, Box, Component, and these structural forms:

```elisp
"plain text"
(text PROPS "styled text")
(box PROPS CHILD...)
(row PROPS CHILD...)
(column PROPS CHILD...)
(flex PROPS CHILD...)
(grid PROPS CHILD...)
```

`row/column/flex/grid` are only layout forms of Box. User properties fall into metadata,
semantics/events, visual style, and parent participation. They use semantically aligned
standard CSS names, a small set of explicit ETAF/Ebox-specific properties, and a small
set of parse-time aliases. Users do not interact with the Ebox, TP, or Emacs backend.

Standalone Ebox users access the same visual forms as inert data syntax through
`ebox-build`, but have no Component, Fragment, expr, slot, or lifecycle.

Framework integrators use only typed Text/Box constructors, LayoutConfig, and the render
and commit boundaries. They do not reconstruct DSL, rerun cascade, or generate Emacs
text properties.

Internal execution has only four layers:

```text
Author API
  → Canonical Model
  → Render Plan (Ebox geometry + TP paint + ETAF semantics)
  → Emacs Adapter commit
```

Core ownership remains unchanged: ETAF Runtime owns identity/lifecycle/reactivity; ECSS
owns selectors/cascade/computed style; Ebox owns measurement/geometry; TP owns paint
priority/transactions; only the final adapter owns Emacs text properties such as
`face`, `display`, and `keymap`.

Ordinary user documentation does not mention NormalizedView, PropertyDefinition,
ProjectionPlan, node IDs, RangeAnchor, or TP slots. The framework integration reference
describes typed constructors; only internal architecture sections describe facts, plans,
patches, and journals.

## 1. Final Model

The ETAF/Ebox representation pipeline is layered by responsibility:

```text
AuthorView
  ↓ parse / desugar / string normalization
NormalizedView = Text | Box | Fragment | ComponentCall
  ↓ ETAF Runtime resolves ComponentCall
Resolved candidate + source facts
  ↓ exactly one style adapter is selected for the current surface
  ETAF Style Adapter | Ebox Standalone Style Adapter
  ↓ ECSS selector / cascade / inheritance (exactly once)
Computed property facts + impact sets
  ├─ structure/geometry impact
  │    ↓ Fragment projection preserves RangeAnchors
  │  CanonicalEboxInput = Forest<TextNode | BoxNode> + RangeAnchors
  │    ↓ Ebox measure / layout
  │  LayoutPlan → GeometryPatch
  │
  └─ paint impact
       ↓ shared property projector
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

`:class`, `:id`, and author `:key` all belong to the source layer, but `:key` is an
identity fact and never enters visual source. Standalone Ebox DSL and ETAF View produce
isomorphic StyleSourceFact values; each surface selects exactly one adapter to invoke
ECSS. ETAF Style Adapter owns Component-scope assembly and stylesheet lifetime on an
ETAF surface, while Ebox Standalone Style Adapter owns them on a standalone surface.
Both reuse the same ECSS implementation and Ebox property registry/projector, so one
surface never runs cascade twice. The same parsed `:id` fact may also project to ETAF
semantic metadata, but it is not reparsed or recascaded.

Typed Text/Box constructors accept only an opaque `sourceHandle` plus already-computed
owned facts. They neither accept nor retain `:class/:id/:key`, and Ebox
measurement/layout core never reads source metadata. StyleEnvironment belongs to the
current surface/runtime and must not be implemented as a process-global stylesheet or
metadata table.

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
| ETAF Runtime metadata | identity/semantics/events/Behavior | `:key`, `:ref`, `:role`, `:disabled`, `:tab-index`, `:aria-*`, `:on-*`, `:use` |
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
- ETAF/Ebox candidate normalization parses the author plist once and produces canonical
  declarations/metadata facts; ECSS computes the computed facts once; projection then
  passes them by owner/impact to Runtime, Ebox, and TP, and no owner reparses the original
  plist;
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

### 3.1 Canonical Property Composition of Author Forms

The following compositions are the normative public schemas. Shorthands expand
immediately upon entering the canonical registry and do not create a second set of owner
or impact rules.

```text
SharedSourceMetadata = :key :class :id
ETAFOnlyMetadata     = :ref :role :disabled :tab-index :aria-* :on-* :use
ETAFSourceMetadata   = SharedSourceMetadata + ETAFOnlyMetadata
EboxSourceMetadata   = SharedSourceMetadata

TextStyle =
  :font-family :font-size :font-weight :font-style
  :color :background-color
  :text-decoration-line :text-decoration-color :text-decoration-style

BoxFrame =
  :outer
  :width/:min-width/:max-width
  :height/:min-height/:max-height
  :box-sizing
  margin/padding shorthands and logical/physical longhands
  border shorthands and width/style/color longhands
  :wrap-mode (word | char | kp | none)
  :overflow :visibility
  inherited standard text style source such as font/color
  non-inherited surface source such as :background-color

NormalConfig = :text-align

RowConfig = :item-gap :cross-align
ColumnConfig = :item-gap :cross-align

FlexConfig =
  :flex-direction :flex-wrap :flex-flow
  :justify-content :align-items :align-content
  :gap :row-gap :column-gap

GridConfig =
  :grid-template-columns :grid-template-rows
  :grid-auto-columns :grid-auto-rows :grid-auto-flow
  :justify-items :align-items :justify-content :align-content
  :gap :row-gap :column-gap

FlexParticipation =
  :order :flex :flex-grow :flex-shrink :flex-basis :align-self

GridParticipation =
  :order :grid-column :grid-row :align-self :justify-self
```

The six visual forms are produced only through composition:

```text
text   = SurfaceSourceMetadata + TextStyle + one String
box    = SurfaceSourceMetadata + BoxFrame + NormalConfig + ParentParticipation + children
row    = SurfaceSourceMetadata + BoxFrame + RowConfig + ParentParticipation + children
column = SurfaceSourceMetadata + BoxFrame + ColumnConfig + ParentParticipation + children
flex   = SurfaceSourceMetadata + BoxFrame + FlexConfig + ParentParticipation + children
grid   = SurfaceSourceMetadata + BoxFrame + GridConfig + ParentParticipation + children
```

`SurfaceSourceMetadata` resolves to ETAFSourceMetadata on an ETAF surface and to
EboxSourceMetadata on a standalone Ebox surface. `:item-gap` and `:cross-align` are Ebox
Row/Column extensions, not CSS `gap`/`align-items`: the former inserts fixed spacing
along the main axis; the latter accepts `start|center|end|stretch` and controls the cross
axis. Flex/Grid `:gap` retains standard CSS shorthand semantics and expands to both
row-gap and column-gap.

The final direct parent selects `ParentParticipation` as Default,
FlexParticipation, or GridParticipation. A candidate cannot carry mutually exclusive
Flex-only and Grid-only fields simultaneously. Text accepts neither BoxFrame,
LayoutConfig, nor Participation; wrap it in an explicit Box when those capabilities are
required. The Ebox DSL does not accept ETAFOnlyMetadata.

### 3.2 Naming Layers and Backend Projection

Names in the author layer belong to four namespaces: CSS, ETAF, Ebox, and the optional
Emacs adapter. A standard CSS name is adopted only when its applicable objects, value
grammar, defaults/inheritance, impact, and observable behavior match CSS or form an
explicit subset. A capability that is conceptually similar but semantically different
retains a precise ETAF/Ebox name; familiarity does not justify an incorrect standard
name.

The target public API classifies historical and backend names as follows:

```text
:bgcolor          → exact alias of :background-color
:font-height      → removed from core; optional Emacs adapter source only
:font-slant       → exact alias of :font-style with identical value grammar
:border-top-p     → retained Ebox boolean shorthand for top width/style
:grid-column-span → Ebox positive-integer shorthand for :grid-column (span N)
:grid-row-span    → Ebox positive-integer shorthand for :grid-row (span N)
:face             → not a core canonical property
:display          → private Ebox/Emacs lowering field
:content          → private legacy runtime storage field
```

`:wrap-mode` is not equivalent to CSS `white-space`, `overflow-wrap`, `word-break`, or
`line-break`. It therefore remains the sole public name in the Ebox namespace, with its
value restricted to `word`, `char`, `kp`, or `none`. `char` breaks only at complete
grapheme-cluster boundaries, while `kp` selects Knuth–Plass paragraph layout. If complete, semantically equivalent
CSS properties are implemented in the future, one explicit migration must replace it;
the two naming systems must not be retained indefinitely.

Only Box author forms accept `:wrap-mode`; it specifies the soft-wrapping policy for
that Box's content. Text forms do not expose a second author path. During computation,
the Box policy is inherited as Text measurement input: Text executes line breaking but
does not own the declaration. `none` disables only automatic soft breaks and preserves
explicit newlines. The independent `:overflow` property decides what happens after
layout when unbroken content exceeds the Box; wrapping never implies clipping or
scrolling.

Standard CSS shorthands have exactly one expansion rule, including `:margin`,
`:padding`, `:border`, `:gap`, `:flex`, `:flex-flow`, `:grid-column`, and `:grid-row`.
The canonical registry uses namespaced IDs such as `ebox/font-size` and
`ebox/background-color`; authors write only keywords and never see internal IDs.

Every definition records its naming domain and relationship to standards explicitly:

```text
PropertyDefinition {
  authorName
  canonicalId
  aliases
  namespace: css | etaf | ebox | emacs-adapter
  standardReference
  semanticSubset
  acceptedContexts
  valueGrammar
  initial
  inherits
  impactSet
  owner
  projections
}
```

An alias must have exactly the same contexts, value grammar, owner, impact, and
projections as its canonical property, and it cannot transform the value. A shorthand
performs one-to-many expansion; an adapter source resolves a composite backend value.
An alias resolves to canonicalId immediately at the parse entry point, so computed
style, caches, diff, Ebox, TP, and Rust never see it. PropertyDefinition registration
rejects canonical/alias collisions. Writing both the canonical name and an alias—or
repeating an alias—in the same declaration is an error rather than an implicit
last-wins rule. The source spelling may be retained only in diagnostic provenance.

Property references list aliases under the canonical property, for example:

```text
background-color
  Canonical: :background-color
  Aliases:   :bgcolor
```

They do not list `bgcolor` as a second capability. In the first phase, aliases are
registered by the owning package's schema; process-global user aliases are not exposed.
An upper-level package that needs an alias must scope it to its own schema and must not
pollute the global Ebox visual-property domain.

`:border-top-p` is not an alias but a retained Ebox boolean shorthand: `t` expands to
`:border-top-width 1` + `:border-top-style solid`, while `nil` expands to width 0 + style
none. Color comes independently from `:border-top-color`, `:border-color`, or the default
foreground. Use standard `:border-top` or its longhands when full control is required.
Mixing `:border-top-p` with its width/style outputs in the same declaration is an error;
different cascade sources still override one another normally through ECSS.

Canonical border widths are always nonnegative integer pixels, and `style=none` has a
used width of zero. Every successful adapter projection must be exact; it may not collapse
width to a boolean or character column. The current Emacs text adapter can exactly express
arbitrary left/right widths and 0/1px top/bottom lines. Thicker horizontal borders raise a
capability error before publication and preserve the old generation instead of degrading
silently. Core retains all four width/style/color facts so a future pixel-coordinate adapter
can widen the success domain.

`:grid-column-span` and `:grid-row-span` are likewise not aliases. They accept only a
positive integer and respectively expand to the corresponding Grid shorthand's `span N`
value; mixing either with `:grid-column` or `:grid-row` in the same declaration is an
error. `:font-slant` is an exact alias only when its value grammar is identical to
`:font-style`. The Emacs face-height semantics of `:font-height` must not masquerade as
CSS `font-size`.

The Emacs text property names `face`, `display`, `keymap`, `mouse-face`, `help-echo`,
`invisible`, `line-prefix`, `wrap-prefix`, and sticky properties belong only to the final
adapter. Ebox core, ETAF Runtime, ECSS, and Rust neither produce nor consume these names
directly. Reuse of a named Emacs face, when needed, is available only through an
optional adapter's explicit `:emacs-face` source input. That input immediately resolves
to standard font/paint facts and computes their impact; the raw face symbol does not
enter the canonical IR.

A typical projection is:

```text
:font-weight bold
  → ebox/font-weight, impact {geometry, paint}
  → Ebox Text measurement weight
  + TP face-weight contribution
  → Emacs adapter emits face :weight

:width 120
  → ebox/width, impact {geometry}
  → Ebox GeometryPatch
  → Emacs adapter may emit display space width
```

### 3.3 Unified Property Facts and Projection Layer

The unified layer is not a direct `author keyword → Emacs text property` dictionary.
One property may affect both measurement and paint; several properties may merge into
one Emacs `face`; and a `display` produced by layout may have no direct author property.
The internal stages must therefore distinguish:

```text
CanonicalDeclaration {
  propertyId
  specifiedValue
  sourceSpelling
  sourceProvenance
}

SelectorSubjectFact {
  classList
  id
  sourceHandle
}

StyleSourceFact {
  sourceHandle
  selectorSubjectFact
  declarations
  scopeHandle
  provenance
}

StyleEnvironment {
  stylesheet
  schemaSet
  scopeIndex
  computedCache
}

RuntimeMetadataFact {
  propertyId
  value
  sourceHandle
}

ComputedPropertyFact {
  propertyId
  computedValue
  winningProvenance
  impactSet
  sourceHandle
}

ProjectionPlan {
  metadataFacts
  measurementFacts
  geometryFacts
  paintFacts
}
```

Normalization parses author input once and simultaneously produces immutable
CanonicalDeclaration, SelectorSubjectFact, and RuntimeMetadataFact artifacts.
`:class/:id` do not enter CSS declarations; SelectorSubjectFact constructs the ECSS subject
directly before cascade. Selector and semantic projection share the same parsed source
value for `:id` rather than rereading the plist independently. ETAF Style Adapter and
Ebox Standalone Style Adapter produce isomorphic StyleSourceFact values, but exactly one
adapter assembles StyleEnvironment for a surface. ECSS cascade/inheritance then receives
SelectorSubjectFact + declarations and produces immutable
ComputedPropertyFact artifacts. `:key`, `:ref`, `:on-*`, and similar properties do not
enter ECSS and appear only in RuntimeMetadataFact. “Materialize once” means that each
stage produces its own immutable artifact once, not that one object mutates across
stages.

A pure property projector consumes computed-style facts and metadata facts and generates
ProjectionPlan according to the PropertyDefinition owner/impact/projections fields.
Every consumer references the same fact rather than reparsing or copying its computed
value. The TP paint projector is the only module that converts paintFacts into
ContributionPlan. The ETAF semantic projector converts metadataFacts into
Runtime/SemanticPlan.

A registry is not one process-global universal table. Each owning package supplies an
immutable SchemaRegistry conforming to the same schema protocol; a surface composes a
SurfaceSchemaSet:

```text
ETAF SurfaceSchemaSet = ETAF registry + Ebox registry
Ebox SurfaceSchemaSet = Ebox registry
ETAF + Emacs adapter  = ETAF registry + Ebox registry + adapter registry
```

Each canonicalId has exactly one owning definition. Canonical/alias collisions are
checked when composing the SchemaSet. This avoids both reverse dependencies and
duplicate sources of truth.

Logical modules remain small and complete:

- package property schema: a package-scoped PropertyDefinition registry;
- SurfaceSchemaSet: conflict-free composition of package registries;
- property normalizer: author names, shorthands, and value grammar;
- property projector: computed/metadata facts → backend-neutral ProjectionPlan;
- Ebox layout projector: measurement/geometry facts → LayoutPlan;
- TP paint projector: paint facts → ContributionPlan;
- ETAF semantic projector: metadata facts → Runtime/SemanticPlan;
- Emacs adapter: GeometryPatch + PaintPatch + SemanticPlan → text-property operations.

Consequently, an Ebox canonical node stores no paint-only field; TP stores no geometry;
the Emacs adapter does not reinterpret CSS; and Rust receives only canonical facts/plans,
not `face`, `display`, or an Elisp plist. Debugging and performance tools must expose the
complete chain, for example:

```text
:font-weight
→ ebox/font-weight
→ {geometry, paint}
→ measurement/font-weight + paint/font-weight
→ face :weight
```

## 4. Module Owners

### 4.1 ETAF Core

`etaf-view`:

- defines and normalizes Text, Box, Fragment, and ComponentCall;
- normalizes strings to Text;
- normalizes the `row`, `column`, `flex`, and `grid` author sugars to Box;
- validates closed property sets, slots, `:key`, and expression boundaries;
- does not measure, lay out, or write buffers.

`etaf-component`:

- defines Component props, mutually exclusive `:view`/`:render` frontends,
  optional `:setup` returning opaque state, the sole `etaf-state` accessor,
  and `:styles`;
- defines the `etaf-node` code frontend at the same typed View ABI boundary;
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
- consumes computed/projection facts already produced by ETAF Style Adapter and turns
  the structure/geometry projection into CanonicalEboxInput forest, RangeAnchors, and
  typed Ebox facts;
- does not rerun selector/cascade or copy a second computed visual representation;
- does not execute Component lifecycle or access Ebox private state.

`etaf-style` (a logical module that may remain in the same distribution):

- owns Component-style scope assembly and one independent StyleEnvironment per
  Runtime/Surface, including its lifetime;
- uses Ebox's public property registry/projector and invokes ECSS directly for the one
  cascade on an ETAF surface;
- does not measure, lay out, write buffers, or own Runtime commit authority.

`etaf-theme-tp`:

- is only the optional TP-palette to ETAF semantic Theme token/value adapter;
- does not produce ContributionPlan, participate in selector/cascade, or own paint
  commit authority.

Theme semantic tokens and inheritance belong to ETAF Context. TP does not own business
meaning such as “dark theme.”

### 4.2 Ebox

Ebox owns:

- normalization of String/Text/Box and layout-sugar expansion in the Ebox DSL;
- the canonical Ebox property registry and pure computed-fact to geometry/paint-fact
  projector;
- a Standalone Style Adapter used only by standalone Ebox surfaces; it invokes ECSS
  directly, while the ETAF typed path bypasses it and never runs a second cascade;
- contextual validation, parent-layout consumption, and dirty propagation of child Box
  participation;
- typed TextNode/BoxNode constructors and canonical property schemas;
- text measurement, wrapping, and line layout;
- the `normal`, `row`, `column`, `flex`, and `grid` geometry algorithms;
- width/height, the box model, overflow, scrolling, and viewport behavior;
- stable Ebox node identity, geometry snapshots, and structural patch plans.

Ebox does not understand Component, slot, Context, Action, Behavior, Data, or Resource,
and does not determine paint-contribution priority.

ETAF Style Adapter and Ebox Standalone Style Adapter share the same pure property
projector. The former handles ETAF Theme/Component/state/inline provenance; the latter
handles standalone Ebox inline/stylesheet provenance. They never coexist on one surface,
never put paint-only properties back into CanonicalEboxInput, and never own TP priority,
journal, or commit authority.

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

### 4.6 Public Surfaces Layered by Consumer

- Ordinary ETAF users use only `etaf-view`, Component, Text/Box forms, ETAF metadata/
  events, canonical CSS-aligned properties, explicitly listed ETAF/Ebox extensions such
  as `:outer` and `:wrap-mode`, and parse-time aliases; they do not call Ebox, TP, or the
  Emacs adapter.
- Standalone Ebox users use inert data forms with the same visual structural vocabulary
  through `ebox-build`; they do not own Component, slot, expr, or lifecycle.
- Framework integrators use `ebox-text-create`, `ebox-box-create`, typed LayoutConfig,
  RangeAnchor, and the TP contribution contract; they do not reconstruct DSL, pass
  shorthands, or run a second cascade. Typed constructors accept only an opaque
  `sourceHandle`, not source-layer `:class/:id/:key`.
- The optional Emacs adapter is an explicit opt-in, independent schema namespace. Only
  a surface that loads the adapter accepts `:emacs-face`; otherwise normalization
  reports the unknown namespace/property precisely.
- `ebox--*`, `etaf--*`, `tp--*`, `:ebox-type`, `:node-id`, `:region-id`, Emacs text
  properties, and runtime storage fields are all private.

The user guide describes only the first layer; the Ebox DSL guide describes the second;
the integration reference describes the third; only architecture documentation
describes canonical IR, identity owners, impact projection, and the commit protocol.

## 5. Dependency Direction

```text
etaf-ui ─────────────▶ ETAF Core ─────────────▶ Ebox public port
etaf-sqlite ─────────▶ ETAF Data contract
etaf-playground ─────▶ ETAF + optional UI/SQLite
ebox-playground ─────▶ Ebox only
etaf-performance ────▶ public observation boundaries only

ETAF Style Adapter ──▶ ECSS + Ebox property registry/projector
Ebox Standalone Style Adapter ─▶ ECSS + same registry/projector
ETAF Renderer ───────▶ Ebox typed core port
ETAF Runtime  ───────▶ Ebox/TP transaction participants
etaf-theme-tp ───────▶ ETAF semantic Theme values only
Ebox surface ────────▶ TP contribution + transaction participant
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
- rejection of canonical/alias collisions when package registries compose a
  SurfaceSchemaSet;
- exact aliases disappear after normalization, while each shorthand expands exactly
  once and conflicts with its owned outputs in the same declaration;
- the optional adapter namespace is accepted only by explicitly opted-in surfaces and
  reports a precise error when the adapter is not loaded;
- CanonicalDeclaration, SelectorSubjectFact, RuntimeMetadataFact, and
  ComputedPropertyFact remain immutable across stages, and the selector subject is
  produced exactly once before cascade;
- ProjectionPlan contains only paintFacts, and only the TP projector may produce
  ContributionPlan;
- Row/Column accept only the `:item-gap/:cross-align` extensions rather than borrowing
  the different semantics of CSS `:gap/:align-items`;
- a multi-impact computed value such as geometry + paint materializes once and is
  referenced by both paths;
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

### 8.1 Atomic migration order and gates

This migration does not keep a tag-by-tag compatibility route. The current verified
baselines are Ebox `6d9f2a4` and Ebox Playground `f571c89`; uncommitted experiments
are never functional or performance baselines. Work proceeds in the following
dependency order, and the author-boundary cutover is committed as one cross-repo
atomic objective:

1. Complete the typed core first: Normal supports zero or many inline/block children;
   Row/Column fully implement `:item-gap/:cross-align`; Normal/Row/Column/Flex/Grid
   are all one BoxNode with a typed LayoutConfig. Text may be a direct Flex/Grid child
   with default participation, but it cannot carry nondefault participation.
2. Switch `ebox-build` once to the sole grammar: String, `text`, `box`, `row`,
   `column`, `flex`, and `grid`. The five Box forms directly construct typed
   Box/LayoutConfig values; remove `ebox/spacer/item/grid-item`, and reject author
   `:content/:layout` plus raw runtime nodes.
3. In the same objective, remove the complete legacy public creation surface:
   `ebox-create`, `ebox-concat/ebox-stack/ebox-spacer/ebox-grid-fr`, the public and
   autoload identity of the old `ebox-row/ebox-column/ebox-flex/ebox-grid`
   constructors, and their public inventories, help, README, documentation, and
   examples. Lowering still required by a backend may remain private temporarily,
   but it must not be canonical output, a public concept, or a second author path.
4. Migrate every actual consumer together: Ebox, ETAF, ETAF UI, Ebox Playground,
   ETAF Playground, and their README files, documentation, examples, and tests.
   Public material and examples must not expose private backend fields such as
   `:ebox-content-node`, `:display`, or `:ebox-type`.

Verification uses a minimal decisive matrix rather than duplicating legacy tests: one
table-driven grammar/negative contract covers seven author entries, five Layouts,
Normal multi-child behavior, Text default participation, and wrong-parent failures;
existing identity, final-candidate, and commit/rollback gates are reused; tests that
only prove removed wrappers or aliases are deleted.

Each candidate first runs targeted checks and then every affected repository's full
static and test gates. Continuous GUI resize checks every step for no unexpected
full-root fallback, requires final text and all text properties to equal a fresh
render, and retains stable identity. Performance comparison interleaves the committed
baseline and candidate under the same Emacs, frame, width sequence, and action
sequence: warm up each operation five times, then measure each side at least thirty
times; use the general recorder to compare operation latency, cross-package stages,
p95, and max. Affected real scenarios must keep p95 and max at or below 50ms, and any
reproducible stage regression must be root-caused first. Any functional, GUI, or
performance failure stops the commit; it must not be hidden by compatibility branches
or a large set of synonymous tests.

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
- retaining old Host/layout-form aliases in Core; property aliases follow only the
  unified mechanism in Section 3.2;
- allowing Playground, UI, or database packages to own Core protocols;
- adding App precompilation artifacts before real compile cost and runtime benefit exist.
