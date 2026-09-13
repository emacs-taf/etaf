;;; etaf-tracked-props-tests.el --- Tracked component inputs -*- lexical-binding: t; -*-

;;; Commentary:
;; Setup-derived values follow successful input updates and lifecycle.

;;; Code:
(require 'ert)
(require 'etaf)

(etaf-define-component etaf-test-tracked-input (&key (label "Default") report invalid)
  :setup
  (let* ((input (etaf-prop 'label))
         (derived (etaf-computed (lambda () (concat (etaf-value input) "!")))))
    (funcall report 'source input)
    (etaf-watch input (lambda (next old) (funcall report 'watch next old)))
    (etaf-watch derived (lambda (next old) (funcall report 'derived next old)))
    derived)
  :render
  (let ((derived (etaf-state)))
    (etaf-view
     (box :ref 'target :on-press
          (lambda () (funcall report 'press label (etaf-value derived)))
       (text (expr (etaf-value derived)))
       (text (expr (if invalid 42 "")))))))

(ert-deftest etaf-tracked-props-follow-publication-and-disposal ()
  "Computed and watch inputs track successful props without losing snapshots."
  (let ((buffer (generate-new-buffer " *tracked-props*"))
        (label (etaf-ref "A"))
        events source)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (lambda ()
             (etaf-view
              (etaf-test-tracked-input
               :label (etaf-value label)
               :report (lambda (kind &rest args)
                         (if (eq kind 'source) (setq source (car args))
                           (push (cons kind args) events)))))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (should (equal "A!" (with-current-buffer buffer (buffer-string))))
            (should-error (etaf-set-value source "bad"))
            (setf (etaf-value label) "B")
            (should (equal "B!" (with-current-buffer buffer (buffer-string))))
            (should (member '(watch "B" "A") events))
            (should (member '(derived "B!" "A!") events))
            (etaf-dispatch-event runtime 'target 'press)
            (should (equal '(press "B" "B!") (car events)))
            (let ((before events))
              (should-error (setf (etaf-value label) 42))
              (should (eq before events))
              (should (equal "B" (etaf-value source)))
              (etaf-dispatch-event runtime 'target 'press)
              (should (equal '(press "B" "B!") (car events))))
            (setf (etaf-value label) "C")
            (should (equal "C!" (with-current-buffer buffer (buffer-string))))
            (should (member '(watch "C" "B") events))
            (should (member '(derived "C!" "B!") events))
            (etaf-unmount runtime)
            (should-error (etaf-value source))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(etaf-define-component etaf-test-tracked-child (&key source)
  :view (text (expr (etaf-value source))))

(etaf-define-component etaf-test-tracked-parent (&key label report)
  :setup
  (let* ((input (etaf-prop :label))
         (derived (etaf-computed (lambda () (concat (etaf-value input) "!")))))
    (etaf-watch input (lambda (next old) (funcall report next old)))
    derived)
  :view (etaf-test-tracked-child :source (etaf-state)))

(ert-deftest etaf-tracked-props-reach-retained-descendants ()
  "Both root and local input updates publish nested computed consumers together."
  (dolist (root-input '(nil t))
    (let ((buffer (generate-new-buffer " *tracked-descendant*"))
          (label (etaf-ref "A"))
          observations)
      (unwind-protect
          (progn
            (etaf-mount
             buffer
             (if root-input
                 (lambda ()
                   (etaf-node 'etaf-test-tracked-parent
                              (list :label (etaf-value label)
                                    :report (lambda (next old)
                                              (push (list next old (with-current-buffer buffer
                                                                     (buffer-string))) observations))) nil))
               (etaf-view
                (etaf-test-tracked-parent
                 :label (etaf-value label)
                 :report (lambda (next old)
                           (push (list next old (with-current-buffer buffer
                                                  (buffer-string))) observations))))))
            (setf (etaf-value label) "B")
            (should (equal '("B" "A" "B!") (car observations)))
            (should (equal "B!" (with-current-buffer buffer (buffer-string)))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
        (kill-buffer buffer)))))

(ert-deftest etaf-tracked-props-restore-successful-computation-after-late-failure ()
  "Rejected later output cannot leak a successfully computed candidate value."
  (let ((buffer (generate-new-buffer " *tracked-late-failure*"))
        (input (etaf-ref '("A" nil)))
        events source)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (lambda ()
             (let ((values (etaf-value input)))
               (etaf-node 'etaf-test-tracked-input
                          (list :label (car values) :invalid (cadr values)
                                :report (lambda (kind &rest args)
                                          (if (eq kind 'source) (setq source (car args))
                                            (push (cons kind args) events)))) nil))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (should-error (setf (etaf-value input) '("B" t)))
            (should-not events)
            (should (equal "A" (etaf-value source)))
            (etaf-dispatch-event runtime 'target 'press)
            (should (equal '(press "A" "A!") (car events)))
            (setf (etaf-value input) '("C" nil))
            (should (member '(watch "C" "A") events))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(etaf-define-component etaf-test-tracked-branch (&key choose-left left right invalid report)
  :setup
  (let* ((choice (etaf-prop 'choose-left))
         (derived (etaf-computed
                   (lambda () (etaf-value (if (etaf-value choice) left right))))))
    (funcall report derived)
    derived)
  :render
  (let ((derived (etaf-state)))
    (etaf-view
     (column
      (text (expr (etaf-value derived)))
      (text (expr (if invalid 42 "")))))))

(ert-deftest etaf-tracked-props-rollback-restores-conditional-dependencies ()
  "A rejected branch restores old edges while preserving live business refs."
  (let ((buffer (generate-new-buffer " *tracked-branch*"))
        (input (etaf-ref '(t nil)))
        (left (etaf-ref "Left")) (right (etaf-ref "Right")) derived)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (lambda ()
             (let ((values (etaf-value input)))
               (etaf-node 'etaf-test-tracked-branch
                          (list :choose-left (car values) :invalid (cadr values)
                                :left left :right right
                                :report (lambda (value) (setq derived value))) nil))))
          (should-error (setf (etaf-value input) '(nil t)))
          (should (equal "Left" (etaf-value derived)))
          ;; The failed root input remains live; a left-side change retries it.
          ;; The application ref write survives that second publication failure.
          (should-error (setf (etaf-value left) "Live left"))
          (should (equal "Live left" (etaf-value derived)))
          (setf (etaf-value right) "Live right")
          (should (equal "Live left" (etaf-value derived)))
          (setf (etaf-value input) '(nil nil))
          (should (equal "Live right" (etaf-value derived))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(etaf-define-component etaf-test-tracked-default (&key (label "Default") report)
  :setup
  (let ((source (etaf-prop 'label)))
    (funcall report source (eq source (etaf-prop :label)))
    source)
  :view (text (expr (etaf-value (etaf-state)))))

(ert-deftest etaf-tracked-props-defaults-and-applications-are-independent ()
  "Sources are stable per instance, include defaults and validate caller context."
  (let ((one (generate-new-buffer " *tracked-one*"))
        (two (generate-new-buffer " *tracked-two*"))
        sources)
    (unwind-protect
        (progn
          (dolist (buffer (list one two))
            (etaf-mount
             buffer
             (etaf-view
              (etaf-test-tracked-default
               :report (lambda (source stable)
                         (should stable)
                         (push source sources))))))
          (should-not (eq (car sources) (cadr sources)))
          (should (equal "Default" (etaf-value (car sources))))
          (etaf-unmount (etaf-runtime-for-buffer one))
          (should-error (etaf-value (cadr sources)))
          (should (equal "Default" (etaf-value (car sources)))))
      (dolist (buffer (list one two))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
        (kill-buffer buffer))))
  (should-error (etaf-prop 'label) :type 'etaf-component-definition-error))

(provide 'etaf-tracked-props-tests)
;;; etaf-tracked-props-tests.el ends here
