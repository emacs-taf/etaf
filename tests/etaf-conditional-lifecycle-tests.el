;;; etaf-conditional-lifecycle-tests.el --- Conditional ownership -*- lexical-binding: t; -*-

;;; Commentary:
;; Structural visibility resolves before descendant input and render updates.

;;; Code:
(require 'ert)
(require 'etaf)

(defun etaf-conditional-test-text (buffer)
  "Return BUFFER's visible text without properties or surrounding blanks."
  (string-trim (substring-no-properties (with-current-buffer buffer (buffer-string)))))

(etaf-define-component etaf-conditional-test-caption (&key value activate dispose)
  :setup (progn (etaf-on-unmounted dispose) nil)
  :view
  (text :ref 'conditional-caption :tab-index 0
        :on-press (lambda () (funcall activate value))
        (expr value)))

(ert-deftest etaf-conditional-component-retires-before-stale-input-work ()
  "Repeated removal and recreation retain matching text, callbacks and lifecycle."
  (let ((state (etaf-ref 'success))
        (buffer (generate-new-buffer " *conditional-lifecycle*"))
        activated (disposals 0))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (column
             (etaf-conditional-test-caption
              :if (not (eq (etaf-value state) 'success))
              :value (symbol-name (etaf-value state))
              :activate (lambda (value) (setq activated value))
              :dispose (lambda () (setq disposals (1+ disposals))))
             (text "Always present"))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (dolist (next '(refreshing cancelled refreshing success loading error success loading success))
              (setf (etaf-value state) next)
              (should (with-current-buffer buffer (string-match-p "Always present" (buffer-string))))
              (if (eq next 'success)
                  (should-error (etaf-dispatch-event runtime 'conditional-caption 'press)
                                :type 'etaf-event-error)
                (should (with-current-buffer buffer (string-match-p (symbol-name next) (buffer-string))))
                (etaf-dispatch-event runtime 'conditional-caption 'press)
                (should (equal activated (symbol-name next)))))
            (should (= disposals 3))))
      (when (etaf-runtime-for-buffer buffer) (etaf-unmount (etaf-runtime-for-buffer buffer)))
      (kill-buffer buffer))))

(ert-deftest etaf-conditional-layout-kind-change-keeps-runtime-type-counts ()
  "A retained node that changes layout kind must keep runtime type counts exact."
  (let ((detailed (etaf-ref t))
        (gridded (etaf-ref t))
        (buffer (generate-new-buffer " *conditional-layout-kind*"))
        runtime)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (column
             (column :if (etaf-value detailed)
               (box :if (etaf-value gridded) "Rows")
               (grid :else t :grid-template-columns '((ch 4)) (box "Grid"))))))
          (setq runtime (etaf-runtime-for-buffer buffer))
          ;; The retained arm node moves from a Box layout to a Grid layout.
          (setf (etaf-value gridded) nil)
          (etaf-runtime-flush runtime)
          (should (equal "Grid" (etaf-conditional-test-text buffer)))
          ;; Removing the same subtree later must not decrement a bucket that
          ;; never counted this node.
          (setf (etaf-value detailed) nil)
          (etaf-runtime-flush runtime)
          (should (equal "" (etaf-conditional-test-text buffer))))
      (when runtime (etaf-unmount runtime))
      (kill-buffer buffer))))

(etaf-define-component etaf-conditional-test-panel ()
  :view (column (text "Details") (slot)))

(etaf-define-component etaf-conditional-test-field (&key value disabled dispose)
  :setup (progn (etaf-on-unmounted dispose) nil)
  :view (box (text :ref 'conditional-field :tab-index 0
                   :disabled disabled :on-press (lambda () value)
                   (expr value))))

(etaf-define-component etaf-conditional-test-form (&key item original data dispose)
  :view
  (column
   (etaf-conditional-test-field
    :value (plist-get (or original item) :title)
    :disabled (and (memq (etaf-value (etaf-data-status data)) '(loading refreshing)) t)
    :dispose dispose)))

(etaf-define-component etaf-conditional-test-summary (&key item)
  :view (column (text "Selected record") (text (expr (plist-get item :title)))))

(etaf-define-component etaf-conditional-test-detail (&key data dispose)
  :view
  (etaf-conditional-test-panel
   (expr (if-let* ((item (etaf-data-selected-item data)))
             (etaf-view (column (etaf-conditional-test-summary :item item)
                               (etaf-conditional-test-form
                                 :item item :original (etaf-data-selected-item data)
                                 :data data :dispose dispose)))
           (etaf-view (text "No selection"))))))

(ert-deftest etaf-conditional-data-detail-retires-staged-descendants ()
  "Filtering or deleting a selected record retires and recreates its whole detail."
  (let* ((buffer (generate-new-buffer " *conditional-data-detail*"))
         (deliver nil)
         (source (etaf-data-source-capabilities
                  (etaf-data-memory-source
                   '((:id 1 :title "First") (:id 2 :title "Second")) :id-key :id)))
         (load (plist-get source :load))
         (data (etaf-data-controller
                (apply #'etaf-data-source
                       (plist-put
                        source :load
                        (lambda (&rest args)
                          (let ((result (apply load args)))
                            (etaf-async
                             (lambda (resolve _reject)
                               (setq deliver (lambda () (funcall resolve result)))
                               nil))))))
                :auto-load t))
         (disposals 0))
    (unwind-protect
        (progn
          (funcall deliver)
          (etaf-mount buffer
                      (etaf-view
                       (etaf-conditional-test-detail
                        :data data :dispose (lambda () (cl-incf disposals)))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-data-select-one data 1)
            (etaf-data-mutate data 'update '(:id 1 :title "Edited"))
            (funcall deliver)
            (etaf-data-set-query data '(:id 2))
            (funcall deliver)
            (should (= disposals 1))
            (should (with-current-buffer buffer
                      (string-match-p "No selection" (buffer-string))))
            (etaf-data-set-query data nil)
            (funcall deliver)
            (etaf-data-select-one data 1)
            (should (with-current-buffer buffer
                      (string-match-p "Selected record" (buffer-string))))
            (should (with-current-buffer buffer
                      (string-match-p "Edited" (buffer-string))))
            (etaf-data-mutate data 'delete 1)
            (funcall deliver)
            (should (= disposals 2))
            (should (with-current-buffer buffer
                      (string-match-p "No selection" (buffer-string))))
            (should-error (etaf-dispatch-event runtime 'conditional-field 'press)
                          :type 'etaf-event-error)
            (dotimes (_ 2) (etaf-data-load data) (funcall deliver))
            (etaf-data-select-one data 2)
            (should (with-current-buffer buffer
                      (string-match-p "Second" (buffer-string))))
            (should (= disposals 2))
            (etaf-unmount runtime)
            (should (= disposals 3))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (etaf-data-stop data)
      (kill-buffer buffer))))

(provide 'etaf-conditional-lifecycle-tests)
;;; etaf-conditional-lifecycle-tests.el ends here
