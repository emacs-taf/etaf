;;; benchmark-ebox-resize.el --- Existing-frame resize benchmark -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Drive any mounted Ebox buffer through a pixel-width sweep in its existing
;; GUI frame.  This includes ETAF apps without depending on ETAF Runtime.
;; Publication completion, rather than a fixed sleep, advances each request.
;; The visual scenario engine remains responsible for screenshots/interaction
;; assertions; this tool measures request and publication boundaries only.
;; Internal Ebox state is read for bounded diagnostics, never mutated.

;;; Code:

(require 'cl-lib)
(require 'ebox)
(require 'ebox-viewport)

(declare-function profiler-running-p "profiler" ())
(declare-function ebox-native-reflow-runtime-report "ebox-native-reflow" ())

(defvar ebox-resize-benchmark--run nil
  "The sole active run, including its owned timers and instrumentation.")
(defvar ebox-resize-benchmark--last-result nil
  "Scalar report for the most recently finished run.")
(defvar ebox-resize-benchmark--phases nil
  "Dynamically bound phase counters for the current measured publication.")
(defvar ebox-resize-benchmark--inside nil
  "Non-nil inside the outer measured public viewport operation.")

(defun ebox-resize-benchmark--widths (minimum maximum step rounds initial)
  "Build MINIMUM–MAXIMUM sweeps using STEP and ROUNDS, returning to INITIAL.
Consecutive duplicate widths, which request no change, are omitted."
  (unless (and (integerp minimum) (> minimum 0)
               (integerp maximum) (> maximum minimum)
               (integerp step) (> step 0)
               (integerp rounds) (> rounds 0))
    (error "Resize requires positive integer bounds, step and rounds; min < max"))
  (let* ((ascending (number-sequence minimum maximum step))
         (up (if (= (car (last ascending)) maximum) ascending
               (append ascending (list maximum))))
         (cycle (append up (cdr (reverse up))))
         (previous initial) widths)
    (dolist (width (append (apply #'append (make-list rounds cycle))
                          (list initial)))
      (unless (= width previous) (push width widths))
      (setq previous width))
    (nreverse widths)))

(defun ebox-resize-benchmark--summary (values)
  "Return count, p50, p95 and max for all numeric VALUES."
  (when values
    (let ((sorted (sort (copy-sequence values) #'<)))
      (list :count (length values)
            :p50-ms (nth (1- (ceiling (* .5 (length values)))) sorted)
            :p95-ms (nth (1- (ceiling (* .95 (length values)))) sorted)
            :max-ms (car (last sorted))))))

(defun ebox-resize-benchmark--condition (condition)
  "Summarize CONDITION without printing arbitrary condition data."
  (list :symbol (car condition)
        :message (if (stringp (cadr condition))
                     (truncate-string-to-width (cadr condition) 512 nil nil t)
                   "Non-text condition data omitted")))

(defun ebox-resize-benchmark--hash-file (file)
  "Return FILE's literal SHA-256."
  (with-temp-buffer
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun ebox-resize-benchmark--file-evidence (file)
  "Return canonical FILE and source paths with their literal hashes."
  (let* ((path (file-truename file))
         (source (if (string-suffix-p ".elc" path) (substring path 0 -1) path)))
    (list :file path :sha256 (ebox-resize-benchmark--hash-file path)
          :source (and (file-readable-p source) (file-truename source))
          :source-sha256 (and (file-readable-p source)
                              (ebox-resize-benchmark--hash-file source)))))

(defun ebox-resize-benchmark--code (files)
  "Reload explicitly supplied compiled FILES and report relevant code origins.
Never reload application declarations implicitly.  Without FILES, origin and
disk hashes are observations, not proof that memory matches current bytecode."
  (dolist (file files)
    (unless (and (stringp file) (string-suffix-p ".elc" file)
                 (file-readable-p file)
                 (not (file-newer-than-file-p (substring file 0 -1) file)))
      (error "Missing or stale compiled reload file: %s" file)))
  (let ((reloads
         (mapcar (lambda (file)
                   (let* ((evidence (ebox-resize-benchmark--file-evidence file))
                          (loaded (load (plist-get evidence :file) nil t t)))
                     (unless (equal evidence (ebox-resize-benchmark--file-evidence file))
                       (error "Reload file changed while loading: %s" file))
                     (append evidence (list :loaded (and loaded t))))) files)))
    (list :reload-files reloads :functions
     (mapcar
   (lambda (symbol)
     (let* ((origin (symbol-file symbol 'defun))
            (source (and origin
                         (if (string-suffix-p ".elc" origin)
                             (substring origin 0 -1) origin))))
       (unless (and origin (file-readable-p origin))
         (error "No readable origin for resize function: %s" symbol))
       (when (and (string-suffix-p ".elc" origin)
                  (file-newer-than-file-p source origin))
         (error "Recompile stale resize bytecode: %s" origin))
       (list :function symbol :origin origin
             :origin-sha256 (ebox-resize-benchmark--hash-file origin)
             :source-sha256 (and (file-readable-p source)
                                 (ebox-resize-benchmark--hash-file source))
             :reloaded (and (member (file-truename origin)
                                   (mapcar #'file-truename files)) t))))
   '(ebox-rerender-buffer-with-context ebox--window-size-change
     ebox-surface-update-buffer-viewport
     ebox-incremental-prepare-viewport-commit ebox-resize-benchmark-start)))))

(defun ebox-resize-benchmark--payload (buffer)
  "Read bounded workload facts from BUFFER, without copying runtime graphs."
  (let* ((state (and (buffer-live-p buffer) (ebox--buffer-render-state buffer)))
         (nodes (plist-get state :node-table)))
    (list :nodes (and (hash-table-p nodes) (hash-table-count nodes))
          :characters (and (buffer-live-p buffer)
                           (with-current-buffer buffer (buffer-size)))
          :viewport (list (plist-get state :viewport-width)
                          (plist-get state :viewport-height)))))

(defun ebox-resize-benchmark--guard ()
  "Require the captured foreground buffer, frame, font and height."
  (let* ((run ebox-resize-benchmark--run)
         (frame (plist-get run :frame))
         (window (plist-get run :window))
         (buffer (plist-get run :buffer)))
    (unless (and (frame-live-p frame) (display-graphic-p frame)
                 (eq frame (selected-frame)) (eq t (frame-visible-p frame))
                 (eq t (frame-focus-state frame)) (window-live-p window)
                 (eq window (selected-window))
                 (eq buffer (window-buffer window))
                 (ebox-surface-buffer-mounted-p buffer)
                 (equal (frame-parameter frame 'font) (plist-get run :font))
                 (= (frame-pixel-height frame) (plist-get run :height))
                 (not (active-minibuffer-window)))
      (error "Resize target, focus, font, height or mount changed"))))

(defun ebox-resize-benchmark--phase (name original &rest arguments)
  "Record inclusive NAME timing around ORIGINAL called with ARGUMENTS."
  (if (not ebox-resize-benchmark--phases)
      (apply original arguments)
    (let ((started (float-time)) (gc-start gc-elapsed))
      (unwind-protect (apply original arguments)
        (let ((row (or (gethash name ebox-resize-benchmark--phases)
                       (puthash name (vector 0 0.0 0.0)
                                ebox-resize-benchmark--phases))))
          (cl-incf (aref row 0))
          (cl-incf (aref row 1) (* 1000 (- (float-time) started)))
          (cl-incf (aref row 2) (* 1000 (- gc-elapsed gc-start))))))))

(defun ebox-resize-benchmark--write (file report)
  "Write REPORT as UTF-8 data to a new FILE, without overwriting evidence."
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-buffer
      (prin1 report (current-buffer))
      (insert "\n")
      (write-region (point-min) (point-max) file nil 'silent nil 'excl))))

(defun ebox-resize-benchmark--finish (status &optional condition)
  "Release owned resources and record STATUS and optional CONDITION."
  (let ((run ebox-resize-benchmark--run))
    (when run
      ;; Cleanup precedes report construction: even a dead buffer or write
      ;; failure cannot leave a timed benchmark attached to the application.
      (setq ebox-resize-benchmark--run nil)
      (dolist (key '(:timer :watchdog))
        (when (timerp (plist-get run key)) (cancel-timer (plist-get run key))))
      (advice-remove 'ebox-rerender-buffer-with-context
                     #'ebox-resize-benchmark--publication)
      (dolist (binding (plist-get run :bindings))
        (advice-remove (car binding) (cdr binding)))
      (let* ((samples (nreverse (plist-get run :samples)))
             (valid (and (eq status 'complete)
                         (= (length samples) (plist-get run :planned-count))
                         (cl-every (lambda (sample) (plist-get sample :published)) samples)))
             (publication (ebox-resize-benchmark--summary
                           (delq nil (mapcar (lambda (s) (plist-get s :publication-ms)) samples))))
             (latency (ebox-resize-benchmark--summary
                       (delq nil (mapcar (lambda (s) (plist-get s :request-to-published-ms)) samples))))
             (report
              (list :format-version 1 :status status :valid valid
                    :failure (and condition (ebox-resize-benchmark--condition condition))
                    :pid (emacs-pid) :emacs-version emacs-version
                    :system-type system-type :buffer (plist-get run :buffer-name)
                    :font (plist-get run :font) :height (plist-get run :height)
                    :range (plist-get run :range) :rounds (plist-get run :rounds)
                    :step (plist-get run :step) :delay (plist-get run :delay)
                    :requested-widths (plist-get run :widths)
                    :start-width (plist-get run :start-width)
                    :gc-before (plist-get run :gc-policy)
                    :gc-after (list gc-cons-threshold gc-cons-percentage)
                    :whole-run-gcs (- gcs-done (plist-get run :gcs))
                    :whole-run-gc-ms (* 1000 (- gc-elapsed (plist-get run :gc)))
                    :code (plist-get run :code) :native (plist-get run :native)
                    :payload-before (plist-get run :payload)
                    :payload-after (ebox-resize-benchmark--payload (plist-get run :buffer))
                    :planned-count (plist-get run :planned-count)
                    :requested-count (length samples)
                    :completed-count (cl-count-if (lambda (s) (plist-get s :published)) samples)
                    :publication publication :request-to-published latency
                    :limit-ms (plist-get run :limit)
                    :within-limit (and valid latency
                                       (<= (plist-get latency :max-ms) (plist-get run :limit)))
                    :phase-columns '(calls inclusive-ms gc-ms)
                    :samples samples)))
        (setq ebox-resize-benchmark--last-result report)
        (condition-case write-error
            (ebox-resize-benchmark--write (plist-get run :output) report)
          ((error quit)
           (setq ebox-resize-benchmark--last-result
                 (plist-put report :evidence-write-error
                            (ebox-resize-benchmark--condition write-error)))
           (setf (plist-get ebox-resize-benchmark--last-result :status) 'failed
                 (plist-get ebox-resize-benchmark--last-result :valid) nil
                 (plist-get ebox-resize-benchmark--last-result :within-limit) nil)
           (message "Resize evidence could not be written: %s"
                    (plist-get (ebox-resize-benchmark--condition write-error) :message))
           (unless condition (signal (car write-error) (cdr write-error)))))))))

(defun ebox-resize-benchmark--abort (condition)
  "Record failure and clean up before re-signaling original CONDITION."
  (condition-case report-error
      (ebox-resize-benchmark--finish 'failed condition)
    ((error quit)
     (message "Resize failure report unavailable: %s"
              (plist-get (ebox-resize-benchmark--condition report-error) :message))))
  (signal (car condition) (cdr condition)))

(defun ebox-resize-benchmark--schedule ()
  "Schedule the next request after the configured event-loop delay."
  (setf (plist-get ebox-resize-benchmark--run :timer)
        (run-at-time (plist-get ebox-resize-benchmark--run :delay)
                     nil #'ebox-resize-benchmark--next)))

(defun ebox-resize-benchmark--timeout ()
  "Fail a request that did not publish within its configured deadline."
  (when ebox-resize-benchmark--run
    (ebox-resize-benchmark--finish 'failed '(error "Resize publication timed out"))))

(defun ebox-resize-benchmark--settled ()
  "Wait for the product's own GC lease to restore, without changing policy."
  (when ebox-resize-benchmark--run
    (condition-case condition
        (progn
          (ebox-resize-benchmark--guard)
          (cond
           ((and (not ebox--deferred-render-gc-state)
                 (equal (list gc-cons-threshold gc-cons-percentage)
                        (plist-get ebox-resize-benchmark--run :gc-policy)))
            (ebox-resize-benchmark--finish 'complete))
           ((>= (float-time) (plist-get ebox-resize-benchmark--run :settle-deadline))
            (error "GC policy did not restore before the settle deadline"))
           (t
            (setf (plist-get ebox-resize-benchmark--run :timer)
                  (run-at-time .05 nil #'ebox-resize-benchmark--settled)))))
      ((error quit) (ebox-resize-benchmark--abort condition)))))

(defun ebox-resize-benchmark--publication (original buffer width &optional height)
  "Measure ORIGINAL publishing BUFFER for WIDTH and HEIGHT."
  (if (or ebox-resize-benchmark--inside (not ebox-resize-benchmark--run)
          (not (plist-get ebox-resize-benchmark--run :armed))
          (not (eq (get-buffer buffer) (plist-get ebox-resize-benchmark--run :buffer))))
      (funcall original buffer width height)
    (let* ((ebox-resize-benchmark--inside t)
           (run ebox-resize-benchmark--run)
           (sample (plist-get run :current))
           (expected (and sample (not (plist-get sample :published))))
           (phase-data (make-hash-table :test #'eq))
           before-failure failure result completed)
      (unwind-protect
          (progn
            (condition-case condition (ebox-resize-benchmark--guard)
              (error (setq before-failure condition)))
            (let ((started (float-time)) (cpu (current-cpu-time))
                  (gc gc-elapsed) (gcs gcs-done)
                  (policy (list gc-cons-threshold gc-cons-percentage)))
              ;; Attribution errors belong to this diagnostic, not the app.
              ;; Always execute the real call once and preserve its outcome.
              (condition-case condition
                  (let ((ebox-resize-benchmark--phases phase-data))
                    (setq result (funcall original buffer width height)))
                ((error quit) (setq failure condition)))
              (let ((finished (float-time)) (cpu-end (current-cpu-time))
                    (gc-end gc-elapsed) (gcs-end gcs-done))
                ;; An observer may cancel this run or start a replacement.
                ;; Never mutate a retired sample or schedule through a new run.
                (when (eq run ebox-resize-benchmark--run)
                  (condition-case condition
                      (progn
                        (unless (and expected (eq sample (plist-get run :current)))
                          (error "Unattributed or duplicate publication during resize"))
                        (let ((payload (ebox-resize-benchmark--payload (get-buffer buffer)))
                              (window (plist-get run :window)) phases)
                          (maphash (lambda (name values) (push (cons name values) phases))
                                   phase-data)
                          (setf (plist-get sample :publication-ms) (* 1000 (- finished started))
                                (plist-get sample :request-to-published-ms)
                                (* 1000 (- finished (plist-get sample :requested-at)))
                                (plist-get sample :cpu-ms)
                                (* 1000.0 (/ (- (car cpu-end) (car cpu)) (float (cdr cpu))))
                                (plist-get sample :gc-ms) (* 1000 (- gc-end gc))
                                (plist-get sample :gcs) (- gcs-end gcs)
                                (plist-get sample :gc-policy) policy
                                (plist-get sample :payload) payload
                                (plist-get sample :phases) phases
                                (plist-get sample :foreground-before) (not before-failure))
                          (when failure (signal (car failure) (cdr failure)))
                          (when before-failure (signal (car before-failure) (cdr before-failure)))
                          (ebox-resize-benchmark--guard)
                          (setf (plist-get sample :foreground-after) t)
                          (unless (and (= (frame-pixel-width (plist-get run :frame))
                                          (plist-get sample :width))
                                       (equal (list width height)
                                              (list (ebox-viewport-window-width window)
                                                    (window-body-height window)))
                                       (equal (list width height) (plist-get payload :viewport)))
                            (error "Requested, actual and published viewport dimensions disagree"))
                          (when (> finished (+ (plist-get sample :requested-at)
                                               (plist-get run :timeout)))
                            (error "Resize publication exceeded its deadline"))
                          (setf (plist-get sample :published) t)
                          (cancel-timer (plist-get run :watchdog))
                          (setf (plist-get run :watchdog) nil)
                          (ebox-resize-benchmark--schedule)))
                    ((error quit) (ebox-resize-benchmark--observation-failed run condition))))))
            (setq completed t)
            (if failure (signal (car failure) (cdr failure)) result))
        (unless completed
          (ebox-resize-benchmark--observation-failed
           run '(error "Publication exited before observation completed")))))))

(defun ebox-resize-benchmark--observation-failed (run condition)
  "Retire captured RUN with CONDITION without changing a product return value."
  (when (eq run ebox-resize-benchmark--run)
    (condition-case report-error
        (ebox-resize-benchmark--finish 'failed condition)
      ((error quit)
       (message "Resize failure report unavailable: %s"
                (plist-get (ebox-resize-benchmark--condition report-error) :message))))))

(defun ebox-resize-benchmark--ready-p (run)
  "Arm RUN after preceding rendering has released its GC lease."
  (or (plist-get run :armed)
      (cond
       ((>= (float-time) (plist-get run :ready-deadline))
        (error "Preceding render did not settle before the startup deadline"))
       (ebox--deferred-render-gc-state
        (ebox-resize-benchmark--schedule)
        nil)
       (t
        (setf (plist-get run :gc-policy) (list gc-cons-threshold gc-cons-percentage)
              (plist-get run :gcs) gcs-done
              (plist-get run :gc) gc-elapsed
              (plist-get run :payload)
              (ebox-resize-benchmark--payload (plist-get run :buffer))
              (plist-get run :armed) t)))))

(defun ebox-resize-benchmark--next ()
  "Issue one resize, then return to Emacs until its publication completes."
  (when ebox-resize-benchmark--run
    (condition-case condition
        (let ((inhibit-quit nil))
          (ebox-resize-benchmark--guard)
          (let* ((run ebox-resize-benchmark--run)
                 (frame (plist-get run :frame))
                 (width (car (plist-get run :remaining))))
            (setf (plist-get run :timer) nil)
            (when (ebox-resize-benchmark--ready-p run)
            (if (not width)
                (progn
                  (setf (plist-get run :settle-deadline)
                        (+ (float-time) (plist-get run :timeout)))
                  (ebox-resize-benchmark--settled))
              ;; Allocate every mutable slot before sharing this record with
              ;; the publication callback: plist setters may replace a head
              ;; when adding a previously absent key.
              (let ((sample (list :index (1+ (length (plist-get run :samples)))
                                  :width width :requested-at (float-time)
                                  :publication-ms nil :request-to-published-ms nil
                                  :cpu-ms nil :gc-ms nil :gcs nil :gc-policy nil
                                  :payload nil :phases nil :published nil
                                  :foreground-before nil :foreground-after nil))
                    (frame-resize-pixelwise t))
                (setf (plist-get run :remaining) (cdr (plist-get run :remaining))
                      (plist-get run :current) sample
                      (plist-get run :samples) (cons sample (plist-get run :samples))
                      (plist-get run :watchdog)
                      (run-at-time (plist-get run :timeout) nil
                                   #'ebox-resize-benchmark--timeout))
                (set-frame-size frame
                                (- width (- (frame-pixel-width frame)
                                            (frame-text-width frame)))
                                (frame-text-height frame) t)
                (redisplay t))))))
      ((error quit) (ebox-resize-benchmark--abort condition)))))

;;;###autoload
(cl-defun ebox-resize-benchmark-start
    (buffer minimum maximum &key (step 32) (rounds 3) (delay .01)
            (timeout 5.0) (limit-ms 50.0) output reload-files phases)
  "Resize existing BUFFER from MINIMUM to MAXIMUM outer-frame pixels.
STEP and ROUNDS control repeated narrow→wide→narrow sweeps.  The final measured
request restores the starting width.  OUTPUT must name a new evidence file.
DELAY spaces completed publications; TIMEOUT bounds startup and publication.
LIMIT-MS applies to all request→publication samples, including GC and first use.
RELOAD-FILES explicitly reloads fresh compiled modules before measurement.
PHASES names loaded ebox-/tp-/etaf- functions for inclusive diagnostics.
Use `ebox-resize-benchmark-status' to poll and `ebox-resize-benchmark-cancel'
to stop.  Failure stops at the current width.  No frame or server is created,
no application observer is replaced, and no GC/font policy is changed."
  (when ebox-resize-benchmark--run (error "A resize benchmark is already active"))
  (unless (and (stringp output) (not (file-exists-p output))
               (file-directory-p (file-name-directory (expand-file-name output)))
               (numberp delay) (> delay 0) (numberp timeout) (> timeout delay)
               (numberp limit-ms) (> limit-ms 0))
    (error "Resize requires a new output path and positive delay/timeout/limit"))
  (when (and (fboundp 'profiler-running-p) (profiler-running-p))
    (error "Stop profiling before collecting resize latency"))
  (dolist (name phases)
    (unless (and (symbolp name) (fboundp name)
                 (string-match-p "\\`\\(?:ebox\\|tp\\|etaf\\)-" (symbol-name name))
                 (not (string-prefix-p "ebox-resize-benchmark-" (symbol-name name)))
                 (not (eq name 'ebox-rerender-buffer-with-context)))
      (error "Invalid or duplicate outer measurement phase: %s" name)))
  (let* ((target (get-buffer buffer))
         (frame (selected-frame))
         (initial (frame-pixel-width frame))
         (widths (ebox-resize-benchmark--widths minimum maximum step rounds initial)))
    (setq ebox-resize-benchmark--last-result nil
          ebox-resize-benchmark--run
          (list :buffer target :buffer-name (and target (buffer-name target))
                :frame frame :window (selected-window)
                :font (frame-parameter frame 'font) :height (frame-pixel-height frame)
                :gc-policy (list gc-cons-threshold gc-cons-percentage)
                :gcs gcs-done :gc gc-elapsed :code nil :native nil :payload nil
                :start-width initial :widths widths :remaining widths
                :planned-count (length widths) :range (list minimum maximum)
                :rounds rounds :step step :delay delay :timeout timeout
                :limit limit-ms :output (expand-file-name output)
                :timer nil :watchdog nil :current nil :samples nil
                :bindings nil :settle-deadline nil :armed nil :ready-deadline nil))
    (condition-case condition
        (progn
          (ebox-resize-benchmark--guard)
          (setf (plist-get ebox-resize-benchmark--run :code)
                (ebox-resize-benchmark--code reload-files)
                (plist-get ebox-resize-benchmark--run :native)
                (and (fboundp 'ebox-native-reflow-runtime-report)
                     (ebox-native-reflow-runtime-report))
                (plist-get ebox-resize-benchmark--run :payload)
                (ebox-resize-benchmark--payload target)
                (plist-get ebox-resize-benchmark--run :gcs) gcs-done
                (plist-get ebox-resize-benchmark--run :gc) gc-elapsed)
          (ebox-resize-benchmark--guard)
          (setf (plist-get ebox-resize-benchmark--run :ready-deadline)
                (+ (float-time) timeout))
          (dolist (name (delete-dups (copy-sequence phases)))
            (let ((wrapper (apply-partially #'ebox-resize-benchmark--phase name)))
              (push (cons name wrapper) (plist-get ebox-resize-benchmark--run :bindings))
              (advice-add name :around wrapper)))
          (advice-add 'ebox-rerender-buffer-with-context :around
                      #'ebox-resize-benchmark--publication)
          (ebox-resize-benchmark--schedule)
          (ebox-resize-benchmark-status))
      ((error quit) (ebox-resize-benchmark--abort condition)))))

;;;###autoload
(defun ebox-resize-benchmark-status ()
  "Return bounded progress or the last run's completion/latency summary."
  (if ebox-resize-benchmark--run
      (list :status 'running
            :requested (length (plist-get ebox-resize-benchmark--run :samples))
            :planned (plist-get ebox-resize-benchmark--run :planned-count)
            :output (plist-get ebox-resize-benchmark--run :output))
    (cl-loop for key in '(:status :valid :failure :completed-count :planned-count
                         :publication :request-to-published :within-limit
                         :evidence-write-error)
             append (list key (plist-get ebox-resize-benchmark--last-result key)))))

;;;###autoload
(defun ebox-resize-benchmark-cancel ()
  "Stop this benchmark and release its timers and advice."
  (interactive)
  (ebox-resize-benchmark--finish 'cancelled '(quit "Resize cancelled"))
  (ebox-resize-benchmark-status))

(provide 'benchmark-ebox-resize)
;;; benchmark-ebox-resize.el ends here
