;;; etaf-resize-benchmark-tests.el --- Resize driver contracts -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'benchmark-ebox-resize)

(defmacro etaf-resize-test--with-run (&rest body)
  "Evaluate BODY with isolated evidence and deterministic frame/publication IO."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "etaf-resize-test-" t))
          (output (expand-file-name "result.eldata" directory))
          (buffer (generate-new-buffer " *resize-test*"))
          (ebox-resize-benchmark--run nil)
          (ebox-resize-benchmark--last-result nil)
          (ebox--deferred-render-gc-state nil)
          (width 600))
     (unwind-protect
         (cl-letf (((symbol-function 'ebox-resize-benchmark--guard) #'ignore)
                   ((symbol-function 'ebox-resize-benchmark--code) (lambda (_) nil))
                   ((symbol-function 'ebox-native-reflow-runtime-report) #'ignore)
                   ((symbol-function 'ebox-resize-benchmark--payload)
                    (lambda (_buffer) (list :nodes 3 :characters 4 :viewport (list width 24))))
                   ((symbol-function 'frame-pixel-width) (lambda (&optional _) width))
                   ((symbol-function 'frame-text-width) (lambda (&optional _) width))
                   ((symbol-function 'frame-text-height) (lambda (&optional _) 400))
                   ((symbol-function 'ebox-viewport-window-width) (lambda (_) width))
                   ((symbol-function 'window-body-height) (lambda (&rest _) 24))
                   ((symbol-function 'redisplay) #'ignore)
                   ((symbol-function 'set-frame-size)
                    (lambda (_frame new-width _height &optional _) (setq width new-width))))
           ,@body)
       (when ebox-resize-benchmark--run
         (ebox-resize-benchmark-cancel))
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (delete-directory directory t))))

(defun etaf-resize-test--tick ()
  "Consume the owned driver timer and execute one request synchronously."
  (cancel-timer (plist-get ebox-resize-benchmark--run :timer))
  (ebox-resize-benchmark--next))

(ert-deftest etaf-resize-widths-cover-both-endpoints-and-return ()
  "Non-divisible ranges retain their widest point on every sweep."
  (should (equal (ebox-resize-benchmark--widths 400 505 40 2 600)
                 '(400 440 480 505 480 440 400 440 480 505 480 440 400 600)))
  (should (equal (ebox-resize-benchmark--widths 400 500 100 1 400)
                 '(500 400)))
  (dolist (args '((0 500 1 1 400) (500 400 1 1 400)
                  (400 500 0 1 400) (400 500 1 0 400)))
    (should-error (apply #'ebox-resize-benchmark--widths args))))

(ert-deftest etaf-resize-completion-keeps-every-publication-and-restores-width ()
  "Only successful publication advances the driver; all samples are retained."
  (etaf-resize-test--with-run
    (ebox-resize-benchmark-start buffer 400 800 :step 200 :rounds 1 :delay 10 :timeout 20 :output output)
    (let ((planned (plist-get ebox-resize-benchmark--run :planned-count)))
      (dotimes (_ planned)
        (etaf-resize-test--tick)
        (should-not (plist-get ebox-resize-benchmark--run :timer))
        (should (timerp (plist-get ebox-resize-benchmark--run :watchdog)))
        (should (eq :published
                    (ebox-resize-benchmark--publication (lambda (&rest _) :published)
                                                        buffer width 24)))
        (should (timerp (plist-get ebox-resize-benchmark--run :timer)))
        (should-not (plist-get ebox-resize-benchmark--run :watchdog)))
      (etaf-resize-test--tick)
      (should-not ebox-resize-benchmark--run)
      (should (= width 600))
      (should (plist-get ebox-resize-benchmark--last-result :valid))
      (should (= planned (plist-get ebox-resize-benchmark--last-result :completed-count)))
      (should (file-exists-p output))
      (should-not (advice-member-p #'ebox-resize-benchmark--publication
                                  'ebox-rerender-buffer-with-context)))))

(ert-deftest etaf-resize-publication-error-and-quit-preserve-cause-and-cleanup ()
  "Original errors and C-g cannot leave advice or timers attached."
  (dolist (failure '((error "original publication failure") (quit "publication interrupted")))
    (etaf-resize-test--with-run
      (ebox-resize-benchmark-start buffer 400 800 :delay 10 :timeout 20 :output output)
      (etaf-resize-test--tick)
      (let ((watchdog (plist-get ebox-resize-benchmark--run :watchdog)) caught)
        (condition-case condition
            (ebox-resize-benchmark--publication
             (lambda (&rest _) (signal (car failure) (cdr failure))) buffer width 24)
          ((error quit) (setq caught condition)))
        (should (equal caught failure))
        (should-not ebox-resize-benchmark--run)
        (should-not (memq watchdog timer-list))
        (should-not (advice-member-p #'ebox-resize-benchmark--publication
                                    'ebox-rerender-buffer-with-context))
        (should (= 0 (plist-get ebox-resize-benchmark--last-result :completed-count)))
        (should-not (plist-get ebox-resize-benchmark--last-result :valid))))))

(ert-deftest etaf-resize-timeout-is-incomplete-and-releases-owned-resources ()
  "No publication must produce failed evidence, never a successful sample."
  (etaf-resize-test--with-run
    (ebox-resize-benchmark-start buffer 400 800 :delay 10 :timeout 20 :output output)
    (etaf-resize-test--tick)
    (let ((watchdog (plist-get ebox-resize-benchmark--run :watchdog)))
      (ebox-resize-benchmark--timeout)
      (should-not ebox-resize-benchmark--run)
      (should-not (memq watchdog timer-list))
      (should (eq 'failed (plist-get ebox-resize-benchmark--last-result :status)))
      (should (= 1 (plist-get ebox-resize-benchmark--last-result :requested-count)))
      (should (= 0 (plist-get ebox-resize-benchmark--last-result :completed-count))))))

(ert-deftest etaf-resize-report-failure-preserves-publication-failure ()
  "A secondary write failure is visible while the original error survives."
  (etaf-resize-test--with-run
    (ebox-resize-benchmark-start buffer 400 800 :delay 10 :timeout 20 :output output)
    (let (warning)
      (cl-letf (((symbol-function 'ebox-resize-benchmark--write)
                 (lambda (&rest _) (error "disk failure")))
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq warning (apply #'format format-string args)))))
        (should (equal '(error "original")
                       (should-error (ebox-resize-benchmark--abort '(error "original"))))))
      (should (string-match-p "disk failure" warning))
      (should (plist-get ebox-resize-benchmark--last-result :evidence-write-error))
      (should-not ebox-resize-benchmark--run))))

(ert-deftest etaf-resize-partial-installation-releases-earlier-phase-advice ()
  "Instrumentation setup failure cleans previously installed advice."
  (etaf-resize-test--with-run
    (let ((original-add (symbol-function 'advice-add)) (calls 0))
      (cl-letf (((symbol-function 'advice-add)
                 (lambda (&rest args)
                   (if (= 2 (cl-incf calls)) (error "injected install failure")
                     (apply original-add args)))))
        (should-error
         (ebox-resize-benchmark-start buffer 400 800 :delay 10 :timeout 20
                                     :phases '(ebox-viewport-window-width ebox-surface-buffer-revision)
                                     :output output)))
      (should-not ebox-resize-benchmark--run)
      (let (remaining)
        (advice-mapc (lambda (_fn _props) (setq remaining t)) 'ebox-viewport-window-width)
        (should-not remaining)))))

(ert-deftest etaf-resize-mismatched-viewport-cannot-count-as-publication ()
  "A call returning normally is insufficient when published geometry differs."
  (etaf-resize-test--with-run
    (ebox-resize-benchmark-start buffer 400 800 :delay 10 :timeout 20 :output output)
    (etaf-resize-test--tick)
    (should (eq :real-result
                (ebox-resize-benchmark--publication (lambda (&rest _) :real-result)
                                                    buffer (1+ width) 24)))
    (should-not (plist-get ebox-resize-benchmark--last-result :valid))
    (should (= 0 (plist-get ebox-resize-benchmark--last-result :completed-count)))))

(ert-deftest etaf-resize-writer-refuses-existing-evidence ()
  "A later invocation must not silently overwrite a previous report."
  (etaf-resize-test--with-run
    (ebox-resize-benchmark--write output '(:original t))
    (should-error (ebox-resize-benchmark--write output '(:replacement t)))
    (with-temp-buffer
      (insert-file-contents output)
      (should (equal '(:original t) (read (current-buffer)))))))

(ert-deftest etaf-resize-nested-publication-counts-only-the-outer-call ()
  "Nested public calls belong to the same measured viewport request."
  (etaf-resize-test--with-run
    (ebox-resize-benchmark-start buffer 400 800 :delay 10 :timeout 20 :output output)
    (etaf-resize-test--tick)
    (should
     (eq :outer
         (ebox-resize-benchmark--publication
          (lambda (&rest _)
            (ebox-resize-benchmark--publication #'ignore buffer width 24)
            :outer)
          buffer width 24)))
    (should (= 1 (length (plist-get ebox-resize-benchmark--run :samples))))
    (should (timerp (plist-get ebox-resize-benchmark--run :timer)))))

(ert-deftest etaf-resize-successful-coverage-without-written-evidence-fails ()
  "Successful calls cannot yield a passed tool result if evidence was lost."
  (etaf-resize-test--with-run
    (ebox-resize-benchmark-start buffer 400 800 :step 400 :rounds 1
                                :delay 10 :timeout 20 :output output)
    (dotimes (_ (plist-get ebox-resize-benchmark--run :planned-count))
      (etaf-resize-test--tick)
      (ebox-resize-benchmark--publication #'ignore buffer width 24))
    (cl-letf (((symbol-function 'ebox-resize-benchmark--write)
               (lambda (&rest _) (error "disk failure")))
              ((symbol-function 'message) #'ignore))
      (should-error (etaf-resize-test--tick)))
    (should-not ebox-resize-benchmark--run)
    (should (eq 'failed (plist-get ebox-resize-benchmark--last-result :status)))
    (should-not (plist-get ebox-resize-benchmark--last-result :valid))
    (should-not (plist-get ebox-resize-benchmark--last-result :within-limit))
    (should (plist-get ebox-resize-benchmark--last-result :evidence-write-error))))

(ert-deftest etaf-resize-unattributed-call-still-executes-product-once ()
  "Diagnostic attribution failure must not prevent real application work."
  (etaf-resize-test--with-run
    (ebox-resize-benchmark-start buffer 400 800 :delay 10 :timeout 20 :output output)
    (etaf-resize-test--tick)
    (ebox-resize-benchmark--publication #'ignore buffer width 24)
    (let ((calls 0))
      (should (eq :real-result
                  (ebox-resize-benchmark--publication
                   (lambda (&rest _) (cl-incf calls) :real-result) buffer width 24)))
      (should (= calls 1))
      (should-not ebox-resize-benchmark--run)
      (should-not (plist-get ebox-resize-benchmark--last-result :valid)))))

(ert-deftest etaf-resize-cancel-from-product-callback-cannot-rearm-run ()
  "Cancellation inside a publication prevents its old callback from rearming."
  (etaf-resize-test--with-run
    (ebox-resize-benchmark-start buffer 400 800 :delay 10 :timeout 20 :output output)
    (etaf-resize-test--tick)
    (should (eq :real-result
                (ebox-resize-benchmark--publication
                 (lambda (&rest _) (ebox-resize-benchmark-cancel) :real-result)
                 buffer width 24)))
    (should-not ebox-resize-benchmark--run)
    (should (eq 'cancelled (plist-get ebox-resize-benchmark--last-result :status)))))

(ert-deftest etaf-resize-old-publication-cannot-reschedule-replacement-run ()
  "A callback may replace the benchmark; old completion cannot own its timer."
  (etaf-resize-test--with-run
    (ebox-resize-benchmark-start buffer 400 800 :delay 10 :timeout 20 :output output)
    (etaf-resize-test--tick)
    (let (new-run new-timer)
      (ebox-resize-benchmark--publication
       (lambda (&rest _)
         (ebox-resize-benchmark-cancel)
         (ebox-resize-benchmark-start buffer 400 800 :delay 10 :timeout 20
                                     :output (expand-file-name "new.eldata" directory))
         (setq new-run ebox-resize-benchmark--run
               new-timer (plist-get new-run :timer)))
       buffer width 24)
      (should (eq new-run ebox-resize-benchmark--run))
      (should (eq new-timer (plist-get new-run :timer)))
      (should-not (plist-get new-run :samples)))))

(ert-deftest etaf-resize-publication-boundary-detects-transient-focus-loss ()
  "Losing focus before publication invalidates it even if the call restores it."
  (etaf-resize-test--with-run
    (ebox-resize-benchmark-start buffer 400 800 :delay 10 :timeout 20 :output output)
    (etaf-resize-test--tick)
    (let (focused)
      (cl-letf (((symbol-function 'ebox-resize-benchmark--guard)
                 (lambda () (unless focused (error "lost focus")))))
        (should (eq :real-result
                    (ebox-resize-benchmark--publication
                     (lambda (&rest _) (setq focused t) :real-result) buffer width 24))))
      (should-not ebox-resize-benchmark--run)
      (should-not (plist-get ebox-resize-benchmark--last-result :valid)))))

(ert-deftest etaf-resize-blocking-publication-cannot-hide-expired-deadline ()
  "Completion must check the deadline even if the event loop could not poll it."
  (etaf-resize-test--with-run
    (ebox-resize-benchmark-start buffer 400 800 :delay 10 :timeout 20 :output output)
    (etaf-resize-test--tick)
    (setf (plist-get (plist-get ebox-resize-benchmark--run :current) :requested-at)
          (- (float-time) 30))
    (should (eq :real-result
                (ebox-resize-benchmark--publication (lambda (&rest _) :real-result)
                                                    buffer width 24)))
    (should-not ebox-resize-benchmark--run)
    (should-not (plist-get ebox-resize-benchmark--last-result :valid))
    (should (> (plist-get (car (plist-get ebox-resize-benchmark--last-result :samples))
                          :request-to-published-ms) 20000))))

(ert-deftest etaf-resize-code-evidence-includes-every-reload-and-the-driver ()
  "Explicitly loaded modules need evidence even without a sentinel function."
  (let* ((directory (make-temp-file "etaf-resize-code-" t))
         (source (expand-file-name "etaf-resize-evidence-fixture.el" directory))
         (compiled (concat source "c"))
         (features (copy-sequence features)))
    (unwind-protect
        (progn
          (with-temp-file source
            (insert ";;; -*- lexical-binding: t; -*-\n"
                    "(provide 'etaf-resize-evidence-fixture)\n"))
          (should (byte-compile-file source))
          (let* ((code (ebox-resize-benchmark--code (list compiled)))
                 (reload (car (plist-get code :reload-files)))
                 (driver (cl-find 'ebox-resize-benchmark-start (plist-get code :functions)
                                  :key (lambda (entry) (plist-get entry :function)))))
            (should (featurep 'etaf-resize-evidence-fixture))
            (should (equal (plist-get reload :file) (file-truename compiled)))
            (should (plist-get reload :loaded))
            (should (equal (plist-get reload :sha256)
                           (ebox-resize-benchmark--hash-file compiled)))
            (should (equal (plist-get reload :source-sha256)
                           (ebox-resize-benchmark--hash-file source)))
            (should (plist-get driver :origin-sha256))))
      (delete-directory directory t))))

(ert-deftest etaf-resize-start-waits-for-existing-gc-lease-without-measuring-it ()
  "A preceding render must settle before recording the benchmark baseline."
  (etaf-resize-test--with-run
    (let ((ebox--deferred-render-gc-state '(:busy t))
          (gc-cons-threshold (* 128 1024 1024))
          (gc-cons-percentage .1))
      (ebox-resize-benchmark-start buffer 400 800 :delay 10 :timeout 20 :output output)
      (etaf-resize-test--tick)
      (should-not (plist-get ebox-resize-benchmark--run :samples))
      (should (= width 600))
      (should (eq :prior-render
                  (ebox-resize-benchmark--publication
                   (lambda (&rest _) :prior-render) buffer width 24)))
      (setq ebox--deferred-render-gc-state nil gc-cons-threshold (* 16 1024 1024))
      (etaf-resize-test--tick)
      (should (plist-get ebox-resize-benchmark--run :armed))
      (should (= width 400))
      (should (equal (plist-get ebox-resize-benchmark--run :gc-policy)
                     (list gc-cons-threshold gc-cons-percentage))))))

(ert-deftest etaf-resize-startup-lease-wait-is-bounded ()
  "A stuck preceding render fails without issuing a benchmark resize."
  (etaf-resize-test--with-run
    (let ((ebox--deferred-render-gc-state '(:busy t)))
      (ebox-resize-benchmark-start buffer 400 800 :delay 10 :timeout 20 :output output)
      (setf (plist-get ebox-resize-benchmark--run :ready-deadline) (1- (float-time)))
      (should-error (etaf-resize-test--tick))
      (should (= width 600))
      (should-not ebox-resize-benchmark--run)
      (should-not (plist-get ebox-resize-benchmark--last-result :valid))
      (should (= 0 (plist-get ebox-resize-benchmark--last-result :requested-count))))))

(ert-deftest etaf-resize-phase-selection-rejects-the-measurement-machinery ()
  "Instrumentation cannot recursively time its own clock and bookkeeping."
  (etaf-resize-test--with-run
    (dolist (phase '(float-time gethash ebox-resize-benchmark--payload
                               ebox-rerender-buffer-with-context))
      (should-error (ebox-resize-benchmark-start buffer 400 800
                                                :phases (list phase) :output output)))
    (should-not ebox-resize-benchmark--run)
    (should-not (file-exists-p output))))

(provide 'etaf-resize-benchmark-tests)
;;; etaf-resize-benchmark-tests.el ends here
