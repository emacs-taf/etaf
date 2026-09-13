;;; etaf-behavior-context-tests.el --- Public installer context -*- lexical-binding: t; -*-

;;; Commentary:
;; Context queries describe installation inputs through supported interfaces.

;;; Code:
(require 'ert)
(require 'etaf)

(ert-deftest etaf-behavior-context-reports-installation-and-cleanup ()
  "Installers get their Runtime, target and a protected property container."
  (let ((buffer (generate-new-buffer " *etaf-context*"))
        (callback #'ignore)
        context cleaned)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (box :ref 'target :role 'button :on-press callback
                 :use (etaf-behavior-create
                       'observe :tab-index 0
                       :install
                       (lambda ()
                         (setq context (etaf-current-behavior-context))
                         (lambda () (setq cleaned (etaf-behavior-context-info context)))))
                 "Button")))
          (should-not (etaf-current-behavior-context))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (info (etaf-behavior-context-info context)))
            (should (eq runtime (plist-get info :runtime)))
            (should (eq 'target (plist-get info :host-ref)))
            (should (eq 'button (plist-get (plist-get info :properties) :role)))
            (should (= 0 (plist-get (plist-get info :properties) :tab-index)))
            (should (eq callback (plist-get (plist-get info :properties) :on-press)))
            (setf (plist-get info :host-ref) 'changed
                  (plist-get (plist-get info :properties) :role) 'changed)
            (let ((fresh (etaf-behavior-context-info context)))
              (should (eq 'target (plist-get fresh :host-ref)))
              (should (eq 'button (plist-get (plist-get fresh :properties) :role))))
            (etaf-unmount runtime)
            (should (eq runtime (plist-get cleaned :runtime)))
            (should (eq 'target (plist-get cleaned :host-ref)))
            (should (equal cleaned (etaf-behavior-context-info context)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer)))
  (should-error (etaf-behavior-context-info nil) :type 'etaf-behavior-error))

(ert-deftest etaf-behavior-context-candidate-facts-do-not-publish-early ()
  "Failed installation replacement cleans up its own facts and keeps old input."
  (let ((buffer (generate-new-buffer " *etaf-context-rollback*"))
        (value (etaf-ref "Before"))
        installed cleaned)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (lambda ()
             (let ((label (etaf-value value)))
               (etaf-view
                (column
                 (box :ref 'target :aria-label label
                      :use (etaf-behavior-create
                            'observe :install
                            (lambda ()
                              (let ((context (etaf-current-behavior-context)))
                                (push context installed)
                                (lambda () (push context cleaned)))))
                      "Target")
                 (text (expr label)))))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (initial (car installed)))
            (should-error (setf (etaf-value value) 42))
            (should (eq (car installed) (car cleaned)))
            (should-not (eq initial (car cleaned)))
            (should (equal "Before"
                           (plist-get (etaf-runtime-host-props-for runtime 'target)
                                      :aria-label)))
            (should (= 42 (plist-get
                           (plist-get (etaf-behavior-context-info (car cleaned))
                                      :properties) :aria-label)))
            (setf (etaf-value value) "After")
            (should (memq initial cleaned))
            (should (equal "After"
                           (plist-get (etaf-runtime-host-props-for runtime 'target)
                                      :aria-label)))
            (etaf-unmount runtime)
            (should (memq (car installed) cleaned))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-behavior-context-tests)
;;; etaf-behavior-context-tests.el ends here
