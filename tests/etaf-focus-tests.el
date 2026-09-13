;;; etaf-focus-tests.el --- Shared Ebox focus acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Verify that both package entries observe and operate one mounted focus.

;;; Code:
(require 'ert)
(require 'etaf)
(require 'ebox)

(ert-deftest etaf-focus-shares-ebox-ownership-and-reactive-navigation ()
  "Both APIs observe one focus while tab order, disabled and visibility change."
  (let ((buffer (generate-new-buffer " *etaf-shared-focus*"))
        (order (etaf-ref 0)) (disabled (etaf-ref nil)) (hidden (etaf-ref nil))
        (window (selected-window)))
    (unwind-protect
        (progn
          (etaf-mount buffer
                      (etaf-view
                       (column
                         (box :ref 'a :tab-index (etaf-value order)
                              :disabled (etaf-value disabled) "A")
                         (box :ref 'b :tab-index 1
                              :visibility (if (etaf-value hidden) 'hidden 'visible) "B")
                         (text :ref 'c :tab-index -1 "C"))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (should (eq (etaf-focus runtime 'a) 'a))
            (should (eq (ebox-focused-host-ref buffer) 'a))
            (ebox-focus 'b buffer)
            (should (eq (etaf-focused-host-ref runtime) 'b))
            (should (eq (etaf-focus runtime) 'a))
            (setf (etaf-value order) 2)
            (should (eq (etaf-focus runtime) 'b))
            (should (eq (ebox-focus-first buffer) 'b))
            (should (eq (etaf-focus runtime 'c) 'c))
            (ebox-focus nil buffer)
            (should-not (etaf-focused-host-ref runtime))
            (should (eq (etaf-focus-previous runtime) 'a))
            (setf (etaf-value order) nil)
            (should (eq (etaf-focused-host-ref runtime) 'a))
            (should (eq (etaf-focus-next runtime) 'b))
            (etaf-focus runtime 'a)
            (setf (etaf-value disabled) t)
            (should-not (etaf-focused-host-ref runtime))
            (should-not (ebox-focused-host-ref buffer))
            (should-error (etaf-focus runtime 'a) :type 'etaf-event-error)
            (should (eq (etaf-focus-next runtime) 'b))
            (setf (etaf-value hidden) t)
            (should-not (etaf-focused-host-ref runtime))
            (etaf-focus runtime 'c)
            (let ((position (with-current-buffer buffer (point))))
              (should-error (etaf-focus runtime) :type 'user-error)
              (should (eq (ebox-focused-host-ref buffer) 'c))
              (should (= position (with-current-buffer buffer (point)))))
            (setf (etaf-value order) nil)
            (should (eq (etaf-focused-host-ref runtime) 'c))
            (should (eq window (selected-window)))
            (etaf-unmount runtime)
            (should-not (ebox-focused-host-ref buffer))
            (should-error (ebox-focus 'c buffer) :type 'user-error)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-focus-follows-identity-across-removal-rejection-and-apps ()
  "Shared focus follows references through reorder, isolates mounts and rejects candidates."
  (let ((first (generate-new-buffer " *etaf-focus-one*"))
        (second (generate-new-buffer " *etaf-focus-two*"))
        (rows (etaf-ref '((a "A") (b "B")))))
    (unwind-protect
        (progn
          (dolist (buffer (list first second))
            (etaf-mount
             buffer
             (lambda ()
               (etaf-node
                'column nil
                (mapcar (lambda (row)
                          (etaf-node 'text (list :ref (car row) :tab-index 0) (list (cadr row))))
                        (etaf-value rows))))))
          (let ((runtime (etaf-runtime-for-buffer first)))
            (etaf-focus runtime 'a)
            (ebox-focus 'b second)
            (setf (etaf-value rows) '((b "B longer") (a "A longer")))
            (should (eq (etaf-focused-host-ref runtime) 'a))
            (should (eq (ebox-focused-host-ref first) 'a))
            (should (eq (ebox-focused-host-ref second) 'b))
            (with-current-buffer first (should (looking-at "A longer")))
            (with-current-buffer second (should (looking-at "B longer")))
            (should-error (setf (etaf-value rows) '((a "Rejected") (b 42))))
            (should (eq (ebox-focused-host-ref first) 'a))
            (with-current-buffer first (should (looking-at "A longer")))
            (setf (etaf-value rows) '((b "B only")))
            (should-not (etaf-focused-host-ref runtime))
            (should (eq (ebox-focused-host-ref second) 'b))
            (should (eq (etaf-focus-next runtime) 'b))
            (etaf-unmount runtime)
            (should-not (ebox-focused-host-ref first))
            (should (eq (ebox-focused-host-ref second) 'b))))
      (dolist (buffer (list first second))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
        (kill-buffer buffer)))))

(provide 'etaf-focus-tests)
;;; etaf-focus-tests.el ends here
