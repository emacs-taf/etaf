;;; etaf-theme.el --- ETAF semantic palette registry -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ETAF owns semantic light/dark palette data.  The registry is independent
;; of Emacs frame state and of any renderer or text-property implementation.

;;; Code:

(require 'etaf-context)


(defvar etaf-theme--palettes (make-hash-table :test #'eq)
  "Semantic light/dark palettes owned by ETAF.")

(defun etaf-theme--define-palette (name plist)
  "Register NAME with validated semantic PLIST."
  (unless (and (symbolp name) (proper-list-p plist)
               (zerop (% (length plist) 2)))
    (signal 'etaf-context-error (list "Invalid ETAF palette" name plist)))
  (puthash name (copy-tree plist) etaf-theme--palettes)
  name)

;;;###autoload
(defmacro etaf-theme-define-palette (name &rest plist)
  "Define semantic palette NAME from PLIST.

Each channel value is a cons cell of (LIGHT . DARK) colors."
  (declare (indent defun))
  `(etaf-theme--define-palette ,name ,@plist))

;;;###autoload
(defun etaf-theme-from-palettes (bindings mode)
  "Return an ETAF Theme plist from semantic palette BINDINGS in MODE.

BINDINGS is a keyword plist whose values are `(PALETTE . CHANNEL)' pairs,
where PALETTE is a semantic palette symbol and CHANNEL is `:fg', `:bg', or
`:border'.  MODE is explicitly `light' or `dark'; the current Emacs frame is
never consulted, so an application Theme toggle remains independent of frame
appearance."
  (unless (and (proper-list-p bindings)
               (zerop (% (length bindings) 2)))
    (signal 'etaf-context-error
            (list "ETAF Theme bindings must be a keyword plist")))
  (let (theme)
    (while bindings
      (let ((token (pop bindings))
            (binding (pop bindings)))
        (unless (and (keywordp token)
                     (consp binding)
                     (symbolp (car binding))
                     (memq (cdr binding) '(:fg :bg :border)))
          (signal 'etaf-context-error
                  (list (format "Invalid ETAF Theme binding: %S"
                                (cons token binding)))))
        (push token theme)
        (push (let* ((palette (gethash (car binding) etaf-theme--palettes))
                      (value (plist-get palette (cdr binding))))
                 (unless (consp value)
                   (signal 'etaf-context-error
                           (list (format "Palette channel is absent: %S" binding))))
                 (if (eq mode 'dark) (cdr value) (car value)))
              theme)))
    (nreverse theme)))

(provide 'etaf-theme)
;;; etaf-theme.el ends here
