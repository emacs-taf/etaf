# Design

## Source of truth
- Status: Active
- Last refreshed: 2026-08-24
- Primary product surfaces: Executable applications under `examples/` and the generic ETAF performance recorder/panel used to inspect any mounted application.
- Evidence reviewed: ETAF public source and user guide, core/Data/Resource tests, `../etaf-playground/DESIGN.md`, the Research Shelf integration benchmark, Ebox's performance evaluator and architecture analysis, TP surface reports, and the original Ebox Flex reference.

## Brand
- Personality: Precise, calm, modern, technical, and intentionally composed.
- Trust signals: Stable geometry, readable contrast, explicit state ownership, public-only construction, and visible success/error/selection states.
- Avoid: Bare fixture text, low-contrast pastel text, decorative emoji, fake browser chrome, huge empty surfaces, and controls indistinguishable from copy.

## Product goals
- Goals: Make core ETAF practices copyable from small executable files; prove the installed Runtime interaction path; keep examples visually consistent with the Flex reference and ETAF Showcase; make every public operation's cross-package latency attributable to concrete nested stages.
- Non-goals: Replacing `etaf-playground`, simulating the missing `etaf-ui` catalog, introducing a second theme system, demonstrating every public symbol in one application, or binding performance analysis to one example or application package.
- Success signals: Each example teaches one ownership boundary, opens without side effects at load time, reacts through public events, cleans up its resources, and remains unclipped in a compact GUI frame. The performance panel can record any mounted application, preserve operation results/errors, expose inclusive and exclusive stage time, and keep a bounded history.

## Personas and jobs
- Primary personas: ETAF application authors and framework maintainers.
- User jobs: Copy a correct state/data/resource pattern, inspect a real mounted application, verify the visible result of an event, and identify which framework/package stage owns an operation's latency.
- Key contexts of use: Source reading, GUI Emacs exploration, automated ERT, and framework regression review.

## Information architecture
- Primary navigation: No shared launcher; every file owns one explicit open and close command.
- Core routes/screens: Retained counter, task Data Controller, Resource health, and the generic performance records buffer.
- Content hierarchy: Examples use capability eyebrow, application title and explanation, primary state surface, actions, then an ownership rule footer. The performance panel uses operation summary first, followed by indented nested stages with package/category, inclusive time, exclusive time, status, and details.

## Design principles
- Principle 1: One example teaches one lifecycle owner; avoid a mega-demo that hides where state and cleanup belong.
- Principle 2: Writes happen at Event, Action, lifecycle, Data, or Resource boundaries; render functions remain read-only.
- Principle 3: Use warm restrained semantic color families and one-pixel borders to make structure obvious without adding a design-system dependency.
- Principle 4: Instrument public operation boundaries once and let package-neutral stage registration extend coverage; examples are validation fixtures, never analyzer concepts.
- Tradeoffs: Prefer a fixed compact teaching canvas over viewport arithmetic in each standalone example; keep the responsive full-application showcase in `etaf-playground`.

## Performance architecture: three root principles

### 1. Host/Box properties are visual update units; Components are not default repaint units

A Component is the computation and ownership boundary for setup, state,
Context, slots, and lifecycle.  It may produce one or more Hosts/Boxes, or be
transparent and produce only Components, Ranges, or fragments, so the
Component record itself is not a Box.  Once a change is localized to a visual
node property, however, the Component that produced it must not run again.

The Runtime retains a structured property delta instead of collapsing every
reactive dependency into “Component dirty”:

```text
source-id → semantic-host-id → backend-node-id → property → old/new → impact
```

The deterministic update tiers are:

- `paint`: update the Host/Box property contribution directly, with no
  Component execution and no layout;
- `content` or local geometry: recompute only the Box and its exact layout
  dependency closure;
- control flow, slot, list topology, or lifecycle: execute the Component that
  owns that structure;
- untrusted input, external buffer mutation, or a missing index: enter an
  explicit root fallback.

Theme is the first vertical implementation.  Theme tokens compile to property
bindings, and palette changes schedule only Hosts bound to color, background,
and border properties.  Real content changes such as `Light theme` versus
`Dark theme` continue to schedule their own Component or Range.

### 2. Authoritative dependency state replaces repeated hot-path proofs

Initial layout produces and retains authoritative parent edges, allocated
slots, containment boundaries, property impacts, overflow facts,
viewport/display revisions, and layout revisions.  Later updates compute a
dirty closure from property schemas and dependency edges; they do not rescan
the rendered buffer to guess whether a local update is safe.

