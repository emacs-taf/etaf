;;; etaf-data-example.el --- Data Controller example -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This example owns a Data Controller at the Component boundary, stops it on
;; unmount, and keeps query, selection, and mutation on public Data APIs.

;;; Code:

(require 'etaf)

(defconst etaf-data-example-buffer-name "*ETAF Data Example*"
  "Buffer opened by `etaf-data-example-open'.")

(defconst etaf-data-example-tasks
  '((:id 1 :title "Define the public boundary" :owner "Ada" :status open)
    (:id 2 :title "Verify retained updates" :owner "Grace" :status done)
    (:id 3 :title "Document cleanup ownership" :owner "Alan" :status open)
    (:id 4 :title "Review visual hierarchy" :owner "Barbara" :status open)
    (:id 5 :title "Run the complete gate" :owner "Edsger" :status done))
  "Initial records used by the Data Controller example.")

(etaf-action-define etaf-data-example-add (runtime controller next-id)
  "Insert one task into CONTROLLER using NEXT-ID inside RUNTIME."
  (ignore runtime)
  (let ((identity (etaf-value next-id)))
    (etaf-data-mutate
     controller 'insert
     (list :id identity
           :title (format "Review example #%d" identity)
           :owner "Team"
           :status 'open))
    (etaf-set-value next-id (1+ identity))))

(etaf-action-define etaf-data-example-toggle (runtime controller identity)
  "Toggle IDENTITY selection in CONTROLLER inside RUNTIME."
  (ignore runtime)
  (etaf-data-select controller identity
                    (not (etaf-data-selected-p controller identity))))

(defun etaf-data-example--filter (controller query)
  "Set CONTROLLER to QUERY and load its matching records."
  (etaf-data-set-query controller query)
  (etaf-data-load controller))

(defun etaf-data-example--row (controller task)
  "Return one TASK row bound to CONTROLLER."
  (let* ((identity (plist-get task :id))
         (selected (etaf-data-selected-p controller identity))
         (status (plist-get task :status))
         (host-ref (intern (format "data-task-%d" identity))))
    (etaf-view
     (flex :width '(718) :flex-flow '(row nowrap) :gap '(0 (10))
      :padding '(1 (12)) :border "#6D8A73"
      :bgcolor (if selected "#DCEBDD" "#FFFDF8")
      :ref host-ref :role 'button :use (list (etaf-focusable))
      :on-press (lambda ()
                  (etaf-dispatch 'etaf-data-example-toggle
                                 controller identity))
      (box :width '(36) :font-weight 'bold
           :color (if selected "#2F6B43" "#8D887F")
       (text (expr :value (if selected "●" "○"))))
      (box :flex-grow 1 :flex-shrink 1 :flex-basis '(390)
           :min-width '(280)
       (text (expr :value (plist-get task :title))))
      (box :width '(96) :color "#66706A"
       (text (expr :value (plist-get task :owner))))
      (box :width '(84) :font-weight 'bold :text-align 'right
           :color (if (eq status 'done) "#2F6B43" "#9B4A34")
       (text (expr :value (upcase (symbol-name status)))))))))

(defun etaf-data-example--header (controller)
  "Return the summary header for CONTROLLER."
  (let ((total (etaf-value (etaf-data-total controller)))
        (selection (etaf-value (etaf-data-selection controller))))
    (etaf-view
     (column :width '(720) :padding '(1 (18)) :border "#8F432F"
      :bgcolor "#FFFDF8" :text-align 'center
      (text :color "#8F432F" :font-weight 'bold
            "BEST PRACTICE  /  DATA OWNERSHIP")
      (text :font-weight 'bold "Task controller")
      (text :color "#66706A"
            (expr :value
                  (format "%d records · %d selected" total
                          (length selection))))))))

(defun etaf-data-example--filter-control
    (controller label host-ref query border background)
  "Return a filter LABEL for CONTROLLER using HOST-REF and QUERY.
Use BORDER and BACKGROUND for its semantic color family."
  (etaf-view
   (box :padding '(1 (12)) :border border :bgcolor background
        :font-weight 'bold :ref host-ref :role 'button
        :use (list (etaf-focusable))
        :on-press (lambda ()
                    (etaf-data-example--filter controller query))
    (text (expr :value label)))))

(defun etaf-data-example--toolbar (controller next-id)
  "Return the action toolbar for CONTROLLER and NEXT-ID."
  (etaf-view
   (flex :width '(720) :flex-flow '(row wrap) :gap '(1 (10))
    (expr :value (etaf-data-example--filter-control
                  controller "ALL" 'data-filter-all nil
                  "#4E7890" "#D9EAF2"))
    (expr :value (etaf-data-example--filter-control
                  controller "OPEN" 'data-filter-open '(:status open)
                  "#C97252" "#F1D4C9"))
    (expr :value (etaf-data-example--filter-control
                  controller "DONE" 'data-filter-done '(:status done)
                  "#6D8A73" "#DCEBDD"))
    (box :padding '(1 (12)) :border "#7A6B95" :bgcolor "#E7E2F1"
         :font-weight 'bold :ref 'data-add :role 'button
         :use (list (etaf-focusable))
         :on-press (lambda ()
                     (etaf-dispatch 'etaf-data-example-add
                                    controller next-id))
     (text "+ ADD TASK")))))

(defun etaf-data-example--rows (controller)
  "Return the loaded task rows for CONTROLLER."
  (let ((items (etaf-value (etaf-data-items controller))))
    (if items
        (mapcar (lambda (task)
                  (etaf-data-example--row controller task))
                items)
      (etaf-view
       (box :width '(720) :padding '(2 (16))
            :border "#8D887F" :bgcolor "#EEEAE2"
            :text-align 'center
        (text "No matching tasks."))))))

(defun etaf-data-example--view (controller next-id)
  "Return the Data example View for CONTROLLER and NEXT-ID."
  (etaf-view
   (column :width '(720) :color "#252A2E" :bgcolor "#F8F5EE"
    (expr :value (etaf-data-example--header controller))
    (box :height 1)
    (expr :value (etaf-data-example--toolbar controller next-id))
    (box :height 1)
    (column :width '(720)
     (expr :value (etaf-data-example--rows controller)))
    (box :height 1)
    (box :width '(720) :padding '(1 (16)) :border "#8D887F"
         :color "#4D5651" :bgcolor "#EEEAE2"
     (text
      "Owner rule: create in setup, mutate through Data, stop on unmount")))))

(etaf-define-component etaf-data-example-app ()
  "Render a memory-backed task application with owned cleanup."
  :setup
  (let* ((source (etaf-data-memory-source
                  etaf-data-example-tasks :id-key :id
                  :name 'etaf-data-example))
         (controller (etaf-data-controller
                      source :page-size 20
                      :name 'etaf-data-example))
         (next-id (etaf-ref 6 :name 'etaf-data-example-next-id)))
    (etaf-on-mounted (lambda () (etaf-data-load controller)))
    (etaf-on-unmounted (lambda () (etaf-data-stop controller)))
    (lambda () (etaf-data-example--view controller next-id))))

;;;###autoload
(defun etaf-data-example-view ()
  "Return the Data Controller example View."
  (etaf-view (etaf-data-example-app)))

;;;###autoload
(defun etaf-data-example-open ()
  "Mount the Data Controller example and return its buffer."
  (interactive)
  (let ((buffer (etaf-mount etaf-data-example-buffer-name
                            (etaf-data-example-view))))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

;;;###autoload
(defun etaf-data-example-close ()
  "Unmount and kill the Data Controller example buffer."
  (interactive)
  (when-let* ((runtime
              (etaf-runtime-for-buffer etaf-data-example-buffer-name)))
    (etaf-unmount runtime))
  (when-let* ((buffer (get-buffer etaf-data-example-buffer-name)))
    (kill-buffer buffer)))

(provide 'etaf-data-example)

;;; etaf-data-example.el ends here
