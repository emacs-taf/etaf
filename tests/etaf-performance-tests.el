;;; etaf-performance-tests.el --- ETAF performance recorder tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'etaf)

(defmacro etaf-performance-test--isolated (&rest body)
  "Run BODY with isolated performance recorder state."
  (declare (indent 0) (debug t))
  `(unwind-protect
       (progn
         (etaf-performance-mode -1)
         (etaf-performance-clear)
         ,@body)
     (etaf-performance-mode -1)
     (etaf-performance-clear)))

(ert-deftest etaf-performance-records-success-result-and-error ()
  "Recording preserves successful results and original error data."
  (etaf-performance-test--isolated
    (etaf-performance-mode 1)
    (should (equal 42
                   (etaf-performance--call-operation
                    (lambda () 42) 'test-success 'test nil)))
    (let ((condition
           (condition-case error-data
               (etaf-performance--call-operation
                (lambda ()
                  (etaf-performance--call-stage
                   (lambda ()
                     (signal 'args-out-of-range '(source 1 2)))
                   'failing-stage 'test 'failure nil))
                'test-error 'test nil)
             (args-out-of-range error-data))))
      (should (equal condition '(args-out-of-range source 1 2))))
    (let ((records (etaf-performance-records)))
      (should (= 2 (length records)))
      (should (eq 'error
                  (etaf-performance-operation-status (car records))))
      (should (eq 'error
                  (etaf-performance-stage-status
                   (car (etaf-performance-operation-stages
                         (car records))))))
      (should (eq 'success
                  (etaf-performance-operation-status (cadr records)))))))

(ert-deftest etaf-performance-records-preserve-quit ()
  "Recording marks and re-signals a quit without changing its data."
  (etaf-performance-test--isolated
    (etaf-performance-mode 1)
    (let ((condition
           (condition-case quit-data
               (etaf-performance--call-operation
                (lambda () (signal 'quit '(performance-test)))
                'test-quit 'test nil)
             (quit quit-data))))
      (should (equal condition '(quit performance-test)))
      (should (eq 'quit
                  (etaf-performance-operation-status
                   (car (etaf-performance-records))))))))

(ert-deftest etaf-performance-public-operation-wrapper-is-generic ()
  "The public operation API records arbitrary code and preserves its result."
  (etaf-performance-test--isolated
    (etaf-performance-mode 1)
    (should
     (equal '(generic result)
            (etaf-performance-with-operation ('command "generic fixture")
              '(generic result))))
    (let ((operation (car (etaf-performance-records))))
      (should (eq 'command
                  (etaf-performance-operation-kind operation)))
      (should (equal "generic fixture"
                     (etaf-performance-operation-label operation))))))

(ert-deftest etaf-performance-stage-registration-is-load-order-safe ()
  "Third-party stages may register before their function is defined."
  (etaf-performance-test--isolated
    (let ((function (make-symbol "etaf-performance-generic-stage")))
      (unwind-protect
          (progn
            (etaf-performance-register-stage function 'extension 'prepare)
            (etaf-performance-mode 1)
            (should-not (assq function etaf-performance--installed-advices))
            (fset function (lambda () 'extension-result))
            (etaf-performance--install-loaded-advices)
            (should (assq function etaf-performance--installed-advices))
            (should (eq 'extension-result
                        (etaf-performance-call-operation
                         'extension "registered stage"
                         (lambda () (funcall function)))))
            (let ((stage
                   (car (etaf-performance-operation-stages
                         (car (etaf-performance-records))))))
              (should (eq function
                          (etaf-performance-stage-function stage)))
              (should (eq 'extension
                          (etaf-performance-stage-category stage)))))
        (etaf-performance-unregister-stage function)
        (when (fboundp function)
          (fmakunbound function))))))

(ert-deftest etaf-performance-default-registry-keeps-per-node-probes-opt-in ()
  "High-frequency per-node probes must not distort default operation timing."
  (dolist (function '(ebox-incremental--candidate-local-changed-keys
                      ebox-tree-node-local-source-signature))
    (should-not (assq function etaf-performance--stage-functions))))

(ert-deftest etaf-performance-stage-advice-survives-package-reload ()
  "Reattach the tracked stage closure after its function is redefined."
  (etaf-performance-test--isolated
    (let ((function (make-symbol "etaf-performance-reloaded-stage")))
      (unwind-protect
          (progn
            (fset function (lambda () 'first))
            (etaf-performance-register-stage function 'extension 'reload)
            (etaf-performance-mode 1)
            (let ((entry (assq function
                               etaf-performance--installed-advices)))
              (should (advice-member-p (cdr entry) function))
              (fset function (lambda () 'second))
              (should-not (advice-member-p (cdr entry) function))
              (etaf-performance--install-loaded-advices)
              (should (advice-member-p (cdr entry) function)))
            (etaf-performance-clear)
            (should (eq 'second
                        (etaf-performance-call-operation
                         'reload "package reload"
                         (lambda () (funcall function)))))
            (should (= 1
                       (length
                        (etaf-performance-operation-stages
                         (car (etaf-performance-records)))))))
        (etaf-performance-unregister-stage function)
        (when (fboundp function) (fmakunbound function))))))

(ert-deftest etaf-performance-stage-registration-rejects-operation-collision ()
  "A detail stage must not replace a public operation boundary advice."
  (etaf-performance-test--isolated
    (etaf-performance-mode 1)
    (let* ((function 'etaf-data-load)
           (entry (assq function etaf-performance--installed-advices)))
      (should entry)
      (should-error
       (etaf-performance-register-stage function 'data 'nested-load))
      (should-error (etaf-performance-unregister-stage function))
      (should (eq entry (assq function etaf-performance--installed-advices)))
      (should (advice-member-p (cdr entry) function)))))

(ert-deftest etaf-performance-public-data-resource-and-viewport-boundaries ()
  "Public cross-package operations are boundaries, never duplicate stages."
  (etaf-performance-test--isolated
    (let ((functions '(etaf-data-load etaf-data-source-load-page
                       etaf-data-mutate etaf-resource-load
                       ebox-surface-update-buffer-viewport
                       ebox-rerender-buffer-with-context)))
      (dolist (function functions)
        (should (assq function etaf-performance--operation-functions))
        (should-not (assq function etaf-performance--stage-functions)))
      (etaf-performance-mode 1)
      (dolist (function functions)
        (when (fboundp function)
          (should (assq function etaf-performance--installed-advices))))
      (let* ((source (etaf-data-memory-source
                      '((:id 1 :name "one")) :id-key :id))
             (controller (etaf-data-controller source))
             (resource (etaf-resource (lambda () 'loaded) :immediate nil)))
        (unwind-protect
            (progn
              (etaf-data-load controller)
              (etaf-data-source-load-page source nil 1 20)
              (etaf-data-mutate controller 'insert '(:id 2 :name "two"))
              (etaf-resource-load resource)
              (let ((kinds
                     (mapcar #'etaf-performance-operation-kind
                             (etaf-performance-records))))
                (should (memq 'data-load kinds))
                (should (memq 'data-prepare kinds))
                (should (memq 'data-mutate kinds))
                (should (memq 'resource-load kinds))))
          (etaf-data-stop controller)
          (etaf-resource-dispose resource))))))

(ert-deftest etaf-performance-records-nested-stage-exclusive-time ()
  "Nested stages retain depth and subtract child inclusive time."
  (etaf-performance-test--isolated
    (etaf-performance-mode 1)
    (etaf-performance--call-operation
     (lambda ()
       (etaf-performance--call-stage
        (lambda ()
          (sleep-for 0.002)
          (etaf-performance--call-stage
           (lambda () (sleep-for 0.002) 'inner-result)
           'inner-stage 'inner 'work nil)
          (sleep-for 0.002))
        'outer-stage 'outer 'work nil))
     'nested-operation 'test nil)
    (let* ((operation (car (etaf-performance-records)))
           (stages (etaf-performance-operation-stages operation))
           (outer (car stages))
           (inner (cadr stages)))
      (should (= 2 (length stages)))
      (should (= 0 (etaf-performance-stage-depth outer)))
      (should (= 1 (etaf-performance-stage-depth inner)))
      (should (>= (etaf-performance-stage-inclusive outer)
                  (etaf-performance-stage-inclusive inner)))
      (should (< (abs (- (etaf-performance-stage-exclusive outer)
                         (- (etaf-performance-stage-inclusive outer)
                            (etaf-performance-stage-inclusive inner))))
                 0.001)))))

(ert-deftest etaf-performance-records-are-bounded ()
  "Only the configured number of newest operations is retained."
  (etaf-performance-test--isolated
    (let ((etaf-performance-max-records 2))
      (etaf-performance-mode 1)
      (dotimes (index 4)
        (etaf-performance--call-operation
         (lambda () index) 'bounded 'test nil))
      (let* ((records (etaf-performance-records))
             (ids (mapcar #'etaf-performance-operation-id records)))
        (should (= 2 (length records)))
        (should (= 1 (- (car ids) (cadr ids))))))))

(ert-deftest etaf-performance-clear-keeps-correlation-ids-monotonic ()
  "Clearing history inside an operation must not reuse its ID."
  (etaf-performance-test--isolated
    (etaf-performance-mode 1)
    (etaf-performance-call-operation
     'outer "clear inside" (lambda () (etaf-performance-clear)))
    (etaf-performance-call-operation 'next "after clear" #'ignore)
    (let ((ids (mapcar #'etaf-performance-operation-id
                       (etaf-performance-records))))
      (should (= 2 (length (delete-dups (copy-sequence ids)))))
      (should (= 1 (- (car ids) (cadr ids)))))))

(ert-deftest etaf-performance-summaries-aggregate-off-the-hot-path ()
  "Summarize operation percentiles and non-overlapping category self time."
  (etaf-performance-test--isolated
    (etaf-performance-mode 1)
    (dolist (delay '(0.001 0.002 0.003))
      (etaf-performance-call-operation
       'summary "generic"
       (lambda ()
         (etaf-performance--call-stage
          (lambda () (sleep-for delay)) 'summary-stage 'application 'work nil))))
    (let* ((records (etaf-performance-records))
           (summary (car (etaf-performance-summary records)))
           (stage-summary
            (car (etaf-performance-operation-stage-summary (car records)))))
      (should (= 3 (plist-get summary :count)))
      (should (<= (plist-get summary :min-ms)
                  (plist-get summary :p50-ms)
                  (plist-get summary :p95-ms)
                  (plist-get summary :max-ms)))
      (should (eq 'application (plist-get stage-summary :category)))
      (should (= 1 (plist-get stage-summary :count)))
      (should (<= (plist-get stage-summary :exclusive-ms)
                  (plist-get stage-summary :inclusive-ms))))))

(ert-deftest etaf-performance-records-real-event-and-runtime-stages ()
  "A real mounted event creates an event operation and runtime stages."
  (etaf-performance-test--isolated
    (let ((buffer-name " *etaf-performance-event-test*")
          (calls 0)
          runtime-holder)
      (unwind-protect
          (progn
            (etaf-performance-mode 1)
            (etaf-mount
             buffer-name
             (etaf-view
              (text :ref 'button
                    :on-press (lambda ()
                                (cl-incf calls)
                                (etaf-runtime-flush runtime-holder))
                    "Press")))
            (etaf-performance-clear)
            (let ((runtime (etaf-runtime-for-buffer buffer-name)))
              (setq runtime-holder runtime)
              (etaf-dispatch-event runtime 'button 'press)
              (should (= calls 1))
              (let ((operation
                     (cl-find 'event (etaf-performance-records)
                              :key #'etaf-performance-operation-kind)))
                (should (eq 'event
                            (etaf-performance-operation-kind operation)))
                (should (= (etaf-runtime-mount-epoch runtime)
                           (etaf-performance-operation-runtime-id operation)))
                (should (equal buffer-name
                               (etaf-performance-operation-buffer-name
                                operation)))
                (should (numberp
                         (etaf-performance-operation-generation-before
                          operation)))
                (should
                 (cl-some
                  (lambda (record)
                    (cl-some
                     (lambda (stage)
                       (memq (etaf-performance-stage-category stage)
                             '(runtime reactive ebox tp)))
                     (etaf-performance-operation-stages record)))
                  (etaf-performance-records))))))
        (when-let ((runtime (etaf-runtime-for-buffer buffer-name)))
          (etaf-unmount runtime))
        (when-let ((buffer (get-buffer buffer-name)))
          (kill-buffer buffer))))))

(ert-deftest etaf-performance-panel-has-operation-and-stage-entries ()
  "The tabulated panel expands one operation into its stage rows."
  (etaf-performance-test--isolated
    (etaf-performance-mode 1)
    (etaf-performance--call-operation
     (lambda ()
       (etaf-performance--call-stage
        (lambda () 'ok) 'panel-stage 'panel 'detail nil))
     'panel-operation 'test nil)
    (let ((entries (etaf-performance--tabulated-entries)))
      (should (= 2 (length entries)))
      (should (equal "operation" (aref (cadr (car entries)) 4)))
      (should (equal "stage" (aref (cadr (cadr entries)) 2))))
    (with-temp-buffer
      (etaf-performance-panel-mode)
      (tabulated-list-print t)
      (should (string-match-p "panel-operation" (buffer-string)))
      (should (string-match-p "panel-stage" (buffer-string))))))

(ert-deftest etaf-performance-report-is-portable-and-copyable ()
  "The shareable report contains environment, operation, and stage data."
  (etaf-performance-test--isolated
    (etaf-performance-mode 1)
    (etaf-performance-call-operation
     'report "copy fixture"
     (lambda ()
       (etaf-performance--call-stage
        (lambda () 'ok) 'report-stage 'fixture 'work nil)))
    (let* ((data (etaf-performance-report-data))
           (operations (plist-get data :operations))
           (operation (car operations))
           (stage (car (plist-get operation :stages)))
           (kill-ring nil)
           (kill-ring-yank-pointer nil)
           (report (etaf-performance-copy-report)))
      (should (= etaf-performance-report-format-version
                 (plist-get data :format-version)))
      (should (equal emacs-version
                     (plist-get (plist-get data :environment)
                                :emacs-version)))
      (should (equal "copy fixture" (plist-get operation :label)))
      (should (eq 'report-stage (plist-get stage :function)))
      (should (equal report (current-kill 0 t)))
      (should (string-match-p "ETAF performance report" report)))))

(ert-deftest etaf-performance-environment-normalizes-darwin-power-state ()
  "Reports distinguish AC, battery low-power, and unknown power states."
  (should
   (equal
    '(:source battery :low-power-mode on)
    (etaf-performance--parse-darwin-power-state
     "Now drawing from 'Battery Power'\n"
     "Battery Power:\n lowpowermode 1\nAC Power:\n lowpowermode 0\n")))
  (should
   (equal
    '(:source ac :low-power-mode off)
    (etaf-performance--parse-darwin-power-state
     "Now drawing from 'AC Power'\n"
     "Battery Power:\n lowpowermode 1\nAC Power:\n lowpowermode 0\n")))
  (should
   (equal
    '(:source unknown :low-power-mode unknown)
    (etaf-performance--parse-darwin-power-state "" ""))))

(ert-deftest etaf-performance-panel-exposes-power-and-load-context ()
  "The visible panel explains system-wide latency shifts."
  (let ((line
         (etaf-performance--panel-environment-line
          '(:emacs-version "31.1"
            :power-state (:source battery :low-power-mode on)
            :load-average (2.5 2.0 1.5)))))
    (should (string-match-p "Emacs 31.1" line))
    (should (string-match-p "power battery/low:on" line))
    (should (string-match-p "load 2.50" line))))

(ert-deftest etaf-performance-export-writes-readable-report ()
  "The interactive export payload is a readable plain-data report."
  (etaf-performance-test--isolated
    (etaf-performance-mode 1)
    (etaf-performance-call-operation 'export "file fixture" #'ignore)
    (let ((file (concat (make-temp-name
                         (expand-file-name "etaf-performance-test-"
                                           temporary-file-directory))
                        ".eld")))
      (unwind-protect
          (progn
            (should (equal file (etaf-performance-export file)))
            (with-temp-buffer
              (insert-file-contents file)
              (should (string-match-p "ETAF performance report"
                                      (buffer-string)))
              (should (string-match-p "file fixture" (buffer-string)))))
        (when (file-exists-p file)
          (delete-file file))))))

(ert-deftest etaf-performance-captures-public-ebox-report-metadata ()
  "Attach compact public Ebox report facts to the active operation."
  (etaf-performance-test--isolated
    (etaf-performance-mode 1)
    (etaf-performance--call-operation
     (lambda ()
       (etaf-performance--call-stage
        (lambda ()
          '(:strategy mixed-owner-reflow
            :projection-kind mixed-owner-reflow
            :dirty-count 8 :owner-ids (1 2 3) :patch-count 3
            :tp-scope-count 3 :tp-text-operations 12
            :tp-property-operations 111 :tp-full-root nil
            :tp-scope-fallback nil))
        'ebox-commit 'ebox 'commit nil))
     'report-operation 'test nil)
    (let* ((operation (car (etaf-performance-records)))
           (report (plist-get
                    (etaf-performance-operation-metadata operation) :ebox)))
      (should (eq 'mixed-owner-reflow (plist-get report :strategy)))
      (should (= 3 (plist-get report :owner-count)))
      (should (= 111 (plist-get report :tp-property-operations)))
      (should (string-match-p "mixed-owner-reflow"
                              (etaf-performance--format-report operation))))))

(ert-deftest etaf-performance-mode-uninstalls-all-advices ()
  "Disabling recording removes operation, stage, and after-load hooks."
  (etaf-performance-test--isolated
    (etaf-performance-mode 1)
    (let ((installed (copy-sequence etaf-performance--installed-advices)))
      (should installed)
      (dolist (entry installed)
        (should (advice-member-p (cdr entry) (car entry))))
      (etaf-performance-mode -1)
      (should-not etaf-performance--installed-advices)
      (should-not (memq #'etaf-performance--install-loaded-advices
                        after-load-functions))
      (dolist (entry installed)
        (should-not (advice-member-p (cdr entry) (car entry)))))))

(provide 'etaf-performance-tests)

;;; etaf-performance-tests.el ends here
