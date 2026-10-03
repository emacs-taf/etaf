# Changelog

## Unreleased

### Added

- `etaf-data-mutate-many` applies a non-empty list of `(OPERATION PAYLOAD)`
  pairs and reconciles the Controller once, so bulk writes no longer pay one
  reload per row.  A source may expose the optional `:mutate-batch' capability
  to receive the whole list in one call; a transactional backend applies it
  atomically.  A signaled operation stops the batch and keeps the completed
  prefix observable under the `external-unknown' outcome.

- `etaf-list-cache` provides the stale-while-revalidate policy for slowly
  changing lists: each list is cached under a key with its arrival time, an
  application shows it at once and compares a fresh reply in the background,
  and `etaf-list-cache-next` picks the stalest or never-loaded list, one at a
  time, for a timer armed while the session is mounted.  Failed refreshes back
  off and a failure that needs a human pauses them until a load succeeds, and
  an optional version token lets a conditional backend refresh an entry
  without a repaint.

- Interactive Hosts advertise themselves: a Host with an `:on-press` or
  `:on-drag` callback publishes the hand pointer by default. Applications no
  longer declare `:pointer 'hand` per element; an explicit `:pointer`,
  including an explicit nil, still keeps its own shape, and a disabled
  boundary stays with the plain arrow.
- `etaf-retained-resize-open` mounts a runnable fixed-text resize example:
  a controlled `etaf-resizable-controlled` Behavior drives a clipped panel
  whose `:width`/`:height` bindings publish through Ebox's prepared crop
  primitive, with Shift-locked drags and Escape restoring the starting size.
  `benchmarks/performance-scenarios.el` registers matching
  `retained.resize.*` workloads for ordinary, prepared and Runtime routes.
- `etaf-runtime-update-host-geometries` reuses a retained
  `ebox-geometry-prepare` operation per Runtime, Host and property set for
  single-Host updates, so repeated moves and fixed-text resizes skip ordinary
  layout; declined or multi-Host updates keep the ordinary geometry batch.
- `etaf-event-target-within-p` reports, from an event callback, whether the
  pressed Host is a given Host or one of its descendants. Combined with a root
  `:on-press` and `:on-press-capture` it lets a shell dismiss an open panel
  when a press lands outside it.
- `etaf-batch` and `etaf-call-with-batch` group related reactive writes in
  ordinary application code. Nested batches defer observers and Runtime
  updates until the outer scope completes while preserving written refs on
  failure.
- `etaf-draggable` and `etaf-resizable` Behaviors translate Ebox drag gestures
  into caller-owned reactive geometry refs, with axis/edge selection, bounds,
  lifecycle callbacks and optional logical-unit delta conversion.
- Controlled variants accept aggregate geometry through `read`/`on-change`
  callbacks without creating a second persistent geometry store.
- `etaf-gui-verifier-line-height-assertions`, `etaf-gui-verifier-canvas-filled-p`
  and `etaf-gui-verifier-canvas-assertion` expose the row-height budget and the
  full-window canvas as reusable scenario checks, so an application scenario
  fails when a glyph falls back to a taller font or a resize leaves the canvas
  taller than the window.

### Changed

- Parent rerenders retain unchanged surrounding output and publish only changed
  descendant ranges. Flattened single-root Component outputs can use their
  retained Host address; structural and source-fact differences keep the
  enclosing replacement. Ebox retains authority over layout propagation.
- Theme dependencies follow the defaults and static token values each Host
  consumes. Unchanged Theme projections avoid unrelated property updates.
- Batched sibling updates share pending ancestor invalidations while preserving
  convergence tracking, detached snapshots and rejected-publication recovery.
- A commit reuses the canonical Range input snapshotted when the current
  generation was published instead of lowering the old output forest again,
  halving Range normalization in structural updates such as a Desktop close.
- A retained child Component whose queued render or input effect settles to
  equal values is no longer rendered again when a structural ancestor
  re-renders, so a parent update touches only children whose inputs changed.
- Idle preparation follows interactive properties and text sharing their
  reactive source roots. Independent text prepares on demand in a separate
  cohort, so periodic data does not recompile the interactive member set.
  Accepted effect deltas maintain the preparation hints across structural
  changes. Interrupted preparation discards partially rebound members; source
  writes still publish atomically and remain retryable after rejection.
