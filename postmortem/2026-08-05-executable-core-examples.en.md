# Executable core examples

## Decision

Core best-practice examples are ordinary loadable Elisp files under `examples/`, with one application responsibility per file and a public open/close pair. They depend only on ETAF core and are compiled and interaction-tested by the normal repository gate.

## Why

README fragments prove syntax but do not prove lifecycle ownership or the installed Runtime dispatch path. A single large playground proves breadth but makes it hard to identify which layer owns state, data loading, and cleanup. Small executable applications keep those boundaries visible and let tests fail when an example drifts from the framework contract.

Data Controllers and Resources are created during Component setup but start state-changing loads from the mounted lifecycle. This distinction matters because render is intentionally write-protected. Detached Data Controllers are stopped explicitly on unmount; Resource values remain owned by their Scope cleanup.

## Rejected alternatives

- Depending on `etaf-ui` would make core examples inherit the incomplete catalog migration and would blur the independent package boundary.
- A shared example framework or theme module would add indirection without enough reuse; three small applications can own their own restrained presentation.
- Catching loader failures and returning display defaults would hide the Resource error contract instead of teaching it.

## Consequence

New core examples should be admitted only when they teach a distinct public ownership rule, include a real mounted interaction test, and remain free of private ETAF/Ebox calls. Broad application demonstrations continue to belong in `etaf-playground`.
