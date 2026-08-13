;;; etaf.el --- Text application framework facade -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: ETAF contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (ebox "2.0.0"))
;; Keywords: ui, tools, convenience
;; URL: https://github.com/ginqi7/etaf

;;; Commentary:

;; ETAF is a small Component and View layer above the independent Ebox
;; renderer.  Runtime, reactive Scope, and the structural grammar are loaded
;; through this one public package entry.

;;; Code:

(defconst etaf--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the ETAF implementation files.")

(defun etaf--prefer-local-files ()
  "Keep this package's implementation directory first on `load-path'."
  (setq load-path (cons etaf--directory
                        (delete etaf--directory load-path))))

(etaf--prefer-local-files)

(require 'etaf-view)
(require 'etaf-component)
(require 'etaf-reactive)
(require 'etaf-context)
(require 'etaf-resource)
(require 'etaf-data)
(require 'etaf-renderer)
(etaf--prefer-local-files)
(require 'etaf-runtime)
(require 'etaf-behavior)
(require 'etaf-actions)
(require 'etaf-events)

(provide 'etaf)

;;; etaf.el ends here