- Mounted reactive primitive bindings are now prepared before input and shared
  by sparse geometry, focus paint, native hover and text updates. Known class
  variants, fixed-shape border colors and measured normal/bold changes can use
  the same publication; observer and lifecycle writes keep their pending work.
- Box and Text class lowering now consistently normalizes whitespace strings,
  symbols and nested lists for selectors while preserving public raw Host props.
- Equal computed inputs retain mounted output and update lifecycle without
  publishing a new revision. Custom `:test` comparisons apply before rendering;
  unused computations stay lazy and failed computation remains retryable.
- Supported reactive Host geometry is prepared automatically for direct
  retained publication. Geometry and semantic queries commit together without
  rebuilding the Component tree; unsupported or structural changes keep the
  ordinary update path. Use committed generation numbers or revisions to
  detect updates, since the opaque generation object may retain identity.
- Related primitive Host paint, hover, `:visibility` and fixed-extent inline
  text changes can join geometry in one retained publication. Existing batch, lifecycle,
  snapshot and rejected-update semantics remain available through ordinary Views.
- Hosts styled by a reactive Theme (`etaf-theme-provide` with a ref or
  computed) now keep prepared property bindings. The Theme source guards the
  binding by version instead of forcing ordinary publication, so moving,
  resizing or hiding themed Hosts retains the committed generation; a Theme
  change still repaints through the ordinary path. A `:color` or
  `:background-color` expression that chooses between `etaf-theme-token`
  values also stays prepared: it publishes the token's installed paint slot
  and declines to ordinary publication only for a token painted for the
  first time. Requires Ebox's paint-slot face binding fix.
- Retained publication is now owned by Ebox. Update Ebox and ETAF together;
  the integration uses SPI v3 and `ebox-publication/v1`. Publication reports
  use `:publication-*` fields and the `ebox-publication` provider.


### Changed

- Rendering requires Ebox framework SPI v3 and `ebox-publication/v1`. Host
  final-accept authority and committed-query guards now use Ebox transactions.
  Upgrade Ebox before ETAF and restart Emacs to load
  one consistent provider and render port. Performance reports correlate the
  `ebox-publication` stage with rendering through `:publication-transaction-id`.

### Fixed

- Semantic palettes use application-owned token plists and
  `etaf-theme-resolve-palette`. The palette adapter and replacement registry
  are removed; replace named palette bindings with direct light/dark token pairs.

- Narrow Host content updates no longer deep-copy their immutable property
  signature before lowering; renderer and source-builder ownership boundaries
  retain the required snapshots without duplicating interaction metadata.
- Local updates invalidate enclosing Range snapshots without eagerly rebuilding
  their complete output. Snapshots are composed from current semantic facts when
  needed; subsequent parent updates and keyed reorders retain current child state.

- Retained Components and keyed rows receive replacement input objects even
  when their contents compare equal. Business props and list items now share
  refs' shallow equality, keeping state and focus while updating callbacks.
  Function-valued refs also preserve this identity rule across Emacs function
  representations.

- Components can change between empty, single-root and fragment output without
  changing the enclosing layout or rejecting a valid update. Component bindings
  survive output changes; retained keyed children keep state and focus. Nested
  updates publish from the same final output, including Host property changes.

- Fragment Components projecting slots no longer introduce an implicit Column
  when mounted. Their children participate directly in the enclosing layout,
  matching pure rendering while preserving state, focus and cleanup.

- Host property updates use Ebox's general property operation for layout, style
  and interaction changes. They compose with retained Component state and child
  updates without rebuilding the Host subtree. Framework checkouts require the
  Ebox version providing `ebox-candidate-update-host-properties`.

- Retire reused Component records with their removed branch, including records
  whose unchanged subtree was not staged. Filtering an edited selection out
  and restoring it no longer leaves loading stuck on a missing render node.

- Retire staged descendants and pending Host updates when their enclosing
  branch is removed. Deleting an edited Data selection leaves subsequent loads
  and filtering usable; slot updates preserve their physical parent.

