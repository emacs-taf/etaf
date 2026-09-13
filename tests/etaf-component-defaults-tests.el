;;; etaf-component-defaults-tests.el --- Default input lifecycle -*- lexical-binding: t; -*-

;;; Commentary:
;; Defaults distinguish missing inputs from nil and belong to retained instances.

;;; Code:
(require 'ert)
(require 'etaf)

(etaf-define-component etaf-test-default-input
    (&key (label "Untitled") (payload (vector label)) report invalid)
  :setup (progn (funcall report 'setup label payload) nil)
  :view
  (box :on-press (lambda () (funcall report 'press label payload))
    (text (expr (if invalid 42 (or label "Explicit nil"))))))

(ert-deftest etaf-component-defaults-retain-instance-values ()
  "Missing props use retained defaults while nil and overrides remain explicit."
  (let ((buffer (generate-new-buffer " *etaf-defaults*"))
        (input (etaf-ref nil))
        observations)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (lambda ()
             (etaf-node
              'etaf-test-default-input
              (append (etaf-value input)
                      (list :ref 'default-input
                            :report (lambda (&rest event)
                                      (push event observations)))) nil)))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (initial (caddar observations)))
            (should (equal (car observations) '(setup "Untitled" ["Untitled"])))
            (etaf-dispatch-event runtime 'default-input 'press)
            (should (eq initial (caddar observations)))
            (setf (etaf-value input) '(:label nil :payload nil))
            (etaf-dispatch-event runtime 'default-input 'press)
            (should (equal (car observations) '(press nil nil)))
            (setf (etaf-value input) '(:label "Override"))
            (etaf-dispatch-event runtime 'default-input 'press)
            (should (equal (cadar observations) "Override"))
            (should (eq initial (caddar observations)))
            (should-error (setf (etaf-value input) '(:invalid t)))
            (etaf-dispatch-event runtime 'default-input 'press)
            (should (equal (cadar observations) "Override"))
            (setf (etaf-value input) nil)
            (etaf-dispatch-event runtime 'default-input 'press)
            (should (equal (cadar observations) "Untitled"))
            (should (eq initial (caddar observations)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-component-defaults-isolate-instances-and-remounts ()
  "Mutable defaults are fresh for each instance and later mount."
  (let ((buffer (generate-new-buffer " *etaf-default-isolation*"))
        values)
    (unwind-protect
        (dotimes (_ 2)
          (etaf-mount
           buffer
           (etaf-node
            'column nil
            (mapcar (lambda (key)
                      (etaf-node
                       'etaf-test-default-input
                       (list :key key :report
                             (lambda (_phase _label payload) (push payload values)))
                       nil)) '(one two))))
          (etaf-unmount (etaf-runtime-for-buffer buffer)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))
    (should (= 4 (length values)))
    (while values
      (let ((value (pop values)))
        (should (equal value ["Untitled"]))
        (should-not (memq value values))))))

(etaf-define-component etaf-test-default-pure (&key (label "Untitled"))
  :render (etaf-node 'text nil (list (or label "Explicit nil"))))

(ert-deftest etaf-component-defaults-support-pure-rendering ()
  "Stateless defaults also work without a mounted runtime."
  (should (equal "Untitled"
                 (substring-no-properties
                  (ebox-render
                   (etaf-render (etaf-view (etaf-test-default-pure)))))))
  (should (equal "Explicit nil"
                 (substring-no-properties
                  (ebox-render
                   (etaf-render (etaf-view (etaf-test-default-pure :label nil))))))))

(ert-deftest etaf-component-defaults-publish-first-use-atomically ()
  "A default first needed by a rejected update is not committed early."
  (let ((buffer (generate-new-buffer " *etaf-default-first-use*"))
        (input (etaf-ref '(:label "Provided" :payload nil)))
        observed)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (lambda ()
             (etaf-node
              'etaf-test-default-input
              (append (etaf-value input)
                      (list :ref 'target
                            :report (lambda (&rest event) (setq observed event))))
              nil)))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (should-error (setf (etaf-value input) '(:label "Rejected" :invalid t)))
            (etaf-dispatch-event runtime 'target 'press)
            (should (equal observed '(press "Provided" nil)))
            (setf (etaf-value input) '(:label "Accepted"))
            (etaf-dispatch-event runtime 'target 'press)
            (should (equal observed '(press "Accepted" ["Accepted"])))
            (let ((payload (caddr observed)))
              (setf (etaf-value input) '(:label "Later"))
              (etaf-dispatch-event runtime 'target 'press)
              (should (eq payload (caddr observed))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(etaf-define-component etaf-test-default-list
    (&key (payload (list "Owned")) tick report)
  :render
  (progn
    (etaf-value tick)
    (etaf-node 'box
               (list :on-press (lambda () (funcall report payload)))
               (list (car payload)))))

(ert-deftest etaf-component-defaults-preserve-list-identity-on-local-updates ()
  "Default lists retain object identity during component-local reevaluation."
  (let ((buffer (generate-new-buffer " *etaf-default-list*"))
        (tick (etaf-ref 0))
        observed)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-test-default-list :tick tick :ref 'target
                                   :report (lambda (value) (setq observed value)))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-dispatch-event runtime 'target 'press)
            (let ((initial observed))
              (should (equal initial '("Owned")))
              (setf (etaf-value tick) 1)
              (etaf-dispatch-event runtime 'target 'press)
              (should (eq initial observed)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-component-defaults-validate-declarations ()
  "Malformed, repeated and reserved default declarations fail at definition."
  (dolist (arguments '((&key (label)) (&key (label 1 extra))
                       (&key label (label 2)) (&key (key 1))
                       (&key (:label 1)) (&key (&rest 1))))
    (should-error
     (macroexpand `(etaf-define-component etaf-test-invalid-default ,arguments
                     :view (text "Invalid")))
     :type 'etaf-component-definition-error)))

(provide 'etaf-component-defaults-tests)
;;; etaf-component-defaults-tests.el ends here
