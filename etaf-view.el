;;; etaf-view.el --- Unified ETAF View grammar -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This file owns the small structural language shared by Hosts and
;; Components.  It deliberately does not render, mutate buffers, or implement
;; lifecycle.  `etaf-view' compiles one structural form into a short-lived
;; View value; the renderer lowers that value to Ebox later.

;;; Code:

(require 'cl-lib)

(define-error 'etaf-view-error "Invalid ETAF View")
(define-error 'etaf-view-syntax-error "Invalid ETAF View syntax"
  'etaf-view-error)
(define-error 'etaf-component-call-error "Invalid ETAF Component call"
  'etaf-view-error)

(cl-defstruct (etaf--view-node
               (:constructor etaf--view-node-create))
  "Internal normalized description of one Host View."
  name
  props
  children)

(cl-defstruct (etaf--expr
               (:constructor etaf--expr-create))
  "Internal executable child expression."
  thunk)

(cl-defstruct (etaf--component-spec
               (:constructor etaf--component-spec-create))
  "Internal definition of one stateless Component."
  name
  props
  render)

(cl-defstruct (etaf--component-call
               (:constructor etaf--component-call-create))
  "Internal Component invocation retained until rendering."
  spec
  props
  children)

(defconst etaf--host-names
  '(text fragment container row column stack flex spacer)
  "Minimal unstyled Hosts implemented by ETAF core.

Product Components such as Button belong to `etaf-ui'; they are not added to
this list merely to make a demo convenient.")

(defconst etaf--host-marker 'etaf--host
  "Value stored in the View registry for a built-in Host.")

(defconst etaf--ordinary-elisp-heads
  '(and or not if when unless cond case pcase
    let let* letrec letrec* prog prog1 prog2 progn
    while dolist dotimes cl-loop mapcar mapc mapcan
    save-excursion save-restriction save-window-excursion
    condition-case condition-case-unless-debug unwind-protect
    catch throw signal error user-error quote function lambda
    setq setq-default setf psetf psetq incf decf push pop
    funcall apply apply-partially progn eval macroexpand)
  "Elisp heads that must appear inside `expr', not as View children.")