- Resolve conditional ancestors before descendant input/render work, so hidden components release their callbacks and repeated show/hide updates never address a retired Host.

- Pure `etaf-render` rejects reactive writes in expressions before they can
  change application state, matching mounted rendering's read-only boundary.

- Repairing a rejected root input now publishes pending descendant state changes,
  including when the repaired props equal the previously committed props.

- Composed slots can update a controlled child and conditional content together
  without duplicating retained children. Both declarative and programmatic slot
  containers preserve the child's interactive identity across repeated updates.

- Buttons without explicit references keep working after theme or reactive style
  updates. Retained layout identity and native activation now address the same
  committed Host, including after disabling and re-enabling a control.

### Removed

- `etaf-input-mode` and its independent keyboard map. Mounted applications use
  `ebox-buffer-mode` automatically; remove calls and hook setup for the old mode.
  Update Ebox together with ETAF and use its shared buffer map for custom keys.

### Changed

- Deferred Resources now start `idle`; successful Data reloads report
  `refreshing` while retaining items. Consumers matching status symbols must
  handle `idle`, `refreshing` and `cancelled` as well as loading/success/error.

### Added

- `etaf-performance-report-data` exposes a detached structured report for
  automated consumers, including operation identity and public provider stages.

- `etaf-focus-within` delegates panel-local navigation to Ebox's shared focus
  implementation. Menus and dialogs can cycle within a committed subtree
  without keeping their own target index. Requires Ebox's `ebox-focus-within`.

- Components can declare optional `:validate` checks using ordinary Elisp after
  defaults resolve, before initialization or updated inputs publish. The shared
  `etaf-check-prop` helper reports the component, property, received value and
  expectation. Pure and mounted rendering use the same input contract.

- Component rules can use Ebox-derived `:active` during native press and drag
  gestures. Reactive updates retain the state; pointer activation observes it
  cleared. No application pressed-state binding is required.

- Hosts and Component root attributes accept Ebox native help, pointer and
  hover paint, preserving inheritance and explicit nil boundaries on updates.

- Host `:on-drag` callbacks use Ebox's shared native gesture lifecycle. Each
  motion publishes through its own reactive event batch; target retention,
  coordinates and native input remain owned by Ebox. Update Ebox together.

- Expose Data source capabilities for adapters that preserve storage and disposal while wrapping load or mutation operations.

- Add `etaf-call-with-input` for native editing and selection inside event callbacks, using Ebox target lifetime and focus restoration.

- Resource and Data accept native asynchronous loaders through `etaf-async`,
  with cancellation, timeout, late-result protection and Scope-owned disposal.
  Resource supports `:keep-value`; Data exposes write certainty and read-only
  recovery with `etaf-data-mutation-outcome`, `etaf-data-reconciliation-state`
  and `etaf-data-retry-reconciliation`.
- The Resource example demonstrates native timers, retained refresh and cancel.
  Its open/close commands are available directly after requiring `etaf`.


- `etaf-update-value` applies an ordinary function to a ref's current value
  and publishes its replacement through the existing reactive write path.
  Updaters need no manual read/write pair or deep reactive proxy.

- Components accept `:bindings ((name initializer) ...)` for stable instance
  values shared directly by setup, views and callbacks. Initializers run once
  in order, using the existing Scope lifecycle. Examples and manuals use this
  form instead of packing and unpacking `etaf-state`; the latter remains an
  advanced accessor for an explicit setup result in components without bindings.

- ECSS-tagged Box layout and outer values now use Ebox's canonical projection,
  including important, CSS-wide and variable values during reactive updates.

- Preserve Host role, ARIA attributes and disabled state in Ebox selector
  subjects, including successful reactive updates and failed-candidate rollback.

- `etaf-local-ref` allocates stable instance-local Host handles during setup.
  Reusable components can address same-named internal controls independently,
  retaining targets across keyed reorder and failed publication.

- `etaf-prop` supplies stable read-only Component inputs for setup computed values
  and watches. Updates notify after publication; rejected candidates preserve
  committed inputs and dependency tracking. Sources expire with their instance.

