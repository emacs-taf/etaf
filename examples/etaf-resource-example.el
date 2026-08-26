;;; etaf-resource-example.el --- Resource lifecycle example -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This example keeps a synchronous Resource inside Component setup, exposes
;; success and error states, and lets Scope disposal own loader cleanup.

;;; Code:

(require 'etaf)

(defconst etaf-resource-example-buffer-name "*ETAF Resource Example*"
  "Buffer opened by `etaf-resource-example-open'.")

(defun etaf-resource-example--message (resource)
  "Return a display message for RESOURCE."
  (pcase (etaf-resource-status resource)
    ('success (etaf-resource-value resource))
    ('error (error-message-string (etaf-resource-error resource)))
    ('loading "Loading service snapshot…")
    (_ "Resource has not loaded.")))

(defun etaf-resource-example--header ()
  "Return the Resource example header."
  (etaf-view
   (box :layout 'column :width '(680) :padding '(1 (18)) :border "#8F432F"
    :bgcolor "#FFFDF8" :text-align 'center
    (text :color "#8F432F" :face 'bold
          "BEST PRACTICE  /  RESOURCE LIFECYCLE")
    (text :face 'bold "Service health")
    (text :color "#66706A"
          "Loader errors become explicit state; cleanup stays scoped."))))

(defun etaf-resource-example--status (resource cleanup-count)
  "Return the status card for RESOURCE and CLEANUP-COUNT."
  (let* ((status (etaf-resource-status resource))
         (success (eq status 'success))
         (surface (if success "#DCEBDD" "#F1D4C9"))
         (border (if success "#6D8A73" "#C97252"))
         (ink (if success "#24422D" "#6B3020")))
    (etaf-view
     (box :layout 'column :width '(680) :padding '(2 (18)) :border border
      :bgcolor surface :color ink :text-align 'center
      (text :face 'bold
            (expr :value (upcase (symbol-name status))))
      (text (expr :value (etaf-resource-example--message resource)))
      (text :color "#66706A"
            (expr :value
                  (format "CLEANUPS  %d" (etaf-value cleanup-count))))))))

(defun etaf-resource-example--actions (resource fail-next)
  "Return action controls for RESOURCE and FAIL-NEXT."
  (etaf-view
   (box :layout 'flex :width '(680) :flex-flow '(row wrap) :gap '(1 (12))
    (text :flex-grow 1 :flex-shrink 1 :flex-basis '(200)
          :min-width '(180) :padding '(1 (12))
          :border "#4E7890" :bgcolor "#D9EAF2" :face 'bold
          :text-align 'center :ref 'resource-reload :role 'button
          :use (list (etaf-focusable))
          :on-press (lambda () (etaf-resource-load resource))
          "RELOAD")
    (text :flex-grow 1 :flex-shrink 1 :flex-basis '(200)
          :min-width '(180) :padding '(1 (12))
          :border "#C97252" :bgcolor "#F1D4C9" :face 'bold
          :text-align 'center :ref 'resource-fail :role 'button
          :use (list (etaf-focusable))
          :on-press (lambda ()
                      (etaf-set-value fail-next t)
                      (etaf-resource-load resource))
          "SIMULATE FAILURE"))))

(defun etaf-resource-example--view (resource fail-next cleanup-count)
  "Return the example View for RESOURCE, FAIL-NEXT, and CLEANUP-COUNT."
  (etaf-view
   (box :layout 'column :width '(680) :color "#252A2E" :bgcolor "#F8F5EE"
    (expr :value (etaf-resource-example--header))
    (box :height 1)
    (expr :value
          (etaf-resource-example--status resource cleanup-count))
    (box :height 1)
    (expr :value (etaf-resource-example--actions resource fail-next))
    (box :height 1)
    (text :width '(680) :padding '(1 (16)) :border "#8D887F"
          :color "#4D5651" :bgcolor "#EEEAE2"
          "Scope rule: reload releases the old value; unmount releases the last one"))))

(etaf-define-component etaf-resource-example-app ()
  "Render a reloadable Resource with visible cleanup and error state."
  :setup
  (let ((fail-next (etaf-ref nil :name 'etaf-resource-example-fail))
        (cleanup-count (etaf-ref 0 :name 'etaf-resource-example-cleanups))
        (generation 0)
        resource)
    (setq resource
          (etaf-resource
           (lambda ()
             (cl-incf generation)
             (if (etaf-value fail-next)
                 (progn
                   (etaf-set-value fail-next nil)
                   (error "Synthetic service failure %d" generation))
               (etaf-resource-result
                (format "Generation %d is healthy." generation)
                :cleanup
                (lambda ()
                  (etaf-set-value
                   cleanup-count
                   (1+ (etaf-value cleanup-count)))))))
           :immediate nil
           :name 'etaf-resource-example))
    (etaf-on-mounted (lambda () (etaf-resource-load resource)))
    (lambda ()
      (etaf-resource-example--view resource fail-next cleanup-count))))

;;;###autoload
(defun etaf-resource-example-view ()
  "Return the Resource lifecycle example View."
  (etaf-view (etaf-resource-example-app)))

;;;###autoload
(defun etaf-resource-example-open ()
  "Mount the Resource lifecycle example and return its buffer."
  (interactive)
  (let ((buffer (etaf-mount etaf-resource-example-buffer-name
                            (etaf-resource-example-view))))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

;;;###autoload
(defun etaf-resource-example-close ()
  "Unmount and kill the Resource lifecycle example buffer."
  (interactive)
  (when-let* ((runtime
              (etaf-runtime-for-buffer etaf-resource-example-buffer-name)))
    (etaf-unmount runtime))
  (when-let* ((buffer (get-buffer etaf-resource-example-buffer-name)))
    (kill-buffer buffer)))

(provide 'etaf-resource-example)

;;; etaf-resource-example.el ends here
