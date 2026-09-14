;;; etaf-value-update-tests.el --- Functional ref updates -*- lexical-binding: t; -*-

;;; Commentary:
;; Observe ref replacement, rendered output and errors through public APIs.

;;; Code:
(require 'ert)
(require 'etaf)

(ert-deftest etaf-value-update-replaces-structured-state-and-renders ()
  "An event replaces a plist without modifying the previously published value."
  (let* ((original (list :title "Draft" :done nil))
         (task (etaf-ref original))
         (buffer (generate-new-buffer " *value-update*")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (column
             (text (expr (format "%s:%s" (plist-get (etaf-value task) :title)
                                 (if (plist-get (etaf-value task) :done) "done" "open"))))
             (box :ref 'toggle
                  :on-press
                  (lambda ()
                    (etaf-update-value
                     task (lambda (old key)
                            (plist-put (copy-sequence old) key
                                       (not (plist-get old key)))) :done))
               "Toggle"))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-dispatch-event runtime 'toggle 'press)
            (should (string-match-p "Draft:done" (with-current-buffer buffer (buffer-string))))
            (should-not (plist-get original :done))
            (should-not (eq original (etaf-value task)))
            (let ((completed (etaf-value task)))
              (etaf-dispatch-event runtime 'toggle 'press)
              (should (plist-get completed :done))
              (should (string-match-p "Draft:open" (with-current-buffer buffer (buffer-string)))))
            (etaf-unmount runtime)
            (let ((published (with-current-buffer buffer (buffer-string))))
              (etaf-update-value task (lambda (_) '(:title "After unmount")))
              (should (equal published (with-current-buffer buffer (buffer-string)))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-value-update-rejects-invalid-writes-before-updater ()
  "Read-only or render writes do not run the updater; updater errors retain state."
  (let ((source (etaf-ref 1))
        (scope (etaf-effect-scope :detached t))
        computed called)
    (unwind-protect
        (progn
          (etaf-scope-run scope (lambda () (setq computed (etaf-computed (lambda () 2)))))
          (should (= 4 (etaf-update-value source #'+ 3)))
          (should (= 4 (etaf-value source)))
          (should-error (etaf-update-value source (lambda (_) (error "Rejected"))))
          (should (= 4 (etaf-value source)))
          (should-error (etaf-update-value source 42))
          (should-error
           (etaf-update-value computed (lambda (_) (setq called t))))
          (should-not called)
          (should-error
           (etaf-render
            (etaf-view
             (text (expr (etaf-update-value source (lambda (_) (setq called t)))))))
           :type 'etaf-render-write-error)
          (should-not called)
          (should-error
           (etaf-render
            (etaf-view (text (expr (number-to-string (etaf-set-value source 9))))))
           :type 'etaf-render-write-error)
          (should (= 4 (etaf-value source))))
      (etaf-scope-stop scope))))

(ert-deftest etaf-value-update-preserves-write-after-rejected-publication ()
  "Publication failure retains the application value and permits a later repair."
  (let ((source (etaf-ref 1))
        (buffer (generate-new-buffer " *value-update-repair*")))
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-view (text (expr (number-to-string (etaf-value source))))))
          (let ((published (with-current-buffer buffer (buffer-string))))
            (should-error (etaf-update-value source (lambda (_) "invalid")))
            (should (equal "invalid" (etaf-value source)))
            (should (equal published (with-current-buffer buffer (buffer-string)))))
          (etaf-update-value source (lambda (_) 2))
          (should (string-match-p "2" (with-current-buffer buffer (buffer-string)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-value-update-tests)
;;; etaf-value-update-tests.el ends here
