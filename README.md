# ETAF

ETAF is the text-application framework built above the independent Ebox layout and rendering engine.

The public model is intentionally small:

- `View` describes Hosts and Component calls.
- `Component` turns props into a View.
- `Ebox` measures, lays out, paints, and publishes the result.

Every structural form uses one shape:

```elisp
(name :property value ... child ...)
```

Properties come first and children come last. Property values are ordinary Elisp expressions. `expr` is the only executable child bridge:

```elisp
(etaf-view
 (column
  (text :face 'bold "Hello")
  (text (expr :value (if ready "Ready" "Waiting")))))
```

Define a stateless Component with `:view`:

```elisp
(etaf-define-component status-label (&key label)
  "Render a status label."
  :view
  (text :face 'bold (expr :value label)))

(etaf-mount
 "*etaf-demo*"
 (etaf-view
  (status-label :label "Connected")))
```

`etaf-view` is the sole public View construction entry. View forms and Component `:view` forms do not use quote. Quote remains ordinary Elisp data syntax, for example `'bold` as a face symbol. A Renderable returned by ordinary Elisp must be constructed with an unquoted `(etaf-view ...)` inside `expr`.

## Development checkout

During development, load the sibling Ebox checkout before ETAF:

```elisp
(add-to-list 'load-path "/path/to/github/emacs-box")
(add-to-list 'load-path "/path/to/github/etaf")
(require 'etaf)
```

The package metadata declares Ebox `1.0.1` as the runtime dependency. ETAF never calls Ebox private functions.

## Scope of this first slice

The repository currently establishes and tests the P0 grammar, `etaf-view`, `expr`, stateless `:view` Components, core Hosts (`text`, `fragment`, `container`, `row`, `column`, `stack`, `flex`, and `spacer`), and the Ebox mount bridge. Stateful `:setup`, slots, styles, Context, Behaviors, events, actions, data, and incremental Component reconciliation are subsequent implementation milestones; unsupported clauses fail explicitly.

Run the focused checks with:

```sh
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
```

The target architecture and the sequenced implementation work are documented in [`docs/architecture.en.md`](docs/architecture.en.md) and [`docs/implementation-plan.en.md`](docs/implementation-plan.en.md). Chinese versions are kept beside them.