- paint deltas have no layout dependency and require zero proof;
- content in a fixed slot checks an O(1) revision/token;
- auto/intrinsic content follows retained layout dependency edges until a
  containment boundary;
- structure and viewport changes invalidate only affected certificates and
  edges;
- full span scans and conservative proofs remain only for untrusted
  candidates, external mutation, debug assertions, and fallback—not normal
  interaction hot paths.

The current retained allocation certificate is a migration device: establish
once, then validate a revision.  Once the dependency graph is complete, remove
the superseded scan path instead of permanently layering two decision systems.

### 3. Paint remains ordered TP property contributions through publication

Theme, Component style, interaction state, explicit inline properties, and
focus/selection are distinct paint contributions.  Ebox must not flatten them
into one final `face` per fragment before TP, and palette changes must not
recompose the complete fragment set.

“Layer” here means ordered property contributions in a TP properties
surface/ledger, not the definition-time recipes in `tp-layer.el`.  Ownership
is explicit:

- ETAF retains `source → Host property contribution` bindings and source
  precedence;
- Ebox retains Box/role mappings to stable TP ranges/objects and reports only
  layout/content deltas;
- TP merges ordered contributions inside one surface and owns baselines,
  conflict detection, atomic publication, rollback, and unmount restoration;
- a palette switch replaces the Theme contribution while higher-priority
  Component/state/inline contributions remain intact.

The target Theme path is therefore:

```text
Theme source changed
→ resolve changed Theme contributions
→ TP properties-only scoped publication
→ redisplay
```

It creates no View, executes no color-consuming Component, runs no Ebox
layout, scans no ancestor slot, and walks no complete fragment ledger.  Real
text or structure changes use a separate content/layout transaction; the
parent ETAF operation still correlates and atomically commits both.

## Precompiled Operation Programs and performance composability

A compiled artifact cannot retain only View syntax or final text coordinates.
An Operation Program that the Runtime can consume directly owns five facts as
one indivisible contract:

1. stable Host/Box/Range topology templates and dynamic holes;
2. `source/effect → OperationBatch` dependency routes;
3. layout slots, containment, overflow, and revision invalidation edges;
4. a closed style environment covering selectors, inheritance, and Theme
   contributions;
5. TP object/ownership ranges/paint contribution addresses plus atomic
   rollback boundaries.

Retaining only a subset merely moves the same work downstream.  Coordinates
without style and TP objects require reconstruction; a View blueprint still
requires lowering, layout, and paint; flattened final faces discard TP
layering.  Such partial artifacts are not App performance compilation.

The Runtime submits only precise operation batches:

```text
OperationBatch = RangeReplace | HostPropertySet | InlineTextSet |
                 LayoutInvalidate | PaintContributionSet
```

Each layer consumes only its fields and forwards the remaining retained
addresses.  Data materializes once; a transaction performs at most one full
walk; every module costs `O(changed)` or a documented small constant.  If an
extra module materially increases total latency, its interface discarded an
upstream intermediate—the overhead is not an inherent cost of architecture.

The current `etaf-view-blueprint/0` caches only static View construction and
is a migration artifact.  A later ABI becomes an Operation Program only after
a real App Range update avoids whole-tree Ebox projection/render and passes
the formal Pagination budget.

### Root implementation order and acceptance

1. Theme vertical slice: add a Theme source→Host/property index and TP
   contributions.  Color-consuming Component render count becomes zero while
   content consumers update separately.
2. Generic property effects: compile reactive expressions written directly in
   Host property positions into stable property bindings; structural
   expressions remain Component/Range work.
3. Exact incremental layout: Ebox retains property-impact and containment
   dependency edges, recomputes the dirty closure directly, and removes
   span/ancestor proofs from the normal path.
4. TP paint plane: migrate precomposed fragment faces to ordered properties
   contributions and delete full-fragment palette recomposition.
5. Converge: remove compatibility caches and proofs that are superseded while
   retaining the conservative root path for arbitrary candidates, rollback,
   and all existing semantics.

Acceptance requires GUI-visible completion timing, not batch alone; no layout
stage or full-fragment recomposition for Theme paint; no regressions in
structure, slots, lifecycle, inheritance, precedence, conflicts, or rollback;
and representative warmed operations passing the scenario budgets in the
performance evaluator.

