;;; etaf-input-validation-tests.el --- Component input contracts -*- lexical-binding: t; -*-

;;; Commentary:
;; Resolved props are validated before initialization or publication.

;;; Code:
(require 'ert)
(require 'etaf)

(defvar etaf-input-test--initialized nil)
(defvar etaf-input-test--observed nil)

(etaf-define-component etaf-input-test-label (&key (count 1))
  :validate (etaf-check-prop :count count (natnump count) "a nonnegative integer")
  :view (text (expr (number-to-string count))))

(etaf-define-component etaf-input-test-counter (&key (count 1))
  :validate (etaf-check-prop :count count (natnump count) "a nonnegative integer")
  :bindings ((presses (etaf-ref 0)))
  :setup (push presses etaf-input-test--initialized)
  :render
  (etaf-view
   (box :ref 'validated-counter :role 'button :tab-index 0
        :on-press (lambda () (setq etaf-input-test--observed count)
                    (cl-incf (etaf-value presses)))
        (text (expr (format "%s/%s" count (etaf-value presses)))))))

(ert-deftest etaf-component-validation-reports-resolved-inputs ()
  "Default values pass normal rendering; invalid props identify the contract."
  (should (equal "1" (substring-no-properties
                      (ebox-render (etaf-render (etaf-view (etaf-input-test-label)))))))
  (dolist (value '(nil -1 "wrong"))
    (let* ((problem (should-error (etaf-render (etaf-node 'etaf-input-test-label
                                                        (list :count value) nil))
                                 :type 'etaf-component-call-error))
           (message (cadr problem)))
      (should (string-match-p "etaf-input-test-label.*:count.*expected a nonnegative integer" message))
      (should (string-match-p (regexp-quote (format "received %S" value)) message))))
  (let ((value (list :owned t)))
    (should (eq value (etaf-check-prop :payload value t "a payload" 'external-component)))))

(ert-deftest etaf-component-validation-precedes-setup-and-input-publication ()
  "Rejected inputs retain displayed props, callbacks and initialized state."
  (dolist (root-function '(nil t))
    (let ((buffer (generate-new-buffer " *etaf-input-validation*"))
          (count (etaf-ref "invalid"))
          (etaf-input-test--initialized nil)
          (etaf-input-test--observed nil))
      (unwind-protect
          (let ((view (if root-function
                          (lambda () (etaf-node 'etaf-input-test-counter (list :count (etaf-value count)) nil))
                        (etaf-view (etaf-input-test-counter :count (etaf-value count))))))
            (should-error (etaf-mount buffer view) :type 'etaf-component-call-error)
            (should-not etaf-input-test--initialized)
            (should-not (etaf-runtime-for-buffer buffer))
            (setf (etaf-value count) 2)
            (etaf-mount buffer view)
            (let ((runtime (etaf-runtime-for-buffer buffer)))
              (etaf-dispatch-event runtime 'validated-counter 'press)
              (should (= 2 etaf-input-test--observed))
              (should-error (setf (etaf-value count) -1) :type 'etaf-component-call-error)
              (should (= -1 (etaf-value count)))
              (with-current-buffer buffer (should (string-match-p "2/1" (buffer-string))))
              (setf (etaf-value count) 3)
              (etaf-dispatch-event runtime 'validated-counter 'press)
              (should (= 3 etaf-input-test--observed))
              (should (= 1 (length etaf-input-test--initialized)))
              (with-current-buffer buffer (should (string-match-p "3/2" (buffer-string))))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest etaf-component-validation-rejects-malformed-definition ()
  "Validation clauses and check metadata have explicit definition errors."
  (should-error (macroexpand '(etaf-define-component etaf-invalid-check ()
                               :validate t :validate nil :view (text "X")))
                :type 'etaf-component-definition-error)
  (should-error (etaf-check-prop :value 1 t "an integer")
                :type 'etaf-component-definition-error))

(provide 'etaf-input-validation-tests)
;;; etaf-input-validation-tests.el ends here
