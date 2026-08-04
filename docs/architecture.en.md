# ETAF Architecture

This document defines the target architecture. It is a contract for public concepts and ownership, not a changelog.

## 1. The one lowering path

```text
Application
  → Runtime / State / Action / Data
  → Component(props, local scope)
  → View
  → ETAF Renderer
  → Ebox Node
  → measure → layout → paint → commit
  → Emacs buffer
```

ETAF describes application structure and behavior. Ebox is the lower-level engine that turns a measurable Node tree into text surfaces and atomically publishes those surfaces. A new ETAF feature must have one owner in this path.

## 2. Four concepts users need

### View

View is the structural description of a result. A View can be a Host call, a Component call, a string text leaf, `nil`, or a sequence of those values.

### Component

Component is the reusable boundary. It receives props, owns optional local scope, and produces a View. A Component is not a second kind of Ebox node and does not require a new renderer branch merely because it is reusable.

### Node

Node is Ebox's measurable and renderable model. Ebox owns geometry, box model, layout, surface properties, scrolling, runtime identity, and buffer publication. ETAF does not put Component semantics, slots, actions, or events into Ebox properties.

### Runtime

Runtime owns mounting, scheduling, state invalidation, event boundaries, commit coordination, rollback, and disposal. Runtime is an application boundary, not another View node.

## 3. One View grammar

Every Host and Component call has one shape:

```elisp
(NAME ATTRIBUTE* CHILD*)
```

An attribute is `:KEY VALUE`; a child is a View, string, `nil`, or a sequence produced through `expr`. The attribute region must be complete before the child region begins:

```elisp
(text :face 'bold :color "#F4F6FB" "Hello")
```

This is invalid because the regions are interleaved:

```elisp
(text "Hello" :face 'bold)
```

The same rule applies to core Hosts and public Components. There is no separate positional-content convention for `text`.

## 4. Elisp evaluation boundary

The compiler reads structural View positions. It does not require quote around a View:

```elisp
(etaf-view (text "Hello"))
```

Attribute values are ordinary Elisp expression positions:

```elisp
(etaf-view
 (text :face (if dark 'light 'dark) "Theme"))
```

The child region has one explicit computation bridge:

```elisp
(expr :value (if checked "☑" "☐"))
```

`expr` accepts exactly `:value`. `if`, `when`, `cond`, `let`, `mapcar`, and other Elisp forms remain ordinary Elisp inside that value. ETAF does not add separate `if`, loop, or computation node categories.

An expression that returns a View constructs it explicitly:

```elisp
(expr
 :value
 (when open
   (etaf-view (text :face 'bold "Details"))))
```

`'(text "Details")` is data, not a View. Quote is therefore neither globally forbidden nor used as a second View compiler.

## 5. Components

The public definition model has one beginner form and one advanced form:

```elisp
(etaf-define-component NAME (&key PROPS)
  :view VIEW)

(etaf-define-component NAME (&key PROPS)
  :setup SETUP)
```

`:view` is structural syntax and needs no quote. `:setup` is ordinary Elisp; it establishes Component Scope and returns a zero-argument render function that uses `etaf-view` when ordinary Elisp produces a View. `:view` and `:setup` are mutually exclusive. Static component styles use the separate definition metadata entry `:styles (styles RULE...)`; styles are not a third rendering model.

Props and children have different owners. Props are named inputs declared by the Component. Trailing children and named slots form one slot collection; children are not a hidden second Component argument list. The Component boundary is the place where that collection is normalized and projected.

Within View syntax, public Component aliases may omit the `etaf-` package prefix. Ordinary Elisp APIs such as `etaf-value`, `etaf-ref`, and `etaf-mount` keep their prefix. Alias resolution is contextual; a collision receives a semantic alias such as `list-view` rather than shadowing Elisp's `list`.

## 6. Core Hosts and official Components

ETAF core contains only minimal, unstyled Hosts:

```text
text · fragment · container · row · column · stack · flex · spacer
```

These names describe structural layout and text surfaces. Product-ready controls such as Button, Checkbox, Input, Dialog, and DataGrid are ordinary Components supplied by the independent `etaf-ui` package. Core pressability uses semantic properties such as `:role` and `:on-press`; it does not create a competing core Button Host.

Strings are the smallest text View and lower to an Ebox box with content. `text` is the explicit text Host for styling and semantic properties; it is not a separate Ebox node family.

## 7. Non-visual capabilities

These mechanisms extend the same Component/Host boundary without creating parallel visual node categories:

| Mechanism | Owns | Entry |
| --- | --- | --- |
| `on-xx` | One local event callback | Host/Component attribute |
| Action | Named, testable business mutation | Action definition and dispatch |
| Effect | External synchronization, subscriptions, cleanup | Effect in Scope |
| Behavior | Reusable non-visual capability bundle | `:use` attribute |
| watch | Reactive invalidation primitive | Reactive API or Behavior |
| Context | Inherited Scope value | Provide / Inject |
| Data | Request, state, cancellation, and error ownership | Core data API |

An `expr` computes a child value. It does not own identity, lifecycle, subscriptions, buffer writes, or effects. A Behavior may use events, refs, Effects, and watches, but it never becomes a View node.

## 8. Package ownership

```text
ebox
  └── optional ebox-playground

etaf → ebox
  ├── reactive / state / action / effect / data / ECSS
  └── pure .etaf compiler

etaf-ui → etaf
etaf-playground → etaf (+ etaf-ui for official Component examples)
```

Ebox knows nothing about Components, slots, Actions, Context, or data. ETAF knows Ebox only through the renderer boundary and its public API. `etaf-data` is a core capability, not a user-required peer package. Database and external integrations use explicit data-source packages such as `etaf-sqlite`; no abstract public `etaf-adapters` layer is needed.

The two Playgrounds are independent optional tools. `ebox-playground` uses Ebox only; `etaf-playground` uses ETAF public APIs and never calls Ebox Playground or Ebox private functions.

## 9. Extension rule

Prefer a Component, Behavior, Action, Effect, Context value, or data source when the feature is application-level. Add an Ebox property or Node only when the feature changes measurement, layout, surface painting, scrolling, or publication and has a complete owner for signature, dirty classification, rendering, rollback, and tests. This keeps the user model small while preserving a Turing-complete Elisp escape through ordinary expression positions and runtime APIs.