- `etaf-behavior-context-info` exposes installation Runtime, Host reference and
  semantic properties through a public snapshot query usable during cleanup.

- Standalone effect scopes have public `etaf-scope-stop` and
  `etaf-on-scope-dispose` lifecycle operations. Cleanup registration rejects
  stopped scopes, and teardown returns cleanup failures while continuing.

- Component props accept `(name default)` declarations. Missing inputs lazily
  initialize instance-owned defaults; explicit nil remains a supplied value.
  Published defaults survive overrides and are discarded on unmount.

### Fixed

- Deferred Theme tokens remain valid in Component rules. Their actual values
  pass Ebox validation after contextual resolution.

- Component callbacks can directly capture declared props in both `:view` and
  `:render`. Successful updates replace their snapshots; rejected renders keep
  the committed callbacks. Setup closures retain initial inputs, and props
  containing refs preserve live reads and reference identity.

### Changed

- Component `:focus` rules now follow shared Ebox focus, including reactive
  layout, hiding and rollback. Update Ebox with ETAF; pure rendering and other
  mounted buffers remain independent of the selected buffer's focus.

- Disabled component styles use Ebox's shared interaction-derived selector
  state. Update Ebox together with ETAF so pure and mounted disabled rules keep
  their behavior during reactive updates.

- Mounted keyboard navigation and activation now use Ebox's buffer mode and
  target selection. `etaf-activate` and native commands share focus precedence;
  mouse clicks continue to use their clicked target. Configure
  `ebox-buffer-mode-map` after requiring Ebox to customize input.

- Focus APIs now operate Ebox's single mounted focus and published tab order.
  Direct Ebox focus changes are visible through ETAF. Reorder follows stable
  source identity; hidden, disabled or removed targets clear focus. Manual point
  movement preserves a clamped numeric position and rejected publication restores
  focus. Negative or absent tab index skips navigation but no longer clears an
  explicitly focused surviving Host; call `(ebox-focus nil buffer)` to clear it.
  Update Ebox together with ETAF; it also supplies shared keyboard bindings.

- Mounted press handlers now use Ebox native keymaps and activation lookup;
  Ebox navigation can discover ETAF controls. Disabled and callbackless children
  block ancestor activation. Native clicks preserve point/window selection,
  and keyboard activation preserves explicit focus at shared positions.

- Component styles now use Ebox/ECSS matching and cascade. Later equal-specificity
  rules win, author-important rules can override normal inline values, and
  structural selectors operate on the canonical tree. Change root class/type
  rules to `&.class` or `:scope`; plain selectors address descendants.
  Fragment roots, reactive Theme rules and code slot recomposition retain ownership.

- Theme defaults now use ECSS UA origin through Ebox scopes. Normal defaults
  remain below author properties; UA-important defaults take precedence over
  author-important declarations. Remove importance from Theme defaults that
  callers should override. Reactive updates retain layout and deferred values.

- Component `:styles` and `etaf-component-set-styles` now accept a plain
  ordered rule list. Remove the `styles` wrapper; normal Elisp arguments still
  quote literal lists. Rules validate through the shared Ebox/ECSS contract.

- Expose the package entry at the repository root, document supported APIs in
  its Commentary and retain implementations under `lisp/`. Source consumers add
  the repository root to `load-path` and require the package entry; internal
  feature imports are unsupported. Archives retain this same directory layout.

## ETAF 0.2 migration

ETAF 0.2.1 requires Ebox 3.0.0 and TP 2.0.0. Install TP, then Ebox, then ETAF.
The renderer bootstrap now requires Ebox framework SPI v2 and fails closed when
the provider is absent, malformed, or incompatible.

Remove any configuration of `etaf-render-port-selection-policy`. The v1 render
port and its manual initial-publication cleanup path have been retired. Runtime
mounts and updates always use the immutable SPI v2 port, including its paired
framework stage and rollback, same-object report, observation replay, revision,
and Host final-marker contracts.

During an ordered source upgrade, ETAF accepts Ebox providers that report either
`tp-transaction-protocol-v1+v2` or `tp-transaction-protocol-v2`. The former is a
temporary capability declaration that still contains the required v2 protocol;
ETAF never invokes a v1 transaction operation.
