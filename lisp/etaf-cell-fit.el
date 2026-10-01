;;; etaf-cell-fit.el --- Fit canvas glyphs into their grid cells -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; A mounted Runtime paints a character grid whose height ETAF reports to the
;; application in rows, and applications budget their content in rows.  Emacs,
;; however, gives a line the height of the tallest glyph on it, and resolves a
;; glyph's font through the fontset fallback chain: a symbol that falls back to
;; a font with taller metrics (or to a bold variant of one) makes its row
;; taller than the cell.  A few such rows then push the canvas past the
;; viewport and the window clips its bottom rows, which applications see as a
;; cut-off status line.
;;
;; No text property can cap a line's height (`line-height' only grows one), so
;; the grid is kept uniform the other way around: after a publication, measure
;; the rows whose content changed and give the glyphs that overflow the cell a
;; smaller face height until their row fits.  The common case measures nothing:
;; an unchanged canvas is recognized from its snapshot, and only changed rows
;; are measured again.

;;; Code:

(require 'cl-lib)

(defcustom etaf-cell-fit-enabled t
  "Whether a published canvas keeps every row within one grid cell.
Disabling it leaves glyph overflow to the font fallback chain, which can make
a canvas taller in pixels than the rows it was budgeted for."
  :type 'boolean
  :group 'etaf)

(defconst etaf-cell-fit--scale-step 0.06
  "Face height fraction removed per fitting attempt.")

(defconst etaf-cell-fit--scale-floor 0.6
  "Smallest face height fraction the fitting pass will try.")

(defvar etaf-cell-fit--snapshots (make-hash-table :test #'eq)
  "Canvas snapshot per buffer, used to skip rows whose content did not change.")

(defvar etaf-cell-fit--timers (make-hash-table :test #'eq)
  "Pending fit timers per buffer.")

(defcustom etaf-cell-fit-delay 0.05
  "Seconds of quiet after the last publication before fitting the canvas.
A publication arrives in a burst and later publications rewrite the text, so
fitting inside the burst is undone by the paint that follows it."
  :type 'number
  :group 'etaf)

(defun etaf-cell-fit-forget (&optional buffer)
  "Drop BUFFER's fitting snapshot, or every snapshot when BUFFER is nil.
Buffers are dropped automatically when they are killed; call this after
changing a canvas behind ETAF's back (tests and probes do)."
  (if buffer
      (remhash buffer etaf-cell-fit--snapshots)
    (clrhash etaf-cell-fit--snapshots)))

(defun etaf-cell-fit--font-height (position)
  "Return the pixel height of the font used at POSITION, or nil."
  (let* ((font (font-at position))
         (info (and font (ignore-errors (font-info font)))))
    (and info (aref info 3))))

(defun etaf-cell-fit--shrink-row (start end cell-height)
  "Give glyphs between START and END a smaller face until the row fits.
CELL-HEIGHT is the grid cell in pixels.  Only glyphs whose font is taller than
the cell are touched, so ordinary text keeps its size."
  (save-excursion
    (goto-char start)
    (while (< (point) end)
      (let ((character (char-after)))
        (when (and character (not (memq character '(?\s ?\n))))
          (let ((height (etaf-cell-fit--font-height (point))))
            (when (and height (> height cell-height))
              (let ((scale (- 1.0 etaf-cell-fit--scale-step)))
                (while (and (> (line-pixel-height) cell-height)
                            (>= scale etaf-cell-fit--scale-floor))
                  (add-face-text-property (point) (1+ (point))
                                          (list :height scale) 'append)
                  (setq scale (- scale etaf-cell-fit--scale-step))))))))
      (forward-char 1))))

(defun etaf-cell-fit--fit-changed-rows (previous cell-height)
  "Fit the current buffer's rows that differ from snapshot PREVIOUS.
Return the number of rows whose glyphs were scaled."
  (let ((rows (and previous (split-string previous "\n")))
        (index 0)
        (fitted 0))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let* ((start (line-beginning-position))
               (end (line-end-position))
               (changed (not (equal (buffer-substring start end)
                                    (nth index rows)))))
          (when (and changed (> (line-pixel-height) cell-height))
            (etaf-cell-fit--shrink-row start end cell-height)
            (cl-incf fitted)))
        (forward-line 1)
        (setq index (1+ index))))
    fitted))

;;;###autoload
(defun etaf-cell-fit-apply (&optional buffer)
  "Keep BUFFER's canvas rows within one grid cell.
Return the number of rows whose glyphs were scaled, or nil when the canvas
was unchanged, is not displayed, or fitting is disabled.  The canvas is
described by the window that displays it; a buffer ETAF only has mounted
headlessly needs no fitting, because nothing paints it."
  (let ((buffer (or buffer (current-buffer))))
    (when (and etaf-cell-fit-enabled
               (buffer-live-p buffer)
               (get-buffer-window buffer t))
      (with-current-buffer buffer
        (let* ((window (get-buffer-window buffer t))
               (cell-height (frame-char-height (window-frame window)))
               (snapshot (buffer-substring (point-min) (point-max)))
               (previous (gethash buffer etaf-cell-fit--snapshots)))
          (unless (equal snapshot previous)
            ;; `let' evaluates its init forms before binding, so the fitting
            ;; pass must run in the body where the buffer is already writable.
            (let ((inhibit-read-only t)
                  fitted)
              (setq fitted (etaf-cell-fit--fit-changed-rows previous cell-height))
              (puthash buffer (buffer-substring (point-min) (point-max))
                       etaf-cell-fit--snapshots)
              fitted)))))))

(defun etaf-cell-fit-schedule (&optional buffer)
  "Fit BUFFER's canvas once the current publication burst has settled.
Repeated calls for the same buffer keep one timer."
  (let ((buffer (or buffer (current-buffer))))
    (when (and etaf-cell-fit-enabled (buffer-live-p buffer))
      (let ((pending (gethash buffer etaf-cell-fit--timers)))
        (when pending (cancel-timer pending))
      (puthash buffer
               (run-at-time etaf-cell-fit-delay nil
                            (lambda ()
                              (remhash buffer etaf-cell-fit--timers)
                              (when (buffer-live-p buffer)
                                (etaf-cell-fit-apply buffer))))
               etaf-cell-fit--timers)))))

(provide 'etaf-cell-fit)
;;; etaf-cell-fit.el ends here
