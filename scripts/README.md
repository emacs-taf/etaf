# Generic Emacs GUI verification

This directory owns the reusable verification mechanism, not application
scenarios:

- `emacs-gui-verifier.el` defines `Scenario`, ordered `Action`, run-local
  `Context`, checkpoint sequencing, assertions, completion, and fail-closed
  evidence finalization.
- `run-emacs-gui-verification.sh` owns one named daemon, explicit load paths,
  external application activation, recorder lifecycle, driver loading, report
  generation, and exact cleanup.
- `record-screen.exp` keeps macOS `screencapture -v` attached to a PTY and stops
  it through an explicit signal. It contains no Emacs or application logic.

Concrete repositories provide adapter files that construct a Scenario and an
entry function. The generic command is:

```sh
scripts/run-emacs-gui-verification.sh run ADAPTER.el ENTRY \
  --load-path /path/to/provider \
  --run-dir /private/tmp/my-gui-run
```

Fresh captures intentionally remain `INCOMPLETE` until their selected images
and contact sheet are reviewed. Finalize the same evidence directory with:

```sh
scripts/run-emacs-gui-verification.sh review /private/tmp/my-gui-run
```

Only `VERDICT=PASS` is completion evidence.
