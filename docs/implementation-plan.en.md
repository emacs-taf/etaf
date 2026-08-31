# ETAF Implementation Plan

This is the maintainer execution document for the independent `etaf` repository. [`architecture.en.md`](architecture.en.md) is the public design contract; [`user-guide.en.md`](user-guide.en.md) is the public usage contract. This document records delivery order, ownership, verification, and deliberately bounded follow-up work.

## 1. Completion rule

A milestone is complete only when:

1. The public path exists, not only a private helper.
2. The public path has a failing-case test and a successful-case test.
3. The affected files compile without warnings.
4. The implementation has a paired English/Chinese documentation update when the public contract changes.
5. A failed candidate does not corrupt the last committed Runtime or buffer.

The repository is complete for the agreed unified architecture when the mandatory milestones below are green. The first official UI catalog, Grid layout, SQLite source, and two independent Playgrounds are delivered as sibling packages; future Components, storage sources, and asynchronous integrations are additive work and must reuse the frozen contracts instead of widening the core vocabulary.

## 2. Milestone status

| Milestone | Delivered responsibility | Evidence |
| --- | --- | --- |
| P0 grammar | Unified View shape, property-first parsing, `etaf-view`, `(expr FORM)`, core Hosts, aliases | `tests/etaf-tests.el` structural and syntax tests |
| P1 Components | `:view`, `:setup`, props, default/named slots, retained instances, lifecycle, `:key`, raw Ebox escape | Component, slot, mount, prop-update, raw-node, and rollback tests |
| P2 Runtime | refs, computed, effects, watches, Scope cleanup, Context, Theme, Behaviors, events, focus, Actions | Mounted event/focus tests, reactive failure rollback, cleanup tests |
| P3 presentation | scoped styles, selector matching, Theme precedence, inline text runs, Resource and error boundary | Style, Theme, text-surface, Resource, and error tests |
| P4 application layer | core Data Controller, memory source, selection, mutation, Grid Host, official UI catalog, DataGrid, SQLite source, and two independent Playgrounds | Core Data/Grid tests plus the four sibling-package `make check` gates |
| Quality gates | independent package entries, warning-free byte compilation, checkdoc, public API tests, and documentation contracts | Core `make check` plus `etaf-ui`, `etaf-sqlite`, `etaf-playground`, and `ebox-playground` checks |

## 3. Ownership map

| File | Stable responsibility | Must not own |
| --- | --- | --- |
| `etaf-view.el` | Structural grammar, View values, slot normalization, expression boundary, Component registry | Ebox calls, buffer writes, lifecycle, business state |
| `etaf-component.el` | `etaf-define-component`, prop declarations, definition-level styles validation | Runtime scheduling or Ebox lowering |
| `etaf-reactive.el` | refs, computed values, effects, watches, effect scopes, cleanup | View syntax or buffer publication |
| `etaf-context.el` | inherited Context and Theme defaults | global service registry or visual nodes |
| `etaf-runtime.el` | retained instances, candidate reconciliation, commit/rollback, lifecycle, Behavior installation | Ebox private state or business data schemas |
| `etaf-renderer.el` | the single ETAF-to-Ebox public boundary, styles, text lowering, raw escape | Component lifecycle and data requests |
| `etaf-behavior.el` | non-visual `:use` Behavior specs and installers | visual nodes or direct buffer mutation |
| `etaf-events.el` | event dispatch, Host reference hit testing, activation, focus | business mutation policy |
| `etaf-actions.el` | named Action registry and Runtime dispatch | View construction or presentation |
| `etaf-resource.el` | Scope-owned synchronous loader state and error boundary | a second async/task object model |
| `etaf-data.el` | source capability contract, controller state, pagination, mutation, selection | database-specific code or storage assumptions |
| sibling `etaf-ui/etaf-ui.el` | one official Component catalog, including compound DataGrid | a second Control/Widget/Component taxonomy |
| sibling `etaf-playground/etaf-playground.el` | public-API-only ETAF examples and optional catalog entry points | Ebox private APIs or `ebox-playground` dependency |
| sibling `etaf-sqlite/etaf-sqlite.el` | typed SQLite Data Source and transaction boundary | Data Controller state or a generic ORM layer |
| sibling `ebox-playground/ebox-playground.el` | public Ebox layout examples | ETAF APIs or Ebox private APIs |
| `etaf.el` | one core facade and local package load-path preference | loading optional UI or Playground modules |

Do not split a file merely to create a shorter name. Split only when a stable responsibility, lifecycle, external boundary, or release boundary moves with the code.

## 4. Frozen public contracts

### 4.1 View and evaluation

- The only structural form is `(NAME :PROPERTY VALUE ... CHILD ...)`.
- All properties precede children.
- Attribute values are ordinary Elisp expressions.
- The only child computation bridge is `(expr ELISP-EXPRESSION)`; its result
  may be text, a typed View/proper typed View sequence, or `nil`.
- A dynamic View returned by Elisp is constructed with `(etaf-view ...)` inside `expr`; quoted structural data is never executed.
- The six visible Host forms are `text`, `box`, `row`, `column`, `flex`, and `grid`; `fragment`, `slot`, and `expr` are transparent framework structure.
- There is no raw Ebox View escape hatch. Framework integrations use Ebox's evaluated typed-constructor port outside the author DSL.

