;;; etaf-animation-example.el --- Animated progress example -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This example drives three animations from one mounted Component: a layout
;; bar that follows its target width, a paint label that follows its target
;; color, and a frame sequence used as a spinner.  `Toggle` writes the two
;; targets, and the shared clock moves the display.

;;; Code:

(require 'etaf)

(defconst etaf-animation-example-buffer-name "*ETAF Animation Example*"
  "Buffer opened by `etaf-animation-example-open'.")

(defvar etaf-animation-example-progress (etaf-ref 0)
  "Target progress of the example bar, 0 to 1.")

(defvar etaf-animation-example-tint (etaf-ref "#4E7890")
  "Target background color of the example label.")

;;;###autoload
(defun etaf-animation-example-toggle ()
  "Flip both animation targets between their two states."
  (interactive)
  (setf (etaf-value etaf-animation-example-progress)
        (if (zerop (etaf-value etaf-animation-example-progress)) 1 0))
  (setf (etaf-value etaf-animation-example-tint)
        (if (equal (etaf-value etaf-animation-example-tint) "#4E7890")
            "#8F432F" "#4E7890")))

(etaf-define-component etaf-animation-example-demo ()
  "Show a layout bar, a fading label and a spinner."
  :bindings ((bar (etaf-transition etaf-animation-example-progress
                                   :duration 0.6 :easing 'ease-in-out))
             (color (etaf-transition etaf-animation-example-tint
                                     :duration 0.6 :easing 'linear))
             (frame (etaf-animation-frames
                     '("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
                     :interval 0.08)))
  :view
  (column
   (box :width '(ch 48) :padding-block '(lh 1)
        (text :font-weight 'bold "ETAF animation"))
   (box :width '(ch 48) :height '(lh 1) :bgcolor "#D8DEE6"
        (box :width (list 'ch (* 48 (etaf-value bar)))
             :height '(lh 1) :bgcolor (etaf-value color)))
   (box :width '(ch 48) :padding-block '(lh 1)
        (text (expr (format "progress %3d%%   "
                            (round (* 100 (etaf-value bar)))))))
   (box :width '(ch 48) :padding-block '(lh 1)
        (text (expr (concat (etaf-value frame) "  loading"))))
   (box :width '(ch 48) :padding-block '(lh 1)
        (text "Press RET on the line below to toggle the targets."))
   (box :role 'button :tab-index 0 :width '(ch 48)
        :border "#8F432F" :bgcolor "#F2E3D5" :text-align 'center
        :on-press #'etaf-animation-example-toggle
        "Toggle progress and color")))

;;;###autoload
(defun etaf-animation-example-view ()
  "Return the animation example View."
  (etaf-view (etaf-animation-example-demo)))

;;;###autoload
(defun etaf-animation-example-open ()
  "Mount the animation example and return its buffer."
  (interactive)
  (let ((buffer (etaf-mount etaf-animation-example-buffer-name
                            (etaf-animation-example-view))))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

(provide 'etaf-animation-example)
;;; etaf-animation-example.el ends here
