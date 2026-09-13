;;; etaf-selector-facts-tests.el --- Shared selector facts -*- lexical-binding: t; -*-

;;; Commentary:
;; Host metadata is observable through the Ebox selector contract.

;;; Code:
(require 'ert)
(require 'etaf)
(require 'ebox)

(ert-deftest etaf-selector-facts-pure-hosts-preserve-semantics ()
  "Role, ARIA presence and disabled state reach canonical subjects."
  (let ((input (etaf-render
                (etaf-view
                 (column :role 'group :aria-label "Actions"
                   (text :id 'toggle :class 'control :role 'checkbox
                         :disabled t :aria-checked nil "Toggle")
                   (box :role 'button :aria-pressed t "Press")
                   (text :role nil "Plain"))))))
    (dolist (selector '("[role=group] > text.control[role=checkbox]:disabled"
                        "#toggle[aria-checked][aria-checked=nil]"
                        "[role=button][aria-pressed=t]"
                        "[aria-label=Actions]"))
      (should (= 1 (length (ebox-selector-query-all input selector)))))
    (should (= 2 (length (ebox-selector-query-all input "text:not(:disabled)")))))
  (should-error (etaf-render (etaf-view (text :selector-state '(disabled) "Bad")))
                :type 'etaf-renderer-error))

(ert-deftest etaf-selector-facts-follow-accepted-reactive-properties ()
  "Reactive metadata publishes together and a failed candidate preserves selectors."
  (let ((buffer (generate-new-buffer " *etaf-selector-facts*"))
        (role (etaf-ref 'button))
        (disabled (etaf-ref nil))
        (checked (etaf-ref nil))
        (presses 0))
    (unwind-protect
        (let* ((_mounted
                (etaf-mount
                 buffer
                 (etaf-view
                  (text :ref 'control :role (etaf-value role)
                        :disabled (etaf-value disabled)
                        :aria-checked (etaf-value checked)
                        :on-press (lambda () (cl-incf presses)) "Control"))))
               (runtime (etaf-runtime-for-buffer buffer)))
          (should (= 1 (length (ebox-selector-query-buffer
                               buffer "[role=button]:not(:disabled)[aria-checked=nil]"))))
          (etaf-dispatch-event runtime 'control 'press)
          (should (= presses 1))
          (setf (etaf-value disabled) t)
          (etaf-runtime-flush runtime)
          (should (= 1 (length (ebox-selector-query-buffer buffer "[role=button]:disabled"))))
          (should-error (etaf-dispatch-event runtime 'control 'press)
                        :type 'etaf-event-error)
          (should (= presses 1))
          (setf (etaf-value role) 'checkbox (etaf-value checked) t)
          (etaf-runtime-flush runtime)
          (should (= 1 (length (ebox-selector-query-buffer
                               buffer "[role=checkbox]:disabled[aria-checked=t]"))))
          (should-error (setf (etaf-value role) '(invalid)))
          (should (= 1 (length (ebox-selector-query-buffer
                               buffer "[role=checkbox]:disabled[aria-checked=t]"))))
          (setf (etaf-value role) 'button (etaf-value disabled) nil)
          (etaf-runtime-flush runtime)
          (should-not (ebox-selector-query-buffer buffer ":disabled"))
          (etaf-dispatch-event runtime 'control 'press)
          (should (= presses 2))
          (should (= 1 (length (ebox-selector-query-buffer buffer "[role=button]")))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-selector-facts-tests)
;;; etaf-selector-facts-tests.el ends here
