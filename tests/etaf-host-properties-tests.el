;;; etaf-host-properties-tests.el --- Host and Component composition -*- lexical-binding: t; -*-

;;; Commentary:
;; Reactive Host attributes compose with retained Component state and siblings.

;;; Code:
(require 'ert)
(require 'etaf)

(etaf-define-component etaf-test-host-properties-counter ()
  :bindings ((count (etaf-ref 0)))
  :view
  (box :ref 'counter :tab-index 0
       :on-press (lambda () (cl-incf (etaf-value count)))
    (text (expr (format "Count %d" (etaf-value count))))))

(ert-deftest etaf-host-properties-compose-with-retained-components ()
  "Parent geometry and interaction changes preserve child state and handlers."
  (let ((state (etaf-ref nil))
        (buffer (generate-new-buffer " *etaf-host-properties*")))
    (unwind-protect
        (let ((runtime
               (etaf-runtime-for-buffer
                (etaf-mount
                 buffer
                 (etaf-view
                  (column
                   (box :ref 'panel
                        :width (if (etaf-value state) '(ch 18) '(ch 30))
                        :padding (if (etaf-value state) '((lh 1) (ch 2)) nil)
                        :color (if (etaf-value state) "red" "blue")
                        :disabled (etaf-value state)
                        :on-press (lambda () (setf (etaf-value state) t))
                        (etaf-test-host-properties-counter)
                        (text (expr (if (etaf-value state) "Expanded" "Compact"))))
                   (expr (when (etaf-value state) (etaf-view (text "Extra"))))))))))
          (etaf-dispatch-event runtime 'counter 'press)
          (dolist (value '(t nil t))
            (setf (etaf-value state) value)
            (with-current-buffer buffer
              (should (string-match-p "Count 1" (buffer-string)))
              (should (string-match-p (if value "Expanded" "Compact") (buffer-string)))
              (should (eq (not (null (string-match-p "Extra" (buffer-string)))) value)))
            (should (etaf-host-ref-position runtime 'counter)))
          (etaf-dispatch-event runtime 'counter 'press)
          (with-current-buffer buffer
            (should (string-match-p "Count 2" (buffer-string)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'etaf-host-properties-tests)
;;; etaf-host-properties-tests.el ends here
