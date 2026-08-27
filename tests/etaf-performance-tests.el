;;; etaf-performance-tests.el --- ETAF performance recorder tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'etaf)
(defconst etaf-performance-test--facade-loaded-recorder-p
  (featurep 'etaf-performance)
  "Whether loading the ETAF facade eagerly loaded the optional recorder.")
(require 'etaf-performance)

(ert-deftest etaf-performance-is-not-an-etaf-facade-dependency ()
  "The optional recorder must be loaded explicitly."
  (should-not etaf-performance-test--facade-loaded-recorder-p))

(defmacro etaf-performance-test--isolated (&rest body)
  "Run BODY with isolated recorder state."
  (declare (indent 0) (debug t))
  `(let ((etaf-performance--record-ring nil)
         (etaf-performance--pending (make-hash-table :test #'equal))
         (etaf-performance--attachments (make-hash-table :test #'eq)))
     ,@body))

(cl-defmacro etaf-performance-test--with-runtime
    ((runtime buffer-name) &rest body)
  "Mount RUNTIME in BUFFER-NAME, evaluate BODY, then clean up."
  (declare (indent 1) (debug ((symbolp symbolp) body)))
  `(let ((,buffer-name (generate-new-buffer-name " *etaf-performance-test*"))
         ,runtime)
     (unwind-protect
         (progn
           (etaf-mount ,buffer-name (etaf-view (box "Performance")))
           (setq ,runtime (etaf-runtime-for-buffer ,buffer-name))
           ,@body)
       (when ,runtime
         (etaf-performance-stop ,runtime)
         (when (etaf-runtime-mounted-p ,runtime)
           (etaf-unmount ,runtime)))
       (when-let* ((buffer (get-buffer ,buffer-name)))
         (kill-buffer buffer)))))

(ert-deftest etaf-performance-start-stop-own-exact-runtime-sink ()
  "Attach idempotently and remove only this recorder's exact sink."
  (etaf-performance-test--isolated
    (etaf-performance-test--with-runtime (runtime buffer-name)
      (should (eq runtime (etaf-performance-start runtime)))
      (let* ((attachment
              (gethash runtime etaf-performance--attachments))
             (sink (etaf-performance--attachment-sink attachment)))
        (should (functionp sink))
        (should (etaf-runtime-compare-and-set-observer runtime sink sink))
        (should (eq runtime (etaf-performance-start runtime)))
        (should (eq runtime (etaf-performance-stop runtime)))
        (should (etaf-runtime-compare-and-set-observer runtime nil nil))))))

(ert-deftest etaf-performance-start-rejects-foreign-observer ()
  "Never replace an observer owned by another consumer."
  (etaf-performance-test--isolated
    (etaf-performance-test--with-runtime (runtime buffer-name)
      (let ((foreign #'ignore))
        (etaf-runtime-set-observer runtime foreign)
        (should-error (etaf-performance-start runtime))
        (should (etaf-runtime-compare-and-set-observer
                 runtime foreign foreign))
        (etaf-runtime-set-observer runtime nil)))))

(ert-deftest etaf-performance-stop-preserves-replacement-observer ()
  "A later foreign replacement is not detached by recorder stop."
  (etaf-performance-test--isolated
    (etaf-performance-test--with-runtime (runtime buffer-name)
      (etaf-performance-start runtime)
      (let ((foreign #'ignore))
        (etaf-runtime-set-observer runtime foreign)
        (etaf-performance-stop runtime)
        (should (etaf-runtime-compare-and-set-observer
                 runtime foreign foreign))
        (etaf-runtime-set-observer runtime nil)))))

(ert-deftest etaf-performance-mode-is-current-buffer-convenience ()
  "The local mode attaches only the Runtime in its current buffer."
  (etaf-performance-test--isolated
    (etaf-performance-test--with-runtime (runtime buffer-name)
      (with-current-buffer buffer-name
        (etaf-performance-mode 1)
        (should etaf-performance-mode)
        (should (eq runtime etaf-performance--mode-runtime))
        (let* ((attachment
                (gethash runtime etaf-performance--attachments))
               (sink (etaf-performance--attachment-sink attachment)))
          (should (functionp sink))
          (should (etaf-runtime-compare-and-set-observer
                   runtime sink sink)))
        (etaf-performance-mode -1)
        (should-not etaf-performance-mode)
        (should (etaf-runtime-compare-and-set-observer runtime nil nil))))))

(ert-deftest etaf-performance-mode-rejects-non-runtime-buffer ()
  "The buffer-local convenience requires a mounted Runtime."
  (with-temp-buffer
    (should-error (etaf-performance-mode 1))
    (should-not etaf-performance-mode)))

(ert-deftest etaf-performance-unmount-records-and-releases-attachment ()
  "Record unmount before the Runtime detaches this recorder."
  (etaf-performance-test--isolated
    (let ((buffer-name (generate-new-buffer-name " *etaf-performance-unmount*"))
          runtime)
      (unwind-protect
          (progn
            (etaf-mount buffer-name (etaf-view (box "Unmount")))
            (setq runtime (etaf-runtime-for-buffer buffer-name))
            (etaf-performance-start runtime)
            (etaf-unmount runtime)
            (should-not (gethash runtime etaf-performance--attachments))
            (let ((operation (car (etaf-performance-records))))
              (should (eq 'unmount
                          (etaf-performance-operation-kind operation)))
              (should (eq 'success
                          (etaf-performance-operation-status operation))))
            (should (eq runtime (etaf-performance-stop runtime))))
        (when-let* ((buffer (get-buffer buffer-name)))
          (kill-buffer buffer))))))

(ert-deftest etaf-performance-groups-flat-reports-in-sequence-order ()
  "One ETAF final report retains one ordered, categorized operation."
  (etaf-performance-test--isolated
    (etaf-performance-test--with-runtime (runtime buffer-name)
      (etaf-performance-start runtime)
      (should
       (equal
        'result
        (etaf-performance-call-operation
         runtime 'command "flat fixture"
         (lambda ()
           (etaf-observer-emit
            '(:provider data :stage load :duration-ms 2.0 :rows 4))
           (etaf-observer-emit
            '(:provider ebox :stage commit :duration-ms 3.0 :patches 2))
           'result))))
      (let* ((records (etaf-performance-records))
             (operation (car records))
             (stages (etaf-performance-operation-stages operation)))
        (should (= 1 (length records)))
        (should (eq 'command (etaf-performance-operation-kind operation)))
        (should (equal "flat fixture"
                       (etaf-performance-operation-label operation)))
        (should (equal '(1 2 3)
                       (mapcar #'etaf-performance-stage-sequence stages)))
        (should (equal '(data ebox etaf)
                       (mapcar #'etaf-performance-stage-provider stages)))
        (should (equal '(data ebox runtime)
                       (mapcar #'etaf-performance-stage-category stages)))
        (should (eq 'runtime-operation
                    (etaf-performance-stage-name (car (last stages)))))
        (should (= 4 (plist-get
                      (etaf-performance-stage-metadata (car stages))
                      :rows)))))))

(ert-deftest etaf-performance-operation-wrapper-preserves-errors ()
  "The public wrapper delegates result, timing, and failure to Runtime."
  (etaf-performance-test--isolated
    (etaf-performance-test--with-runtime (runtime buffer-name)
      (etaf-performance-start runtime)
      (let ((condition
             (condition-case data
                 (etaf-performance-with-operation
                     (runtime 'command "failure")
                   (signal 'args-out-of-range '(source 1 2)))
               (args-out-of-range data))))
        (should (equal condition '(args-out-of-range source 1 2))))
      (let ((operation (car (etaf-performance-records))))
        (should (eq 'error (etaf-performance-operation-status operation)))
        (should (eq 'error
                    (etaf-performance-stage-status
                     (car (last
                           (etaf-performance-operation-stages operation))))))))))

(ert-deftest etaf-performance-record-ring-is-bounded ()
  "Retain only the configured number of newest operations."
  (etaf-performance-test--isolated
    (let ((etaf-performance-max-records 2))
      (etaf-performance-test--with-runtime (runtime buffer-name)
        (etaf-performance-start runtime)
        (dotimes (index 4)
          (etaf-performance-call-operation
           runtime 'bounded (format "operation %d" index) #'ignore))
        (let ((records (etaf-performance-records)))
          (should (= 2 (length records)))
          (should (> (etaf-performance-operation-id (car records))
                     (etaf-performance-operation-id (cadr records)))))))))

(ert-deftest etaf-performance-summary-uses-flat-duration ()
  "Summaries expose percentiles and overlapping provider durations honestly."
  (etaf-performance-test--isolated
    (etaf-performance-test--with-runtime (runtime buffer-name)
      (etaf-performance-start runtime)
      (dotimes (_ 3)
        (etaf-performance-call-operation
         runtime 'summary "fixture"
         (lambda ()
           (etaf-observer-emit
            '(:provider tp :stage publish :duration-ms 2.5)))))
      (let* ((operation (car (etaf-performance-records)))
             (summary (car (etaf-performance-summary)))
             (stage-summary
              (etaf-performance-operation-stage-summary operation))
             (tp-summary
              (cl-find 'tp stage-summary :key
                       (lambda (entry) (plist-get entry :category)))))
        (should (= 3 (plist-get summary :count)))
        (should (<= (plist-get summary :min-ms)
                    (plist-get summary :p50-ms)
                    (plist-get summary :p95-ms)
                    (plist-get summary :max-ms)))
        (should (= 1 (plist-get tp-summary :count)))
        (should (= 2.5 (plist-get tp-summary :duration-ms)))
        (should-not (plist-member tp-summary :exclusive-ms))))))

(ert-deftest etaf-performance-report-panel-copy-and-export-remain-usable ()
  "Portable reports, the panel, copy, and export consume flat records."
  (etaf-performance-test--isolated
    (etaf-performance-test--with-runtime (runtime buffer-name)
      (etaf-performance-start runtime)
      (etaf-performance-call-operation
       runtime 'report "portable fixture"
       (lambda ()
         (etaf-observer-emit
          '(:provider tp :stage publish :duration-ms 1.25))))
      (let* ((data (etaf-performance-report-data))
             (operation (car (plist-get data :operations)))
             (stage (car (plist-get operation :stages)))
             (kill-ring nil)
             (kill-ring-yank-pointer nil)
             (copied (etaf-performance-copy-report))
             (file (make-temp-file "etaf-performance-" nil ".eld")))
        (unwind-protect
            (progn
              (delete-file file)
              (should (= 2 (plist-get data :format-version)))
              (should (equal "portable fixture"
                             (plist-get operation :label)))
              (should (eq 'tp (plist-get stage :provider)))
              (should (equal copied (current-kill 0 t)))
              (should (equal file (etaf-performance-export file)))
              (with-temp-buffer
                (insert-file-contents file)
                (should (string-match-p "portable fixture"
                                        (buffer-string)))))
          (when (file-exists-p file)
            (delete-file file))))
      (let ((entries (etaf-performance--tabulated-entries)))
        (should (= 3 (length entries))))
      (with-temp-buffer
        (etaf-performance-panel-mode)
        (tabulated-list-print t)
        (should (string-match-p "portable fixture" (buffer-string)))
        (should (string-match-p "publish" (buffer-string)))))))

(ert-deftest etaf-performance-environment-normalizes-darwin-power-state ()
  "Reports distinguish AC, battery low-power, and unknown power states."
  (should
   (equal '(:source battery :low-power-mode on)
          (etaf-performance--parse-darwin-power-state
           "Now drawing from 'Battery Power'\n"
           "Battery Power:\n lowpowermode 1\nAC Power:\n lowpowermode 0\n")))
  (should
   (equal '(:source ac :low-power-mode off)
          (etaf-performance--parse-darwin-power-state
           "Now drawing from 'AC Power'\n"
           "Battery Power:\n lowpowermode 1\nAC Power:\n lowpowermode 0\n")))
  (should
   (equal '(:source unknown :low-power-mode unknown)
          (etaf-performance--parse-darwin-power-state "" ""))))

(ert-deftest etaf-performance-environment-reports-native-jit-state ()
  "Expose background JIT state beside absolute latency records."
  (let ((native-comp-jit-compilation t))
    (should (eq t (plist-get (etaf-performance-environment-data)
                             :native-comp-jit-compilation))))
  (let ((native-comp-jit-compilation nil))
    (should-not (plist-get (etaf-performance-environment-data)
                           :native-comp-jit-compilation))))

(ert-deftest etaf-performance-source-has-no-advice-or-private-provider-registry ()
  "Recorder source depends only on the public Runtime observation boundary."
  (let ((source
         (with-temp-buffer
           (insert-file-contents
            (expand-file-name
             "etaf-performance.el"
             (file-name-directory (locate-library "etaf-performance"))))
           (buffer-string))))
    (dolist (pattern '("advice-add" "advice-remove" "after-load-functions"
                       "operation-functions" "stage-functions"
                       "etaf-runtime-mount-epoch"
                       "etaf-runtime-observer runtime"
                       "etaf-runtime-mounted-p"
                       "ebox--" "tp--" "etaf-sqlite--"))
      (should-not (string-match-p (regexp-quote pattern) source)))))

(provide 'etaf-performance-tests)

;;; etaf-performance-tests.el ends here
