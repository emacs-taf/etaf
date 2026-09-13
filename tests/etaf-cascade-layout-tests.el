;;; etaf-cascade-layout-tests.el --- Shared layout value projection -*- lexical-binding: t; -*-

;;; Commentary:
;; Programmatic ECSS layout values use the Ebox declaration pipeline.

;;; Code:
(require 'ert)
(require 'etaf)
(require 'ebox)
(require 'ecss)

(defun etaf-layout-test-appearance (text)
  "Return TEXT and its visible display and face properties."
  (cons (substring-no-properties text)
        (cl-loop for position below (length text)
                 collect (list (get-text-property position 'display text)
                               (get-text-property position 'face text)))))

(ert-deftest etaf-layout-values-match-shared-ebox-projection ()
  "Every Box layout uses provider-owned projection for tagged declaration values."
  (dolist (entry (list (list 'flex :flex-direction (ecss-important 'column))
                       (list 'flex :flex-direction (ecss-var '--direction 'column))
                       (list 'flex :flex-direction (ecss-wide-value 'initial))
                       (list 'row :item-gap (ecss-important '(ch 2)))
                       (list 'column :item-gap (ecss-important '(lh 1)))
                       (list 'grid :grid-template-columns
                             (ecss-important '((ch 3) (ch 5))))
                       (list 'box :outer (ecss-important 'inline))))
    (let* ((tag (car entry)) (props (cdr entry))
           (view (etaf-node tag props (list (etaf-node 'box nil '("One"))
                                           (etaf-node 'box nil '("Two")))))
           (dsl (append (list tag) props '((box "One") (box "Two")))))
      (should (equal (etaf-layout-test-appearance (ebox-render (etaf-render view)))
                     (etaf-layout-test-appearance (ebox-render (ebox-build dsl))))))))

(ert-deftest etaf-layout-values-publish-reactively-and-reject-invalid-input ()
  "Deferred layout changes publish atomically and match a fresh provider render."
  (let ((buffer (generate-new-buffer " *etaf-layout-values*"))
        (direction (etaf-ref (ecss-important 'column))))
    (unwind-protect
        (progn
          (etaf-mount buffer
                      (etaf-view
                       (flex :flex-direction (etaf-value direction)
                         (box "One") (box "Two"))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (dolist (value (list (ecss-important 'column) (ecss-var '--direction 'row)))
              (setf (etaf-value direction) value)
              (etaf-runtime-flush runtime)
              (should (equal (etaf-layout-test-appearance
                              (with-current-buffer buffer (buffer-string)))
                             (etaf-layout-test-appearance
                              (ebox-render (ebox-build
                                            (list 'flex :flex-direction value
                                                  '(box "One") '(box "Two"))))))))
            (let ((before (with-current-buffer buffer (buffer-string))))
              (should-error (setf (etaf-value direction) (ecss-important 'invalid)))
              (should (equal-including-properties before
                                                  (with-current-buffer buffer (buffer-string)))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-cascade-layout-tests)
;;; etaf-cascade-layout-tests.el ends here
