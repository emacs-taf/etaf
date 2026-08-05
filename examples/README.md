# ETAF best-practice examples

These examples are executable applications, not documentation fragments. They use only the public `etaf` facade and deliberately avoid `etaf-ui` so the core framework boundary remains independently runnable.

| Example | Public command | Practice demonstrated |
| --- | --- | --- |
| Retained counter | `M-x etaf-counter-example-open` | Component-owned refs, computed state, focusable Hosts, Event → Action → Runtime updates |
| Task controller | `M-x etaf-data-example-open` | Data Controller ownership, mounted loading, query, selection, mutation, and unmount cleanup |
| Resource health | `M-x etaf-resource-example-open` | Deferred Resource loading, visible error state, reload cleanup, and Scope disposal |

During checkout development, add Ebox, ETAF, and this directory to `load-path`:

```elisp
(add-to-list 'load-path "/path/to/github/ebox")
(add-to-list 'load-path "/path/to/github/etaf")
(add-to-list 'load-path "/path/to/github/etaf/examples")

(require 'etaf-counter-example)
(etaf-counter-example-open)
```

Replace the feature and open command with `etaf-data-example` / `etaf-data-example-open` or `etaf-resource-example` / `etaf-resource-example-open` for the other applications. Every example has a corresponding `-close` command that unmounts its Runtime before killing the buffer.

## Why these are the preferred patterns

- Keep writes out of render functions. Events and Actions mutate refs or Data Controllers; rendering only reads state.
- Create owned services during Component setup, start state-changing work from `etaf-on-mounted`, and release detached controllers from `etaf-on-unmounted`.
- Let Resource Scope cleanup own loaded values. Do not catch loader errors and invent plausible defaults; render the Resource error state explicitly.
- Use stable Host refs, semantic roles, and `etaf-focusable` so the same installed event path works for keyboard integration and tests.
- Keep examples compact and visually structured, but never introduce example-only rendering APIs or private `etaf--*` / `ebox--*` calls.

Run `make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs` from the repository root. The gate byte-compiles these files, checks their docstrings and public boundaries, and drives their mounted interaction paths.
