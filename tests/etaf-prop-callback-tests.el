;;; etaf-prop-callback-tests.el --- Component input snapshots -*- lexical-binding: t; -*-

;;; Commentary:
;; Deferred callbacks observe the props of their successful publication.

;;; Code:
(require 'ert)
(require 'etaf)

(etaf-define-component etaf-test-prop-callback (&key label source report)
  :view
  (box :on-press (lambda () (funcall report label source (etaf-value source)))
    (text (expr label))))

(etaf-define-component etaf-test-prop-code-callback (&key label source report)
  :render
  (etaf-node 'box
             (list :on-press
                   (lambda () (funcall report label source (etaf-value source))))
             (list (etaf-node 'text nil (list label)))))

(ert-deftest etaf-prop-callbacks-follow-successful-publication ()
  "Both frontends retain committed snapshots and explicit live ref identity."
  (dolist (component '(etaf-test-prop-callback etaf-test-prop-code-callback))
    (let ((buffer (generate-new-buffer " *etaf-prop-callback*"))
          (label (etaf-ref "Before"))
          (source (etaf-ref 1))
          observed)
      (unwind-protect
          (let ((runtime
                 (etaf-mount
                  buffer
                  (lambda ()
                    (etaf-node component
                               (list :label (etaf-value label) :source source
                                     :ref 'target
                                     :report (lambda (&rest values)
                                               (setq observed values)))
                               nil)))))
            (setq runtime (etaf-runtime-for-buffer buffer))
            (etaf-dispatch-event runtime 'target 'press)
            (should (equal observed (list "Before" source 1)))
            (setf (etaf-value label) "After")
            (setf (etaf-value source) 2)
            (etaf-dispatch-event runtime 'target 'press)
            (should (equal observed (list "After" source 2)))
            (let ((published (with-current-buffer buffer (buffer-string))))
              (should-error (setf (etaf-value label) 42))
              (should (equal-including-properties
                       published (with-current-buffer buffer (buffer-string))))
              (etaf-dispatch-event runtime 'target 'press)
              (should (equal observed (list "After" source 2))))
            (setf (etaf-value label) "Recovered")
            (etaf-dispatch-event runtime 'target 'press)
            (should (equal observed (list "Recovered" source 2))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
          (etaf-unmount runtime))
        (kill-buffer buffer)))))

(provide 'etaf-prop-callback-tests)
;;; etaf-prop-callback-tests.el ends here
