;;; etaf-theme-tp.el --- Optional ETAF Theme adapter for TP palettes -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; TP owns low-level palette storage and frame-aware text-property helpers.
;; ETAF owns the semantic Theme contract.  This optional adapter is the only
;; place where an application needs to bridge the two; etaf-ui and etaf core
;; do not depend on TP palette names.

;;; Code:

(require 'etaf-context)
(require 'tp-palette)

;;;###autoload
(defmacro etaf-theme-define-palette (name &rest plist)
  "Define a TP palette NAME from PLIST for the ETAF Theme adapter.

The palette registry remains owned by TP; this wrapper keeps an application
from depending on the lower-level `tp-define-palette' spelling in its View or
Component modules."
  (declare (indent defun))
  `(tp-define-palette ,name ,@plist))

;;;###autoload
(defun etaf-theme-from-tp-palettes (bindings mode)
  "Return an ETAF Theme plist from TP palette BINDINGS in MODE.

BINDINGS is a keyword plist whose values are `(PALETTE . CHANNEL)' pairs,
where PALETTE is a TP palette symbol and CHANNEL is `:fg', `:bg', or
`:border'.  MODE is explicitly `light' or `dark'; the current Emacs frame is
never consulted, so an application Theme toggle remains independent of frame
appearance."
  (unless (and (proper-list-p bindings)
               (zerop (% (length bindings) 2)))
    (signal 'etaf-context-error
            (list "TP Theme bindings must be a keyword plist")))
  (let (theme)
    (while bindings
      (let ((token (pop bindings))
            (binding (pop bindings)))
        (unless (and (keywordp token)
                     (consp binding)
                     (symbolp (car binding))
                     (memq (cdr binding) '(:fg :bg :border)))
          (signal 'etaf-context-error
                  (list (format "Invalid TP Theme binding: %S"
                                (cons token binding)))))
        (push token theme)
        (push (tp-palette-color-for-mode
               (car binding) (cdr binding) mode)
              theme)))
    (nreverse theme)))

(provide 'etaf-theme-tp)
;;; etaf-theme-tp.el ends here
