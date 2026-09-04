;;; etaf-data-tests.el --- ETAF Data tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'etaf-data)
(require 'etaf-observer)

(defconst etaf-data-test-records
  '((:id 1 :name "Ada" :group "compiler")
    (:id 2 :name "Grace" :group "systems")
    (:id 3 :name "Alan" :group "compiler")
    (:id 4 :name "Barbara" :group "compiler"))
  "Records shared by ETAF Data tests.")

(defun etaf-data-test--ids (controller)
  "Return loaded item ids from CONTROLLER."
  (mapcar (lambda (record) (plist-get record :id))
          (etaf-value (etaf-data-items controller))))

(ert-deftest etaf-data-controller-loads-query-and-status ()
  "Load memory source records through the public controller API."
  (let* ((source (etaf-data-memory-source etaf-data-test-records
                                          :id-key :id))
         (controller (etaf-data-controller source
                                           :query '(:group "compiler")
                                           :page-size 2)))
    (unwind-protect
        (progn
          (etaf-data-load controller)
          (should (equal '(1 3) (etaf-data-test--ids controller)))
          (should (= 3 (etaf-value (etaf-data-total controller))))
          (should (eq 'success (etaf-value (etaf-data-status controller)))))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-controller-accepts-prepared-initial-result ()
  "Seed one data-ready Controller without a second source call."
  (let* ((calls 0)
         (source
          (etaf-data-source
           :load (lambda (_query page page-size)
                   (cl-incf calls)
                   (list :items '((:id 9 :name "Prepared"))
                         :total 41 :page page :page-size page-size))))
         (prepared (etaf-data-source-load-page source nil 2 10))
         (controller (etaf-data-controller
                      source :page 2 :page-size 10
                      :initial-result prepared :item-key (lambda (row)
                                                           (plist-get row :id)))))
    (unwind-protect
        (progn
          (should (= 1 calls))
          (should (equal '(9) (etaf-data-test--ids controller)))
          (should (= 41 (etaf-value (etaf-data-total controller))))
          (should (= 2 (etaf-value (etaf-data-page controller))))
          (should (= 10 (etaf-value (etaf-data-page-size controller))))
          (should (eq 'success (etaf-value (etaf-data-status controller))))
          (should-error
           (etaf-data-controller source :initial-result prepared :auto-load t)))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-loading-state-is-visible-to-source-boundary ()
  "Publish loading before invoking the source load capability."
  (let (controller seen candidate-kinds)
    (let ((source (etaf-data-source
                   :load (lambda (_query _page _page-size)
                           (push (etaf-value (etaf-data-status controller))
                                 seen)
                           (push (etaf-data--projection-candidate-kind
                                  (etaf-data--controller-projection-candidate
                                   controller))
                                 candidate-kinds)
                           (list :items '(a b) :total 2)))))
      (setq controller (etaf-data-controller source))
      (unwind-protect
          (progn
            (etaf-data-load controller)
            (should (equal '(loading) seen))
            (should (equal '(loading) candidate-kinds))
            (should (eq 'success (etaf-value
                                  (etaf-data-status controller)))))
        (etaf-data-stop controller)))))

(ert-deftest etaf-data-controller-reloads-for-pagination ()
  "Reload when controller pagination refs change."
  (let* ((source (etaf-data-memory-source etaf-data-test-records
                                          :id-key :id))
         (controller (etaf-data-controller source
                                           :query '(:group "compiler")
                                           :page-size 2
                                           :auto-load t)))
    (unwind-protect
        (progn
          (should (equal '(1 3) (etaf-data-test--ids controller)))
          (should (= 2 (etaf-data-next-page controller)))
          (should (equal '(4) (etaf-data-test--ids controller)))
          (should (= 1 (etaf-data-previous-page controller)))
          (should (equal '(1 3) (etaf-data-test--ids controller))))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-imperative-pagination-reloads-without-auto-load ()
  "Public pager commands reload Controllers that opt out of AUTO-LOAD."
  (let* ((source (etaf-data-memory-source etaf-data-test-records
                                          :id-key :id))
         (controller (etaf-data-controller source :page-size 2)))
    (unwind-protect
        (progn
          (etaf-data-load controller)
          (should (equal '(1 2) (etaf-data-test--ids controller)))
          (should (= 2 (etaf-data-next-page controller)))
          (should (equal '(3 4) (etaf-data-test--ids controller)))
          (should (= 1 (etaf-data-previous-page controller)))
          (should (equal '(1 2) (etaf-data-test--ids controller))))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-source-page-normalization-does-not-reload-twice ()
  "Avoid a second reload when source results normalize page refs."
  (let* ((load-count 0)
         (source (etaf-data-source
                  :load (lambda (_query _page page-size)
                          (cl-incf load-count)
                          (list :items '(only)
                                :total 1
                                :page 1
                                :page-size page-size))))
         (controller (etaf-data-controller source :auto-load t)))
    (unwind-protect
        (progn
          (should (= 1 load-count))
          (etaf-data-set-page controller 99)
          (should (= 2 load-count))
          (should (= 1 (etaf-value (etaf-data-page controller)))))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-memory-source-mutates-and-reloads ()
  "Apply source mutations through the controller boundary."
  (let* ((source (etaf-data-memory-source etaf-data-test-records
                                          :id-key :id))
         (controller (etaf-data-controller source
                                           :page-size 10
                                           :auto-load t)))
    (unwind-protect
        (progn
          (etaf-data-mutate
           controller 'insert '(:id 5 :name "Edsger" :group "systems"))
          (should (equal '(1 2 3 4 5) (etaf-data-test--ids controller)))
          (etaf-data-mutate
           controller 'replace '(:id 2 :name "Grace Hopper" :group "navy"))
          (should (equal "Grace Hopper"
                         (plist-get (cadr (etaf-value
                                           (etaf-data-items controller)))
                                    :name)))
          (etaf-data-mutate controller 'delete 1)
          (should (equal '(2 3 4 5) (etaf-data-test--ids controller))))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-memory-source-supports-keyword-alist-records ()
  "Query and mutate memory records represented as keyword alists."
  (let* ((records '((( :id . 1) (:group . "compiler"))
                    ((:id . 2) (:group . "systems"))))
         (source (etaf-data-memory-source records :id-key :id))
         (controller (etaf-data-controller source
                                           :query '((:group . "compiler"))
                                           :auto-load t)))
    (unwind-protect
        (progn
          (should (= 1 (length (etaf-value (etaf-data-items controller)))))
          (etaf-data-mutate
           controller 'replace '((:id . 1) (:group . "language")))
          (etaf-data-set-query controller '((:group . "language")))
          (should (equal "language"
                         (alist-get :group
                                    (car (etaf-value
                                          (etaf-data-items controller)))))))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-errors-are-observable-and-resignaled ()
  "Store source load errors in controller state and re-signal them."
  (let* ((source (etaf-data-source
                  :load (lambda (_query _page _page-size)
                          (error "boom"))))
         (controller (etaf-data-controller source)))
    (unwind-protect
        (progn
          (should-error (etaf-data-load controller) :type 'error)
          (should (eq 'error (etaf-value (etaf-data-status controller))))
          (should (eq 'error
                      (car (etaf-value (etaf-data-error controller))))))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-m4a-malformed-load-publishes-atomic-error ()
  "A malformed source result leaves old data intact and exits loading."
  (let* ((source (etaf-data-source
                  :load (lambda (&rest _args) '(:total 99))))
         (controller
          (etaf-data-controller
           source
           :initial-result '(:items (old) :total 1 :page 2 :page-size 7)))
         captured)
    (unwind-protect
        (progn
          (condition-case condition
              (etaf-data-load controller)
            (error (setq captured condition)))
          (should captured)
          (should (eq 'error (car captured)))
          (should (eq 'error (etaf-value (etaf-data-status controller))))
          (should (equal captured
                         (etaf-value (etaf-data-error controller))))
          (should (equal '(old) (etaf-value (etaf-data-items controller))))
          (should (= 1 (etaf-value (etaf-data-total controller))))
          (should (= 2 (etaf-value (etaf-data-page controller))))
          (should (= 7 (etaf-value (etaf-data-page-size controller)))))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-m4a-committed-load-error-has-read-only-retry ()
  "A committed mutation reports a trailer and retry never mutates twice."
  (let* ((load-count 0)
         (mutate-count 0)
         (source
          (etaf-data-source
           :load (lambda (&rest _args)
                   (cl-incf load-count)
                   (if (= load-count 1)
                       (error "reconciliation read failed")
                     '(:items (new) :total 1)))
           :mutate-v2 (lambda (&rest _args)
                        (cl-incf mutate-count)
                        '(:certainty committed :result committed-result))))
         (controller
          (etaf-data-controller
           source :initial-result '(:items (old) :total 1)))
         captured)
    (unwind-protect
        (progn
          (condition-case condition
              (etaf-data-mutate controller 'update 'payload)
            (error (setq captured condition)))
          (should captured)
          (should (eq 'error (car captured)))
          (should (equal '(error "reconciliation read failed")
                         (butlast captured)))
          (should (equal 'committed-result
                         (plist-get (etaf-data-condition-projection-info
                                     captured)
                                    :result)))
          (should (= 1 mutate-count))
          (should (= 1 load-count))
          (should (eq 'committed
                      (plist-get (etaf-data-mutation-outcome controller)
                                 :certainty)))
          (should (eq 'projection-pending
                      (etaf-data-reconciliation-state controller)))
          (should (eq 'error (etaf-value (etaf-data-status controller))))
          (should (equal '(old) (etaf-value (etaf-data-items controller))))
          (should (equal '(:items (new) :total 1)
                         (etaf-data-retry-reconciliation controller)))
          (should (= 1 mutate-count))
          (should (= 2 load-count))
          (should (eq 'success (etaf-value (etaf-data-status controller))))
          (should (equal '(new) (etaf-value (etaf-data-items controller))))
          (should (eq 'projected
                      (etaf-data-reconciliation-state controller))))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-m4a-external-unknown-is-not-replayed ()
  "A v1 mutation signal is conservatively unknown and never auto-retried."
  (let* ((mutate-count 0)
         (load-count 0)
         (source
          (etaf-data-source
           :load (lambda (&rest _args)
                   (cl-incf load-count)
                   '(:items (old) :total 1))
           :mutate (lambda (&rest _args)
                     (cl-incf mutate-count)
                     (error "write uncertainty"))))
         (controller
          (etaf-data-controller source :initial-result '(:items (old) :total 1)))
         captured)
    (unwind-protect
        (progn
          (condition-case condition
              (etaf-data-mutate controller 'update 'payload)
            (error (setq captured condition)))
          (should captured)
          (should (equal '(error "write uncertainty") captured))
          (should (= 1 mutate-count))
          (should (= 0 load-count))
          (should (eq 'external-unknown
                      (plist-get (etaf-data-mutation-outcome controller)
                                 :certainty)))
          (should (eq 'external-unknown
                      (etaf-data-reconciliation-state controller)))
          (should-not (etaf-data-retry-reconciliation controller))
          (should-not (etaf-data-retry-render controller)))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-m4a-uncertain-mutation-projection-fault-keeps-cause ()
  "A mutation projection fault preserves the primary cause and adds a trailer."
  (let* ((source
          (etaf-data-source
           :load (lambda (&rest _args) '(:items (old) :total 1))
           :mutate (lambda (&rest _args) (error "write uncertainty"))))
         (controller
          (etaf-data-controller source :initial-result '(:items (old) :total 1)))
         (stop-status-watch
          (etaf-watch
           (etaf-data-status controller)
           (lambda (new _old)
             (when (eq new 'error)
               (error "status projection failed")))))
         captured)
    (unwind-protect
        (progn
          (condition-case condition
              (etaf-data-mutate controller 'update 'payload)
            (error (setq captured condition)))
          (should (equal '(error "write uncertainty") (butlast captured)))
          (let ((projection-info (etaf-data-condition-projection-info captured))
                (token (etaf-data-reconciliation-token controller)))
            (should projection-info)
            (should (eq 'external-unknown
                        (plist-get projection-info
                                   :external-commit-certainty)))
            (should (equal token (plist-get projection-info
                                             :reconciliation-token)))
            (should (equal '(error "status projection failed")
                           (plist-get token :projection-condition)))))
      (funcall stop-status-watch)
      (etaf-data-stop controller))))

(ert-deftest etaf-data-m4a-mutation-loading-is-a-candidate ()
  "The mutation boundary exposes loading through the shared candidate path."
  (let (controller seen kinds)
    (let ((source
           (etaf-data-source
            :load (lambda (&rest _args) '(:items (old) :total 1))
            :mutate (lambda (&rest _args)
                      (push (etaf-value (etaf-data-status controller)) seen)
                      (push (etaf-data--projection-candidate-kind
                             (etaf-data--controller-projection-candidate
                              controller))
                            kinds)
                      'mutation-result))))
      (setq controller
            (etaf-data-controller source
                                  :initial-result '(:items (old) :total 1))))
    (unwind-protect
        (progn
          (should (equal 'mutation-result
                         (etaf-data-mutate controller 'update 'payload)))
          (should (equal '(loading) seen))
          (should (equal '(loading) kinds)))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-m4a-loading-projection-fault-exits-terminally ()
  "A loading dispatch fault publishes error and prevents the mutation call."
  (let* ((mutate-count 0)
         (source
          (etaf-data-source
           :load (lambda (&rest _args) '(:items (old) :total 1))
           :mutate (lambda (&rest _args)
                     (cl-incf mutate-count)
                     'mutation-result)))
         (controller
          (etaf-data-controller source :initial-result '(:items (old) :total 1)))
         (stop-status-watch
          (etaf-watch
           (etaf-data-status controller)
           (lambda (new _old)
             (when (eq new 'loading)
               (error "loading projection failed")))))
         captured)
    (unwind-protect
        (progn
          (condition-case condition
              (etaf-data-mutate controller 'update 'payload)
            (error (setq captured condition)))
          (should (equal '(error "loading projection failed") captured))
          (should (= 0 mutate-count))
          (should (eq 'error (etaf-value (etaf-data-status controller))))
          (should (equal captured (etaf-value (etaf-data-error controller)))))
      (funcall stop-status-watch)
      (etaf-data-stop controller))))

(ert-deftest etaf-data-m4a-committed-candidate-is-one-shot ()
  "A committed projection candidate cannot be submitted or rolled back twice."
  (let* ((source (etaf-data-source
                  :load (lambda (&rest _args)
                          '(:items (new) :total 2))))
         (controller
          (etaf-data-controller source :initial-result '(:items (old) :total 1)))
         candidate)
    (unwind-protect
        (progn
          (etaf-data-load controller)
          (setq candidate (etaf-data--controller-projection-candidate controller))
          (let ((items-version (etaf-ref-version (etaf-data-items controller)))
                (total-version (etaf-ref-version (etaf-data-total controller))))
            (should (eq 'committed
                        (etaf-data--projection-candidate-state candidate)))
            (should-error
             (etaf-data--commit-projection controller candidate)
             :type 'etaf-data-projection-conflict)
            (should (eq 'committed
                        (etaf-data--projection-candidate-state candidate)))
            (should (equal '(new) (etaf-value (etaf-data-items controller))))
            (should (= 2 (etaf-value (etaf-data-total controller))))
            (should (= items-version
                       (etaf-ref-version (etaf-data-items controller))))
            (should (= total-version
                       (etaf-ref-version (etaf-data-total controller))))))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-m4a-v2-malformed-outcome-is-unknown ()
  "Malformed v2 metadata publishes an error without starting a read."
  (let* ((load-count 0)
         (source
          (etaf-data-source
           :load (lambda (&rest _args)
                   (cl-incf load-count)
                   '(:items (old) :total 1))
           :mutate-v2 (lambda (&rest _args) '(:certainty committed :error bad))))
         (controller
          (etaf-data-controller source :initial-result '(:items (old) :total 1)))
         captured)
    (unwind-protect
        (progn
          (condition-case condition
              (etaf-data-mutate controller 'update 'payload)
            (error (setq captured condition)))
          (should captured)
          (should (eq 'external-unknown
                      (plist-get (etaf-data-mutation-outcome controller)
                                 :certainty)))
          (should (eq 'external-unknown
                      (etaf-data-reconciliation-state controller)))
          (should (= 0 load-count))
          (should (eq 'error (etaf-value (etaf-data-status controller))))
          (should-not (etaf-data-retry-reconciliation controller)))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-m4a-v2-outcome-validates-result-and-rollback-error ()
  "Reject contradictory results and incomplete rolled-back outcomes."
  (dolist (outcome
           '((:certainty committed :result left :mutation-result right)
             (:certainty committed)
             (:certainty rolled-back)))
    (let* ((load-count 0)
           (source
            (etaf-data-source
             :load (lambda (&rest _args)
                     (cl-incf load-count)
                     '(:items (old) :total 1))
             :mutate-v2 (lambda (&rest _args) outcome)))
           (controller
            (etaf-data-controller source :initial-result '(:items (old)
                                                            :total 1)))
           captured)
      (unwind-protect
          (progn
            (condition-case condition
                (etaf-data-mutate controller 'update 'payload)
              (error (setq captured condition)))
            (should captured)
            (should (eq 'external-unknown
                        (plist-get (etaf-data-mutation-outcome controller)
                                   :certainty)))
            (should (eq 'external-unknown
                        (etaf-data-reconciliation-state controller)))
            (should (zerop load-count)))
        (etaf-data-stop controller)))))

(ert-deftest etaf-data-m4a-field-apply-fault-restores-written-fields ()
  "A field fault before dispatch restores every field written by the candidate."
  (let* ((source (etaf-data-source
                  :load (lambda (&rest _args)
                          '(:items (new) :total 2))))
         (controller
          (etaf-data-controller source :initial-result '(:items (old) :total 1)))
         (old-apply etaf-data--projection-field-apply-function)
         (old-items-version (etaf-ref-version (etaf-data-items controller)))
         (old-total-version (etaf-ref-version (etaf-data-total controller)))
         captured)
    (unwind-protect
        (progn
          (setq etaf-data--projection-field-apply-function
                (lambda (entry)
                  (let ((ref (plist-get entry :ref)))
                    (setf (etaf-ref-value ref) (plist-get entry :new-value)
                          (etaf-ref-version ref)
                          (1+ (plist-get entry :old-version))))
                  (error "field installation failed")))
          (condition-case condition
              (etaf-data-load controller)
            (error (setq captured condition)))
          (should captured)
          (should (equal '(old) (etaf-value (etaf-data-items controller))))
          (should (= 1 (etaf-value (etaf-data-total controller))))
          (should (= old-items-version
                     (etaf-ref-version (etaf-data-items controller))))
          (should (= old-total-version
                     (etaf-ref-version (etaf-data-total controller)))))
      (setq etaf-data--projection-field-apply-function old-apply)
      (etaf-data-stop controller))))

(ert-deftest etaf-data-m4a-field-apply-runs-once-per-entry ()
  "Install each changed field exactly once after version validation."
  (let* ((source (etaf-data-source
                  :load (lambda (&rest _args)
                          (list :items '(new) :total 2))))
         (controller
          (etaf-data-controller source
                                :initial-result '(:items (old) :total 1)))
         (old-apply etaf-data--projection-field-apply-function)
         (apply-count 0))
    (unwind-protect
        (progn
          (setq etaf-data--projection-field-apply-function
                (lambda (entry)
                  (cl-incf apply-count)
                  (etaf-data--projection-default-apply-field entry)))
          (etaf-data-load controller)
          (let* ((candidate (etaf-data-projection-candidate controller))
                 (entries (etaf-data--projection-candidate-entries candidate)))
            (should (= apply-count (length entries)))
            (should (equal '(new) (etaf-value (etaf-data-items controller))))
            (should (= 2 (etaf-value (etaf-data-total controller))))))
      (setq etaf-data--projection-field-apply-function old-apply)
      (etaf-data-stop controller))))

(ert-deftest etaf-data-m4a-item-key-fault-exits-loading ()
  "A materialization fault publishes error instead of leaving loading set."
  (let* ((source (etaf-data-source
                  :load (lambda (&rest _args)
                          (list :items '((:id new)) :total 2))))
         (controller
          (etaf-data-controller
           source
           :initial-result '(:items ((:id old)) :total 1)
           :item-key
           (lambda (item)
             (if (eq (plist-get item :id) 'new)
                 (error "item key failed")
               (plist-get item :id)))))
         captured)
    (unwind-protect
        (progn
          (condition-case condition
              (etaf-data-load controller)
            (error (setq captured condition)))
          (should (equal '(error "item key failed") captured))
          (should (eq 'error (etaf-value (etaf-data-status controller))))
          (should (equal captured
                         (etaf-value (etaf-data-error controller))))
          (should (equal '((:id old))
                         (etaf-value (etaf-data-items controller))))
          (should (= 1 (etaf-value (etaf-data-total controller))))
          (should (eq 'load-error
                      (etaf-data--projection-candidate-kind
                       (etaf-data--controller-projection-candidate
                        controller)))))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-m4a-source-error-projection-fault-exits-loading ()
  "A source error plus error projection fault still leaves terminal error state."
  (let* ((source (etaf-data-source
                  :load (lambda (&rest _args)
                          (error "source boom"))))
         (controller
          (etaf-data-controller source
                                :initial-result '(:items (old) :total 1)))
         (old-apply etaf-data--projection-field-apply-function)
         captured)
    (unwind-protect
        (progn
          (setq etaf-data--projection-field-apply-function
                (lambda (entry)
                  (let ((ref (plist-get entry :ref)))
                    (setf (etaf-ref-value ref) (plist-get entry :new-value)
                          (etaf-ref-version ref)
                          (1+ (plist-get entry :old-version))))
                  (error "error projection installation failed")))
          (condition-case condition
              (etaf-data-load controller)
            (error (setq captured condition)))
          (should (equal '(error "source boom") captured))
          (should (eq 'error (etaf-value (etaf-data-status controller))))
          (should (equal captured
                         (etaf-value (etaf-data-error controller))))
          (should (equal '(old) (etaf-value (etaf-data-items controller))))
          (should (= 1 (etaf-value (etaf-data-total controller))))
          (should (eq 'aborted
                      (etaf-data--projection-candidate-state
                       (etaf-data--controller-projection-candidate
                        controller)))))
      (setq etaf-data--projection-field-apply-function old-apply)
      (etaf-data-stop controller))))

(ert-deftest etaf-data-m4a-plain-load-projection-fault-keeps-raw-condition ()
  "A plain successful load keeps a projection fault in the v1 condition shape."
  (let* ((source (etaf-data-source
                  :load (lambda (&rest _args)
                          '(:items (new) :total 2))))
         (controller
          (etaf-data-controller source :initial-result '(:items (old) :total 1)))
         (stop-status-watch
          (etaf-watch
           (etaf-data-status controller)
           (lambda (new _old)
             (when (eq new 'success)
               (error "success projection failed")))))
         captured)
    (unwind-protect
        (progn
          (condition-case condition
              (etaf-data-load controller)
            (error (setq captured condition)))
          (should (equal '(error "success projection failed") captured))
          (should-not (etaf-data-condition-projection-info captured))
          (should-not (etaf-data-reconciliation-token controller))
          (should (eq 'success (etaf-value (etaf-data-status controller))))
          (should (equal '(new) (etaf-value (etaf-data-items controller))))
          (should (= 2 (etaf-value (etaf-data-total controller)))))
      (funcall stop-status-watch)
      (etaf-data-stop controller))))

(ert-deftest etaf-data-selection-is-reactive-state ()
  "Select, deselect, and clear identities through the controller API."
  (let* ((source (etaf-data-memory-source etaf-data-test-records
                                          :id-key :id))
         (controller (etaf-data-controller source)))
    (unwind-protect
        (progn
          (etaf-data-select controller 1)
          (etaf-data-select controller 3)
          (should (etaf-data-selected-p controller 1))
          (should (etaf-data-selected-p controller 3))
          (etaf-data-select controller 1 nil)
          (should-not (etaf-data-selected-p controller 1))
          (etaf-data-clear-selection controller)
          (should-not (etaf-value (etaf-data-selection controller))))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-selected-refs-are-stable-and-differential ()
  "Selected refs keep identity and notify only changed identities."
  (let* ((source (etaf-data-memory-source etaf-data-test-records :id-key :id))
         (controller (etaf-data-controller source :selection '(1 3)))
         (one (etaf-data-selected-ref controller 1))
         (two (etaf-data-selected-ref controller 2))
         (three (etaf-data-selected-ref controller 3))
         (one-updates 0)
         (two-updates 0)
         (three-updates 0))
    (unwind-protect
        (progn
          (should (eq one (etaf-data-selected-ref controller 1)))
          (should (etaf-value one))
          (should-not (etaf-value two))
          (should (etaf-value three))
          (etaf-watch one (lambda (&rest _) (cl-incf one-updates)))
          (etaf-watch two (lambda (&rest _) (cl-incf two-updates)))
          (etaf-watch three (lambda (&rest _) (cl-incf three-updates)))
          (setf (etaf-value (etaf-data-selection controller)) '(2 3))
          (should-not (etaf-value one))
          (should (etaf-value two))
          (should (etaf-value three))
          (should (= 1 one-updates))
          (should (= 1 two-updates))
          (should (zerop three-updates)))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-selected-refs-preserve-multi-select-apis ()
  "Additive selection updates the matching keyed refs independently."
  (let* ((source (etaf-data-memory-source etaf-data-test-records :id-key :id))
         (controller (etaf-data-controller source))
         (one (etaf-data-selected-ref controller 1))
         (three (etaf-data-selected-ref controller 3)))
    (unwind-protect
        (progn
          (etaf-data-select controller 1)
          (etaf-data-select controller 3)
          (should (equal '(3 1) (etaf-value (etaf-data-selection controller))))
          (should (etaf-value one))
          (should (etaf-value three))
          (etaf-data-select controller 1 nil)
          (should-not (etaf-value one))
          (should (etaf-value three))
          (etaf-data-clear-selection controller)
          (should-not (etaf-value three)))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-stop-disposes-selection-index-watcher ()
  "Stopping a controller unsubscribes its selection-index watcher."
  (let* ((source (etaf-data-memory-source etaf-data-test-records :id-key :id))
         (controller (etaf-data-controller source))
         (selection (etaf-data-selection controller)))
    (should (= 1 (hash-table-count (etaf-ref-subscribers selection))))
    (etaf-data-stop controller)
    (should (zerop (hash-table-count (etaf-ref-subscribers selection))))))

(ert-deftest etaf-data-select-one-replaces-existing-selection ()
  "Single-selection consumers replace, rather than adjoin, identities."
  (let* ((source (etaf-data-memory-source
                  '((:id 1) (:id 2) (:id 3)) :id-key :id))
         (controller (etaf-data-controller source :auto-load nil)))
    (unwind-protect
        (progn
          (etaf-data-select-one controller 1)
          (etaf-data-select-one controller 2)
          (should (equal '(2) (etaf-value (etaf-data-selection controller))))
          (etaf-data-select-one controller 2)
          (should (equal '(2) (etaf-value (etaf-data-selection controller))))
          (etaf-data-select-one controller nil)
          (should-not (etaf-value (etaf-data-selection controller))))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-selected-item-resolves-the-current-identity ()
  "Resolve a selected identity to the loaded item through the public helper."
  (let* ((source (etaf-data-memory-source etaf-data-test-records :id-key :id))
         (controller (etaf-data-controller
                      source :item-key (lambda (record) (plist-get record :id))
                      :auto-load t)))
    (unwind-protect
        (progn
          (etaf-data-select-one controller 3)
          (should (equal "Alan"
                         (plist-get (etaf-data-selected-item controller)
                                    :name)))
          (etaf-data-select-one controller 99)
          (should-not (etaf-data-selected-item controller)))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-controller-is-owned-by-current-scope ()
  "Dispose a controller created in a Scope when its owner Scope stops."
  (let ((disposed 0)
        controller
        (scope (etaf-effect-scope :detached t :name 'etaf-data-owner-test)))
    (etaf-scope-run
     scope
     (lambda ()
       (setq controller
             (etaf-data-controller
              (etaf-data-source
               :load (lambda (_query _page _page-size)
                       (list :items nil :total 0))
               :dispose (lambda () (cl-incf disposed)))))))
    (should (etaf-data-controller-p controller))
    (etaf-scope-stop scope)
    (should (= 1 disposed))))

(ert-deftest etaf-data-stop-disposes-source-and-controller ()
  "Stop controller lifecycle resources and reject later operations."
  (let* ((dispose-count 0)
         (source (etaf-data-source
                  :load (lambda (_query _page _page-size)
                          (list :items nil :total 0))
                  :dispose (lambda ()
                             (cl-incf dispose-count))))
         (controller (etaf-data-controller source :auto-load t)))
    (should (eq 'success (etaf-value (etaf-data-status controller))))
    (should-not (etaf-data-stop controller))
    (should (= 1 dispose-count))
    (should-error (etaf-data-load controller)
                  :type 'etaf-data-stopped-error)
    (should-error (etaf-data-set-page controller 2)
                  :type 'etaf-data-stopped-error)))

(ert-deftest etaf-data-observes-source-capabilities-once-in-call-order ()
  "Report source load and mutation without timing controller publication."
  (let* ((source (etaf-data-memory-source '((:id 1)) :id-key :id))
         (controller (etaf-data-controller source))
         reports
         diagnostics
         (context
          (etaf--observer-context-create
           :sink (lambda (report) (push report reports))
           :operation-id 41
           :runtime-id 7
           :buffer-name nil
           :diagnostic (lambda (diagnostic) (push diagnostic diagnostics)))))
    (unwind-protect
        (progn
          (etaf--observer-call-with-context
           context
           (lambda ()
             (etaf-data-load controller)
             (etaf-data-mutate controller 'insert '(:id 2))))
          (setq reports (nreverse reports))
          (should-not diagnostics)
          (should (equal '(load mutate load)
                         (mapcar (lambda (report)
                                   (plist-get report :stage))
                                 reports)))
          (should (equal '(memory memory memory)
                         (mapcar (lambda (report)
                                   (plist-get report :provider))
                                 reports)))
          (should (equal '(1 nil 1)
                         (mapcar (lambda (report)
                                   (plist-get report :page))
                                 reports)))
          (should (eq 'insert (plist-get (cadr reports) :operation)))
          (should (equal '((:id 1) (:id 2))
                         (etaf-value (etaf-data-items controller))))
          (should (eq 'success (etaf-value
                                (etaf-data-status controller)))))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-observed-source-error-preserves-controller-state ()
  "Report a source error and preserve the ordinary Data error contract."
  (let* ((source (etaf-data-source
                  :load (lambda (&rest _args) (error "unavailable"))))
         (controller (etaf-data-controller source))
         reports
         (context
          (etaf--observer-context-create
           :sink (lambda (report) (push report reports))
           :operation-id 42
           :runtime-id 7
           :buffer-name nil
           :diagnostic #'ignore)))
    (unwind-protect
        (progn
          (should-error
           (etaf--observer-call-with-context
            context (lambda () (etaf-data-load controller)))
           :type 'error)
          (should (= 1 (length reports)))
          (should (eq 'data (plist-get (car reports) :provider)))
          (should (eq 'load (plist-get (car reports) :stage)))
          (should (eq 'error (plist-get (car reports) :status)))
          (should (eq 'error (etaf-value (etaf-data-status controller))))
          (should (string-match-p
                   "unavailable"
                   (cadr (etaf-value (etaf-data-error controller))))))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-source-rejects-invalid-observation-provider ()
  "Require an explicit source provider to be a non-nil symbol."
  (should-error
   (etaf-data-source :provider nil
                     :load (lambda (&rest _args) (list :items nil)))
   :type 'wrong-type-argument)
  (should-error
   (etaf-data-source :provider 7
                     :load (lambda (&rest _args) (list :items nil)))
   :type 'wrong-type-argument))

(ert-deftest etaf-data-unobserved-source-call-bypasses-stage-runtime ()
  "Keep the standalone source path free of observation work."
  (let ((source (etaf-data-memory-source '((:id 1)) :id-key :id)))
    (cl-letf (((symbol-function 'etaf--observer-call-stage)
               (lambda (&rest _args)
                 (ert-fail "unobserved Data call entered stage runtime"))))
      (should (equal '((:id 1))
                     (plist-get (etaf-data-source-load-page source) :items))))))

;;; etaf-data-tests.el ends here
