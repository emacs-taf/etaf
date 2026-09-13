;;; etaf-local-ref-tests.el --- Instance Host references -*- lexical-binding: t; -*-

;;; Commentary:
;; Public Host handles retain component ownership across publication and teardown.

;;; Code:
(require 'ert)
(require 'etaf)

(etaf-define-component etaf-test-local-target (&key label report on-press)
  :setup
  (let ((target (etaf-local-ref 'button)))
    (should (eq target (etaf-local-ref 'button)))
    (should-not (eq target (etaf-local-ref 'other)))
    (funcall report label target)
    target)
  :view (box :ref (etaf-state) :role 'button :tab-index 0
             :on-press (lambda () (funcall on-press label))
          (text (expr label))))

(ert-deftest etaf-local-ref-retains-target-across-reorder-and-failure ()
  "Repeated keyed instances retain distinct handles and committed event targets."
  (let ((buffer (generate-new-buffer " *local-ref*"))
        (input (etaf-ref '((a "A") (b "B"))))
        refs presses)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (lambda ()
             (etaf-node
              'column nil
              (mapcar
               (lambda (entry)
                 (etaf-node 'etaf-test-local-target
                            (list :key (car entry) :label (cadr entry)
                                  :report (lambda (label ref) (push (cons label ref) refs))
                                  :on-press (lambda (label) (push label presses))) nil))
               (etaf-value input)))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (a (cdr (assoc "A" refs))) (b (cdr (assoc "B" refs))))
            (should-not (eq a b))
            (should (< (etaf-host-ref-position runtime a)
                       (etaf-host-ref-position runtime b)))
            (etaf-focus runtime a)
            (should (eq a (etaf-focused-host-ref runtime)))
            (setf (etaf-value input) '((b "Bee") (a "Ay")))
            (should (eq a (etaf-focused-host-ref runtime)))
            (should (< (etaf-host-ref-position runtime b)
                       (etaf-host-ref-position runtime a)))
            (etaf-dispatch-event runtime a 'press)
            (should (equal "Ay" (car presses)))
            (should-error (setf (etaf-value input) '((a "Candidate") (b 42))))
            (etaf-dispatch-event runtime a 'press)
            (should (equal "Ay" (car presses)))
            (should (eq a (etaf-focused-host-ref runtime)))
            (should (< (etaf-host-ref-position runtime b)
                       (etaf-host-ref-position runtime a)))
            (setf (etaf-value input) '((b "Bee")))
            (should-not (etaf-host-ref-position runtime a))
            (should-not (etaf-host-ref-bounds runtime a))
            (setf (etaf-value input) '((a "Again") (b "Bee")))
            (let ((replacement (cdr (assoc "Again" refs))))
              (should replacement)
              (should-not (eq a replacement))
              (should-not (etaf-host-ref-position runtime a))
              (should (etaf-host-ref-position runtime replacement)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-local-ref-isolates-applications-and-rejected-creation ()
  "A failed creation or a different mount cannot acquire another owner's handle."
  (let ((one (generate-new-buffer " *local-one*"))
        (two (generate-new-buffer " *local-two*"))
        refs)
    (unwind-protect
        (progn
          (should-error
           (etaf-mount one
                       (etaf-view
                        (etaf-test-local-target
                         :label 42 :report (lambda (_ ref) (push ref refs))))))
          (let ((rejected (car refs)))
            (dolist (buffer (list one two))
              (etaf-mount buffer
                          (etaf-view
                           (etaf-test-local-target
                            :label "Ready" :report (lambda (_ ref) (push ref refs))))))
            (let ((first (cadr refs)) (second (car refs))
                  (runtime (etaf-runtime-for-buffer one)))
              (should-not (eq first second))
              (should-not (eq first rejected))
              (should-not (etaf-host-ref-position runtime rejected))
              (should-not (etaf-host-ref-position runtime second))
              (should (etaf-host-ref-position runtime first))
              (etaf-unmount runtime)
              (should (etaf-host-ref-position (etaf-runtime-for-buffer two) second)))))
      (dolist (buffer (list one two))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
        (kill-buffer buffer)))))

(etaf-define-component etaf-test-local-name ()
  :setup
  (let ((name (copy-sequence "button")))
    (let ((ref (etaf-local-ref name)))
      (aset name 0 ?x)
      (should (eq ref (etaf-local-ref "button")))
      (should-error (etaf-local-ref nil) :type 'etaf-component-definition-error)
      (should-error (etaf-local-ref 42) :type 'etaf-component-definition-error)
      ref))
  :view (text :ref (etaf-state) "Local"))

(ert-deftest etaf-local-ref-validates-context-and-copies-name ()
  "Only setup creates handles and caller string mutation cannot rename them."
  (should-error (etaf-local-ref 'button) :type 'etaf-component-definition-error)
  (let ((buffer (generate-new-buffer " *local-name*")))
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-view (etaf-test-local-name)))
          (should (equal "Local" (with-current-buffer buffer (buffer-string)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-local-ref-tests)
;;; etaf-local-ref-tests.el ends here
