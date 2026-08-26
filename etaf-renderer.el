;;; etaf-renderer.el --- ETAF to Ebox rendering bridge -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This is ETAF's only Ebox boundary.  It lowers normalized View values and
;; delegates measurement, layout, painting, and publication to Ebox.  Runtime
;; owns retained Component instances and calls the renderer through the small
;; `etaf--render-value-list' port below.

;;; Code:

(require 'cl-lib)
(require 'ebox)
(require 'etaf-view)
(require 'etaf-component)
(require 'etaf-context)

(declare-function etaf--runtime-render-component "etaf-runtime" (runtime call path))

(defvar etaf--rendered-range-container-nodes nil
  "Candidate-local Ebox nodes whose layout directly contains a Range.")
(declare-function etaf--runtime-render-child-range "etaf-runtime" (runtime expr path))
(declare-function etaf--runtime-render-fragment-range
                  "etaf-runtime" (runtime fragment path))
(declare-function etaf--runtime-render-raw-range
                  "etaf-runtime" (runtime raw path))
(declare-function etaf--runtime-render-slot-range
                  "etaf-runtime" (runtime projection path))
(declare-function etaf--runtime-register-semantic-host
                  "etaf-runtime"
                  (runtime name props backend-props path
                           &optional theme-bindings theme-deps
                           property-bindings property-deps
                           property-context-deps base-props site-token))
(declare-function etaf--runtime-resolve-host-properties
                  "etaf-runtime" (props))
(declare-function etaf--runtime-theme-paint-value
                  "etaf-runtime" (runtime property token source resolved))
(declare-function etaf--runtime-finish-semantic-host
                  "etaf-runtime" (runtime semantic-id &optional content content-parts))
(declare-function etaf--runtime-render-inline-content
                  "etaf-runtime" (runtime host-id values path &optional surface))
(declare-function etaf--runtime-call-with-component-env
                  "etaf-runtime" (runtime component-id function))
(declare-function etaf--runtime-behavior-node "etaf-runtime" (runtime node path))
(declare-function etaf--runtime-register-host
                  "etaf-runtime" (runtime props path &optional site-token))
(declare-function etaf-theme-defaults "etaf-context" (&optional default))
(declare-function etaf-theme-token-p "etaf-context" (value))
(declare-function etaf-theme-token-resolve "etaf-context" (value))

(define-error 'etaf-renderer-error "ETAF rendering error")

(defconst etaf--semantic-props
  '(:class :id :role :disabled :tab-index :ref :use :aria-label
    :aria-description :on-press :on-key-down :on-mouse-down :on-mouse-drag
    :on-wheel :on-input :on-focus :on-blur)
  "ETAF semantic properties that are not Ebox box properties.")

(defvar etaf--render-runtime nil
  "Runtime currently lowering a View tree, or nil for a pure render.")

(defvar etaf--render-style-stack nil
  "Component style scopes active during View lowering.")

(defvar etaf--render-parent-style-stack nil
  "Style scopes belonging to the caller of the current Component.")

(defvar etaf--current-semantic-parent-id 0
  "Semantic parent receiving Hosts during mounted lowering.")

(defvar etaf--rendering-range-p nil
  "Non-nil while eagerly lowering descendants of one Range item Host.")

(defun etaf--event-property-p (property)
  "Return non-nil when PROPERTY is an ETAF event callback property."
  (and (keywordp property)
       (string-prefix-p "on-" (substring (symbol-name property) 1))))

(defun etaf--generated-host-ref (props path &optional site-token)
  "Return the explicit or generated opaque Host reference."
  (or (plist-get props :ref)
      (list 'etaf-host (or site-token (copy-sequence path)))))

(defun etaf--merge-property (props key value)
  "Return PROPS with KEY set to VALUE, preserving the original order."
  (if (plist-member props key)
      (let ((copy (copy-sequence props)))
        (plist-put copy key value)
        copy)
    (append props (list key value))))

(defun etaf--style-selector-match-p (selector node &optional root-p)
  "Return whether string SELECTOR matches normalized Host NODE.

This small matcher covers the stable core selector vocabulary.  The complete
ECSS compiler is layered on top later without changing the View or Ebox
boundaries: `&', `.class', `&.class', and `[role=value]' are enough for core
Component styles and remain deterministic for all text applications.
ROOT-P marks the Component style root."
  (let* ((name (symbol-name (etaf--view-node-name node)))
         (props (etaf--view-node-props node))
         (class (plist-get props :class))
         (classes (cond
                   ((stringp class) (split-string class "[[:space:]]+" t))
                   ((symbolp class) (list (symbol-name class)))
                   ((listp class)
                    (mapcar (lambda (item)
                              (if (symbolp item)
                                  (symbol-name item)
                                (format "%s" item)))
                            class))
                   (t nil))))
    (cond
     ((string= selector "&") root-p)
     ((string-prefix-p "." selector)
      (member (substring selector 1) classes))
     ((string-prefix-p "&." selector)
      (and root-p (member (substring selector 2) classes)))
     ((string-match "\\`\\[role=\\([^]]+\\)\\]\\'" selector)
      (equal (format "%s" (plist-get props :role))
             (match-string 1 selector)))
     ((string= selector name) t)
     (t nil))))

