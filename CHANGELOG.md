# Changelog

## Unreleased

### Added

- Standalone effect scopes have public `etaf-scope-stop` and
  `etaf-on-scope-dispose` lifecycle operations. Cleanup registration rejects
  stopped scopes, and teardown returns cleanup failures while continuing.

- Component props accept `(name default)` declarations. Missing inputs lazily
  initialize instance-owned defaults; explicit nil remains a supplied value.
  Published defaults survive overrides and are discarded on unmount.

### Fixed

- Component callbacks can directly capture declared props in both `:view` and
  `:render`. Successful updates replace their snapshots; rejected renders keep
  the committed callbacks. Setup closures retain initial inputs, and props
  containing refs preserve live reads and reference identity.

### Changed

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
