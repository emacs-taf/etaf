;;; etaf-interaction-contract-tests.el --- Interaction contract tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Lock the M0b Action, Behavior, and local event composition contract.

;;; Code:

(require 'ert)
(require 'etaf)

(defun etaf-interaction-test--dispose-buffer (buffer-name)
  "Unmount and kill BUFFER-NAME when either still exists."
  (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
    (etaf-unmount runtime))
  (when-let* ((buffer (get-buffer buffer-name)))
    (kill-buffer buffer)))

(ert-deftest etaf-interaction-duplicate-behavior-fails-before-install ()
  "Reject duplicate names on one Host without running either installer."
  (let ((buffer-name " *etaf-duplicate-behavior-contract*")
        (installs 0))
    (unwind-protect
        (let ((first
               (etaf-behavior-create
                'duplicate
                :install (lambda () (cl-incf installs) #'ignore)))
              (second
               (etaf-behavior-create
                'duplicate
                :install (lambda () (cl-incf installs) #'ignore))))
          (should-error
           (etaf-mount
            buffer-name
            (lambda ()
              (etaf--view-call
               'text (list :ref 'target :use (list first second))
               (list "target"))))
           :type 'etaf-behavior-error)
          (should (zerop installs)))
      (etaf-interaction-test--dispose-buffer buffer-name))))

(ert-deftest etaf-interaction-behaviors-compose-in-declaration-order ()
  "Preserve installer/event order, first-wins props, and one cleanup each."
  (let ((buffer-name " *etaf-behavior-order-contract*")
        install-order event-order cleanup-counts)
    (unwind-protect
        (let* ((first
                (etaf-behavior-create
                 'first
                 :class "first"
                 :on-press (lambda () (setq event-order
                                             (append event-order '(first))))
                 :install (lambda ()
                            (setq install-order (append install-order '(first)))
                            (lambda () (push 'first cleanup-counts)))))
               (second
                (etaf-behavior-create
                 'second
                 :class "second"
                 :on-press (lambda () (setq event-order
                                             (append event-order '(second))))
                 :install (lambda ()
                            (setq install-order (append install-order '(second)))
                            (lambda () (push 'second cleanup-counts))))))
          (etaf-mount
           buffer-name
           (lambda ()
             (etaf--view-call
              'text
              (list :ref 'target :use (list first second)
                    :on-press
                    (lambda () (setq event-order (append event-order '(host)))))
              (list "target"))))
          (let ((runtime (etaf-runtime-for-buffer buffer-name)))
            (should (equal install-order '(first second)))
            (should (equal (plist-get
                            (etaf-runtime-host-props-for runtime 'target)
                            :class)
                           "first"))
            (etaf-dispatch-event runtime 'target 'press)
            (should (equal event-order '(host first second)))
            (etaf-unmount runtime))
          (should (= 1 (cl-count 'first cleanup-counts)))
          (should (= 1 (cl-count 'second cleanup-counts))))
      (etaf-interaction-test--dispose-buffer buffer-name))))

(ert-deftest etaf-interaction-callback-failure-short-circuits-behaviors ()
  "Stop Behavior callbacks after an earlier callback signals."
  (let ((buffer-name " *etaf-behavior-failure-contract*") trace)
    (unwind-protect
        (let ((first
               (etaf-behavior-create
                'first :on-press
                (lambda () (push 'first trace) (error "first failed"))))
              (second
               (etaf-behavior-create
                'second :on-press (lambda () (push 'second trace)))))
          (etaf-mount
           buffer-name
           (lambda ()
             (etaf--view-call
              'text
              (list :ref 'target :use (list first second)
                    :on-press (lambda () (push 'host trace) (error "host failed")))
              (list "target"))))
          (should-error
           (etaf-dispatch-event (etaf-runtime-for-buffer buffer-name)
                                'target 'press))
          (should (equal trace '(host)))
          (etaf-unmount (etaf-runtime-for-buffer buffer-name))
          (setq trace nil)
          (etaf-mount
           buffer-name
           (lambda ()
             (etaf--view-call
              'text
              (list :ref 'target :use (list first second)
                    :on-press (lambda () (push 'host trace)))
              (list "target"))))
          (should-error
           (etaf-dispatch-event (etaf-runtime-for-buffer buffer-name)
                                'target 'press))
          (should (equal trace '(first host))))
      (etaf-interaction-test--dispose-buffer buffer-name))))

(ert-deftest etaf-interaction-stable-installer-identity-cleans-up-once ()
  "Reuse an identical installer and run its cleanup exactly once."
  (let ((buffer-name " *etaf-behavior-identity-contract*")
        (trigger (etaf-ref 0))
        (installs 0)
        (cleanups 0))
    (unwind-protect
        (let* ((installer
                (lambda ()
                  (cl-incf installs)
                  (lambda () (cl-incf cleanups))))
               (behavior
                (etaf-behavior-create 'stable :install installer)))
          (etaf-mount
           buffer-name
           (lambda ()
             (etaf--view-call
              'text
              (list :ref 'target :use behavior
                    :aria-label (format "version-%d" (etaf-value trigger)))
              (list "target"))))
          (should (= installs 1))
          (setf (etaf-value trigger) 1)
          (should (= installs 1))
          (should (zerop cleanups))
          (etaf-unmount (etaf-runtime-for-buffer buffer-name))
          (should (= cleanups 1)))
      (etaf-interaction-test--dispose-buffer buffer-name))))

(ert-deftest etaf-interaction-events-do-not-capture-or-bubble ()
  "Dispatch only the callback owned by the exact Host reference."
  (let ((buffer-name " *etaf-local-event-contract*") trace)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (lambda ()
             (etaf--view-call
              'column
              (list :ref 'parent :on-press (lambda () (push 'parent trace)))
              (list
               (etaf--view-call
                'text
                (list :ref 'child :on-press (lambda () (push 'child trace)))
                (list "child"))))))
          (let ((runtime (etaf-runtime-for-buffer buffer-name)))
            (etaf-dispatch-event runtime 'child 'press)
            (should (equal trace '(child)))
            (setq trace nil)
            (etaf-dispatch-event runtime 'parent 'press)
            (should (equal trace '(parent)))))
      (etaf-interaction-test--dispose-buffer buffer-name))))

(ert-deftest etaf-action-duplicate-registration-errors-by-default ()
  "Keep the first Action when another application claims the same name."
  (let ((name 'etaf-interaction-test-cross-app-action)
        (first (lambda (_runtime) 'first))
        (second (lambda (_runtime) 'second)))
    (unwind-protect
        (progn
          (etaf-action-register name first)
          (should-error (etaf-action-register name second)
                        :type 'etaf-action-error)
          (should (eq first
                      (etaf-action-spec-function
                       (gethash name etaf--action-registry)))))
      (etaf-action-undefine name))))

(ert-deftest etaf-action-redefine-boundary-affects-only-future-dispatch ()
  "Replace name lookup explicitly without flushing a mounted Runtime."
  (let ((buffer-name " *etaf-action-redefine-contract*")
        (name 'etaf-interaction-test-future-action)
        (first-calls 0)
        (second-calls 0))
    (unwind-protect
        (progn
          (etaf-action-register
           name (lambda (_runtime) (cl-incf first-calls)))
          (etaf-mount
           buffer-name
           (lambda ()
             (etaf--view-call
              'text
              (list :ref 'target
                    :on-press (lambda () (etaf-dispatch name)))
              (list "target"))))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-current-generation runtime)))
            (etaf-dispatch-event runtime 'target 'press)
            (should (= first-calls 1))
            (etaf-action-redefine-run
             (lambda ()
               (etaf-action-register
                name (lambda (_runtime) (cl-incf second-calls)))))
            (should (eq generation
                        (etaf-runtime-current-generation runtime)))
            (should (= first-calls 1))
            (should (zerop second-calls))
            (etaf-dispatch-event runtime 'target 'press)
            (should (= second-calls 1))))
      (etaf-action-undefine name)
      (etaf-interaction-test--dispose-buffer buffer-name))))

(ert-deftest etaf-action-reload-requires-explicit-redefine-boundary ()
  "Make repeated authoring definitions explicit and dynamically scoped."
  (let ((name 'etaf-interaction-test-reload-action)
        (function-symbol 'etaf-interaction-test-reload-action--etaf-action))
    (unwind-protect
        (progn
          (eval '(etaf-action-define etaf-interaction-test-reload-action
                     (_runtime)
                   'first)
                t)
          (should-error
           (eval '(etaf-action-define etaf-interaction-test-reload-action
                      (_runtime)
                    'unintended)
                 t)
           :type 'etaf-action-error)
          (should
           (eq 'first
               (funcall
                (etaf-action-spec-function
                 (gethash name etaf--action-registry))
                nil)))
          (etaf-action-redefine-run
           (lambda ()
             (eval '(etaf-action-define etaf-interaction-test-reload-action
                        (_runtime)
                      'second)
                   t)))
          (should
           (eq 'second
               (funcall
                (etaf-action-spec-function
                 (gethash name etaf--action-registry))
                nil)))
          (should-error
           (eval '(etaf-action-define etaf-interaction-test-reload-action
                      (_runtime)
                    'unintended)
                 t)
           :type 'etaf-action-error)
          (should
           (eq 'second
               (funcall
                (etaf-action-spec-function
                 (gethash name etaf--action-registry))
                nil))))
      (etaf-action-undefine name)
      (when (fboundp function-symbol)
        (fmakunbound function-symbol)))))

(provide 'etaf-interaction-contract-tests)

;;; etaf-interaction-contract-tests.el ends here
