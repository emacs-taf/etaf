# ETAF

ETAF is a small text-application framework built above the independent [Ebox](../ebox) layout and rendering engine.

Its complete public model is:

```text
Component(props, Scope) → View → Renderer → Ebox Node → Emacs buffer
```

Every visible structure uses one form:

```elisp
(name :property value ... child ...)
```

The only child computation bridge is `expr :value`; attribute values are ordinary Elisp expressions.

```elisp
(etaf-view
 (column
  (text :font-weight 'bold "Hello")
  (text
   :color "#687386"
   (expr :value (if ready "Ready" "Waiting")))))
```

Define a Component:

```elisp
(etaf-define-component status-label (&key label)
  "Render a status label."
  :view
  (text :font-weight 'bold (expr :value label)))

(etaf-mount
 "*etaf-demo*"
 (etaf-view (status-label :label "Connected")))
```

`etaf-view` is the single public View constructor. Structural forms do not use quote; quote remains ordinary Elisp data syntax, such as `'bold`. A View returned from ordinary Elisp is explicitly constructed with `(etaf-view ...)` inside `expr`.

## Performance records

ETAF provides an independent, opt-in, application-neutral timing recorder.  It
consumes public Runtime observer reports without advice or private cross-package
probes.  Runtime operations such as Event, Action, mount, flush, and unmount are
recorded automatically; Ebox, TP, Data, Resource, and SQLite provider stages
inside the same operation are correlated by sequence.

```elisp
(require 'etaf-performance)
;; In a buffer with a mounted ETAF Runtime:
(etaf-performance-mode 1)
;; Use any mounted ETAF application normally.
(etaf-performance-show)
```

For an interactive capture, run `M-x etaf-performance-clear` first.  After
reproducing the operations, press `c` in the panel (or run
`M-x etaf-performance-copy-report`) to copy a complete report.  Press `w` (or
run `M-x etaf-performance-export`) to save the same report as an `.eld` file.
The portable report includes the Emacs/display environment, power source,
low-power mode, native-JIT state, system load, grouped p50/p95/max, individual
operations, GC deltas, and ordered provider stages.  The panel header exposes
the same environment context so a machine-wide slowdown is not mistaken for
one package hotspot.

The `*ETAF Performance*` panel shows operation IDs, generation changes, total
latency, GC deltas, and each flat provider stage in sequence.  Provider stages
may overlap, so they are not presented as exclusive/self time.  Records are
bounded by `etaf-performance-max-records`; disabling the mode only detaches the
Runtime observer and never rewrites functions.  `etaf-performance-summary`
computes operation p50/p95/max statistics on demand, while
`etaf-performance-operation-stage-summary` groups one operation's flat stages
by provider category.  `etaf-performance-records` returns defensive operation
and stage snapshots; caller mutation cannot rewrite retained history.

Use `etaf-performance-call-operation` or
`etaf-performance-with-operation` to trace an arbitrary operation that has no
built-in public boundary.  Both delegate to the same Runtime operation boundary;
they do not create a second timer.

## Executable examples

The [`examples/`](examples/README.md) directory contains three core-only best-practice applications: retained state and Actions, Data Controller ownership, and Resource error/cleanup lifecycle. They are byte-compiled and driven through mounted public event paths by `make check`.

```elisp
(add-to-list 'load-path "/path/to/github/etaf/examples")
(require 'etaf-counter-example)
(etaf-counter-example-open)
```

## Documentation

- [Architecture](docs/architecture.en.md) · [中文架构](docs/architecture.zh.md)
- [User guide](docs/user-guide.en.md) · [中文用户指南](docs/user-guide.zh.md)
- [Implementation plan](docs/implementation-plan.en.md) · [中文实施计划](docs/implementation-plan.zh.md)
- [Module-boundary proposal (unimplemented)](docs/proposals/module-boundaries.en.md) · [模块边界提案（未实现）](docs/proposals/module-boundaries.zh.md)
- [Best-practice examples](examples/README.md) · [中文示例](examples/README.zh-CN.md)

## Independent packages

| Package | Role |
| --- | --- |
| [`etaf-ui`](../etaf-ui/README.md) | Official Component catalog: Button, Checkbox, Label, Panel, and DataGrid. |
| [`etaf-sqlite`](../etaf-sqlite/README.md) | Concrete SQLite Data Source; the Data Controller remains in ETAF core. |
| [`etaf-playground`](../etaf-playground/README.md) | ETAF examples, with the UI catalog loaded only when requested. |
| [`ebox-playground`](../ebox-playground/README.md) | Ebox-only layout examples, independent from ETAF. |

There is no separate `etaf-data` install: Data is a core ETAF capability. There is no generic `etaf-adapters` package: other databases, services, files, or ORMs should provide concrete Data Source packages with explicit names.

## Load and verify

ECSS 0.1.0 and TP 1.0.1 are independent packages and may be installed in either order. Install both before Ebox 2.0.1, then install ETAF 0.1.1. ETAF declares TP directly because Host final-accept authority uses the TP transaction contract; rendering still consumes only the Ebox 2.0 public contract.

During development, load the sibling Ebox checkout before ETAF:

```elisp
(add-to-list 'load-path "/path/to/github/ebox")
(add-to-list 'load-path "/path/to/github/etaf")
(require 'etaf)
```

Run the complete local gate:

```sh
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
```

The core gate byte-compiles the implementation, runs the core/Data/Resource tests, and checks documentation/API boundaries. Run `make check` in the sibling `etaf-ui`, `etaf-sqlite`, `etaf-playground`, and `ebox-playground` repositories for their independent gates; none is loaded by the core facade.