(defun etaf--apply-inline-style-rules (node styles &optional root-p)
  "Apply static STYLES to NODE and return a copied normalized node.

Inline View properties win over Component style declarations.  Styles are
represented as ordinary static data until this final lowering step; they do
not create another visual node category."
  (if (null styles)
      node
    (let ((props (copy-sequence
                  (etaf--resolve-property-plist
                   (etaf--view-node-props node)))))
      (dolist (rule (cdr styles))
        (when (and (consp rule) (stringp (car rule))
                   (etaf--style-selector-match-p (car rule) node root-p))
          (let ((rule-props (cdr rule)))
            (while rule-props
              (let ((key (pop rule-props))
                    (value (pop rule-props)))
                (unless (keywordp key)
                  (signal 'etaf-renderer-error
                          (list (format "Style property must be a keyword: %S"
                                        key))))
                (setq value (if (and (consp value) (eq (car value) 'quote))
                                (cadr value)
                              value))
                (unless (plist-get props key)
                  (setq props (etaf--merge-property props key value))))))))
      (etaf--view-node-create
       :name (etaf--view-node-name node)
       :token (etaf--view-node-token node)
       :props props
       :children (etaf--view-node-children node)))))

(defun etaf--apply-theme-defaults (node)
  "Apply known inherited Theme defaults to NODE without overriding props.
Unknown Theme keys remain readable through `etaf-theme-value' but are design
tokens, not Ebox Host properties, and therefore are not materialized here."
  (let* ((source (etaf--theme-source))
         (defaults (etaf--theme-source-value source nil nil)))
    (if (null defaults)
        node
      (let ((props (copy-sequence
                    (etaf--resolve-property-plist
                     (etaf--view-node-props node)))))
        (while defaults
          (let ((key (pop defaults))
                (value (pop defaults)))
            (when (and (etaf--theme-ebox-property-p key)
                       (not (plist-get props key)))
              (setq props
                    (etaf--merge-property
                     props key (etaf-theme-token key value))))))
        (etaf--view-node-create
         :name (etaf--view-node-name node)
         :token (etaf--view-node-token node)
         :props props
         :children (etaf--view-node-children node))))))

(defun etaf--resolve-theme-property-plist (props)
  "Return resolved PROPS, Theme bindings, and reactive dependencies."
  (let ((source (etaf--theme-source)) resolved bindings deps)
    (while props
      (let ((property (pop props))
            (value (pop props)))
        (if (etaf-theme-token-p value)
            (let ((resolved-value
                   (etaf--theme-token-resolve-from-source value source)))
              (push property resolved)
              (push (if etaf--render-runtime
                        (etaf--runtime-theme-paint-value
                         etaf--render-runtime property value source
                         resolved-value)
                      resolved-value)
                    resolved)
              (when (or (etaf-ref-p source) (etaf-computed-p source))
                (push (etaf--theme-property-binding-create
                       :property property :token (copy-tree value)
                       :source source)
                      bindings)
                (cl-pushnew source deps :test #'eq)))
          (push property resolved)
          (push value resolved))))
    (list (nreverse resolved) (nreverse bindings) (nreverse deps))))

(defun etaf--theme-ebox-property-p (key)
  "Return non-nil when Theme KEY is a known Ebox property.
The public `ebox-property-rules' table is the shared property vocabulary;
custom Theme tokens remain Context data and are never copied onto Hosts."
  (and (keywordp key)
       (boundp 'ebox-property-rules)
       (assq key ebox-property-rules)))

(defun etaf--inline-text-surface-properties (props)
  "Return text properties represented by inline text PROPS."
  (let ((surface (copy-sequence (or (plist-get props :surface-properties) nil))))
    (when (plist-member props :face)
      (setq surface (append surface (list 'face (plist-get props :face)))))
    (when (plist-member props :color)
      (setq surface (append surface
                             (list 'foreground (plist-get props :color)))))
    (when (plist-member props :bgcolor)
      (setq surface (append surface
                             (list 'background (plist-get props :bgcolor)))))
    surface))

(defun etaf--apply-inline-surface-properties (content surface)
  "Return CONTENT with resolved inline SURFACE properties applied."
  (let ((result (copy-sequence content)))
    (when (and surface (not (zerop (length result))))
      (add-text-properties 0 (length result) surface result))
    result))

(defun etaf--inline-text-content (value)
  "Return `(SUCCESS . STRING)' for inline-compatible text VALUE.

Nested `text' Hosts become propertized runs in one Ebox content surface.
Other View Hosts and Components return a failed result so the caller can use
the ordinary layout lowering path instead."
  (cond
   ((stringp value) (cons t value))
   ((etaf--expr-p value)
    (etaf--inline-text-content (funcall (etaf--expr-thunk value))))
   ((etaf--view-node-p value)
    (if (eq (etaf--view-node-name value) 'text)
        (let ((children (etaf--view-node-children value))
              (result "")
              (valid-p t))
          (dolist (child children)
            (pcase (etaf--inline-text-content child)
              (`(t . ,content) (setq result (concat result content)))
              (_ (setq valid-p nil))))
          (if valid-p
              (let ((surface
                     (etaf--inline-text-surface-properties
                      (etaf--resolve-property-plist
                       (etaf--view-node-props value)))))
                (when surface
                  (setq result (copy-sequence result))
                  (unless (zerop (length result))
                    (add-text-properties 0 (length result) surface result)))
                (cons t result))
            (cons nil nil)))
      (cons nil nil)))
   ((proper-list-p value)
    (let ((result "")
          (valid-p t))
      (dolist (item value)
        (pcase (etaf--inline-text-content item)
          (`(t . ,content) (setq result (concat result content)))
          (_ (setq valid-p nil))))
      (cons valid-p (and valid-p result))))
   (t (cons nil nil))))

(defun etaf--inline-text-structural-p (value)
  "Return non-nil when VALUE can be owned by mounted inline effects."
  (cond
   ((or (null value) (stringp value) (etaf--expr-p value)) t)
   ((etaf--view-node-p value)
    (and (eq (etaf--view-node-name value) 'text)
         (cl-every #'etaf--inline-text-structural-p
                   (etaf--view-node-children value))))
   ((proper-list-p value)
    (cl-every #'etaf--inline-text-structural-p value))
   (t nil)))

(defun etaf--ebox-properties (props path &optional site-token)
  "Translate ETAF PROPS at PATH into Ebox's public property list."
  (let* ((source-props (etaf--resolve-property-plist props))
         (props (copy-sequence source-props))
         ebox-props surface-properties)
    (while props
      (let ((key (pop props))
            (value (pop props)))
        (cond
         ((eq key :face)
          (push 'face surface-properties)
          (push value surface-properties))
         ((eq key :surface-properties)
          (let ((tail value))
            (while tail
              (push (pop tail) surface-properties)
              (push (pop tail) surface-properties))))
         ((eq key :content)
          (signal 'etaf-renderer-error
                  (list "Use View children for content, not :content")))
         ((or (memq key etaf--semantic-props)
              (etaf--event-property-p key)
              (eq key :styles))
          nil)
         (t
          (push key ebox-props)
          (push value ebox-props)))))
    (setq ebox-props (nreverse ebox-props)
          surface-properties (nreverse surface-properties))
    (setq ebox-props
          (etaf--merge-property
           ebox-props :host-ref
           (etaf--generated-host-ref source-props path site-token)))
    (when surface-properties
      (setq ebox-props
            (append ebox-props
                    (list :surface-properties surface-properties))))
    ebox-props))

(defun etaf--flatten-view-value (value)
  "Flatten VALUE through transparent `expr' and sequence values."
  (cond
   ((null value) nil)
   ((or (stringp value) (etaf--view-node-p value)
        (etaf--component-call-p value) (etaf--slot-projection-p value)
        (etaf--raw-ebox-p value))
    (list value))
   ((etaf--expr-p value)
    (etaf--flatten-view-value (funcall (etaf--expr-thunk value))))
   ((proper-list-p value)
    (cl-mapcan #'etaf--flatten-view-value value))
   (t
    (signal 'etaf-renderer-error
            (list (format "Invalid View value: %S" value))))))

(defun etaf--render-slot-projection (projection path)
  "Render PROJECTION at PATH using the active Component slot collection."
  (setq etaf--raw-slot-read-p t)
  (let* ((name (etaf--slot-projection-name projection))
         (slots etaf--current-component-slots)
         (entry (assq name slots))
         (content (and entry (cdr entry)))
         (children (if (etaf--slot-content-p content)
                       (etaf--slot-content-children content)
                     content))
         (owner-id (and (etaf--slot-content-p content)
                        (etaf--slot-content-owner-component-id content)))
         (fallback (etaf--slot-projection-fallback projection)))
    (let ((etaf--render-style-stack
           (if entry
               etaf--render-parent-style-stack
             etaf--render-style-stack)))
      (let ((render (lambda ()
                      (etaf--render-value-list
                       (if entry children fallback)
                       (append path (list :slot name))))))
        (if (and entry etaf--render-runtime)
            (etaf--runtime-call-with-component-env
             etaf--render-runtime owner-id render)
          (funcall render))))))

(defun etaf--slot-projection-range-compatible-p (projection)
  "Return whether mounted PROJECTION can use the current slot Range slice."
  (let* ((entry (assq (etaf--slot-projection-name projection)
                      etaf--current-component-slots))
         (content (and entry (cdr entry)))
         (values (if entry
                     (if (etaf--slot-content-p content)
                         (etaf--slot-content-children content)
                       content)
                   (etaf--slot-projection-fallback projection))))
    (cl-labels
        ((valid
          (value)
          (cond ((or (null value) (stringp value) (etaf--expr-p value)) t)
                ((etaf--view-node-p value)
                 (and (not (eq (etaf--view-node-name value) 'fragment))
                      (cl-every #'valid (etaf--view-node-children value))))
                ((proper-list-p value) (cl-every #'valid value))
                (t nil))))
      (valid values))))

(defun etaf--render-component-call-pure (call path)
  "Render stateless CALL at PATH without a retained Runtime."
  (let* ((spec (etaf--component-call-spec call))
         (render (etaf--component-spec-render spec)))
    (when (etaf--component-spec-setup spec)
      (signal 'etaf-renderer-error
              (list "Stateful Component requires `etaf-mount'")))
    (let ((etaf--current-component-props
           (etaf--component-call-props call))
          (etaf--current-component-slots
           (etaf--component-call-slots call)))
      (let ((etaf--render-parent-style-stack etaf--render-style-stack)
            (etaf--render-style-stack
             (list (cons (etaf--component-spec-styles spec)
                         (append path (list :component
                                            (etaf--component-spec-name spec)))))))
        (etaf--render-value-list
         (funcall render
                  (etaf--component-call-props call)
                  (etaf--component-call-slots call))
         (append path (list :component (etaf--component-spec-name spec))))))))

(defun etaf--render-value-list (value path)
  "Render VALUE at structural PATH into a list of Ebox nodes."
  (let* ((items (etaf--flatten-view-value value))
         (multiple-p (> (length items) 1)))
    (cl-loop for item in items
             for index from 0
             for item-path = (if multiple-p
                                 (append path (list index))
                               path)
             append
             (cond
              ((stringp item)
               (when etaf--render-runtime
                 (let ((semantic-id
                        (etaf--runtime-register-semantic-host
                         etaf--render-runtime 'text nil nil item-path)))
                   (etaf--runtime-finish-semantic-host
                    etaf--render-runtime semantic-id item)))
               (list (ebox-create :content item)))
              ((etaf--view-node-p item)
               (etaf--render-node item item-path))
              ((etaf--component-call-p item)
               (if etaf--render-runtime
                   (let ((result (etaf--runtime-render-component
                                  etaf--render-runtime item item-path)))
                     (if (and (consp result)
                              (eq (car result) 'component-output-range))
                         (cdr result)
                       (list result)))
                 (etaf--render-component-call-pure item item-path)))
              ((etaf--slot-projection-p item)
               (etaf--render-slot-projection item item-path))
              ((etaf--raw-ebox-p item)
               (let ((node (funcall (etaf--raw-ebox-thunk item)))
                     (key (and (etaf--raw-ebox-key-thunk item)
                               (funcall (etaf--raw-ebox-key-thunk item)))))
                 (unless node
                   (signal 'etaf-renderer-error
                           (list "raw-ebox :value returned nil")))
                 (unless (listp node)
                   (signal 'etaf-renderer-error
                           (list "raw-ebox :value must return an Ebox node")))
                 (when key
                   (etaf--validate-key key)
                   (setq node (copy-sequence node))
                   (plist-put node :key key))
                 (list node)))
              (t
               (signal 'etaf-renderer-error
                       (list (format "Unresolved View item: %S" item))))))))

(defun etaf--render-node (node path)
  "Render normalized Host NODE at structural PATH."
  (let* ((node (if (and etaf--render-runtime
                        (fboundp 'etaf--runtime-behavior-node))
                   (etaf--runtime-behavior-node
                    etaf--render-runtime node path)
                 node))
         (property-result
          (if etaf--render-runtime
              (etaf--runtime-resolve-host-properties
               (etaf--view-node-props node))
            (list (etaf--resolve-property-plist
                   (etaf--view-node-props node))
                  nil nil nil)))
         (property-bindings (nth 1 property-result))
         (property-deps (nth 2 property-result))
         (property-context-deps (nth 3 property-result))
         (base-props (car property-result))
         (node (let ((copy (copy-sequence node)))
                 (setf (etaf--view-node-props copy) base-props)
                 copy))
         (node (if (fboundp 'etaf--runtime-style-node)
                   (etaf--runtime-style-node node path)
                 node))
         (node (etaf--apply-theme-defaults node))
         (name (etaf--view-node-name node))
         (theme-result
          (etaf--resolve-theme-property-plist
           (etaf--resolve-property-plist (etaf--view-node-props node))))
         (raw-props (nth 0 theme-result))
         (theme-bindings (nth 1 theme-result))
         (theme-deps (nth 2 theme-result))
         (props (etaf--ebox-properties
                 raw-props path (etaf--view-node-token node)))
         (children (etaf--view-node-children node)))
    (when (and etaf--render-runtime
               (fboundp 'etaf--runtime-register-host))
      (etaf--runtime-register-host
       etaf--render-runtime raw-props path (etaf--view-node-token node)))
    (pcase name
      ('text
       (let* ((semantic-id
              (and etaf--render-runtime
                    (etaf--runtime-register-semantic-host
                     etaf--render-runtime name raw-props props path
                     theme-bindings theme-deps property-bindings
                     property-deps property-context-deps base-props
                     (etaf--view-node-token node))))
              (child-path (append path (list :text)))
              (runtime-inline
               (and semantic-id
                    (etaf--inline-text-structural-p children)
                    (etaf--runtime-render-inline-content
                     etaf--render-runtime semantic-id children child-path)))
              (flat (unless runtime-inline
                      (cl-mapcan #'etaf--flatten-view-value children)))
              (inline (if runtime-inline
                          (cons t (car runtime-inline))
                        (etaf--inline-text-content flat)))
              (rendered (unless (car inline)
                          (let ((etaf--current-semantic-parent-id
                                 (or semantic-id
                                     etaf--current-semantic-parent-id)))
                            (etaf--render-value-list flat child-path)))))
         (when semantic-id
           (etaf--runtime-finish-semantic-host
           etaf--render-runtime semantic-id
            (and (car inline) (cdr inline))
            (and runtime-inline (cadr runtime-inline))))
         (if (car inline)
             (list (apply #'ebox-create :content (cdr inline) props))
           (list (ebox-build (append (list 'row) props rendered))))))
      ('spacer
       (when children
         (signal 'etaf-renderer-error
                 (list "spacer cannot have children")))
       (when etaf--render-runtime
         (let ((semantic-id (etaf--runtime-register-semantic-host
                             etaf--render-runtime name raw-props props path
                             theme-bindings theme-deps property-bindings
                             property-deps property-context-deps base-props
                             (etaf--view-node-token node))))
           (etaf--runtime-finish-semantic-host
            etaf--render-runtime semantic-id)))
       (list (apply #'ebox-spacer props)))
      ('fragment
       (etaf--render-value-list children (append path (list :fragment))))
      ((or 'box 'row 'column 'container 'stack 'flex 'grid)
       (let ((nodes nil)
             (index 0)
             (range-child-p nil)
             (semantic-id
              (and etaf--render-runtime
                   (etaf--runtime-register-semantic-host
                    etaf--render-runtime name raw-props props path
                    theme-bindings theme-deps property-bindings
                    property-deps property-context-deps base-props
                    (etaf--view-node-token node)))))
         (dolist (child children)
           (setq nodes
                 (nconc nodes
                        (let ((etaf--current-semantic-parent-id
                               (or semantic-id
                                   etaf--current-semantic-parent-id)))
                          (if (and semantic-id (etaf--expr-p child)
                                   (not etaf--rendering-range-p))
                              (let ((result
                                     (etaf--runtime-render-child-range
                                      etaf--render-runtime child
                                      (append path (list index)))))
                                (when (eq (car result) 'range)
                                  (setq range-child-p t))
                                (cdr result))
                            (if (and semantic-id
                                     (etaf--view-node-p child)
                                     (eq (etaf--view-node-name child) 'fragment)
                                     (not etaf--rendering-range-p))
                                (let ((result
                                       (etaf--runtime-render-fragment-range
                                        etaf--render-runtime child
                                        (append path (list index)))))
                                  (setq range-child-p t)
                                  (cdr result))
                              (if (and semantic-id
                                       (etaf--raw-ebox-p child)
                                       (not etaf--rendering-range-p))
                                  (let ((result
                                         (etaf--runtime-render-raw-range
                                          etaf--render-runtime child
                                          (append path (list index)))))
                                    (setq range-child-p t)
                                    (cdr result))
                                (if (and semantic-id
                                     (etaf--slot-projection-p child)
                                     (etaf--slot-projection-range-compatible-p
                                      child)
                                     (not etaf--rendering-range-p))
                                (let ((result
                                       (etaf--runtime-render-slot-range
                                        etaf--render-runtime child
                                        (append path (list index)))))
                                  (setq range-child-p t)
                                  (cdr result))
                                  (etaf--render-value-list
                                   child (append path (list index))))))))))
           (cl-incf index))
         (when semantic-id
           (etaf--runtime-finish-semantic-host
            etaf--render-runtime semantic-id))
         (list (etaf--layout-node name props nodes range-child-p))))
      (_
       (signal 'etaf-renderer-error
               (list (format "Unknown Host reached renderer: %S" name)))))))

(defun etaf--layout-node (name props nodes &optional range-child-p)
  "Build layout NAME with Ebox PROPS around child NODES.
RANGE-CHILD-P records that NODES include nonvisual Range segments."
  (let ((node
         (cond
   ((eq name 'box)
    (ebox-build (append (list 'box) props nodes)))
   ((eq name 'row)
    (if (null props)
        (apply #'ebox-row nodes)
      (ebox-build (append (list 'row) props nodes))))
   ((memq name '(column container stack))
    (if (null props)
        (apply #'ebox-column nodes)
      (ebox-build (append (list 'column) props nodes))))
   ((eq name 'flex)
    (apply #'ebox-flex (append props nodes)))
   ((eq name 'grid)
    (apply #'ebox-grid (append props nodes)))
   (t
     (signal 'etaf-renderer-error
             (list (format "Not a layout Host: %S" name)))))))
    (when range-child-p
      (push node etaf--rendered-range-container-nodes))
    node))

(defun etaf--lower-resolved-semantic-host
    (name props content children range-child-p)
  "Lower resolved NAME, PROPS, CONTENT, and CHILDREN through Renderer.
RANGE-CHILD-P preserves the direct material Range parent."
  (pcase name
    ('text
     (if children
         (etaf--layout-node 'row props children range-child-p)
       (apply #'ebox-create :content content props)))
    ('spacer (apply #'ebox-spacer props))
    ((or 'box 'row 'column 'container 'stack 'flex 'grid)
     (etaf--layout-node name props children range-child-p))
    (_ (signal 'etaf-renderer-error
               (list (format "Semantic Host requires Step4b lowering: %S"
                             name))))))

;;;###autoload
(defun etaf-render (view)
  "Lower normalized VIEW to one Ebox node.

This pure entry supports stateless Components.  Stateful Components require a
Runtime because their setup Scope must have a lifecycle owner."
  (let ((nodes (etaf--render-value-list view '(root))))
    (cond
     ((null nodes) (ebox-spacer))
     ((null (cdr nodes)) (car nodes))
     (t (apply #'ebox-column nodes)))))

;;;###autoload
(defun etaf-mount (buffer-or-name view &optional options)
  "Mount normalized VIEW into BUFFER-OR-NAME and return its buffer.
OPTIONS is forwarded to `etaf-runtime-mount' when the Runtime is loaded."
  (if (fboundp 'etaf-runtime-mount)
      (etaf-runtime-mount buffer-or-name view options)
    (let ((ebox-viewport-width (plist-get options :viewport-width))
          (ebox-viewport-height (plist-get options :viewport-height)))
      (ebox-render-to-buffer buffer-or-name (etaf-render view)))))

(provide 'etaf-renderer)

;;; etaf-renderer.el ends here
