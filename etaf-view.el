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
  token
  props
  children)

(cl-defstruct (etaf--expr
               (:constructor etaf--expr-create))
  "Internal executable child expression."
  token
  thunk)

(cl-defstruct (etaf--component-spec
               (:constructor etaf--component-spec-create))
  "Internal definition of one ETAF Component."
  name
  props
  render
  setup
  styles)

(cl-defstruct (etaf--component-call
               (:constructor etaf--component-call-create))
  "Internal Component invocation retained until rendering."
  spec
  props
  slots)

(cl-defstruct (etaf--slot-input
               (:constructor etaf--slot-input-create))
  "Call-site contribution to a named Component slot."
  name
  children)

(cl-defstruct (etaf--slot-projection
               (:constructor etaf--slot-projection-create))
  "A Component View request for one slot and its fallback children."
  name
  token
  fallback)

(cl-defstruct (etaf--raw-ebox
               (:constructor etaf--raw-ebox-create))
  "Explicit escape carrying an already-built public Ebox node."
  token
  thunk
  key-thunk)

(defconst etaf--host-names
  '(text fragment container row column stack flex grid spacer)
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

(defvar etaf--current-component-props nil
  "Dynamic props of the Component currently being evaluated.")

(defvar etaf--current-component-slots nil
  "Dynamic slots of the Component currently being evaluated.")

(defvar etaf--current-component-instance nil
  "Dynamic Component instance currently being evaluated.")

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
       "Component %S conflicts with a core Host" name))
    (when (and existing (not (eq existing etaf--host-marker))
               (not (eq existing spec)))
      (etaf--component-error
       "Component %S is already registered" name)))
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

(defun etaf--resolve-property-value (value)
  "Resolve one lazily compiled property VALUE."
  (if (etaf--expr-p value)
      (etaf--resolve-property-value (funcall (etaf--expr-thunk value)))
    value))

(defun etaf--resolve-property-plist (props)
  "Resolve all lazy values in PROPS while preserving its keys."
  (let ((copy nil)
        (tail props))
    (while tail
      (setq copy (append copy
                         (list (pop tail)
                               (etaf--resolve-property-value (pop tail))))))
    copy))

