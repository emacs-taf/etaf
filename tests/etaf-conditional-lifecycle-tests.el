;;; etaf-conditional-lifecycle-tests.el --- Conditional ownership -*- lexical-binding: t; -*-

;;; Commentary:
;; Structural visibility resolves before descendant input and render updates.

;;; Code:
(require 'ert)
(require 'etaf)

(etaf-define-component etaf-conditional-test-caption (&key value activate dispose)
  :setup (progn (etaf-on-unmounted dispose) nil)
  :view
  (text :ref 'conditional-caption :tab-index 0
        :on-press (lambda () (funcall activate value))
        (expr value)))

(ert-deftest etaf-conditional-component-retires-before-stale-input-work ()
  "Repeated removal and recreation retain matching text, callbacks and lifecycle."
  (let ((state (etaf-ref 'success))
        (buffer (generate-new-buffer " *conditional-lifecycle*"))
        activated (disposals 0))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (column
             (etaf-conditional-test-caption
              :if (not (eq (etaf-value state) 'success))
              :value (symbol-name (etaf-value state))
              :activate (lambda (value) (setq activated value))
              :dispose (lambda () (setq disposals (1+ disposals))))
             (text "Always present"))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (dolist (next '(refreshing cancelled refreshing success loading error success loading success))
              (setf (etaf-value state) next)
              (should (with-current-buffer buffer (string-match-p "Always present" (buffer-string))))
              (if (eq next 'success)
                  (should-error (etaf-dispatch-event runtime 'conditional-caption 'press)
                                :type 'etaf-event-error)
                (should (with-current-buffer buffer (string-match-p (symbol-name next) (buffer-string))))
                (etaf-dispatch-event runtime 'conditional-caption 'press)
                (should (equal activated (symbol-name next)))))
            (should (= disposals 3))))
      (when (etaf-runtime-for-buffer buffer) (etaf-unmount (etaf-runtime-for-buffer buffer)))
      (kill-buffer buffer))))

(provide 'etaf-conditional-lifecycle-tests)
;;; etaf-conditional-lifecycle-tests.el ends here
