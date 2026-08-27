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

(defvar etaf--theme-host-default-cache
  (make-hash-table :test #'eq :weakness 'key)
  "Theme-value keyed accepted Host default templates.")

(defun etaf--theme-host-defaults (defaults name)
  "Return immutable DEFAULTS accepted by View node NAME."
  (let* ((by-name
          (or (gethash defaults etaf--theme-host-default-cache)
              (let ((table (make-hash-table :test #'eq)))
                (puthash defaults table etaf--theme-host-default-cache)
                table)))
         (missing (make-symbol "etaf-theme-host-defaults-missing"))
         (cached (gethash name by-name missing)))
    (if (not (eq cached missing))
        cached
      (let ((tail defaults) result)
        (while tail
          (let ((key (pop tail))
                (value (pop tail)))
            (when (and (etaf--theme-ebox-property-p key)
                       (ebox-style-property-accepted-p name key))
              (setq result
                    (append result
                            (list key (etaf-theme-token key value)))))))
        (puthash name result by-name)
        result))))

(defun etaf--apply-theme-defaults (node)
  "Apply known inherited Theme defaults to NODE without overriding props.
Unknown Theme keys remain readable through `etaf-theme-value' but are design
tokens, not Ebox Host properties, and therefore are not materialized here."
  (let* ((source (etaf--theme-source))
         (defaults (etaf--theme-source-value source nil nil)))
    (if (null defaults)
        node
      (let* ((name (etaf--view-node-name node))
             (props (copy-sequence
                     (etaf--resolve-property-plist
                      (etaf--view-node-props node))))
             (template (etaf--theme-host-defaults defaults name)))
        (while template
          (let ((key (pop template))
                (value (pop template)))
            (unless (plist-get props key)
              (setq props (etaf--merge-property props key value)))))
        (etaf--view-node-create
         :name name
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

(defun etaf--inline-text-dynamic-p (value)
  "Return non-nil when VALUE contains an inline `expr' update site."
  (cond
   ((etaf--expr-p value) t)
   ((etaf--view-node-p value)
    (cl-some #'etaf--inline-text-dynamic-p
             (etaf--view-node-children value)))
   ((proper-list-p value)
    (cl-some #'etaf--inline-text-dynamic-p value))
   (t nil)))

(defun etaf--ebox-properties (props path &optional site-token)
  "Project ETAF PROPS at PATH to canonical Ebox author facts."
  (let* ((source-props (etaf--resolve-property-plist props))
         (props (copy-sequence source-props))
         ebox-props)
    (while props
      (let ((key (pop props))
            (value (pop props)))
        (cond
         ((memq key '(:face :surface-properties))
          (signal 'etaf-renderer-error
                  (list (format
                         "%S is not a canonical ETAF property" key))))
         ((eq key :content)
          (signal 'etaf-renderer-error
                  (list "Use View children for content, not :content")))
         ((or (and (memq key etaf--semantic-props)
                   (not (memq key '(:class :id))))
              (etaf--event-property-p key)
              (eq key :styles))
          nil)
         (t
          ;; Component APIs pass optional properties as nil.  At the resolved
          ;; author boundary nil means "unspecified"; canonical Ebox defaults
          ;; own the initial value and never receive a synthetic declaration.
          (when value
            (push key ebox-props)
            (push value ebox-props))))))
    (setq ebox-props (nreverse ebox-props))
    (setq ebox-props
          (etaf--merge-property
           ebox-props :source-handle
           (etaf--generated-host-ref source-props path site-token)))
    ebox-props))

(defconst etaf--ebox-source-fields
  '(:source-handle :key :class :id)
  "Canonical Ebox source metadata forwarded by ETAF Renderer.")

(defvar etaf--ebox-declaration-cache (make-hash-table :test #'equal)
  "Bounded canonical declaration cache for normalized ETAF author props.")

(defconst etaf--ebox-declaration-cache-limit 512
  "Maximum canonical ETAF declaration entries retained across renders.")

(defvar etaf--ebox-layout-config-cache (make-hash-table :test #'equal)
  "Bounded typed LayoutConfig cache for normalized ETAF Box forms.")

(defconst etaf--ebox-layout-config-cache-limit 128
  "Maximum typed LayoutConfig entries retained across renders.")

(defun etaf--ebox-keep-properties (props names)
  "Return PROPS whose keys occur in NAMES."
  (cl-loop for (key value) on props by #'cddr
           when (memq key names)
           append (list key value)))

(defun etaf--ebox-remove-properties (props names)
  "Return PROPS without keys in NAMES."
  (cl-loop for (key value) on props by #'cddr
           unless (memq key names)
           append (list key value)))

(defun etaf--ebox-declarations (tag props)
  "Compile TAG style declarations from canonical ETAF PROPS once."
  (let* ((style-props
          (etaf--ebox-remove-properties
           props
           (append etaf--ebox-source-fields
                   (unless (eq tag 'text) '(:outer))
                   (when (memq tag '(row column))
                     '(:item-gap :cross-align)))))
         (key (cons tag style-props))
         (missing (make-symbol "etaf-ebox-declarations-missing"))
         (cached (gethash key etaf--ebox-declaration-cache missing)))
    (if (not (eq cached missing))
        cached
      (let ((compiled (ebox-style-compile-form tag style-props)))
        (when (>= (hash-table-count etaf--ebox-declaration-cache)
                  etaf--ebox-declaration-cache-limit)
          (clrhash etaf--ebox-declaration-cache))
        (puthash (copy-tree key) compiled etaf--ebox-declaration-cache)
        compiled))))

(defun etaf--ebox-layout-config (tag props declarations)
  "Return TAG LayoutConfig from PROPS and normalized DECLARATIONS."
  (let* ((layout-props
          (if (memq tag '(row column))
              (etaf--ebox-keep-properties props '(:item-gap :cross-align))
            (ebox-style-declaration-properties
             declarations
             (lambda (property)
               (memq (plist-get property :name)
                     (ebox-layout-config-property-names tag))))))
         (key (cons tag layout-props))
         (config (gethash key etaf--ebox-layout-config-cache)))
    (or config
        (let ((created (ebox-layout-config-for-form tag layout-props)))
          (when (>= (hash-table-count etaf--ebox-layout-config-cache)
                    etaf--ebox-layout-config-cache-limit)
            (clrhash etaf--ebox-layout-config-cache))
          (puthash (copy-tree key) created etaf--ebox-layout-config-cache)
          created))))

(defun etaf--ebox-text-node (value props)
  "Return one typed Ebox TextNode for string VALUE and canonical PROPS."
  (unless (stringp value)
    (signal 'etaf-renderer-error
            (list (format "Text payload must resolve to a string: %S" value))))
  (let ((declarations (etaf--ebox-declarations 'text props)))
    (apply #'ebox-text-create
           (append (list :value value :declarations declarations)
                   (etaf--ebox-keep-properties
                    props etaf--ebox-source-fields)))))

(defun etaf--ebox-box-node (tag props children)
  "Return one typed Ebox BoxNode TAG over canonical CHILDREN."
  (let* ((declarations (etaf--ebox-declarations tag props))
         (layout (etaf--ebox-layout-config tag props declarations))
         (outer (if (plist-member props :outer)
                    (plist-get props :outer)
                  'block)))
    (apply #'ebox-box-create
           (append
            (list :layout layout :outer outer :children children
                  :declarations declarations)
            (etaf--ebox-keep-properties props etaf--ebox-source-fields)))))

(defun etaf--ebox-forest-root (nodes source-handle)
  "Return one canonical backend root for ordered forest NODES.
SOURCE-HANDLE identifies only a backend root introduced for an empty or
multi-root forest; a single material root is returned unchanged."
  (cond
   ((null nodes)
    (etaf--ebox-box-node
     'box (list :source-handle source-handle) nil))
   ((null (cdr nodes)) (car nodes))
   (t
    (etaf--ebox-box-node
     'column (list :source-handle source-handle) nodes))))

(defun etaf--flatten-view-value (value)
  "Flatten VALUE through transparent `expr' and sequence values."
  (cond
   ((null value) nil)
   ((or (stringp value) (etaf--view-node-p value)
        (etaf--component-call-p value) (etaf--slot-projection-p value))
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
               (list
                (etaf--ebox-text-node
                 item (etaf--ebox-properties nil item-path))))
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
                    (etaf--inline-text-dynamic-p children)
                    (etaf--inline-text-structural-p children)
                    (etaf--runtime-render-inline-content
                     etaf--render-runtime semantic-id children child-path)))
              (flat (unless runtime-inline
                      (cl-mapcan #'etaf--flatten-view-value children)))
              (inline (if runtime-inline
                          (cons t (car runtime-inline))
                        (etaf--inline-text-content flat))))
         (when semantic-id
           (etaf--runtime-finish-semantic-host
           etaf--render-runtime semantic-id
            (and (car inline) (cdr inline))
            (and runtime-inline (cadr runtime-inline))))
         (if (car inline)
             (list (etaf--ebox-text-node (cdr inline) props))
           (signal 'etaf-renderer-error
                   (list "Text payload must resolve to one string")))))
      ('fragment
       (etaf--render-value-list children (append path (list :fragment))))
      ((or 'box 'row 'column 'flex 'grid)
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
                                   child (append path (list index)))))))))
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
  (unless (memq name '(box row column flex grid))
    (signal 'etaf-renderer-error
            (list (format "Not a Box form: %S" name))))
  (let ((node (etaf--ebox-box-node name props nodes)))
    (when range-child-p
      (push node etaf--rendered-range-container-nodes))
    node))

(defun etaf--lower-resolved-semantic-host
    (name props content children range-child-p)
  "Lower resolved NAME, PROPS, CONTENT, and CHILDREN through Renderer.
RANGE-CHILD-P preserves the direct material Range parent."
  (pcase name
    ('text
     (when children
       (signal 'etaf-renderer-error
               (list "Text cannot contain material child nodes")))
     (etaf--ebox-text-node content props))
    ((or 'box 'row 'column 'flex 'grid)
     (etaf--layout-node name props children range-child-p))
    (_ (signal 'etaf-renderer-error
               (list (format "Semantic Host requires Step4b lowering: %S"
                             name))))))

;;;###autoload
(defun etaf-render (view)
  "Lower normalized VIEW to one Ebox node.

This pure entry supports stateless Components.  Stateful Components require a
  Runtime because their setup Scope must have a lifecycle owner."
  (etaf--ebox-forest-root
   (etaf--render-value-list view '(root)) '(etaf-root pure)))

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
