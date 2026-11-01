;;; etaf-projection.el --- Read painted cells back as source ranges  -*- lexical-binding: t; -*-

;;; Commentary:

;; A preview paints a document that lives elsewhere: markdown source in a
;; buffer, an org subtree, a database row.  Editing it in place needs the way
;; back from painted cells to that source.
;;
;; Only some applications have such a source, so this is a plain query rather
;; than a rendering mode.  Nothing runs unless an application asks:
;;
;;   (etaf-projection runtime '((intro . (0 . 42))
;;                              (body  . (43 . 91))))
;;
;; Each entry names a Host reference and the source range its painted cells
;; stand for.  References, not nodes, are the identity a repaint keeps.
;;
;; The result is plain data computed from the current paint, so it can never
;; describe an older frame.

;;; Code:

(require 'cl-lib)
(require 'ebox)
(require 'etaf-runtime)

(defun etaf--projection-cells (buffer start end)
  "Return the painted (BEG . END) cells in BUFFER between START and END.
Each cell is one line without its break, because a break owns no character a
caret can stand on."
  (let ((cells nil))
    (with-current-buffer buffer
      (save-excursion
        (goto-char start)
        (while (< (point) end)
          (let* ((beg (point))
                 (line-end (min (line-end-position) end)))
            (when (> line-end beg)
              (push (cons beg line-end) cells))
            (goto-char (min end (1+ (line-end-position))))))))
    (nreverse cells)))

(defun etaf--projection-runs (buffer bounds source)
  "Return one run per painted line of BOUNDS, cut from SOURCE.
A Host whose text wraps spreads its source range over the lines it painted in
proportion to their cells, so a wrapped paragraph stays editable in place
without asking authors to pre-split it."
  (let* ((cells (etaf--projection-cells buffer (car bounds) (cdr bounds)))
         (total (cl-loop for cell in cells sum (- (cdr cell) (car cell))))
         (span (- (cdr source) (car source))))
    (when (> total 0)
      (let ((consumed 0) (runs nil))
        (dolist (cell cells)
          (let* ((width (- (cdr cell) (car cell)))
                 (beg (+ (car source) (/ (* consumed span) total)))
                 (end (+ (car source) (/ (* (+ consumed width) span) total))))
            (push (list (car cell) (cdr cell) beg end) runs)
            (setq consumed (+ consumed width))))
        (nreverse runs)))))

(defun etaf--projection-trim (runs)
  "Return RUNS ordered by painted position with overlapping tails trimmed.
An inner Host wins the cells it shares with the Host around it."
  (let ((sorted (sort runs (lambda (a b) (< (car a) (car b)))))
        (result nil)
        (reached 0))
    (dolist (run sorted)
      (when (> (nth 1 run) reached)
        (when (< (car run) reached)
          (setcar run reached))
        (push run result)
        (setq reached (nth 1 run))))
    (vconcat (nreverse result))))

;;;###autoload
(defun etaf-projection (runtime entries)
  "Return the projection of RUNTIME described by ENTRIES.
ENTRIES is an alist of (REF . (SOURCE-START . SOURCE-END)), one per Host whose
painted cells stand for a source range.  Return a vector of runs
\(DISPLAY-BEG DISPLAY-END SOURCE-BEG SOURCE-END) ordered by display position;
entries that paint nothing, or name a range of zero length, are skipped."
  (let ((buffer (etaf-runtime-buffer runtime))
        (runs nil))
    (dolist (entry entries)
      (let* ((range (cdr entry))
             (node (etaf-runtime-host-node runtime (car entry)))
             (bounds (and node (ebox-node-bounds node t))))
        (when (and bounds (integerp (car range)) (integerp (cdr range))
                   (< (car range) (cdr range)))
          (setq runs (nconc (etaf--projection-runs buffer bounds range) runs)))))
    (etaf--projection-trim runs)))

(defun etaf--projection-find (projection start-slot end-slot position)
  "Return the run of PROJECTION whose START-SLOT..END-SLOT holds POSITION."
  (let ((low 0) (high (1- (length projection))) (found nil))
    (while (<= low high)
      (let* ((middle (/ (+ low high) 2))
             (run (aref projection middle)))
        (cond ((< position (nth start-slot run)) (setq high (1- middle)))
              ((>= position (nth end-slot run)) (setq low (1+ middle)))
              (t (setq found run low (1+ high))))))
    found))

;;;###autoload
(defun etaf-projection-source-offset (projection position)
  "Return the source offset that painted POSITION stands for.
A position outside every run reports the nearest run edge, so a caret after
the last cell of a line still names a source character."
  (let ((run (etaf--projection-find projection 0 1 position)))
    (if run
        (min (nth 3 run) (+ (nth 2 run) (- position (car run))))
      (let ((nearest nil) (first nil))
        (dotimes (index (length projection))
          (let ((candidate (aref projection index)))
            (when (and (<= (car candidate) position)
                       (or (null nearest) (> (car candidate) (car nearest))))
              (setq nearest candidate))
            (when (or (null first) (< (car candidate) (car first)))
              (setq first candidate))))
        ;; A position before the first run, such as the page margin, names the
        ;; start of the source rather than nothing at all.
        (cond (nearest (nth 3 nearest))
              (first (nth 2 first)))))))

;;;###autoload
(defun etaf-projection-position (projection offset)
  "Return the painted position where source OFFSET lives, or nil.
An offset inside a run maps to its cell; an offset the paint skipped, such as
a marker the render folded away, maps to the start of the next run."
  (let ((run (etaf--projection-find projection 2 3 offset)))
    (if run
        (min (nth 1 run) (+ (car run) (- offset (nth 2 run))))
      (let ((next nil) (previous nil))
        (dotimes (index (length projection))
          (let ((candidate (aref projection index)))
            (when (and (>= (nth 2 candidate) offset)
                       (or (null next) (< (nth 2 candidate) (nth 2 next))))
              (setq next candidate))
            (when (<= (nth 3 candidate) offset)
              (setq previous candidate))))
        (cond (next (car next))
              ;; An offset at or past the end of the last run names the end of
              ;; the source, so its caret sits after the final painted cell.
              (previous (nth 1 previous)))))))

(provide 'etaf-projection)

;;; etaf-projection.el ends here
