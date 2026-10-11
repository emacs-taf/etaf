# etaf repository instructions

The enclosing workspace `AGENTS.md` (`../AGENTS.md`) carries the shared
engineering, documentation, validation, performance and Jujutsu rules; read it
first. This file adds only what is specific to this repository.

## Where a change belongs

`etaf.el` is the only package entry; implementation modules live in `lisp/`,
each declaring its own responsibility in the first Commentary line. Modules
grouped by the theme you are chasing:

| Theme | Modules |
| --- | --- |
| View grammar, Hosts, structural normalization | `etaf-view`, `etaf-compiler` |
| Component definition, props, slots, retained instances | `etaf-component` |
| Mounted lifetime, retained Host tree, fine-grained bindings, commit, direct Ebox writes | `etaf-runtime` |
| Nested viewport regions: subtree layout region publication and resolution | `etaf-viewport` |
| Reactive state, derived values, effects, batches, Scopes | `etaf-reactive` |
| Events, activation, focus, input identity | `etaf-events` |
| Scoped Host keys, keyboard drags, command palette | `etaf-keys` |
| Named regions: declarations, entry resolution and adjacency | `etaf-regions` |
| Behaviors and named Actions | `etaf-behavior`, `etaf-controlled-behavior`, `etaf-actions` |
| Inherited Context and Theme resolution | `etaf-context` |
| Data controllers, Resources, shared async completion | `etaf-data`, `etaf-resource`, `etaf-async` |
| Cached lists with background revalidation | `etaf-list-cache` |
| Native video sources, playback sessions and the video Component | `etaf-video-source`, `etaf-video-audio`, `etaf-video-session`, `etaf-video-component` |
| Optional observation and recording | `etaf-observer`, `etaf-performance` |

`docs/architecture.md` states concepts, ownership, data flow and invariants; it
is not an implementation map, so do not look there for "which file". User
workflows and the GUI verification procedure are in `docs/manual.md`, and the
`etaf.el` Commentary is the authoritative public API inventory.

Design rationale, the files a change touched and its verification commands are
recorded in the commit descriptions, so `jj log -p <path>` answers "why is it
like this" when the documents do not.

## Reading `lisp/etaf-runtime.el`

It is the largest module, about 2100 lines organised in `;;;;` sections
(segments, Hosts, regions, Components, commit, mounting and Host queries).  Ask for a
definition instead of reading guessed line ranges:

```sh
python3 ../scripts/elisp.py def SYMBOL...   # complete forms, with file and range
python3 ../scripts/elisp.py refs SYMBOL     # callers grouped by definition
```

Both directions are available for every module; batch independent symbols into
one call. Bindings are closures registered as reactive effects, so `refs`
reporting no direct caller for a binding updater is expected.

## Enforced gates

- `tests/acceptance.json` must inventory exactly the maintained Lisp
  scenarios: a new `tests/*-tests.el` case without an entry fails the structure
  gate, and an entry whose ERT name disappeared fails it too.
- `docs/` accepts only the fixed document names, plus their `.zh-CN.md`
  translations. Any other document, including agent notes and task reports,
  fails the structure gate.
- The README examples are executed as the acceptance scenario in
  `tests/etaf-docs-tests.el`; `make check` covers them, and `make docs-check`
  runs that file alone.
- Compilation is warning-free by contract (`byte-compile-error-on-warn`).

`make check` covers all of the above in well under a minute, so run it on every
coherent change rather than a subset.
