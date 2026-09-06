# Generic Emacs GUI verification

For an already running Emacs, use its existing server through `emacsclient`.
Load the checkout and call the example entry point in an explicit buffer, show
that buffer in the existing graphical frame, and capture only that owned
window. Preserve the user's font and chrome. Do not start another daemon or
frame for this workflow. Preserve application focus so the user can keep working
in other apps. The `emacsclient-render-capture` skill supplies buffer selection
without activation and before/after target guards.

This directory also owns reusable verification mechanisms; application
scenarios live in their respective example repositories:

- `emacs-gui-verifier.el` defines `Scenario`, ordered `Action`, run-local
  `Context`, checkpoint sequencing, assertions, completion, and fail-closed
  evidence finalization.
- `benchmark-ebox-resize.el` drives continuous pixel-width sweeps of any
  existing mounted Ebox buffer, including ETAF apps, without taking over its
  observer. See the existing-server entry below.
- The legacy isolated runner `run-emacs-gui-verification.sh` owns one named daemon, explicit load paths,
  external application activation, recorder lifecycle, driver loading, report
  generation, and exact cleanup.
- `record-emacs-window.swift` uses macOS 15 ScreenCaptureKit to record only the
  frame owned by the supplied Emacs PID. It follows replacement window IDs and
  rejects changed pixel mappings. Its desktop-independent window filter works
  without activating Emacs. Its canvas is fixed at recording start:
  when the scenario includes resize, prepare the largest tested frame before
  starting the recorder. Smaller windows retain native pixels with padding;
  a window larger than the original canvas invalidates the recording.
- `capture-emacs-window.sh` supplies window-only checkpoint screenshots and
  rejects missing, ambiguous, or changing frame identities without activating
  Emacs. The runner compiles
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

For an existing server, take a background screenshot with the observed process ID:

```sh
ETAF_GUI_CAPTURE_PID=12345 scripts/capture-emacs-window.sh -x /tmp/app-checkpoint.png
```

Keep the target frame open and non-minimized. Validate a known content change in
before/after pixels to establish fresh background rendering. Hidden, minimized,
off-Space and locked-session behavior is not covered by this procedure. Background
Lisp callbacks and runtime timing do not require application activation; report
them as background measurements, separately from foreground input-to-display
latency. Use Emacs-local operations while another app is active, not global input.

## Continuous resize on the existing server

Use this entry for resize performance investigations instead of copying the
historical `.omx/component-api-implementation/*continuous-resize*.el` probes.
First show the intended buffer in the user's existing foreground GUI frame.
Preserve its font and chrome. Compile changed product modules before loading
them; `make compile` in this repository also compiles the benchmark tool.

```sh
emacsclient --eval '(progn
  (load "/path/to/etaf/scripts/benchmark-ebox-resize.elc" nil t t)
  (ebox-resize-benchmark-start "*Your app*" 480 1400
    :step 32 :rounds 3 :output "/tmp/resize-run-1.eldata"))'
```

The bounds are outer-frame pixels. Every round goes from narrow to wide and
back, including both endpoints even when the step does not divide the range.
The last measured request returns to the initial width. Consecutive equal
widths are omitted because they request no resize; no warmup or slow sample is
dropped. The function returns immediately. Poll or cancel this owned run with:

```elisp
(ebox-resize-benchmark-status)
(ebox-resize-benchmark-cancel)
```

`:delay` (default 0.01 seconds) runs between completed publications;
`:timeout` (default 5 seconds) bounds startup, publication and final settling.
The tool waits for a preceding render's GC lease to end before recording the
baseline, and for its own run's lease to end before accepting the final result.
Unsupported sizes,
changed targets/focus/font/height, publication failures and cancellation produce
invalid/incomplete evidence. Advice and timers are removed on success, error,
quit and timeout. Failure leaves the last applied width; it does not fight a
user's subsequent window changes. No server, frame, application buffer, observer, profiler
or GC policy is created/replaced to make the benchmark pass.

Use a **new output path** each time. UTF-8 `.eldata` reports retain all requests,
all completed samples, actual published dimensions, node/text counts, GC,
per-operation CPU time, code origins and hashes. Optional `:phases '(FUNCTIONS…)`
records inclusive phase durations for loaded `ebox-`, `tp-` and `etaf-` provider
functions. The driver and outer publication boundary cannot be selected as
phases; nested durations must not be summed.
Publication timing ends when the real public Ebox viewport call returns.
Request→publication also includes event-loop delivery. Neither metric proves
compositor presentation, absence of flicker, or every interaction's correctness;
use the existing visual scenario/capture tools for those claims.

`:valid t` requires complete correctly attributed publication coverage.
`:within-limit t` additionally requires **every** request→publication sample to
meet `:limit-ms` (default 50). Inspect p95 **and** max, including GC samples.
Compare payload counts at matching widths before making speedup claims. A
different page size/content or loaded version is a different baseline.

Code origins and disk hashes alone cannot establish when a running function was
loaded. After recompilation, `:reload-files '("/checkout/ebox/ebox-viewport.elc" …)`
explicitly loads the chosen fresh bytecode before instrumentation. `:code`
contains every explicitly loaded file's canonical path, source/bytecode hashes
and load result, plus observed core function and benchmark driver origins;
matching origins are marked `:reloaded t`. Choose the affected modules; do not reload
application component declarations blindly. Without this option, report code
origin observations separately from independent evidence of a fresh GUI load.

Run the tool's regression checks with `make resize-benchmark-tests`; they also
run in the full `make check` gate. Application-specific data setup and interaction
assertions remain in the example repositories, not this resize driver.
