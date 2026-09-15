;;; etaf-input-identity-tests.el --- Shallow application input ownership -*- lexical-binding: t; -*-

;;; Commentary:
;; Replacing an application object must retarget retained views and callbacks.

;;; Code:
(require 'ert)
(require 'etaf)

(etaf-define-component etaf-test-input-slot ()
  :view (column (slot)))

(etaf-define-component etaf-test-input-view (&key payload report)
  :bindings ((count (etaf-ref 0)))
  :view
  (box :ref 'input :tab-index 0
       :on-press (lambda ()
                   (cl-incf (etaf-value count))
                   (funcall report payload (etaf-value count)))
       (text (expr (number-to-string (etaf-value count))))))

(etaf-define-component etaf-test-input-code (&key payload report)
  :bindings ((count (etaf-ref 0)))
  :render
  (etaf-node 'box
             (list :ref 'input :tab-index 0
                   :on-press (lambda ()
                               (cl-incf (etaf-value count))
                               (funcall report payload (etaf-value count))))
             (list (number-to-string (etaf-value count)))))

(etaf-define-component etaf-test-input-author (&key component payload report)
  :render (etaf-node 'etaf-test-input-slot nil
                     (list (etaf-node component
                                      (list :payload payload :report report) nil))))

(ert-deftest etaf-component-input-replacement-preserves-application-identity ()
  "Both frontends follow replacement objects without replacing the instance."
  (dolist (component '(etaf-test-input-view etaf-test-input-code))
    (dolist (route '(root input expression slot))
      (dolist (create (list (lambda () (list 'same))
                            (lambda () (vector 'same))
                            (lambda () (let ((value (list 'same))) (lambda () value)))))
        (let* ((before (funcall create)) (after (funcall create))
               (source (etaf-ref before))
               (buffer (generate-new-buffer " *input-identity*"))
               observed clicks
               (report (lambda (payload count) (setq observed payload clicks count))))
          (unwind-protect
              (progn
                (ert-info ((format "component=%S route=%S value=%S"
                                   component route (type-of before)))
                  (etaf-mount
                   buffer
                   (pcase route
                     ('root (lambda () (etaf-node component
                                                  (list :payload (etaf-value source)
                                                        :report report) nil)))
                     ('input (if (eq component 'etaf-test-input-view)
                                 (etaf-view (etaf-test-input-view
                                             :payload (etaf-value source) :report report))
                               (etaf-view (etaf-test-input-code
                                           :payload (etaf-value source) :report report))))
                     ('slot (etaf-view (etaf-test-input-author
                                        :component component
                                        :payload (etaf-value source) :report report)))
                     ('expression
                      (etaf-view (column
                                  (expr (etaf-node component
                                                   (list :payload (etaf-value source)
                                                         :report report) nil)))))))
                  (let ((runtime (etaf-runtime-for-buffer buffer)))
                    (etaf-focus runtime 'input)
                    (etaf-dispatch-event runtime 'input 'press)
                    (should (eq observed before))
                    (should (= clicks 1))
                    (setf (etaf-value source) after)
                    (should (eq (etaf-focused-host-ref runtime) 'input))
                    (etaf-dispatch-event runtime 'input 'press)
                    (should (eq observed after))
                    (should (= clicks 2)))))
            (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
            (kill-buffer buffer)))))))

(ert-deftest etaf-keyed-items-follow-object-replacement ()
  "A stable key retains state and focus while its callbacks receive the new row."
  (dolist (component-p '(nil t))
    (let* ((before (list :id 'primary)) (after (list :id 'primary))
           (rows (etaf-ref (list before))) observed clicks
           (report (lambda (payload count) (setq observed payload clicks count)))
           (buffer (generate-new-buffer " *keyed-input-identity*")))
      (unwind-protect
          (progn
            (etaf-mount
             buffer
             (if component-p
                 (etaf-view
                     (column
                      (etaf-test-input-view :for (row (etaf-value rows))
                                            :key (plist-get row :id)
                                            :payload row :report report)))
               (etaf-view
                   (column
                    (box :for (row (etaf-value rows)) :key (plist-get row :id)
                         :ref 'input :tab-index 0
                         :on-press (lambda () (setq observed row))
                         (text "Row"))))))
            (let ((runtime (etaf-runtime-for-buffer buffer)))
              (etaf-focus runtime 'input)
              (etaf-dispatch-event runtime 'input 'press)
              (should (eq observed before))
              (setf (etaf-value rows) (list after))
              (should (eq (etaf-focused-host-ref runtime) 'input))
              (etaf-dispatch-event runtime 'input 'press)
              (should (eq observed after))
              (when component-p (should (= clicks 2)))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
        (kill-buffer buffer)))))

(provide 'etaf-input-identity-tests)
;;; etaf-input-identity-tests.el ends here
