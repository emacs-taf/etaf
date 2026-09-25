;;; performance-scenarios.el --- ETAF runtime interaction workloads -*- lexical-binding: t; -*-

;;; Commentary:
;; Adapters for the workspace performance driver (scripts/performance.py).
;; The retained resize scenarios keep the same two-panel native scene for
;; ordinary Ebox publication, prepared Ebox geometry and full ETAF reactive
;; publication.  This is fixed text cropping, not the catalog window or
;; paragraph reflow.  The driver measures invocation through publication and
;; forced redisplay.

;;; Code:
(require 'cl-lib)
(require 'etaf)
(require 'ebox)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defun etaf-resize-benchmark--view (width height)
  "Build the same native scene with dynamic WIDTH and HEIGHT."
  (etaf-view
   (box :width '(px 640) :height '(lh 24) :position 'relative :background-color "#EAF0F6"
     (box :id "crop" :ref 'crop :position 'absolute :left '(px 16) :top '(lh 2)
          :width (if (etaf-ref-p width) (etaf-value width) width)
          :height (if (etaf-ref-p height) (etaf-value height) height)
          :min-width '(px 0) :min-height '(lh 0) :z-index 2
          :overflow 'hidden :wrap-mode 'none :background-color "#243447" :color "#F1F5F9"
          :role 'button :tab-index 0 :on-press #'ignore
       (text "Fixed native text: ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789\nSecond row stays unchanged.\n第三行：裁剪与恢复。"))
     (box :id "peer" :ref 'peer :position 'absolute :left '(px 300) :top '(lh 8)
          :width '(px 160) :height '(lh 5) :z-index 1 :background-color "#705070"
       (text "Independent peer\nRestored after shrink")))))

(defun etaf-resize-benchmark--fresh-p (buffer)
  "Check BUFFER's accepted text and native properties against a fresh render."
  (with-current-buffer buffer
    (let* ((actual (buffer-string))
           (expected (ebox-render (plist-get (ebox-surface-buffer-snapshot buffer) :input)))
           (same (equal (substring-no-properties actual) (substring-no-properties expected)))
           (position 0))
      (while (and same (< position (length actual)))
        (dolist (property '(face display font-lock-face keymap pointer help-echo mouse-face))
          (unless (equal (get-text-property position property actual)
                         (get-text-property position property expected))
            (setq same nil)))
        (setq position (1+ position)))
      same)))

(defun etaf-resize-benchmark--fixture (route axis)
  "Create matched native output for ROUTE and resize AXIS."
  (let* ((buffer (generate-new-buffer " *ETAF retained resize benchmark*"))
         (width (etaf-ref '(px 320) :test #'equal))
         (height (etaf-ref '(lh 8) :test #'equal))
         (values (vector '(px 320) '(lh 8)))
         (step 0) expected revision runtime operation prepared-p)
    (if (eq route 'runtime)
        (progn (etaf-mount buffer (etaf-resize-benchmark--view width height))
               (setq runtime (etaf-runtime-for-buffer buffer)))
      (ebox-render-to-buffer buffer
                            (etaf-render (etaf-resize-benchmark--view '(px 320) '(lh 8)))))
    (list
     :buffer buffer
     :environment (lambda () (list :route (symbol-name route) :axis (symbol-name axis)
                                   :canvas-width 640 :canvas-height 24
                                   :body-reflow :false :physical-pointer-latency-certified :false))
     :ready
     (lambda ()
       (unless prepared-p
         (when (eq route 'prepared)
           (setq operation (ebox-geometry-prepare buffer "crop" [:width :height]))
           (unless operation (error "Fixed crop geometry was not admitted")))
         (setq prepared-p t))
       t)
     :prepare
     (lambda ()
       (setq step (1+ step)
             expected (if (cl-oddp step)
                          (list (if (eq axis 'height) 320 352)
                                (if (eq axis 'width) 8 10))
                        '(320 8))
             revision (ebox-surface-buffer-revision buffer))
       (setcar (cdr (aref values 0)) (car expected))
       (setcar (cdr (aref values 1)) (cadr expected)))
     :invoke
     (lambda (_sample)
       (pcase route
         ('prepared (unless (ebox-geometry-apply operation values)
                      (error "Prepared resize declined")))
         ('runtime
          (etaf-batch
            (etaf-set-value width (list 'px (car expected)))
            (etaf-set-value height (list 'lh (cadr expected))))
          (etaf-runtime-flush runtime))
         (_ (with-current-buffer buffer
              (ebox-region-update-geometry "crop" :width (aref values 0) :height (aref values 1))))))
     :verify
     (lambda ()
       (and (= (1+ revision) (ebox-surface-buffer-revision buffer))
            (with-current-buffer buffer
              (let ((geometry (ebox-region-geometry "crop")))
                (and (equal (plist-get geometry :width) (aref values 0))
                     (equal (plist-get geometry :height) (aref values 1)))))
            (or (null runtime)
                (and (eq 'prepared-update (plist-get (ebox-buffer-update-report buffer) :projection-kind))
                     (etaf-host-ref-position runtime 'crop)
                     (equal (plist-get (etaf-runtime-host-props-for runtime 'crop) :width)
                            (etaf-value width))))
            (etaf-resize-benchmark--fresh-p buffer)))
     :outcome (lambda () (list :route (symbol-name route) :size (vconcat expected)
                               :revision (ebox-surface-buffer-revision buffer)
                               :projection (format "%s" (plist-get (ebox-buffer-update-report buffer) :projection-kind))))
     :observe (lambda (sink) (ebox-buffer-set-observer buffer sink)
                (lambda () (ebox-buffer-set-observer buffer nil)))
     :cleanup (lambda ()
                (when runtime (etaf-unmount runtime))
                (when (buffer-live-p buffer) (kill-buffer buffer))))))

(dolist (route '(ordinary prepared runtime))
  (dolist (axis '(width height corner))
    (let ((selected-route route) (selected-axis axis))
      (taf-benchmark-register
       (format "retained.resize.%s.%s" route axis)
       :version 1 :modes '(batch gui) :isolation 'series :required-providers '(ebox)
       :budget-ms 10 :impact 'local
       :description (format "Two native panels, fixed text %s crop via %s" axis route)
       :setup (lambda (_mode) (etaf-resize-benchmark--fixture selected-route selected-axis))))))

(defun etaf-resize-benchmark--native-fixture (sweep)
  "Exercise the mounted example's native input, optionally with a broad SWEEP."
   (let* ((buffer (etaf-retained-resize-open
                   (generate-new-buffer " *ETAF native resize benchmark*")))
          (runtime (etaf-runtime-for-buffer buffer))
          (step 0) expected events)
     (list
      :buffer buffer
      :environment (lambda () (list :input-route "native-keymap" :motion-queue "prequeued"
                                    :motion-count 1 :body-reflow :false
                                    :physical-pointer-latency-certified :false))
      :prepare
      (lambda ()
        (redisplay t)
        (let* ((window (get-buffer-window buffer t))
               (position (etaf-host-ref-position runtime 'resize-panel))
               (start (and position (posn-at-point position window)))
               (xy (and start (posn-x-y start)))
               (sign (if (if sweep (< (mod (1- (cl-incf step)) 16) 8)
                           (cl-oddp (cl-incf step))) 1 -1))
               (props (etaf-runtime-host-props-for runtime 'resize-panel))
               (dx (* sign (if sweep 32 8)))
               (dy (* sign (frame-char-height (window-frame window)))))
          (when (and sweep xy)
            ;; This example resizes from any painted body position. Use a
            ;; visible text cell with room for a negative movement, not the
            ;; leading position of a stretched trailing fill cell.
            (setq start (posn-at-x-y (+ (car xy) 48)
                                     (+ (cdr xy) 2) window)
                  xy (and start (posn-x-y start))
                  position (and start (posn-point start))))
          (unless (and (eq window (selected-window)) (consp xy)
                       (pos-visible-in-window-p position window))
            (error "Native resize example target is not visibly selected"))
          (setq expected (list (+ (cadr (plist-get props :width)) dx)
                               (+ (cadr (plist-get props :height)) sign)))
          (let ((end (list window position (cons (+ (car xy) dx) (+ (cdr xy) dy)) 2)))
            (setq events (vector (list 'down-mouse-1 start)
                                 (list 'mouse-movement end)
                                 (list 'drag-mouse-1 start end))))))
      :invoke (lambda (_sample) (execute-kbd-macro events) (etaf-runtime-flush runtime))
      :verify
      (lambda ()
        (let ((props (etaf-runtime-host-props-for runtime 'resize-panel)))
          (and (equal expected (list (cadr (plist-get props :width))
                                     (cadr (plist-get props :height))))
               (etaf-host-ref-position runtime 'resize-panel)
               (not (ebox-selector-query-buffer buffer ":active"))
               (etaf-resize-benchmark--fresh-p buffer))))
      :outcome (lambda () (list :size (vconcat expected)
                                :projection (format "%s" (plist-get (ebox-buffer-update-report buffer)
                                                                    :projection-kind))))
      :observe (lambda (sink) (ebox-buffer-set-observer buffer sink)
                 (lambda () (ebox-buffer-set-observer buffer nil)))
      :cleanup (lambda () (etaf-unmount runtime)
                 (when (buffer-live-p buffer) (kill-buffer buffer))))))

(dolist (sweep '(nil t))
  (let ((selected sweep))
    (taf-benchmark-register
     (if sweep "retained.resize.native.sweep" "retained.resize.native.corner")
     :version 1 :modes '(gui) :isolation 'series :required-providers '(ebox)
     :budget-ms 10 :impact 'local
     :description (if sweep "Native example resizing from 320x8 to 576x16 and back"
                    "Mounted resize example through native press, movement and release")
     :setup (lambda (_mode) (etaf-resize-benchmark--native-fixture selected)))))

;;; performance-scenarios.el ends here
