;;; etaf-context.el --- Inherited Component Context -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Context is the one deliberately inherited dependency environment.  It is
;; attached to Component instances, not to View nodes or global variables.

;;; Code:

(require 'cl-lib)
(require 'etaf-reactive)

(define-error 'etaf-context-error "Invalid ETAF Context operation")

(cl-defstruct (etaf-context
               (:constructor etaf--context-create))
  "One inherited Context frame owned by a Component instance."
  parent
  (values (make-hash-table :test #'eq)))

(defvar etaf--current-context nil
  "Context table of the Component currently being evaluated.")

(defconst etaf--context-missing (make-symbol "etaf-context-missing")
  "Unique sentinel used to distinguish an absent Context value.")

(defun etaf--context-key (key)
  "Validate and normalize Context KEY."
  (unless (and (symbolp key) (not (keywordp key)) (not (memq key '(nil t))))
    (signal 'etaf-context-error
            (list (format "Context keys must be stable symbols: %S" key))))
  key)

;;;###autoload
(defun etaf-provide (key value)
  "Provide VALUE under stable Context KEY to the current subtree."
  (unless (etaf-context-p etaf--current-context)
    (error "ETAF provide requires Component setup or render context"))
  (puthash (etaf--context-key key) value
           (etaf-context-values etaf--current-context))
  value)

;;;###autoload
(cl-defun etaf-inject (key &optional default (required-p nil required-p-supplied-p))
  "Return the nearest provided value for KEY.

DEFAULT is returned when KEY is absent.  When REQUIRED-P is non-nil, absence
signals an error.  The optional third argument is explicit so a provided nil
can be distinguished from a missing dependency."
  (let ((key (etaf--context-key key))
        (context etaf--current-context)
        found
        value)
    (while (and context (not found))
      (let ((candidate (gethash key (etaf-context-values context)
                               etaf--context-missing)))
        (unless (eq candidate etaf--context-missing)
          (setq value candidate
                found t)))
      (setq context (etaf-context-parent context)))
    (if found
        value
      (if (and required-p-supplied-p required-p)
          (signal 'etaf-context-error
                  (list (format "Missing ETAF Context dependency: %S" key)))
        default))))

(defun etaf--validate-theme-defaults (theme)
  "Validate THEME as a property plist and return a defensive copy.

ETAF deliberately keeps Theme as a Context value rather than another runtime
object.  The convention is a property plist whose entries are defaults for
Hosts in the inherited subtree."
  (unless (and (proper-list-p theme)
               (zerop (% (length theme) 2)))
    (signal 'etaf-context-error
            (list (format "Theme defaults must be keyword/value pairs: %S"
                          theme))))
  (let ((copy nil)
        (tail theme))
    (while tail
      (let ((key (pop tail))
            (value (pop tail)))
        (unless (keywordp key)
          (signal 'etaf-context-error
                  (list (format "Theme default must use a keyword: %S" key))))
        (setq copy (append copy (list key value)))))
    copy))

;;;###autoload
(defun etaf-theme-provide (theme)
  "Provide THEME property defaults to the current Component subtree.

THEME is a property plist such as `(:color \"#F4F6FB\" :bgcolor \"#202634\")'.
Explicit Host properties and matching Component `:styles' declarations take
precedence over these defaults.  A reactive ref containing such a plist is
also accepted and remains tracked by the current render effect."
  (etaf-provide 'theme
                (if (or (etaf-ref-p theme) (etaf-computed-p theme))
                    theme
                  (etaf--validate-theme-defaults theme))))

;;;###autoload
(defun etaf-theme-defaults (&optional default)
  "Return inherited Theme property defaults, or DEFAULT when absent."
  (let ((theme (etaf-inject 'theme default)))
    (cond
     ((or (etaf-ref-p theme) (etaf-computed-p theme))
      (let ((value (etaf-value theme)))
        (if (and (proper-list-p value)
                 (zerop (% (length value) 2)))
            (etaf--validate-theme-defaults value)
          default)))
     ((and (proper-list-p theme)
           (zerop (% (length theme) 2)))
      (etaf--validate-theme-defaults theme))
     (t default))))

;;;###autoload
(defun etaf-theme-value (key &optional default)
  "Return Theme property KEY from inherited defaults, or DEFAULT."
  (let ((theme (etaf-theme-defaults)))
    (if (plist-member theme key)
        (plist-get theme key)
      default)))

(provide 'etaf-context)

;;; etaf-context.el ends here
