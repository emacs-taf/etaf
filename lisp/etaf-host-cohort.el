;;; etaf-host-cohort.el --- Retained primitive publication groups -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Bind the registered primitive Host and text effects when a structural
;; generation publishes, then compile them into the provider's retained scene
;; once Emacs is idle or the first sparse flush needs them.  Input dispatch
;; only selects known sparse members; it never discovers a Component subtree.

;;; Code:

(require 'cl-lib)
(require 'etaf-host-update)

(declare-function ebox-update-prepare "ebox"
                  (buffer-or-name specifications &optional stage rollback after-commit))
(declare-function ebox-update-valid-p "ebox" (operation))
(declare-function ebox-update-apply "ebox" (operation values changed-indices &optional count))
(declare-function ebox-update-binding-token "ebox" (buffer-or-name))
(declare-function ebox-update-prepare-report "ebox" (buffer-or-name))
(declare-function ebox-transaction-active-p "ebox" ())
(declare-function etaf--runtime-primitive-queue-p "etaf-runtime" (runtime generation))

(cl-defstruct (etaf--host-cohort (:constructor etaf--host-cohort-create))
  runtime generation members values effect-indices
  dirty-indices dirty-epochs (dirty-count 0) (epoch 0)
  changed-indices (changed-count 0)
  operation owner-indices owners owner-epochs changed-owners (changed-owner-count 0))

(defun etaf--host-cohort-stage (cohort)
  "Stage COHORT's changed semantic cells under one generation token."
  (let* ((runtime (etaf--host-cohort-runtime cohort))
         (generation (etaf--host-cohort-generation cohort))
         (members (etaf--host-cohort-members cohort))
         (indices (etaf--host-cohort-changed-indices cohort))
         (inhibit-quit t))
    (unless (eq generation (etaf-runtime-current-generation runtime))
      (signal 'etaf-generation-conflict '(prepared-cohort-generation)))
    (dotimes (position (etaf--host-cohort-changed-count cohort))
      (etaf--host-update-stage (aref members (aref indices position)) t))
    (cl-incf (etaf-generation-generation-id generation))
    (cl-incf (etaf-generation-authority-token
             (etaf-runtime-generation-authority runtime)))))

(defun etaf--host-cohort-rollback (cohort)
  "Restore COHORT's semantic writes in reverse staging order."
  (let ((members (etaf--host-cohort-members cohort))
        (indices (etaf--host-cohort-changed-indices cohort))
        (position (etaf--host-cohort-changed-count cohort)))
    (while (> position 0)
      (setq position (1- position))
      (etaf--host-update-rollback (aref members (aref indices position))))))

(defun etaf--host-cohort-after-commit (cohort)
  "Consume COHORT work and deliver each changed inline owner's hooks once."
  (let* ((runtime (etaf--host-cohort-runtime cohort))
         (members (etaf--host-cohort-members cohort))
         (owners (etaf--host-cohort-owners cohort))
         (changed (etaf--host-cohort-changed-owners cohort))
         journal)
    ;; Consume only the captured dirty set.  A provider observer or later
    ;; lifecycle hook may leave other work queued on this Runtime.
    (let ((queue (etaf-runtime-dirty-effect-queue runtime)) previous
          (indices (etaf--host-cohort-effect-indices cohort))
          (epochs (etaf--host-cohort-dirty-epochs cohort))
          (epoch (etaf--host-cohort-epoch cohort)))
      (while queue
        (let ((index (gethash (car queue) indices)))
          (if (and index (= (aref epochs index) epoch))
              (let* ((member (aref members index))
                     (pending (etaf--host-update-newer-input-p member)))
                (etaf--host-update-consume member pending)
                (if pending
                    (setq previous queue)
                  (if previous (setcdr previous (cdr queue))
                    (setf (etaf-runtime-dirty-effect-queue runtime) (cdr queue)))))
            (setq previous queue)))
        (setq queue (cdr queue)))
      (setf (etaf-runtime-dirty-effect-queue-tail runtime) previous))
    (setf (etaf-runtime-pending-p runtime)
          (and (etaf-runtime-dirty-effect-queue runtime) t))
    (dotimes (position (etaf--host-cohort-changed-owner-count cohort))
      (let* ((index (aref changed position))
             (instance (aref owners index))
             (hooks (etaf--component-instance-updated-hooks instance)))
        (when hooks
          (unless journal
            (setq journal
                  (etaf--runtime-new-retirement-journal
                   runtime (cl-incf (etaf-runtime-next-semantic-candidate-id runtime)))))
          (etaf--runtime-enqueue-instance-hooks
           runtime journal instance 'updated hooks (list 3 index)))))
    (when journal (etaf--runtime-drain-retirement runtime journal))))

(defun etaf--host-cohort-bind-owners (cohort)
  "Compile COHORT's owner order and per-member lifecycle indices."
  (let* ((members (etaf--host-cohort-members cohort))
         (ordinals (make-hash-table :test #'eq))
         owners)
    (dotimes (index (length members))
      (when-let* ((instance (etaf--host-update-lifecycle-instance (aref members index))))
        (cl-pushnew instance owners :test #'eq)))
    (setq owners (vconcat (nreverse owners)))
    (dotimes (index (length owners)) (puthash (aref owners index) index ordinals))
    (let ((indices (make-vector (length members) nil)))
      (dotimes (index (length members))
        (aset indices index
              (gethash (etaf--host-update-lifecycle-instance (aref members index)) ordinals)))
      (setf (etaf--host-cohort-owner-indices cohort) indices
            (etaf--host-cohort-owners cohort) owners
            (etaf--host-cohort-owner-epochs cohort) (make-vector (length owners) 0)
            (etaf--host-cohort-changed-owners cohort) (make-vector (length owners) 0)))))

(defun etaf--host-cohort-program-key (member)
  "Return MEMBER's compiled Host program identity for finite value domains."
  (let ((host (etaf--host-update-semantic member)))
    (or (etaf--semantic-host-site-token host)
        (etaf--semantic-host-identity host))))

(defun etaf--host-cohort-copy-class (value)
  "Detach a supported raw class VALUE for the control-plane variant domain."
  (cond ((stringp value) (copy-sequence value))
        ((consp value) (mapcar #'etaf--host-cohort-copy-class value))
        (t value)))

(defun etaf--host-cohort-record-variants (runtime members)
  "Retain committed class variants from RUNTIME's actually registered MEMBERS.
No getter is invoked to invent a future application state.  Instances of one
compiled Host program share the finite raw values already present or accepted."
  (let ((history (etaf-runtime-prepared-host-variants runtime)))
    (dolist (member members)
      (when (cl-position :class (etaf--host-update-properties member))
        (let* ((key (etaf--host-cohort-program-key member))
               (value (plist-get (etaf--semantic-host-base-props
                                  (etaf--host-update-semantic member)) :class))
               (known (gethash key history)))
          (unless (member value known)
            (puthash key (cons (etaf--host-cohort-copy-class value) known)
                     history)))))))

(defun etaf--host-cohort-class-domain (raw-values)
  "Compile RAW-VALUES to a lookup table and canonical provider token variants.
ETAF owns whitespace/list/symbol normalization.  Ebox receives its existing
flat-token grammar, while semantic/public property cells keep the raw value."
  (let ((projection (make-hash-table :test #'equal))
        (canonical (make-vector (length raw-values) nil))
        (index 0))
    (dolist (raw raw-values)
      (let ((tokens (etaf--class-tokens raw)))
        (puthash raw (cons t tokens) projection)
        (aset canonical index tokens)
        (setq index (1+ index))))
    (cons projection canonical)))

(defun etaf--host-cohort-specifications (runtime members)
  "Build provider specifications for cold RUNTIME MEMBERS with finite domains."
  (let ((specifications (make-vector (length members) nil))
        (domains (make-hash-table :test #'equal)))
    (dotimes (index (length members))
      (let* ((member (aref members index))
             (properties (etaf--host-update-properties member))
             (class-index (cl-position :class properties))
             (variants (and class-index (make-vector (length properties) nil))))
        (when class-index
          (let* ((key (etaf--host-cohort-program-key member))
                 (domain
                  (or (gethash key domains)
                      (puthash key
                               (etaf--host-cohort-class-domain
                                (gethash key (etaf-runtime-prepared-host-variants runtime)))
                               domains))))
            (setf (etaf--host-update-class-projection member) (car domain)
                  (etaf--host-update-provider-values member) (make-vector (length properties) nil))
            (aset variants class-index (cdr domain))))
        (aset specifications index
              (if variants
                  (vector (etaf--semantic-host-host-ref (etaf--host-update-semantic member))
                          properties variants)
                (vector (etaf--semantic-host-host-ref (etaf--host-update-semantic member))
                        properties)))))
    specifications))

(defun etaf--host-cohort-bind-storage (cohort)
  "Bind COHORT's sparse queues and dependency-independent value storage once."
  (let* ((members (etaf--host-cohort-members cohort))
         (count (length members))
         (values (make-vector count nil))
         (indices (make-hash-table :test #'eql)))
    (dotimes (index count)
      (let ((member (aref members index)))
        (puthash (etaf--host-update-effect-id member) index indices)
        (aset values index (etaf--host-update-provider-values member))))
    (setf (etaf--host-cohort-values cohort) values
          (etaf--host-cohort-effect-indices cohort) indices
          (etaf--host-cohort-dirty-indices cohort) (make-vector count 0)
          (etaf--host-cohort-dirty-epochs cohort) (make-vector count 0)
          (etaf--host-cohort-changed-indices cohort) (make-vector count 0))
    (etaf--host-cohort-bind-owners cohort)))

(defun etaf--host-cohort-interactive-effect-p (generation effect)
  "Whether GENERATION's EFFECT owns a non-text primitive property."
  (and effect (eq (etaf--generation-effect-kind effect) 'host-properties)
       (etaf--generation-effect-deps effect)
       (let ((semantic (etaf--generation-effect-semantic
                        generation (etaf--generation-effect-effect-id effect))))
         (and (etaf--semantic-host-p semantic)
              (cl-some
               (lambda (binding)
                 (let ((property (etaf--host-property-binding-property binding)))
                   (and (memq property etaf--host-update-properties)
                        (not (memq property '(:content :hover-content))))))
               (etaf--semantic-host-property-bindings semantic))))))

(defun etaf--host-cohort-text-effect-p (generation effect)
  "Whether GENERATION's EFFECT is a reactive pure-text primitive."
  (and effect (etaf--generation-effect-deps effect)
       (or (eq (etaf--generation-effect-kind effect) 'inline)
           (and (eq (etaf--generation-effect-kind effect) 'host-properties)
                (not (etaf--host-cohort-interactive-effect-p generation effect))
                (let ((semantic (etaf--generation-effect-semantic
                                 generation (etaf--generation-effect-effect-id effect))))
                  (and (etaf--semantic-host-p semantic)
                       (cl-some (lambda (binding)
                                  (memq (etaf--host-property-binding-property binding)
                                        '(:content :hover-content)))
                                (etaf--semantic-host-property-bindings semantic))))))))

(defun etaf--host-cohort-register-interactive (runtime)
  "Update RUNTIME's interactive and text IDs from the accepted effect delta."
  (let* ((generation (etaf-runtime-current-generation runtime))
         (ids (or (etaf-runtime-prepared-interactive-effect-ids runtime)
                  (setf (etaf-runtime-prepared-interactive-effect-ids runtime)
                        (make-hash-table :test #'eql))))
         (text-ids (or (etaf-runtime-prepared-text-effect-ids runtime)
                       (setf (etaf-runtime-prepared-text-effect-ids runtime)
                             (make-hash-table :test #'eql)))))
    ;; Retained IDs are only discovery hints; the current generation owns
    ;; membership, dependency edges and every eventual provider binding.
    (maphash
     (lambda (id _)
       (unless (etaf--host-cohort-interactive-effect-p
                generation (etaf--generation-effect generation id))
         (remhash id ids)))
     ids)
    (maphash
     (lambda (id _)
       (unless (etaf--host-cohort-text-effect-p
                generation (etaf--generation-effect generation id))
         (remhash id text-ids)))
     text-ids)
    (maphash
     (lambda (id _)
       (let ((effect (etaf--generation-effect generation id)))
         (cond ((etaf--host-cohort-interactive-effect-p generation effect)
                (puthash id t ids))
               ((etaf--host-cohort-text-effect-p generation effect)
                (puthash id t text-ids)))))
     (etaf-runtime-candidate-effects runtime))
    (setf (etaf-runtime-prepared-related-text-effect-ids runtime) nil)))

(defun etaf--host-cohort-interaction-members (runtime generation)
  "Return interactive IDs and source-coupled text IDs in RUNTIME GENERATION.
Read only the existing dependency graph.  Lazy or cyclic computed branches
without known ref roots are not evaluated to discover hypothetical work."
  (let ((roots (make-hash-table :test #'eq))
        (seen (make-hash-table :test #'eq))
        (memo (make-hash-table :test #'eq))
        (related (make-hash-table :test #'eql))
        (ids (hash-table-keys (etaf-runtime-prepared-interactive-effect-ids runtime))))
    (cl-labels
        ((collect (source)
           (unless (gethash source seen)
             (puthash source t seen)
             (cond ((etaf-ref-p source) (puthash source t roots))
                   ((etaf-computed-p source)
                    (when-let* ((effect (etaf-computed-effect source)))
                      (mapc #'collect (etaf-effect-deps effect)))))))
         (connected (source)
           (let ((known (gethash source memo)))
             (if known (eq known 'connected)
               ;; Mark before descending so a malformed cycle cannot recurse.
               (puthash source 'disconnected memo)
               (when (or (and (etaf-ref-p source) (gethash source roots))
                         (and (etaf-computed-p source)
                              (etaf-computed-effect source)
                              (cl-some #'connected
                                       (etaf-effect-deps (etaf-computed-effect source)))))
                 (puthash source 'connected memo)
                 t)))))
      (dolist (id ids)
        (mapc #'collect (etaf--generation-effect-deps (etaf--generation-effect generation id))))
      (maphash
       (lambda (id _)
         (when (cl-some #'connected
                        (etaf--generation-effect-deps (etaf--generation-effect generation id)))
           (puthash id t related)
           (push id ids)))
       (etaf-runtime-prepared-text-effect-ids runtime)))
    (setf (etaf-runtime-prepared-related-text-effect-ids runtime) related)
    ids))

(defvar etaf--host-cohort-idle-delay 0.15
  "Idle seconds before current interactive primitive bindings prepare.
Text sharing their reactive roots joins the same cohort; independent text
prepares only on real demand.")

(defun etaf--host-cohort-cancel (runtime)
  "Cancel RUNTIME's pending interactive preparation."
  (when-let* ((timer (etaf-runtime-prepared-host-timer runtime)))
    (cancel-timer timer)
    (setf (etaf-runtime-prepared-host-timer runtime) nil)))

(defun etaf--host-cohort-schedule (runtime)
  "Prepare RUNTIME's registered interactive programs at the normal idle boundary."
  (etaf--host-cohort-cancel runtime)
  (when-let* ((ids (etaf-runtime-prepared-interactive-effect-ids runtime))
              ((> (hash-table-count ids) 0)))
    (setf (etaf-runtime-prepared-host-timer runtime)
          (run-with-idle-timer etaf--host-cohort-idle-delay nil
                              #'etaf--host-cohort-idle-prepare runtime
                              (etaf-runtime-current-generation runtime)))))

(defun etaf--host-cohort-refresh-binding (runtime)
  "Refresh RUNTIME's two cohort caches against the current public binding token."
  (let ((generation (etaf-runtime-current-generation runtime))
        (token (ebox-update-binding-token (etaf-runtime-buffer runtime))))
    (unless (and (eq generation (etaf-runtime-prepared-host-generation runtime))
                 (eq token (etaf-runtime-prepared-host-binding-token runtime)))
      (etaf--host-update-reset runtime)
      (setf (etaf-runtime-prepared-host-binding-token runtime) token))))

(defun etaf--host-cohort-idle-prepare (runtime generation)
  "Prepare only RUNTIME's interactive IDs while GENERATION remains current."
  (setf (etaf-runtime-prepared-host-timer runtime) nil)
  (when (and (etaf-runtime-mounted-p runtime)
             (buffer-live-p (etaf-runtime-buffer runtime))
             (eq generation (etaf-runtime-current-generation runtime)))
    (if (or (etaf-runtime-flushing-p runtime) (ebox-transaction-active-p))
        (etaf--host-cohort-schedule runtime)
      (when
          (eq t
              (while-no-input
                (etaf--host-cohort-refresh-binding runtime)
                (let* ((cohort (etaf-runtime-prepared-host-cohort runtime))
                       (mapping (and cohort (etaf--host-cohort-effect-indices cohort)))
                       (ids (etaf--host-cohort-interaction-members runtime generation)))
                  (unless (and cohort (ebox-update-valid-p (etaf--host-cohort-operation cohort))
                               (cl-every (lambda (id) (gethash id mapping)) ids))
                    ;; Prepare only the interaction dependency group.  Text
                    ;; driven by an independent source stays demand-driven.
                    (setf (etaf-runtime-prepared-host-cohort runtime) nil
                          (etaf-runtime-prepared-host-members runtime) nil)
                    (let (members)
                      (dolist (id ids)
                        (unless (gethash id (etaf-runtime-prepared-host-rejections runtime))
                          (etaf--host-cohort-retire-overlap runtime id nil)
                          (when-let* ((member (etaf--host-update-for-effect runtime id t)))
                            (push member members))))
                      (setf (etaf-runtime-prepared-host-members runtime) members)
                      (etaf--host-cohort-prepare runtime members nil t))))))
        (setf (etaf-runtime-prepared-host-cohort runtime) nil
              (etaf-runtime-prepared-host-members runtime) nil)
        (etaf--host-cohort-schedule runtime)))))

(defun etaf--host-cohort-text-queue-p (runtime generation)
  "Whether RUNTIME's queued GENERATION effects are independent text work."
  (let ((related (etaf-runtime-prepared-related-text-effect-ids runtime)))
    (cl-every
     (lambda (id)
       (and (not (and related (gethash id related)))
            (etaf--host-cohort-text-effect-p
             generation (etaf--generation-effect generation id))))
     (etaf-runtime-dirty-effect-queue runtime))))

(defun etaf--host-cohort-retire-overlap (runtime effect-id text-p)
  "Retire the other RUNTIME cache before rebinding EFFECT-ID for TEXT-P.
A fresh binding may replace authoritative property spines; provider validity
alone does not establish that the old ETAF member still owns those cells."
  (let ((other (if text-p (etaf-runtime-prepared-host-members runtime)
                 (etaf-runtime-prepared-text-members runtime))))
    (when (cl-find effect-id other :key #'etaf--host-update-effect-id :test #'eql)
      (if text-p
          (setf (etaf-runtime-prepared-host-cohort runtime) nil
                (etaf-runtime-prepared-host-members runtime) nil)
        (setf (etaf-runtime-prepared-text-cohort runtime) nil
              (etaf-runtime-prepared-text-members runtime) nil)))))

(defun etaf--host-cohort-prepare (runtime members &optional text-p interactive-p)
  "Compile RUNTIME's MEMBERS into the interactive or TEXT-P demand cohort.
INTERACTIVE-P requires a non-text member to remain after provider rejections;
idle preparation must not compile an otherwise unused text-only remainder.
Return the cohort, or nil when the demanded set is empty or unsupported.
Unsupported members are removed according to the provider's cold proof report;
each unsuccessful member-specific pass strictly shrinks the finite pool."
  (let* ((generation (etaf-runtime-current-generation runtime))
         (buffer (etaf-runtime-buffer runtime))
         (rejections (if text-p (etaf-runtime-prepared-text-rejections runtime)
                       (etaf-runtime-prepared-host-rejections runtime))))
    ;; New source bindings may invalidate the previous operation, so no
    ;; failure or non-local exit may leave that operation available to apply.
    (if text-p (setf (etaf-runtime-prepared-text-cohort runtime) nil)
      (setf (etaf-runtime-prepared-host-cohort runtime) nil))
    (when members
      (etaf--host-cohort-record-variants runtime members)
      (let* ((cohort (etaf--host-cohort-create :runtime runtime :generation generation))
             (stage (lambda () (etaf--host-cohort-stage cohort)))
             (rollback (lambda () (etaf--host-cohort-rollback cohort)))
             (after-commit (lambda () (etaf--host-cohort-after-commit cohort)))
             done)
        (while (and members (not done)
                    (or (not interactive-p)
                        (cl-some (lambda (member)
                                   (etaf--host-cohort-interactive-effect-p
                                    generation (etaf--host-update-effect member)))
                                 members)))
          (let* ((vector (vconcat members))
                 (specifications (etaf--host-cohort-specifications runtime vector)))
            (setf (etaf--host-cohort-members cohort) vector
                  (etaf--host-cohort-operation cohort)
                  (ebox-update-prepare buffer specifications stage rollback after-commit))
            (if (etaf--host-cohort-operation cohort)
                (progn
                  (etaf--host-cohort-bind-storage cohort)
                  (if text-p (setf (etaf-runtime-prepared-text-cohort runtime) cohort)
                    (setf (etaf-runtime-prepared-host-cohort runtime) cohort))
                  (setq done t))
              (let* ((report (ebox-update-prepare-report buffer))
                     (index (plist-get report :member)))
                (if (and (eq (plist-get report :status) 'unsupported)
                         (integerp index) (<= 0 index) (< index (length vector)))
                    (let ((rejected (aref vector index)))
                      (puthash (etaf--host-update-effect-id rejected) report rejections)
                      (setq members (delq rejected members)))
                  (puthash 'cohort report rejections)
                  (setq done t))))))
        (setf (etaf-runtime-prepared-host-binding-token runtime)
              (ebox-update-binding-token buffer))
        (if text-p
            (setf (etaf-runtime-prepared-text-members runtime) members)
          (setf (etaf-runtime-prepared-host-members runtime) members))
        (if text-p (etaf-runtime-prepared-text-cohort runtime)
          (etaf-runtime-prepared-host-cohort runtime))))))

(defun etaf--host-cohort-for-queue (runtime)
  "Select RUNTIME's interactive/mixed or separate pure-text demand cohort.
Pure text never compiles the interactive member set.  Mixed source batches
still evaluate and publish through one cohort and one atomic provider call."
  (let ((generation (etaf-runtime-current-generation runtime)))
    (when (etaf--runtime-primitive-queue-p runtime generation)
      (etaf--host-cohort-refresh-binding runtime)
      (let* ((text-p (etaf--host-cohort-text-queue-p runtime generation))
             (cohort (if text-p (etaf-runtime-prepared-text-cohort runtime)
                       (etaf-runtime-prepared-host-cohort runtime)))
             (mapping (and cohort (etaf--host-cohort-effect-indices cohort)))
             (rejections (if text-p (etaf-runtime-prepared-text-rejections runtime)
                           (etaf-runtime-prepared-host-rejections runtime)))
             (members (if text-p (etaf-runtime-prepared-text-members runtime)
                        (etaf-runtime-prepared-host-members runtime)))
             (queue (etaf-runtime-dirty-effect-queue runtime))
             added (valid (not (gethash 'cohort rejections))))
        (while (and queue valid)
          (let* ((id (pop queue))
                 (index (and mapping (gethash id mapping)))
                 (member (or (and index (aref (etaf--host-cohort-members cohort) index))
                             (cl-find id members :key #'etaf--host-update-effect-id :test #'eql))))
            (unless member
              (unless (gethash id rejections)
                (etaf--host-cohort-retire-overlap runtime id text-p)
                (setq member (etaf--host-update-for-effect runtime id t)))
              (when member (push member members) (setq added t)))
            (unless member (setq valid nil))))
        (if text-p (setf (etaf-runtime-prepared-text-members runtime) members)
          (setf (etaf-runtime-prepared-host-members runtime) members))
        (when valid
          (when (or added (null cohort)
                    (not (ebox-update-valid-p (etaf--host-cohort-operation cohort))))
            (setq cohort (etaf--host-cohort-prepare runtime members text-p)))
          (when (and cohort
                     (eq (etaf--host-cohort-generation cohort) generation)
                     (eq (etaf-runtime-prepared-host-binding-token runtime)
                         (ebox-update-binding-token (etaf-runtime-buffer runtime)))
                     (ebox-update-valid-p (etaf--host-cohort-operation cohort)))
            (let ((queue (etaf-runtime-dirty-effect-queue runtime))
                  (mapping (etaf--host-cohort-effect-indices cohort))
                  (indices (etaf--host-cohort-dirty-indices cohort))
                  (epochs (etaf--host-cohort-dirty-epochs cohort))
                  (epoch (cl-incf (etaf--host-cohort-epoch cohort)))
                  (count 0))
              (while (and queue valid)
                (let ((index (gethash (pop queue) mapping)))
                  (if (null index) (setq valid nil)
                    (aset indices count index)
                    (aset epochs index epoch)
                    (setq count (1+ count)))))
              (when valid
                (setf (etaf--host-cohort-dirty-count cohort) count)
                cohort))))))))

(defun etaf--host-cohort-evaluate (cohort)
  "Evaluate only COHORT's captured dirty members using retained storage."
  (let ((members (etaf--host-cohort-members cohort))
        (indices (etaf--host-cohort-changed-indices cohort))
        (owner-indices (etaf--host-cohort-owner-indices cohort))
        (owners (etaf--host-cohort-owner-epochs cohort))
        (changed-owners (etaf--host-cohort-changed-owners cohort))
        (epoch (etaf--host-cohort-epoch cohort))
        (count 0) (owner-count 0))
    (setf (etaf--host-cohort-changed-count cohort) 0
          (etaf--host-cohort-changed-owner-count cohort) 0)
    (dotimes (position (etaf--host-cohort-dirty-count cohort))
      (let* ((index (aref (etaf--host-cohort-dirty-indices cohort) position))
             (member (aref members index)))
        (setf (etaf--host-update-staged-p member) nil)
        (funcall (etaf--host-update-evaluate-function member))
        (etaf--host-update-capture-versions member)
        (when (etaf--host-update-changed-p member)
          (aset indices count index)
          (setq count (1+ count))
          (when-let* (((etaf--host-update-lifecycle-p member))
                      (owner (aref owner-indices index))
                      ((/= (aref owners owner) epoch)))
            (aset owners owner epoch)
            (aset changed-owners owner-count owner)
            (setq owner-count (1+ owner-count))))))
    (setf (etaf--host-cohort-changed-count cohort) count
          (etaf--host-cohort-changed-owner-count cohort) owner-count))
  t)

(defun etaf--host-cohort-try-flush (runtime)
  "Publish RUNTIME's eligible primitive work as one atomic retained cohort."
  (when (and (etaf-runtime-dirty-effect-queue runtime)
             (not (etaf-runtime-root-dirty-p runtime)))
    (when-let* ((cohort (etaf--host-cohort-for-queue runtime)))
      (let (handled)
        (setf (etaf-runtime-flushing-p runtime) t)
        (unwind-protect
            (setq handled
                  (when (catch 'etaf-host-update-declined (etaf--host-cohort-evaluate cohort))
                    (if (zerop (etaf--host-cohort-changed-count cohort))
                        (progn (etaf--host-cohort-after-commit cohort) t)
                      (ebox-update-apply
                       (etaf--host-cohort-operation cohort) (etaf--host-cohort-values cohort)
                       (etaf--host-cohort-changed-indices cohort)
                       (etaf--host-cohort-changed-count cohort)))))
          (setf (etaf-runtime-flushing-p runtime) nil))
        (when (and handled (etaf-runtime-pending-p runtime)
                   (etaf-runtime-dirty-effect-queue runtime))
          (etaf-reactive-enqueue-runtime-flush
           (etaf-runtime-mount-epoch runtime) (etaf-runtime-flush-function runtime)
           (etaf-runtime-scheduler-context runtime)))
        handled))))

(provide 'etaf-host-cohort)
;;; etaf-host-cohort.el ends here
