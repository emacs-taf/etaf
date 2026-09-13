# Changelog

## Unreleased

### Added

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

- Focus APIs now operate Ebox's single mounted focus and published tab order.
  Direct Ebox focus changes are visible through ETAF. Reorder follows stable
  source identity; hidden, disabled or removed targets clear focus. Manual point
  movement preserves a clamped numeric position and rejected publication restores
  focus. Negative or absent tab index skips navigation but no longer clears an
  explicitly focused surviving Host; call `(ebox-focus nil buffer)` to clear it.
  Update Ebox together with ETAF. Keyboard bindings remain in `etaf-input-mode`.

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
