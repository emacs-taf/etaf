;;; etaf-data-tests.el --- ETAF Data tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'etaf-data)

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
  (let (controller seen)
    (let ((source (etaf-data-source
                   :load (lambda (_query _page _page-size)
                           (push (etaf-value (etaf-data-status controller))
                                 seen)
                           (list :items '(a b) :total 2)))))
      (setq controller (etaf-data-controller source))
      (unwind-protect
          (progn
            (etaf-data-load controller)
            (should (equal '(loading) seen))
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

;;; etaf-data-tests.el ends here
