;;; etaf-data-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'etaf)

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

(etaf-define-component etaf-data-test-retained-pages (&key source page ready)
  :bindings ((data (etaf-data-controller source :auto-load t :page-size 2)))
  :setup (funcall ready data)
  :view
  (column
   (text "Retained header")
   (expr (if (eq (etaf-value page) 'data)
             (etaf-view
              (column
               (text (expr (symbol-name (etaf-value (etaf-data-status data)))))
               (text (expr (mapconcat
                            (lambda (row) (plist-get row :name))
                            (etaf-value (etaf-data-items data)) ", ")))))
           (etaf-view (text "Preferences"))))))

(ert-deftest etaf-data-auto-load-survives-view-switches-without-reloading ()
  "Retained pages share one loaded Controller until query or pagination changes."
  (let* ((buffer (generate-new-buffer " *data-pages*"))
         (page (etaf-ref 'data))
         (capabilities (etaf-data-source-capabilities
                        (etaf-data-memory-source etaf-data-test-records :id-key :id)))
         (load-page (plist-get capabilities :load))
         (loads 0) data)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-data-test-retained-pages
             :page page :ready (lambda (controller) (setq data controller))
             :source (apply #'etaf-data-source
                            (plist-put capabilities :load
                                       (lambda (&rest args)
                                         (cl-incf loads)
                                         (apply load-page args)))))))
          (should (eq (etaf-value (etaf-data-status data)) 'success))
          (should (= loads 1))
          (dotimes (_ 3)
            (setf (etaf-value page) 'preferences)
            (should (with-current-buffer buffer
                      (string-match-p "Preferences" (buffer-string))))
            (setf (etaf-value page) 'data)
            (should (with-current-buffer buffer
                      (string-match-p "Ada, Grace" (buffer-string))))
            (should (= loads 1)))
          (etaf-data-next-page data)
          (should (= loads 2))
          (should (with-current-buffer buffer
                    (string-match-p "Alan, Barbara" (buffer-string))))
          (let ((data-page (etaf-data-page data)))
            (etaf-unmount (etaf-runtime-for-buffer buffer))
            (setf (etaf-value data-page) 1))
          (should-error (etaf-data-load data) :type 'etaf-data-stopped-error)
          (should (= loads 2)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (when data (etaf-data-stop data))
      (kill-buffer buffer))))

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

(provide 'etaf-data-tests)
;;; etaf-data-tests.el ends here
