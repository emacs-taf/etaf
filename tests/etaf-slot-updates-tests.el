;;; etaf-slot-updates-tests.el --- Composed public updates -*- lexical-binding: t; -*-

;;; Commentary:
;; Controlled children and conditional slot content update in one publication.

;;; Code:
(require 'ert)
(require 'etaf)

(etaf-define-component etaf-test-slot-view-container ()
  :view (column (slot)))

(etaf-define-component etaf-test-slot-code-container ()
  :render (etaf-node 'column nil (etaf-current-slot 'default)))

(etaf-define-component etaf-test-slot-switch (&key checked on-change)
  :view
  (box :role 'button :tab-index 0 :aria-label "Disclosure"
       :on-press (lambda () (funcall on-change (not checked)))
    (box (text (expr (if checked "Expanded" "Collapsed"))))))

(defun etaf-test-slot-updates (container)
  "Exercise CONTAINER through controlled activation and conditional content."
  (let ((buffer (generate-new-buffer " *etaf-slot-updates*"))
        (shown (etaf-ref t))
        runtime host)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-node
            container nil
            (list
             (etaf-view
              (etaf-test-slot-switch
               :checked (etaf-value shown)
               :on-change (lambda (next) (setf (etaf-value shown) next))))
             (etaf-view (box :if (etaf-value shown) "Detail content")))))
          (setq runtime (etaf-runtime-for-buffer buffer)
                host
                (car (cl-find-if
                      (lambda (entry)
                        (equal (plist-get (cdr entry) :aria-label) "Disclosure"))
                      (etaf-runtime-host-props-entries runtime))))
          (should host)
          (dotimes (index 6)
            (etaf-dispatch-event runtime host 'press)
            (let* ((expanded (= (% index 2) 1))
                   (text (with-current-buffer buffer (buffer-string)))
                   (entries
                    (cl-remove-if-not
                     (lambda (entry)
                       (equal (plist-get (cdr entry) :aria-label) "Disclosure"))
                     (etaf-runtime-host-props-entries runtime))))
              (should (eq expanded (etaf-value shown)))
              (should (string-match-p (if expanded "Expanded" "Collapsed") text))
              (should (eq expanded (not (null (string-match-p "Detail content" text)))))
              (should (= (length entries) 1))
              (should (equal host (caar entries)))
              (should (etaf-host-ref-bounds runtime host)))))
      (when runtime (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-slot-view-composes-controlled-and-conditional-updates ()
  "A declarative slot preserves its controlled child across repeated toggles."
  (etaf-test-slot-updates 'etaf-test-slot-view-container))

(ert-deftest etaf-slot-code-composes-controlled-and-conditional-updates ()
  "Programmatic slot composition follows the same retained update contract."
  (etaf-test-slot-updates 'etaf-test-slot-code-container))

(provide 'etaf-slot-updates-tests)
;;; etaf-slot-updates-tests.el ends here
