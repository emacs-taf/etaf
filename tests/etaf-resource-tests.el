;;; etaf-resource-tests.el --- ETAF Resource tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'etaf-observer)
(require 'etaf-resource)

(ert-deftest etaf-resource-loads-synchronous-value ()
  "Expose successful loader output through the public Resource readers."
  (let ((resource (etaf-resource (lambda () "ready") :name 'success-test)))
    (unwind-protect
        (progn
          (should (eq 'success (etaf-resource-status resource)))
          (should (equal "ready" (etaf-resource-value resource)))
          (should-not (etaf-resource-error resource)))
      (etaf-resource-dispose resource))))

(ert-deftest etaf-resource-captures-loader-error-state ()
  "Capture synchronous loader failures without signaling them."
  (let ((resource (etaf-resource (lambda () (error "boom"))
                                 :name 'error-test)))
    (unwind-protect
        (progn
          (should (eq 'error (etaf-resource-status resource)))
          (should-not (etaf-resource-value resource))
          (should (eq 'error (car (etaf-resource-error resource))))
          (should (string-match-p "boom"
                                  (cadr (etaf-resource-error resource)))))
      (etaf-resource-dispose resource))))

(ert-deftest etaf-resource-reload-runs-cleanup-and-replaces-value ()
  "Run loader cleanup on reload and disposal."
  (let ((load-count 0)
        (cleanup-count 0)
        resource)
    (setq resource
          (etaf-resource
           (lambda ()
             (cl-incf load-count)
             (etaf-resource-result
              load-count
              :cleanup (lambda () (cl-incf cleanup-count))))
           :name 'reload-test))
    (unwind-protect
        (progn
          (should (= 1 (etaf-resource-value resource)))
          (should (= 0 cleanup-count))
          (etaf-resource-load resource)
          (should (= 2 (etaf-resource-value resource)))
          (should (= 1 cleanup-count))
          (should-not (etaf-resource-dispose resource))
          (should (= 2 cleanup-count))
          (should-error (etaf-resource-load resource)
                        :type 'etaf-resource-error))
      (when resource
        (etaf-resource-dispose resource)))))

(ert-deftest etaf-resource-parent-scope-disposes-resource-cleanup ()
  "Attach Resource cleanup to the active parent Scope."
  (let ((scope (etaf-effect-scope :detached t :name 'parent-test))
        resource
        cleanup-count)
    (setq cleanup-count 0)
    (setq resource
          (etaf-scope-run
           scope
           (lambda ()
             (etaf-resource
              (lambda ()
                (etaf-resource-result
                 "scoped"
                 :cleanup (lambda () (cl-incf cleanup-count))))
              :name 'scoped-test))))
    (should (equal "scoped" (etaf-resource-value resource)))
    (should-not (etaf-scope-stop scope))
    (should (= 1 cleanup-count))
    (should-error (etaf-resource-load resource)
                  :type 'etaf-resource-error)))

(ert-deftest etaf-error-boundary-run-handles-body-error ()
  "Convert an explicitly wrapped body error into a handler result."
  (let ((seen nil))
    (should
     (equal "handled"
            (etaf-error-boundary-run
             (lambda () (error "render failed"))
             (lambda (condition)
               (setq seen condition)
               "handled")
             :name 'boundary-test)))
    (should (eq 'error (car seen)))
    (should (string-match-p "render failed" (cadr seen)))))

(ert-deftest etaf-error-boundary-run-preserves-unhandled-errors ()
  "Do not swallow errors outside the wrapped body or inside the handler."
  (should-error
   (progn
     (etaf-error-boundary-run
      (lambda () "ok")
      (lambda (_condition) "unused"))
     (error "outside"))
   :type 'error)
  (should-error
   (etaf-error-boundary-run
    (lambda () (error "body"))
    (lambda (_condition) (error "handler")))
   :type 'error))

(ert-deftest etaf-resource-observes-only-loader-execution ()
  "Report Resource loads while preserving replacement cleanup semantics."
  (let* ((loads 0)
         (cleanups 0)
         reports
         resource
         (context
         (etaf--observer-context-create
          :sink (lambda (report) (push report reports))
          :operation-id 51
          :runtime-id 8
          :buffer-name nil
          :diagnostic #'ignore)))
    (unwind-protect
        (progn
          (etaf--observer-call-with-context
           context
           (lambda ()
             (setq resource
                   (etaf-resource
                    (lambda ()
                      (etaf-resource-result
                       (cl-incf loads)
                       :cleanup (lambda () (cl-incf cleanups))))))
             (etaf-resource-load resource)))
          (setq reports (nreverse reports))
          (should (equal '(resource resource)
                         (mapcar (lambda (report)
                                   (plist-get report :provider))
                                 reports)))
          (should (equal '(load load)
                         (mapcar (lambda (report)
                                   (plist-get report :stage))
                                 reports)))
          (should (equal '(success success)
                         (mapcar (lambda (report)
                                   (plist-get report :status))
                                 reports)))
          (should (= 2 (etaf-resource-value resource)))
          (should (= 1 cleanups))
          (etaf-resource-dispose resource)
          (should (= 2 cleanups)))
      (when resource
        (etaf-resource-dispose resource)))))

(ert-deftest etaf-resource-observed-error-keeps-captured-error-contract ()
  "Report loader failure without changing Resource error containment."
  (let* (reports resource
         (context
         (etaf--observer-context-create
          :sink (lambda (report) (push report reports))
          :operation-id 52
          :runtime-id 8
          :buffer-name nil
          :diagnostic #'ignore)))
    (unwind-protect
        (progn
          (etaf--observer-call-with-context
           context
           (lambda ()
             (setq resource (etaf-resource (lambda () (error "boom"))))))
          (should (= 1 (length reports)))
          (should (eq 'error (plist-get (car reports) :status)))
          (should (eq 'error (etaf-resource-status resource)))
          (should (string-match-p "boom" (cadr (etaf-resource-error resource)))))
      (when resource
        (etaf-resource-dispose resource)))))

(ert-deftest etaf-resource-unobserved-load-bypasses-stage-runtime ()
  "Keep standalone Resource loading free of observation work."
  (let (resource)
    (unwind-protect
        (cl-letf (((symbol-function 'etaf--observer-call-stage)
                   (lambda (&rest _args)
                     (ert-fail "unobserved Resource entered stage runtime"))))
          (setq resource (etaf-resource (lambda () "ready")))
          (should (equal "ready" (etaf-resource-value resource))))
      (when resource
        (etaf-resource-dispose resource)))))

;;; etaf-resource-tests.el ends here
