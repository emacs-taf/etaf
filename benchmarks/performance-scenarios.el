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

;;; ---------------------------------------------------------------------------
;;; One row's update must not scale with the scene
;;; ---------------------------------------------------------------------------

;; A fixed-height row whose paint and weight change is the smallest possible
;; update; it must cost about the same in a 30-row and a 400-row scene.  The
;; scenario gates the complete incremental commit, not just native layout.
;; Unchanged layout and publication metadata must remain retained: expanding
;; or validating the whole frame can dominate even a dirty-owner layout.

(etaf-define-component etaf-row-update-benchmark--probe (&key rows marked)
  "Render ROWS fixed-height rows; row 1's paint follows MARKED."
  :view
  (column :width 'stretch :item-gap '(lh 0)
    (box :for (row (number-sequence 1 rows)) :key row
         :height '(lh 1) :overflow 'hidden
         :bgcolor (if (and (equal row 1) (etaf-value marked))
                      "#1A2436" "#223344")
         :font-weight (if (and (equal row 1) (etaf-value marked)) 'bold 'normal)
         (text (expr (format "row %04d 汉字 ABC abcdefghijklmnopqrstuvwxyz" row))))))

(defun etaf-row-update-benchmark--bold-p (face)
  "Return non-nil when FACE carries a bold weight."
  (let ((faces (if (and (consp face) (keywordp (car face))) (list face) face)))
    (cl-some (lambda (entry) (eq (plist-get entry :weight) 'bold))
             (if (listp faces) faces nil))))

(defun etaf-row-update-benchmark--fixture (rows _mode)
  "Mount ROWS fixed-height rows and toggle one row's style per sample.
The runtime stays mounted until the driver calls the returned `:cleanup'."
  (let* ((buffer (generate-new-buffer (format " *TAF row update %s*" rows)))
         (marked (etaf-ref t :name 'etaf-row-update-marked))
         (runtime nil))
    (with-current-buffer buffer (setq-local truncate-lines t))
    (etaf-mount buffer
                (etaf-view (etaf-row-update-benchmark--probe
                            :rows rows :marked marked))
                (list :viewport-width 1200 :viewport-height 40))
    (setq runtime (etaf-runtime-for-buffer buffer))
    (etaf-runtime-flush runtime)
    (list
     :buffer buffer
     :invoke (lambda (_sample)
               (etaf-set-value marked (not (etaf-value marked)))
               (etaf-runtime-flush runtime))
     :verify
     (lambda ()
       (with-current-buffer buffer
         (let* ((position (+ (point-min) (string-match "row 0001" (buffer-string))))
                (bold (etaf-row-update-benchmark--bold-p
                       (get-text-property position 'face))))
           (if (eq bold (not (null (etaf-value marked)))) t
             (format "Row 1 bold=%s while marked=%s"
                     bold (etaf-value marked))))))
     :observe
     (lambda (sink)
       (etaf-performance-start runtime)
       (let ((before (mapcar (lambda (operation)
                              (cons (plist-get operation :runtime-id)
                                    (plist-get operation :id)))
                            (plist-get (etaf-performance-report-data) :operations))))
         (lambda ()
           (etaf-performance-stop runtime)
           (dolist (operation (plist-get (etaf-performance-report-data) :operations))
             (when (and (equal (plist-get operation :buffer-name) (buffer-name buffer))
                        (not (member (cons (plist-get operation :runtime-id)
                                           (plist-get operation :id)) before)))
               (dolist (stage (plist-get operation :stages))
                 (funcall sink
                          (append (list :provider (plist-get stage :provider)
                                        :stage (plist-get stage :stage)
                                        :duration-ms (plist-get stage :duration-ms))
                                  (plist-get stage :metadata)))))))))
     :cleanup
     (lambda ()
       (when (buffer-live-p buffer)
         (when (etaf-runtime-for-buffer buffer) (etaf-unmount runtime))
         (kill-buffer buffer))))))

(dolist (rows '(30 120 400))
  (let ((count rows))
    (taf-benchmark-register
     (format "row-update.%s" count)
     :version 1 :modes '(batch) :isolation 'series
     :required-providers '(etaf ebox)
     :impact 'local :budget-ms 10
     :description
     (format "One row's paint and weight toggle in a %d-row fixed-height scene; the cost must not scale with the scene"
             count)
     :setup (lambda (_mode) (etaf-row-update-benchmark--fixture count nil)))))

;; A keyed list append must cost like a one-row change.  The native retained
;; patch path proves equal-length replacements only, so an inserted row falls
;; back to re-encoding the whole frame; these scenarios guard the incremental
;; path for growing lists.

(etaf-define-component etaf-list-append-benchmark--probe (&key rows)
  "Render ROWS one-line rows keyed by their number."
  :view
  (column :width 'stretch :item-gap '(lh 0)
    (box :for (row (etaf-value rows)) :key row
         :height '(lh 1) :overflow 'hidden
         (text (expr (format "row %04d 汉字 ABC abcdefghijklmnopqrstuvwxyz" row))))))

(defun etaf-list-append-benchmark--fixture (rows _mode)
  "Mount ROWS keyed rows and append one row per sample.
The runtime stays mounted until the driver calls the returned `:cleanup'."
  (let* ((buffer (generate-new-buffer (format " *TAF list append %s*" rows)))
         (rows-ref (etaf-ref (number-sequence 1 rows) :name 'etaf-list-append-rows))
         (appended 0)
         runtime)
    (with-current-buffer buffer (setq-local truncate-lines t))
    (etaf-mount buffer
                (etaf-view (etaf-list-append-benchmark--probe :rows rows-ref))
                (list :viewport-width 1200 :viewport-height 40))
    (setq runtime (etaf-runtime-for-buffer buffer))
    (etaf-runtime-flush runtime)
    (list
     :buffer buffer
     :environment (lambda () (list :rows rows :viewport-rows 40))
     :invoke (lambda (_sample)
               (cl-incf appended)
               (etaf-set-value rows-ref
                               (append (etaf-value rows-ref)
                                       (list (+ rows appended))))
               (etaf-runtime-flush runtime))
     :verify
     (lambda ()
       (with-current-buffer buffer
         (let ((newest (format "row %04d" (+ rows appended))))
           (if (string-match-p newest (buffer-substring-no-properties
                                       (point-min) (point-max)))
               t
             (format "appended %s is not published" newest)))))
     :observe
     (lambda (sink)
       (etaf-performance-start runtime)
       (let ((before (mapcar (lambda (operation)
                               (cons (plist-get operation :runtime-id)
                                     (plist-get operation :id)))
                             (plist-get (etaf-performance-report-data) :operations))))
         (lambda ()
           (etaf-performance-stop runtime)
           (dolist (operation (plist-get (etaf-performance-report-data) :operations))
             (when (and (equal (plist-get operation :buffer-name) (buffer-name buffer))
                        (not (member (cons (plist-get operation :runtime-id)
                                           (plist-get operation :id)) before)))
               (dolist (stage (plist-get operation :stages))
                 (funcall sink
                          (append (list :provider (plist-get stage :provider)
                                        :stage (plist-get stage :stage)
                                        :duration-ms (plist-get stage :duration-ms))
                                  (plist-get stage :metadata)))))))))
     :cleanup
     (lambda ()
       (when (buffer-live-p buffer)
         (when (etaf-runtime-for-buffer buffer) (etaf-unmount runtime))
         (kill-buffer buffer))))))

(dolist (rows '(30 120))
  (let ((count rows))
    (taf-benchmark-register
     (format "list-append.%s" count)
     :version 1 :modes '(batch) :isolation 'series
     :required-providers '(etaf ebox)
     :impact 'local :budget-ms 10
     :description
     (format "Append one keyed row to a %d-row list; the cost must not scale with the list"
             count)
     :setup (lambda (_mode) (etaf-list-append-benchmark--fixture count nil)))))

;;; performance-scenarios.el ends here

;;; ---------------------------------------------------------------------------
;;; Retained Host content frames
;;; ---------------------------------------------------------------------------

(defconst etaf-video-frame-benchmark--ramp " .:-=+*#%@"
  "Density ramp used by the ASCII video application.")

(defun etaf-video-frame-benchmark--frame (columns rows index)
  "Return a deterministic video-like frame of COLUMNS by ROWS ramp cells.
INDEX moves the pattern so consecutive invocations publish different text."
  (let ((ramp etaf-video-frame-benchmark--ramp)
        (last (1- (length etaf-video-frame-benchmark--ramp)))
        (lines nil))
    (dotimes (row rows)
      (let ((line (make-string columns ?\s)))
        (dotimes (column columns)
          (let* ((phase (mod (+ (* 3 column) (* 7 index) (* 13 row)) 256))
                 (level (max 0 (min last (/ (+ (* phase last) 127) 255)))))
            (aset line column (aref ramp level))))
        (push line lines)))
    (mapconcat #'identity (nreverse lines) "\n")))

(defun etaf-video-frame-benchmark--fixture (columns rows _mode)
  "Mount a fixed COLUMNS by ROWS canvas and publish frame texts.
The fixture is steady state: one retained Host text update per sample, and no
layout, style or interaction change."
  (let* ((buffer (generate-new-buffer
                  (format " *TAF video frame %dx%d*" columns rows)))
         (frames (cl-loop for index below 32
                          collect (etaf-video-frame-benchmark--frame columns rows index)))
         (index 0)
         (expected nil)
         runtime)
    (with-current-buffer buffer (setq-local truncate-lines t))
    (etaf-mount buffer
                (etaf-view
                 (flex :flex-direction 'column :width (list 'ch columns)
                       (box :width (list 'ch columns) :height (list 'lh rows)
                            :wrap-mode 'none :overflow 'hidden
                            (text :id "grid" :ref 'grid " "))
                       (box :height '(lh 1)
                            (text :id "hud" :ref 'hud "hud"))))
                (list :viewport-width 1200 :viewport-height (+ rows 4)))
    (setq runtime (etaf-runtime-for-buffer buffer))
    (etaf-runtime-flush runtime)
    (list
     :buffer buffer
     :environment (lambda ()
                    (list :columns columns :rows rows :chars (* columns rows)
                          :frames (length frames)))
     :invoke (lambda (_sample)
               (setq expected (nth (% index (length frames)) frames)
                     index (1+ index))
               (etaf-runtime-update-host-contents
                runtime (list (cons 'grid expected))))
     :verify
     (lambda ()
       (with-current-buffer buffer
         (let* ((actual (substring-no-properties (buffer-string)))
                (first (car (split-string expected "\n"))))
           (if (string-prefix-p first actual) t
             (format "Published first row differs for frame %d" (1- index))))))
     :observe (lambda (sink) (ebox-buffer-set-observer buffer sink)
                (lambda () (ebox-buffer-set-observer buffer nil)))
     :cleanup
     (lambda ()
       (when (buffer-live-p buffer)
         (when (etaf-runtime-for-buffer buffer) (etaf-unmount runtime))
         (kill-buffer buffer))))))

(dolist (size '((160 . 45) (96 . 27)))
  (let ((columns (car size))
        (rows (cdr size)))
    (taf-benchmark-register
     (format "host-content.video-frame.%dx%d" columns rows)
     :version 1 :modes '(batch gui) :isolation 'series
     :required-providers '(ebox)
     :impact 'local :budget-ms 33
     :description
     (format "One video-like frame (%d ramp cells) as a retained Host text update; the cost must fit a 30 fps frame budget"
             (* columns rows))
     :setup (lambda (_mode) (etaf-video-frame-benchmark--fixture columns rows nil)))))
