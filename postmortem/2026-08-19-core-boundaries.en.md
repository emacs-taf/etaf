# Core boundaries after the `.etaf` pair experiment

The safe data-only `.etaf` pair path was removed from current core. It added a second file grammar, companion execution boundary, and registry validation surface before a compiler contract existed. The archived `emacs-box` DSL cannot be reused as a shortcut: it has different ownership and executable semantics. A future `.etaf` SFC belongs in a compiler layer that emits the existing `etaf-view` and `etaf-define-component` contracts.

The current Component definition remains the single structure/style/behavior unit. Its `:view` owns structure, `:styles` owns presentation, and `:setup` owns retained state, Actions, and lifecycle. Style scopes now stop at nested Component internals; caller-owned slot content keeps the caller scope, while child-authored slot fallbacks keep the child scope.

Mounted input stays in the small Runtime lifecycle path: the input minor mode is enabled after a successful mount and disabled before unmount. TAB/backtab, RET, and mouse-1 use the public focus and hit-test operations rather than a second event layer.
