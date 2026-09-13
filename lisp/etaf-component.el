;;; etaf-component.el --- ETAF Component definitions -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Components have one public definition boundary with two authoring
;; frontends: compiled `:view' DSL and ordinary Elisp `:render'.  Optional
;; `:setup' runs once and returns opaque state read through `etaf-state'.

;;; Code:

(require 'cl-lib)
(require 'macroexp)
(require 'etaf-view)
(require 'etaf-compiler)

(define-error 'etaf-component-definition-error
  "Invalid ETAF Component definition"
  'etaf-view-error)

(cl-defstruct (etaf--slot-content (:constructor etaf--slot-content-create))
  "Internal caller ownership metadata for one slot entry."
  owner-component-id children)

(defvar etaf--raw-slot-read-p nil
  "Set while a Component render uses public raw slot accessors.")

(defvar etaf--component-phase nil
  "Dynamic Component phase, either `setup', `render', or nil.")

(defvar etaf--current-component-state nil
  "Opaque setup result supplied by the current Runtime Component context.")

(defvar etaf--current-component-setup-defined-p nil
  "Whether the current Component definition declares setup.")

(defvar etaf--current-component-setup-complete-p nil
  "Whether the current Component instance completed setup.")

(defconst etaf--component-reserved-props
  '(key if else-if else for)
  "Framework names forbidden in Component business prop declarations.")

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
      (unless (or (symbolp entry)
                  (and (proper-list-p entry) (= (length entry) 2)
                       (symbolp (car entry))))
        (etaf--component-definition-error
         "Component props must be NAME or (NAME DEFAULT): %S" entry))
      (let ((name (if (consp entry) (car entry) entry)))
        (when (or (keywordp name) (memq name '(nil t))
                  (string-prefix-p "&" (symbol-name name)))
          (etaf--component-definition-error
           "Component prop name must be an ordinary symbol: %S" name))
        (when (memq name prop-names)
          (etaf--component-definition-error
           "Duplicate Component prop: %S" name))
        (when (memq name etaf--component-reserved-props)
          (etaf--component-definition-error
           "Component prop %S is reserved by the View grammar" name))
        (push name prop-names)))
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
(defun etaf-state ()
  "Return the current Component instance's exact setup result.
The accessor is valid only while rendering a Component that declares setup.
A defined setup may return nil; setup presence is tracked independently."
  (unless (and (eq etaf--component-phase 'render)
               etaf--current-component-instance)
    (etaf--component-definition-error
     "ETAF state is available only during Component view/render"))
  (unless etaf--current-component-setup-defined-p
    (etaf--component-definition-error
     "Current Component does not declare :setup"))
  (unless etaf--current-component-setup-complete-p
    (etaf--component-definition-error
     "Current Component setup has not completed"))
  etaf--current-component-state)

;;;###autoload
(defun etaf-component-set-styles (name styles)
  "Replace the static style form for Component NAME with STYLES.

STYLES must use the same `((SELECTOR PROPERTY VALUE ...) ...)'
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
  (unless (eq etaf--component-phase 'render)
    (etaf--component-definition-error
     "Slots are available only during Component view/render"))
  (setq etaf--raw-slot-read-p t)
  (mapcar (lambda (entry)
            (cons (car entry)
                  (if (etaf--slot-content-p (cdr entry))
                      (etaf--slot-content-children (cdr entry))
                    (cdr entry))))
          etaf--current-component-slots))

(defun etaf-current-slot (name &optional fallback)
  "Return the child list for slot NAME, or FALLBACK when it is absent."
  (unless (eq etaf--component-phase 'render)
    (etaf--component-definition-error
     "Slots are available only during Component view/render"))
  (setq etaf--raw-slot-read-p t)
  (let ((entry (assq name etaf--current-component-slots)))
    (if entry
        (if (etaf--slot-content-p (cdr entry))
            (etaf--slot-content-children (cdr entry))
          (cdr entry))
      fallback)))

(defun etaf--component-prop-bindings (props)
  "Return lexical bindings for the current Component PROPS."
  (mapcar (lambda (prop)
            `(,prop (etaf-current-prop ',prop)))
          props))

(defun etaf--component-default-resolver (arguments)
  "Compile ARGUMENTS into an instance-default resolver, or nil."
  (when (cl-some #'consp (cdr arguments))
    (let ((input (make-symbol "input"))
          (cache (make-symbol "defaults"))
          bindings)
      (dolist (entry (cdr arguments))
        (let* ((name (if (consp entry) (car entry) entry))
               (key (etaf--component-prop-key name)))
          (push
           `(,name
             ,(if (consp entry)
                  `(if (plist-member ,input ,key)
                       (plist-get ,input ,key)
                     (unless (plist-member ,cache ,key)
                       (setq ,cache (plist-put ,cache ,key ,(cadr entry))))
                     (setq ,input
                           (plist-put ,input ,key (plist-get ,cache ,key)))
                     (plist-get ,input ,key))
                `(plist-get ,input ,key)))
           bindings)))
      `(lambda (,input ,cache)
         (setq ,input (copy-sequence ,input)
               ,cache (copy-sequence ,cache))
         (let* ,(nreverse bindings)
           (ignore ,@(mapcar (lambda (entry)
                              (if (consp entry) (car entry) entry))
                            (cdr arguments)))
           (cons ,input ,cache))))))

(defun etaf--component-resolve-defaults (spec props defaults)
  "Return (PROPS . DEFAULTS) for SPEC without mutating either input."
  (if-let* ((resolver (etaf--component-spec-defaults spec)))
      (funcall resolver props defaults)
    (cons props defaults)))

(defun etaf--validate-styles-form (form name)
  "Validate static rule list FORM against the Ebox schema for Component NAME."
  (condition-case err
      (ebox-style-compile-rules form)
    (error (etaf--component-definition-error
            "Component %S rejected :styles: %s" name (error-message-string err))))
  form)

(defun etaf--component-form-contains-head-p (form heads)
  "Return non-nil when executable FORM contains a call headed by HEADS."
  (cond
   ((atom form) nil)
   ((memq (car form) '(quote function)) nil)
   ((memq (car form) heads) t)
   (t (cl-some (lambda (part)
                 (etaf--component-form-contains-head-p part heads))
               form))))

;;;###autoload
(defmacro etaf-define-component (name arguments &rest clauses)
  "Define Component NAME from prop ARGUMENTS and CLAUSES.

Choose exactly one authoring frontend:

  (etaf-define-component NAME (&key PROPS)
    [:setup SETUP]
    :view VIEW
    :styles ((SELECTOR ATTR ...)))

or:

  (etaf-define-component NAME (&key PROPS)
    [:setup SETUP]
    :render ORDINARY-ELISP
    :styles ((SELECTOR ATTR ...)))

`:setup' runs once per retained identity and returns opaque state.  `:view'
is unquoted DSL; `:render' is ordinary Elisp returning the same typed View,
usually through `etaf-view'.  `etaf-node' also constructs Views
programmatically.  Both frontends use the same prop and slot rules.  Declared
props are lexical snapshots for each setup or render evaluation; callbacks
may refer to them directly.  Passed refs retain identity and live value reads.
Bind state handles during rendering, and keep reactive value reads inside
the View properties or expressions they update.

Props accept NAME or (NAME DEFAULT) after &key.  Defaults evaluate in order
on first missing input and can read earlier props.  Explicit nil is supplied.
Mounted instances retain successfully published defaults until replacement or
unmount; pure rendering evaluates defaults anew.  Default expressions must be
safe to retry after rejected publication; allocate mutable values explicitly."
  (declare (indent 2) (debug defun))
  (unless (symbolp name)
    (etaf--component-definition-error
     "Component name must be a symbol: %S" name))
  (let ((docstring (when (stringp (car clauses)) (pop clauses)))
        view-form
        render-form
        setup-form
        styles-form
        saw-view
        saw-render
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
          (:render
           (when saw-render
             (etaf--component-definition-error
              "Component %S has duplicate :render" name))
           (setq render-form (pop clauses) saw-render t))
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
    (when (and saw-view saw-render)
      (etaf--component-definition-error
       "Component %S must choose :view or :render, not both" name))
    (unless (or saw-view saw-render)
      (etaf--component-definition-error
       "Component %S requires exactly one of :view or :render" name))
    (when (and saw-setup
               (etaf--component-form-contains-head-p
                setup-form '(etaf-view etaf-node)))
      (etaf--component-definition-error
       "Component %S :setup cannot construct View structure" name))
    (when (and saw-setup
               (consp setup-form)
               (memq (car setup-form) '(lambda function)))
      (etaf--component-definition-error
       "Component %S :setup cannot return a render function" name))
    (let* ((props (etaf--parse-component-props arguments))
           (styles-form (etaf--validate-styles-form styles-form name))
           (definition-symbol
            (intern (format "%s--etaf-component-definition" name)))
           (render-lambda
            `(lambda (etaf--component-props etaf--component-slots)
               (let ((etaf--current-component-props etaf--component-props)
                     (etaf--current-component-slots etaf--component-slots)
                     (etaf--component-phase 'render))
                 ,(let ((etaf--compiling-component-props props))
                    ;; Expand every embedded View inside its Component prop
                    ;; grammar, including Views produced by lexical macros.
                    ;; Lexical props belong to this evaluation and its closures.
                    ;; Nested let/lambda bindings retain normal Elisp shadowing.
                    (macroexpand-all
                     `(let ,(etaf--component-prop-bindings props)
                        (ignore ,@props)
                        ,(if saw-view
                             (etaf-compiler-expand-view view-form :projection)
                           render-form))
                     macroexpand-all-environment)))))
           (setup-lambda
            (when saw-setup
              `(lambda (etaf--component-props _etaf--component-slots)
                 (let ((etaf--current-component-props etaf--component-props)
                       (etaf--current-component-slots nil)
                       (etaf--component-phase 'setup))
                   (let ,(etaf--component-prop-bindings props)
                     (ignore ,@props)
                     ,setup-form))))))
      `(progn
         (defconst ,definition-symbol
           (etaf--component-spec-create
            :name ',name
            :props ',props
            :defaults ,(etaf--component-default-resolver arguments)
            :render ,render-lambda
            :setup ,setup-lambda
            :styles ',styles-form)
           ,(or docstring
                (format "Definition of ETAF Component `%s'." name)))
         (etaf--register-component ',name ,definition-symbol)
         ',name))))

(provide 'etaf-component)

;;; etaf-component.el ends here
