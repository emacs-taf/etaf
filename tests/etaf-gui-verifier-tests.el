;;; etaf-gui-verifier-tests.el --- Generic GUI scenario engine tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'emacs-gui-verifier)

(ert-deftest etaf-gui-verifier-measures-success-and-original-failure ()
  "Each callback retains its own timing, result, and error condition."
  (let* ((scenario (etaf-gui-verifier-scenario-create :name "measurement"))
         (context (etaf-gui-verifier--context-create :scenario scenario))
         (result (list 'exact-result))
         (error-data (list "original failure" result))
         (wall-times '(1.0 1.002 10.0 10.03))
         (cpu-times '((1000 . 1000) (1004 . 1000)
                      (2000 . 1000) (2010 . 1000)))
         (gcs-done 5) (gc-elapsed 0.1)
         (calls 0))
    (cl-letf (((symbol-function 'float-time)
               (lambda (&optional _time) (pop wall-times)))
              ((symbol-function 'current-cpu-time)
               (lambda () (pop cpu-times))))
      (should
       (eq result
           (etaf-gui-verifier-measure-action
            context
            (etaf-gui-verifier-action-create
             :id "success"
             :execute (lambda (current)
                        (should (eq current context))
                        (cl-incf calls)
                        result)))))
      (should
       (equal (cons 'error error-data)
              (should-error
               (etaf-gui-verifier-measure-action
                context
                (etaf-gui-verifier-action-create
                 :id "failure"
                 :execute (lambda (_current)
                            (cl-incf calls)
                            (cl-incf gcs-done 2)
                            (cl-incf gc-elapsed 0.003)
                            (signal 'error error-data))))))))
    (should (= calls 2))
    (let* ((measurements (etaf-gui-verifier-context-measurements context))
           (failed (car measurements))
           (succeeded (cadr measurements))
           (adapter (etaf-gui-verifier--adapter-data context)))
      (should (= (length measurements) 2))
      (should (equal (alist-get 'status succeeded) "success"))
      (should (equal (alist-get 'status failed) "error"))
      (should (equal (alist-get 'action_id failed) "failure"))
      (should-not (alist-get 'valid failed))
      (should (< (abs (- (alist-get 'wall_ms failed) 30.0)) 0.001))
      (should (< (abs (- (alist-get 'wall_ms succeeded) 2.0)) 0.001))
      (should (< (abs (- (alist-get 'cpu_ms failed) 10.0)) 0.001))
      (should (= (alist-get 'gc_count failed) 2))
      (should (< (abs (- (alist-get 'gc_ms failed) 3.0)) 0.001))
      (should (= (alist-get 'duration_ms adapter)
                 (alist-get 'wall_ms failed)))
      (should (eq (alist-get 'last_measurement adapter) failed))
      (should-not (assq 'measurements adapter)))))

(ert-deftest etaf-gui-verifier-labels-callback-context-without-changing-it ()
  "Foreground, background, and unknown callbacks keep their execution context."
  (let* ((focus t) (calls 0)
         (inhibit-quit t) (inhibit-redisplay t)
         (threshold gc-cons-threshold) (percentage gc-cons-percentage)
         (context
          (etaf-gui-verifier--context-create
           :target-buffer (window-buffer (selected-window)))))
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) t))
              ((symbol-function 'frame-focus-state)
               (lambda (&optional _frame) focus))
              ((symbol-function 'redisplay)
               (lambda (&rest _arguments) (ert-fail "Forced redisplay")))
              ((symbol-function 'sit-for)
               (lambda (&rest _arguments) (ert-fail "Waited for display")))
              ((symbol-function 'garbage-collect)
               (lambda () (ert-fail "Forced GC"))))
      (dolist (state '((t "foreground") (nil "background") (unknown "unknown")))
        (setq focus (car state))
        (should
         (eq 'exact-result
             (etaf-gui-verifier-measure-action
              context
              (etaf-gui-verifier-action-create
               :id "context"
               :execute (lambda (_context)
                          (cl-incf calls)
                          (should inhibit-quit)
                          (should inhibit-redisplay)
                          (should (= gc-cons-threshold threshold))
                          (should (= gc-cons-percentage percentage))
                          'exact-result))
              (eq focus t))))
        (let* ((measurement
                (car (etaf-gui-verifier-context-measurements context)))
               (before (alist-get 'before measurement)))
          (should (equal (alist-get 'foreground measurement) (cadr state)))
          (should (equal (alist-get 'status measurement) "success"))
          (should (alist-get 'valid measurement))
          (should (alist-get 'inhibit_quit before))
          (should (alist-get 'inhibit_redisplay before))
          (should (eq (alist-get 'noninteractive before) noninteractive))
          (should (stringp (json-serialize measurement))))))
    (should (= calls 3))))

(ert-deftest etaf-gui-verifier-unselected-target-runs-with-invalid-timing ()
  "An unchanged unselected target permits the callback but invalidates timing."
  (let* ((target (generate-new-buffer " *etaf-gui-unselected-target*"))
         (context (etaf-gui-verifier--context-create :target-buffer target))
         (result (list 'exact-result))
         (calls 0))
    (unwind-protect
        (cl-letf (((symbol-function 'display-graphic-p)
                   (lambda (&optional _frame) t))
                  ((symbol-function 'frame-focus-state)
                   (lambda (&optional _frame) nil)))
          (should
           (eq result
               (etaf-gui-verifier-measure-action
                context
                (etaf-gui-verifier-action-create
                 :id "unselected-target"
                 :execute (lambda (_context)
                            (cl-incf calls)
                            result)))))
          (should (= calls 1))
          (let ((measurement
                 (car (etaf-gui-verifier-context-measurements context))))
            (should (equal (alist-get 'status measurement) "success"))
            (should (equal (alist-get 'foreground measurement) "background"))
            (should (equal (alist-get 'before measurement)
                           (alist-get 'after measurement)))
            (should-not (alist-get 'target_selected
                                   (alist-get 'before measurement)))
            (should-not (alist-get 'valid measurement))
            (should (numberp (alist-get 'wall_ms measurement)))))
      (kill-buffer target))))

(ert-deftest etaf-gui-verifier-foreground-rejection-does-not-execute-or-focus ()
  "Foreground requirements reject absent focus or targets before execution."
  (let ((focus t) (graphic t) (calls 0)
        (context (etaf-gui-verifier--context-create)))
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) graphic))
              ((symbol-function 'frame-focus-state)
               (lambda (&optional _frame) focus))
              ((symbol-function 'raise-frame)
               (lambda (&rest _arguments) (ert-fail "Raised frame")))
              ((symbol-function 'select-frame-set-input-focus)
               (lambda (&rest _arguments) (ert-fail "Changed focus")))
              ((symbol-function 'x-focus-frame)
               (lambda (&rest _arguments) (ert-fail "Focused frame"))))
      (dolist (state '((nil t t) (unknown t t) (t nil t) (t t nil)))
        (setq focus (nth 0 state) graphic (nth 1 state))
        (setf (etaf-gui-verifier-context-target-buffer context)
              (and (nth 2 state) (window-buffer (selected-window))))
        (should-error
         (etaf-gui-verifier-measure-action
          context
          (etaf-gui-verifier-action-create
           :id "foreground-only" :execute (lambda (_context) (cl-incf calls)))
          t))
        (let ((measurement
               (car (etaf-gui-verifier-context-measurements context))))
          (should (equal (alist-get 'status measurement) "rejected"))
          (should-not (alist-get 'valid measurement))
          (should-not (alist-get 'wall_ms measurement)))))
    (should (zerop calls))))

(ert-deftest etaf-gui-verifier-retains-valid-timing-when-frame-title-changes ()
  "A GC count in the frame title must not invalidate a stable target."
  (let* ((gcs-done 713)
         (calls 0)
         (result (list 'exact-result))
         (frame-parameter-function (symbol-function 'frame-parameter))
         (context
          (etaf-gui-verifier--context-create
           :target-buffer (window-buffer (selected-window)))))
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) t))
              ((symbol-function 'frame-focus-state)
               (lambda (&optional _frame) t))
              ((symbol-function 'frame-parameter)
               (lambda (frame parameter)
                 (if (eq parameter 'name) (format "GC%d" gcs-done)
                   (funcall frame-parameter-function frame parameter)))))
      (should
       (eq result
           (etaf-gui-verifier-measure-action
            context
            (etaf-gui-verifier-action-create
             :id "title-update"
             :execute (lambda (_context)
                        (cl-incf calls)
                        (cl-incf gcs-done)
                        result))
            t))))
    (should (= calls 1))
    (let ((measurement
           (car (etaf-gui-verifier-context-measurements context))))
      (should (equal (alist-get 'status measurement) "success"))
      (should (equal (alist-get 'foreground measurement) "foreground"))
      (should (alist-get 'valid measurement))
      (should (= (alist-get 'gc_count measurement) 1))
      (should (equal (alist-get 'frame_name (alist-get 'before measurement))
                     "GC713"))
      (should (equal (alist-get 'frame_name (alist-get 'after measurement))
                     "GC714")))))

(ert-deftest etaf-gui-verifier-invalidates-replaced-selected-target ()
  "A different live selected buffer remains an identity change."
  (let ((target (generate-new-buffer " *etaf-gui-original-target*"))
        (replacement (generate-new-buffer " *etaf-gui-replacement-target*"))
        (calls 0))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer target)
          (let ((context (etaf-gui-verifier--context-create :target-buffer target)))
            (cl-letf (((symbol-function 'display-graphic-p)
                       (lambda (&optional _frame) t))
                      ((symbol-function 'frame-focus-state)
                       (lambda (&optional _frame) t)))
              (should-error
               (etaf-gui-verifier-measure-action
                context
                (etaf-gui-verifier-action-create
                 :id "replace-selected-target"
                 :execute (lambda (_context)
                            (cl-incf calls)
                            (setf (etaf-gui-verifier-context-target-buffer context)
                                  replacement)
                            (set-window-buffer (selected-window) replacement)))
                t)))
            (should (= calls 1))
            (let ((measurement
                   (car (etaf-gui-verifier-context-measurements context))))
              (should (alist-get 'target_selected
                                 (alist-get 'before measurement)))
              (should (alist-get 'target_selected
                                 (alist-get 'after measurement)))
              (should (equal (alist-get 'status measurement) "invalid"))
              (should-not (alist-get 'valid measurement)))))
      (kill-buffer target)
      (kill-buffer replacement))))

(ert-deftest etaf-gui-verifier-invalidates-changed-foreground-environment ()
  "Changed focus, target, font, or dimensions invalidate strict timing."
  (let ((focus t) (width 800) (font "original-font") (calls 0)
        (frame-parameter-function (symbol-function 'frame-parameter))
        (context (etaf-gui-verifier--context-create)))
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) t))
              ((symbol-function 'frame-focus-state)
               (lambda (&optional _frame) focus))
              ((symbol-function 'frame-pixel-width)
               (lambda (&optional _frame) width))
              ((symbol-function 'frame-parameter)
               (lambda (frame parameter)
                 (if (eq parameter 'font) font
                   (funcall frame-parameter-function frame parameter)))))
      (dolist (change '(focus target font dimensions))
        (setq focus t width 800 font "original-font")
        (setf (etaf-gui-verifier-context-target-buffer context)
              (window-buffer (selected-window)))
        (should-error
         (etaf-gui-verifier-measure-action
          context
          (etaf-gui-verifier-action-create
           :id (symbol-name change)
           :execute
           (lambda (_context)
             (cl-incf calls)
             (pcase change
               ('focus (setq focus nil))
               ('target
                (setf (etaf-gui-verifier-context-target-buffer context) nil))
               ('font (setq font "changed-font"))
               ('dimensions (setq width 900)))))
          t))
        (let ((measurement
               (car (etaf-gui-verifier-context-measurements context))))
          (should (equal (alist-get 'status measurement) "invalid"))
          (should (equal (alist-get 'foreground measurement) "changed"))
          (should-not (alist-get 'valid measurement))
          (should (numberp (alist-get 'wall_ms measurement))))))
    (should (= calls 4))))

(ert-deftest etaf-gui-verifier-preserves-quit-despite-focus-change ()
  "A quit keeps its exact data even if strict environment checks also fail."
  (let* ((focus t)
         (quit-data (list 'original-quit))
         (context
          (etaf-gui-verifier--context-create
           :target-buffer (window-buffer (selected-window)))))
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) t))
              ((symbol-function 'frame-focus-state)
               (lambda (&optional _frame) focus)))
      (should
       (equal (cons 'quit quit-data)
              (condition-case condition
                  (etaf-gui-verifier-measure-action
                   context
                   (etaf-gui-verifier-action-create
                    :id "quit"
                    :execute (lambda (_context)
                               (setq focus nil)
                               (signal 'quit quit-data)))
                   t)
                (quit condition)))))
    (let ((measurement
           (car (etaf-gui-verifier-context-measurements context))))
      (should (equal (alist-get 'status measurement) "quit"))
      (should (equal (alist-get 'foreground measurement) "changed"))
      (should-not (alist-get 'valid measurement))
      (should (numberp (alist-get 'wall_ms measurement))))))

(ert-deftest etaf-gui-verifier-retains-timing-despite-closing-snapshot-failure ()
  "Snapshot errors and quits preserve action failures and retain fresh timing."
  (dolist (action-outcome '(error quit success))
    (dolist (snapshot-outcome '(error quit))
      (let* ((context
              (etaf-gui-verifier--context-create
               :target-buffer (window-buffer (selected-window))
               :last-duration-ms 999.0))
             (before (etaf-gui-verifier--measurement-state context))
             (result (list 'exact-result))
             (action-data (list "original-action-failure" result))
             (snapshot-data (list "snapshot-interrupted" result))
             (wall-times '(1.0 1.025))
             (calls 0) (snapshots 0) observed-condition returned)
        (cl-letf (((symbol-function 'float-time)
                   (lambda (&optional _time) (pop wall-times)))
                  ((symbol-function 'etaf-gui-verifier--measurement-state)
                   (lambda (_context)
                     (if (= (cl-incf snapshots) 1) before
                       (signal snapshot-outcome snapshot-data)))))
          (setq returned
                (condition-case condition
                    (etaf-gui-verifier-measure-action
                     context
                     (etaf-gui-verifier-action-create
                      :id "snapshot-failure"
                      :execute (lambda (_context)
                                 (cl-incf calls)
                                 (if (eq action-outcome 'success) result
                                   (signal action-outcome action-data)))))
                  ((error quit)
                   (setq observed-condition condition)
                   nil))))
        (should (= calls 1))
        (should (= snapshots 2))
        (cond
         ((not (eq action-outcome 'success))
          (should (eq (car observed-condition) action-outcome))
          (should (eq (cdr observed-condition) action-data)))
         ((eq snapshot-outcome 'quit)
          (should (eq (car observed-condition) 'quit))
          (should (eq (cdr observed-condition) snapshot-data)))
         (t
          (should-not observed-condition)
          (should (eq returned result))))
        (let* ((measurements (etaf-gui-verifier-context-measurements context))
               (measurement (car measurements)))
          (should (= (length measurements) 1))
          (should-not (alist-get 'valid measurement))
          (should-not (alist-get 'after measurement))
          (should
           (equal (alist-get 'status measurement)
                  (symbol-name
                   (if (and (eq action-outcome 'success)
                            (eq snapshot-outcome 'quit))
                       'quit action-outcome))))
          (should (< (abs (- (alist-get 'wall_ms measurement) 25.0)) 0.001))
          (should (= (etaf-gui-verifier-context-last-duration-ms context)
                     (alist-get 'wall_ms measurement))))))))

(ert-deftest etaf-gui-verifier-measures-callback-without-settle-or-checkpoints ()
  "The action callback is timed separately from checkpoints and settling."
  (let ((context (etaf-gui-verifier--context-create))
        (clock 0.0) events)
    (cl-letf (((symbol-function 'float-time)
               (lambda (&optional _time) clock))
              ((symbol-function 'etaf-gui-verifier--checkpoint)
               (lambda (_context _id phase _screenshot &optional _extra)
                 (cl-incf clock 1.0)
                 (push phase events)))
              ((symbol-function 'etaf-gui-verifier--settle-action)
               (lambda (_context _action)
                 (cl-incf clock 2.0)
                 (push 'settle events))))
      (etaf-gui-verifier--run-action
       context
       (etaf-gui-verifier-action-create
        :id "callback-only"
        :execute (lambda (_context)
                   (cl-incf clock 0.025)
                   (push 'execute events)))))
    (should (< (abs (- (etaf-gui-verifier-context-last-duration-ms context)
                      25.0))
               0.001))
    (should (equal (nreverse events)
                   '("before-action" execute "after-action"
                     settle "after-redisplay")))
    (let ((measurement
           (car (etaf-gui-verifier-context-measurements context))))
      (should (equal (alist-get 'boundary measurement) "action.execute callback"))
      (should-not (alist-get 'presentation_measured measurement)))))

(ert-deftest etaf-gui-verifier-runs-and-settles-without-raising-frame ()
  "Actions and settled checkpoints must complete without raising Emacs."
  (let ((context (etaf-gui-verifier--context-create))
        (settle-checks 0)
        events)
    (cl-letf (((symbol-function 'raise-frame)
               (lambda (&rest _arguments)
                 (error "GUI verifier must preserve application focus")))
              ((symbol-function 'etaf-gui-verifier--checkpoint)
               (lambda (_context _action-id phase _screenshot &optional _extra)
                 (push phase events))))
      (etaf-gui-verifier--run-action
       context
       (etaf-gui-verifier-action-create
        :id "background-action" :settle-interval 0.001
        :execute
        (lambda (current)
          (etaf-gui-verifier-context-put current 'executed t)
          (push 'execute events))
        :settled-p
        (lambda (current)
          (should (etaf-gui-verifier-context-get current 'executed))
          (cl-incf settle-checks)
          (push 'settle events)
          t)
        :assertions
        (lambda (_current)
          (push 'assertions events)
          (list (etaf-gui-verifier-assert "action-settled" t))))))
    (should (= 1 (etaf-gui-verifier-context-action-count context)))
    (should (= 2 settle-checks))
    (should
     (equal '("before-action" execute "after-action" settle settle
              assertions "after-redisplay")
            (nreverse events)))))

(ert-deftest etaf-gui-verifier-composes-generic-scenario-actions ()
  "The engine should own ordering while adapters own actions and assertions."
  (let ((buffer (generate-new-buffer " *etaf-gui-verifier-test*"))
        events checkpoints finished (settle-checks 0))
    (unwind-protect
        (cl-letf
            (((symbol-function 'emacs-dynamic-ui-verification-start)
              (lambda (_directory run-id _claim phases)
                (push (list 'start run-id phases) events)))
             ((symbol-function 'emacs-dynamic-ui-verification-checkpoint)
              (lambda (action phase adapter assertions screenshot)
                (push (list action phase adapter assertions screenshot)
                      checkpoints)))
             ((symbol-function 'emacs-dynamic-ui-verification-finish)
              (lambda (completed adapter)
                (setq finished (list completed adapter)))))
          (let* ((scenario
                  (etaf-gui-verifier-scenario-create
                   :name "generic"
                   :claim "generic claim"
                   :initialize
                   (lambda (context)
                     (etaf-gui-verifier-context-select-buffer context buffer))
                   :invariants
                   (lambda (context)
                     (list
                      (etaf-gui-verifier-assert
                       "buffer-live"
                       (buffer-live-p
                        (etaf-gui-verifier-context-target-buffer context)))))
                   :adapter
                   (lambda (context)
                     (list
                      (cons 'size
                            (with-current-buffer
                                (etaf-gui-verifier-context-target-buffer context)
                              (buffer-size)))))
                   :actions
                   (list
                    (etaf-gui-verifier-action-create
                     :id "insert-a" :settle-interval 0.001
                     :execute
                     (lambda (context)
                       (with-current-buffer
                           (etaf-gui-verifier-context-target-buffer context)
                         (insert "A")))
                     :settled-p
                     (lambda (_context)
                       (>= (cl-incf settle-checks) 2))
                     :assertions
                     (lambda (context)
                       (list
                        (etaf-gui-verifier-assert
                         "one-character"
                         (= 1
                            (with-current-buffer
                                (etaf-gui-verifier-context-target-buffer context)
                              (buffer-size))))))
                     :screenshot t)
                    (etaf-gui-verifier-action-create
                     :id "insert-b"
                     :execute
                     (lambda (context)
                       (with-current-buffer
                           (etaf-gui-verifier-context-target-buffer context)
                         (insert "B")))
                     :settled-p (lambda (_context) t)))
                   :completion
                   (lambda (context)
                     (= 2 (etaf-gui-verifier-context-action-count context)))))
                 (context (etaf-gui-verifier-run scenario "/tmp/generic")))
            (should (= 2 (etaf-gui-verifier-context-action-count context)))
            (should (equal "AB" (with-current-buffer buffer (buffer-string))))
            (should (car finished))
            (should (= settle-checks 3))
            (should (= 6 (length checkpoints)))
            (should
             (equal
              '("before-action" "after-action" "after-redisplay"
                "before-action" "after-action" "after-redisplay")
              (mapcar #'cadr (nreverse checkpoints))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-gui-verifier-rejects-invalid-settle-contracts ()
  "Every action should have a bounded, non-busy settle contract."
  (let ((context (etaf-gui-verifier--context-create)))
    (dolist
        (action
         (list
          (etaf-gui-verifier-action-create :id "missing")
          (etaf-gui-verifier-action-create
           :id "timeout" :settled-p (lambda (_context) t)
           :settle-timeout 0)
          (etaf-gui-verifier-action-create
           :id "interval" :settled-p (lambda (_context) t)
           :settle-interval 0)))
      (should-error (etaf-gui-verifier--settle-action context action)))))

(ert-deftest etaf-gui-verifier-timeout-finishes-false-and-propagates ()
  "A settle timeout should finish incomplete and preserve its error."
  (let ((buffer (generate-new-buffer " *etaf-gui-timeout-test*"))
        finished)
    (unwind-protect
        (cl-letf
            (((symbol-function 'emacs-dynamic-ui-verification-start)
              (lambda (&rest _arguments) nil))
             ((symbol-function 'emacs-dynamic-ui-verification-checkpoint)
              (lambda (&rest _arguments) nil))
             ((symbol-function 'emacs-dynamic-ui-verification-finish)
              (lambda (completed adapter)
                (setq finished (list completed adapter)))))
          (let* ((scenario
                  (etaf-gui-verifier-scenario-create
                   :name "timeout"
                   :claim "timeout must fail closed"
                   :initialize
                   (lambda (context)
                     (etaf-gui-verifier-context-select-buffer context buffer))
                   :actions
                   (list
                    (etaf-gui-verifier-action-create
                     :id "never-settles"
                     :execute (lambda (_context) nil)
                     :settled-p (lambda (_context) nil)
                     :settle-timeout 0.003
                     :settle-interval 0.001))))
                 (error-data
                  (should-error
                   (etaf-gui-verifier-run scenario "/tmp/timeout"))))
            (should
             (string-match-p
              "did not settle" (error-message-string error-data)))
            (should finished)
            (should-not (car finished))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'etaf-gui-verifier-tests)
;;; etaf-gui-verifier-tests.el ends here
