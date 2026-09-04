;;; etaf-render-port.el --- Versioned Ebox renderer port -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This file is ETAF's only Ebox framework-SPI bootstrap owner.  It probes the
;; Ebox v2 provider once, selects one immutable port, and exposes that
;; selection to downstream ETAF code without repeated `featurep' or `fboundp'
;; protocol guesses.  A completely absent v2 provider receives a complete v1
;; fallback; a present but broken or incompatible provider fails closed.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox)

(define-error 'etaf-spi-bootstrap-error
  "Malformed Ebox framework SPI provider")
(define-error 'etaf-spi-incompatible-error
  "Incompatible Ebox framework SPI provider"
  'etaf-spi-bootstrap-error)

(defcustom etaf-render-port-selection-policy 'v2
  "ETAF render authority selected during process bootstrap.
`v2' selects the compatible Ebox SPI v2 port.  `v1' is the complete legacy
render/Host rollback switch and bypasses provider probing.  Generation stores,
retirement, and scheduler keep their unified authority so v1 and v2 preserve
the same generation/token/store-version outcomes.  Set this before loading
ETAF; the selected port is process-wide and immutable."
  :type '(choice (const :tag "ETAF v2 authorities" v2)
                 (const :tag "Complete ETAF v1 route" v1))
  :group 'etaf)

(defconst etaf-render-port--required-spi-version 2
  "Ebox framework SPI version consumed by this ETAF build.")

(defconst etaf-render-port--required-schema-version
  'ebox-framework-spi-schema/v2
  "Ebox provider schema consumed by this ETAF build.")

(defconst etaf-render-port--required-capabilities
  '(initial-paired-stage-rollback
    update-paired-stage-rollback
    combined-participant-ordering
    same-object-legacy-report
    initial-observation-replay)
  "Capabilities required from an Ebox framework SPI v2 provider.")

(defconst etaf-render-port--required-tp-protocol
  'tp-transaction-protocol-v1+v2
  "TP transaction protocol required by the Ebox framework SPI.")

(defconst etaf-render-port--required-stage-order
  '(ebox-mirror/native framework-stage)
  "Required stage order inside the combined Ebox participant.")

(defconst etaf-render-port--required-rollback-order
  '(framework-rollback ebox-mirror/native tp)
  "Required rollback order inside the combined Ebox participant.")

(cl-defstruct
    (etaf-render-port
     (:constructor etaf-render-port--create)
     (:conc-name etaf-render-port--))
  "Immutable selected Ebox rendering capability."
  (route nil :read-only t)
  (spi-version nil :read-only t)
  (schema-version nil :read-only t)
  (capabilities nil :read-only t)
  (tp-protocol nil :read-only t)
  (initial-function nil :read-only t)
  (update-function nil :read-only t)
  (revision-function nil :read-only t)
  (bootstrap-outcome nil :read-only t)
  (provider nil :read-only t))

(defun etaf-render-port-route (port)
  "Return selected PORT route, either `v1' or `v2'."
  (etaf-render-port--route port))

(defun etaf-render-port-spi-version (port)
  "Return PORT's selected framework SPI version."
  (etaf-render-port--spi-version port))

(defun etaf-render-port-schema-version (port)
  "Return PORT's selected provider schema version."
  (etaf-render-port--schema-version port))

(defun etaf-render-port-capabilities (port)
  "Return a defensive copy of PORT's capabilities."
  (copy-sequence (etaf-render-port--capabilities port)))

(defun etaf-render-port-tp-protocol (port)
  "Return PORT's selected TP transaction protocol."
  (etaf-render-port--tp-protocol port))

(defun etaf-render-port-initial-function (port)
  "Return PORT's initial mount function symbol."
  (etaf-render-port--initial-function port))

(defun etaf-render-port-update-function (port)
  "Return PORT's update function symbol."
  (etaf-render-port--update-function port))

