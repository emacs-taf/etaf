;;; etaf-scope-tests.el --- Public effect scope lifecycle -*- lexical-binding: t; -*-

;;; Commentary:
;; Standalone consumers can create, enter and fully release effect scopes.

;;; Code:
(require 'ert)
(require 'etaf)

(ert-deftest etaf-scope-stop-releases-effects-and-owned-children ()
  "Stopping a parent ends owned effects and runs cleanup once."
  (let ((scope (etaf-effect-scope :detached t))
        (source (etaf-ref 0))
        child observed cleanup)
    (unwind-protect
        (progn
          (should
           (eq 'ready
               (etaf-scope-run
                scope
                (lambda ()
                  (etaf-on-scope-dispose (lambda () (push 'parent cleanup)))
                  (setq child (etaf-effect-scope))
                  (etaf-scope-run
                   child
                   (lambda ()
                     (etaf-on-scope-dispose (lambda () (push 'child cleanup)))
                     (etaf-watch-effect
                      (lambda () (push (etaf-value source) observed)))))
                  'ready))))
          (should (equal observed '(0)))
          (setf (etaf-value source) 1)
          (should (equal observed '(1 0)))
          (should-not (etaf-scope-stop scope))
          (should (equal cleanup '(parent child)))
          (setf (etaf-value source) 2)
          (should (equal observed '(1 0)))
          (should-error (etaf-scope-run scope #'ignore))
          (should-error (etaf-scope-run child #'ignore))
          (should-not (etaf-scope-stop scope))
          (should (equal cleanup '(parent child))))
      (etaf-scope-stop scope))))

(ert-deftest etaf-scope-stop-contains-cleanup-errors-and-quits ()
  "A failing cleanup cannot prevent other cleanup or reactivate a stopped scope."
  (let ((scope (etaf-effect-scope :detached t))
        cleanup)
    (unwind-protect
        (progn
          (etaf-scope-run
           scope
           (lambda ()
             (etaf-on-scope-dispose (lambda () (push 'last cleanup)))
             (etaf-on-scope-dispose (lambda () (error "cleanup failure")))
             (etaf-on-scope-dispose (lambda () (signal 'quit nil)))
             (etaf-on-scope-dispose (lambda () (push 'first cleanup)))))
          (let ((conditions (etaf-scope-stop scope)))
            (should (equal cleanup '(last first)))
            (should (= 2 (length conditions)))
            (should (assq 'error conditions))
            (should (assq 'quit conditions)))
          (should-not (etaf-scope-stop scope)))
      (etaf-scope-stop scope))))

(ert-deftest etaf-scope-rejects-cleanup-registration-after-stop ()
  "A still-bound scope cannot acquire unreachable cleanup after it stops."
  (let ((scope (etaf-effect-scope :detached t)))
    (unwind-protect
        (etaf-scope-run
         scope
         (lambda ()
           (etaf-scope-stop scope)
           (should-error (etaf-on-scope-dispose #'ignore))))
      (etaf-scope-stop scope)))
  (should-error (etaf-on-scope-dispose #'ignore)))

(provide 'etaf-scope-tests)
;;; etaf-scope-tests.el ends here
