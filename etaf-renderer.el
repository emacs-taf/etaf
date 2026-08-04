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
(require 'etaf-context)

(declare-function etaf--runtime-render-component "etaf-runtime" (runtime call path))
(declare-function etaf--runtime-behavior-node "etaf-runtime" (runtime node path))
(declare-function etaf--runtime-register-host "etaf-runtime" (runtime props path))
(declare-function etaf-theme-defaults "etaf-context" (&optional default))

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

(defun etaf--event-property-p (property)
  "Return non-nil when PROPERTY is an ETAF event callback property."
  (and (keywordp property)
       (string-prefix-p "on-" (substring (symbol-name property) 1))))

(defun etaf--generated-host-ref (props path)
  "Return the explicit or generated opaque host reference for PROPS and PATH."
  (or (plist-get props :ref)
      (list 'etaf-host (copy-sequence path))))

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
    (let ((props (copy-sequence (etaf--view-node-props node))))
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
                (unless (plist-member props key)
                  (setq props (append props (list key value)))))))))
      (etaf--view-node-create
       :name (etaf--view-node-name node)
       :props props
       :children (etaf--view-node-children node)))))

(defun etaf--apply-theme-defaults (node)
  "Apply inherited Theme defaults to NODE without overriding props."
  (let ((defaults (etaf-theme-defaults)))
    (if (null defaults)
        node
      (let ((props (copy-sequence (etaf--view-node-props node))))
        (while defaults
          (let ((key (pop defaults))
                (value (pop defaults)))
            (unless (plist-member props key)
              (setq props (append props (list key value))))))
        (etaf--view-node-create
         :name (etaf--view-node-name node)
         :props props
         :children (etaf--view-node-children node))))))

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

(defun etaf--ebox-properties (props path)
  "Translate ETAF PROPS at PATH into Ebox's public property list."
  (let* ((source-props (etaf--resolve-property-plist props))
         (props (copy-sequence source-props))
         ebox-props surface-properties)
    (while props
      (let ((key (pop props))
            (value (pop props)))
        (cond
         ((eq key :face)
          (setq surface-properties
                (append surface-properties (list 'face value))))
         ((eq key :surface-properties)
          (setq surface-properties
                (append surface-properties value)))
         ((eq key :content)
          (signal 'etaf-renderer-error
                  (list "Use View children for content, not :content")))
         ((or (memq key etaf--semantic-props)
              (etaf--event-property-p key)
              (eq key :styles))
          nil)
         (t
          (setq ebox-props (append ebox-props (list key value)))))))
    (setq ebox-props
          (etaf--merge-property
           ebox-props :host-ref (etaf--generated-host-ref source-props path)))
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
  (let* ((name (etaf--slot-projection-name projection))
         (slots etaf--current-component-slots)
         (entry (assq name slots))
         (fallback (etaf--slot-projection-fallback projection)))
    (etaf--render-value-list
     (if entry (cdr entry) fallback)
     (append path (list :slot name)))))

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
      (let ((etaf--render-style-stack
             (cons (cons (etaf--component-spec-styles spec)
                         (append path (list :component
                                            (etaf--component-spec-name spec))))
                   etaf--render-style-stack)))
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
              ((stringp item) (list (ebox-create :content item)))
              ((etaf--view-node-p item)
               (etaf--render-node item item-path))
              ((etaf--component-call-p item)
               (if etaf--render-runtime
                   (list (etaf--runtime-render-component
                          etaf--render-runtime item item-path))
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
         (node (if (fboundp 'etaf--runtime-style-node)
                   (etaf--runtime-style-node node path)
                 node))
         (node (etaf--apply-theme-defaults node))
         (name (etaf--view-node-name node))
         (raw-props (etaf--resolve-property-plist
                     (etaf--view-node-props node)))
         (props (etaf--ebox-properties raw-props path))
         (children (etaf--view-node-children node)))
    (when (and etaf--render-runtime
               (fboundp 'etaf--runtime-register-host))
      (etaf--runtime-register-host etaf--render-runtime raw-props path))
    (pcase name
      ('text
       (let* ((flat (cl-mapcan #'etaf--flatten-view-value children))
              (child-path (append path (list :text)))
              (inline (etaf--inline-text-content flat))
              (rendered (unless (car inline)
                          (etaf--render-value-list flat child-path))))
         (if (car inline)
             (list (apply #'ebox-create
                          :content (cdr inline)
                          props))
           (list (ebox-build
                  (append (list 'row) props rendered))))))
      ('spacer
       (when children
         (signal 'etaf-renderer-error
                 (list "spacer cannot have children")))
       (list (apply #'ebox-spacer props)))
      ('fragment
       (etaf--render-value-list children (append path (list :fragment))))
      ((or 'row 'column 'container 'stack 'flex 'grid)
       (let ((nodes nil)
             (index 0))
         (dolist (child children)
           (setq nodes
                 (nconc nodes
                        (etaf--render-value-list
                         child (append path (list index)))))
           (cl-incf index))
         (list (etaf--layout-node name props nodes))))
      (_
       (signal 'etaf-renderer-error
               (list (format "Unknown Host reached renderer: %S" name)))))))

(defun etaf--layout-node (name props nodes)
  "Build layout NAME with Ebox PROPS around child NODES."
  (cond
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
            (list (format "Not a layout Host: %S" name))))))

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
(defun etaf-mount (buffer-or-name view)
  "Mount normalized VIEW into BUFFER-OR-NAME and return its buffer."
  (if (fboundp 'etaf-runtime-mount)
      (etaf-runtime-mount buffer-or-name view)
    (ebox-render-to-buffer buffer-or-name (etaf-render view))))

(provide 'etaf-renderer)

;;; etaf-renderer.el ends here
