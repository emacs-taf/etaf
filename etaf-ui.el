;;; etaf-ui.el --- Official ETAF Components -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This file is the official Component catalog.  It deliberately exposes
;; Components, not Control/Widget/DataGrid runtime categories: a DataGrid is
;; a normal compound Component built from the same View, props, events, and
;; reactive Data contracts as every other catalog entry.

;;; Code:

(require 'cl-lib)
(require 'etaf)

(declare-function etaf-data-status "etaf-data" (controller))
(declare-function etaf-data-items "etaf-data" (controller))
(declare-function text "etaf-view" (&rest arguments))
(declare-function row "etaf-view" (&rest arguments))
(declare-function column "etaf-view" (&rest arguments))
(declare-function expr "etaf-view" (&rest arguments))
(declare-function slot "etaf-view" (&rest arguments))

(defun etaf-ui--column-value (column key)
  "Return KEY from COLUMN, accepting a plist or alist descriptor."
  (if (and (listp column) (keywordp (car column)))
      (plist-get column key)
    (alist-get key column)))

(defun etaf-ui--grid-cell-value (row key)
  "Return KEY from data ROW, accepting a plist, alist, or hash table."
  (cond
   ((hash-table-p row) (gethash key row))
   ((and (proper-list-p row)
         (zerop (% (length row) 2))
         (keywordp (car row)))
    (plist-get row key))
   ((listp row) (alist-get key row))
   (t nil)))

(defun etaf-ui--grid-header-cell (column)
  "Return one header View for COLUMN."
  (etaf-view
   (text
    :face 'bold
    :width (etaf-ui--column-value column :width)
    (expr :value (format "%s"
                        (or (etaf-ui--column-value column :label)
                            (etaf-ui--column-value column :key)))))))

(defun etaf-ui--grid-header (columns)
  "Return a View header row for COLUMNS."
  (etaf-view
   (row
    :class "etaf-data-grid-header"
    (expr :value (mapcar #'etaf-ui--grid-header-cell columns)))))

(defun etaf-ui--grid-cell (row column)
  "Return one data cell View for ROW and COLUMN."
  (let ((key (etaf-ui--column-value column :key)))
    (etaf-view
     (text
      :width (etaf-ui--column-value column :width)
      (expr :value
            (format "%s" (or (etaf-ui--grid-cell-value row key) "")))))))

(defun etaf-ui--grid-cells (row columns)
  "Return data cell Views for ROW and COLUMNS."
  (mapcar (lambda (column) (etaf-ui--grid-cell row column)) columns))

(defun etaf-ui--grid-row (row columns row-key on-row-press)
  "Return a View row for ROW, COLUMNS, ROW-KEY, and ON-ROW-PRESS."
  (let ((key (funcall row-key row)))
    (unless key
      (error "ETAF DataGrid row-key must return a non-nil stable scalar"))
    (etaf-view
     (row
      :key key
      :class "etaf-data-grid-row"
      :on-press (when on-row-press
                  (lambda () (funcall on-row-press row)))
      (expr :value (etaf-ui--grid-cells row columns))))))

;;;###autoload
(etaf-define-component etaf-button (&key label on-press disabled ref)
  "Render a standard pressable button with LABEL and ON-PRESS.

DISABLED removes the callback and the default focus tab index.  The Component
has no `variant' or Control type; callers use ordinary props and `:styles'
when they need a product-specific appearance."
  :styles
  (styles
   ("&" :padding (0 1) :border ((1) solid "#687386"))
   ("&.disabled" :color "#8A93A6")
   ("&.enabled" :face bold))
  :view
  (text
   :class (if disabled "etaf-button disabled" "etaf-button enabled")
   :role 'button
   :ref ref
   :disabled disabled
   :tab-index (unless disabled 0)
   :on-press (unless disabled on-press)
   (expr :value label)))

;;;###autoload
(etaf-define-component etaf-checkbox (&key checked label on-change ref)
  "Render a controlled checkbox with CHECKED, LABEL, and ON-CHANGE.

ON-CHANGE receives the next boolean value.  State ownership remains with the
caller, so the Component is reusable in both local and Data-backed forms."
  :view
  (row
   :class "etaf-checkbox"
   :role 'checkbox
   :ref ref
   :aria-label label
   :on-press (lambda ()
               (when on-change
                 (funcall on-change (not checked))))
   (text :face 'bold (expr :value (if checked "☑" "☐")))
   (text (expr :value (if label (concat " " label) "")))))

;;;###autoload
(etaf-define-component etaf-label (&key text face)
  "Render TEXT as a semantic text label with optional FACE."
  :view
  (text :face face (expr :value text)))

;;;###autoload
(etaf-define-component etaf-panel (&key title)
  "Render a titled panel with header and default slot projections."
  :styles
  (styles
   ("&" :padding (1 2) :border ((1) solid "#687386"))
   (".etaf-panel-title" :face bold))
  :view
  (column
   :class "etaf-panel"
   (expr
    :value
    (when title
      (etaf-view (text :class "etaf-panel-title"
                       (expr :value title)))))
   (slot :name 'header)
   (slot)))

;;;###autoload
(etaf-define-component etaf-data-grid
    (&key controller columns row-key on-row-press
          loading-label error-label empty-label)
  "Render rows from reactive DATA CONTROLLER and COLUMNS.

COLUMNS is a list of descriptors such as `(:key :name :label NAME)'.
ROW-KEY is a function receiving each row and must return a non-nil stable
scalar key.
The Data Controller owns loading, errors, pagination, mutation, and selection;
this Component only projects that state into ordinary Hosts."
  :view
  (column
   :class "etaf-data-grid"
   (expr :value (etaf-ui--grid-header columns))
   (expr
    :value
    (progn
      (unless (functionp row-key)
        (error "ETAF DataGrid requires a function-valued :row-key"))
      (let ((status (etaf-value (etaf-data-status controller)))
            (items (etaf-value (etaf-data-items controller))))
        (cond
         ((eq status 'loading)
          (etaf-view (text (expr :value (or loading-label "Loading...")))))
         ((eq status 'error)
          (etaf-view (text :color "#FF6B6B"
                           (expr :value
                                 (or error-label "Unable to load data.")))))
         ((null items)
          (etaf-view (text (expr :value (or empty-label "No data.")))))
         (t
          (mapcar
           (lambda (item)
             (etaf-ui--grid-row item columns row-key
                                on-row-press))
           items))))))
   (slot :name 'footer)))

(provide 'etaf-ui)

;;; etaf-ui.el ends here
