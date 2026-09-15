;;; etaf-transparent-slots-tests.el --- Transparent slot composition -*- lexical-binding: t; -*-

;;; Commentary:
;; Slot composition preserves parent layout and retained child lifetimes.

;;; Code:
(require 'ert)
(require 'etaf)

(etaf-define-component etaf-test-transparent-view-slots ()
  :view (fragment (slot :name 'header) (slot) (slot :name 'footer)))

(etaf-define-component etaf-test-transparent-code-slots ()
  :render
  (etaf-node 'fragment nil
             (append (etaf-current-slot 'header)
                     (etaf-current-slot 'default)
                     (etaf-current-slot 'footer))))

(etaf-define-component etaf-test-transparent-slot-label (&key label)
  :view (text (expr label)))

(defun etaf-test-transparent-presentation (text)
  "Return TEXT's visible characters, faces and layout properties."
  (cl-loop for index below (length text)
           collect (list (aref text index)
                         (get-text-property index 'face text)
                         (get-text-property index 'display text))))

(ert-deftest etaf-slot-fragments-preserve-parent-layout ()
  "Both slot frontends preserve direct children in every layout Host."
  (dolist (layout '((row :item-gap (ch 1))
                    (column :item-gap (lh 1))
                    (flex :width (ch 20) :flex-direction row)
                    (grid :grid-template-columns (auto auto auto auto))))
    (let* ((a (etaf-view (etaf-test-transparent-slot-label :label "A")))
           (b (etaf-view (etaf-test-transparent-slot-label :label "B")))
           (left (etaf-view (text "L")))
           (right (etaf-view (text "R")))
           (direct (etaf-node (car layout) (cdr layout) (list left a b right)))
           (expected (etaf-test-transparent-presentation
                      (ebox-render (etaf-render direct)))))
      (dolist (component '(etaf-test-transparent-view-slots
                           etaf-test-transparent-code-slots))
        (let* ((buffer (generate-new-buffer " *transparent-layout*"))
               (view (etaf-node
                      (car layout) (cdr layout)
                      (list left (etaf-node component nil (list a b)) right))))
          (unwind-protect
              (progn
                (should (equal expected (etaf-test-transparent-presentation
                                         (ebox-render (etaf-render view)))))
                (etaf-mount buffer view)
                (should (equal expected (etaf-test-transparent-presentation
                                         (with-current-buffer buffer (buffer-string))))))
            (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
            (kill-buffer buffer)))))))

(etaf-define-component etaf-test-transparent-slot-counter (&key id label dispose)
  :bindings ((count (etaf-ref 0)))
  :setup (etaf-on-unmounted (lambda () (funcall dispose id)))
  :view
  (text :tab-index 0 :on-press (lambda () (cl-incf (etaf-value count)))
        (expr (format "%s%d" label (etaf-value count)))))

(ert-deftest etaf-slot-fragments-retain-keyed-children ()
  "Projected children keep state and focus through updates and release on removal."
  (dolist (component '(etaf-test-transparent-view-slots
                       etaf-test-transparent-code-slots))
    (let ((buffer (generate-new-buffer " *transparent-children*"))
          (rows (etaf-ref '((a . "A") (b . "B"))))
          disposed)
      (unwind-protect
          (progn
            (etaf-mount
             buffer
             (lambda ()
               (etaf-node
                'row nil
                (list
                 (etaf-view (text "L"))
                 (etaf-node
                  component nil
                  (append
                   (list (etaf-view (slot :name 'header (text "["))))
                   (mapcar (lambda (entry)
                             (etaf-node
                              'etaf-test-transparent-slot-counter
                              (list :key (car entry) :ref (car entry)
                                    :id (car entry) :label (cdr entry)
                                    :dispose (lambda (id) (push id disposed))) nil))
                           (etaf-value rows))
                   (list (etaf-view (slot :name 'footer (text "]"))))))
                 (etaf-view (text "R"))))))
            (let ((runtime (etaf-runtime-for-buffer buffer)))
              (cl-flet ((visible () (with-current-buffer buffer
                                     (buffer-substring-no-properties (point-min) (point-max)))))
                (should (equal "L[A0B0]R" (visible)))
                (etaf-focus runtime 'b)
                (etaf-dispatch-event runtime 'b 'press)
                (should (equal "L[A0B1]R" (visible)))
                (setf (etaf-value rows) '((b . "Beta") (a . "Alpha")))
                (should (equal "L[Beta1Alpha0]R" (visible)))
                (should (equal 'b (etaf-focused-host-ref runtime)))
                (etaf-dispatch-event runtime 'b 'press)
                (should (equal "L[Beta2Alpha0]R" (visible)))
                (setf (etaf-value rows) '((a . "A")))
                (should (equal "L[A0]R" (visible)))
                (should (equal '(b) disposed))
                (should-error (etaf-dispatch-event runtime 'b 'press)
                              :type 'etaf-event-error)
                (setf (etaf-value rows) nil)
                (should (equal "L[]R" (visible)))
                (should (equal '(a b) disposed))
                (setf (etaf-value rows) '((b . "B")))
                (should (equal "L[B0]R" (visible)))
                (etaf-unmount runtime)
                (should (equal '(b a b) disposed)))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
        (kill-buffer buffer)))))

(provide 'etaf-transparent-slots-tests)
;;; etaf-transparent-slots-tests.el ends here
