;;; etaf-animation-tests.el --- Time-driven reactive values -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Transitions, frame sequences, their shared clock and Scope ownership are
;; public behavior: values interpolate, interruption never jumps, and stop,
;; finish, disabling and unmount all leave a stable value and no clock demand.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'etaf)

(defun etaf-animation-test-wait (predicate)
  "Process timers until PREDICATE succeeds, with a bounded deadline."
  (let ((deadline (+ (float-time) 2)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.005))
    (should (funcall predicate))))

(defun etaf-animation-test-sleep (seconds)
  "Process timers for SECONDS."
  (let ((deadline (+ (float-time) seconds)))
    (while (< (float-time) deadline)
      (accept-process-output nil 0.005))))

(defvar etaf-animation-test-level nil
  "Target ref owned by the test component.")

(defvar etaf-animation-test-shown nil
  "Transition ref owned by the test component's Scope.")

(etaf-define-component etaf-animation-test-card ()
  "Component whose Scope owns one transition to an internal target."
  :setup (progn
           (setq etaf-animation-test-level (etaf-ref 0 :name 'test-level))
           (setq etaf-animation-test-shown
                 (etaf-transition etaf-animation-test-level
                                  :duration 0.3 :easing 'linear))
           nil)
  :view (text (expr (format "level %.2f" (etaf-value etaf-animation-test-shown)))))

(ert-deftest etaf-animation-transition-interpolates-and-lands-exactly ()
  "A transition samples between values, lands exactly and reports completion."
  (let* ((completed 0)
         (target (etaf-ref 0))
         (shown (etaf-transition target :duration 0.25 :easing 'linear
                                 :on-complete (lambda () (cl-incf completed))))
         (samples nil)
         (stop (etaf-watch shown (lambda (new _old) (push new samples)))))
    (unwind-protect
        (progn
          (should (= 0 (etaf-value shown)))
          (should-not (etaf-animation-active-p shown))
          (setf (etaf-value target) 10)
          (should (etaf-animation-active-p shown))
          (etaf-animation-test-wait
           (lambda () (not (etaf-animation-active-p shown))))
          (should (= 10 (etaf-value shown)))
          (setq samples (nreverse samples))
          (should (> (length samples) 1))
          (should (cl-some (lambda (value) (and (> value 0) (< value 10)))
                           samples))
          (should (cl-every (lambda (a b) (<= a b)) samples (cdr samples)))
          (should (= 1 completed)))
      (etaf-animation-stop shown)
      (funcall stop))))

(ert-deftest etaf-animation-transition-retargets-from-current-value ()
  "Changing the target mid-run continues from the displayed value."
  (let* ((target (etaf-ref 0))
         (shown (etaf-transition target :duration 0.4 :easing 'linear))
         (samples nil)
         (stop (etaf-watch shown (lambda (new _old) (push new samples)))))
    (unwind-protect
        (progn
          (setf (etaf-value target) 10)
          (etaf-animation-test-wait
           (lambda () (let ((value (etaf-value shown)))
                        (and (numberp value) (> value 0)))))
          (let ((pivot (etaf-value shown)))
            (setq samples nil)
            (setf (etaf-value target) 2)
            (etaf-animation-test-wait
             (lambda () (not (etaf-animation-active-p shown))))
            (should (= 2 (etaf-value shown)))
            (setq samples (nreverse samples))
            (should (> (length samples) 1))
            (should (cl-every (lambda (value)
                                (and (>= value (- pivot 0.001)) (<= value 2)))
                              samples))))
      (etaf-animation-stop shown)
      (funcall stop))))

(ert-deftest etaf-animation-stop-and-finish-freeze-or-land ()
  "Stopping keeps the displayed value; finishing applies the target."
  (let* ((target (etaf-ref 0))
         (shown (etaf-transition target :duration 1.0 :easing 'linear)))
    (setf (etaf-value target) 100)
    (etaf-animation-test-wait (lambda () (etaf-animation-active-p shown)))
    (etaf-animation-test-sleep 0.08)
    (etaf-animation-stop shown)
    (let ((frozen (etaf-value shown)))
      (should-not (etaf-animation-active-p shown))
      (etaf-animation-test-sleep 0.12)
      (should (equal frozen (etaf-value shown)))
      (setf (etaf-value target) 5)
      (etaf-animation-test-sleep 0.08)
      (should (equal frozen (etaf-value shown)))
      (should-not (etaf-animation-active-p shown))))
  (let* ((target (etaf-ref 0))
         (shown (etaf-transition target :duration 1.0 :easing 'linear)))
    (setf (etaf-value target) 7)
    (etaf-animation-test-wait (lambda () (etaf-animation-active-p shown)))
    (etaf-animation-finish shown)
    (should (= 7 (etaf-value shown)))
    (should-not (etaf-animation-active-p shown)))
  (let ((shown (etaf-animation-frames '("a" "b" "c") :interval 0.03)))
    (etaf-animation-test-wait (lambda () (etaf-animation-active-p shown)))
    (etaf-animation-test-sleep 0.07)
    (etaf-animation-stop shown)
    (let ((frozen (etaf-value shown)))
      (etaf-animation-test-sleep 0.1)
      (should (equal frozen (etaf-value shown)))
      (should-not (etaf-animation-active-p shown)))))

(ert-deftest etaf-animation-scope-and-switch-control-the-clock ()
  "Unmounting stops the Scope's animation; a disabled switch applies at once."
  (let ((baseline (length timer-list))
        (buffer (generate-new-buffer " *etaf-animation-test*")))
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-view (etaf-animation-test-card))
                      (list :viewport-width 400 :viewport-height 20))
          (setf (etaf-value etaf-animation-test-level) 4)
          (should (etaf-animation-active-p etaf-animation-test-shown))
          (etaf-animation-test-wait
           (lambda () (not (etaf-animation-active-p etaf-animation-test-shown))))
          (should (= 4 (etaf-value etaf-animation-test-shown)))
          (with-current-buffer buffer
            (should (string-match-p "level 4.00"
                                    (buffer-substring-no-properties
                                     (point-min) (point-max)))))
          (setf (etaf-value etaf-animation-test-level) 9)
          (etaf-animation-test-wait
           (lambda () (etaf-animation-active-p etaf-animation-test-shown)))
          (etaf-unmount (etaf-runtime-for-buffer buffer))
          (should-not (etaf-animation-active-p etaf-animation-test-shown))
          (let ((frozen (etaf-value etaf-animation-test-shown)))
            (etaf-animation-test-sleep 0.1)
            (should (equal frozen (etaf-value etaf-animation-test-shown)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))
    (should (= baseline (length timer-list))))
  (let* ((etaf-animation-enabled nil)
         (target (etaf-ref 0))
         (shown (etaf-transition target :duration 1.0)))
    (setf (etaf-value target) 5)
    (should (= 5 (etaf-value shown)))
    (should-not (etaf-animation-active-p shown))))

(ert-deftest etaf-animation-frames-cycle-and-finish ()
  "A frame sequence cycles, freezes on stop and finishes on its last frame."
  (let* ((shown (etaf-animation-frames '("a" "b" "c") :interval 0.03))
         (samples nil)
         (stop (etaf-watch shown (lambda (new _old) (push new samples)))))
    (unwind-protect
        (progn
          (etaf-animation-test-wait (lambda () (>= (length samples) 4)))
          (should (etaf-animation-active-p shown))
          (should (cl-every (lambda (value) (member value '("a" "b" "c")))
                            samples))
          (etaf-animation-stop shown)
          (should-not (etaf-animation-active-p shown)))
      (funcall stop)))
  (let ((completed 0)
        (shown nil))
    (setq shown (etaf-animation-frames ["x" "y"] :interval 0.03 :loop nil
                                       :on-complete (lambda () (cl-incf completed))))
    (etaf-animation-test-wait
     (lambda () (not (etaf-animation-active-p shown))))
    (should (equal "y" (etaf-value shown)))
    (should (= 1 completed))))

(ert-deftest etaf-animation-interpolation-easings-and-validation ()
  "Values convert over registered easings; invalid inputs signal."
  (should (= 5.0 (etaf-animation-interpolate 0 10 0.5)))
  (should (= 10 (etaf-animation-interpolate 0 10 1)))
  (should (= 3 (etaf-animation-interpolate 3 9 0)))
  (let ((middle (etaf-animation-interpolate "#000000" "#ffffff" 0.5)))
    (should (color-name-to-rgb middle))
    (should-not (equal middle "#000000"))
    (should-not (equal middle "#ffffff")))
  (should (equal "#123456" (etaf-animation-interpolate "#000000" "#123456" 1)))
  (should (equal '(lh 2.5) (etaf-animation-interpolate '(lh 1) '(lh 4) 0.5)))
  (should (equal [1.0 5.0] (etaf-animation-interpolate [0 2] [2 8] 0.5)))
  (should (equal 'unchanged (etaf-animation-interpolate 'unchanged 'other 0.5)))
  (let ((etaf-animation-interpolators
         (cons (cons (lambda (from to) (and (stringp from) (stringp to)))
                     (lambda (_from _to progress) (format "%.2f" progress)))
               etaf-animation-interpolators)))
    (should (equal "0.50" (etaf-animation-interpolate "a" "b" 0.5))))
  (dolist (name '(linear ease ease-in ease-out ease-in-out))
    (let ((function (cdr (assq name etaf-animation-easings))))
      (should (numberp (funcall function 0.0)))
      (should (numberp (funcall function 1.0)))
      (should (<= -0.001 (funcall function 0.5) 1.001))))
  (should-error (etaf-transition (etaf-ref 0) :easing 'bogus)
                :type 'etaf-animation-error)
  (should-error (etaf-transition (etaf-ref 0) :duration -1)
                :type 'etaf-animation-error)
  (should-error (etaf-animation-frames '())
                :type 'etaf-animation-error)
  (should-error (etaf-animation-frames '("a") :interval 0)
                :type 'etaf-animation-error)
  (should-error (etaf-animation-stop (etaf-ref 0))
                :type 'etaf-animation-error)
  (should-not (etaf-animation-active-p 42)))

(provide 'etaf-animation-tests)
;;; etaf-animation-tests.el ends here
