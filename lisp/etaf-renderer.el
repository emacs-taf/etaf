;;; etaf-renderer.el --- ETAF to Ebox rendering bridge -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This is ETAF's only Ebox boundary.  It lowers normalized View values and
;; delegates measurement, layout, painting, and publication to Ebox.  Runtime
;; owns retained Component instances and calls the renderer through the small
;; `etaf--render-value-list' port below.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox)
(require 'etaf-view)
(require 'etaf-component)
(require 'etaf-context)
(require 'etaf-behavior)
(require 'etaf-render-port)

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

(defun etaf--behavior-source-p (value)
  "Return non-nil when VALUE has the public `:use' source grammar."
  (or (null value)
      (symbolp value)
      (etaf-behavior-spec-p value)
      (and (proper-list-p value)
           (cl-every (lambda (entry)
                       (or (symbolp entry) (etaf-behavior-spec-p entry)))
                     value))))

(defun etaf--validate-semantic-properties (props)
  "Return PROPS after validating ETAF Runtime-owned metadata values."
  (cl-loop for (property value) on props by #'cddr
           do
           (cond
            ((eq property :ref)
             (unless (or (null value) (symbolp value) (functionp value))
               (signal 'etaf-renderer-error
                       (list ":ref must be a symbol, function, or nil"))))
            ((eq property :role)
             (unless (or (null value) (symbolp value) (stringp value))
               (signal 'etaf-renderer-error
                       (list ":role must be a symbol, string, or nil"))))
            ((etaf--aria-property-p property)
             (unless (or (null value) (stringp value) (numberp value)
                         (symbolp value))
               (signal 'etaf-renderer-error
                       (list (format "%S has an invalid semantic value"
                                     property)))))
            ((etaf--event-property-p property)
             (unless (or (null value) (functionp value))
               (signal 'etaf-renderer-error
                       (list (format "%S must be a function or nil"
                                     property)))))
            ((eq property :disabled)
             (unless (memq value '(nil t))
               (signal 'etaf-renderer-error
                       (list ":disabled must be boolean"))))
            ((eq property :tab-index)
             (unless (or (null value) (integerp value))
               (signal 'etaf-renderer-error
                       (list ":tab-index must be an integer or nil"))))
            ((eq property :use)
             (unless (etaf--behavior-source-p value)
               (signal 'etaf-renderer-error
                       (list ":use must be a Behavior symbol, spec, or proper list"))))))
  props)

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

(defvar etaf--render-parent-path nil
  "Structural path of the current retained semantic parent.")

(defvar etaf--render-site-counts nil
  "Occurrence counts distinguishing reused compiled sites under each parent.")

(defun etaf--render-site-token (token)
  "Qualify repeated TOKEN occurrences within their mounted semantic parent."
  (if (or (null token) (null etaf--render-site-counts))
      token
    (let* ((key (list etaf--current-semantic-parent-id token))
           (index (gethash key etaf--render-site-counts 0)))
      (puthash key (1+ index) etaf--render-site-counts)
      (if (zerop index) token (list :site token :occurrence index)))))

(defvar etaf--ebox-source-builder nil
  "Source builder owned by the current ETAF lowering boundary.")

(defun etaf--ebox-import-input (input)
  "Import canonical INPUT into the current lowering and return its nodes."
  (unless etaf--ebox-source-builder
    (signal 'etaf-renderer-error
            (list "Canonical Ebox input escaped its lowering boundary")))
  (ebox-canonical-input-import-roots
   input (ebox-canonical-input-roots input) etaf--ebox-source-builder))

(defun etaf--ebox-input-for-nodes (nodes)
  "Snapshot current source facts for canonical forest NODES."
  (unless etaf--ebox-source-builder
    (signal 'etaf-renderer-error
            (list "Canonical Ebox nodes have no lowering source builder")))
  (ebox-canonical-input-create
   nodes
   (ebox-tree-source-builder-snapshot etaf--ebox-source-builder nodes)))

(defun etaf--generated-host-ref (props path &optional site-token)
  "Return PROPS' explicit Host reference or one generated for PATH.
SITE-TOKEN replaces PATH as the generated call-site identity when non-nil."
  (or (plist-get props :ref)
      (let ((site (or (and (plist-get props :key)
                           (list :key (plist-get props :key)))
                      site-token (copy-sequence path))))
        (list 'etaf-host
              (cond
               (etaf--render-runtime
                (list :parent etaf--current-semantic-parent-id :site site))
               (t
                (list :path (copy-sequence path) :site site)))))))

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
      (dolist (rule styles)
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
             (template (etaf--theme-host-defaults defaults name))
             (present (make-hash-table :test #'eq)))
        (cl-loop for (key value) on props by #'cddr
                 when value do
                 (puthash (etaf--property-domain-key key) t present))
        (while template
          (let ((key (pop template))
                (value (pop template)))
            (unless (gethash (etaf--property-domain-key key) present)
              (setq props (etaf--merge-property props key value))
              (when value
                (puthash (etaf--property-domain-key key) t present)))))
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
The immutable Ebox schema registry is the sole shared property vocabulary;
custom Theme tokens remain Context data and are never copied onto Hosts."
  (and (keywordp key)
       (ebox-style-schema-id key)))

(defun etaf--inline-text-content (value)
  "Return `(SUCCESS . STRING)' for inline-compatible text VALUE.

Only strings and `expr' values that resolve to strings are compatible.  View
structure must use the ordinary typed lowering path."
  (cond
   ((stringp value) (cons t value))
   ((and (etaf--expr-p value)
         (eq (etaf--expr-kind value) 'interpolation))
    (let ((result (funcall (etaf--expr-thunk value))))
      (if (stringp result) (cons t result) (cons nil nil))))
   ((etaf--view-node-p value) (cons nil nil))
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
   ((or (null value) (stringp value)
        (and (etaf--expr-p value)
             (eq (etaf--expr-kind value) 'interpolation))) t)
   ((etaf--view-node-p value) nil)
    ((proper-list-p value)
     (cl-every #'etaf--inline-text-structural-p value))
    (t nil)))

(defun etaf--inline-text-dynamic-p (value)
  "Return non-nil when VALUE contains an inline `expr' update site."
  (cond
   ((and (etaf--expr-p value)
         (eq (etaf--expr-kind value) 'interpolation)) t)
   ((etaf--view-node-p value)
    (cl-some #'etaf--inline-text-dynamic-p
             (etaf--view-node-children value)))
   ((proper-list-p value)
    (cl-some #'etaf--inline-text-dynamic-p value))
   (t nil)))

(defun etaf--ebox-properties (props path &optional site-token)
  "Project ETAF PROPS at PATH to canonical Ebox author facts.
SITE-TOKEN supplies the stable generated Host identity when non-nil."
  (let* ((source-props (etaf--resolve-property-plist props))
         (_validated (etaf--validate-semantic-properties source-props))
         (props (copy-sequence source-props))
         ebox-props)
    (while props
      (let ((key (pop props))
            (value (pop props)))
        (cond
         ((memq key '(:face :surface-properties :selector-attributes :selector-state))
          (signal 'etaf-renderer-error
                  (list (format
                         "%S is not a canonical ETAF property" key))))
         ((eq key :content)
          (signal 'etaf-renderer-error
                  (list "Use View children for content, not :content")))
         ((or (and (etaf--semantic-property-p key)
                   (not (memq key '(:class :id))))
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
    (let ((attributes
           (cl-loop for (key value) on source-props by #'cddr
                    when (or (and (eq key :role) value)
                             (etaf--aria-property-p key))
                    collect (cons key value))))
      (when attributes
        (setq ebox-props
              (etaf--merge-property ebox-props :selector-attributes attributes))))
    (when (plist-get source-props :disabled)
      (setq ebox-props
            (etaf--merge-property ebox-props :selector-state '(disabled))))
    (setq ebox-props
          (etaf--merge-property
           ebox-props :source-identity
           (etaf--generated-host-ref source-props path site-token)))
    ebox-props))

(defconst etaf--ebox-source-fields
  '(:source-identity :key :class :id :selector-attributes :selector-state)
  "ETAF source facts compiled into one opaque Ebox source handle.")

(defvar etaf--ebox-declaration-cache (make-hash-table :test #'equal)
  "Bounded canonical declaration cache for normalized ETAF author props.")

(defconst etaf--ebox-declaration-cache-limit 512
  "Maximum canonical ETAF declaration entries retained across renders.")

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
           etaf--ebox-source-fields))
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

(defun etaf--ebox-text-node (value props)
  "Return one typed Ebox TextNode for string VALUE and canonical PROPS."
  (unless (stringp value)
    (signal 'etaf-renderer-error
            (list (format "Text payload must resolve to a string: %S" value))))
  (unless (ebox-source-builder-p etaf--ebox-source-builder)
    (signal 'etaf-renderer-error
            (list "ETAF Text lowering requires one source builder")))
  (let* ((declarations (etaf--ebox-declarations 'text props))
         (source-handle
          (ebox-source-builder-bind
           etaf--ebox-source-builder
           :identity (plist-get props :source-identity)
           :key (plist-get props :key)
           :id (plist-get props :id)
           :class (plist-get props :class)
           :selector-attributes (plist-get props :selector-attributes)
           :selector-state (plist-get props :selector-state)
           :declarations declarations
           :provenance '(:adapter etaf-renderer :tag text))))
    (ebox-text-create
     :value value
     :owned-facts
     (ebox-canonical-facts-from-declarations 'text declarations)
     :source-handle source-handle)))

(defun etaf--ebox-box-node (tag props children)
  "Return one typed Ebox BoxNode TAG with PROPS over canonical CHILDREN."
  (unless (ebox-source-builder-p etaf--ebox-source-builder)
    (signal 'etaf-renderer-error
            (list "ETAF Box lowering requires one source builder")))
  (let* ((declarations (etaf--ebox-declarations tag props))
         (configuration (ebox-canonical-box-configuration tag declarations))
         (source-handle
          (ebox-source-builder-bind
           etaf--ebox-source-builder
           :identity (plist-get props :source-identity)
           :key (plist-get props :key)
           :id (plist-get props :id)
           :class (plist-get props :class)
           :selector-attributes (plist-get props :selector-attributes)
           :selector-state (plist-get props :selector-state)
           :declarations declarations
           :provenance (list :adapter 'etaf-renderer :tag tag))))
    (ebox-box-create
     :layout (plist-get configuration :layout)
     :outer (plist-get configuration :outer) :children children
     :source-builder etaf--ebox-source-builder
     :owned-facts (ebox-canonical-facts-from-declarations tag declarations)
     :source-handle source-handle)))

(defun etaf--ebox-forest-root (nodes source-identity)
  "Return one canonical backend root for ordered forest NODES.
SOURCE-IDENTITY belongs only to a backend root introduced for an empty or
multi-root forest; a single material root is returned unchanged."
  (cond
   ((null nodes)
    (etaf--ebox-box-node
     'box (list :source-identity source-identity) nil))
   ((null (cdr nodes))
    (car nodes))
   (t
    (etaf--ebox-box-node
     'column (list :source-identity source-identity) nodes))))

(defun etaf--flatten-view-value (value)
  "Flatten VALUE through transparent `expr' and sequence values."
  (cond
   ((null value) nil)
   ((or (stringp value) (etaf--view-node-p value)
        (etaf--component-call-p value) (etaf--slot-projection-p value))
    (list value))
   ((etaf--expr-p value)
    (pcase (etaf--expr-kind value)
      ('interpolation
       (let ((resolved (funcall (etaf--expr-thunk value))))
         (cond ((null resolved) nil)
               ((stringp resolved) (list resolved))
               ;; Text Hosts validate interpolation through
               ;; `etaf--inline-text-content'.  At a structural boundary the
               ;; same evaluated value may be a dynamically produced View
               ;; forest (notably a transparent Component's fragment).
               (t (etaf--flatten-view-value resolved)))))
      ('branch
       (etaf--flatten-view-value (funcall (etaf--expr-thunk value))))
      ('keyed-list
       (let ((snapshot (etaf--keyed-program-snapshot value)))
         (etaf--flatten-view-value
          (etaf--keyed-program-outputs value snapshot))))
      (_ (signal 'etaf-renderer-error
                 (list (format "Unknown View program: %S" value))))))
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
         (render (etaf--component-spec-render spec))
         (props (car (etaf--component-resolve-defaults
                      spec (etaf--resolve-property-plist
                            (etaf--component-business-props call)) nil)))
         (attrs (etaf--resolve-property-plist
                 (etaf--component-call-attrs call))))
    (when (etaf--component-spec-setup spec)
      (signal 'etaf-renderer-error
              (list "Stateful Component requires `etaf-mount'")))
    (let ((etaf--current-component-props props)
          (etaf--current-component-slots
           (etaf--component-call-slots call))
          (etaf--component-phase 'render))
      (let ((etaf--render-parent-style-stack etaf--render-style-stack)
            (etaf--render-style-stack
             (list (cons (etaf--component-spec-styles spec)
                         (append path (list :component
                                            (etaf--component-spec-name spec)))))))
        (etaf--render-value-list
         (etaf--apply-component-attrs
          (etaf--validate-component-render-result
           (funcall render props (etaf--component-call-slots call))
           (etaf--component-spec-name spec))
          attrs (etaf--component-spec-name spec))
         (append path (list :component (etaf--component-spec-name spec))))))))

(defun etaf--render-value-list (value path)
  "Render VALUE at structural PATH into a list of Ebox nodes."
  (let* ((items (etaf--flatten-view-value value))
         (multiple-p (or (proper-list-p value) (> (length items) 1)))
         (etaf--render-site-counts
          (or etaf--render-site-counts (make-hash-table :test #'equal)))
         (keys (make-hash-table :test #'equal)))
    ;; Validate the entire sibling set before any Component setup runs.
    (dolist (item items)
      (let* ((props (cond ((etaf--view-node-p item)
                          (etaf--view-node-props item))
                         ((etaf--component-call-p item)
                          (etaf--component-call-props item))))
             (key (etaf--resolve-property-value (plist-get props :key))))
        (when key
          (when (gethash key keys)
            (signal (if etaf--render-runtime
                        'etaf-runtime-error 'etaf-renderer-error)
                    (list (format "View at %S has duplicate sibling key: %S"
                                  path key))))
          (puthash key t keys))))
    (cl-loop for item in items
             for index from 0
             for item-path = (if multiple-p (append path (list index)) path)
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
                     (cond
                      ((eq (car-safe result) 'component-output-material)
                       (etaf--ebox-import-input (cdr result)))
                      ((eq (car-safe result) 'component-output-range)
                       (etaf--ebox-import-input (cdr result)))
                      ((eq (car-safe result) 'component-output-anchor)
                       (list
                        (apply #'ebox-child-range
                               (nth 1 result)
                               (etaf--ebox-import-input (nth 2 result)))))
                      (t
                       (signal 'etaf-renderer-error
                               (list "Runtime returned invalid Component output")))))
                 (etaf--render-component-call-pure item item-path)))
              ((etaf--slot-projection-p item)
               (etaf--render-slot-projection item item-path))
              (t
               (signal 'etaf-renderer-error
                       (list (format "Unresolved View item: %S" item))))))))

(defun etaf--render-node (node path)
  "Render normalized Host NODE at structural PATH."
  (let* ((node (let ((copy (copy-sequence node)))
                 (setf (etaf--view-node-token copy)
                       (etaf--render-site-token (etaf--view-node-token node)))
                 copy))
         (node (if (and etaf--render-runtime
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
              (flat (unless runtime-inline children))
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
             (etaf--render-parent-path path)
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
                          (if (and semantic-id
                                   ;; Code-mode may carry a retained
                                   ;; structural Expr through `etaf-node'.
                                   ;; Both compiler-owned programs and these
                                   ;; validated Expr values use the same
                                   ;; direct Range lowering boundary.
                                   (etaf--expr-p child))
                              (let ((result
                                     (etaf--runtime-render-child-range
                                      etaf--render-runtime child
                                      (append path (list index)))))
                                (when (eq (car result) 'range)
                                  (setq range-child-p t))
                                (cdr result))
                            (if (and semantic-id
                                     (etaf--view-node-p child)
                                     (eq (etaf--view-node-name child) 'fragment))
                                (let ((result
                                       (etaf--runtime-render-fragment-range
                                        etaf--render-runtime child
                                        (append path (list index)))))
                                  (setq range-child-p t)
                                  (cdr result))
                              (if (and semantic-id
                                     (etaf--slot-projection-p child)
                                     (etaf--slot-projection-range-compatible-p
                                      child))
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
               (list (format "Expected text, box, row, column, flex, or grid Host; received %S"
                             name))))))

;;;###autoload
(defun etaf-render (view)
  "Lower normalized VIEW to one atomic canonical Ebox input.

This pure entry supports stateless Components.  Stateful Components require a
  Runtime because their setup Scope must have a lifecycle owner."
  (let ((builder (ebox-source-builder-create)))
    (let* ((etaf--ebox-source-builder builder)
           (root
            (etaf--ebox-forest-root
             (etaf--render-value-list view '(root)) '(etaf-root pure))))
      (ebox-canonical-input-create
       (list root) (ebox-source-builder-finish builder)))))

;;;###autoload
(defun etaf-mount (buffer-or-name view &optional options)
  "Mount normalized VIEW into BUFFER-OR-NAME and return its buffer.
OPTIONS is forwarded to `etaf-runtime-mount' when the Runtime is loaded."
  (if (fboundp 'etaf-runtime-mount)
      (etaf-runtime-mount buffer-or-name view options)
    (let ((ebox-viewport-width (plist-get options :viewport-width))
          (ebox-viewport-height (plist-get options :viewport-height)))
      (let ((input (etaf-render view))
            (buffer (get-buffer-create buffer-or-name)))
        (etaf-render-port-initial buffer input #'ignore #'ignore)
        buffer))))

(provide 'etaf-renderer)

;;; etaf-renderer.el ends here
