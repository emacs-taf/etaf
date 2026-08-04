;;; etaf-playground.el --- Small ETAF application examples -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The ETAF playground is an optional application example.  It exercises only
;; public ETAF APIs; the Ebox playground remains a separate sibling package.

;;; Code:

(require 'cl-lib)
(require 'etaf)

(defconst etaf-playground-buffer-name "*ETAF Playground*"
  "Default buffer name used by `etaf-playground-open'.")

;;;###autoload
(etaf-define-component etaf-playground-counter (&key title)
  "Render a small stateful counter titled TITLE.

The counter demonstrates a retained `:setup' Scope, reactive state, semantic
Host references, and ordinary `:on-press' callbacks without introducing a
special counter node or a second event model."
  :setup
  (let ((count (etaf-ref 0 :name 'playground-count)))
    (lambda ()
      (etaf-view
       (column
        :class "etaf-playground-counter"
        (text :face 'bold (expr :value title))
        (text
         (expr :value (format "Count: %d" (etaf-value count))))
        (row
         (text
          :ref 'decrement
          :role 'button
          :tab-index 0
          :on-press (lambda () (cl-decf (etaf-value count)))
          " - ")
         (text
          :ref 'increment
          :role 'button
          :tab-index 0
          :on-press (lambda () (cl-incf (etaf-value count)))
          " + ")))))))

;;;###autoload
(defun etaf-playground-view ()
  "Return the core ETAF playground View.

The returned View has no buffer or global state side effect until it is passed
to `etaf-mount'."
  (etaf-view
   (column
    :class "etaf-playground-root"
    (text :face 'bold "ETAF Playground")
    (text :color "#687386"
          "One grammar: Hosts, Components, props, children, and expr.")
    (etaf-playground-counter :title "Reactive counter")
    (text :color "#687386"
          "Press + or - with `etaf-dispatch-event' or the normal event bridge."))))

;;;###autoload
(defun etaf-playground-ui-view ()
  "Return a playground View that also demonstrates the official UI catalog.

Loading this function requires `etaf-ui'; the core playground itself does not
depend on that optional Component catalog."
  (require 'etaf-ui)
  (etaf-view
   (column
    (etaf-panel :title "Official Components"
     (etaf-button
      :label "A public Component"
      :on-press (lambda () (message "ETAF UI button pressed")))
     (etaf-checkbox
      :checked nil
      :label "Controlled checkbox"
      :on-change (lambda (value)
                   (message "Checkbox value: %s" value))))
    (etaf-playground-counter :title "Core counter"))))

;;;###autoload
(defun etaf-playground-open (&optional buffer-name)
  "Mount the core ETAF playground in BUFFER-NAME and return its buffer."
  (interactive)
  (etaf-mount (or buffer-name etaf-playground-buffer-name)
              (etaf-playground-view)))

;;;###autoload
(defun etaf-playground-open-ui (&optional buffer-name)
  "Mount the ETAF playground with official UI Components in BUFFER-NAME."
  (interactive)
  (etaf-mount (or buffer-name etaf-playground-buffer-name)
              (etaf-playground-ui-view)))

;;;###autoload
(defun etaf-playground-close (&optional buffer-name)
  "Unmount and kill the playground BUFFER-NAME, returning its buffer.

When BUFFER-NAME is nil, use `etaf-playground-buffer-name'."
  (interactive)
  (let* ((name (or buffer-name etaf-playground-buffer-name))
         (buffer (get-buffer name)))
    (when-let ((runtime (and buffer (etaf-runtime-for-buffer buffer))))
      (etaf-unmount runtime))
    (when buffer
      (kill-buffer buffer))
    buffer))

(provide 'etaf-playground)

;;; etaf-playground.el ends here
