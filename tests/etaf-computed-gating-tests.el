;;; etaf-computed-gating-tests.el --- Derived value publication -*- lexical-binding: t; -*-

;;; Commentary:
;; Equal derived values retain mounted publication and lifecycle state.

;;; Code:

(require 'ert)
(require 'etaf)

(etaf-define-component etaf-test-derived-consumer (&key source report)
  :setup (progn (etaf-on-updated report) nil)
  :render (etaf-node 'text nil (list (format "%s" (etaf-value source)))))

(ert-deftest etaf-computed-equality-retains-mounted-publication ()
  "Root, Component and inline consumers publish only changed derived values."
  (dolist (mode '(root component inline))
    (let* ((buffer (generate-new-buffer " *derived-equality*"))
           (source (etaf-ref 2))
           (derived (etaf-computed (lambda () (list (/ (etaf-value source) 2)))
                                   :test #'equal))
           updates)
      (unwind-protect
          (let* ((mounted
                  (etaf-mount
                   buffer
                   (pcase mode
                     ('root (lambda () (etaf-node 'text nil
                                                   (list (format "%s" (etaf-value derived))))))
                     ('component
                      (etaf-view
                       (etaf-test-derived-consumer
                        :source derived :report (lambda () (push 'updated updates)))))
                     ('inline (etaf-view (text (expr (format "%s" (etaf-value derived)))))))))
                 (runtime (etaf-runtime-for-buffer mounted))
                 (revision (etaf-runtime-flush runtime)))
            (should (equal "(1)" (with-current-buffer buffer (buffer-string))))
            (setf (etaf-value source) 3)
            (should (= revision (etaf-runtime-flush runtime)))
            (should-not updates)
            (setf (etaf-value source) 4)
            (should (> (etaf-runtime-flush runtime) revision))
            (should (equal "(2)" (with-current-buffer buffer (buffer-string))))
            (when (eq mode 'component) (should (equal updates '(updated)))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
        (kill-buffer buffer)))))

(ert-deftest etaf-computed-equality-retargets-conditional-inputs ()
  "An equal derived result still follows its newly selected dependency."
  (let* ((buffer (generate-new-buffer " *derived-retarget*"))
         (which (etaf-ref nil))
         (one (etaf-ref "A"))
         (two (etaf-ref "A"))
         (derived (etaf-computed (lambda () (etaf-value (if (etaf-value which) two one))))))
    (unwind-protect
        (let* ((mounted (etaf-mount buffer (etaf-view (text (expr (etaf-value derived))))))
               (runtime (etaf-runtime-for-buffer mounted))
               (revision (etaf-runtime-flush runtime)))
          (setf (etaf-value which) t)
          (should (= revision (etaf-runtime-flush runtime)))
          (setf (etaf-value one) "unused")
          (should (= revision (etaf-runtime-flush runtime)))
          (setf (etaf-value two) "B")
          (should (equal "B" (with-current-buffer buffer (buffer-string)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-computed-settlement-preserves-unused-laziness ()
  "Previously read but unobserved computations remain lazy during publication."
  (let* ((buffer (generate-new-buffer " *derived-lazy*"))
         (source (etaf-ref 1))
         (unused (etaf-computed (lambda ()
                                  (if (= (etaf-value source) 1) "initial"
                                    (error "Unused computation evaluated")))))
         (used (etaf-computed (lambda () (number-to-string (etaf-value source))))))
    (unwind-protect
        (progn
          (should (equal "initial" (etaf-value unused)))
          (etaf-mount buffer (etaf-view (text (expr (etaf-value used)))))
          (setf (etaf-value source) 2)
          (should (equal "2" (with-current-buffer buffer (buffer-string))))
          (should-error (etaf-value unused)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-computed-settlement-failure-preserves-retry ()
  "A failed getter retains published output and pending work for explicit retry."
  (let* ((buffer (generate-new-buffer " *derived-retry*"))
         (source (etaf-ref 1))
         reject
         (derived (etaf-computed
                   (lambda ()
                     (when (eq reject 'getter) (error "Rejected derived input"))
                     (number-to-string (etaf-value source)))
                   :test (lambda (old new)
                           (when (eq reject 'comparison) (error "Rejected comparison"))
                           (equal old new)))))
    (unwind-protect
        (let* ((mounted (etaf-mount buffer (etaf-view (text (expr (etaf-value derived))))))
               (runtime (etaf-runtime-for-buffer mounted))
               (revision (etaf-runtime-flush runtime)))
          (setq reject 'getter)
          (should-error (setf (etaf-value source) 2))
          (should (= 2 (etaf-value source)))
          (should (equal "1" (with-current-buffer buffer (buffer-string))))
          (setq reject nil)
          (should (> (etaf-runtime-flush runtime) revision))
          (should (equal "2" (with-current-buffer buffer (buffer-string))))
          (setq reject 'comparison)
          (should-error (setf (etaf-value source) 3))
          (should (equal "2" (with-current-buffer buffer (buffer-string))))
          (setq reject nil)
          (etaf-runtime-flush runtime)
          (should (equal "3" (with-current-buffer buffer (buffer-string)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-computed-settlement-observes-complete-batch ()
  "Unequal-depth derived inputs settle before mounted publication."
  (let* ((buffer (generate-new-buffer " *derived-batch*"))
         (left (etaf-ref 2)) (right (etaf-ref 2))
         (one (etaf-computed (lambda () (etaf-value left))))
         (two (etaf-computed (lambda () (etaf-value right))))
         (three (etaf-computed (lambda () (etaf-value two))))
         (derived (etaf-computed (lambda () (= (etaf-value one) (etaf-value three))))))
    (unwind-protect
        (let* ((mounted (etaf-mount buffer (etaf-view (text (expr (format "%s" (etaf-value derived)))))))
               (runtime (etaf-runtime-for-buffer mounted))
               (revision (etaf-runtime-flush runtime)))
          (etaf-batch
            (setf (etaf-value left) 3)
            (setf (etaf-value right) 3))
          (should (= revision (etaf-runtime-flush runtime)))
          (setf (etaf-value left) 4)
          (should (equal "nil" (with-current-buffer buffer (buffer-string)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-computed-settlement-retires-before-child-read ()
  "Removing a branch does not evaluate that branch's newly invalid getter."
  (dolist (root-p '(nil t))
    (let* ((buffer (generate-new-buffer " *derived-retire*"))
           (visible (etaf-ref t)) (source (etaf-ref 1))
           (derived (etaf-computed (lambda ()
                                     (if (> (etaf-value source) 0) "child"
                                       (error "Retired child was evaluated"))))))
      (unwind-protect
          (progn
            (etaf-mount
             buffer
             (if root-p
                 (lambda ()
                   (when (etaf-value visible)
                     (etaf-view (text (expr (etaf-value derived))))))
               (etaf-view
                (column
                 (expr (when (etaf-value visible)
                         (etaf-view (text (expr (etaf-value derived))))))))))
            (etaf-batch
              (setf (etaf-value source) -1)
              (setf (etaf-value visible) nil))
            (should (equal "" (with-current-buffer buffer (buffer-string)))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
        (kill-buffer buffer)))))

(etaf-define-component etaf-test-derived-input (&key label source report)
  :setup (progn (etaf-on-updated report) nil)
  :render (etaf-node 'text nil (list (format "%s:%s" label (etaf-value source)))))

(ert-deftest etaf-computed-equality-settles-component-input-and-render ()
  "Equal Component input and render dependencies retain their publication."
  (let* ((buffer (generate-new-buffer " *derived-input*"))
         (source (etaf-ref 2))
         (derived (etaf-computed (lambda () (/ (etaf-value source) 2))))
         updates)
    (unwind-protect
        (progn
          (etaf-mount buffer
                      (etaf-view
                       (etaf-test-derived-input
                        :label (etaf-value derived) :source derived
                        :report (lambda () (push 'updated updates)))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (revision (etaf-runtime-flush runtime)))
            (setf (etaf-value source) 3)
            (should (= revision (etaf-runtime-flush runtime)))
            (should-not updates)
            (setf (etaf-value source) 4)
            (should (equal "2:2" (with-current-buffer buffer (buffer-string))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-computed-equality-retains-host-geometry-publication ()
  "Computed Host properties retain equality across successive geometry commits."
  (let* ((buffer (generate-new-buffer " *derived-host*"))
         (source (etaf-ref 2))
         (left (etaf-computed (lambda () (list 'ch (/ (etaf-value source) 2)))
                              :test #'equal)))
    (unwind-protect
        (progn
          (etaf-mount buffer
                      (etaf-view
                       (box :position 'relative :width '(ch 20) :height '(lh 2)
                            (box :position 'absolute :left (etaf-value left)
                                 :top '(lh 0) :width '(ch 2) :height '(lh 1)
                                 "X"))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (revision (etaf-runtime-flush runtime)))
            (setf (etaf-value source) 3)
            (should (= revision (etaf-runtime-flush runtime)))
            (setf (etaf-value source) 4)
            (setq revision (etaf-runtime-flush runtime))
            (setf (etaf-value source) 5)
            (should (= revision (etaf-runtime-flush runtime)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(etaf-define-component etaf-test-derived-context-child (&key source)
  :bindings
  ((display (etaf-computed
             (lambda () (format "%s:%s" (etaf-inject 'derived-prefix nil t)
                                 (etaf-value source))))))
  :view (text (expr (etaf-value display))))

(etaf-define-component etaf-test-derived-context-parent (&key source)
  :setup (progn (etaf-provide 'derived-prefix "prefix") nil)
  :view (etaf-test-derived-context-child :source source))

(ert-deftest etaf-computed-settlement-preserves-consumer-context ()
  "A lazy getter retains its consumer environment and Context render tracking."
  (let ((buffer (generate-new-buffer " *derived-context*"))
        (source (etaf-ref 1)))
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-view (etaf-test-derived-context-parent :source source)))
          (setf (etaf-value source) 2)
          (should (equal "prefix:2" (with-current-buffer buffer (buffer-string)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-computed-gating-tests)
;;; etaf-computed-gating-tests.el ends here
