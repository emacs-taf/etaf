;;; etaf-host-properties-tests.el --- Host and Component composition -*- lexical-binding: t; -*-

;;; Commentary:
;; Reactive Host attributes compose with retained Component state and siblings.

;;; Code:
(require 'ert)
(require 'etaf)

(etaf-define-component etaf-test-host-properties-counter ()
  :bindings ((count (etaf-ref 0)))
  :view
  (box :ref 'counter :tab-index 0
       :on-press (lambda () (cl-incf (etaf-value count)))
    (text (expr (format "Count %d" (etaf-value count))))))

(ert-deftest etaf-host-properties-compose-with-retained-components ()
  "Parent geometry and interaction changes preserve child state and handlers."
  (let ((state (etaf-ref nil))
        (buffer (generate-new-buffer " *etaf-host-properties*")))
    (unwind-protect
        (let ((runtime
               (etaf-runtime-for-buffer
                (etaf-mount
                 buffer
                 (etaf-view
                  (column
                   (box :ref 'panel
                        :width (if (etaf-value state) '(ch 18) '(ch 30))
                        :padding (if (etaf-value state) '((lh 1) (ch 2)) nil)
                        :color (if (etaf-value state) "red" "blue")
                        :disabled (etaf-value state)
                        :on-press (lambda () (setf (etaf-value state) t))
                        (etaf-test-host-properties-counter)
                        (text (expr (if (etaf-value state) "Expanded" "Compact"))))
                   (expr (when (etaf-value state) (etaf-view (text "Extra"))))))))))
          (etaf-dispatch-event runtime 'counter 'press)
          (dolist (value '(t nil t))
            (setf (etaf-value state) value)
            (with-current-buffer buffer
              (should (string-match-p "Count 1" (buffer-string)))
              (should (string-match-p (if value "Expanded" "Compact") (buffer-string)))
              (should (eq (not (null (string-match-p "Extra" (buffer-string)))) value)))
            (should (etaf-host-ref-position runtime 'counter)))
          (etaf-dispatch-event runtime 'counter 'press)
          (with-current-buffer buffer
            (should (string-match-p "Count 2" (buffer-string)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(etaf-define-component etaf-test-host-properties-frame (&key expanded)
  :view
  (column
   (expr (when expanded (etaf-view (text "Expanded"))))
   (slot)))

(etaf-define-component etaf-test-host-properties-leaf (&key name caption width reject)
  :view
  (box :ref name :width (etaf-value width)
    (text (expr (let ((value (etaf-value caption)))
                  (when (funcall reject) (error "Rejected caption"))
                  (concat "Value: " value))))))

(defun etaf-test-host-properties-appearance (text)
  "Return TEXT's visible characters, faces and geometry."
  (cl-loop for index below (length text)
           collect (list (aref text index)
                         (get-text-property index 'face text)
                         (get-text-property index 'display text))))

(ert-deftest etaf-host-properties-batches-compose-shared-ancestors-and-retry ()
  "Sibling updates, enclosing output changes and retries retain final output."
  (let ((buffer (generate-new-buffer " *etaf-host-shared-ancestors*"))
        (expanded (etaf-ref nil))
        (left (etaf-ref "Left 0"))
        (right (etaf-ref "Right 0"))
        (width (etaf-ref '(ch 18)))
        rejected)
    (unwind-protect
        (let* ((view
                (etaf-view
                 (etaf-test-host-properties-frame :expanded (etaf-value expanded)
                   (etaf-test-host-properties-frame
                     (etaf-test-host-properties-leaf
                      :name 'left :caption left :width width :reject (lambda () nil))
                     (etaf-test-host-properties-leaf
                      :name 'right :caption right :width width
                      :reject (lambda () rejected))))))
               (runtime (etaf-runtime-for-buffer (etaf-mount buffer view))))
          (cl-labels
              ((appearance ()
                 (etaf-test-host-properties-appearance
                  (with-current-buffer buffer (buffer-string))))
               (assert-current ()
                 (let ((fresh (etaf-test-host-properties-appearance
                               (ebox-render (etaf-render view)))))
                   (should (equal fresh (appearance)))
                   (should
                    (equal fresh
                           (etaf-test-host-properties-appearance
                            (ebox-render
                             (plist-get (etaf-runtime-snapshot runtime) :input))))))
                 (dolist (host '(left right))
                   (should
                    (equal (etaf-value width)
                           (plist-get (etaf-runtime-host-props-for runtime host)
                                      :width))))))
            (assert-current)
            (let* ((snapshot (etaf-runtime-snapshot runtime))
                   (original (etaf-test-host-properties-appearance
                              (ebox-render (plist-get snapshot :input)))))
              ;; Recompose both siblings beneath shared Host, Component and
              ;; slot ancestors, with and without enclosing structural work.
              (dotimes (index 4)
                (etaf-batch
                  (etaf-set-value left (format "Left %d" (1+ index)))
                  (etaf-set-value right (format "Right %d" (1+ index)))
                  (etaf-set-value width (list 'ch (+ 19 index)))
                  (etaf-set-value expanded (cl-oddp index)))
                (assert-current))
              (should
               (equal original
                      (etaf-test-host-properties-appearance
                       (ebox-render (plist-get snapshot :input))))))
            (let ((before (appearance))
                  (revision (etaf-runtime-generation runtime))
                  (left-props (etaf-runtime-host-props-for runtime 'left)))
              (setq rejected t)
              (should-error
               (etaf-batch
                 (etaf-set-value left "Retried left")
                 (etaf-set-value right "Retried right")
                 (etaf-set-value width '(ch 25)))
               :type 'error)
              (should (equal before (appearance)))
              (should (= revision (etaf-runtime-generation runtime)))
              (should (equal left-props
                             (etaf-runtime-host-props-for runtime 'left)))
              (should
               (equal before
                      (etaf-test-host-properties-appearance
                       (ebox-render
                        (plist-get (etaf-runtime-snapshot runtime) :input)))))
              (setq rejected nil)
              (should (= (1+ revision) (etaf-runtime-flush runtime)))
              (assert-current))
            ;; A subsequent enclosing render must use the accepted descendants,
            ;; including their retried property and inline output.
            (etaf-set-value expanded nil)
            (assert-current)
            (etaf-batch
              (etaf-set-value left "Final left")
              (etaf-set-value right "Final right"))
            (assert-current)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'etaf-host-properties-tests)
;;; etaf-host-properties-tests.el ends here
