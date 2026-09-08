# Historical worktree integration

The September 5 benchmark worktrees contain competing repair attempts against
an earlier ETAF contract. Their changes were reconciled against current main
on September 8, rather than replacing the newer implementation.

- `127aa7a` preserves every existing root metadata value. Current main's
  `805323a` already protects owned role and ARIA semantics, composes callbacks
  and Behaviors, and allows caller values for ordinary metadata. Retain that
  more precise implementation when reconciling the old attempt.
- `a206cfd` changes only the old metadata docstring to describe unrestricted
  caller overrides. Retain the current docstring because owned semantic
  conflicts are now rejected explicitly.
- The retained-root fixture's instance-scoping test is already present in
  `tests/etaf-component-frontends-tests.el`. Its old role-override expectation
  conflicts with the current owned-role contract and is superseded by the
  existing rejection assertion.
- The three v1 unmount test attempts exercise the same lifecycle outcome.
  Production no longer exposes the v1 fallback. Their live-buffer, unmounted,
  zero-revision assertions are carried into the current render-port revision
  contract test.
- The metadata baseline deliberately rejects every duplicate metadata key;
  that blanket rule is superseded by the current property-specific policy.
- The missing-revision baseline deletes an old v1 test. Both that test and the
  v1 production route have already been removed by the current SPI boundary.

The historical worktrees remain as evidence. They are not runtime dependencies.
Regression execution was explicitly waived for this integration; static checks
do not establish fresh behavioral or performance acceptance.
