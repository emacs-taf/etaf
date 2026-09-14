;;; etaf-instance-bindings-tests.el --- Named instance values -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise named values through mounting, public events and teardown.

;;; Code:
(require 'ert)
(require 'etaf)

(etaf-define-component etaf-test-bound-counter (&key label report)
  :bindings ((initial-label label)
             (count (etaf-ref 0))
             (double (etaf-computed (lambda () (* 2 (etaf-value count)))))
             (target (etaf-local-ref 'increment)))
  :setup
  (progn
    (funcall report 'ready initial-label count target)
    (etaf-on-unmounted (lambda () (funcall report 'removed initial-label))))
  :view
  (box :ref target :role 'button :tab-index 0
       :on-press (lambda ()
                   (funcall report 'press label)
                   (cl-incf (etaf-value count)))
    (text (expr (concat label ":" (number-to-string (etaf-value count))
                        "/" (number-to-string (etaf-value double))
                        "/" initial-label)))))

(ert-deftest etaf-instance-bindings-retain-values-and-current-props ()
  "Named refs retain identity across reorder; event props follow publication."
  (let ((buffer (generate-new-buffer " *instance-bindings*"))
        (input (etaf-ref '((a "A") (b "B"))))
        events)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (lambda ()
             (etaf-node
              'column nil
              (mapcar (lambda (entry)
                        (etaf-node
                         'etaf-test-bound-counter
                         (list :key (car entry) :label (cadr entry)
                               :report (lambda (&rest event) (push event events))) nil))
                      (etaf-value input)))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (a (cl-find "A" events :key #'cadr :test #'equal))
                 (b (cl-find "B" events :key #'cadr :test #'equal))
                 (count (nth 2 a)) (target (nth 3 a)))
            (should-not (eq count (nth 2 b)))
            (etaf-dispatch-event runtime target 'press)
            (should (= 1 (etaf-value count)))
            (setf (etaf-value input) '((b "Bee") (a "Ay")))
            (should (< (etaf-host-ref-position runtime (nth 3 b))
                       (etaf-host-ref-position runtime target)))
            (should (string-match-p "Ay:1/2/A" (with-current-buffer buffer (buffer-string))))
            (should-error (setf (etaf-value input) '((a "Rejected") (b 42))))
            ;; The committed callback remains valid. Its write retries the
            ;; still-invalid external input; publication cannot repair that input.
            (should-error (etaf-dispatch-event runtime target 'press))
            (should (equal '(press "Ay") (car events)))
            (should (= 2 (etaf-value count)))
            (should (string-match-p "Ay:1/2/A" (with-current-buffer buffer (buffer-string))))
            (setf (etaf-value input) '((b "Bee") (a "Ay")))
            (should (string-match-p "Ay:2/4/A" (with-current-buffer buffer (buffer-string))))
            (should (= 2 (cl-count 'ready events :key #'car)))
            (setf (etaf-value input) '((b "Bee")))
            (should (member '(removed "A") events))
            (should-not (etaf-host-ref-position runtime target))
            (setf (etaf-value input) '((a "Again") (b "Bee")))
            (let ((replacement (cl-find "Again" events :key #'cadr :test #'equal)))
              (should (= 0 (etaf-value (nth 2 replacement))))
              (should-not (eq count (nth 2 replacement))))
            (etaf-unmount runtime)
            (should (member '(removed "Again") events))
            (should (member '(removed "B") events))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(etaf-define-component etaf-test-bound-initialization (&key label report fail)
  :bindings ((source (let ((value (etaf-prop 'label)))
                      (funcall report value)
                      value))
             (valid (unless fail t)))
  :setup (unless valid (error "Rejected initialization"))
  :render (etaf-view (text (expr (etaf-value source)))))

(ert-deftest etaf-instance-bindings-clean-up-rejected-initialization ()
  "Failed initialization releases sources and a new mount creates fresh values."
  (let ((buffer (generate-new-buffer " *bound-initialization*")) sources)
    (unwind-protect
        (progn
          (should-error
           (etaf-mount buffer
                       (etaf-view (etaf-test-bound-initialization
                                   :label "Rejected" :fail t
                                   :report (lambda (source) (push source sources))))))
          (should-error (etaf-value (car sources)))
          (etaf-mount buffer
                      (etaf-view (etaf-test-bound-initialization
                                  :label "Ready"
                                  :report (lambda (source) (push source sources)))))
          (should (equal "Ready" (etaf-value (car sources))))
          (should-not (eq (car sources) (cadr sources)))
          (etaf-unmount (etaf-runtime-for-buffer buffer))
          (should-error (etaf-value (car sources))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-instance-bindings-validate-definition-names ()
  "Bindings require unique ordinary names distinct from props."
  (dolist (bindings '(((value 1)) ((x 1) (x 2)) ((nil 1)) ((:x 1))
                      ((x)) ((x 1 2)) (x) ((x 1) . tail)))
    (should-error
     (macroexpand `(etaf-define-component etaf-test-invalid-bindings (&key value)
                     :bindings ,bindings :view (text "Unused")))
     :type 'etaf-component-definition-error)))

(etaf-define-component etaf-test-bound-setup-result (&key read-state)
  :bindings ((label "Bound"))
  :setup (etaf-on-mounted #'ignore)
  :render (etaf-view (text (expr (if read-state (etaf-state) label)))))

(ert-deftest etaf-instance-bindings-preserve-setup-result-contract ()
  "Initialization return values are ignored; named values are the state interface."
  (let ((buffer (generate-new-buffer " *bound-setup-result*")))
    (unwind-protect
        (progn
          (should-error
           (etaf-mount buffer (etaf-view (etaf-test-bound-setup-result :read-state t)))
           :type 'etaf-component-definition-error)
          (etaf-mount buffer (etaf-view (etaf-test-bound-setup-result)))
          (should (string-match-p "Bound" (with-current-buffer buffer (buffer-string)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(etaf-define-component etaf-test-bound-resource ()
 :bindings
 ((fail (etaf-ref nil))
  (count (etaf-ref 0))
  (resource
   (let ((serial 0))
     (etaf-resource
      (lambda ()
        (cl-incf serial)
        (when (etaf-value fail)
          (setf (etaf-value fail) nil)
          (error "Failure %d" serial))
        (etaf-resource-result
         (format "Success %d" serial)
         :cleanup (lambda () (cl-incf (etaf-value count)))))
      :immediate nil))))
 :setup (etaf-on-mounted (lambda () (etaf-resource-load resource)))
 :view
 (column
  (box :width '(px 680) :padding '((lh 2) (px 18)) :text-align 'center
       :color (if (eq (etaf-resource-status resource) 'success) "black" "white")
       :border (if (eq (etaf-resource-status resource) 'success) "green" "red")
       :bgcolor (if (eq (etaf-resource-status resource) 'success) "green" "red")
   (column
    (text :font-weight 'bold (expr (symbol-name (etaf-resource-status resource))))
    (text (expr (pcase (etaf-resource-status resource)
                  ('success (etaf-resource-value resource))
                  ('error (error-message-string (etaf-resource-error resource)))
                  (_ "Loading"))))
    (text :color "gray" (expr (number-to-string (etaf-value count))))))
  (box :ref 'reload :on-press (lambda () (etaf-resource-load resource)) "Reload")
  (box :ref 'fail :on-press (lambda () (setf (etaf-value fail) t)
                                  (etaf-resource-load resource)) "Fail")))

(ert-deftest etaf-instance-bindings-compose-resource-state-and-inherited-paint ()
  "Resource reload, failure and retry keep nested text and parent paint coherent."
  (let ((buffer (generate-new-buffer " *bound-resource*")))
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-view (etaf-test-bound-resource)))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (dolist (step '((reload "success" "Success 2")
                            (fail "error" "Failure 3")
                            (reload "success" "Success 4")))
              (etaf-dispatch-event runtime (car step) 'press)
              (dolist (text (cdr step))
                (should (string-match-p text (with-current-buffer buffer (buffer-string))))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-instance-bindings-tests)
;;; etaf-instance-bindings-tests.el ends here
