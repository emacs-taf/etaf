;;; etaf-component-output-tests.el --- Component output composition -*- lexical-binding: t; -*-

;;; Commentary:
;; One component can produce zero, one or several children in the same layout.

;;; Code:
(require 'ert)
(require 'etaf)

(etaf-define-component etaf-test-output-shape (&key shape)
  :render
  (pcase shape
    ('one (etaf-view (text "X")))
    ('many (etaf-view (fragment (text "A") (text "B"))))
    ('empty nil)))

(defun etaf-test-output-presentation (text)
  "Read TEXT's visible characters, face and geometry properties."
  (cl-loop for index below (length text)
           collect (list (aref text index)
                         (get-text-property index 'face text)
                         (get-text-property index 'display text))))

(ert-deftest etaf-component-output-shapes-preserve-enclosing-layout ()
  "Root and nested output changes match fresh rendering in each layout."
  (dolist (layout '(nil (row :item-gap (ch 1))
                       (column :item-gap (lh 1))
                       (flex :width (ch 20) :flex-direction row)
                       (grid :grid-template-columns (auto auto auto auto))))
    (dolist (initial '(one many empty))
      (let ((shape (etaf-ref initial))
            (buffer (generate-new-buffer " *component-shape*")))
        (cl-flet ((enclose (content)
                    (if layout
                        (etaf-node (car layout) (cdr layout)
                                   (list (etaf-view (text "L")) content
                                         (etaf-view (text "R"))))
                      content)))
          (unwind-protect
              (progn
                (etaf-mount buffer
                            (enclose (etaf-view (etaf-test-output-shape
                                                 :shape (etaf-value shape)))))
                (dolist (next '(one many empty many one empty one))
                  (setf (etaf-value shape) next)
                  (let ((fresh (ebox-render
                                (etaf-render
                                 (enclose (etaf-node 'etaf-test-output-shape
                                                      (list :shape next) nil))))))
                    (should (equal (etaf-test-output-presentation fresh)
                                   (etaf-test-output-presentation
                                    (with-current-buffer buffer (buffer-string))))))))
            (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
            (kill-buffer buffer)))))))

(etaf-define-component etaf-test-output-child (&key outer dispose)
  :bindings ((local (etaf-ref 0)))
  :setup (etaf-on-unmounted dispose)
  :view
  (text :tab-index 0
        :on-press (lambda ()
                    (cl-incf (etaf-value local))
                    (cl-incf (etaf-value outer)))
        (expr (format "%d/%d" (etaf-value local) (etaf-value outer)))))

(etaf-define-component etaf-test-output-parent (&key shape report dispose child-dispose)
  :bindings ((outer (etaf-ref 0)))
  :setup (progn (funcall report outer) (etaf-on-unmounted dispose))
  :render
  (let ((child (etaf-node 'etaf-test-output-child
                          (list :key 'primary :ref 'primary :outer outer
                                :dispose child-dispose) nil)))
    (pcase shape
      ('one child)
      ('many (etaf-node 'fragment nil (list child (etaf-view (text "+")))))
      ('empty nil))))

(ert-deftest etaf-component-output-shapes-retain-owner-and-child-lifetimes ()
  "Output cardinality keeps its owner; keys retain children until removal."
  (let ((shape (etaf-ref 'one))
        (buffer (generate-new-buffer " *component-output-state*"))
        (owner-disposals 0) (child-disposals 0) outer)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (row (text "L")
                 (etaf-test-output-parent
                  :shape (etaf-value shape) :report (lambda (value) (setq outer value))
                  :dispose (lambda () (cl-incf owner-disposals))
                  :child-dispose (lambda () (cl-incf child-disposals)))
                 (text "R"))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (cl-flet ((visible () (with-current-buffer buffer
                                   (buffer-substring-no-properties (point-min) (point-max)))))
              (etaf-focus runtime 'primary)
              (etaf-dispatch-event runtime 'primary 'press)
              (should (equal "L1/1R" (visible)))
              (setf (etaf-value shape) 'many)
              (should (equal "L1/1+R" (visible)))
              (should (eq 'primary (etaf-focused-host-ref runtime)))
              (etaf-dispatch-event runtime 'primary 'press)
              (setf (etaf-value shape) 'one)
              (should (equal "L2/2R" (visible)))
              (should (zerop child-disposals))
              (setf (etaf-value shape) 'empty)
              (should (equal "LR" (visible)))
              (should (= child-disposals 1))
              (should (zerop owner-disposals))
              (should (= (etaf-value outer) 2))
              (should-not (etaf-focused-host-ref runtime))
              (should-error (etaf-dispatch-event runtime 'primary 'press)
                            :type 'etaf-event-error)
              (setf (etaf-value shape) 'many)
              (should (equal "L0/2+R" (visible)))
              (etaf-unmount runtime)
              (should (= owner-disposals 1))
              (should (= child-disposals 2)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-component-output-tests)
;;; etaf-component-output-tests.el ends here
