;;; etaf-renderer.el --- ETAF to Ebox rendering bridge -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The renderer is the only first-slice module that knows Ebox.  It accepts
;; normalized View values, resolves `expr', turns semantic ETAF properties into
;; Ebox properties, and delegates measurement, layout, painting, and buffer
;; publication to Ebox's public API.

;;; Code:

(require 'cl-lib)
(require 'ebox)
(require 'etaf-view)

(define-error 'etaf-renderer-error "ETAF rendering error")

(defconst etaf--semantic-props
  '(:class :id :role :disabled :tab-index :ref :use
    :aria-label :aria-description :on-press :on-key-down :on-mouse-down
    :on-mouse-drag :on-wheel :on-input)
  "ETAF semantic properties that are not Ebox box properties.")

(defun etaf--event-property-p (property)
  "Return non-nil when PROPERTY is an ETAF event callback property."
  (and (keywordp property)
       (string-prefix-p "on-" (substring (symbol-name property) 1))))

(defun etaf--ebox-properties (props)
  "Translate ETAF PROPS into a property list accepted by Ebox."
  (let (ebox-props surface-properties)
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
    (when surface-properties
      (setq ebox-props
            (append ebox-props
                    (list :surface-properties surface-properties))))
    ebox-props))

(defun etaf--render-resolved-value (value)
  "Render one resolved string or View VALUE to a list of Ebox nodes."
  (cond
   ((stringp value)
    (list (ebox-create :content value)))
   ((etaf--view-node-p value)
    (etaf--render-node value))
   (t
    (signal 'etaf-renderer-error
            (list (format "Unresolved View value reached renderer: %S"
                          value))))))

(defun etaf--render-values (value)
  "Resolve and render VALUE to a flat list of Ebox nodes."
  (cl-mapcan #'etaf--render-resolved-value
             (etaf--resolve-value value)))

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
   (t
    (signal 'etaf-renderer-error
            (list (format "Not a layout Host: %S" name))))))

(defun etaf--render-node (node)
  "Render normalized Host NODE to a list of Ebox nodes."
  (let* ((name (etaf--view-node-name node))
         (props (etaf--ebox-properties (etaf--view-node-props node)))
         (children (etaf--resolve-value (etaf--view-node-children node))))
    (pcase name
      ('text
       (unless (cl-every #'stringp children)
         (signal 'etaf-renderer-error
                 (list "text children must resolve to strings")))
       (list (apply #'ebox-create
                    :content (apply #'concat children)
                    props)))
      ('spacer
       (when children
         (signal 'etaf-renderer-error
                 (list "spacer cannot have children")))
       (list (apply #'ebox-spacer props)))
      ('fragment
       (etaf--render-values children))
      ((or 'row 'column 'container 'stack 'flex)
       (list (etaf--layout-node name props (etaf--render-values children))))
      (_
       (signal 'etaf-renderer-error
               (list (format "Unknown Host reached renderer: %S" name)))))))

;;;###autoload
(defun etaf-render (view)
  "Lower normalized VIEW to one Ebox node.

Multiple root values are placed in a vertical column.  Ebox remains the owner
of all measurement, layout, painting, and identity details."
  (let ((nodes (etaf--render-values view)))
    (cond
     ((null nodes) (ebox-spacer))
     ((null (cdr nodes)) (car nodes))
     (t (apply #'ebox-column nodes)))))

;;;###autoload
(defun etaf-mount (buffer-or-name view)
  "Render VIEW into BUFFER-OR-NAME and return the live buffer."
  (ebox-render-to-buffer buffer-or-name (etaf-render view)))

(provide 'etaf-renderer)

;;; etaf-renderer.el ends here
