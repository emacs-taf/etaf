;;; etaf-performance.el --- Cross-package ETAF performance records -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This opt-in recorder follows one user-visible ETAF operation through the
;; reactive, data, Ebox, and TP layers.  Other packages remain independent:
;; instrumentation is attached here, after those packages are loaded.

;;; Code:

(require 'cl-lib)
(require 'pp)
(require 'ring)
(require 'seq)
(require 'tabulated-list)

(defgroup etaf-performance nil
  "Operation and stage timing for ETAF applications."
  :group 'etaf)

(defcustom etaf-performance-max-records 200
  "Maximum completed operations retained by the recorder."
  :type 'integer
  :group 'etaf-performance)

(defconst etaf-performance-report-format-version 1
  "Current portable performance report format version.")

(cl-defstruct (etaf-performance-stage
               (:constructor etaf-performance--stage-create))
  "One timed stage inside an ETAF operation.
All duration fields are milliseconds."
  id category function detail depth start-time end-time inclusive exclusive
  status)

(cl-defstruct (etaf-performance-operation
               (:constructor etaf-performance--operation-create))
  "One bounded, user-visible ETAF operation record.
ELAPSED is milliseconds; START-TIME and END-TIME are wall-clock seconds."
  id parent-id kind label runtime-id buffer-name generation-before generation-after
  start-time end-time elapsed status
  gc-count-before gc-count-after gc-elapsed-before gc-elapsed-after metadata
  stages)

(cl-defstruct (etaf-performance--stage-frame
               (:constructor etaf-performance--stage-frame-create))
  id category function detail depth start-time (child-time 0.0))

(defvar etaf-performance--record-ring nil)
(defvar etaf-performance--next-operation-id 0)
(defvar etaf-performance--next-stage-id 0)
(defvar etaf-performance--current-operation nil)
(defvar etaf-performance--stage-stack nil)
(defvar etaf-performance--installed-advices nil)
(defvar etaf-performance-mode nil)

(defconst etaf-performance--operation-functions
  '((etaf-dispatch-event event)
    (etaf-dispatch action)
    (etaf-runtime-mount mount)
    (etaf-runtime-flush flush)
    (etaf-runtime-unmount unmount)
    (etaf-data-load data-load)
    (etaf-data-source-load-page data-prepare)
    (etaf-data-mutate data-mutate)
    (etaf-resource-load resource-load)
    (ebox-surface-update-buffer-viewport viewport)
    (ebox-rerender-buffer-with-context rerender)
    (etaf-focus focus)
    (etaf-focus-next focus)
    (etaf-focus-previous focus)
    (etaf-activate activate)
    (etaf-activate-mouse activate))
  "Coarse functions that begin visible operation records.")

(defvar etaf-performance--stage-functions
  '((etaf--runtime-component-overlay runtime owner-overlay)
    (etaf--runtime-render-root-turn runtime root-turn)
    (etaf--runtime-build-generation runtime generation)
    (etaf--runtime-render-dirty-component runtime component-effect)
    (etaf--runtime-render-dirty-host-properties runtime host-property-effect)
    (etaf--runtime-render-dirty-range runtime range-effect)
    (etaf--runtime-render-dirty-inline-range runtime inline-range-effect)
    (etaf--runtime-render-dirty-slot-range runtime slot-range-effect)
    (etaf-compiler-instantiate compiler blueprint-instantiate)
    (etaf-sqlite--call sqlite call)
    (etaf-sqlite--transaction sqlite transaction)
    (etaf-sqlite--select-items sqlite query)
    (etaf-sqlite--mutate sqlite mutate)
    (ebox-incremental-consume-candidate ebox candidate)
    (ebox-incremental--prepare-logical-candidate ebox candidate-preparation)
    (ebox-incremental--candidate-logical-root ebox candidate-root)
    (ebox-incremental--candidate-local-index-delta ebox index-delta)
    (ebox-incremental--candidate-copy-index-table ebox index-table-copy)
    (ebox-incremental--candidate-dirty-set-from-touched ebox dirty-diff)
    (ebox-incremental--candidate-map-native-postorder ebox native-postorder)
    (ebox-incremental--candidate-range-ref-overlay ebox range-index)
    (ebox-incremental--candidate-structural-caches ebox structural-cache)
    (ebox-incremental--prepare-declarative-runtime ebox runtime-preparation)
    (ebox-incremental--candidate-layout-snapshots ebox snapshot-seed)
    (ebox-incremental--candidate-state ebox candidate-state)
    (ebox-incremental--surface-commit-input ebox owner-proof)
    (ebox-incremental--mixed-owner-proof ebox mixed-owner-proof)
    (ebox-incremental--formatting-context-reflow-proof ebox context-proof)
    (ebox-incremental--common-runtime-ancestor-id ebox common-ancestor)
    (ebox-incremental--formatting-context-reflow-fast-eligible-p
     ebox context-eligibility)
    (ebox-incremental--cached-layout-snapshot-details ebox snapshot-details)
    (ebox-incremental--layout-owner-plan ebox owner-plan)
    (ebox-incremental--span-patch-projection-proof ebox span-proof)
    (ebox-incremental--allocation-closure-proof ebox allocation-proof)
    (ebox-incremental--two-owner-allocation-proof ebox allocation-union-proof)
    (ebox-surface--cascade-local-owner-proof-p ebox cascade-proof)
    (ebox-incremental--layout-owner-report ebox owner-report)
    (ebox-incremental--surface-state-overrides ebox state-overrides)
    (ebox-surface-update-buffer-scoped ebox scoped-publication)
    (ebox-surface--project ebox projection)
    (ebox-surface--projection-start ebox projection-start)
    (ebox-surface--style-state-table ebox style-state-copy)
    (ebox-tree-subject-index ebox selector-subject-index)
    (ebox-surface--project-native-stable-node-table ebox native-object-reuse)
    (ebox-surface--mixed-owner-output ebox mixed-owner-output)
    (ebox-surface--rendered-fragments ebox fragments)
    (ebox-surface--render-candidate ebox candidate-render)
    (ebox-surface--surface-plan ebox surface-plan)
    (ebox-surface--native-patch-result ebox native-patch-result)
    (ebox-native-commit-render ebox native-commit)
    (ebox-native-commit-context-axes-stable-p ebox native-axes-proof)
    (ebox-native-commit--apply-fragment-style-delta
     ebox fragment-style-delta)
    (ebox-native-reflow--compile-layout-package compiler layout-ir)
    (ebox-native-reflow--compile-retained-layout-package
     compiler retained-layout-ir)
    (ebox-native-reflow--materialize-layout-tape ebox tape-decode)
    (ebox-surface--native-owned-ranges ebox native-ownership)
    (ebox-surface--owned-ranges ebox ownership-ranges)
    (ebox-commit ebox commit)
    (ebox-render-to-buffer ebox render-to-buffer)
    (tp-surface-update-scoped tp scoped-update)
    (tp-object-reuse-subtree tp object-subtree-reuse)
    (tp--prepare-surface tp prepare)
    (tp-commit-batch-result-create tp batch-result)
    (tp--prepare-commit-batch tp prepare-batch)
    (tp--commit-batch-retained-mount-state tp mount-proof)
    (tp--retain-candidate-mount-state tp retain-mounts)
    (tp--validate-retained-batch-precommit tp retained-precommit)
    (tp--publish-one-surface tp publication))
  "Cross-package coarse stages installed only while recording is enabled.")

(defun etaf-performance-records ()
  "Return a newest-first copy of completed performance records."
  (if etaf-performance--record-ring
      (ring-elements etaf-performance--record-ring)
    nil))

(defun etaf-performance--percentile (samples percentile)
  "Return nearest-rank PERCENTILE from numeric SAMPLES."
  (when samples
    (let* ((ordered (sort (copy-sequence samples) #'<))
           (rank (max 1 (ceiling (* percentile (length ordered))))))
      (nth (1- rank) ordered))))

;;;###autoload
(defun etaf-performance-operation-stage-summary (operation)
  "Return stage-category timing summaries for OPERATION.

Each result plist contains `:category', `:count', `:inclusive-ms', and
`:exclusive-ms'.  Results are sorted by decreasing exclusive time.  Inclusive
totals may overlap because they preserve nested span semantics; exclusive
totals partition the recorded work."
  (unless (etaf-performance-operation-p operation)
    (signal 'wrong-type-argument
            (list 'etaf-performance-operation-p operation)))
  (let ((table (make-hash-table :test #'eq)) result)
    (dolist (stage (etaf-performance-operation-stages operation))
      (let* ((category (etaf-performance-stage-category stage))
             (value (or (gethash category table) (vector 0 0.0 0.0))))
        (aset value 0 (1+ (aref value 0)))
        (aset value 1 (+ (aref value 1)
                         (etaf-performance-stage-inclusive stage)))
        (aset value 2 (+ (aref value 2)
                         (etaf-performance-stage-exclusive stage)))
        (puthash category value table)))
    (maphash
     (lambda (category value)
       (push (list :category category :count (aref value 0)
                   :inclusive-ms (aref value 1)
                   :exclusive-ms (aref value 2))
             result))
     table)
    (sort result
          (lambda (left right)
            (> (plist-get left :exclusive-ms)
               (plist-get right :exclusive-ms))))))

;;;###autoload
(defun etaf-performance-summary (&optional records)
  "Summarize completed RECORDS by operation kind and label.

RECORDS defaults to `etaf-performance-records'.  Each result plist contains
`:kind', `:label', `:count', `:min-ms', `:p50-ms', `:p95-ms', `:max-ms', and
`:mean-ms'.  Summary calculation happens on demand, never in the measured hot
path."
  (let ((groups (make-hash-table :test #'equal)) result)
    (dolist (operation (or records (etaf-performance-records)))
      (let ((key (cons (etaf-performance-operation-kind operation)
                       (etaf-performance-operation-label operation))))
        (puthash key
                 (cons (etaf-performance-operation-elapsed operation)
                       (gethash key groups))
                 groups)))
    (maphash
     (lambda (key samples)
       (push
        (list :kind (car key) :label (cdr key) :count (length samples)
              :min-ms (apply #'min samples)
              :p50-ms (etaf-performance--percentile samples 0.50)
              :p95-ms (etaf-performance--percentile samples 0.95)
              :max-ms (apply #'max samples)
              :mean-ms (/ (apply #'+ samples) (float (length samples))))
        result))
     groups)
    (sort result
          (lambda (left right)
            (> (plist-get left :p95-ms) (plist-get right :p95-ms))))))

(defun etaf-performance--stage-report-data (stage)
  "Return portable report data for performance STAGE."
  (list :id (etaf-performance-stage-id stage)
        :category (etaf-performance-stage-category stage)
        :function (etaf-performance-stage-function stage)
        :detail (etaf-performance-stage-detail stage)
        :depth (etaf-performance-stage-depth stage)
        :inclusive-ms (etaf-performance-stage-inclusive stage)
        :exclusive-ms (etaf-performance-stage-exclusive stage)
        :status (etaf-performance-stage-status stage)))

(defun etaf-performance--operation-report-data (operation)
  "Return portable report data for performance OPERATION."
  (list
   :id (etaf-performance-operation-id operation)
   :parent-id (etaf-performance-operation-parent-id operation)
   :kind (etaf-performance-operation-kind operation)
   :label (etaf-performance-operation-label operation)
   :runtime-id (etaf-performance-operation-runtime-id operation)
   :buffer-name (etaf-performance-operation-buffer-name operation)
   :generation-before
   (etaf-performance-operation-generation-before operation)
   :generation-after
   (etaf-performance-operation-generation-after operation)
   :started-at
   (format-time-string "%Y-%m-%dT%H:%M:%S%z"
                       (seconds-to-time
                        (etaf-performance-operation-start-time operation)))
   :elapsed-ms (etaf-performance-operation-elapsed operation)
   :status (etaf-performance-operation-status operation)
   :gc-count-delta
   (- (etaf-performance-operation-gc-count-after operation)
      (etaf-performance-operation-gc-count-before operation))
   :gc-elapsed-ms
   (* 1000.0
      (- (etaf-performance-operation-gc-elapsed-after operation)
         (etaf-performance-operation-gc-elapsed-before operation)))
   :metadata (copy-tree (etaf-performance-operation-metadata operation))
   :stage-summary (etaf-performance-operation-stage-summary operation)
   :stages
   (mapcar #'etaf-performance--stage-report-data
           (etaf-performance-operation-stages operation))))

(defun etaf-performance--parse-darwin-power-state
    (battery-output custom-output)
  "Return normalized macOS power state from PMSET outputs.
BATTERY-OUTPUT identifies the active source; CUSTOM-OUTPUT contains settings."
  (let* ((source
          (cond
           ((string-match-p "Battery Power" (or battery-output "")) 'battery)
           ((string-match-p "AC Power" (or battery-output "")) 'ac)
           (t 'unknown)))
         (target-heading
          (pcase source ('battery "Battery Power") ('ac "AC Power") (_ nil)))
         active low-power)
    (dolist (line (split-string (or custom-output "") "\n" t))
      (cond
       ((string-match "^\\(.+ Power\\):[[:space:]]*$" line)
        (setq active (and target-heading
                          (string= (match-string 1 line) target-heading))))
       ((and active
             (string-match
              "^[[:space:]]*lowpowermode[[:space:]]+\\([01]\\)" line))
        (setq low-power (if (string= (match-string 1 line) "1")
                            'on 'off)))))
    (list :source source :low-power-mode (or low-power 'unknown))))

(defun etaf-performance--command-output (program &rest arguments)
  "Return PROGRAM output for ARGUMENTS, or nil on failure."
  (when program
    (with-temp-buffer
      (let ((default-directory temporary-file-directory))
        (when (eq 0 (apply #'call-process program nil t nil arguments))
          (buffer-string))))))

(defun etaf-performance--power-state ()
  "Return a portable local power-state snapshot."
  (if (not (eq system-type 'darwin))
      (list :source 'unknown :low-power-mode 'unknown)
    (let ((pmset (executable-find "pmset")))
      (if (not pmset)
          (list :source 'unknown :low-power-mode 'unknown)
        (etaf-performance--parse-darwin-power-state
         (etaf-performance--command-output pmset "-g" "batt")
         (etaf-performance--command-output pmset "-g" "custom"))))))

(defun etaf-performance-environment-data ()
  "Return the environment snapshot used to interpret latency records."
  (list :emacs-version emacs-version
        :system-type system-type
        :window-system window-system
        :graphic-display (display-graphic-p)
        :frame-pixel-size
        (list (frame-pixel-width) (frame-pixel-height))
        :window-body-pixel-size
        (list (window-body-width nil t) (window-body-height nil t))
        :gc-cons-threshold gc-cons-threshold
        :gc-cons-percentage gc-cons-percentage
        :load-average (load-average t)
        :power-state (etaf-performance--power-state)))

;;;###autoload
(defun etaf-performance-report-data (&optional records)
  "Return a portable report for completed performance RECORDS.

RECORDS defaults to `etaf-performance-records'.  Operations are returned in
capture order, oldest first.  The report contains only plain Lisp data so it
can be copied, saved, and read in another Emacs process."
  (let ((records (or records (etaf-performance-records))))
    (list
     :format-version etaf-performance-report-format-version
     :generated-at (format-time-string "%Y-%m-%dT%H:%M:%S%z")
     :environment (etaf-performance-environment-data)
     :summary (etaf-performance-summary records)
     :operations
     (mapcar #'etaf-performance--operation-report-data
             (reverse (copy-sequence records))))))

;;;###autoload
(defun etaf-performance-report-string (&optional records)
  "Return completed performance RECORDS as a readable report string."
  (concat ";; ETAF performance report\n"
          (pp-to-string (etaf-performance-report-data records))))

;;;###autoload
(defun etaf-performance-copy-report ()
  "Copy all retained performance records to the kill ring."
  (interactive)
  (let* ((record-count (length (etaf-performance-records)))
         (report (etaf-performance-report-string)))
    (kill-new report)
    (message "Copied %d ETAF performance operation%s"
             record-count (if (= 1 record-count) "" "s"))
    report))

;;;###autoload
(defun etaf-performance-export (file)
  "Export all retained performance records to FILE.

When called interactively, suggest a timestamped `.eld' file in
`default-directory'.  Refuse to overwrite an existing file."
  (interactive
   (list
    (read-file-name
     "Export ETAF performance report: " nil
     (expand-file-name
      (format "etaf-performance-%s.eld"
              (format-time-string "%Y%m%d-%H%M%S"))
      default-directory))))
  (let* ((record-count (length (etaf-performance-records)))
         (report (etaf-performance-report-string)))
    (write-region report nil file nil 'silent nil 'excl)
    (message "Exported %d ETAF performance operations to %s"
             record-count (abbreviate-file-name file))
    file))

(defun etaf-performance-clear ()
  "Clear all completed performance records."
  (interactive)
  ;; Keep correlation IDs monotonic even if an active operation clears history.
  (setq etaf-performance--record-ring nil)
  (when-let* ((panel (get-buffer "*ETAF Performance*")))
    (with-current-buffer panel
      (when (derived-mode-p 'etaf-performance-panel-mode)
        (tabulated-list-revert))))
  nil)

(defun etaf-performance--now ()
  "Return a wall-clock timestamp as floating-point seconds."
  (float-time))

(defun etaf-performance--runtime-p (value)
  "Return non-nil when VALUE is an ETAF Runtime."
  (and (fboundp 'etaf-runtime-p) (etaf-runtime-p value)))

(defun etaf-performance--runtime-for-buffer (buffer)
  "Return the Runtime mounted in BUFFER, without signaling."
  (and buffer (fboundp 'etaf-runtime-for-buffer)
       (ignore-errors (etaf-runtime-for-buffer buffer))))

(defun etaf-performance--runtime-from-call (function arguments result after)
  "Resolve Runtime for FUNCTION call using ARGUMENTS, RESULT, and AFTER."
  (let ((first (car arguments)))
    (cond
     ((eq function 'etaf-runtime-mount)
      (when after (etaf-performance--runtime-for-buffer result)))
     ((etaf-performance--runtime-p first) first)
     ((memq function '(etaf-runtime-flush etaf-runtime-unmount
                       etaf-focus etaf-focus-next etaf-focus-previous
                       etaf-activate))
      (or (and first (etaf-performance--runtime-for-buffer first))
          (and (boundp 'etaf--current-runtime) etaf--current-runtime)
          (etaf-performance--runtime-for-buffer (current-buffer))))
     ((eq function 'etaf-activate-mouse)
      (and (boundp 'etaf--current-runtime) etaf--current-runtime))
     ((eq function 'etaf-dispatch)
      (if (etaf-performance--runtime-p first)
          first
        (and (boundp 'etaf--current-runtime) etaf--current-runtime)))
     ((memq function '(ebox-surface-update-buffer-viewport
                       ebox-rerender-buffer-with-context))
      (etaf-performance--runtime-for-buffer first))
     (t
      (and (boundp 'etaf--current-runtime) etaf--current-runtime)))))

(defun etaf-performance--buffer (runtime function arguments result after)
  "Resolve operation buffer from RUNTIME and call metadata.
FUNCTION received ARGUMENTS and produced RESULT when AFTER is non-nil."
  (cond
   ((and runtime (fboundp 'etaf-runtime-buffer))
    (ignore-errors (etaf-runtime-buffer runtime)))
   ((eq function 'etaf-runtime-mount)
    (let ((value (if after result (car arguments))))
      (cond ((bufferp value) value)
            ((stringp value) (get-buffer value)))))
   ((memq function '(ebox-surface-update-buffer-viewport
                     ebox-rerender-buffer-with-context))
    (get-buffer (car arguments)))
   (t nil)))

(defun etaf-performance--generation (runtime)
  "Return RUNTIME's committed generation, or nil."
  (and runtime (fboundp 'etaf-runtime-generation)
       (ignore-errors (etaf-runtime-generation runtime))))

(defun etaf-performance--runtime-id (runtime)
  "Return RUNTIME's stable scalar mount identity, or nil."
  (and runtime (fboundp 'etaf-runtime-mount-epoch)
       (ignore-errors (etaf-runtime-mount-epoch runtime))))

(defun etaf-performance--buffer-name (buffer)
  "Return BUFFER's name snapshot, or nil."
  (cond ((bufferp buffer) (buffer-name buffer))
        ((stringp buffer) buffer)
        (t nil)))

(defun etaf-performance--label (function arguments)
  "Return a concise label for FUNCTION called with ARGUMENTS."
  (pcase function
    ('etaf-dispatch-event
     (format "%s %S" (nth 2 arguments) (nth 1 arguments)))
    ('etaf-dispatch
     (format "%S" (if (etaf-performance--runtime-p (car arguments))
                       (nth 1 arguments)
                     (car arguments))))
    ('etaf-runtime-mount (format "%s" (car arguments)))
    ('etaf-runtime-flush "manual flush")
    ('etaf-runtime-unmount "unmount")
    ('etaf-data-load "data load")
    ('etaf-data-source-load-page
     (format "data prepare page %s/%s"
             (or (nth 2 arguments) 1) (or (nth 3 arguments) 20)))
    ('etaf-data-mutate (format "data %S" (nth 1 arguments)))
    ('etaf-resource-load "resource load/reload")
    ('ebox-surface-update-buffer-viewport
     (format "viewport %sx%s" (nth 1 arguments) (or (nth 2 arguments) "-")))
    ('ebox-rerender-buffer-with-context
     (format "rerender %sx%s" (nth 1 arguments) (or (nth 2 arguments) "-")))
    ('etaf-focus (format "focus %S" (nth 1 arguments)))
    ('etaf-focus-next "next")
    ('etaf-focus-previous "previous")
    ('etaf-activate-mouse "mouse")
    ('etaf-activate "keyboard")
    (_ (symbol-name function))))

(defun etaf-performance--retain (operation)
  "Retain completed OPERATION under the configured bound."
  (let ((limit (max 0 etaf-performance-max-records)))
    (if (zerop limit)
        (setq etaf-performance--record-ring nil)
      (unless (and etaf-performance--record-ring
                   (= (ring-size etaf-performance--record-ring) limit))
        (let ((existing (etaf-performance-records)))
          (setq etaf-performance--record-ring (make-ring limit))
          (dolist (record (reverse (seq-take existing limit)))
            (ring-insert etaf-performance--record-ring record))))
      (ring-insert etaf-performance--record-ring operation))))

(defun etaf-performance--call-operation
    (original function kind arguments &optional label runtime buffer)
  "Call ORIGINAL as operation FUNCTION of KIND with ARGUMENTS.
Optional LABEL, RUNTIME, and BUFFER override inferred metadata."
  (if (not etaf-performance-mode)
      (apply original arguments)
    (let* ((runtime-before
            (or runtime
                (etaf-performance--runtime-from-call
                 function arguments nil nil)))
           (buffer-before
            (or buffer
                (etaf-performance--buffer
                 runtime-before function arguments nil nil)))
           (start (etaf-performance--now))
           (gc-count-before gcs-done)
           (gc-elapsed-before gc-elapsed)
           (operation
            (etaf-performance--operation-create
             :id (cl-incf etaf-performance--next-operation-id)
             :parent-id (and etaf-performance--current-operation
                             (etaf-performance-operation-id
                              etaf-performance--current-operation))
             :kind kind :label (or label
                                   (etaf-performance--label
                                    function arguments))
             :runtime-id (etaf-performance--runtime-id runtime-before)
             :buffer-name (etaf-performance--buffer-name buffer-before)
             :generation-before
             (etaf-performance--generation runtime-before)
             :start-time start :gc-count-before gc-count-before
             :gc-elapsed-before gc-elapsed-before))
           (etaf-performance--current-operation operation)
           (etaf-performance--stage-stack nil)
           (completed nil)
           (quit-p nil)
           result)
      (unwind-protect
          (condition-case condition
              (prog1 (setq result (apply original arguments))
                (setq completed t))
            (quit
             (setq quit-p t)
             (signal (car condition) (cdr condition))))
        (let* ((end (etaf-performance--now))
               (runtime-after
                (or (etaf-performance--runtime-from-call
                     function arguments result t)
                    runtime-before))
               (buffer-after
                (or (etaf-performance--buffer
                     runtime-after function arguments result t)
                    buffer-before)))
          (setf (etaf-performance-operation-runtime-id operation)
                (etaf-performance--runtime-id runtime-after)
                (etaf-performance-operation-buffer-name operation)
                (etaf-performance--buffer-name buffer-after)
                (etaf-performance-operation-generation-after operation)
                (etaf-performance--generation runtime-after)
                (etaf-performance-operation-end-time operation) end
                (etaf-performance-operation-elapsed operation)
                (* 1000.0 (- end start))
                (etaf-performance-operation-status operation)
                (cond (completed 'success) (quit-p 'quit) (t 'error))
                (etaf-performance-operation-gc-count-after operation) gcs-done
                (etaf-performance-operation-gc-elapsed-after operation)
                gc-elapsed
                (etaf-performance-operation-stages operation)
                (sort (etaf-performance-operation-stages operation)
                      (lambda (left right)
                        (< (etaf-performance-stage-id left)
                           (etaf-performance-stage-id right)))))
          (etaf-performance--retain operation)))
      result)))

;;;###autoload
(defun etaf-performance-call-operation
    (kind label function &optional runtime buffer)
  "Call FUNCTION as a recorded operation and return its exact result.
KIND and LABEL identify the operation.  Optional RUNTIME and BUFFER attach
framework metadata without constraining FUNCTION's implementation.  FUNCTION
should close over any arguments it needs.  Errors and quits are re-signaled."
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (etaf-performance--call-operation
   function 'etaf-performance-call-operation kind nil label runtime buffer))

(cl-defmacro etaf-performance-with-operation
    ((kind label &optional runtime buffer) &rest body)
  "Evaluate BODY as a recorded operation and return its exact result.
KIND, LABEL, optional RUNTIME, and optional BUFFER are evaluated once."
  (declare (indent 1) (debug ((form form &optional form form) body)))
  `(etaf-performance-call-operation
    ,kind ,label (lambda () ,@body) ,runtime ,buffer))

(defun etaf-performance--make-operation-advice (function kind)
  "Return an around advice closure for operation FUNCTION and KIND."
  (lambda (original &rest arguments)
    (etaf-performance--call-operation original function kind arguments)))

(defun etaf-performance--call-stage
    (original function category detail arguments)
  "Call ORIGINAL as stage FUNCTION in CATEGORY with DETAIL and ARGUMENTS."
  (if (not etaf-performance--current-operation)
      (apply original arguments)
    (let* ((start (etaf-performance--now))
           (frame
            (etaf-performance--stage-frame-create
             :id (cl-incf etaf-performance--next-stage-id)
             :category category :function function :detail detail
             :depth (length etaf-performance--stage-stack)
             :start-time start))
           (parent (car etaf-performance--stage-stack))
           (etaf-performance--stage-stack
            (cons frame etaf-performance--stage-stack))
           (completed nil)
           (quit-p nil)
           result)
      (unwind-protect
          (condition-case condition
              (prog1 (setq result (apply original arguments))
                (setq completed t))
            (quit
             (setq quit-p t)
             (signal (car condition) (cdr condition))))
        (let* ((end (etaf-performance--now))
               (inclusive (* 1000.0 (- end start)))
               (exclusive
                (max 0.0 (- inclusive
                            (etaf-performance--stage-frame-child-time frame)))))
          (when parent
            (cl-incf (etaf-performance--stage-frame-child-time parent)
                     inclusive))
          (when completed
            (etaf-performance--capture-stage-result
             etaf-performance--current-operation function result))
          (push
           (etaf-performance--stage-create
            :id (etaf-performance--stage-frame-id frame)
            :category category :function function :detail detail
            :depth (etaf-performance--stage-frame-depth frame)
            :start-time start :end-time end :inclusive inclusive
            :exclusive exclusive
            :status (cond (completed 'success) (quit-p 'quit) (t 'error)))
           (etaf-performance-operation-stages
            etaf-performance--current-operation))))
      result)))

(defun etaf-performance--compact-ebox-report (report)
  "Return stable scalar diagnostics from public Ebox REPORT."
  (when (listp report)
    (list :strategy (plist-get report :strategy)
          :projection-kind (plist-get report :projection-kind)
          :dirty-count (plist-get report :dirty-count)
          :owner-count (length (plist-get report :owner-ids))
          :patch-count (plist-get report :patch-count)
          :tp-scope-count (plist-get report :tp-scope-count)
          :tp-text-operations (plist-get report :tp-text-operations)
          :tp-property-operations (plist-get report :tp-property-operations)
          :tp-full-root (and (plist-get report :tp-full-root) t)
          :tp-scope-fallback (and (plist-get report :tp-scope-fallback) t)
          :native-frame-kind (plist-get report :native-frame-kind)
          :timing (copy-tree (plist-get report :timing)))))

(defun etaf-performance--capture-stage-result (operation function result)
  "Attach public FUNCTION RESULT diagnostics to OPERATION."
  (when (eq function 'ebox-commit)
    (setf (etaf-performance-operation-metadata operation)
          (plist-put (etaf-performance-operation-metadata operation)
                     :ebox
                     (etaf-performance--compact-ebox-report result)))))

(defun etaf-performance--make-stage-advice (function category detail)
  "Return an around advice closure for stage FUNCTION CATEGORY and DETAIL."
  (lambda (original &rest arguments)
    (etaf-performance--call-stage
     original function category detail arguments)))

(defun etaf-performance--install-one (function advice)
  "Install ADVICE around FUNCTION once and remember it."
  (let ((installed
         (cl-find function etaf-performance--installed-advices :key #'car)))
    (cond
     ((and installed (advice-member-p (cdr installed) function)) nil)
     (installed
      ;; Reloading a package replaces its advised symbol-function.  Reattach
      ;; the exact tracked closure so disable/unregister can still remove it.
      (advice-add function :around (cdr installed)))
     (t
      (advice-add function :around advice)
      (push (cons function advice) etaf-performance--installed-advices)))))

(defun etaf-performance--uninstall-function (function)
  "Remove recorder advice installed on FUNCTION."
  (when-let* ((entry (assq function etaf-performance--installed-advices)))
    (advice-remove function (cdr entry))
    (setq etaf-performance--installed-advices
          (delq entry etaf-performance--installed-advices))))

;;;###autoload
(defun etaf-performance-register-stage (function category &optional detail)
  "Register FUNCTION as a timed stage in CATEGORY.
DETAIL defaults to FUNCTION.  Registration is safe before or after the
package defining FUNCTION is loaded.  Return FUNCTION."
  (unless (symbolp function)
    (signal 'wrong-type-argument (list 'symbolp function)))
  (unless (symbolp category)
    (signal 'wrong-type-argument (list 'symbolp category)))
  (when (assq function etaf-performance--operation-functions)
    (error "ETAF performance operation boundary cannot be a stage: %S"
           function))
  (let ((detail (or detail function)))
    (unless (symbolp detail)
      (signal 'wrong-type-argument (list 'symbolp detail)))
    (setq etaf-performance--stage-functions
          (cons (list function category detail)
                (assq-delete-all function
                                 etaf-performance--stage-functions)))
    (etaf-performance--uninstall-function function)
    (when (and etaf-performance-mode (fboundp function))
      (etaf-performance--install-one
       function
       (etaf-performance--make-stage-advice function category detail))))
  function)

;;;###autoload
(defun etaf-performance-unregister-stage (function)
  "Unregister timed stage FUNCTION and remove its installed advice."
  (when (assq function etaf-performance--operation-functions)
    (error "ETAF performance operation boundary is not a registered stage: %S"
           function))
  (setq etaf-performance--stage-functions
        (assq-delete-all function etaf-performance--stage-functions))
  (etaf-performance--uninstall-function function)
  function)

(defun etaf-performance--install-loaded-advices (&optional _file)
  "Install configured advices whose functions are currently loaded."
  (when etaf-performance-mode
    (dolist (entry etaf-performance--operation-functions)
      (when (fboundp (car entry))
        (etaf-performance--install-one
         (car entry)
         (etaf-performance--make-operation-advice
          (car entry) (nth 1 entry)))))
    (dolist (entry etaf-performance--stage-functions)
      (when (fboundp (car entry))
        (etaf-performance--install-one
         (car entry)
         (etaf-performance--make-stage-advice
          (car entry) (nth 1 entry) (nth 2 entry)))))))

(defun etaf-performance--uninstall-advices ()
  "Remove every operation and stage advice installed by this recorder."
  (dolist (entry etaf-performance--installed-advices)
    (advice-remove (car entry) (cdr entry)))
  (setq etaf-performance--installed-advices nil))

;;;###autoload
(define-minor-mode etaf-performance-mode
  "Globally record ETAF operations and cross-package performance stages."
  :global t
  :init-value nil
  :lighter " ETAF-Perf"
  (if etaf-performance-mode
      (progn
        (add-hook 'after-load-functions
                  #'etaf-performance--install-loaded-advices)
        (etaf-performance--install-loaded-advices))
    (remove-hook 'after-load-functions
                 #'etaf-performance--install-loaded-advices)
    (etaf-performance--uninstall-advices)))

(defun etaf-performance--format-object (value)
  "Format VALUE compactly for the performance table."
  (cond ((bufferp value) (buffer-name value))
        ((null value) "-")
        (t (format "%s" value))))

(defun etaf-performance--format-report (operation)
  "Return compact public backend metadata for OPERATION."
  (if-let* ((report (plist-get (etaf-performance-operation-metadata operation)
                              :ebox)))
      (format "%s/%s d:%s o:%s tp:%s/%s/%s%s"
              (or (plist-get report :strategy) "-")
              (or (plist-get report :projection-kind) "-")
              (or (plist-get report :dirty-count) 0)
              (or (plist-get report :owner-count) 0)
              (or (plist-get report :tp-scope-count) 0)
              (or (plist-get report :tp-text-operations) 0)
              (or (plist-get report :tp-property-operations) 0)
              (if (or (plist-get report :tp-full-root)
                      (plist-get report :tp-scope-fallback))
                  " fallback"
                ""))
    "-"))

(defun etaf-performance--tabulated-entries ()
  "Return tabulated entries for retained operations and their stages."
  (let (entries)
    (dolist (operation (reverse (etaf-performance-records)))
      (let ((id (etaf-performance-operation-id operation)))
        (push
         (list (cons 'operation id)
               (vector
                (number-to-string id)
                (etaf-performance--format-object
                 (etaf-performance-operation-parent-id operation))
                (symbol-name (etaf-performance-operation-kind operation))
                (or (etaf-performance-operation-label operation) "")
                "operation" "-" "0"
                (format "%.3f" (etaf-performance-operation-elapsed operation))
                "-" (symbol-name (etaf-performance-operation-status operation))
                (etaf-performance--format-object
                 (etaf-performance-operation-buffer-name operation))
                (format "%s→%s"
                        (etaf-performance--format-object
                         (etaf-performance-operation-generation-before operation))
                        (etaf-performance--format-object
                         (etaf-performance-operation-generation-after operation)))
                (etaf-performance--format-report operation)
                (format "%d/%.3fms"
                        (- (etaf-performance-operation-gc-count-after operation)
                           (etaf-performance-operation-gc-count-before operation))
                        (* 1000.0
                           (- (etaf-performance-operation-gc-elapsed-after operation)
                              (etaf-performance-operation-gc-elapsed-before operation))))))
         entries)
        (dolist (stage (etaf-performance-operation-stages operation))
          (push
           (list (cons id (etaf-performance-stage-id stage))
                 (vector
                  (format "%s.%s" id (etaf-performance-stage-id stage))
                  (number-to-string id) "stage"
                  (concat (make-string (* 2 (etaf-performance-stage-depth stage)) ?\s)
                          (symbol-name (etaf-performance-stage-detail stage)))
                  (symbol-name (etaf-performance-stage-category stage))
                  (symbol-name (etaf-performance-stage-function stage))
                  (number-to-string (etaf-performance-stage-depth stage))
                  (format "%.3f" (etaf-performance-stage-inclusive stage))
                  (format "%.3f" (etaf-performance-stage-exclusive stage))
                  (symbol-name (etaf-performance-stage-status stage))
                  "-" "-" "-" "-"))
           entries))))
    (nreverse entries)))

(defun etaf-performance--panel-environment-line (&optional environment)
  "Return one compact header for performance ENVIRONMENT."
  (let* ((environment (or environment
                          (etaf-performance-environment-data)))
         (power (plist-get environment :power-state))
         (load (car (plist-get environment :load-average))))
    (format " ETAF Performance | Emacs %s | power %s/low:%s | load %.2f "
            (or (plist-get environment :emacs-version) "unknown")
            (or (plist-get power :source) 'unknown)
            (or (plist-get power :low-power-mode) 'unknown)
            (or load 0.0))))

(define-derived-mode etaf-performance-panel-mode tabulated-list-mode "ETAF-Performance"
  "Display ETAF operation and nested stage timing records.

Press `c' to copy a complete report or `w' to export it to a file."
  (setq tabulated-list-format
        [("ID" 9 t) ("Parent" 7 t) ("Type" 10 t) ("Label / Detail" 24 t)
         ("Category" 12 t) ("Function" 34 t) ("Depth" 6 t)
         ("Inclusive ms" 13 t) ("Exclusive ms" 13 t) ("Status" 8 t)
         ("Buffer" 18 t) ("Generation" 12 t) ("Backend report" 40 t)
         ("GC delta" 14 t)])
  (setq tabulated-list-padding 2
        tabulated-list-entries #'etaf-performance--tabulated-entries
        header-line-format (etaf-performance--panel-environment-line))
  (tabulated-list-init-header))

(define-key etaf-performance-panel-mode-map (kbd "c")
            #'etaf-performance-copy-report)
(define-key etaf-performance-panel-mode-map (kbd "w")
            #'etaf-performance-export)

;;;###autoload
(defun etaf-performance-show ()
  "Show retained ETAF operations and stages in a tabulated panel."
  (interactive)
  (let ((buffer (get-buffer-create "*ETAF Performance*")))
    (with-current-buffer buffer
      (etaf-performance-panel-mode)
      (tabulated-list-print t))
    (pop-to-buffer buffer)))

(provide 'etaf-performance)

;;; etaf-performance.el ends here
