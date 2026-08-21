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
