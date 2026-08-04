;;; etaf.el --- Text application framework facade -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: ETAF contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (ebox "1.0.1"))
;; Keywords: ui, tools, convenience
;; URL: https://github.com/ginqi7/etaf

;;; Commentary:

;; ETAF is a Component and View layer above the independent Ebox renderer.
;; This package is intentionally starting with the grammar and stateless View
;; path before adding retained state, events, styles, and data capabilities.

;;; Code:

(require 'etaf-view)
(require 'etaf-component)
(require 'etaf-renderer)

(provide 'etaf)

;;; etaf.el ends here
