;;; etaf-nested-reorder-tests.el --- Retained composition updates -*- lexical-binding: t; -*-

;;; Commentary:
;; Component keys retain nested state without repeated keys on internal Hosts.

;;; Code:
(require 'ert)
(require 'etaf)

(defvar etaf-reorder-test--states nil)
(defvar etaf-reorder-test--removed nil)

(etaf-define-component etaf-reorder-test-button (&key label target on-press)
  :view (box :ref target :role 'button :tab-index 0 :on-press on-press (expr label)))

(etaf-define-component etaf-reorder-test-counter (&key row field)
  :bindings ((count (etaf-ref 0)) (target (etaf-local-ref 'button)))
  :setup
  (let ((id (list (plist-get row :id) field)))
    (push (list id count target) etaf-reorder-test--states)
    (etaf-on-unmounted (lambda () (push id etaf-reorder-test--removed))))
  :render
  (etaf-node 'etaf-reorder-test-button
             (list :label (format "%s/%s=%s" (plist-get row :id) field (etaf-value count))
                   :target target :on-press (lambda () (cl-incf (etaf-value count)))) nil))

(etaf-define-component etaf-reorder-test-row (&key row columns)
  :render
  (etaf-node
   'row nil
   (list
    (etaf-node
     'grid (list :grid-template-columns '((ch 12) (ch 12)))
     (mapcar
      (lambda (field)
        (etaf-node
         'box (list :key field)
         (list (etaf-view
                (expr (etaf-node 'etaf-reorder-test-counter (list :row row :field field) nil))))))
      columns)))))

(etaf-define-component etaf-reorder-test-grid (&key rows columns)
  :view
  (column (etaf-reorder-test-row :for (item (etaf-value rows))
                                 :key (plist-get item :id) :row item :columns columns)))

(ert-deftest etaf-nested-reorder-keeps-state-visible-without-host-keys ()
  "Keyed rows and columns keep state, focus and updates through unkeyed Hosts."
  (dolist (focused '(nil t))
    (let ((etaf-reorder-test--states nil)
          (etaf-reorder-test--removed nil)
          (rows (etaf-ref '((:id 1) (:id 2))))
          (columns (etaf-ref '(:a :b)))
          (buffer (generate-new-buffer " *etaf-nested-reorder*")))
      (unwind-protect
          (progn
            (etaf-mount buffer (etaf-view (etaf-reorder-test-grid :rows rows :columns (etaf-value columns))))
            (let* ((runtime (etaf-runtime-for-buffer buffer))
                   (state (assoc '(1 :a) etaf-reorder-test--states))
                   (target (nth 2 state)))
              (when focused (etaf-focus runtime target))
              ;; Several descendant generations precede ancestor composition.
              ;; Reordering must use the latest child output and callbacks.
              (dotimes (index 4)
                (etaf-dispatch-event runtime target 'press)
                (with-current-buffer buffer
                  (should (string-match-p (format "1/:a=%s" (1+ index))
                                          (buffer-string)))))
              (setf (etaf-value columns) (reverse (etaf-value columns)))
              (setf (etaf-value rows) '((:id 2) (:id 1)))
              (should (equal (and focused target) (etaf-focused-host-ref runtime)))
              (should-not etaf-reorder-test--removed)
              (should (= 4 (length etaf-reorder-test--states)))
              (dotimes (index 2)
                (etaf-dispatch-event runtime target 'press)
                (should (= (+ 5 index) (etaf-value (cadr state))))
                (with-current-buffer buffer
                  (should (string-match-p (format "1/:a=%s" (+ 5 index)) (buffer-string)))
                  (should (string-match-p "2/:a=0" (buffer-string)))))
              (setf (etaf-value rows) '((:id 2)))
              (should-not (etaf-focused-host-ref runtime))
              (should (member '(1 :a) etaf-reorder-test--removed))
              (should (member '(1 :b) etaf-reorder-test--removed))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'etaf-nested-reorder-tests)
;;; etaf-nested-reorder-tests.el ends here
