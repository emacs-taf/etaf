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
  owner-id
  (values (make-hash-table :test #'eq)))

(defvar etaf--current-context nil
  "Context table of the Component currently being evaluated.")

(defvar etaf--theme-defaults-cache
  (make-hash-table :test #'eq :weakness 'key)
  "Context-keyed cache of validated Theme default plists.

Theme values are immutable for the duration of a render pass.  Keeping the
validated copy by Context frame avoids rebuilding the same semantic palette
for every Host that reads one token, while weak keys let disposed Component
Contexts disappear with their Runtime.")

(defvar etaf--context-inject-recorder nil
  "Candidate-local function recording Context provider reads.")

(defconst etaf--context-missing (make-symbol "etaf-context-missing")
  "Unique sentinel used to distinguish an absent Context value.")

(defun etaf-context-copy (context)
  "Return an immutable candidate copy of CONTEXT's local frame."
  (when context
    (let ((values (make-hash-table :test #'eq)))
      (maphash (lambda (key value) (puthash key value values))
               (etaf-context-values context))
      (etaf--context-create :parent (etaf-context-parent context)
                            :owner-id (etaf-context-owner-id context)
                            :values values))))

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
        provider
        value)
    (while (and context (not found))
      (let ((candidate (gethash key (etaf-context-values context)
                               etaf--context-missing)))
        (unless (eq candidate etaf--context-missing)
          (setq value candidate
                found t
                provider context)))
      (setq context (etaf-context-parent context)))
    (if found
        (progn
          (when etaf--context-inject-recorder
            (funcall etaf--context-inject-recorder provider key))
          value)
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
  (let* ((theme (etaf-inject 'theme default))
         (value (if (or (etaf-ref-p theme) (etaf-computed-p theme))
                    (etaf-value theme)
                  theme))
         (context etaf--current-context)
         (cached (gethash context etaf--theme-defaults-cache)))
    (if (and cached
             (eq (plist-get cached :source) theme)
             (eq (plist-get cached :value) value)
             (equal (plist-get cached :default) default))
        (plist-get cached :validated)
      (let ((validated
             (if (and (proper-list-p value)
                      (zerop (% (length value) 2)))
                 (etaf--validate-theme-defaults value)
               default)))
        (puthash context
                 (list :source theme :value value :default default
                       :validated validated)
                 etaf--theme-defaults-cache)
        validated))))

;;;###autoload
(defun etaf-theme-value (key &optional default)
  "Return Theme property KEY from inherited defaults, or DEFAULT."
  (let ((theme (etaf-theme-defaults)))
    (if (plist-member theme key)
        (plist-get theme key)
      default)))

;;;###autoload
(defun etaf-theme-token (key &optional default)
  "Return a deferred Theme token for a static Component style.

KEY is resolved when ETAF lowers the Component's `:styles' declaration, so a
static rule can use the current inherited Theme without turning every retained
Host into an inline dynamic property.  DEFAULT is used when KEY is absent.
The returned list is intentionally data, which also makes it safe to place
directly in a quoted `(styles ...)' form."
  (unless (keywordp key)
    (signal 'etaf-context-error
            (list (format "Theme token keys must be keywords: %S" key))))
  (list 'etaf-theme-token key default))

;;;###autoload
(defun etaf-theme-token-p (value)
  "Return non-nil when VALUE is a deferred ETAF Theme token."
  (and (proper-list-p value)
       (memq (length value) '(2 3))
       (eq (car value) 'etaf-theme-token)
       (keywordp (nth 1 value))))

;;;###autoload
(defun etaf-theme-token-resolve (value)
  "Resolve deferred Theme token VALUE, or return ordinary VALUE unchanged."
  (if (etaf-theme-token-p value)
      (etaf-theme-value (nth 1 value) (nth 2 value))
    value))

;;;###autoload
(defun etaf-theme-current-mode ()
  "Return the current frame color mode as `light' or `dark'.

This is only the default mode for palette resolution.  An application-owned
Theme toggle should pass its explicit mode to `etaf-theme-resolve-palette'
instead of changing the Emacs frame."
  (if (eq (frame-parameter nil 'background-mode) 'dark) 'dark 'light))

(defun etaf--theme-resolve-color (value mode)
  "Resolve one light/dark VALUE for MODE."
  (cond
   ((stringp value) value)
   ((and (consp value)
         (or (stringp (car value)) (null (car value)))
         (or (stringp (cdr value)) (null (cdr value))))
    (if (eq mode 'dark) (cdr value) (car value)))
   ((and (proper-list-p value)
         (or (plist-member value :light) (plist-member value :dark)))
    (if (eq mode 'dark) (plist-get value :dark) (plist-get value :light)))
   ((null value) nil)
   (t
    (signal 'etaf-context-error
            (list (format "Invalid ETAF palette color: %S" value))))))

;;;###autoload
(defun etaf-theme-resolve-palette (palette mode)
  "Resolve semantic PALETTE token specs for explicit MODE.

PALETTE is a keyword plist.  Each value may be a color string, a
`(LIGHT . DARK)' pair, or a `(:light LIGHT :dark DARK)' plist.  MODE is
`light' or `dark'.  The result is an ordinary Theme plist suitable for
`etaf-theme-provide'.  ETAF owns this semantic contract; a renderer-specific
palette package may adapt its own registry into this shape at the boundary."
  (unless (memq mode '(light dark))
    (signal 'etaf-context-error
            (list (format "Theme palette mode must be light or dark: %S"
                          mode))))
  (unless (and (proper-list-p palette)
               (zerop (% (length palette) 2)))
    (signal 'etaf-context-error
            (list (format "Theme palette must be a keyword plist: %S"
                          palette))))
  (let (result)
    (while palette
      (let ((key (pop palette))
            (value (pop palette)))
        (unless (keywordp key)
          (signal 'etaf-context-error
                  (list (format "Theme palette key must be a keyword: %S"
                                key))))
        (setq result
              (append result (list key (etaf--theme-resolve-color value mode))))))
    result))

(provide 'etaf-context)

;;; etaf-context.el ends here
