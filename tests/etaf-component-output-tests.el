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

(etaf-define-component etaf-test-output-local-child (&key value tag)
  :render
  (etaf-node 'column (list :key (or tag 'child) :id (or tag "child"))
             (list (etaf-node 'text nil (list (etaf-value value))))))

(etaf-define-component etaf-test-output-local-parent (&key tick title value)
  :render
  (progn
    (ignore tick)
    (etaf-node
     'column '(:key parent :id "parent")
     (list (etaf-node 'text nil (list title))
           (etaf-node 'box nil
                      (list (etaf-node 'etaf-test-output-local-child
                                       (list :value value) nil)))))))

(ert-deftest etaf-component-output-publishes-only-changed-child-ranges ()
  "A rerendered parent retains its own nodes unless their content changes."
  (let ((tick (etaf-ref 0)) (title (etaf-ref "Title"))
        (value (etaf-ref "A"))
        (buffer (generate-new-buffer " *component-local-output*")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view (etaf-test-output-local-parent
                      :tick (etaf-value tick) :title (etaf-value title) :value value)))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (dolist (own-change '(nil t nil))
              (etaf-batch
                (cl-incf (etaf-value tick))
                (setf (etaf-value value)
                      (if (equal (etaf-value value) "A") "B" "A"))
                (when own-change (setf (etaf-value title) "Changed")))
              (etaf-runtime-flush runtime)
              (let ((report (ebox-buffer-update-report buffer)))
                (should
                 (equal (plist-get report :rendered-owner-ids)
                        (mapcar (lambda (match) (plist-get match :node-id))
                                (ebox-select-all
                                 buffer (if own-change "#parent" "#child")))))
                (unless own-change
                  (should (= 1 (plist-get (plist-get report :range-metrics)
                                         :replacement-count)))))
              (should
               (equal
                (etaf-test-output-presentation
                 (with-current-buffer buffer (buffer-string)))
                (etaf-test-output-presentation
                 (ebox-render
                  (etaf-render
                   (etaf-node 'etaf-test-output-local-parent
                              (list :tick (etaf-value tick)
                                    :title (etaf-value title) :value value) nil)))))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(etaf-define-component etaf-test-output-forest-child (&key tag values)
  :render
  (etaf-node
   'fragment nil
   (cl-loop for value in (etaf-value values)
            for index from 0
            collect (etaf-node 'text (list :key (format "%s-%d" tag index))
                               (list value)))))

(etaf-define-component etaf-test-output-forest-parent (&key tick order values)
  :render
  (progn
    (ignore tick)
    (etaf-node
     'column '(:id "parent")
     (cons (etaf-node 'text nil '("Title"))
           (mapcar (lambda (tag)
                     (etaf-node 'etaf-test-output-forest-child
                                (list :key tag :tag tag :values values) nil))
                   order)))))

(ert-deftest etaf-component-output-keeps-range-membership-and-order ()
  "Sibling ranges can change size; adding, removing or moving them replaces parent."
  (let ((tick (etaf-ref 0)) (order (etaf-ref '(a b)))
        (values (etaf-ref '("A")))
        (buffer (generate-new-buffer " *component-forest-output*")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view (etaf-test-output-forest-parent
                      :tick (etaf-value tick) :order (etaf-value order) :values values)))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (dolist (step '(((a b) nil 2) ((a b) ("A" "B") 2)
                            ((b a) ("C") nil) ((b a c) ("D") nil)
                            ((a c) ("E") nil) ((a c) nil 2)
                            ((a c) ("F") 2)))
              (etaf-batch
                (cl-incf (etaf-value tick))
                (setf (etaf-value order) (nth 0 step)
                      (etaf-value values) (nth 1 step)))
              (etaf-runtime-flush runtime)
              (let* ((report (ebox-buffer-update-report buffer))
                     (count (plist-get (plist-get report :range-metrics)
                                       :replacement-count)))
                (if (nth 2 step)
                    (should (eql (nth 2 step) count))
                  (should-not count)))
              (should
               (equal
                (etaf-test-output-presentation
                 (with-current-buffer buffer (buffer-string)))
                (etaf-test-output-presentation
                 (ebox-render
                  (etaf-render
                   (etaf-node 'etaf-test-output-forest-parent
                              (list :tick (etaf-value tick)
                                    :order (etaf-value order) :values values) nil)))))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(etaf-define-component etaf-test-output-loop-parent (&key tick entries)
  :render
  (progn
    (ignore tick)
    (etaf-view
     (column :id "parent"
       (text "Title")
       (etaf-test-output-local-child :for (entry entries) :key (car entry)
                                    :tag (car entry) :value (cdr entry))))))

(ert-deftest etaf-component-output-publishes-flattened-single-root-child ()
  "A loop child with one stable root publishes through that Host alone."
  (let* ((tick (etaf-ref 0)) (value (etaf-ref "A"))
         (entries (list (cons "first" value) (cons "second" (etaf-ref "B"))))
         (buffer (generate-new-buffer " *component-loop-output*")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view (etaf-test-output-loop-parent
                      :tick (etaf-value tick) :entries entries)))
          (etaf-batch
            (cl-incf (etaf-value tick))
            (setf (etaf-value value) "C"))
          (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
          (should
           (equal (plist-get (ebox-buffer-update-report buffer) :rendered-owner-ids)
                  (mapcar (lambda (match) (plist-get match :node-id))
                          (ebox-select-all buffer "#first"))))
          (should
           (equal
            (etaf-test-output-presentation (with-current-buffer buffer (buffer-string)))
            (etaf-test-output-presentation
             (ebox-render
              (etaf-render
               (etaf-node 'etaf-test-output-loop-parent
                          (list :tick (etaf-value tick) :entries entries) nil)))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-component-output-tests)
;;; etaf-component-output-tests.el ends here