## Visual language
- Color: Warm canvas `#F8F5EE`, paper `#FFFDF8`, ink `#252A2E`, muted ink `#66706A`, terracotta `#F1D4C9`, sage `#DCEBDD`, blue `#D9EAF2`, and violet `#E7E2F1`, always with explicit dark text.
- Typography: The configured Emacs monospace face; bold only for titles, actions, statuses, and important values.
- Spacing/layout rhythm: One-line vertical gaps, 10–12 px horizontal gaps, and 12–18 px surface padding.
- Shape/radius/elevation: Square text-native blocks and one-pixel borders; no shadows or fake radius.
- Motion: None; synchronous commits must settle without geometry shifts.
- Imagery/iconography: Text and restrained semantic marks such as selection circles only.

## Components
- Existing components to reuse: Core Hosts, retained Components, refs, computed values, Actions, focusable Behaviors, Data Controllers, Resources, and Runtime lifecycle callbacks.
- New/changed components: Example-specific shell, metric, action, row, status, and footer Components/Hosts; one `tabulated-list-mode` performance panel backed by generic operation and stage records.
- Variants and states: Ready/active counter, selected/unselected task, open/done filter, idle/loading/success/error Resource; recorder disabled/enabled, successful/failed operation, empty history, bounded history, and explicit manual refresh outside the measured hot path.
- Token/component ownership: Each example owns its small static palette and composition; ETAF/Ebox own semantics, layout, and rendering.

## Accessibility
- Target standard: High-contrast, keyboard-addressable text UI.
- Keyboard/focus behavior: Every action has a stable ref, button role, and `etaf-focusable` Behavior.
- Contrast/readability: Tinted surfaces always set explicit foregrounds; status is expressed in text as well as color.
- Screen-reader semantics: Preserve textual labels and semantic roles; do not encode meaning only in decoration.
- Reduced motion and sensory considerations: No animation or flashing state.

## Responsive behavior
- Supported breakpoints/devices: GUI Emacs body widths of approximately 760 px and above.
- Layout adaptations: Examples use 680–720 px teaching canvases; action groups use wrapping Flex; the full viewport-responsive pattern remains in `etaf-playground`.
- Touch/hover differences: None; interaction uses the Runtime event boundary.

## Interaction states
- Loading: Explicit Resource/Data status rather than an invented fallback.
- Empty: Bounded explanatory row with no hidden placeholder data.
- Error: High-contrast visible error message that persists until the next action.
- Success: Explicit status text on a sage surface.
- Disabled: Remove the event/tab stop instead of presenting a misleading active control.
- Performance recorder disabled: Explain the enabling command without manufacturing sample data.
- Empty performance history: Show a concise empty state and the public operation boundaries that can create records.
- Failed operation trace: Retain the timing record with an error status while allowing the original condition to propagate unchanged.
- Offline/slow network, if applicable: Not applicable to the synchronous core examples.

## Content voice
- Tone: Direct, technical, concise, and instructional.
- Terminology: Use the canonical names View, Component, Host, Runtime, Data Controller, Resource, Event, Action, Scope, and public API.
- Microcopy rules: Name the demonstrated ownership boundary and describe the visible effect; avoid promotional filler.

## Implementation constraints
- Framework/styling system: Emacs 29.1+, the public `etaf` facade, and public Ebox properties lowered through ETAF Hosts.
- Design-token constraints: Reuse the established warm palette directly; do not add a token framework for three examples.
- Performance constraints: Synchronous bounded data only; no timers, background work, or hidden repeated mounts.
- Performance analysis constraints: Recording is opt-in, bounded, package-neutral, result/error preserving, and removable. Disabled operation boundaries perform one fast gate. Third-party packages register stage symbols without creating reverse dependencies. Inclusive/exclusive stage accounting must remain valid under nesting.
- Compatibility constraints: Core examples must not require `etaf-ui`, `etaf-sqlite`, `etaf-playground`, or private `etaf--*` / `ebox--*` APIs.
- Test/screenshot expectations: `make check` byte-compiles examples and drives their mounted public event paths; GUI verification uses one target buffer window and rejects clipping or continuation indicators.

## Open questions
- [ ] Add an asynchronous Resource example only after ETAF defines a public asynchronous completion contract / maintainer / avoids teaching a speculative API.
- [ ] GUI redisplay completion is outside batch publication timing; define a portable Emacs redisplay marker before presenting it as a synchronous framework stage / maintainer / avoids false end-to-end claims.
