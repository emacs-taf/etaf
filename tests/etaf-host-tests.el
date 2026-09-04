;;; etaf-host-tests.el --- M3a Host authority gates -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'cl-lib)
(require 'ert)
(require 'etaf)
(require 'tp-transaction)

(defvar etaf-host-test-unmount-error-p nil)

(etaf-define-component etaf-host-test-component (&key source fail-unmount)
  "Render SOURCE and optionally fail the public unmounted hook."
  :setup
  (progn
    (etaf-on-unmounted
     (lambda ()
       (when (or fail-unmount etaf-host-test-unmount-error-p)
         (error "injected Host retirement failure"))))
    nil)
  :view
  (text :ref 'host-value (expr (format "host=%s" (etaf-value source)))))

(ert-deftest etaf-host-initial-marker-attaches-on-final-accept-only ()
  "Initial v2 mount uses one marker; ordinary update uses zero markers."
  (let ((buffer-name " *etaf-host-marker-test*")
        (source (etaf-ref 0))
        lookup-during-stage
        (original-stage (symbol-function 'etaf-host-authority-stage-attach)))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'etaf-host-authority-stage-attach)
                     (lambda (authority)
                       (setq lookup-during-stage
                             (etaf-runtime-for-buffer buffer-name))
                       (funcall original-stage authority))))
            (etaf-mount
             buffer-name
             (etaf--view-call 'etaf-host-test-component
                              (list :source source) nil)))
          (should-not lookup-during-stage)
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (authority (etaf-runtime-host-authority runtime)))
            (should (etaf-host-authority-attached-p authority))
            (should (= (etaf-host-authority-version authority) 1))
            (should (= (tp-committed-success-outcome-marker-count
                        tp--last-transaction-outcome)
                       1))
            (setf (etaf-value source) 1)
            (should (= (tp-committed-success-outcome-marker-count
                        tp--last-transaction-outcome)
                       0))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-host-initial-faults-restore-detached-authority ()
  "Precommit and final-accept faults restore Host and Ebox initial state."
  (dolist (phase '(precommit final-accept))
    (let ((buffer-name
           (format " *etaf-host-%s-fault-test*" phase))
          captured-authority
          (source (etaf-ref 0))
          (original-create (symbol-function 'etaf-host-authority-create))
          (original-precommit
           (symbol-function 'tp--run-transaction-precommit-functions))
          (original-accept (symbol-function 'accept-change-group)))
      (unwind-protect
          (cl-letf
              (((symbol-function 'etaf-host-authority-create)
                (lambda (&rest arguments)
                  (setq captured-authority (apply original-create arguments))))
               ((symbol-function 'tp--run-transaction-precommit-functions)
                (if (eq phase 'precommit)
                    (lambda ()
                      (funcall original-precommit)
                      (error "injected Host precommit failure"))
                  original-precommit))
               ((symbol-function 'accept-change-group)
                (if (eq phase 'final-accept)
                    (lambda (_group)
                      (error "injected Host final-accept failure"))
                  original-accept)))
            (should-error
             (etaf-mount
              buffer-name
              (etaf--view-call 'etaf-host-test-component
                               (list :source source) nil))
             :type 'error)
            (should (etaf-host-authority-p captured-authority))
            (should (eq (etaf-host-authority-state captured-authority)
                        'detached))
            (should (zerop
                     (etaf-host-authority-version captured-authority)))
            (should-not (etaf-runtime-for-buffer buffer-name))
            (should-not
             (ebox-surface-buffer-mounted-p (get-buffer buffer-name))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
          (etaf-unmount runtime))
        (when-let* ((buffer (get-buffer buffer-name)))
          (kill-buffer buffer))))))

(ert-deftest etaf-host-postaccept-report-fault-still-finishes-attach ()
  "Ebox report-finalization failure cannot roll back an accepted Host."
  (let ((buffer-name " *etaf-host-report-postaccept-test*")
        (source (etaf-ref 0))
        (rollback-count 0)
        (original-rollback
         (symbol-function 'etaf-semantic-candidate-rollback)))
    (unwind-protect
        (progn
          (cl-letf
              (((symbol-function 'ebox-surface--participant-complete)
                (lambda (&rest _arguments)
                  (error "injected initial report finalization fault")))
               ((symbol-function 'etaf-semantic-candidate-rollback)
                (lambda (candidate)
                  (cl-incf rollback-count)
                  (funcall original-rollback candidate))))
            (etaf-mount
             buffer-name
             (etaf--view-call 'etaf-host-test-component
                              (list :source source) nil)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (authority (etaf-runtime-host-authority runtime)))
            (should runtime)
            (should (etaf-host-authority-attached-p authority))
            (should (zerop rollback-count))
            (should (ebox-surface-buffer-mounted-p
                     (get-buffer buffer-name)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-host-unmount-invalidates-before-component-cleanup ()
  "Explicit unmount invalidates Host token before any Component hook runs."
  (let ((buffer-name " *etaf-host-unmount-boundary-test*")
        (source (etaf-ref 0))
        checked)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf--view-call 'etaf-host-test-component
                            (list :source source) nil))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (authority (etaf-runtime-host-authority runtime))
                 (original
                  (symbol-function 'etaf--runtime-dispose-instance)))
            (cl-letf (((symbol-function 'etaf--runtime-dispose-instance)
                       (lambda (&rest arguments)
                         (should-not (etaf-host-authority-token authority))
                         (should (eq (etaf-host-authority-state authority)
                                     'detached-retiring))
                         (setq checked t)
                         (apply original arguments))))
              (etaf-unmount runtime))
            (should checked)
            (should (eq (etaf-host-authority-state authority) 'terminal))
            (should-not (etaf-runtime-for-buffer buffer-name))
            (should (eq (etaf--runtime-unmount-now runtime) runtime))
            (should-error (etaf-unmount runtime) :type 'etaf-runtime-error)))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-host-kill-contains-user-cleanup-failure ()
  "Buffer kill never rethrows user cleanup after Host authority invalidation."
  (let ((buffer-name " *etaf-host-kill-contained-test*")
        (source (etaf-ref 0))
        runtime authority)
    (setq etaf-host-test-unmount-error-p nil)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf--view-call 'etaf-host-test-component
                            (list :source source :fail-unmount t) nil))
          (setq runtime (etaf-runtime-for-buffer buffer-name)
                authority (etaf-runtime-host-authority runtime))
          (kill-buffer (get-buffer buffer-name))
          (should (eq (etaf-host-authority-state authority) 'terminal))
          (should-not (etaf-runtime-mounted-p runtime))
          (should-not (gethash (etaf-runtime-mount-epoch runtime)
                               etaf--runtime-route-registry)))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-host-detach-makes-route-token-stale ()
  "A detached Host route cannot schedule later source changes."
  (let ((buffer-name " *etaf-host-stale-route-test*")
        (source (etaf-ref 0))
        runtime route)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf--view-call 'etaf-host-test-component
                            (list :source source) nil))
          (setq runtime (etaf-runtime-for-buffer buffer-name)
                route (etaf-runtime-route-token runtime))
          (etaf-unmount runtime)
          (should-not
           (etaf-host-authority-accepts-token-p
            (etaf-runtime-host-authority runtime)
            (etaf-runtime-route-authority-token route)))
          (setf (etaf-value source) 1)
          (should-not (etaf-runtime-pending-p runtime)))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(provide 'etaf-host-tests)

;;; etaf-host-tests.el ends here
