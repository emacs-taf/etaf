;;; etaf-batch-tests.el --- Public reactive batching -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Observe batching through ref reads, watches and mounted output.

;;; Code:
(require 'ert)
(require 'etaf)

(ert-deftest etaf-batch-defers-observers-until-outer-scope-exits ()
  "Nested batches expose current refs and deliver only their completed state."
  (let ((x (etaf-ref 0))
        (y (etaf-ref 0))
        observed)
    (let ((stop (etaf-watch
                 (lambda () (list (etaf-value x) (etaf-value y)))
                 (lambda (new old) (push (list new old) observed)))))
      (unwind-protect
          (progn
            (should
             (eq 'complete
                 (etaf-call-with-batch
                  (lambda ()
                    (etaf-set-value x 1)
                    (should (= 1 (etaf-value x)))
                    (should-not observed)
                    (should
                     (eq 'nested
                         (etaf-batch
                           (etaf-set-value y 2)
                           (etaf-set-value x 3)
                           (should (= 2 (etaf-value y)))
                           (should-not observed)
                           'nested)))
                    (should-not observed)
                    'complete))))
            (should (equal observed '(((3 2) (0 0)))))
            (should-not (etaf-batch))
            (etaf-set-value y 4)
            (should (equal observed '(((3 4) (3 2)) ((3 2) (0 0))))))
        (funcall stop)))))

(ert-deftest etaf-batch-defers-mounted-output-until-outer-scope-exits ()
  "Related writes retain committed output until the outer batch publishes."
  (let ((x (etaf-ref 0))
        (y (etaf-ref 0))
        (buffer (generate-new-buffer " *etaf-batch-output*")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (text (expr (format "%s:%s" (etaf-value x) (etaf-value y))))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (before (plist-get (etaf-runtime-snapshot runtime) :revision)))
            (etaf-batch
              (etaf-set-value x 3)
              (etaf-call-with-batch (lambda () (etaf-set-value y 4)))
              (should (= before (plist-get (etaf-runtime-snapshot runtime)
                                           :revision)))
              (should (equal "0:0" (with-current-buffer buffer
                                     (buffer-string)))))
            (should (> (plist-get (etaf-runtime-snapshot runtime) :revision)
                       before))
            (should (equal "3:4" (with-current-buffer buffer
                                   (buffer-string))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-batch-body-error-drains-writes-before-resignaling ()
  "A body error preserves refs and publishes completed writes before escaping."
  (let ((source (etaf-ref 0))
        (buffer (generate-new-buffer " *etaf-batch-body-error*")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view (text (expr (number-to-string (etaf-value source))))))
          (should
           (equal '(error "Batch body failed" :detail original)
                  (should-error
                   (etaf-batch
                     (etaf-set-value source 7)
                     (signal 'error '("Batch body failed" :detail original)))
                   :type 'error)))
          (should (= 7 (etaf-value source)))
          (should (equal "7" (with-current-buffer buffer (buffer-string))))
          (etaf-batch (etaf-set-value source 8))
          (should (equal "8" (with-current-buffer buffer (buffer-string)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-batch-primary-error-survives-publication-failure ()
  "Publication failure does not replace the body error or roll back written refs."
  (let ((source (etaf-ref 0))
        (buffer (generate-new-buffer " *etaf-batch-primary-error*")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view (text (expr (number-to-string (etaf-value source))))))
          (should
           (equal '(error "Primary batch failure")
                  (should-error
                   (etaf-batch
                     (etaf-set-value source 'invalid)
                     (error "Primary batch failure"))
                   :type 'error)))
          (should (eq 'invalid (etaf-value source)))
          (should (equal "0" (with-current-buffer buffer (buffer-string))))
          (etaf-batch (etaf-set-value source 9))
          (should (equal "9" (with-current-buffer buffer (buffer-string)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-batch-runtime-failure-preserves-other-publications ()
  "One failed Runtime retains its display while another accepts the batch."
  (let ((source (etaf-ref 0))
        (numeric-buffer (generate-new-buffer " *etaf-batch-numeric*"))
        (text-buffer (generate-new-buffer " *etaf-batch-text*")))
    (unwind-protect
        (progn
          (etaf-mount
           numeric-buffer
           (etaf-view (text (expr (number-to-string (etaf-value source))))))
          (etaf-mount
           text-buffer
           (etaf-view (text (expr (format "%s" (etaf-value source))))))
          (should-error (etaf-batch (etaf-set-value source 'invalid))
                        :type 'wrong-type-argument)
          (should (eq 'invalid (etaf-value source)))
          (should (equal "0" (with-current-buffer numeric-buffer
                               (buffer-string))))
          (should (equal "invalid" (with-current-buffer text-buffer
                                     (buffer-string))))
          (etaf-batch (etaf-set-value source 5))
          (dolist (buffer (list numeric-buffer text-buffer))
            (should (equal "5" (with-current-buffer buffer (buffer-string))))))
      (dolist (buffer (list numeric-buffer text-buffer))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
          (etaf-unmount runtime))
        (kill-buffer buffer)))))

(ert-deftest etaf-batch-quit-drains-written-state ()
  "A quit preserves changed refs and delivers their notifications before escape."
  (let ((source (etaf-ref 0)) observed condition)
    (let ((stop (etaf-watch source (lambda (new _old) (setq observed new)))))
      (unwind-protect
          (progn
            (condition-case caught
                (etaf-batch
                  (etaf-set-value source 4)
                  (signal 'quit nil))
              (quit (setq condition caught)))
            (should (equal '(quit) condition))
            (should (= 4 (etaf-value source)))
            (should (= 4 observed)))
        (funcall stop)))))

(ert-deftest etaf-batch-rejects-invalid-functions-and-render-scopes ()
  "Invalid input and render calls fail without evaluating the batch body."
  (let (called)
    (should-error (etaf-call-with-batch 42) :type 'wrong-type-argument)
    (should-error
     (etaf-render
      (etaf-view
       (text (expr (etaf-call-with-batch
                    (lambda () (setq called t) "rendered"))))))
     :type 'etaf-render-side-effect-error)
    (should-not called)
    (should-error
     (etaf-render
      (etaf-view (text (expr (etaf-batch (setq called t) "rendered")))))
     :type 'etaf-render-side-effect-error)
    (should-not called)))

(provide 'etaf-batch-tests)
;;; etaf-batch-tests.el ends here
