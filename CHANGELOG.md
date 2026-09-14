# Changelog

## Unreleased

### Fixed

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
