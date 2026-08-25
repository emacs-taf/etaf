;;; etaf-counter-example.el --- Retained state example -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This example keeps state inside one retained Component, derives display
;; values with `etaf-computed', and routes named mutations through an Action.

;;; Code:

(require 'etaf)

(defconst etaf-counter-example-buffer-name "*ETAF Counter Example*"
  "Buffer opened by `etaf-counter-example-open'.")

(etaf-action-define etaf-counter-example-update (runtime count operation)
  "Apply OPERATION to COUNT inside RUNTIME."
  (ignore runtime)
  (etaf-set-value
   count
   (pcase operation
     ('increment (1+ (etaf-value count)))
     ('decrement (max 0 (1- (etaf-value count))))
     ('reset 0)
     (_ (user-error "Unknown counter operation: %S" operation)))))

(defun etaf-counter-example--header (title)
  "Return the counter header for TITLE."
  (etaf-view
   (column :class "hero"
    (text :class "eyebrow" "BEST PRACTICE  /  RETAINED STATE")
    (text :face 'bold (expr :value title))
    (text :color "#66706A"
          "State belongs to setup; rendering only reads it."))))

(defun etaf-counter-example--metrics (count double status)
  "Return metric cards for COUNT, DOUBLE, and STATUS."
  (etaf-view
   (flex :width '(680) :flex-flow '(row wrap) :gap '(1 (12))
    (text :class "metric"
          (expr :value (format "COUNT  %d" (etaf-value count))))
    (text :class "metric"
          (expr :value (format "DOUBLE  %d" (etaf-value double))))
    (text :class "metric"
          (expr :value (format "STATE  %s" (etaf-value status)))))))

(defun etaf-counter-example--action (count label host-ref operation)
  "Return one COUNT action named LABEL using HOST-REF and OPERATION."
  (etaf-view
   (text :class "action" :ref host-ref :role 'button
         :use (list (etaf-focusable))
         :on-press (lambda ()
                     (etaf-dispatch 'etaf-counter-example-update
                                    count operation))
         (expr :value label))))

(defun etaf-counter-example--actions (count)
  "Return the action group for COUNT."
  (etaf-view
   (flex :width '(680) :flex-flow '(row wrap) :gap '(1 (12))
    (expr :value
          (etaf-counter-example--action
           count "−  DECREMENT" 'counter-decrement 'decrement))
    (expr :value
          (etaf-counter-example--action
           count "RESET" 'counter-reset 'reset))
    (expr :value
          (etaf-counter-example--action
           count "+  INCREMENT" 'counter-increment 'increment)))))

(etaf-define-component etaf-counter-example-card (&key title initial-value)
  "Render a retained counter named TITLE starting at INITIAL-VALUE."
  :styles
  (styles
   ("&" :width (680) :color "#252A2E" :bgcolor "#F8F5EE")
   (".hero" :width (680) :padding (1 (18)) :border "#8F432F"
    :bgcolor "#FFFDF8" :text-align center)
   (".eyebrow" :color "#8F432F" :face bold)
   (".metric" :flex-grow 1 :flex-shrink 1 :flex-basis (200)
    :min-width (180) :padding (1 (14)) :border "#6D8A73"
    :bgcolor "#DCEBDD" :text-align center)
   (".action" :flex-grow 1 :flex-shrink 1 :flex-basis (160)
    :min-width (140) :padding (1 (12)) :border "#4E7890"
    :bgcolor "#D9EAF2" :text-align center :face bold)
   (".note" :width (680) :padding (1 (16)) :border "#8D887F"
    :color "#4D5651" :bgcolor "#EEEAE2"))
  :setup
  (let* ((count (etaf-ref (or initial-value 0) :name 'counter))
         (double (etaf-computed
                  (lambda () (* 2 (etaf-value count)))
                  :name 'counter-double))
         (status (etaf-computed
                  (lambda ()
                    (if (zerop (etaf-value count)) "READY" "ACTIVE"))
                  :name 'counter-status)))
    (lambda ()
      (etaf-view
       (column
        (expr :value (etaf-counter-example--header title))
        (spacer :height 1)
        (expr :value
              (etaf-counter-example--metrics count double status))
        (spacer :height 1)
        (expr :value (etaf-counter-example--actions count))
        (spacer :height 1)
        (text :class "note"
              "Public path: Event → Action → Ref → Computed → Runtime commit"))))))

;;;###autoload
(defun etaf-counter-example-view ()
  "Return the counter example View."
  (etaf-view
   (etaf-counter-example-card
    :title "Counter workspace"
    :initial-value 2)))

;;;###autoload
(defun etaf-counter-example-open ()
  "Mount the counter example and return its buffer."
  (interactive)
  (let ((buffer (etaf-mount etaf-counter-example-buffer-name
                            (etaf-counter-example-view))))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

;;;###autoload
(defun etaf-counter-example-close ()
  "Unmount and kill the counter example buffer."
  (interactive)
  (when-let* ((runtime
              (etaf-runtime-for-buffer etaf-counter-example-buffer-name)))
    (etaf-unmount runtime))
  (when-let* ((buffer (get-buffer etaf-counter-example-buffer-name)))
    (kill-buffer buffer)))

(provide 'etaf-counter-example)

;;; etaf-counter-example.el ends here