(defun etaf-render-port-revision-function (port)
  "Return PORT's committed-revision query function symbol."
  (etaf-render-port--revision-function port))

(defun etaf-render-port-bootstrap-outcome (port)
  "Return PORT's immutable bootstrap outcome tag."
  (etaf-render-port--bootstrap-outcome port))

(defun etaf-render-port--bootstrap-error (reason &optional detail)
  "Signal a fail-closed bootstrap error for REASON and DETAIL."
  (signal 'etaf-spi-bootstrap-error
          (list :reason reason :detail detail)))

(defun etaf-render-port--ensure-accessors ()
  "Require every public Ebox v2 record accessor before reading a provider."
  (dolist
      (function
       '(ebox-framework-spi-provider-p
         ebox-framework-spi-provider-spi-version
         ebox-framework-spi-provider-schema-version
         ebox-framework-spi-provider-capabilities
         ebox-framework-spi-provider-tp-protocol
         ebox-framework-spi-provider-stage-order
         ebox-framework-spi-provider-rollback-order
         ebox-framework-spi-provider-report-semantics
         ebox-framework-spi-provider-initial-operation
         ebox-framework-spi-provider-update-operation
         ebox-framework-spi-operation-p
         ebox-framework-spi-operation-kind
         ebox-framework-spi-operation-function
         ebox-framework-spi-operation-argument-schema
         ebox-framework-spi-operation-result-schema
         ebox-framework-spi-operation-paired-stage-rollback-p
         ebox-framework-spi-initial-observation-reports))
    (unless (fboundp function)
      (etaf-render-port--bootstrap-error
       'missing-provider-accessor function))))

(defun etaf-render-port--operation-snapshot (operation label)
  "Return validated immutable field snapshot for OPERATION named LABEL."
  (unless (ebox-framework-spi-operation-p operation)
    (etaf-render-port--bootstrap-error
     'malformed-operation (list :label label :value operation)))
  (let ((kind (ebox-framework-spi-operation-kind operation))
        (function (ebox-framework-spi-operation-function operation))
        (arguments
         (ebox-framework-spi-operation-argument-schema operation))
        (result (ebox-framework-spi-operation-result-schema operation))
        (paired
         (ebox-framework-spi-operation-paired-stage-rollback-p operation)))
    (unless (and (symbolp kind)
                 (symbolp function)
                 (fboundp function)
                 (proper-list-p arguments)
                 (cl-every #'symbolp arguments)
                 (symbolp result)
                 (memq paired '(nil t)))
      (etaf-render-port--bootstrap-error
       'malformed-operation-fields
       (list :label label :kind kind :function function
             :arguments arguments :result result :paired paired)))
    (list :kind kind :function function
          :arguments (copy-sequence arguments)
          :result result :paired paired)))

(defun etaf-render-port--provider-snapshot (provider)
  "Return a validated field snapshot of Ebox v2 PROVIDER."
  (etaf-render-port--ensure-accessors)
  (unless (ebox-framework-spi-provider-p provider)
    (etaf-render-port--bootstrap-error 'non-provider-record provider))
  (let ((spi-version (ebox-framework-spi-provider-spi-version provider))
        (schema-version
         (ebox-framework-spi-provider-schema-version provider))
        (capabilities
         (ebox-framework-spi-provider-capabilities provider))
        (tp-protocol (ebox-framework-spi-provider-tp-protocol provider))
        (stage-order (ebox-framework-spi-provider-stage-order provider))
        (rollback-order
         (ebox-framework-spi-provider-rollback-order provider))
        (report-semantics
         (ebox-framework-spi-provider-report-semantics provider)))
    (unless (and (integerp spi-version)
                 (> spi-version 0)
                 (symbolp schema-version)
                 (proper-list-p capabilities)
                 (cl-every #'symbolp capabilities)
                 (symbolp tp-protocol)
                 (proper-list-p stage-order)
                 (cl-every #'symbolp stage-order)
                 (proper-list-p rollback-order)
                 (cl-every #'symbolp rollback-order)
                 (symbolp report-semantics))
      (etaf-render-port--bootstrap-error
       'malformed-provider-fields
       (list :spi-version spi-version :schema-version schema-version
             :capabilities capabilities :tp-protocol tp-protocol
             :stage-order stage-order :rollback-order rollback-order
             :report-semantics report-semantics)))
    (list
     :provider provider
     :spi-version spi-version
     :schema-version schema-version
     :capabilities (copy-sequence capabilities)
     :tp-protocol tp-protocol
     :stage-order (copy-sequence stage-order)
     :rollback-order (copy-sequence rollback-order)
     :report-semantics report-semantics
     :initial
     (etaf-render-port--operation-snapshot
      (ebox-framework-spi-provider-initial-operation provider) 'initial)
     :update
     (etaf-render-port--operation-snapshot
      (ebox-framework-spi-provider-update-operation provider) 'update))))

(defun etaf-render-port--incompatibilities (snapshot)
  "Return deterministic compatibility failures in provider SNAPSHOT."
  (let (failures)
    (unless (eql (plist-get snapshot :spi-version)
                 etaf-render-port--required-spi-version)
      (push (list :spi-version (plist-get snapshot :spi-version)) failures))
    (unless (eq (plist-get snapshot :schema-version)
                etaf-render-port--required-schema-version)
      (push (list :schema-version (plist-get snapshot :schema-version))
            failures))
    (let ((capabilities (plist-get snapshot :capabilities)))
      (dolist (capability etaf-render-port--required-capabilities)
        (unless (memq capability capabilities)
          (push (list :missing-capability capability) failures))))
    (unless (eq (plist-get snapshot :tp-protocol)
                etaf-render-port--required-tp-protocol)
      (push (list :tp-protocol (plist-get snapshot :tp-protocol)) failures))
    (unless (equal (plist-get snapshot :stage-order)
                   etaf-render-port--required-stage-order)
      (push (list :stage-order (plist-get snapshot :stage-order)) failures))
    (unless (equal (plist-get snapshot :rollback-order)
                   etaf-render-port--required-rollback-order)
      (push (list :rollback-order (plist-get snapshot :rollback-order))
            failures))
    (unless (eq (plist-get snapshot :report-semantics)
                'same-object-legacy-report)
      (push (list :report-semantics
                  (plist-get snapshot :report-semantics))
            failures))
    (dolist
        (expectation
         `((:initial initial ebox-framework-spi-initial
                    (buffer canonical-input framework-stage framework-rollback))
           (:update update ebox-framework-spi-update
                    (buffer canonical-input-or-candidate
                            framework-stage framework-rollback))))
      (let* ((slot (nth 0 expectation))
             (operation (plist-get snapshot slot)))
        (unless (and (eq (plist-get operation :kind) (nth 1 expectation))
                     (eq (plist-get operation :function) (nth 2 expectation))
                     (equal (plist-get operation :arguments)
                            (nth 3 expectation))
                     (eq (plist-get operation :result)
                         'ebox-legacy-report/same-object)
                     (eq (plist-get operation :paired) t))
          (push (list slot operation) failures))))
    (nreverse failures)))

(defun etaf-render-port--validate-framework-pair
    (framework-stage framework-rollback)
  "Validate FRAMEWORK-STAGE and FRAMEWORK-ROLLBACK as one required pair."
  (unless (functionp framework-stage)
    (signal 'wrong-type-argument (list 'functionp framework-stage)))
  (unless (functionp framework-rollback)
    (signal 'wrong-type-argument (list 'functionp framework-rollback)))
  t)

(defvar-local etaf-render-port--v1-cleanup-diagnostics nil
  "Contained cleanup failures from the latest failed v1 initial operation.")

(defvar-local etaf-render-port--v1-committed-revision nil
  "ETAF-owned revision evidence for a mounted legacy Ebox v1 surface.")

(defun etaf-render-port-v1-cleanup-diagnostics (buffer)
  "Return a defensive copy of BUFFER's latest v1 cleanup diagnostics."
  (and (buffer-live-p (get-buffer buffer))
       (with-current-buffer (get-buffer buffer)
         (copy-tree etaf-render-port--v1-cleanup-diagnostics))))

(defun etaf-render-port--v1-buffer-snapshot (buffer)
  "Return BUFFER content and editor state needed by v1 manual cleanup."
  (with-current-buffer buffer
    (let ((narrowed-p (buffer-narrowed-p))
          (start (point-min))
          (end (point-max)))
      (save-restriction
        (widen)
        (list :contents (buffer-substring (point-min) (point-max))
              :point (point)
              :mark-marker (mark-marker)
              :mark-position (mark t)
              :mark-insertion-type
              (marker-insertion-type (mark-marker))
              :mark-active mark-active
              :narrowed-p narrowed-p
              :narrow-start start
              :narrow-end end
              :read-only buffer-read-only
              :modified-p (buffer-modified-p)
              :undo-list buffer-undo-list
              :overlays
              (mapcar
               (lambda (overlay)
                 (list :overlay overlay
                       :start (overlay-start overlay)
                       :end (overlay-end overlay)))
               (delete-dups
                (append (car (overlay-lists)) (cdr (overlay-lists))))))))))

(defun etaf-render-port--v1-restore-buffer
    (buffer snapshot &optional restore-contents-p)
  "Restore BUFFER editor state from a pre-render v1 SNAPSHOT.
When RESTORE-CONTENTS-P is non-nil, also re-materialize text as a last-resort
fallback after change-group cancellation itself failed."
  (unless (buffer-live-p buffer)
    (error "Legacy Ebox target died during manual cleanup"))
  (with-current-buffer buffer
    (let ((inhibit-read-only t)
          (inhibit-modification-hooks t))
      (widen)
      (when restore-contents-p
        (let ((buffer-undo-list t))
          (erase-buffer)
          (insert (plist-get snapshot :contents))))
      (let* ((saved-overlays (plist-get snapshot :overlays))
             (saved-identities
              (mapcar (lambda (entry) (plist-get entry :overlay))
                      saved-overlays)))
        (dolist
            (overlay
             (delete-dups
              (append (car (overlay-lists)) (cdr (overlay-lists)))))
          (unless (memq overlay saved-identities)
            (delete-overlay overlay)))
        (dolist (entry saved-overlays)
          (let ((overlay (plist-get entry :overlay)))
            (move-overlay overlay
                          (plist-get entry :start)
                          (plist-get entry :end)
                          buffer))))
      (when (plist-get snapshot :narrowed-p)
        (narrow-to-region
         (min (point-max) (plist-get snapshot :narrow-start))
         (min (point-max) (plist-get snapshot :narrow-end))))
      (goto-char (min (point-max)
                      (max (point-min) (plist-get snapshot :point))))
      (let ((mark-marker (plist-get snapshot :mark-marker)))
        (set-marker mark-marker (plist-get snapshot :mark-position) buffer)
        (set-marker-insertion-type
         mark-marker (plist-get snapshot :mark-insertion-type)))
      (setq mark-active (plist-get snapshot :mark-active))
      (setq buffer-read-only (plist-get snapshot :read-only))
      (set-buffer-modified-p (plist-get snapshot :modified-p))
      (setq buffer-undo-list (plist-get snapshot :undo-list))))
  buffer)

(defun etaf-render-port--v1-cleanup-failed-initial
    (buffer snapshot change-group change-group-active-p stage-entered
            observer framework-rollback)
  "Clean one failed legacy initial operation and return diagnostics.
BUFFER and SNAPSHOT identify editor custody.  CHANGE-GROUP-ACTIVE-P says
whether CHANGE-GROUP still needs cancellation.  STAGE-ENTERED controls the
paired FRAMEWORK-ROLLBACK.  OBSERVER is detached before Ebox unmount."
  (let (cancel-failed-p)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq-local etaf-render-port--v1-cleanup-diagnostics nil)))
    (cl-labels
        ((record
          (diagnostic)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (setq-local
               etaf-render-port--v1-cleanup-diagnostics
               (append etaf-render-port--v1-cleanup-diagnostics
                       (list diagnostic))))))
         (run-phase
          (entry)
          (let ((phase (nth 0 entry))
                (function (nth 1 entry))
                (failure-function (nth 2 entry))
                completed-p)
            (unwind-protect
                (let ((inhibit-quit t) (quit-flag nil))
                  (condition-case condition
                      (progn (funcall function) (setq completed-p t))
                    ((error quit)
                     (setq completed-p t)
                     (when failure-function (funcall failure-function))
                     (record
                      (list :phase phase
                            :condition (copy-tree condition))))))
              (unless completed-p
                (when failure-function (funcall failure-function))
                (record (list :phase phase :nonlocal-exit t))))))
         (run-phases
          (entries)
          (when entries
            ;; A cleanup callback may perform an arbitrary nonlocal exit.
            ;; Nested unwind cleanup guarantees every later phase still runs.
            (unwind-protect
                (run-phase (car entries))
              (run-phases (cdr entries))))))
      (run-phases
       `((framework-rollback
          ,(lambda ()
             (when stage-entered
               (funcall framework-rollback nil))))
         (observer-detach
          ,(lambda ()
             (when (and observer (buffer-live-p buffer)
                        (ebox-surface-buffer-mounted-p buffer))
               (ebox-buffer-set-observer buffer nil))))
         (ebox-unmount
          ,(lambda ()
             (when (and (buffer-live-p buffer)
                        (ebox-surface-buffer-mounted-p buffer))
               (ebox-unmount-buffer buffer))))
         (revision-reset
          ,(lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq-local
                  etaf-render-port--v1-committed-revision nil)))))
         (change-group-cancel
          ,(lambda ()
             (when change-group-active-p
               (with-current-buffer buffer
                 (cancel-change-group change-group))))
          ,(lambda () (setq cancel-failed-p t)))
         (buffer-restore
          ,(lambda ()
             (etaf-render-port--v1-restore-buffer
              buffer snapshot cancel-failed-p))))))
    (and (buffer-live-p buffer)
         (etaf-render-port-v1-cleanup-diagnostics buffer))))

(defun etaf-render-port--v1-record-revision (buffer revision)
  "Record committed v1 REVISION for BUFFER without postaccept failure."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq-local etaf-render-port--v1-committed-revision
                  (if (and (integerp revision) (> revision 0))
                      revision
                    'unavailable)))))

(defun etaf-render-port--v1-revision (buffer)
  "Return ETAF's committed revision evidence for legacy v1 BUFFER."
  (let ((revision
         (and (buffer-live-p buffer)
              (buffer-local-value
               'etaf-render-port--v1-committed-revision buffer))))
    (unless (and (integerp revision) (> revision 0))
      (error "Mounted legacy Ebox surface has no committed revision: %S"
             revision))
    revision))

(defun etaf-render-port--v1-initial
    (buffer input framework-stage framework-rollback &optional observer)
  "Publish INPUT initially to BUFFER through legacy Ebox.
FRAMEWORK-STAGE runs after publication; FRAMEWORK-ROLLBACK performs contained
manual framework cleanup if staging fails.  OBSERVER, when non-nil, is passed
through Ebox's legacy initial option."
  (etaf-render-port--validate-framework-pair
   framework-stage framework-rollback)
  (let* ((buffer (get-buffer-create buffer))
         (snapshot (etaf-render-port--v1-buffer-snapshot buffer))
         (change-group (with-current-buffer buffer (prepare-change-group)))
         result stage-entered operation-started-p change-group-active-p
         cleanup-ran-p)
    (cl-labels
        ((cleanup
          ()
          (unless cleanup-ran-p
            (setq cleanup-ran-p t)
            (when operation-started-p
              (let ((active-p change-group-active-p))
                (setq change-group-active-p nil)
                (etaf-render-port--v1-cleanup-failed-initial
                 buffer snapshot change-group active-p stage-entered
                 observer framework-rollback))))))
      (unwind-protect
          (condition-case primary
              (progn
                (when (ebox-surface-buffer-mounted-p buffer)
                  (error
                   "Legacy Ebox initial operation requires an unmounted buffer"))
                (with-current-buffer buffer
                  (setq-local etaf-render-port--v1-cleanup-diagnostics nil
                              etaf-render-port--v1-committed-revision nil)
                  (activate-change-group change-group)
                  (setq operation-started-p t
                        change-group-active-p t)
                  (save-restriction
                    (widen)
                    (setq result
                          (ebox-render-to-buffer
                           buffer input
                           (and observer (list :observer observer))))))
                (setq stage-entered t)
                (funcall framework-stage nil)
                (with-current-buffer buffer
                  (accept-change-group change-group))
                (setq change-group-active-p nil)
                ;; TP surfaces start at committed revision one.  Legacy Ebox
                ;; does not expose its surface handle, so ETAF owns this
                ;; compatibility evidence and advances it from update reports.
                (etaf-render-port--v1-record-revision buffer 1)
                result)
            ((error quit)
             (cleanup)
             (signal (car primary) (cdr primary))))
        (when change-group-active-p
          (cleanup))))))

(defun etaf-render-port--v1-update
    (buffer input framework-stage framework-rollback)
  "Update BUFFER from INPUT through the legacy Ebox callback pair.
FRAMEWORK-STAGE and FRAMEWORK-ROLLBACK retain their existing Ebox meanings."
  (etaf-render-port--validate-framework-pair
   framework-stage framework-rollback)
  (let ((report
         (ebox-commit buffer input framework-stage framework-rollback)))
    ;; Publication is accepted here.  Missing compatibility metadata must not
    ;; become a rollback-capable error after commit; a later read fails closed.
    (etaf-render-port--v1-record-revision
     (get-buffer buffer) (plist-get report :surface-revision))
    report))

(defun etaf-render-port--v1-fallback (&optional bootstrap-outcome)
  "Return the complete immutable v1 port tagged with BOOTSTRAP-OUTCOME."
  (etaf-render-port--create
   :route 'v1
   :spi-version 1
   :schema-version 'etaf-ebox-v1-fallback/v1
   :capabilities
   '(initial-manual-cleanup update-paired-stage-rollback
     same-object-update-report)
   :tp-protocol 'tp-transaction-protocol-v1
   :initial-function 'etaf-render-port--v1-initial
   :update-function 'etaf-render-port--v1-update
   :revision-function 'etaf-render-port--v1-revision
   :bootstrap-outcome (or bootstrap-outcome 'v2-absent-v1-selected)))

(defun etaf-render-port--v2-port (snapshot)
  "Return an immutable selected v2 port from compatible SNAPSHOT."
  (let ((failures (etaf-render-port--incompatibilities snapshot)))
    (when failures
      (signal 'etaf-spi-incompatible-error
              (list :incompatibilities failures)))
    (etaf-render-port--create
     :route 'v2
     :spi-version (plist-get snapshot :spi-version)
     :schema-version (plist-get snapshot :schema-version)
     :capabilities (copy-sequence (plist-get snapshot :capabilities))
     :tp-protocol (plist-get snapshot :tp-protocol)
     :initial-function
     (plist-get (plist-get snapshot :initial) :function)
     :update-function
     (plist-get (plist-get snapshot :update) :function)
     :revision-function 'ebox-surface-buffer-revision
     :bootstrap-outcome 'valid-v2-selected
     :provider (plist-get snapshot :provider))))

(defun etaf-render-port--bootstrap ()
  "Probe Ebox exactly once and return one immutable selected render port."
  (pcase etaf-render-port-selection-policy
    ('v1
     (etaf-render-port--v1-fallback 'v1-kill-switch-selected))
    ('v2
     (let ((feature-present-p (featurep 'ebox-framework-spi-v2))
           (predicate-present-p (fboundp 'ebox-framework-spi-capabilities)))
       (cond
        ((and (not feature-present-p) (not predicate-present-p))
         (etaf-render-port--v1-fallback))
        ((not feature-present-p)
         (etaf-render-port--bootstrap-error 'predicate-without-v2-feature))
        ((not predicate-present-p)
         (etaf-render-port--bootstrap-error 'v2-feature-without-predicate))
        (t
         (condition-case condition
             (etaf-render-port--v2-port
              (etaf-render-port--provider-snapshot
               (ebox-framework-spi-capabilities)))
           ((etaf-spi-incompatible-error etaf-spi-bootstrap-error)
            (signal (car condition) (cdr condition)))
           ((error quit)
            (etaf-render-port--bootstrap-error
             'provider-predicate-failure condition)))))))
    (_
     (etaf-render-port--bootstrap-error
      'invalid-render-port-selection etaf-render-port-selection-policy))))

(defconst etaf-render-port--selected-port
  (etaf-render-port--bootstrap)
  "Process-wide immutable Ebox render port selected during ETAF bootstrap.")

(defun etaf-render-port-selected ()
  "Return the process-wide immutable Ebox render port."
  etaf-render-port--selected-port)

(defun etaf-render-port-initial
    (buffer input framework-stage framework-rollback &optional observer)
  "Run selected initial operation for BUFFER and canonical INPUT.
FRAMEWORK-STAGE and FRAMEWORK-ROLLBACK are one required callback pair.
OBSERVER, when non-nil, receives TP and Ebox snapshots measured during the
initial v2 publication and replayed only after successful final accept."
  (if (eq (etaf-render-port-route etaf-render-port--selected-port) 'v1)
      (funcall (etaf-render-port-initial-function
                etaf-render-port--selected-port)
               buffer input framework-stage framework-rollback observer)
    (let ((report
           (funcall
            (etaf-render-port-initial-function etaf-render-port--selected-port)
            buffer input framework-stage framework-rollback)))
      (when observer
        (dolist (provider-report
                 (ebox-framework-spi-initial-observation-reports report))
          (funcall observer buffer provider-report)))
      report)))

(defun etaf-render-port-update
    (buffer input framework-stage framework-rollback)
  "Run selected update operation for BUFFER and INPUT.
FRAMEWORK-STAGE and FRAMEWORK-ROLLBACK are one required callback pair."
  (funcall (etaf-render-port-update-function
            etaf-render-port--selected-port)
           buffer input framework-stage framework-rollback))

(defun etaf-render-port-unmount (buffer)
  "Release the retained Ebox surface owned by mounted BUFFER."
  (let ((buffer (get-buffer buffer)))
    (prog1 (ebox-unmount-buffer buffer)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq-local etaf-render-port--v1-committed-revision nil))))))

(defun etaf-render-port-mounted-p (buffer)
  "Return non-nil when BUFFER owns a live retained Ebox surface."
  (ebox-surface-buffer-mounted-p buffer))

(defun etaf-render-port-revision (buffer)
  "Return BUFFER's committed Ebox revision, or zero when it is unmounted."
  (let ((buffer (get-buffer buffer)))
    (if (not (and (buffer-live-p buffer)
                  (ebox-surface-buffer-mounted-p buffer)))
        0
      (let ((revision
             (funcall
              (etaf-render-port-revision-function
               etaf-render-port--selected-port)
              buffer)))
        (unless (and (integerp revision) (> revision 0))
          (error "Mounted Ebox surface has no committed revision: %S"
                 revision))
        revision))))

(provide 'etaf-render-port)

;;; etaf-render-port.el ends here