### 4.2 Component and slots

- `etaf-define-component` chooses exactly one of `:view` or `:render`; `:setup`
  and `:styles` are optional.
- `:view` and `:render` are mutually exclusive frontends.
- `:setup` runs once per retained identity and returns opaque state read with
  `etaf-state` during either frontend.
- Props update render without rerunning setup.
- Trailing children are `slots.default`; named slot input uses `(slot :name 'NAME CHILD...)`.
- Default outlet shorthand is `(slot)` or `(slot FALLBACK...)`.
- Slot names are stable, non-keyword symbols only.
- `:key` is identity metadata, not a business prop: Component calls use it for retained identity, while Hosts project the same parsed fact into the Ebox source index.

### 4.3 Runtime and non-visual capabilities

- Refs, computed values, watches, Effects, and cleanup use one reactive Scope model.
- Context is inherited through retained Component instances; Theme is a Context property plist.
- `:on-*` is a local callback; Action is a named mutation; Behavior is a reusable `:use` bundle; Effect is the subscription/cleanup owner.
- Events and focus enter through Runtime and public Ebox Host-reference APIs.
- Data is core ETAF capability. A source has required `:load` and optional `:mutate`/`:dispose` capabilities.
- Resource is a Scope-owned synchronous loader; no task/promise abstraction is introduced into core.

Changing one of these contracts requires an architecture-document review before implementation. Do not add a compatibility spelling to avoid making the decision.

## 5. Verification matrix

| Surface | Command or test | What it proves |
| --- | --- | --- |
| Package load | `make load EMACS=...` | The public facade loads against the sibling Ebox package |
| Byte compile | `make compile EMACS=...` | All distributable implementation files compile without warnings |
| Core behavior | `tests/etaf-tests.el` | Grammar, Component, Runtime, reactive, Context, styles, events, Actions, raw escape |
| Resource behavior | `tests/etaf-resource-tests.el` | Loading, errors, replacement cleanup, Scope disposal, explicit boundary |
| Data behavior | `tests/etaf-data-tests.el` | Query, pagination, normalization, mutation, selection, errors, stop |
| UI behavior | `tests/etaf-ui-tests.el` | Button, Checkbox, Panel slots, reactive DataGrid projection |
| Playground behavior | `tests/etaf-playground-tests.el` | Public ETAF mount and event flow without Ebox internals |
| Documentation | `tests/etaf-docs-tests.el` | Paired files, current names, no stale public entry examples, no private Ebox calls |
| Full gate | `make check EMACS=...` | Compile, all ERT tests, and docs contract together |

The test suite must exercise the public dispatch path for event and Runtime bugs. Pure helper tests do not replace mounted tests.

## 6. Review checklist for changes

Before changing code:

1. Name the owner of the behavior and the data flow from View to Ebox.
2. Search existing tests and sibling modules for the same public path.
3. Write the smallest failing regression test when behavior is wrong or missing.
4. Prefer deleting a redundant abstraction before adding a helper.

During implementation:

- Keep View values pure and keep buffer mutation at Runtime/Ebox publication boundaries.
- Keep cleanup attached to the Scope that created the resource.
- Let internal errors surface; catch only at an explicit loader or application boundary.
- Preserve structural identity for repeated sequences with `:key`.
- Keep Component style precedence and property/child ordering deterministic.
- Keep optional packages out of the core facade.

Before handoff:

- Read the full diff.
- Run `make check` and inspect all output.
- Run a fresh `make load` with only the local ETAF and sibling Ebox paths.
- Scan implementation files for `ebox--` and unrelated private calls.
- Update both language documents when a public contract changes.
- Commit one focused, verified change before starting another milestone.

## 7. Bounded follow-up work

The following are extension lanes, not missing core concepts:

| Extension | Required contract | Safe implementation direction |
| --- | --- | --- |
| Async external data | A concrete source must define callback, generation, cancellation, and error ownership | Add it to a concrete source package or a narrowly specified Data capability; do not add a generic task hierarchy |
| More UI Components | Existing props/children/slots/events/Behavior contract | Add ordinary Components to `etaf-ui` and test them through Runtime |
| Database sources | The frozen `etaf-data-source` capability plist | Use explicit packages such as a concrete SQLite/PostgreSQL source; keep storage out of core |
| Richer layouts | A complete Ebox measurement/layout/publication contract | Extend Ebox first, then expose it through a Host or Component |
| Visual Playground tooling | Public inspection and reporting APIs | Extend `etaf-playground` without coupling it to Ebox Playground |

Each extension must carry its own tests and documentation. If it needs a new public noun, update `architecture.en.md` and `architecture.zh.md` first, then this plan and the user guide.

## 8. Stop conditions

Stop a milestone when its public path, rollback behavior, tests, compile, load, and paired documentation are complete. Do not broaden the core model merely because an optional integration is not yet present. Do not create a second rendering grammar, a second Component model, or a package boundary that users must learn as a new runtime concept.
