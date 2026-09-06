# Generic Emacs GUI verification

For an already running Emacs, use its existing server through `emacsclient`.
Load the checkout and call the example entry point in an explicit buffer, show
that buffer in the existing graphical frame, and capture only that owned
window. Preserve the user's font and chrome. Do not start another daemon or
frame for this workflow. The `emacsclient-render-capture` skill supplies the
foreground and before/after target guards.

This directory also owns reusable verification mechanisms; application
scenarios live in their respective example repositories:

- `emacs-gui-verifier.el` defines `Scenario`, ordered `Action`, run-local
  `Context`, checkpoint sequencing, assertions, completion, and fail-closed
  evidence finalization.
- The legacy isolated runner `run-emacs-gui-verification.sh` owns one named daemon, explicit load paths,
  external application activation, recorder lifecycle, driver loading, report
  generation, and exact cleanup.
- `record-emacs-window.swift` uses macOS 15 ScreenCaptureKit to record only the
  frame owned by the supplied Emacs PID. It follows replacement window IDs and
  rejects changed pixel mappings. Its canvas is fixed at recording start:
  when the scenario includes resize, prepare the largest tested frame before
  starting the recorder. Smaller windows retain native pixels with padding;
  a window larger than the original canvas invalidates the recording.
- `capture-emacs-window.sh` supplies window-only checkpoint screenshots and
  rejects missing, ambiguous, or changing frame identities. The runner compiles
  the video helper using the system Swift compiler; no package install is needed.

Concrete repositories provide adapter files that construct a Scenario and an
entry function. They can run through the existing server. The following command
instead starts the legacy isolated environment; use it only when that separate
environment is explicitly intended:

```sh
scripts/run-emacs-gui-verification.sh run ADAPTER.el ENTRY \
  --load-path /path/to/provider \
  --run-dir /private/tmp/my-gui-run
```

In that isolated runner, fresh captures remain `INCOMPLETE` until their selected images
and contact sheet are reviewed. Finalize the same evidence directory with:

```sh
scripts/run-emacs-gui-verification.sh review /private/tmp/my-gui-run
```

Only `VERDICT=PASS` completes that runner's evidence bundle. An existing-server
run reports its actual interaction assertions and inspected screenshots
separately. A failed recorder is never evidence of continuous capture, and
neither screenshots nor recording establish an operation latency bound.
