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

(provide 'etaf-performance-tests)
;;; etaf-performance-tests.el ends here
