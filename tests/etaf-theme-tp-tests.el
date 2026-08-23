;;; etaf-theme-tp-tests.el --- Optional TP Theme adapter tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'etaf-theme-tp)

(ert-deftest etaf-theme-tp-adapter-resolves-explicit-mode ()
  "Bridge TP palettes into semantic ETAF Theme tokens."
  (let ((tp-palette-alist tp-palette-alist))
    (etaf-theme-define-palette etaf-test-adapter-status
      :fg ("#111111" . "#EEEEEE")
      :bg ("#FFFFFF" . "#222222"))
    (should
     (equal '(:ink "#111111" :paper "#FFFFFF")
            (etaf-theme-from-tp-palettes
             '(:ink (etaf-test-adapter-status . :fg)
               :paper (etaf-test-adapter-status . :bg))
             'light)))
    (should
     (equal '(:ink "#EEEEEE" :paper "#222222")
            (etaf-theme-from-tp-palettes
             '(:ink (etaf-test-adapter-status . :fg)
               :paper (etaf-test-adapter-status . :bg))
             'dark)))))

;;; etaf-theme-tp-tests.el ends here
