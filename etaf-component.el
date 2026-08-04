;;; etaf-component.el --- Stateless ETAF Component definitions -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This first implementation slice owns only the beginner `:view' Component
;; form.  Stateful `:setup', Context, Behaviors, and lifecycle will be added
;; behind the same Component boundary in later milestones; they are rejected
;; here instead of silently receiving different semantics.

;;; Code:

(require 'cl-lib)
(require 'etaf-view)

(define-error 'etaf-component-definition-error
  "Invalid ETAF Component definition"
  'etaf-view-error)

(defun etaf--component-definition-error (format-string &rest arguments)
  "Signal a Component definition error formatted from FORMAT-STRING."
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
      (when (keywordp entry)
        (etaf--component-definition-error
         "Component prop names must not be keywords: %S" entry))
      (when (memq entry '(nil t))
        (etaf--component-definition-error
         "Component prop name cannot be a constant: %S" entry))
      (when (memq entry prop-names)
        (etaf--component-definition-error
         "Duplicate Component prop: %S" entry))
      (push entry prop-names))
    (nreverse prop-names)))

(defun etaf--component-view-variable-bindings (props)
  "Return lexical bindings for Component PROP names."
  (mapcar (lambda (prop)
            `(,prop
              (plist-get etaf--component-props
                         ,(etaf--component-prop-key prop))))
          props))

;;;###autoload
(defmacro etaf-define-component (name arguments &rest clauses)
  "Define stateless Component NAME with ARGUMENTS and CLAUSES.

The implemented P0 form is:

  (etaf-define-component NAME (&key PROPS)
    :view VIEW)

VIEW is already structural View syntax and does not need quote.  Attribute
values inside VIEW are ordinary Elisp expressions.  `:setup', `:styles',
slots, and lifecycle are intentionally rejected until their owning runtime
contracts are implemented."
  (declare (indent 2) (debug defun))
  (unless (symbolp name)
    (etaf--component-definition-error
     "Component name must be a symbol: %S" name))
  (let ((docstring (when (stringp (car clauses)) (pop clauses)))
        view-form
        saw-view)
    (while clauses
      (let ((keyword (pop clauses)))
        (unless (keywordp keyword)
          (etaf--component-definition-error
           "Expected a Component definition keyword, got %S" keyword))
        (pcase keyword
          (:view
           (when saw-view
             (etaf--component-definition-error
              "Component %S has duplicate :view" name))
           (unless clauses
             (etaf--component-definition-error
              "Component %S :view has no View" name))
           (setq view-form (pop clauses)
                 saw-view t))
          (:setup
           (etaf--component-definition-error
            "Component %S :setup is reserved for the stateful milestone"
            name))
          (:styles
           (etaf--component-definition-error
            "Component %S :styles is reserved for the style milestone"
            name))
          (_
           (etaf--component-definition-error
            "Unknown Component definition keyword %S" keyword)))))
    (unless saw-view
      (etaf--component-definition-error
       "Component %S requires exactly one :view clause" name))
    (let* ((props (etaf--parse-component-props arguments))
           (definition-symbol
            (intern (format "%s--etaf-component-definition" name)))
           (render-lambda
            `(lambda (etaf--component-props _etaf--children)
               (let ,(etaf--component-view-variable-bindings props)
                 ,(etaf--compile-view-form view-form)))))
      `(progn
         (defconst ,definition-symbol
           (etaf--component-spec-create
            :name ',name
            :props ',props
            :render ,render-lambda)
           ,(or docstring
                (format "Definition of ETAF Component `%s'." name)))
         (etaf--register-component ',name ,definition-symbol)
         ',name))))

(provide 'etaf-component)

;;; etaf-component.el ends here
