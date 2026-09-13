;;; etaf-event-forwarding-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'etaf)

(defvar etaf-forward-test--trace nil)

(defvar etaf-forward-test--inner-use nil)

(defvar etaf-forward-test--inner-disabled nil)

(defun etaf-forward-test--record (item)
  "Append ITEM to the current interaction trace."
  (setq etaf-forward-test--trace (append etaf-forward-test--trace (list item))))

(defun etaf-forward-test--dispose (buffer)
  "Unmount and kill test BUFFER."
  (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
    (etaf-unmount runtime))
  (when-let* ((live (get-buffer buffer))) (kill-buffer live)))

(etaf-define-component etaf-forward-test-leaf (&key on-press use disabled ref)
  :view (text :ref ref :role 'button :tab-index 0 :disabled disabled
              :on-press on-press :use use "Press"))

(etaf-define-component etaf-forward-test-middle ()
  :view (etaf-forward-test-leaf
         :ref 'internal
         :disabled (if (etaf-ref-p etaf-forward-test--inner-disabled)
                       (etaf-value etaf-forward-test--inner-disabled)
                     etaf-forward-test--inner-disabled)
         :use etaf-forward-test--inner-use
         :on-press (lambda () (etaf-forward-test--record 'inner))))

(etaf-define-component etaf-forward-test-business (&key on-change)
  :view (text :role 'checkbox :aria-checked nil
              :on-press (let ((change on-change))
                          (lambda ()
                            (etaf-forward-test--record 'business)
                            (funcall change t)))
              "Toggle"))

(ert-deftest etaf-forward-disabled-or-recomputes-and-guards-public-input ()
  "Outer nil never enables an internally disabled Host; later inputs recover."
  (let* ((buffer " *etaf-forward-disabled*")
        (outer-disabled (etaf-ref nil))
        (inner-disabled (etaf-ref t))
        (etaf-forward-test--inner-disabled inner-disabled)
        (etaf-forward-test--trace nil))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (lambda ()
             (etaf-view (etaf-forward-test-middle
                         :ref 'target :disabled (etaf-value outer-disabled)))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (should (plist-get (etaf-runtime-host-props-for runtime 'target)
                               :disabled))
            (should-error (etaf-dispatch-event runtime 'target 'press)
                          :type 'etaf-event-error)
            (should-error (etaf-focus runtime 'target) :type 'etaf-event-error)
            (setf (etaf-value inner-disabled) nil)
            (etaf-dispatch-event runtime 'target 'press)
            (should (equal etaf-forward-test--trace '(inner)))
            (setf (etaf-value outer-disabled) t)
            (should-error (etaf-dispatch-event runtime 'target 'press)
                          :type 'etaf-event-error)
            (setf (etaf-value outer-disabled) nil)
            (etaf-dispatch-event runtime 'target 'press)
            (should (equal etaf-forward-test--trace '(inner inner)))))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-business-conversion-precedes-subscriptions ()
  "A consumed change prop remains the business conversion for one press."
  (let ((buffer " *etaf-forward-conversion*")
        (etaf-forward-test--trace nil) (value nil))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-forward-test-business
             :ref 'target
             :on-change (lambda (next)
                          (setq value next)
                          (etaf-forward-test--record 'change))
             :on-press (lambda () (etaf-forward-test--record 'outer))
             :use (etaf-behavior-create
                   'observer :on-press
                   (lambda () (etaf-forward-test--record 'behavior))))))
          (etaf-dispatch-event (etaf-runtime-for-buffer buffer) 'target 'press)
          (should value)
          (should (equal etaf-forward-test--trace
                         '(business change outer behavior))))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-wrapper-duplicate-behaviors-fail-before-install ()
  "Do not lose duplicate names when declared use props consume fallthrough."
  (let* ((buffer " *etaf-forward-duplicate-use*")
         (installs 0)
         (behavior (etaf-behavior-create
                    'duplicate :install (lambda () (cl-incf installs) nil)))
         (etaf-forward-test--inner-use behavior))
    (unwind-protect
        (progn
          (should-error
           (etaf-mount buffer (etaf-view (etaf-forward-test-middle :use behavior)))
           :type 'etaf-behavior-error)
          (should (zerop installs)))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-failed-callback-stops-outer-subscriptions ()
  "An inner callback error stops outer subscriptions and Behaviors."
  (let ((buffer " *etaf-forward-callback-failure*")
        (etaf-forward-test--trace nil))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-forward-test-business
             :ref 'target :on-change (lambda (_) (error "change failed"))
             :on-press (lambda () (etaf-forward-test--record 'outer))
             :use (etaf-behavior-create
                   'observer :on-press
                   (lambda () (etaf-forward-test--record 'behavior))))))
          (should-error
           (etaf-dispatch-event (etaf-runtime-for-buffer buffer) 'target 'press))
          (should (equal etaf-forward-test--trace '(business))))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-disabled-behavior-never-installs ()
  "Final disabled state, including Behavior defaults, precedes installation."
  (let ((buffer " *etaf-forward-behavior-disabled*") (installs 0))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (text :ref 'target :disabled nil
                  :use (list
                        (etaf-behavior-create
                         'first :install (lambda () (cl-incf installs) nil))
                        (etaf-behavior-create 'disabled :disabled t))
                  "Disabled")))
          (should (zerop installs))
          (should (plist-get (etaf-runtime-host-props-for
                              (etaf-runtime-for-buffer buffer) 'target)
                             :disabled)))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-behavior-disabled-transitions-and-rollback ()
  "Commit disables clean up once; failed disables preserve the old resource."
  (let ((buffer " *etaf-forward-behavior-transition*")
        (mode (etaf-ref 'enabled))
        (installs 0) (cleanups 0))
    (unwind-protect
        (let ((behavior (etaf-behavior-create
                         'resource :install
                         (lambda () (cl-incf installs)
                           (lambda () (cl-incf cleanups))))))
          (etaf-mount
           buffer
           (lambda ()
             (etaf-view
              (column
               (text :ref 'target :use behavior
                     :disabled (not (eq (etaf-value mode) 'enabled)) "Target")
               (text (expr (if (eq (etaf-value mode) 'failed)
                               (error "later sibling failed") "OK")))))))
          (should (= installs 1))
          (should-error (setf (etaf-value mode) 'failed))
          (should (= cleanups 0))
          (should-not (plist-get (etaf-runtime-host-props-for
                                  (etaf-runtime-for-buffer buffer) 'target)
                                 :disabled))
          (setf (etaf-value mode) 'disabled)
          (should (= cleanups 1))
          (setf (etaf-value mode) 'enabled)
          (should (= installs 2))
          (etaf-unmount (etaf-runtime-for-buffer buffer))
          (should (= cleanups 2)))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-failed-enable-disposes-only-candidate-behavior ()
  "A failed enable cleans its new resource while committed Host stays disabled."
  (let ((buffer " *etaf-forward-enable-rollback*")
        (mode (etaf-ref 'disabled)) (installs 0) (cleanups 0))
    (unwind-protect
        (let ((behavior
               (etaf-behavior-create
                'resource :install
                (lambda () (cl-incf installs)
                  (lambda () (cl-incf cleanups))))))
          (etaf-mount
           buffer
           (etaf-view
            (column
             (text :ref 'target :use behavior
                   :disabled (eq (etaf-value mode) 'disabled) "Target")
             (text (expr (if (eq (etaf-value mode) 'failed)
                             (error "later sibling failed") "OK"))))))
          (should (zerop installs))
          (should-error (setf (etaf-value mode) 'failed))
          (should (= installs 1))
          (should (= cleanups 1))
          (should (plist-get (etaf-runtime-host-props-for
                              (etaf-runtime-for-buffer buffer) 'target)
                             :disabled))
          (setf (etaf-value mode) 'enabled)
          (should (= installs 2))
          (etaf-unmount (etaf-runtime-for-buffer buffer))
          (should (= cleanups 2)))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-component-overlay-promotes-behavior-lifetime ()
  "A locally enabled Component owns its installed Behavior through teardown."
  (let ((buffer " *etaf-forward-overlay-behavior*")
        (disabled (etaf-ref t)) (installs 0) (cleanups 0))
    (unwind-protect
        (let ((behavior
               (etaf-behavior-create
                'resource :install
                (lambda () (cl-incf installs)
                  (lambda () (cl-incf cleanups))))))
          ;; Passing a View value keeps dependency ownership on the Component
          ;; input effect, exercising local overlay instead of Root rebuild.
          (etaf-mount buffer
                      (etaf-view (etaf-forward-test-leaf
                                  :ref 'target :use behavior
                                  :disabled (etaf-value disabled))))
          (should (zerop installs))
          (setf (etaf-value disabled) nil)
          (should (= installs 1))
          (should (zerop cleanups))
          (setf (etaf-value disabled) t)
          (should (= cleanups 1))
          (setf (etaf-value disabled) nil)
          (should (= installs 2))
          (etaf-unmount (etaf-runtime-for-buffer buffer))
          (should (= cleanups 2)))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-component-overlay-removes-use-resources ()
  "Changing or removing use retires obsolete names on a retained Host."
  (let ((buffer " *etaf-forward-overlay-use*")
        (use (etaf-ref nil)) (installs 0) (cleanups 0))
    (unwind-protect
        (let* ((install (lambda () (cl-incf installs)
                          (lambda () (cl-incf cleanups))))
               (first (etaf-behavior-create 'first :install install))
               (second (etaf-behavior-create 'second :install install)))
          (setf (etaf-value use) first)
          (etaf-mount
           buffer (etaf-view (etaf-forward-test-leaf
                             :ref 'target :use (etaf-value use))))
          (should (= installs 1))
          (setf (etaf-value use) second)
          (should (= installs 2))
          (should (= cleanups 1))
          (setf (etaf-value use) nil)
          (should (= cleanups 2))
          (etaf-unmount (etaf-runtime-for-buffer buffer))
          (should (= cleanups 2)))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-carried-component-keeps-behavior-resource ()
  "A Root update carrying an unchanged Component retains its Host resource."
  (let ((buffer " *etaf-forward-carried-behavior*")
        (version (etaf-ref 0)) (installs 0) (cleanups 0))
    (unwind-protect
        (let ((behavior
               (etaf-behavior-create
                'resource :install
                (lambda () (cl-incf installs)
                  (lambda () (cl-incf cleanups))))))
          (etaf-mount
           buffer
           (lambda ()
             (etaf-value version)
             (etaf-view
              (column
               (etaf-forward-test-leaf :ref 'target :use behavior)))))
          (should (= installs 1))
          (setf (etaf-value version) 1)
          (should (= installs 1))
          (should (zerop cleanups))
          (etaf-unmount (etaf-runtime-for-buffer buffer))
          (should (= cleanups 1)))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-callback-snapshot-changes-only-after-commit ()
  "Composed subscriptions preserve committed scalar props after render fails."
  (let ((buffer " *etaf-forward-callback-commit*")
        (version (etaf-ref 'a)) (seen nil)
        (etaf-forward-test--trace nil))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (column
             (etaf-forward-test-middle
              :ref 'target
              :on-press (let ((snapshot (etaf-value version)))
                          (lambda () (push snapshot seen))))
             (text (expr (if (eq (etaf-value version) 'failed)
                             (error "later sibling failed") "OK"))))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-dispatch-event runtime 'target 'press)
            (should-error (setf (etaf-value version) 'failed))
            (etaf-dispatch-event runtime 'target 'press)
            (setf (etaf-value version) 'b)
            (etaf-dispatch-event runtime 'target 'press)
            (should (equal seen '(b a a)))
            (should (equal etaf-forward-test--trace '(inner inner inner)))))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-focused-control-follows-changing-layout ()
  "Repeated keyboard activation follows a retained control after width changes."
  (let ((buffer " *etaf-forward-focus-layout*") (page (etaf-ref 9)))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (row
             (text (expr (format "Page %s" (etaf-value page))))
             (text :ref 'next :role 'button :tab-index 0
                   :on-press (lambda () (cl-incf (etaf-value page))) "Next"))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-focus runtime 'next)
            (etaf-activate runtime)
            (should (= (etaf-value page) 10))
            (should (eq (etaf-focused-host-ref runtime) 'next))
            (with-current-buffer buffer
              (should (= (point) (etaf-host-ref-position runtime 'next))))
            (etaf-activate runtime)
            (should (= (etaf-value page) 11))))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-layout-update-respects-manually-moved-point ()
  "A layout commit must not pull point back after the user leaves a control."
  (let ((buffer " *etaf-forward-focus-manual*") (page (etaf-ref 9)))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (row
             (text (expr (format "Page %s" (etaf-value page))))
             (text :ref 'next :role 'button :tab-index 0 "Next"))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-focus runtime 'next)
            (with-current-buffer buffer (goto-char (point-min)))
            (setf (etaf-value page) 10)
            (with-current-buffer buffer
              (should (= (point) (point-min)))
              (should-not (= (point) (etaf-host-ref-position runtime 'next))))))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-focused-point-survives-failed-publication ()
  "A failed candidate retains the old focus and point; the next commit follows."
  (let ((buffer " *etaf-forward-focus-rollback*") (page (etaf-ref 9)))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (row
             (text (expr (format "Page %s" (etaf-value page))))
             (text :ref 'next :role 'button :tab-index 0 "Next")
             (text (expr (if (= (etaf-value page) 10)
                             (error "later rendering failed") "OK"))))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (generation (etaf-runtime-current-generation runtime))
                 (position (etaf-host-ref-position runtime 'next)))
            (etaf-focus runtime 'next)
            (should-error (setf (etaf-value page) 10))
            (should (eq generation (etaf-runtime-current-generation runtime)))
            (should (eq (etaf-focused-host-ref runtime) 'next))
            (with-current-buffer buffer (should (= (point) position)))
            (setf (etaf-value page) 11)
            (with-current-buffer buffer
              (should (= (point) (etaf-host-ref-position runtime 'next))))))
      (etaf-forward-test--dispose buffer))))

(provide 'etaf-event-forwarding-tests)
;;; etaf-event-forwarding-tests.el ends here
