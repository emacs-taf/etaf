;;; etaf-component.el --- ETAF Component definitions -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Components have one public definition boundary.  A stateless Component
;; declares `:view'; a stateful Component declares `:setup' which runs once
;; per retained instance and returns a render function.  Both forms produce
;; the same normalized View tree and share props, slots, styles, and Context.

;;; Code:

(require 'cl-lib)
(require 'etaf-view)

(define-error 'etaf-component-definition-error
  "Invalid ETAF Component definition"
  'etaf-view-error)

(cl-defstruct (etaf--slot-content (:constructor etaf--slot-content-create))
  "Internal caller ownership metadata for one slot entry."
  owner-component-id children)

(defvar etaf--raw-slot-read-p nil
  "Set while a Component render uses public raw slot accessors.")

(defun etaf--component-definition-error (format-string &rest arguments)
  "Signal a Component definition error from FORMAT-STRING and ARGUMENTS."
  (signal 'etaf-component-definition-error
          (list (apply #'format format-string arguments))))

(defun etaf--parse-component-props (arguments)
  "Return prop names from Component argument declaration ARGUMENTS."
  (unless (proper-list-p arguments)
    (etaf--component-definition-error
     "Component prop declaration must be a proper list: %S" arguments))
  (let ((tail arguments)
        prop-names)
    (when tail
      (unless (eq (pop tail) '&key)
        (etaf--component-definition-error
         "Component props must use (&key NAME ...), got %S" arguments)))
    (dolist (entry tail)
      (unless (symbolp entry)
        (etaf--component-definition-error
         "Component props must be symbols without defaults: %S" entry))
      (when (or (keywordp entry) (memq entry '(nil t)))
        (etaf--component-definition-error
         "Component prop name must be an ordinary symbol: %S" entry))
      (when (memq entry prop-names)
        (etaf--component-definition-error
         "Duplicate Component prop: %S" entry))
      (push entry prop-names))
    (nreverse prop-names)))

(defun etaf--component-prop-key (name)
  "Return the public keyword used to pass prop NAME."
  (if (keywordp name)
      name
    (intern (concat ":" (symbol-name name)))))

(defun etaf-current-prop (name)
  "Return current Component prop NAME.

NAME is normally an ordinary symbol used by the `:setup' lexical shorthand.
The function is also useful to code that deliberately avoids that shorthand."
  (plist-get etaf--current-component-props
             (etaf--component-prop-key name)))

;;;###autoload
(defun etaf-component-set-styles (name styles)
  "Replace the static style form for Component NAME with STYLES.

STYLES must use the same `(styles (SELECTOR PROPERTY VALUE ...) ...)'
contract accepted by `etaf-define-component'.  This small runtime authoring
hook is useful to tools which reload a stylesheet without redefining the
Component itself, such as a source/preview playground.  The next mount or
render observes the replacement; existing mounted runtimes are not flushed
implicitly."
  (let ((spec (and (boundp 'etaf--view-registry)
                   (gethash name etaf--view-registry))))
    (unless (and (symbolp name) (etaf--component-spec-p spec))
      (etaf--component-definition-error
       "Unknown ETAF Component: %S" name))
    (etaf--validate-styles-form styles name)
    (setf (etaf--component-spec-styles spec) styles)
    styles))

(defun etaf-component-styles (name)
  "Return the current static style form for Component NAME."
  (let ((spec (and (boundp 'etaf--view-registry)
                   (gethash name etaf--view-registry))))
    (unless (and (symbolp name) (etaf--component-spec-p spec))
      (etaf--component-definition-error
       "Unknown ETAF Component: %S" name))
    (etaf--component-spec-styles spec)))

;;;###autoload
(defun etaf-component-redefine-run (function)
  "Run FUNCTION while allowing intentional Component redefinition.

Normal duplicate Component definitions remain errors.  Authoring tools may
use this narrow public boundary after disposing the old Runtime, so hot reload
does not depend on ETAF's private registry flag."
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (let ((etaf--allow-component-redefinition t))
    (funcall function)))

(defun etaf-current-slots ()
  "Return the current Component's normalized slot alist."
  (setq etaf--raw-slot-read-p t)
  (mapcar (lambda (entry)
            (cons (car entry)
                  (if (etaf--slot-content-p (cdr entry))
                      (etaf--slot-content-children (cdr entry))
                    (cdr entry))))
          etaf--current-component-slots))

(defun etaf-current-slot (name &optional fallback)
  "Return the child list for slot NAME, or FALLBACK when it is absent."
  (setq etaf--raw-slot-read-p t)
  (let ((entry (assq name etaf--current-component-slots)))
    (if entry
        (if (etaf--slot-content-p (cdr entry))
            (etaf--slot-content-children (cdr entry))
          (cdr entry))
      fallback)))

(defun etaf--component-prop-symbol-macros (props)
  "Return symbol macros that read current Component PROPS."
  (mapcar (lambda (prop)
            `(,prop (etaf-current-prop ',prop)))
          props))

(defun etaf--validate-styles-form (form name)
  "Validate static Component styles FORM for Component NAME."
  (when form
    (unless (and (consp form) (eq (car form) 'styles))
      (etaf--component-definition-error
       "Component %S :styles must be a (styles RULE ...) form" name))
    (dolist (rule (cdr form))
      (unless (and (consp rule) (stringp (car rule)))
        (etaf--component-definition-error
         "Component %S style rules need string selectors: %S" name rule))
      (let ((attributes (cdr rule)))
        (unless (zerop (% (length attributes) 2))
          (etaf--component-definition-error
           "Component %S style rule has an incomplete property pair: %S"
           name rule))
        (while attributes
          (let ((key (pop attributes)))
            (pop attributes)
            (unless (keywordp key)
              (etaf--component-definition-error
               "Component %S style properties must be keywords: %S"
               name key)))))))
  form)

;;;###autoload
(defmacro etaf-define-component (name arguments &rest clauses)
  "Define Component NAME from prop ARGUMENTS and CLAUSES.

The definition boundary is intentionally small:

  (etaf-define-component NAME (&key PROPS)
    :view VIEW
    :styles (styles (SELECTOR ATTR ...)))

or:

  (etaf-define-component NAME (&key PROPS)
    :setup SETUP
    :styles (styles (SELECTOR ATTR ...)))

`:view' is rendered for every update.  `:setup' runs once per retained
Component instance and must return a zero-argument render function.  View
forms do not use quote; ordinary Elisp belongs in `expr :value'."
  (declare (indent 2) (debug defun))
  (unless (symbolp name)
    (etaf--component-definition-error
     "Component name must be a symbol: %S" name))
  (let ((docstring (when (stringp (car clauses)) (pop clauses)))
        view-form
        setup-form
        styles-form
        saw-view
        saw-setup
        saw-styles)
    (while clauses
      (let ((keyword (pop clauses)))
        (unless (keywordp keyword)
          (etaf--component-definition-error
           "Expected a Component definition keyword, got %S" keyword))
        (unless clauses
          (etaf--component-definition-error
           "Component %S keyword %S has no value" name keyword))
        (pcase keyword
          (:view
           (when saw-view
             (etaf--component-definition-error
              "Component %S has duplicate :view" name))
           (setq view-form (pop clauses) saw-view t))
          (:setup
           (when saw-setup
             (etaf--component-definition-error
              "Component %S has duplicate :setup" name))
           (setq setup-form (pop clauses) saw-setup t))
          (:styles
           (when saw-styles
             (etaf--component-definition-error
              "Component %S has duplicate :styles" name))
           (setq styles-form (pop clauses) saw-styles t))
          (_
           (etaf--component-definition-error
            "Unknown Component definition keyword %S" keyword)))))
    (when (and saw-view saw-setup)
      (etaf--component-definition-error
       "Component %S must choose :view or :setup, not both" name))
    (unless (or saw-view saw-setup)
      (etaf--component-definition-error
       "Component %S requires exactly one of :view or :setup" name))
    (let* ((props (etaf--parse-component-props arguments))
           (styles-form (etaf--validate-styles-form styles-form name))
           (definition-symbol
            (intern (format "%s--etaf-component-definition" name)))
           (render-lambda
            (when saw-view
              `(lambda (etaf--component-props etaf--component-slots)
                 (let ((etaf--current-component-props etaf--component-props)
                       (etaf--current-component-slots etaf--component-slots)
                       (etaf--current-component-instance
                        etaf--current-component-instance))
                   (cl-symbol-macrolet
                       ,(etaf--component-prop-symbol-macros props)
                     ,(etaf--compile-view-form view-form :projection))))))
           (setup-lambda
            (when saw-setup
              `(lambda (etaf--component-props etaf--component-slots)
                 (let ((etaf--current-component-props etaf--component-props)
                       (etaf--current-component-slots etaf--component-slots))
                   (cl-symbol-macrolet
                       ,(etaf--component-prop-symbol-macros props)
                     ,setup-form))))))
      `(progn
         (defconst ,definition-symbol
           (etaf--component-spec-create
            :name ',name
            :props ',props
            :render ,render-lambda
            :setup ,setup-lambda
            :styles ',styles-form)
           ,(or docstring
                (format "Definition of ETAF Component `%s'." name)))
         (etaf--register-component ',name ,definition-symbol)
         ',name))))

(provide 'etaf-component)

;;; etaf-component.el ends here
