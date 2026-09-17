;;; etaf-performance-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'etaf)

(ert-deftest etaf-performance-mode-rejects-non-runtime-buffer ()
  "The buffer-local convenience requires a mounted Runtime."
  (with-temp-buffer
    (should-error (etaf-performance-mode 1))
    (should-not etaf-performance-mode)))

(ert-deftest etaf-performance-environment-reports-native-jit-state ()
  "Expose background JIT state beside absolute latency records."
  (let ((native-comp-jit-compilation t))
    (should (eq t (plist-get (etaf-performance-environment-data)
                             :native-comp-jit-compilation))))
  (let ((native-comp-jit-compilation nil))
    (should-not (plist-get (etaf-performance-environment-data)
                           :native-comp-jit-compilation))))

(ert-deftest etaf-performance-portable-report-is-a-detached-snapshot ()
  "Portable consumers identify operations without mutating recorded labels."
  (let ((buffer (generate-new-buffer " *etaf-portable-report*")) runtime)
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-view (text "Report fixture")))
          (setq runtime (etaf-runtime-for-buffer buffer))
          (etaf-performance-start runtime)
          (etaf-performance-call-operation runtime 'test (copy-sequence "Portable fixture") #'ignore)
          (let* ((records (etaf-performance-records))
                 (report (etaf-performance-report-data records))
                 (operation (cl-find "Portable fixture" (plist-get report :operations)
                                     :key (lambda (value) (plist-get value :label)) :test #'equal)))
            (should (integerp (plist-get report :format-version)))
            (should (integerp (plist-get operation :runtime-id)))
            (should (equal (buffer-name buffer) (plist-get operation :buffer-name)))
            (aset (plist-get operation :label) 0 ?X)
            (should (cl-find "Portable fixture" records :key #'etaf-performance-operation-label :test #'equal))
            (should-not (plist-get (etaf-performance-report-data nil) :operations))))
      (when runtime (etaf-performance-stop runtime) (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'etaf-performance-tests)
;;; etaf-performance-tests.el ends here
