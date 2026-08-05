# Design

## Source of truth
- Status: Active
- Last refreshed: 2026-08-05
- Primary product surfaces: Executable applications under `examples/`, especially the buffers opened by the three `etaf-*-example-open` commands.
- Evidence reviewed: ETAF public source and user guide, core/Data/Resource tests, `../etaf-playground/DESIGN.md`, the polished ETAF Showcase, and the original Ebox Flex reference.

## Brand
- Personality: Precise, calm, modern, technical, and intentionally composed.
- Trust signals: Stable geometry, readable contrast, explicit state ownership, public-only construction, and visible success/error/selection states.
- Avoid: Bare fixture text, low-contrast pastel text, decorative emoji, fake browser chrome, huge empty surfaces, and controls indistinguishable from copy.

## Product goals
- Goals: Make core ETAF practices copyable from small executable files; prove the installed Runtime interaction path; keep examples visually consistent with the Flex reference and ETAF Showcase.
- Non-goals: Replacing `etaf-playground`, simulating the missing `etaf-ui` catalog, introducing a second theme system, or demonstrating every public symbol in one application.
- Success signals: Each example teaches one ownership boundary, opens without side effects at load time, reacts through public events, cleans up its resources, and remains unclipped in a compact GUI frame.

## Personas and jobs
- Primary personas: ETAF application authors and framework maintainers.
- User jobs: Copy a correct state/data/resource pattern, inspect a real mounted application, and verify the visible result of an event.
- Key contexts of use: Source reading, GUI Emacs exploration, automated ERT, and framework regression review.

## Information architecture
- Primary navigation: No shared launcher; every file owns one explicit open and close command.
- Core routes/screens: Retained counter, task Data Controller, and Resource health.
- Content hierarchy: Capability eyebrow, application title and explanation, primary state surface, actions, then an ownership rule footer.

## Design principles
- Principle 1: One example teaches one lifecycle owner; avoid a mega-demo that hides where state and cleanup belong.
- Principle 2: Writes happen at Event, Action, lifecycle, Data, or Resource boundaries; render functions remain read-only.
- Principle 3: Use warm restrained semantic color families and one-pixel borders to make structure obvious without adding a design-system dependency.
- Tradeoffs: Prefer a fixed compact teaching canvas over viewport arithmetic in each standalone example; keep the responsive full-application showcase in `etaf-playground`.

## Visual language
- Color: Warm canvas `#F8F5EE`, paper `#FFFDF8`, ink `#252A2E`, muted ink `#66706A`, terracotta `#F1D4C9`, sage `#DCEBDD`, blue `#D9EAF2`, and violet `#E7E2F1`, always with explicit dark text.
- Typography: The configured Emacs monospace face; bold only for titles, actions, statuses, and important values.
- Spacing/layout rhythm: One-line vertical gaps, 10–12 px horizontal gaps, and 12–18 px surface padding.
- Shape/radius/elevation: Square text-native blocks and one-pixel borders; no shadows or fake radius.
- Motion: None; synchronous commits must settle without geometry shifts.
- Imagery/iconography: Text and restrained semantic marks such as selection circles only.

## Components
- Existing components to reuse: Core Hosts, retained Components, refs, computed values, Actions, focusable Behaviors, Data Controllers, Resources, and Runtime lifecycle callbacks.
- New/changed components: Example-specific shell, metric, action, row, status, and footer Components/Hosts.
- Variants and states: Ready/active counter, selected/unselected task, open/done filter, idle/loading/success/error Resource.
- Token/component ownership: Each example owns its small static palette and composition; ETAF/Ebox own semantics, layout, and rendering.

## Accessibility
- Target standard: High-contrast, keyboard-addressable text UI.
- Keyboard/focus behavior: Every action has a stable ref, button role, and `etaf-focusable` Behavior.
- Contrast/readability: Tinted surfaces always set explicit foregrounds; status is expressed in text as well as color.
- Screen-reader semantics: Preserve textual labels and semantic roles; do not encode meaning only in decoration.
- Reduced motion and sensory considerations: No animation or flashing state.

## Responsive behavior
- Supported breakpoints/devices: GUI Emacs body widths of approximately 760 px and above.
- Layout adaptations: Examples use 680–720 px teaching canvases; action groups use wrapping Flex; the full viewport-responsive pattern remains in `etaf-playground`.
- Touch/hover differences: None; interaction uses the Runtime event boundary.

## Interaction states
- Loading: Explicit Resource/Data status rather than an invented fallback.
- Empty: Bounded explanatory row with no hidden placeholder data.
- Error: High-contrast visible error message that persists until the next action.
- Success: Explicit status text on a sage surface.
- Disabled: Remove the event/tab stop instead of presenting a misleading active control.
- Offline/slow network, if applicable: Not applicable to the synchronous core examples.

## Content voice
- Tone: Direct, technical, concise, and instructional.
- Terminology: Use the canonical names View, Component, Host, Runtime, Data Controller, Resource, Event, Action, Scope, and public API.
- Microcopy rules: Name the demonstrated ownership boundary and describe the visible effect; avoid promotional filler.

## Implementation constraints
- Framework/styling system: Emacs 29.1+, the public `etaf` facade, and public Ebox properties lowered through ETAF Hosts.
- Design-token constraints: Reuse the established warm palette directly; do not add a token framework for three examples.
- Performance constraints: Synchronous bounded data only; no timers, background work, or hidden repeated mounts.
- Compatibility constraints: Core examples must not require `etaf-ui`, `etaf-sqlite`, `etaf-playground`, or private `etaf--*` / `ebox--*` APIs.
- Test/screenshot expectations: `make check` byte-compiles examples and drives their mounted public event paths; GUI verification uses one target buffer window and rejects clipping or continuation indicators.

## Open questions
- [ ] Add an asynchronous Resource example only after ETAF defines a public asynchronous completion contract / maintainer / avoids teaching a speculative API.
