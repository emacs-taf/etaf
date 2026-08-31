;;; etaf-m0b-component-manifest-tests.el --- M0b manifest probes -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'etaf-m0b-component-manifest)

(ert-deftest etaf-m0b-component-manifest-is-derived-and-mounted ()
  "Derive business props and prove Host-attribute forwarding by mounting."
  (let* ((manifest (etaf-m0b-component-manifest-data))
         (components (alist-get 'components manifest)))
    (should (= 2 (length components)))
    (should (equal '("title")
                   (alist-get 'declared-business-props (car components))))
    (should (equal '("label")
                   (alist-get 'declared-business-props (cadr components))))
    (dolist (entry components)
      (should (alist-get 'forwarded-host-attrs entry))
      (should (string-match-p "single attr-capable root"
                              (alist-get 'root-shape-forwarding-guarantee
                                         entry)))
      (should (eq t (alist-get 'mounted-validation entry))))))

;;; etaf-m0b-component-manifest-tests.el ends here
