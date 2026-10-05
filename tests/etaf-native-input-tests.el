;;; etaf-native-input-tests.el --- Native input event ownership -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise the public event bridge without loading the UI catalog.

;;; Code:
(require 'ert)
(require 'etaf)

(ert-deftest etaf-native-input-uses-the-current-event-and-restores-focus ()
  "The current event supplies the mounted owner, including from another buffer."
  (let ((buffer (generate-new-buffer " *etaf-input*")) value runtime)
    (unwind-protect
        (progn
          (should-error (etaf-call-with-input #'ignore) :type 'etaf-event-error)
          (etaf-mount
           buffer
           (etaf-view
            (column
             (text :ref 'edit :on-press
                   (lambda ()
                     (setq value (etaf-call-with-input
                                  (lambda ()
                                    (should (eq (current-buffer) buffer))
                                    (etaf-focus runtime 'other)
                                    "中文")))) "Edit")
             (text :ref 'other "Other"))))
          (setq runtime (etaf-runtime-for-buffer buffer))
          (with-temp-buffer (etaf-dispatch-event runtime 'edit 'press))
          (should (equal value "中文"))
          (should (eq (etaf-focused-host-ref runtime) 'edit)))
      (when (etaf-runtime-for-buffer buffer) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-native-input-unmount-cancels-results-and-forwarded-observers ()
  "Closing a mounted owner during input cannot publish a value or observer."
  (let ((buffer (generate-new-buffer " *etaf-input-unmount*")) value runtime observed)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (text :ref 'edit :on-press
                  (lambda ()
                    (setq value (etaf-call-with-input
                                 (lambda () (etaf-unmount runtime) "discard")))
                    (setq observed t)) "Edit")))
          (setq runtime (etaf-runtime-for-buffer buffer))
          (should (eq 'cancelled
                      (condition-case nil
                          (etaf-dispatch-event runtime 'edit 'press)
                        (quit 'cancelled))))
          (should-not value)
          (should-not observed)
          (should-not (etaf-runtime-for-buffer buffer)))
      (when (etaf-runtime-for-buffer buffer) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-native-input-refit-waits-for-the-session ()
  "A viewport refit requested while editing publishes after the session ends."
  (let ((buffer (generate-new-buffer " *etaf-input-refit*")) session)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view (column (text :ref 'edit "Edit")
                              (text :ref 'other "Other")))
           '(:viewport-width 600 :viewport-height 20))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (setq session (etaf-input-begin runtime 'edit))
            (should-not (etaf-runtime-refit runtime 500 19))
            (should (equal (etaf-runtime-viewport runtime) '(600 . 20)))
            (etaf-input-end session)
            (setq session nil)
            (etaf-runtime-flush runtime)
            (should (equal (etaf-runtime-viewport runtime) '(500 . 19)))))
      (when session (ignore-errors (etaf-input-end session)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-native-input-outside-press-runs-the-runtime-finisher ()
  "A press on another Host finishes the session through the Runtime finisher."
  (let ((buffer (generate-new-buffer " *etaf-input-finisher*"))
        session pressed end-text)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (column
             (text :ref 'edit :on-press (lambda () nil) "Edit")
             (text :ref 'other :on-press (lambda () (setq pressed t)) "Other")))
           '(:viewport-width 600 :viewport-height 20))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (setq session (etaf-input-begin runtime 'edit))
            (etaf-runtime-set-input-finisher
             runtime
             (lambda (rt)
               (setq end-text (etaf-input-end session))
               (etaf-runtime-set-input-finisher rt nil)))
            ;; A press on the session's own Host keeps editing.
            (etaf-dispatch-event runtime 'edit 'press)
            (should-not pressed)
            (should (ebox-input-active-p buffer))
            (etaf-dispatch-event runtime 'other 'press)
            (should pressed)
            (should end-text)
            (should-not (ebox-input-active-p buffer))
            (should-not (etaf-runtime-input-finisher runtime))))
      (when (and session (ebox-input-active-p buffer)) (etaf-input-end session))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-native-input-tests)
;;; etaf-native-input-tests.el ends here