(defvar etaf--view-registry (make-hash-table :test #'eq)
  "Registry of Hosts and Components used by structural View calls.")

(defun etaf--syntax-error (format-string &rest arguments)
  "Signal a View syntax error formatted from FORMAT-STRING and ARGUMENTS."
  (signal 'etaf-view-syntax-error
          (list (apply #'format format-string arguments))))

(defun etaf--component-error (format-string &rest arguments)
  "Signal a Component call error formatted from FORMAT-STRING and ARGUMENTS."
  (signal 'etaf-component-call-error
          (list (apply #'format format-string arguments))))

(defun etaf--keyword-for-name (name)
  "Return the property keyword corresponding to symbol NAME."
  (intern (concat ":" (symbol-name name))))

(defun etaf--component-alias (name)
  "Return the public View alias for canonical Component NAME, or nil.

Canonical names may carry the `etaf-' package prefix.  The prefix is omitted
in View syntax unless doing so would collide with an Elisp function, special
form, or core Host.  A collision receives a semantic `-view' alias."
  (when (and (symbolp name)
             (string-prefix-p "etaf-" (symbol-name name)))
    (let* ((suffix (substring (symbol-name name) (length "etaf-")))
           (candidate (intern suffix)))
      (cond
       ((or (memq candidate etaf--host-names)
            (special-form-p candidate)
            (fboundp candidate))
        (intern (concat suffix "-view")))
       (t candidate)))))

(defun etaf--register-component (name spec)
  "Register Component SPEC under canonical NAME and its public alias."
  (unless (and (symbolp name) (etaf--component-spec-p spec))
    (signal 'wrong-type-argument (list 'etaf--component-spec-p spec)))
  (let ((existing (gethash name etaf--view-registry)))
    (when (eq existing etaf--host-marker)
      (etaf--component-error
       "Component %S conflicts with a core Host" name)))
  (puthash name spec etaf--view-registry)
  (when-let ((alias (etaf--component-alias name)))
    (let ((existing (gethash alias etaf--view-registry)))
      (when (and existing (not (eq existing spec)))
        (etaf--component-error
         "Component alias %S is already registered" alias)))
    (puthash alias spec etaf--view-registry))
  spec)

(defun etaf--register-core-hosts ()
  "Register the core Host names and explicit prefixed spellings."
  (dolist (name etaf--host-names)
    (puthash name etaf--host-marker etaf--view-registry)
    (puthash (intern (concat "etaf-" (symbol-name name)))
             etaf--host-marker
             etaf--view-registry)))

(defun etaf--canonical-host-name (name)
  "Return the unprefixed renderer name for Host NAME."
  (if (and (symbolp name)
           (string-prefix-p "etaf-" (symbol-name name)))
      (let ((short-name (intern (substring (symbol-name name) 5))))
        (if (memq short-name etaf--host-names)
            short-name
          name))
    name))

(etaf--register-core-hosts)

(defun etaf--validate-property-plist (props)
  "Validate evaluated View PROPS and return a defensive copy."
  (unless (and (proper-list-p props) (zerop (% (length props) 2)))
    (etaf--component-error "View properties must be keyword/value pairs: %S"
                           props))
  (let ((copy nil)
        (seen nil)
        (tail props))
    (while tail
      (let ((key (pop tail))
            (value (pop tail)))
        (unless (keywordp key)
          (etaf--component-error "View property name must be a keyword: %S"
                                 key))
        (when (memq key seen)
          (etaf--component-error "Duplicate View property: %S" key))
        (push key seen)
        (setq copy (append copy (list key value)))))
    copy))

(defun etaf--validate-key (key)
  "Validate a Host identity KEY and return it."
  (unless (or (null key) (symbolp key) (stringp key)
              (integerp key) (floatp key))
    (etaf--component-error
     "View keys must be immutable scalar values: %S" key))
  key)

(defun etaf--parse-attributes-and-children (items)
  "Split structural ITEMS into `(PROPS . CHILDREN)'.

All keyword attributes must precede the first non-keyword child.  Values are
returned as unevaluated forms because they are ordinary Elisp expressions in
the generated code."
  (let (props children seen children-started)
    (while items
      (let ((item (pop items)))
        (if (keywordp item)
            (progn
              (when children-started
                (etaf--syntax-error
                 "Attributes must precede children; found %S after a child"
                 item))
              (unless items
                (etaf--syntax-error "Missing value for View property %S"
                                    item))
              (when (memq item seen)
                (etaf--syntax-error "Duplicate View property %S" item))
              (push item seen)
              (let ((value (pop items)))
                (push item props)
                (push value props)))
          (setq children-started t)
          (push item children))))
    (cons (nreverse props) (nreverse children))))

(defun etaf--parse-expr-form (items)
  "Return the value form from an `expr' child with ITEMS.

`expr' intentionally has one property, `:value', and no children."
  (let ((parts (etaf--parse-attributes-and-children items)))
    (when (cdr parts)
      (etaf--syntax-error "expr accepts :value and no children"))
    (let ((props (car parts)))
      (unless (and (= (length props) 2)
                   (eq (car props) :value))
        (etaf--syntax-error
         "expr accepts exactly one attribute: :value"))
      (cadr props))))

(defun etaf--ordinary-expression-head-p (head)
  "Return non-nil when HEAD denotes ordinary Elisp computation."
  (or (memq head etaf--ordinary-elisp-heads)
      (special-form-p head)
      (and (symbolp head) (fboundp head))))

(defun etaf--compile-expr-form (items)
  "Compile an `expr' form with ITEMS into an executable View value."
  `(etaf--expr-create
    :thunk (lambda () ,(etaf--parse-expr-form items))))

(defun etaf--compile-child-form (form)
  "Compile structural child FORM into code returning a View value."
  (cond
   ((null form) nil)
   ((stringp form) `(quote ,form))
   ((and (consp form) (eq (car form) 'expr))
    (etaf--compile-expr-form (cdr form)))
   ((and (consp form) (symbolp (car form)))
    (when (etaf--ordinary-expression-head-p (car form))
      (etaf--syntax-error
       "Elisp expression %S must be inside (expr :value ...)" (car form)))
    (etaf--compile-view-form form))
   ((consp form)
    (etaf--syntax-error "Invalid View child form: %S" form))
   (t
    (etaf--syntax-error
     "View children must be strings, nil, View forms, or expr results: %S"
     form))))

(defun etaf--compile-view-form (form)
  "Compile one structural View FORM into runtime construction code."
  (cond
   ((null form) nil)
   ((stringp form) `(quote ,form))
   ((not (and (consp form) (symbolp (car form))))
    (etaf--syntax-error "View form must start with a symbol: %S" form))
   ((eq (car form) 'expr)
    (etaf--compile-expr-form (cdr form)))
   ((eq (car form) 'slot)
    (etaf--syntax-error
     "slot is not implemented in the P0 package; use ordinary children for now"))
   ((eq (car form) 'raw-ebox)
    (etaf--syntax-error
     "raw-ebox is not implemented in the P0 package"))
   (t
    (let* ((parts (etaf--parse-attributes-and-children (cdr form)))
           (props (car parts))
           (children (cdr parts)))
      `(etaf--view-call ',(car form)
                        (list ,@props)
                        (list ,@(mapcar #'etaf--compile-child-form children)))))))

;;;###autoload
(defmacro etaf-view (form)
  "Construct a normalized ETAF View from structural FORM.

FORM uses one grammar for Hosts and Component calls:

  (NAME :PROPERTY VALUE ... CHILD ...)

Properties must come first and children must come last.  Property values are
ordinary Elisp expressions.  `expr' is the only computation bridge in the
child region and accepts only `:value'."
  (declare (indent 1) (debug (form)))
  (etaf--compile-view-form form))

(defun etaf--component-prop-key (name)
  "Return the keyword used to pass Component prop NAME."
  (if (keywordp name)
      name
    (etaf--keyword-for-name name)))

(defun etaf--validate-component-props (spec props)
  "Validate Component SPEC against evaluated property PLIST PROPS."
  (let ((allowed (mapcar #'etaf--component-prop-key
                         (etaf--component-spec-props spec)))
        (tail (etaf--validate-property-plist props)))
    (while tail
      (let ((key (pop tail)))
        (pop tail)
        (unless (memq key allowed)
          (etaf--component-error
           "Unknown prop %S for Component %S"
           key (etaf--component-spec-name spec)))))
    props))

(defun etaf--view-call (name props children)
  "Construct a Host or Component named NAME from PROPS and CHILDREN."
  (unless (symbolp name)
    (etaf--syntax-error "View name must be a symbol: %S" name))
  (setq props (etaf--validate-property-plist props))
  (let ((entry (gethash name etaf--view-registry)))
    (cond
     ((eq entry etaf--host-marker)
      (when (plist-member props :key)
        (etaf--validate-key (plist-get props :key)))
      (etaf--view-node-create
       :name (etaf--canonical-host-name name)
       :props props
       :children children))
     ((etaf--component-spec-p entry)
      (etaf--validate-component-props entry props)
      (etaf--component-call-create
       :spec entry
       :props props
       :children children))
     (t
      (etaf--component-error "Unknown ETAF Host or Component: %S" name)))))

(defun etaf--resolve-value (value)
  "Resolve VALUE to a flat list of string or View leaves.

This is deliberately a value normalizer, not an evaluator.  Only `expr'
thunks are executed; a quoted list returned by an expression is treated as a
sequence and each member must already be a valid View value."
  (cond
   ((null value) nil)
   ((or (stringp value)
        (etaf--view-node-p value))
    (list value))
   ((etaf--expr-p value)
    (etaf--resolve-value (funcall (etaf--expr-thunk value))))
   ((etaf--component-call-p value)
    (etaf--resolve-value
     (funcall (etaf--component-spec-render
               (etaf--component-call-spec value))
              (etaf--component-call-props value)
              (etaf--component-call-children value))))
   ((proper-list-p value)
    (cl-mapcan #'etaf--resolve-value value))
   (t
    (signal 'etaf-view-error
            (list (format
                   "View values must be strings, nil, Views, or sequences: %S"
                   value))))))

(provide 'etaf-view)

;;; etaf-view.el ends here
