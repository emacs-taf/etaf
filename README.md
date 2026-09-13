# ETAF

ETAF builds text applications from reusable Components above the independent
[Ebox](https://gitea.gklazycat.heiyu.space/geekinney/ebox/src/branch/main/) layout and rendering engine.

Start with `etaf-view` and `etaf-mount`. Properties precede children in
`(name :property value ... child ...)`; property values are ordinary Elisp.
Evaluate the complete example, switch to `*etaf-hello*`, and activate “Say hello”:

<!-- etaf-example: hello -->
```elisp
;;; -*- lexical-binding: t; -*-
(require 'etaf)

(etaf-mount
 "*etaf-hello*"
 (etaf-view
  (column
    (text :font-weight 'bold "Hello")
    (box :ref 'hello :role 'button :tab-index 0
         :on-press (lambda () (message "Hello ETAF"))
      "Say hello"))))
```

A Component receives declared props and optional content through slots. Use the
exact name passed to `etaf-define-component`; the registry creates no aliases.
`(expr FORM)` evaluates one child expression. In a structural child position it
may return nil, text, a typed Host or Component View, or a proper sequence of
those values. Inside `text`, an expression must return a string.

<!-- etaf-example: card -->
```elisp
;;; -*- lexical-binding: t; -*-
(require 'etaf)

(etaf-define-component demo-card (&key title)
  :view
  (column
    (text :font-weight 'bold (expr title))
    (slot)
    (slot :name 'footer)))

(etaf-mount
 "*etaf-card*"
 (etaf-view
  (demo-card :title "Account"
    (text "Connected")
    (slot :name 'footer (text "Footer")))))
```

Add `:setup` when a Component owns state. It runs once per retained instance;
`:render` uses ordinary Elisp to capture handles before returning `etaf-view`.
The shorter `:view` form compiles the same View model.

<!-- etaf-example: counter -->
```elisp
;;; -*- lexical-binding: t; -*-
(require 'etaf)

(etaf-define-component demo-counter ()
  :setup (etaf-ref 0)
  :render
  (let ((count (etaf-state)))
    (etaf-view
     (column
       (text (expr (format "Count: %d" (etaf-value count))))
       (box :ref 'increment :role 'button :tab-index 0
            :on-press (lambda () (cl-incf (etaf-value count)))
         "Increment")))))

(etaf-mount "*etaf-counter*" (etaf-view (demo-counter)))
```

Keep `etaf-value` reads inside the property or `expr` that should update. Event
callbacks capture ordinary lexical locals; call `etaf-state` during rendering.
Use a lexical-binding `.el` file for reusable application code. `etaf-node` is
available for programmatic View builders. Context, Data, Behavior, and named
Actions are optional capabilities; simple callbacks need no Action registration.

Use exact catalog names such as `etaf-button` after `(require 'etaf-ui)`.
Core does not load `.etaf` files: Playground treats them as inert structure,
with its explicit companion registration handling executable Elisp.

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
Pass a numeric observer runtime ID to `etaf-performance-records` to select one
mount's history even when a buffer name is reused. Summary and report functions
use all retained records when called without an argument; an explicit `nil`
means an empty selection. The exported environment describes report generation,
not each historical operation. These synchronous operation durations do not
measure physical input-to-presentation latency; use the GUI measurement entry
in [README.md](README.md) for per-action condition checks.

Use `etaf-performance-call-operation` or
`etaf-performance-with-operation` to trace an arbitrary operation that has no
built-in public boundary.  Both delegate to the same Runtime operation boundary;
they do not create a second timer.

## Executable examples

The [`examples/`](README.md) directory contains three core-only best-practice applications: retained state and Actions, Data Controller ownership, and Resource error/cleanup lifecycle. They are byte-compiled and driven through mounted public event paths by `make check`.

```elisp
(add-to-list 'load-path "/path/to/github/etaf/examples")
(require 'etaf-counter-example)
(etaf-counter-example-open)
```

## Documentation

- [Architecture](docs/architecture.md) · [中文架构](docs/architecture.zh-CN.md)
- [User guide](docs/manual.md) · [中文用户指南](docs/manual.zh-CN.md)
- [Implementation plan](docs/architecture.md) · [中文实施计划](docs/architecture.zh-CN.md)
- [Module-boundary proposal (unimplemented)](docs/architecture.md) · [模块边界提案（未实现）](docs/architecture.zh-CN.md)
- [Best-practice examples](README.md) · [中文示例](README.zh-CN.md)

## Independent packages

| Package | Role |
| --- | --- |
| [`etaf-ui`](https://gitea.gklazycat.heiyu.space/geekinney/etaf-ui/src/branch/main/README.md) | Official Component catalog: Button, Checkbox, Label, Panel, and DataGrid. |
| [`etaf-sqlite`](https://gitea.gklazycat.heiyu.space/geekinney/etaf-db/src/branch/main/README.md) | Concrete SQLite Data Source; the Data Controller remains in ETAF core. |
| [`etaf-playground`](https://gitea.gklazycat.heiyu.space/geekinney/etaf-playground/src/branch/main/README.md) | ETAF examples, with the UI catalog loaded only when requested. |
| [`ebox-playground`](https://gitea.gklazycat.heiyu.space/geekinney/ebox-playground/src/branch/main/README.md) | Ebox-only layout examples, independent from ETAF. |

There is no separate `etaf-data` install: Data is a core ETAF capability. There is no generic `etaf-adapters` package: other databases, services, files, or ORMs should provide concrete Data Source packages with explicit names.

## Load and verify

Install ECSS 0.1.0 and TP 2.0.0 before Ebox 3.0.0, then install ETAF 0.2.1.
ETAF declares TP directly because Host final-accept authority uses the TP
transaction contract. Rendering requires Ebox framework SPI v2; a missing,
malformed, or incompatible provider fails during ETAF bootstrap.

ETAF snapshots one immutable v2 render port for the Emacs process. During an
ordered upgrade it also accepts Ebox's transitional dual-capability TP manifest
because that manifest contains the required v2 protocol. ETAF never dispatches
through the retired v1 capability.

During development, load the sibling Ebox checkout before ETAF:

```elisp
(add-to-list 'load-path "/path/to/github/ecss")
(add-to-list 'load-path "/path/to/github/tp")
(add-to-list 'load-path "/path/to/github/ebox")
(add-to-list 'load-path "/path/to/github/etaf")
(require 'etaf)
```

Run the complete local gate:

```sh
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
```

The core gate byte-compiles the implementation, runs the core/Data/Resource tests, and checks documentation/API boundaries. Run `make check` in the sibling `etaf-ui`, `etaf-sqlite`, `etaf-playground`, and `ebox-playground` repositories for their independent gates; none is loaded by the core facade.



## Development

After cloning, run `make setup-hooks`. Before submitting a change, run `make check`; `make structure-check` is the fast organization gate. The shared rules are in [AGENTS.md](AGENTS.md).

[docs/manual.md](docs/manual.md) · [docs/architecture.md](docs/architecture.md) · [CHANGELOG.md](CHANGELOG.md)

`make check` runs structure checks, compilation and the public acceptance scenarios listed in [scripts/acceptance.json](scripts/acceptance.json). `make test` runs the broader regression suite; GUI and performance checks remain explicit targets. The acceptance inventory is selected by user-visible contracts, not by current pass/fail status.