(defun etaf--compile-property-value (form)
  "Compile property FORM as a constant or a render-time thunk."
  (if (or (null form) (numberp form) (stringp form) (characterp form)
          (keywordp form) (eq form t)
          (and (consp form) (memq (car form) '(quote function))))
      form
    `(etaf--expr-create :thunk (lambda () ,form))))

(defun etaf--compile-property-plist (props)
  "Compile alternating property FORMS in PROPS into a generated property list."
  (let (compiled)
    (while props
      (let ((key (pop props))
            (value (pop props)))
        (setq compiled
              (append compiled
                      (list key (etaf--compile-property-value value))))))
    compiled))

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
      (etaf--syntax-error "Expr accepts :value and no children"))
    (let ((props (car parts)))
      (unless (and (= (length props) 2)
                   (eq (car props) :value))
        (etaf--syntax-error
         "Expr accepts exactly one attribute: :value"))
      (cadr props))))

(defun etaf--constant-slot-name (form)
  "Return the static slot symbol represented by FORM, or signal an error."
  (unless (and (consp form)
               (eq (car form) 'quote)
               (null (cddr form)))
    (etaf--syntax-error
     "Slot names must be quoted stable symbols: %S" form))
  (let ((name (cadr form)))
    (unless (and (symbolp name) (not (keywordp name))
                 (not (memq name '(nil t))))
      (etaf--syntax-error
       "Slot names must be stable non-keyword symbols: %S" form))
    name))

(defun etaf--compile-slot-form (items slot-mode)
  "Compile a slot form with ITEMS according to SLOT-MODE.

SLOT-MODE is `:projection' while compiling a Component's own View and
`:input' while compiling the children supplied to a Component call.  An
input slot must have an explicit `:name'; ordinary trailing children already
belong to the anonymous `default' slot."
  (let* ((parts (etaf--parse-attributes-and-children items))
         (props (car parts))
         (children (cdr parts))
         (name-supplied-p (plist-member props :name))
         (name (if name-supplied-p
                   (etaf--constant-slot-name (plist-get props :name))
                 'default)))
    (unless (or (null props)
                (and (= (length props) 2) (eq (car props) :name)))
      (etaf--syntax-error "Slot accepts only the optional :name attribute"))
    (when (and (eq slot-mode :input) (not name-supplied-p))
      (etaf--syntax-error
       "A named slot input requires :name; ordinary children fill default"))
    (let ((compiled (mapcar (lambda (child)
                              (etaf--compile-child-form child slot-mode))
                            children)))
      (if (eq slot-mode :projection)
          (let ((token (gensym "etaf-slot-site-")))
            `(etaf--slot-projection-create
              :name ',name
              :token ',token
              :fallback (list ,@compiled)))
        `(etaf--slot-input-create
          :name ',name
          :children (list ,@compiled))))))

(defun etaf--ordinary-expression-head-p (head)
  "Return non-nil when HEAD denotes ordinary Elisp computation."
  (or (memq head etaf--ordinary-elisp-heads)
      (special-form-p head)
      (and (symbolp head) (fboundp head))))

(defun etaf--compile-expr-form (items)
  "Compile an `expr' form with ITEMS into an executable View value."
  (let ((token (gensym "etaf-expr-site-")))
    `(etaf--expr-create
    :token ',token
    :thunk (lambda () ,(etaf--parse-expr-form items)))))

(defun etaf--compile-child-form (form &optional slot-mode)
  "Compile structural child FORM into code returning a View value.

SLOT-MODE distinguishes Component-owned projections from call-site inputs."
  (cond
   ((null form) nil)
   ((stringp form) `(quote ,form))
   ((and (consp form) (eq (car form) 'expr))
    (etaf--compile-expr-form (cdr form)))
   ((and (consp form) (eq (car form) 'slot))
    (etaf--compile-slot-form (cdr form) slot-mode))
   ((and (consp form) (eq (car form) 'raw-ebox))
    (etaf--compile-view-form form slot-mode))
   ((and (consp form) (symbolp (car form)))
    (when (etaf--ordinary-expression-head-p (car form))
      (etaf--syntax-error
       "Elisp expression %S must be inside (expr :value ...)" (car form)))
    (etaf--compile-view-form form slot-mode))
   ((consp form)
    (etaf--syntax-error "Invalid View child form: %S" form))
   (t
    (etaf--syntax-error
     "View children must be strings, nil, View forms, or expr results: %S"
     form))))

(defun etaf--compile-view-form (form &optional slot-mode)
  "Compile one structural View FORM into runtime construction code.

SLOT-MODE distinguishes Component-owned projections from call-site inputs."
  (cond
   ((null form) nil)
   ((stringp form) `(quote ,form))
   ((not (and (consp form) (symbolp (car form))))
    (etaf--syntax-error "View form must start with a symbol: %S" form))
   ((eq (car form) 'expr)
    (etaf--compile-expr-form (cdr form)))
   ((eq (car form) 'slot)
    ;; A render closure returned from `:setup' invokes `etaf-view' later than
    ;; the Component definition macro, so the public macro defaults to
    ;; projection mode.  An unowned projection simply uses its fallback.
    (etaf--compile-slot-form (cdr form) slot-mode))
   ((eq (car form) 'raw-ebox)
    (let ((parts (etaf--parse-attributes-and-children (cdr form))))
      (when (cdr parts)
        (etaf--syntax-error "Raw-ebox accepts :value, optional :key, and no children"))
      (let ((props (car parts)))
        (unless (and (plist-member props :value)
                     (cl-every #'keywordp (cl-loop for (key _value) on props by #'cddr collect key)))
          (etaf--syntax-error "Raw-ebox requires :value"))
        (let ((allowed '(:value :key))
              (token (gensym "etaf-raw-site-")))
          (dolist (key (cl-loop for (key _value) on props by #'cddr collect key))
            (unless (memq key allowed)
              (etaf--syntax-error "Raw-ebox does not accept %S" key)))
          `(etaf--raw-ebox-create
            :token ',token
            :thunk (lambda () ,(plist-get props :value))
            :key-thunk ,(when (plist-member props :key)
                          `(lambda () ,(plist-get props :key))))))))
   (t
    (let* ((parts (etaf--parse-attributes-and-children (cdr form)))
           (props (car parts))
           (children (cdr parts))
           (host-view-p (eq (gethash (car form) etaf--view-registry)
                            etaf--host-marker))
           (child-slot-mode (if host-view-p slot-mode :input)))
      (let ((token (and (memq (car form) '(fragment etaf-fragment))
                        (gensym "etaf-fragment-site-"))))
        `(etaf--view-call ',(car form)
                          (list ,@(etaf--compile-property-plist props))
                          (list ,@(mapcar (lambda (child)
                                            (etaf--compile-child-form
                                             child child-slot-mode))
                                          children))
                          ,(and token `',token)))))))

;;;###autoload
(defmacro etaf-view (form)
  "Construct a normalized ETAF View from structural FORM.

FORM uses one grammar for Hosts and Component calls:

  (NAME :PROPERTY VALUE ... CHILD ...)

Properties must come first and children must come last.  Property values are
ordinary Elisp expressions.  `expr' is the only computation bridge in the
child region and accepts only `:value'."
  (declare (indent 1) (debug (form)))
  (etaf--compile-view-form form :projection))

(defun etaf--component-prop-key (name)
  "Return the keyword used to pass Component prop NAME."
  (if (keywordp name)
      name
    (etaf--keyword-for-name name)))

(defun etaf--validate-component-props (spec props)
  "Validate Component SPEC against evaluated property PLIST PROPS."
  (let ((allowed (append '(:key)
                         (mapcar #'etaf--component-prop-key
                                 (etaf--component-spec-props spec))))
        (tail (etaf--validate-property-plist props)))
    (while tail
      (let ((key (pop tail)))
        (pop tail)
        (unless (memq key allowed)
          (etaf--component-error
           "Unknown prop %S for Component %S"
           key (etaf--component-spec-name spec)))))
    props))

(defun etaf--view-call (name props children &optional token)
  "Construct NAME from PROPS and CHILDREN, retaining optional site TOKEN."
  (unless (symbolp name)
    (etaf--syntax-error "View name must be a symbol: %S" name))
  (setq props (etaf--validate-property-plist props))
  (let ((entry (gethash name etaf--view-registry)))
    (cond
     ((eq entry etaf--host-marker)
      (when (plist-member props :key)
        (etaf--validate-key
         (etaf--resolve-property-value (plist-get props :key))))
      (etaf--view-node-create
       :name (etaf--canonical-host-name name)
       :token token
       :props props
       :children children))
     ((etaf--component-spec-p entry)
      (etaf--validate-component-props entry props)
      (let (default-children named-slots)
        (dolist (child children)
          (if (etaf--slot-input-p child)
              (progn
                (when (assq (etaf--slot-input-name child) named-slots)
                  (etaf--component-error
                   "Duplicate Component slot %S" (etaf--slot-input-name child)))
                (push (cons (etaf--slot-input-name child)
                            (etaf--slot-input-children child))
                      named-slots))
            (push child default-children)))
        (setq default-children (nreverse default-children)
              named-slots (nreverse named-slots))
        (when (and default-children (assq 'default named-slots))
          (etaf--component-error
           "Component default slot has both children and an explicit input"))
        (etaf--component-call-create
         :spec entry
         :props props
         :slots (if default-children
                    (cons (cons 'default default-children) named-slots)
                  named-slots))))
     (t
      (etaf--component-error "Unknown ETAF Host or Component: %S" name)))))

(provide 'etaf-view)

;;; etaf-view.el ends here
