;;; etaf-retirement-tests.el --- M3a retirement gates -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'cl-lib)
(require 'ert)
(require 'etaf)
(require 'etaf-retirement)

(define-error 'etaf-retirement-test-condition
  "ETAF retirement test condition")

(defvar etaf-retirement-test-update-fail-p nil)
(defvar etaf-retirement-test-update-count 0)
(defvar etaf-retirement-test-unmount-first-count 0)
(defvar etaf-retirement-test-unmount-second-count 0)
(defvar etaf-retirement-test-scope-cleanup-count 0)

(etaf-define-component etaf-retirement-test-updated (&key source)
  "Render SOURCE and expose a failing updated lifecycle entry."
  :setup
  (progn
    (etaf-on-updated
     (lambda ()
       (cl-incf etaf-retirement-test-update-count)
       (when etaf-retirement-test-update-fail-p
         (signal 'etaf-retirement-test-condition
                 '("update failed" :payload update)))))
    nil)
  :view
  (text (expr (format "updated=%s" (etaf-value source)))))

(etaf-define-component etaf-retirement-test-unmounted ()
  "Expose ordered unmounted hooks and structural scope cleanup."
  :setup
  (progn
    (etaf-on-unmounted
     (lambda ()
       (cl-incf etaf-retirement-test-unmount-first-count)
       (signal 'etaf-retirement-test-condition
               '("unmount failed" :payload unmount))))
    (etaf-on-unmounted
     (lambda () (cl-incf etaf-retirement-test-unmount-second-count)))
    (etaf-on-scope-dispose
     (lambda () (cl-incf etaf-retirement-test-scope-cleanup-count)))
    nil)
  :view (text "retire"))

(ert-deftest etaf-retirement-drain-stops-public-and-continues-structure ()
  "First public failure abandons later hooks but retries structural cleanup."
  (let ((journal
         (etaf-retirement-journal-create
          :operation-id 1 :outcome-id 2 :generation-id 3 :revision 4))
        (attempts 0)
        trace)
    (etaf-retirement-enqueue
     journal :owner 'first :kind 'updated
     :payload (lambda ()
                (push 'first trace)
                (signal 'etaf-retirement-test-condition '("first")))
     :ordering-key 1 :policy 'run-once-public :max-attempts 1)
    (etaf-retirement-enqueue
     journal :owner 'second :kind 'updated
     :payload (lambda () (push 'second trace))
     :ordering-key 2 :policy 'run-once-public :max-attempts 1)
    (etaf-retirement-enqueue
     journal :owner 'structure :kind 'route-cleanup
     :payload (lambda ()
                (cl-incf attempts)
                (push 'structure trace)
                (when (= attempts 1) (error "retry")))
     :ordering-key 3 :policy 'retryable-idempotent :max-attempts 2)
    (let ((condition (etaf-retirement-drain journal)))
      (should (eq (car condition) 'etaf-retirement-test-condition))
      (should (equal (nreverse trace) '(first structure structure)))
      (should (= attempts 2))
      (should
       (equal (mapcar #'etaf-retirement-entry-state
                      (etaf-retirement-journal-entries journal))
              '(failed-contained abandoned-contained completed))))))

(ert-deftest etaf-retirement-ordering-keys-sort-structurally ()
  "Numeric ordering remains correct after single-digit entry counts."
  (let ((journal
         (etaf-retirement-journal-create
          :operation-id 4 :outcome-id 5 :generation-id 6 :revision 7))
        trace)
    (dolist (key '((2 10 0) (2 2 0) (1 12 0) (1 3 0)))
      (let ((captured-key key))
        (etaf-retirement-enqueue
         journal :owner captured-key :kind 'ordering
         :payload (lambda () (push captured-key trace))
         :ordering-key captured-key :policy 'contained-once :max-attempts 1)))
    (should-not (etaf-retirement-drain journal))
    (should (equal (nreverse trace)
                   '((1 3 0) (1 12 0) (2 2 0) (2 10 0))))))

(ert-deftest etaf-retirement-condition-trailer-is-cause-compatible ()
  "Re-signal keeps symbol/data prefix and the reader rejects lookalikes."
  (let* ((journal
          (etaf-retirement-journal-create
           :operation-id 7 :outcome-id 8 :generation-id 9 :revision 10))
         captured)
    (condition-case condition
        (etaf-retirement-resignal
         '(etaf-retirement-test-condition "original" (:business t))
         journal)
      (etaf-retirement-test-condition (setq captured condition)))
    (should (eq (car captured) 'etaf-retirement-test-condition))
    (should (equal (butlast (cdr captured))
                   '("original" (:business t))))
    (should
     (equal (etaf-condition-postcommit-info captured)
            (list :kind 'postcommit :committed-p t :operation-id 7
                  :outcome-id 8 :generation-id 9 :revision 10
                  :diagnostic-journal-id
                  (etaf-retirement-journal-id journal))))
    (should-not
     (etaf-condition-postcommit-info
      '(error (:etaf-condition-trailer/v1 (:kind postcommit)) business)))
    (should-not
     (etaf-condition-postcommit-info
      '(error business
              (:etaf-condition-trailer/v2
               (:kind postcommit :committed-p t)))))
    (dolist
        (malformed
         '((:kind postcommit :committed-p t :operation-id 1
            :outcome-id 2 :generation-id 3 :revision 4
            :diagnostic-journal-id 5 :unexpected accepted)
           (:kind postcommit :committed-p t :operation-id 1
            :outcome-id 2 :generation-id 3 :revision 4
            :diagnostic-journal-id 5 :operation-id 6)
           (:kind postcommit :committed-p t :operation-id 1
            :outcome-id 2 :generation-id 3 :revision 4
            :diagnostic-journal-id)
           (:kind postcommit :committed-p t :operation-id -1
            :outcome-id 2 :generation-id 3 :revision 4
            :diagnostic-journal-id 5)))
      (should-not
       (etaf-condition-postcommit-info
        (list 'error
              (list :etaf-condition-trailer/v1 malformed)))))
    (let (decorated)
      (condition-case condition
          (etaf-retirement-resignal
           '(etaf-retirement-test-condition
             "business"
             (:etaf-condition-trailer/v1
              (:kind postcommit :committed-p t :operation-id 1
               :outcome-id 2 :generation-id 3 :revision 4
               :diagnostic-journal-id 5 :unexpected accepted)))
           journal)
        (etaf-retirement-test-condition (setq decorated condition)))
      (should decorated)
      (should (etaf-condition-postcommit-info decorated))
      (should (= 3 (length (cdr decorated)))))))

(ert-deftest etaf-retirement-data-projection-trailer-reader ()
  "Projection trailers are readable while preserving the condition prefix."
  (let* ((journal (etaf-retirement-journal-create
                   :operation-id 11 :outcome-id 12 :generation-id 13
                   :revision 14))
         (trailer (etaf-retirement-condition-trailer
                   journal 'projection
                   :external-commit-certainty 'committed
                   :reconciliation-token 'reconcile-1
                   :projection-token 'projection-1
                   :result 'mutation-result))
         (condition (append '(etaf-retirement-test-condition "business"
                              (:cause original)) (list trailer)))
         (info (etaf-data-condition-projection-info condition)))
    (should info)
    (should (equal (butlast (cdr condition))
                   '("business" (:cause original))))
    (should (equal info
                   (list :kind 'projection :committed-p t
                         :external-commit-certainty 'committed
                         :reconciliation-token 'reconcile-1
                         :projection-token 'projection-1
                         :result 'mutation-result
                         :operation-id 11 :outcome-id 12
                         :generation-id 13 :revision 14
                         :diagnostic-journal-id
                         (etaf-retirement-journal-id journal))))
    (should-not (etaf-condition-postcommit-info condition))
    ;; Unknown versions, malformed payloads, and non-final lookalikes are inert.
    (should-not
     (etaf-data-condition-projection-info
      '(error (:etaf-condition-trailer/v2 (:kind projection)))))
    (should-not
     (etaf-data-condition-projection-info
      '(error (:etaf-condition-trailer/v1
               (:kind projection :committed-p t
                :external-commit-certainty committed
                :reconciliation-token r :projection-token p
                :operation-id 1 :outcome-id 2 :generation-id 3 :revision 4
                :diagnostic-journal-id 5 :unexpected x)))))
    (should
     (etaf-data-condition-projection-info
      (list 'error
            '(:etaf-condition-trailer/v1
               (:kind projection :committed-p t
                :external-commit-certainty committed
                :reconciliation-token r :projection-token p :result result
                :operation-id 1 :outcome-id 2 :generation-id 3 :revision 4
                :diagnostic-journal-id 5))
            '(:etaf-condition-trailer/v1
              (:kind projection :committed-p t
               :external-commit-certainty committed
               :reconciliation-token r :projection-token p :result result
               :operation-id 1 :outcome-id 2 :generation-id 3 :revision 4
               :diagnostic-journal-id 6)))))))

(ert-deftest etaf-retirement-updated-error-is-committed-and-not-rerun ()
  "Updated hook error carries a trailer while generation and buffer stay new."
  (let ((buffer-name " *etaf-retirement-update-test*")
        (source (etaf-ref "A"))
        captured)
    (setq etaf-retirement-test-update-count 0
          etaf-retirement-test-update-fail-p nil)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf--view-call 'etaf-retirement-test-updated
                            (list :source source) nil))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-generation runtime))
                 (token (etaf-runtime-generation-token runtime)))
            (setq etaf-retirement-test-update-fail-p t)
            (condition-case condition
                (setf (etaf-value source) "B")
              (etaf-retirement-test-condition (setq captured condition)))
            (should captured)
            (should (equal (butlast (cdr captured))
                           '("update failed" :payload update)))
            (should (etaf-condition-postcommit-info captured))
            (should (= (1+ generation) (etaf-runtime-generation runtime)))
            (should (= (1+ token) (etaf-runtime-generation-token runtime)))
            (should (= etaf-retirement-test-update-count 1))
            (should (equal "updated=B"
                           (with-current-buffer buffer-name (buffer-string))))
            (setq etaf-retirement-test-update-fail-p nil)
            (setf (etaf-value source) "C")
            (should (= etaf-retirement-test-update-count 2))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-retirement-unmount-error-drains-structure-before-resignal ()
  "Explicit unmount remains detached, abandons later hooks, and cleans scope."
  (let ((buffer-name " *etaf-retirement-unmount-test*") runtime authority captured)
    (setq etaf-retirement-test-unmount-first-count 0
          etaf-retirement-test-unmount-second-count 0
          etaf-retirement-test-scope-cleanup-count 0)
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-retirement-test-unmounted)))
          (setq runtime (etaf-runtime-for-buffer buffer-name)
                authority (etaf-runtime-host-authority runtime))
          (condition-case condition
              (etaf-unmount runtime)
            (etaf-retirement-test-condition (setq captured condition)))
          (should captured)
          (should (etaf-condition-postcommit-info captured))
          (should (= etaf-retirement-test-unmount-first-count 1))
          (should (zerop etaf-retirement-test-unmount-second-count))
          (should (= etaf-retirement-test-scope-cleanup-count 1))
          (should-not (etaf-runtime-mounted-p runtime))
          (should (eq (etaf-host-authority-state authority) 'terminal))
          (should-not (etaf-render-port-mounted-p (get-buffer buffer-name))))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(provide 'etaf-retirement-tests)

;;; etaf-retirement-tests.el ends here
