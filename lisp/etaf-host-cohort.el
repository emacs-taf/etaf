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

(defun etaf--host-cohort-collect (runtime)
  "Bind RUNTIME's registered primitive effects into a pending member pool.
Members whose semantic cannot bind are rejected immediately; the provider's
compile runs later in `etaf--host-cohort-prepare'."
  (let* ((generation (etaf-runtime-current-generation runtime))
         (rejections (etaf-runtime-prepared-host-rejections runtime))
         members)
    (cl-labels
        ((collect
          (id)
          (when-let* ((semantic (etaf--pvec-get (etaf-generation-semantic-nodes generation) id)))
            (let* ((effect-id
                    (cond ((etaf--semantic-host-p semantic)
                           (etaf--semantic-host-effect-id semantic))
                          ((etaf--semantic-inline-range-p semantic)
                           (etaf--semantic-inline-range-effect-id semantic))))
                   (effect (and effect-id (etaf--generation-effect generation effect-id))))
              (when (and effect (etaf--generation-effect-deps effect))
                (let ((member (etaf--host-update-for-effect runtime effect-id)))
                  (if member (push member members)
                    (puthash effect-id '(:status unsupported :reason semantic-binding) rejections)))))
            (dolist (child (etaf--semantic-child-ids semantic)) (collect child)))))
      (collect (etaf-generation-root-semantic-id generation)))
    (setf (etaf-runtime-prepared-host-members runtime)
          (cons generation (nreverse members)))))

(defvar etaf--host-cohort-idle-delay 0.15
  "Idle seconds before a published generation compiles its primitive cohort.
A structural publish that arrives first discards the pending compile, and
input during the compile interrupts it, so rapid structural interactions
never wait for scenes they immediately replace.")

(defun etaf--host-cohort-cancel (runtime)
  "Drop RUNTIME's pending cohort compile and its idle timer."
  (when-let* ((timer (etaf-runtime-prepared-host-timer runtime)))
    (cancel-timer timer)
    (setf (etaf-runtime-prepared-host-timer runtime) nil)))

(defun etaf--host-cohort-schedule (runtime)
  "Compile RUNTIME's pending cohort once Emacs is idle."
  (etaf--host-cohort-cancel runtime)
  (when (cdr (etaf-runtime-prepared-host-members runtime))
    (setf (etaf-runtime-prepared-host-timer runtime)
          (run-with-idle-timer etaf--host-cohort-idle-delay nil
                               #'etaf--host-cohort-idle-prepare runtime))))

(defun etaf--host-cohort-idle-prepare (runtime)
  "Idle-timer entry: compile RUNTIME's pending cohort when it is still current."
  (setf (etaf-runtime-prepared-host-timer runtime) nil)
  (when (and (etaf-runtime-mounted-p runtime)
             (buffer-live-p (etaf-runtime-buffer runtime))
             (not (etaf-runtime-flushing-p runtime))
             (eq (car (etaf-runtime-prepared-host-members runtime))
                 (etaf-runtime-current-generation runtime)))
    (if (ebox-transaction-active-p)
        (etaf--host-cohort-schedule runtime)
      ;; Input arriving during the cold compile interrupts it.  An input that
      ;; only needs this cohort compiles it on demand; a structural one
      ;; replaces the generation, so the abandoned work is never repaid.
      (let ((pending (etaf-runtime-prepared-host-members runtime)))
        (when (eq t (while-no-input (etaf--host-cohort-prepare runtime)))
          (setf (etaf-runtime-prepared-host-cohort runtime) nil
                (etaf-runtime-prepared-host-members runtime) pending)
          (etaf--host-cohort-schedule runtime))))))

(defun etaf--host-cohort-prepare (runtime)
  "Compile RUNTIME's pending primitive members into one provider cohort.
Return the cohort, or nil when the pool is empty, stale or unsupported.
Unsupported members are removed according to the provider's cold proof report;
each unsuccessful member-specific pass strictly shrinks the finite pool."
  (let* ((generation (etaf-runtime-current-generation runtime))
         (buffer (etaf-runtime-buffer runtime))
         (rejections (etaf-runtime-prepared-host-rejections runtime))
         (pending (etaf-runtime-prepared-host-members runtime))
         (members (and (eq (car pending) generation) (cdr pending))))
    (etaf--host-cohort-cancel runtime)
    (setf (etaf-runtime-prepared-host-members runtime) nil)
    (when members
      (etaf--host-cohort-record-variants runtime members)
      (let* ((cohort (etaf--host-cohort-create :runtime runtime :generation generation))
             (stage (lambda () (etaf--host-cohort-stage cohort)))
             (rollback (lambda () (etaf--host-cohort-rollback cohort)))
             (after-commit (lambda () (etaf--host-cohort-after-commit cohort)))
             done)
        (while (and members (not done))
          (let* ((vector (vconcat members))
                 (specifications (etaf--host-cohort-specifications runtime vector)))
            (setf (etaf--host-cohort-members cohort) vector
                  (etaf--host-cohort-operation cohort)
                  (ebox-update-prepare buffer specifications stage rollback after-commit))
            (if (etaf--host-cohort-operation cohort)
                (progn
                  (etaf--host-cohort-bind-storage cohort)
                  (setf (etaf-runtime-prepared-host-cohort runtime) cohort)
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
        (etaf-runtime-prepared-host-cohort runtime)))))

(defun etaf--host-cohort-for-queue (runtime)
  "Select RUNTIME's known sparse work without discovering owners.
A generation whose cohort is still pending compiles it here on demand, but
only for an all-primitive queue: a structural queue replaces the generation."
  (let ((generation (etaf-runtime-current-generation runtime)))
    (when (and (null (etaf-runtime-prepared-host-cohort runtime))
               (eq (car (etaf-runtime-prepared-host-members runtime)) generation)
               (etaf--runtime-primitive-queue-p runtime generation))
      (etaf--host-cohort-prepare runtime)))
  (when-let* ((cohort (etaf-runtime-prepared-host-cohort runtime))
              ((eq (etaf--host-cohort-generation cohort)
                   (etaf-runtime-current-generation runtime)))
              ((eq (etaf-runtime-prepared-host-binding-token runtime)
                   (ebox-update-binding-token (etaf-runtime-buffer runtime))))
              ((ebox-update-valid-p (etaf--host-cohort-operation cohort))))
    (let ((queue (etaf-runtime-dirty-effect-queue runtime))
          (mapping (etaf--host-cohort-effect-indices cohort))
          (indices (etaf--host-cohort-dirty-indices cohort))
          (epochs (etaf--host-cohort-dirty-epochs cohort))
          (epoch (cl-incf (etaf--host-cohort-epoch cohort)))
          (count 0) (valid t))
      (while (and queue valid)
        (let ((index (gethash (pop queue) mapping)))
          (if (null index) (setq valid nil)
            (aset indices count index)
            (aset epochs index epoch)
            (setq count (1+ count)))))
      (when valid
        (setf (etaf--host-cohort-dirty-count cohort) count)
        cohort))))

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
