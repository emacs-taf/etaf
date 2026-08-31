;;; etaf-m0a-current-characterization-tests.el --- M0a ETAF baseline -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'etaf)
(require 'etaf-m0a-inventory)

(define-error 'etaf-test-m0a-lifecycle-condition
  "M0a lifecycle characterization condition")

(defconst etaf-test-m0a-condition-data
  '(:phase updated
    :payload ((account-id . 42) (tags alpha beta))
    :retryable nil)
  "Non-trivial raw condition data used by the M0a public update probe.")

(etaf-define-component etaf-test-m0a-dependency-only (&key source)
  "Observe SOURCE while retaining equal rendered output."
  :view (text (expr (progn (etaf-value source) "same"))))

(etaf-define-component etaf-test-m0a-lifecycle-failure (&key label)
  "Publish LABEL, then signal a custom condition from the update lifecycle."
  :setup
  (progn
    (etaf-on-updated
     (lambda ()
       (signal 'etaf-test-m0a-lifecycle-condition
               etaf-test-m0a-condition-data)))
    nil)
  :view (text (expr label)))

(ert-deftest etaf-m0a-action-registration-requires-explicit-redefinition ()
  "Duplicate Action registration fails outside the authoring boundary."
  (let* ((name (make-symbol "etaf-m0a-action"))
         (first (lambda (_runtime) 'first))
         (second (lambda (_runtime) 'second)))
    (unwind-protect
        (progn
          (etaf-action-register name first)
          (should-error (etaf-action-register name second)
                        :type 'etaf-action-error)
          (should (eq first
                      (etaf-action-spec-function
                       (gethash name etaf--action-registry))))
          (etaf-action-redefine-run
           (lambda () (etaf-action-register name second)))
          (should (eq second
                      (etaf-action-spec-function
                       (gethash name etaf--action-registry)))))
      (etaf-action-undefine name))))

(ert-deftest etaf-m0a-event-kind-normalizes-current-spellings ()
  "Keyword, symbol, and string event spellings normalize to one symbol."
  (dolist (spelling '(:press press on-press "press" "on-press"))
    (should (eq 'press (etaf-event-kind spelling)))))

(ert-deftest etaf-m0a-dependency-only-skips-ebox-and-tp-publication ()
  "An equal-output dependency update advances ETAF only, not Ebox or TP."
  (let ((buffer-name " *etaf-m0a-dependency-only*")
        (source (etaf-ref 0))
        (ebox-commits 0))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view (etaf-test-m0a-dependency-only :source source)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (surface (with-current-buffer buffer-name
                            (car tp--buffer-surfaces)))
                 (generation (etaf-runtime-generation runtime))
                 (revision (tp-surface-revision surface))
                 (original-ebox-commit (symbol-function 'ebox-commit)))
            (cl-letf (((symbol-function 'ebox-commit)
                       (lambda (&rest arguments)
                         (cl-incf ebox-commits)
                         (apply original-ebox-commit arguments))))
              (setf (etaf-value source) 1))
            (should (= (1+ generation) (etaf-runtime-generation runtime)))
            (should (zerop ebox-commits))
            (should (= revision (tp-surface-revision surface)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-m0a-repeated-public-unmount-signals-runtime-error ()
  "Calling the public unmount boundary twice signals runtime error."
  (let ((buffer-name " *etaf-m0a-repeated-unmount*") runtime)
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (text "mounted")))
          (setq runtime (etaf-runtime-for-buffer buffer-name))
          (etaf-unmount runtime)
          (should-error (etaf-unmount runtime) :type 'etaf-runtime-error))
      (when (and runtime (etaf-runtime-mounted-p runtime))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-m0a-public-update-preserves-raw-condition-symbol-and-data ()
  "A public update exposes the exact lifecycle condition symbol and payload."
  (let ((buffer-name " *etaf-m0a-lifecycle-condition*")
        (label (etaf-ref "A"))
        captured)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (lambda ()
             (etaf-view
              (etaf-test-m0a-lifecycle-failure
               :label (etaf-value label)))))
          (condition-case condition
              (setf (etaf-value label) "B")
            (etaf-test-m0a-lifecycle-condition
             (setq captured condition)))
          (should
           (equal captured
                  (cons 'etaf-test-m0a-lifecycle-condition
                        etaf-test-m0a-condition-data)))
          (should (equal "B"
                         (with-current-buffer buffer-name
                           (buffer-string)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-m0a-condition-consumer-inventory-is-machine-readable ()
  "The source consumer inventory exactly matches its reviewed golden."
  (let ((consumers (etaf-m0a-condition-consumer-inventory))
        (golden-file
         (expand-file-name "tests/fixtures/etaf-m0a-condition-consumers.sexp"
                           etaf-m0a-package-root)))
    (should consumers)
    (should (cl-find "etaf-runtime.el" consumers
                     :key (lambda (entry) (plist-get entry :file))
                     :test #'equal))
    (should (cl-every (lambda (entry)
                        (and (stringp (plist-get entry :file))
                             (integerp (plist-get entry :line))
                             (symbolp (plist-get entry :form))
                             (proper-list-p (plist-get entry :conditions))
                             (symbolp (plist-get entry :owner))
                             (memq (plist-get entry :policy)
                                   '(generic-containment
                                     specific-compatibility))))
                      consumers))
    (with-temp-buffer
      (insert-file-contents golden-file)
      (should (equal (read (current-buffer))
                     (etaf-m0a-condition-consumer-signatures)))
      (skip-chars-forward " \t\r\n")
      (should (eobp)))
    (should (cl-find 'observed-baseline
                     etaf-m0a-current-contract-inventory
                     :key (lambda (entry)
                            (plist-get entry :evidence-mode))))
    (let ((json (json-parse-string (etaf-m0a-inventory-json))))
      (should (= 1 (gethash "schema-version" json)))
      (should (= (length etaf-m0a-current-contract-inventory)
                 (length (gethash "contract-inventory" json))))
      (should (= (length consumers)
                 (length (gethash "condition-consumers" json))))
      (should (= (length etaf-m0a-document-example-files)
                 (length (gethash "document-examples" json)))))))

(ert-deftest etaf-m0a-document-example-inventory-matches-reviewed-golden ()
  "Every user documentation block matches its reviewed M0a outcome."
  (let* ((golden-file
          (expand-file-name "tests/fixtures/etaf-m0a-document-examples.sexp"
                            etaf-m0a-package-root))
         (inventory (etaf-m0a-document-example-inventory))
         (blocks (apply #'append
                        (mapcar (lambda (entry)
                                  (plist-get entry :blocks))
                                inventory)))
         golden)
    (with-temp-buffer
      (insert-file-contents golden-file)
      (setq golden (read (current-buffer)))
      (skip-chars-forward " \t\r\n")
      (should (eobp)))
    (should (equal golden (etaf-m0a-document-example-signatures)))
    (should (= 122 (length blocks)))
    (should (= 0 (cl-count 'read-error blocks
                           :key (lambda (entry)
                                  (plist-get entry :drift)))))
    (should (= 4 (cl-count 'macroexpand-error blocks
                            :key (lambda (entry)
                                   (plist-get entry :drift)))))
    (should (cl-every
             (lambda (entry)
               (and (eq 'skipped-unsafe (plist-get entry :load-status))
                    (eq 'arbitrary-document-code
                        (plist-get entry :load-reason))))
             blocks))))

(provide 'etaf-m0a-current-characterization-tests)
;;; etaf-m0a-current-characterization-tests.el ends here
