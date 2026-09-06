;;; etaf-gui-verifier-tests.el --- Generic GUI scenario engine tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacs-gui-verifier)

(ert-deftest etaf-gui-verifier-runs-and-settles-without-raising-frame ()
  "Actions and settled checkpoints must complete without raising Emacs."
  (let ((context (etaf-gui-verifier--context-create))
        (settle-checks 0)
        events)
    (cl-letf (((symbol-function 'raise-frame)
               (lambda (&rest _arguments)
                 (error "GUI verifier must preserve application focus")))
              ((symbol-function 'etaf-gui-verifier--checkpoint)
               (lambda (_context _action-id phase _screenshot &optional _extra)
                 (push phase events))))
      (etaf-gui-verifier--run-action
       context
       (etaf-gui-verifier-action-create
        :id "background-action" :settle-interval 0.001
        :execute
        (lambda (current)
          (etaf-gui-verifier-context-put current 'executed t)
          (push 'execute events))
        :settled-p
        (lambda (current)
          (should (etaf-gui-verifier-context-get current 'executed))
          (cl-incf settle-checks)
          (push 'settle events)
          t)
        :assertions
        (lambda (_current)
          (push 'assertions events)
          (list (etaf-gui-verifier-assert "action-settled" t))))))
    (should (= 1 (etaf-gui-verifier-context-action-count context)))
    (should (= 2 settle-checks))
    (should
     (equal '("before-action" execute "after-action" settle settle
              assertions "after-redisplay")
            (nreverse events)))))

(ert-deftest etaf-gui-verifier-composes-generic-scenario-actions ()
  "The engine should own ordering while adapters own actions and assertions."
  (let ((buffer (generate-new-buffer " *etaf-gui-verifier-test*"))
        events checkpoints finished (settle-checks 0))
    (unwind-protect
        (cl-letf
            (((symbol-function 'emacs-dynamic-ui-verification-start)
              (lambda (_directory run-id _claim phases)
                (push (list 'start run-id phases) events)))
             ((symbol-function 'emacs-dynamic-ui-verification-checkpoint)
              (lambda (action phase adapter assertions screenshot)
                (push (list action phase adapter assertions screenshot)
                      checkpoints)))
             ((symbol-function 'emacs-dynamic-ui-verification-finish)
              (lambda (completed adapter)
                (setq finished (list completed adapter)))))
          (let* ((scenario
                  (etaf-gui-verifier-scenario-create
                   :name "generic"
                   :claim "generic claim"
                   :initialize
                   (lambda (context)
                     (etaf-gui-verifier-context-select-buffer context buffer))
                   :invariants
                   (lambda (context)
                     (list
                      (etaf-gui-verifier-assert
                       "buffer-live"
                       (buffer-live-p
                        (etaf-gui-verifier-context-target-buffer context)))))
                   :adapter
                   (lambda (context)
                     (list
                      (cons 'size
                            (with-current-buffer
                                (etaf-gui-verifier-context-target-buffer context)
                              (buffer-size)))))
                   :actions
                   (list
                    (etaf-gui-verifier-action-create
                     :id "insert-a" :settle-interval 0.001
                     :execute
                     (lambda (context)
                       (with-current-buffer
                           (etaf-gui-verifier-context-target-buffer context)
                         (insert "A")))
                     :settled-p
                     (lambda (_context)
                       (>= (cl-incf settle-checks) 2))
                     :assertions
                     (lambda (context)
                       (list
                        (etaf-gui-verifier-assert
                         "one-character"
                         (= 1
                            (with-current-buffer
                                (etaf-gui-verifier-context-target-buffer context)
                              (buffer-size))))))
                     :screenshot t)
                    (etaf-gui-verifier-action-create
                     :id "insert-b"
                     :execute
                     (lambda (context)
                       (with-current-buffer
                           (etaf-gui-verifier-context-target-buffer context)
                         (insert "B")))
                     :settled-p (lambda (_context) t)))
                   :completion
                   (lambda (context)
                     (= 2 (etaf-gui-verifier-context-action-count context)))))
                 (context (etaf-gui-verifier-run scenario "/tmp/generic")))
            (should (= 2 (etaf-gui-verifier-context-action-count context)))
            (should (equal "AB" (with-current-buffer buffer (buffer-string))))
            (should (car finished))
            (should (= settle-checks 3))
            (should (= 6 (length checkpoints)))
            (should
             (equal
              '("before-action" "after-action" "after-redisplay"
                "before-action" "after-action" "after-redisplay")
              (mapcar #'cadr (nreverse checkpoints))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-gui-verifier-rejects-invalid-settle-contracts ()
  "Every action should have a bounded, non-busy settle contract."
  (let ((context (etaf-gui-verifier--context-create)))
    (dolist
        (action
         (list
          (etaf-gui-verifier-action-create :id "missing")
          (etaf-gui-verifier-action-create
           :id "timeout" :settled-p (lambda (_context) t)
           :settle-timeout 0)
          (etaf-gui-verifier-action-create
           :id "interval" :settled-p (lambda (_context) t)
           :settle-interval 0)))
      (should-error (etaf-gui-verifier--settle-action context action)))))

(ert-deftest etaf-gui-verifier-timeout-finishes-false-and-propagates ()
  "A settle timeout should finish incomplete and preserve its error."
  (let ((buffer (generate-new-buffer " *etaf-gui-timeout-test*"))
        finished)
    (unwind-protect
        (cl-letf
            (((symbol-function 'emacs-dynamic-ui-verification-start)
              (lambda (&rest _arguments) nil))
             ((symbol-function 'emacs-dynamic-ui-verification-checkpoint)
              (lambda (&rest _arguments) nil))
             ((symbol-function 'emacs-dynamic-ui-verification-finish)
              (lambda (completed adapter)
                (setq finished (list completed adapter)))))
          (let* ((scenario
                  (etaf-gui-verifier-scenario-create
                   :name "timeout"
                   :claim "timeout must fail closed"
                   :initialize
                   (lambda (context)
                     (etaf-gui-verifier-context-select-buffer context buffer))
                   :actions
                   (list
                    (etaf-gui-verifier-action-create
                     :id "never-settles"
                     :execute (lambda (_context) nil)
                     :settled-p (lambda (_context) nil)
                     :settle-timeout 0.003
                     :settle-interval 0.001))))
                 (error-data
                  (should-error
                   (etaf-gui-verifier-run scenario "/tmp/timeout"))))
            (should
             (string-match-p
              "did not settle" (error-message-string error-data)))
            (should finished)
            (should-not (car finished))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'etaf-gui-verifier-tests)
;;; etaf-gui-verifier-tests.el ends here
