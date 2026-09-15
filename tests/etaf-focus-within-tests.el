;;; etaf-focus-within-tests.el --- Shared subtree navigation -*- lexical-binding: t; -*-

;;; Commentary:
;; Components use the same focus authority as independent Ebox consumers.

;;; Code:
(require 'ert)
(require 'etaf)
(require 'ebox)

(ert-deftest etaf-focus-within-shares-provider-order-and-reactive-visibility ()
  "Nested controls navigate inside a panel and follow accepted disabled state."
  (let ((disabled (etaf-ref nil)))
    (with-temp-buffer
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (column
                (box :ref 'outside :tab-index 0 "Outside")
                (column :ref 'panel
                  (box :ref 'first :tab-index 0 "First")
                  (column (box :ref 'second :tab-index 0
                               :disabled (etaf-value disabled) "Second"))))))
            (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
              (etaf-focus runtime 'outside)
              (should-not (etaf-focus-within runtime 'panel 0))
              (should (eq (etaf-focus-within runtime 'panel) 'first))
              (should (eq (ebox-focused-host-ref) 'first))
              (should (eq (etaf-focus-within runtime 'panel -1) 'second))
              (should (eq (ebox-focus-within 'panel 1 t) 'first))
              (should (eq (etaf-focused-host-ref runtime) 'first))
              (setf (etaf-value disabled) t)
              (should (eq (etaf-focus-within runtime 'panel 1) 'first))
              (should-error (etaf-focus-within runtime 'missing) :type 'user-error)))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(provide 'etaf-focus-within-tests)
;;; etaf-focus-within-tests.el ends here
