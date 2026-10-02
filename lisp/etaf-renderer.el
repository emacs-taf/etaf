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
                           &optional theme-deps
                           property-bindings property-deps
                           property-context-deps base-props site-token style-root-p))
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
(declare-function etaf-runtime-scope "etaf-runtime" (runtime))
(declare-function etaf--host-property-binding-property "etaf-runtime" (binding))
(declare-function etaf--component-instance-scope "etaf-runtime" (instance))

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

(defvar etaf--render-style-owners nil
  "Component style scopes active during View lowering.")

(defvar etaf--render-parent-style-owners nil
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

(cl-defstruct (etaf--style-owner (:constructor etaf--style-owner-create))
  "Immutable Component rule input and shared membership identity."
  scope rules)

(defvar etaf--render-enclosing-style-scopes nil
  "Component scopes of physical ancestors during recursive lowering.")

(defvar etaf--component-style-scope-cache (make-hash-table :test #'equal)
  "Bounded cache of immutable Component rule revisions.")

(defun etaf--component-style-root-p ()
  "Return whether this Host is a topmost member of its Component scope."
  (when-let* ((owner (car etaf--render-style-owners)))
    (let ((scope (etaf--style-owner-scope owner)))
      (not (or (memq scope etaf--render-enclosing-style-scopes)
               (and etaf--render-runtime
                    (etaf--runtime-style-ancestor-p
                     etaf--render-runtime etaf--current-semantic-parent-id scope)))))))

(defun etaf--host-component-style-properties (props root-p)
  "Return canonical PROPS and rule dependencies, marking ROOT-P ownership."
  (let ((owner (car etaf--render-style-owners)) deps)
    (when owner
      (let ((scope (etaf--style-owner-scope owner)) revision)
        (when root-p
          (let* ((rules
                  (mapcar
                   (lambda (rule)
                     (let ((resolved (etaf--resolve-theme-property-plist (cdr rule))))
                       (setq deps (append deps (cadr resolved)))
                       (cons (car rule) (car resolved))))
                   (etaf--style-owner-rules owner)))
                 (key (list scope rules)))
            (setq revision
                  (or (gethash key etaf--component-style-scope-cache)
                      (let ((next (ebox-style-scope-with-rules scope rules)))
                        (when (>= (hash-table-count etaf--component-style-scope-cache) 512)
                          (clrhash etaf--component-style-scope-cache))
                        (puthash (copy-tree key) next etaf--component-style-scope-cache)
                        next)))))
        (setq props (etaf--merge-property props :ecss-scopes
                                          (append (plist-get props :ecss-scopes) (list scope))))
        (when revision
          (setq props (etaf--merge-property props :ecss-scope-roots
                                            (append (plist-get props :ecss-scope-roots)
                                                    (list revision)))))))
    (list props (delete-dups deps))))

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

(defvar etaf--theme-scope-cache (make-hash-table :test #'equal)
  "Bounded cache of immutable UA default scopes.")

(defvar etaf--theme-projection-caches (make-hash-table :test #'eq :weakness 'key)
  "Scope-owned derived Theme sources, keyed by source and consumed value.
Their effects stop with the consuming Component, or the Runtime for root Hosts.
The original Theme remains authoritative; these are ordinary lazy computeds.")

(defun etaf--theme-projection (source selector)
  "Return the retained projection of Theme SOURCE described by SELECTOR.
SELECTOR is `(defaults NAME)' or `(token TOKEN)'.  A nil result means SOURCE
is static, its transform requires Context, or there is no mounted Runtime."
  (when (and etaf--render-runtime
             (or (etaf-ref-p source) (etaf-computed-p source)))
    (let* ((scope (if etaf--current-component-instance
                      (etaf--component-instance-scope etaf--current-component-instance)
                    (etaf-runtime-scope etaf--render-runtime)))
           (cache (or (gethash scope etaf--theme-projection-caches)
                      (let ((etaf--render-phase-p nil)
                            (etaf--active-scope scope))
                        (etaf-on-scope-dispose
                         (lambda () (remhash scope etaf--theme-projection-caches)))
                        (puthash scope (make-hash-table :test #'eq)
                                 etaf--theme-projection-caches))))
           (projections (or (gethash source cache)
                            (puthash source (make-hash-table :test #'equal) cache))))
      (let ((entry (gethash selector projections)))
        (unless entry
          (setq entry (cons nil nil))
          (let ((etaf--render-phase-p nil)
                (etaf--active-scope scope))
            (setcar
             entry
             (etaf-computed
              (lambda ()
                (let* ((recorder etaf--context-inject-recorder)
                       (etaf--context-inject-recorder
                        (lambda (frame key)
                          ;; A contextual transform belongs to its consumer,
                          ;; so it cannot share a source-only cached result.
                          (setcdr entry t)
                          (when recorder (funcall recorder frame key))))
                       (theme (etaf--theme-source-value source nil t)))
                  (pcase (car selector)
                    ('defaults (etaf--theme-host-defaults theme (cadr selector)))
                    ('token (etaf--theme-token-resolve-from-theme
                             (cadr selector) theme)))))
              :test #'equal :name 'theme-projection)))
          (puthash (copy-tree selector) entry projections))
        (unless (cdr entry) (car entry))))))

(defun etaf--resolve-host-theme (name props identity &optional property-bindings)
  "Return resolved PROPS, dependencies and a UA scope for NAME at IDENTITY.
PROPERTY-BINDINGS identify dynamic tokens requiring a whole-Theme guard."
  (let* ((source (etaf--theme-source))
         (defaults-source (etaf--theme-projection source (list 'defaults name)))
         (defaults (if defaults-source
                       (let ((etaf--tracking-enabled-p nil))
                         (etaf-value defaults-source))
                     (etaf--theme-host-defaults
                      (etaf--theme-source-value source nil nil) name)))
         (inline (etaf--resolve-theme-property-plist
                  props (mapcar #'etaf--host-property-binding-property
                                property-bindings)))
         (theme (etaf--resolve-theme-property-plist
                 defaults))
         (declarations (cl-loop for (key value) on (car theme) by #'cddr
                                when value append (list key value)))
         (scope-key (list identity declarations))
         (scope
          (when declarations
            (or (gethash scope-key etaf--theme-scope-cache)
                (let ((scope (ebox-style-scope-create
                              (list (cons "&" declarations)) :origin 'ua)))
                  (when (>= (hash-table-count etaf--theme-scope-cache) 512)
                    (clrhash etaf--theme-scope-cache))
                  (puthash (copy-tree scope-key) scope etaf--theme-scope-cache)
                  scope)))))
    (list (car inline)
          (delete-dups (append (nth 1 inline) (nth 1 theme)
                              (and (or (etaf-ref-p source) (etaf-computed-p source))
                                   (list (or defaults-source source))))) scope)))

(defun etaf--host-theme-properties (props scope)
  "Attach default SCOPE to canonical backend PROPS."
  (if (null scope) props
    (append props (list :ecss-scopes (list scope) :ecss-scope-roots (list scope)))))

(defun etaf--resolve-theme-property-plist (props &optional dynamic-properties)
  "Return resolved PROPS and reactive Theme dependencies.
DYNAMIC-PROPERTIES retain their Theme source across prepared token switches."
  (let ((source (etaf--theme-source)) resolved deps)
    (while props
      (let ((property (pop props))
            (value (pop props)))
        (if (etaf-theme-token-p value)
            (let* ((projection
                    (unless (memq property dynamic-properties)
                      (etaf--theme-projection source (list 'token value))))
                   (resolved-value
                    (if projection
                        (let ((etaf--tracking-enabled-p nil)) (etaf-value projection))
                      (etaf--theme-token-resolve-from-source value source))))
              (when resolved-value
                (ebox-style-compile-declarations (list property resolved-value) t))
              (push property resolved)
              (push (if etaf--render-runtime
                        (etaf--runtime-theme-paint-value
                         etaf--render-runtime property value source
                         resolved-value)
                      resolved-value)
                    resolved)
              (when (or (etaf-ref-p source) (etaf-computed-p source))
                ;; A prepared dynamic token can switch without rebuilding its
                ;; dependency vector.  Retain its whole-source guard until an
                ;; ordinary publication rebinds the selected token.
                (cl-pushnew (or projection source) deps :test #'eq)))
          (push property resolved)
          (push value resolved))))
    (list (nreverse resolved) (nreverse deps))))

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

(defun etaf--interaction-boundary-p (props)
  "Return non-nil when resolved PROPS describe an interaction boundary.
Disabled and callbackless controls still own their hit area.  Ordinary text
with only a reference or accessibility label remains part of its parent."
  (or (functionp (plist-get props :on-press))
      (functionp (plist-get props :on-drag))
      (plist-get props :disabled)
      (numberp (plist-get props :tab-index))
      (member (let ((role (plist-get props :role)))
                (if (symbolp role) (symbol-name role) role))
              '("button" "checkbox" "combobox" "link" "menuitem" "option"
                "radio" "slider" "spinbutton" "switch" "tab" "textbox"
                "treeitem"))))

(defun etaf--ebox-properties (props path &optional site-token runtime host-ref)
  "Project ETAF PROPS at PATH to canonical Ebox author facts.
SITE-TOKEN supplies the generated Host identity when non-nil.
HOST-REF preserves an already allocated identity during retained updates."
  (let* ((source-props (etaf--resolve-property-plist props))
         (_validated (etaf--validate-semantic-properties source-props))
         (props (copy-sequence source-props))
         ebox-props)
    (while props
      (let ((key (pop props))
            (value (pop props)))
        (cond
         ((memq key '(:face :surface-properties :selector-attributes :selector-state
                        :ecss-scopes :ecss-scope-roots :interactions))
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
    (setq ebox-props
          (etaf--merge-property
           ebox-props :source-identity
           (or host-ref (etaf--generated-host-ref source-props path site-token))))
    (when (etaf--interaction-boundary-p source-props)
      (let* ((runtime (or runtime etaf--render-runtime))
             (press (functionp (plist-get source-props :on-press)))
             (drag (functionp (plist-get source-props :on-drag)))
             (map (and runtime (or press drag) (not (plist-get source-props :disabled))
                       (etaf--runtime-interaction-keymap
                        runtime (plist-get ebox-props :source-identity) press drag
                        (plist-get source-props :drag-lock-modifier)))))
        (setq ebox-props
              (etaf--merge-property
               ebox-props :interactions
               (append
                (list :keymap map :tab-index (plist-get source-props :tab-index)
                      :disabled (and (plist-get source-props :disabled) t))
                ;; A clickable Host advertises itself: every press or drag
                ;; boundary carries the hand pointer.  An explicit :pointer,
                ;; including an explicit nil, always wins.
                (when (and (not (plist-get source-props :disabled))
                           (not (plist-member source-props :pointer)))
                  (when (or press drag)
                    (list :pointer 'hand))))))))
    ;; Native affordances belong to Ebox even on ordinary, non-activating text.
    ;; Preserve explicit nil so a child can stop its parent's inherited paint
    ;; or help without creating an activation boundary.
    (dolist (property '(:help-echo :pointer :hover-style :hover-content
                        :drag-lock-modifier :hover-group))
      (when (plist-member source-props property)
        (setq ebox-props
              (etaf--merge-property
               ebox-props :interactions
               (append (plist-get ebox-props :interactions)
                       (list property (plist-get source-props property)))))))
    ebox-props))

(defconst etaf--ebox-source-fields
  '(:source-identity :key :class :id :selector-attributes
    :ecss-scopes :ecss-scope-roots :interactions)
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
           :class (etaf--class-tokens (plist-get props :class))
           :selector-attributes (plist-get props :selector-attributes)
           :ecss-scopes (plist-get props :ecss-scopes)
           :ecss-scope-roots (plist-get props :ecss-scope-roots)
           :declarations declarations
           :interactions (plist-get props :interactions)
           :provenance '(:adapter etaf-renderer :tag text))))
    (ebox-text-create
     :value value
     :owned-facts
     (ebox-canonical-facts-from-declarations 'text declarations (plist-get props :interactions))
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
           :class (etaf--class-tokens (plist-get props :class))
           :selector-attributes (plist-get props :selector-attributes)
           :ecss-scopes (plist-get props :ecss-scopes)
           :ecss-scope-roots (plist-get props :ecss-scope-roots)
           :declarations declarations
           :interactions (plist-get props :interactions)
           :provenance (list :adapter 'etaf-renderer :tag tag))))
    (ebox-box-create
     :layout (plist-get configuration :layout)
     :outer (plist-get configuration :outer) :children children
     :source-builder etaf--ebox-source-builder
     :owned-facts (ebox-canonical-facts-from-declarations tag declarations (plist-get props :interactions))
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
         (captured-p (etaf--slot-projection-captured-p projection))
         (entry (if captured-p (cons name (etaf--slot-projection-content projection))
                  (assq name slots)))
         (content (and entry (cdr entry)))
         (children (if (etaf--slot-content-p content)
                       (etaf--slot-content-children content)
                     content))
         (owner-id (and (etaf--slot-content-p content)
                        (etaf--slot-content-owner-component-id content)))
         (fallback (etaf--slot-projection-fallback projection)))
    (let ((etaf--render-style-owners
           (cond (captured-p (etaf--slot-projection-style-owners projection))
                 (entry etaf--render-parent-style-owners)
                 (t etaf--render-style-owners))))
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
    (and (not (etaf--slot-projection-captured-p projection))
     (cl-labels
        ((valid
          (value)
          (cond ((or (null value) (stringp value) (etaf--expr-p value)) t)
                ((etaf--view-node-p value)
                 (and (not (eq (etaf--view-node-name value) 'fragment))
                      (cl-every #'valid (etaf--view-node-children value))))
                ((proper-list-p value) (cl-every #'valid value))
                (t nil))))
      (valid values)))))

(defun etaf--render-component-call-pure (call path)
  "Render stateless CALL at PATH without a retained Runtime."
  (let* ((spec (etaf--component-call-spec call))
         (render (etaf--component-spec-render spec))
         (props (car (etaf--component-resolve-input
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
      (let ((etaf--render-parent-style-owners etaf--render-style-owners)
            (etaf--render-style-owners
             (list (etaf--style-owner-create
                    :scope (ebox-style-scope-create nil)
                    :rules (etaf--component-spec-styles spec)))))
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

(defun etaf--image-node (props)
  "Return one canonical Ebox media node for resolved image PROPS.
PROPS must contain :src, :columns and :rows; :adapter optionally selects the
Ebox image adapter.  The image owns its fixed cell size, clipping and no
wrapping, so the caller chooses the grid and wraps it in ordinary Boxes for
spacing and paint.  The cold preparation step owns all decoding and I/O and is
cached by Ebox for identical source/grid/adapter requests."
  (let ((src (plist-get props :src))
        (columns (plist-get props :columns))
        (rows (plist-get props :rows))
        (adapter (or (plist-get props :adapter) 'auto)))
    (unless (stringp src)
      (signal 'etaf-renderer-error
              (list (format "Image :src must be a file path string: %S" src))))
    (dolist (pair (list (cons :columns columns) (cons :rows rows)))
      (unless (and (integerp (cdr pair)) (> (cdr pair) 0))
        (signal 'etaf-renderer-error
                (list (format "Image %s must be a positive integer: %S"
                              (car pair) (cdr pair))))))
    (unless (memq adapter '(auto text placeholder))
      (signal 'etaf-renderer-error
              (list (format "Image :adapter must be auto, text or placeholder: %S"
                            adapter))))
    (unless (ebox-source-builder-p etaf--ebox-source-builder)
      (signal 'etaf-renderer-error
              (list "ETAF Image lowering requires one source builder")))
    (ebox-image-create
     (ebox-image-prepare src columns rows :adapter adapter)
     etaf--ebox-source-builder
     :identity (plist-get props :source-identity)
     :key (plist-get props :key)
     :id (plist-get props :id)
     :class (etaf--class-tokens (plist-get props :class))
     :selector-attributes (plist-get props :selector-attributes)
     :ecss-scopes (plist-get props :ecss-scopes)
     :ecss-scope-roots (plist-get props :ecss-scope-roots)
     :interactions (plist-get props :interactions)
     :provenance '(:adapter etaf-renderer :tag image))))

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
         (name (etaf--view-node-name node))
         (theme-result
          (etaf--resolve-host-theme
           name (etaf--resolve-property-plist (etaf--view-node-props node))
           (etaf--generated-host-ref base-props path (etaf--view-node-token node))
           property-bindings))
         (raw-props (nth 0 theme-result))
         (theme-deps (nth 1 theme-result))
         (props (etaf--host-theme-properties
                 (etaf--ebox-properties raw-props path (etaf--view-node-token node))
                 (nth 2 theme-result)))
         (style-root-p (and (not (eq name 'fragment)) (etaf--component-style-root-p)))
         (style-result (if (eq name 'fragment) (list props nil)
                         (etaf--host-component-style-properties props style-root-p)))
         (props (car style-result))
         (theme-deps (delete-dups (append theme-deps (cadr style-result))))
         (children (etaf--view-node-children node)))
    (pcase name
      ('text
       (let* ((semantic-id
              (and etaf--render-runtime
                    (etaf--runtime-register-semantic-host
                     etaf--render-runtime name raw-props props path
                     theme-deps property-bindings
                     property-deps property-context-deps base-props
                     (etaf--view-node-token node) style-root-p)))
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
      ('image
       (when children
         (signal 'etaf-renderer-error
                 (list "Image Host takes no children")))
       (let ((semantic-id
              (and etaf--render-runtime
                   (etaf--runtime-register-semantic-host
                    etaf--render-runtime name raw-props props path
                    theme-deps property-bindings
                    property-deps property-context-deps base-props
                    (etaf--view-node-token node) style-root-p))))
         (when semantic-id
           (etaf--runtime-finish-semantic-host etaf--render-runtime semantic-id))
         (list (etaf--image-node props))))
      ('fragment
       (etaf--render-value-list children (append path (list :fragment))))
      ((or 'box 'row 'column 'flex 'grid)
       (let ((nodes nil)
             (etaf--render-parent-path path)
             ;; A Host starts a new physical child list.  Component output
             ;; Ranges here keep their own anchor even inside another Range.
             (etaf--rendering-range-p nil)
             (index 0)
             (range-child-p nil)
             (semantic-id
              (and etaf--render-runtime
                   (etaf--runtime-register-semantic-host
                    etaf--render-runtime name raw-props props path
                    theme-deps property-bindings
                    property-deps property-context-deps base-props
                    (etaf--view-node-token node) style-root-p))))
         (dolist (child children)
           (setq nodes
                 (nconc nodes
                        (let ((etaf--current-semantic-parent-id
                               (or semantic-id etaf--current-semantic-parent-id))
                              (etaf--render-enclosing-style-scopes
                               (append (mapcar #'etaf--style-owner-scope etaf--render-style-owners)
                                       etaf--render-enclosing-style-scopes)))
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
    ('image
     (when children
       (signal 'etaf-renderer-error
               (list "Image Host takes no children")))
     (etaf--image-node props))
    ((or 'box 'row 'column 'flex 'grid)
     (etaf--layout-node name props children range-child-p))
    (_ (signal 'etaf-renderer-error
               (list (format "Expected text, image, box, row, column, flex, or grid Host; received %S"
                             name))))))

;;;###autoload
(defun etaf-render (view)
  "Lower normalized VIEW to one atomic canonical Ebox input.

This pure entry supports stateless Components.  Stateful Components require a
  Runtime because their setup Scope must have a lifecycle owner."
  (let ((builder (ebox-source-builder-create))
        (etaf--render-phase-p t))
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
