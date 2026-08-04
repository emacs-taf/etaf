# ETAF Implementation Plan

This document is the working plan for the independent `etaf` repository. The architecture contract lives in [`architecture.en.md`](architecture.en.md); this file records implementation order, verification, and explicit gaps.

## 1. Milestones

| Milestone | Scope | Exit evidence |
| --- | --- | --- |
| P0 | Unified grammar, `etaf-view`, `expr`, stateless `:view`, core Hosts, Ebox bridge | Macro-expansion failures, ERT contract tests, byte compilation, mount smoke test |
| P1 | Slot collection, `:setup`, Component Scope, refs, lifecycle, raw Ebox escape | Public Component tests cover setup-once, props, slots, disposal, and rollback |
| P2 | Context, Behavior, focus/event protocol, Actions, Effects, watches | Real mounted event paths, cleanup tests, identity and failure tests |
| P3 | ECSS styles, themes, inline text runs, resource/error boundary | Style ordering, text-surface, async recovery, and buffer publication tests |
| P4 | Data capabilities, `etaf-ui`, data sources, playgrounds, use-case-driven layout extensions | Independent-load scans, package tests, application examples, and CI |

## 2. P0 delivered slice

- The repository is an independent package at `/Users/geekinney/IPARA/3-RESOURCES/emacs/config/github/etaf`.
- The only dependency is the sibling Ebox package during this checkout phase.
- `etaf-view.el` owns structural parsing and the single `expr :value` bridge.
- `etaf-component.el` owns stateless `:view` definitions and contextual aliases.
- `etaf-renderer.el` is the only module that calls Ebox; it uses public Ebox constructors and publication APIs.
- Core Hosts are minimal and unstyled: `text`, `fragment`, `container`, `row`, `column`, `stack`, `flex`, and `spacer`.
- Attribute/child ordering, ordinary Elisp evaluation boundaries, expression results, Component props, alias collisions, and mounting are covered by `tests/etaf-tests.el`.

## 3. P1 sequence

1. Freeze the Component call and slot collection representation.
2. Implement `(slot)` and `(slot FALLBACK...)` as default-slot projection, then named `(slot :name 'NAME CHILD...)`.
3. Make trailing children and named slot declarations normalize into that same collection; reject dynamic, string, numeric, and keyword slot names.
4. Add `:setup` as ordinary Elisp that runs once per retained Component Scope and returns a zero-argument render function.
5. Add refs and computed values with stable identity, then connect props updates without rerunning setup.
6. Add explicit lifecycle and failed-candidate disposal before any stateful application example.
7. Add `raw-ebox :value` as the namespaced backend escape after the normal View path is proven.

P1 must not add a second Template entry, a Variant definition model, a positional `text` exception, or a quote-based View convention.

## 4. P2–P4 dependency order

- Context depends on retained Component Scope and nearest-ancestor ownership.
- Behaviors depend on stable Host identity, events, refs, Effects, and disposal.
- Actions are business mutations and must not become View nodes or presentation callbacks.
- Effects own external synchronization and cleanup; `watch` remains a reactive primitive that a Behavior or Effect may use.
- ECSS and state styles depend on a frozen Ebox property boundary and text-surface mapping.
- Data remains an ETAF core capability. SQLite, PostgreSQL, MySQL, REST, file, and ORM implementations are optional concrete data-source packages.
- `etaf-ui` is one official Component catalog. Source file splits are maintainer boundaries, not user concepts; DataGrid is an ordinary compound Component.
- `ebox-playground` depends only on Ebox. `etaf-playground` depends on ETAF and optionally `etaf-ui`; neither depends on the other.

## 5. Verification gates

Every milestone must pass the smallest relevant gate before the next boundary is started:

```sh
make compile EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make test EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
```

P0 additionally requires a clean macro-expansion failure for malformed grammar and a real `etaf-mount` path. P1 adds setup/slot lifecycle tests. P2 adds mounted event and cleanup paths. P3 adds text-surface and publication tests. P4 adds package boundary scans, independent loading, and application smoke tests.

No milestone is complete when only helper functions pass: public macro expansion, Component construction, renderer lowering, and buffer publication must all be exercised.

## 6. Stop conditions

Do not introduce `etaf-template`, `Variant`, public Control/Widget categories, `etaf-data` as a required peer package, abstract `etaf-adapters`, or a second public View construction entry. Do not implement Grid, Overlay, or a complete CSS clone before a real application use case supplies a measurement, layout, and publication contract.
