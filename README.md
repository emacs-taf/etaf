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
  (text :face 'bold "Hello")
  (text
   :color "#687386"
   (expr :value (if ready "Ready" "Waiting")))))
```

Define a Component:

```elisp
(etaf-define-component status-label (&key label)
  "Render a status label."
  :view
  (text :face 'bold (expr :value label)))

(etaf-mount
 "*etaf-demo*"
 (etaf-view (status-label :label "Connected")))
```

`etaf-view` is the single public View constructor. Structural forms do not use quote; quote remains ordinary Elisp data syntax, such as `'bold`. A View returned from ordinary Elisp is explicitly constructed with `(etaf-view ...)` inside `expr`.

## Documentation

- [Architecture](docs/architecture.en.md) · [中文架构](docs/architecture.zh.md)
- [User guide](docs/user-guide.en.md) · [中文用户指南](docs/user-guide.zh.md)
- [Implementation plan](docs/implementation-plan.en.md) · [中文实施计划](docs/implementation-plan.zh.md)

## Independent packages

| Package | Role |
| --- | --- |
| [`etaf-ui`](../etaf-ui/README.md) | Official Component catalog: Button, Checkbox, Label, Panel, and DataGrid. |
| [`etaf-sqlite`](../etaf-sqlite/README.md) | Concrete SQLite Data Source; the Data Controller remains in ETAF core. |
| [`etaf-playground`](../etaf-playground/README.md) | ETAF examples, with the UI catalog loaded only when requested. |
| [`ebox-playground`](../ebox-playground/README.md) | Ebox-only layout examples, independent from ETAF. |

There is no separate `etaf-data` install: Data is a core ETAF capability. There is no generic `etaf-adapters` package: other databases, services, files, or ORMs should provide concrete Data Source packages with explicit names.

## Load and verify

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
