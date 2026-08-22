;;; etaf-runtime.el --- ETAF retained runtime and publication loop -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Runtime is the owner of mounted lifetime, retained Component instances,
;; reactive render effects, and the Ebox commit boundary.  It does not know
;; Ebox's private tree representation; Renderer is the only lowering port.

;;; Code:

(require 'cl-lib)
(require 'ebox)
(require 'etaf-view)
(require 'etaf-component)
(require 'etaf-reactive)
(require 'etaf-renderer)
(require 'etaf-context)
(require 'etaf-behavior)

(declare-function etaf--render-value-list "etaf-renderer" (value path))
(declare-function etaf--apply-inline-style-rules "etaf-renderer" (node styles &optional root-p))
(declare-function etaf--generated-host-ref "etaf-renderer" (props path))
(declare-function etaf--lower-resolved-semantic-host
                  "etaf-renderer" (name props content children range-child-p))
(declare-function etaf--inline-text-surface-properties
                  "etaf-renderer" (props))
(declare-function etaf--apply-inline-surface-properties
                  "etaf-renderer" (content surface))
(declare-function etaf-events-enable-input "etaf-events" (buffer))
(declare-function etaf-events-disable-input "etaf-events" (buffer))
(declare-function ebox-range-ref-present-p "ebox" (buffer-or-name range-ref))
(defvar etaf--render-runtime)
(defvar etaf--render-style-stack)
(defvar etaf--render-parent-style-stack)
(defvar etaf--current-context)

(define-error 'etaf-runtime-error "ETAF runtime error")

(cl-defstruct (etaf--component-instance
               (:constructor etaf--component-instance-create))
  "Retained state and lifecycle for one logical Component call."
  spec
  identity
  scope
  render-function
  context
  mounted-hooks
  updated-hooks
  unmounted-hooks
  resource-key
  (mounted-p nil))

(cl-defstruct (etaf--semantic-component
               (:constructor etaf--semantic-component-create))
  semantic-id identity input-effect-id effect-id resource-key props slots
  input-props input-slots output-signature artifact-key
  path caller-style-stack input-deps deps
  parent-id caller-component-id child-ids raw-slot-reader-p
  publication-kind output-range-id output-range-ref
  context-frame context-deps
  (composition-version 0))

(cl-defstruct (etaf--semantic-host (:constructor etaf--semantic-host-create))
  semantic-id identity parent-id child-ids host-ref key name props-signature
  content content-parts path style-identity (composition-version 0))

(cl-defstruct (etaf--semantic-range (:constructor etaf--semantic-range-create))
  semantic-id identity effect-id kind parent-id component-id token range-ref
  path caller-style-stack output-signature deps artifact-key item-host-ids
  item-identity-index context-deps (composition-version 0))

(cl-defstruct (etaf--semantic-inline-range
               (:constructor etaf--semantic-inline-range-create))
  semantic-id identity effect-id parent-id component-id token path
  surface-properties output deps context-deps (composition-version 0))

(cl-defstruct (etaf--semantic-slot-range
               (:constructor etaf--semantic-slot-range-create))
  semantic-id identity effect-id parent-id owner-component-id
  consumer-component-id token name range-ref path style-stack
  output-signature deps artifact-key item-host-ids item-identity-index
  context-deps
  (composition-version 0))

(cl-defstruct (etaf--semantic-root (:constructor etaf--semantic-root-create))
  "Immutable semantic Root owner stored at generation node zero."
  semantic-id effect-id input-signature deps)

(cl-defstruct (etaf--generation-effect
               (:constructor etaf--generation-effect-create))
  "Immutable generation scheduling target."
  effect-id kind semantic-id deps target)

(cl-defstruct (etaf--contribution-index
               (:constructor etaf--contribution-index-create))
  "Persistent generation contribution delta rooted at BASE."
  base handlers host-props contexts themes behaviors context-consumers lifecycle
  host-removals semantic-removals)

(cl-defstruct (etaf--generation-participant
               (:constructor etaf--generation-participant-create))
  runtime old candidate (state 'unpublished))

(cl-defstruct (etaf-generation
               (:constructor etaf--generation-create))
  generation-id root-semantic-id semantic-nodes effect-map
  source-effects effect-sources parent-table children-table
  resource-membership identity-index indexes)

(cl-defstruct (etaf--pvec-node (:constructor etaf--pvec-node-create))
  "One sparse immutable 32-way generation index node."
  children value)

(cl-defstruct (etaf--generation-metrics
               (:constructor etaf--generation-metrics-create))
  (node-visits 0) (node-copies 0) (effect-visits 0) (source-visits 0))

(defun etaf--pvec-get (root id &optional metrics kind)
  "Return integer ID value from sparse ROOT, recording METRICS KIND visits."
  (let ((node root) (level 6))
    (while (and node (>= level 0))
      (when metrics
        (cl-incf (etaf--generation-metrics-node-visits metrics))
        (pcase kind
          ('effect (cl-incf (etaf--generation-metrics-effect-visits metrics)))
          ('source (cl-incf (etaf--generation-metrics-source-visits metrics)))))
      (setq node (and (etaf--pvec-node-children node)
                      (aref (etaf--pvec-node-children node)
                            (logand 31 (ash id (* -5 level)))))
            level (1- level)))
    (and node (etaf--pvec-node-value node))))

(defun etaf--pvec-put (root id value &optional metrics)
  "Return sparse ROOT with ID set to VALUE, recording copies in METRICS."
  (cl-labels
      ((put (node level)
         (when metrics
           (cl-incf (etaf--generation-metrics-node-visits metrics))
           (cl-incf (etaf--generation-metrics-node-copies metrics)))
         (if (< level 0)
             (etaf--pvec-node-create :value value)
           (let* ((children (copy-sequence
                             (or (and node (etaf--pvec-node-children node))
                                 (make-vector 32 nil))))
                  (slot (logand 31 (ash id (* -5 level)))))
             (aset children slot (put (aref children slot) (1- level)))
             (etaf--pvec-node-create :children children)))))
    (put root 6)))

(defun etaf--pvec-put-many (root entries &optional metrics)
  "Return sparse ROOT after applying ENTRIES in one persistent batch.
ENTRIES is a list of cons cells `(ID . VALUE)'.  METRICS, when non-nil, records
physical trie node visits/copies.  Updates sharing a trie path
are grouped before copying, so each touched vector node is copied once per
batch rather than once per entry.  Later entries for the same ID win, matching
the sequential `etaf--pvec-put' contract."
  (if (null entries)
      root
    (let ((values (make-hash-table :test #'eql))
          (ids nil)
          (missing (make-symbol "etaf-pvec-missing")))
      (dolist (entry entries)
        (let ((id (car entry)))
          (when (eq (gethash id values missing) missing)
            (push id ids))
          (puthash id (cdr entry) values)))
      (setq ids (nreverse ids))
      (cl-labels
          ((put-batch (node level batch)
             (when metrics
               (cl-incf (etaf--generation-metrics-node-visits metrics))
               (cl-incf (etaf--generation-metrics-node-copies metrics)))
             (if (< level 0)
                 (etaf--pvec-node-create
                  :value (gethash (car batch) values))
               (let ((children
                      (copy-sequence
                       (or (and node (etaf--pvec-node-children node))
                           (make-vector 32 nil))))
                     (groups (make-hash-table :test #'eql)))
                 (dolist (id batch)
                   (let ((slot (logand 31 (ash id (* -5 level)))))
                     (puthash slot (cons id (gethash slot groups)) groups)))
                 (maphash
                  (lambda (slot group)
                    (aset children slot
                          (put-batch
                           (aref children slot)
                           (1- level)
                           group)))
                  groups)
                 (etaf--pvec-node-create :children children)))))
        (put-batch root 6 ids)))))

(cl-defstruct (etaf-runtime
               (:constructor etaf--runtime-create))
  "Mounted ETAF application runtime."
  buffer
  root-view
  root-node
  scope
  root-effect-id
  root-range-id
  candidate-root-deps
  root-view-cache
  root-dirty-p
  instances
  resource-registry
  mount-epoch
  next-resource-id
  next-effect-id
  next-semantic-id
  current-generation
  artifact-registry
  candidate-artifacts
  candidate-effects
  candidate-source-deltas
  route-token
  route-sources
  dirty-effect-ids
  dirty-effect-queue
  handlers
  host-props
  focus-ref
  behaviors
  candidate-live
  candidate-semantic-nodes
  candidate-component-envs
  candidate-graph-nodes
  candidate-identity-entries
  candidate-graph-children
  candidate-removed-semantic-ids
  candidate-removed-effect-ids
  candidate-removed-host-refs
  candidate-rendered-identities
  candidate-updated-component-identities
  candidate-generation-metrics
  candidate-full-rebuild-p
  range-artifact-registry
  candidate-range-artifacts
  candidate-invalidated-artifact-keys
  candidate-inline-host-ids
  candidate-eager-range-changes
  candidate-handlers
  candidate-host-props
  candidate-behaviors
  behavior-resource-keys
  candidate-behavior-resource-keys
  candidate-created
  candidate-old-instances
  (mounted-p t)
  flushing-p
  pending-p
  diagnostics
  (event-depth 0))

(defvar etaf--mount-epoch-counter 0)

(defvar etaf--current-component-identity nil)
(defvar etaf--current-component-semantic-id nil)
(defvar etaf--current-semantic-parent-id 0)
(defvar etaf--current-range-item-index nil)
(defvar etaf--rendering-range-p nil)
(defvar etaf--rendering-component-effect-p nil)
(defvar etaf--rendered-range-container-nodes nil)
(defvar etaf--runtime-force-full-component-render-p nil
  "Non-nil only while a failed local anchor proof rebuilds all Components.")
(defvar etaf--runtime-fixed-point-stamps nil
  "Dynamic Runtime flush table of evaluated effect input/version tuples.")
(defvar etaf--runtime-fixed-point-steps 0
  "Number of effect evaluations recorded in the current Runtime flush.")
(defvar etaf--runtime-fixed-point-step-bound nil
  "Graph-derived safety bound for one Runtime fixed-point flush.")
(defvar etaf--runtime-fixed-point-history nil
  "Ordered fixed-point effect/edge trace for the current Runtime flush.")

(defun etaf--contribution-index-values (index slot)
  "Return INDEX delta values for SLOT."
  (pcase slot
    ('handlers (etaf--contribution-index-handlers index))
    ('host-props (etaf--contribution-index-host-props index))
    ('contexts (etaf--contribution-index-contexts index))
    ('themes (etaf--contribution-index-themes index))
    ('behaviors (etaf--contribution-index-behaviors index))
    ('context-consumers (etaf--contribution-index-context-consumers index))
    ('lifecycle (etaf--contribution-index-lifecycle index))))

(defun etaf--generation-index-lookup (generation slot key)
  "Return committed KEY contribution in GENERATION SLOT."
  (let ((index (and generation (etaf-generation-indexes generation))) found)
    (while (and index (not found))
      (if (member key (if (memq slot '(handlers host-props))
                          (etaf--contribution-index-host-removals index)
                        (etaf--contribution-index-semantic-removals index)))
          (setq index nil)
        (if-let ((entry (assoc key
                              (etaf--contribution-index-values index slot))))
            (setq found entry)
          (setq index (etaf--contribution-index-base index)))))
    (cdr found)))

(defun etaf--generation-index-entries (generation slot)
  "Return effective committed entries for GENERATION SLOT."
  (let ((index (and generation (etaf-generation-indexes generation)))
        (seen (make-hash-table :test #'equal)) result)
    (while index
      (dolist (key (if (memq slot '(handlers host-props))
                       (etaf--contribution-index-host-removals index)
                     (etaf--contribution-index-semantic-removals index)))
        (puthash key t seen))
      (dolist (entry (etaf--contribution-index-values index slot))
        (unless (gethash (car entry) seen)
          (puthash (car entry) t seen)
          (push entry result)))
      (setq index (unless (eq slot 'lifecycle)
                    (etaf--contribution-index-base index))))
    (nreverse result)))

(defun etaf--generation-validate-context-acyclic (generation)
  "Reject Context provider/consumer cycles in GENERATION."
  (let ((edges (make-hash-table :test #'eql))
        (visiting (make-hash-table :test #'eql))
        (visited (make-hash-table :test #'eql)))
    (dolist (entry (etaf--generation-index-entries
                    generation 'context-consumers))
      (let ((provider-id (caar entry)))
        (dolist (effect-id (cdr entry))
          (when-let ((effect (etaf--generation-effect generation effect-id)))
            (let ((consumer-id (etaf--generation-effect-semantic-id effect)))
              (unless (= provider-id consumer-id)
                (cl-pushnew consumer-id
                            (gethash provider-id edges) :test #'eql)))))))
    (cl-labels
        ((visit
          (node path)
          (when (gethash node visiting)
            (signal 'etaf-context-error
                    (list "Context provider/consumer cycle"
                          (nreverse (cons node path)))))
          (unless (gethash node visited)
            (puthash node t visiting)
            (dolist (next (gethash node edges))
              (visit next (cons node path)))
            (remhash node visiting)
            (puthash node t visited))))
      (maphash (lambda (node _) (visit node nil)) edges)))
  generation)

(defun etaf-runtime-handler-for (runtime host-ref)
  "Return committed handler entries for HOST-REF in RUNTIME."
  (etaf--generation-index-lookup
   (etaf-runtime-current-generation runtime) 'handlers host-ref))

(defun etaf-runtime-handler-entries (runtime)
  "Return committed handler contribution entries for RUNTIME."
  (copy-tree (etaf--generation-index-entries
              (etaf-runtime-current-generation runtime) 'handlers)))

(defun etaf-runtime-host-props-for (runtime host-ref)
  "Return committed semantic Host props for HOST-REF in RUNTIME."
  (etaf--generation-index-lookup
   (etaf-runtime-current-generation runtime) 'host-props host-ref))

(defun etaf-runtime-host-props-entries (runtime)
  "Return committed Host contribution entries for RUNTIME."
  (copy-tree (etaf--generation-index-entries
              (etaf-runtime-current-generation runtime) 'host-props)))

(defun etaf--runtime-build-contribution-indexes (runtime base full-p)
  "Build RUNTIME immutable generation contributions over BASE.
FULL-P means candidate tables describe the complete mounted tree."
  (let (handler-additions prop-additions context-additions theme-additions
        behavior-membership context-consumer-additions lifecycle-membership
        changed-component-ids)
    (maphash (lambda (key value)
               (push (cons (copy-tree key) (copy-tree value))
                     handler-additions))
             (etaf-runtime-candidate-handlers runtime))
    (maphash (lambda (key value)
               (push (cons (copy-tree key) (copy-tree value)) prop-additions))
             (etaf-runtime-candidate-host-props runtime))
    (maphash
     (lambda (_identity semantic)
       (let* ((semantic-id (etaf--semantic-component-semantic-id semantic))
              (effect-id (etaf--semantic-component-effect-id semantic))
              (old-semantic
               (and base
                    (etaf--pvec-get (etaf-generation-semantic-nodes base)
                                    semantic-id)))
              (frame (etaf--semantic-component-context-frame semantic))
              (theme (and frame
                          (gethash 'theme (etaf-context-values frame)
                                   etaf--context-missing))))
         (push semantic-id changed-component-ids)
         (push (cons semantic-id frame) context-additions)
         (dolist (dependency
                  (cl-delete-duplicates
                   (append (copy-sequence
                            (and old-semantic
                                 (etaf--semantic-component-context-deps
                                  old-semantic)))
                           (copy-sequence
                            (etaf--semantic-component-context-deps semantic)))
                   :test #'equal))
           (let ((consumers
                  (delq effect-id
                        (copy-sequence
                         (etaf--generation-index-lookup
                          base 'context-consumers dependency)))))
             (when (member dependency
                           (etaf--semantic-component-context-deps semantic))
               (push effect-id consumers))
             (push (cons (copy-tree dependency)
                         (sort consumers #'<))
                   context-consumer-additions)))
         (unless (eq theme etaf--context-missing)
           (push (cons semantic-id theme) theme-additions))))
     (etaf-runtime-candidate-semantic-nodes runtime))
    (maphash
     (lambda (semantic-id semantic)
       (let* ((effect-id
               (cond ((etaf--semantic-range-p semantic)
                      (etaf--semantic-range-effect-id semantic))
                     ((etaf--semantic-inline-range-p semantic)
                      (etaf--semantic-inline-range-effect-id semantic))
                     ((etaf--semantic-slot-range-p semantic)
                      (etaf--semantic-slot-range-effect-id semantic))))
              (new-deps
               (cond ((etaf--semantic-range-p semantic)
                      (etaf--semantic-range-context-deps semantic))
                     ((etaf--semantic-inline-range-p semantic)
                      (etaf--semantic-inline-range-context-deps semantic))
                     ((etaf--semantic-slot-range-p semantic)
                      (etaf--semantic-slot-range-context-deps semantic))))
              (old (and base effect-id
                        (etaf--pvec-get (etaf-generation-semantic-nodes base)
                                        semantic-id)))
              (old-deps
               (cond ((etaf--semantic-range-p old)
                      (etaf--semantic-range-context-deps old))
                     ((etaf--semantic-inline-range-p old)
                      (etaf--semantic-inline-range-context-deps old))
                     ((etaf--semantic-slot-range-p old)
                      (etaf--semantic-slot-range-context-deps old)))))
         (when effect-id
           (dolist (dependency
                    (cl-delete-duplicates
                     (append (copy-sequence old-deps)
                             (copy-sequence new-deps))
                     :test #'equal))
             (let ((consumers
                    (delq effect-id
                          (copy-sequence
                           (etaf--generation-index-lookup
                            base 'context-consumers dependency)))))
               (when (member dependency new-deps)
                 (push effect-id consumers))
               (push (cons (copy-tree dependency) (sort consumers #'<))
                     context-consumer-additions))))))
     (etaf-runtime-candidate-graph-nodes runtime))
    (maphash
     (lambda (identity state)
       (push
        (cons (copy-tree identity)
              (copy-tree
               (or (gethash identity
                            (etaf-runtime-candidate-behavior-resource-keys
                             runtime))
                   (etaf-behavior-spec-name (car state)))))
        behavior-membership))
     (etaf-runtime-candidate-behaviors runtime))
    (dolist (identity
             (cl-delete-duplicates
              (append (copy-sequence
                       (etaf-runtime-candidate-rendered-identities runtime))
                      (copy-sequence
                       (etaf-runtime-candidate-updated-component-identities
                        runtime)))
              :test #'equal))
      (push (cons (copy-tree identity) 'updated) lifecycle-membership))
    (etaf--contribution-index-create
     :base (and (not full-p) base (etaf-generation-indexes base))
     :handlers (nreverse handler-additions)
     :host-props (nreverse prop-additions)
     :contexts (nreverse context-additions)
     :themes (nreverse theme-additions)
     :behaviors (nreverse behavior-membership)
     :context-consumers (nreverse context-consumer-additions)
     :lifecycle (nreverse lifecycle-membership)
     :host-removals
     (cl-remove-if
      (lambda (host-ref)
        (gethash host-ref (etaf-runtime-candidate-host-props runtime)))
      (copy-sequence (etaf-runtime-candidate-removed-host-refs runtime)))
     :semantic-removals
     (append changed-component-ids
             (copy-sequence
              (etaf-runtime-candidate-removed-semantic-ids runtime))))))

(defun etaf-runtime-generation (runtime)
  "Return RUNTIME's committed generation id."
  (if-let ((generation (etaf-runtime-current-generation runtime)))
      (etaf-generation-generation-id generation)
    0))

(defun etaf--semantic-backend-range-artifact-key (semantic)
  "Return external artifact key for direct or slot Range SEMANTIC."
  (if (etaf--semantic-range-p semantic)
      (etaf--semantic-range-artifact-key semantic)
    (etaf--semantic-slot-range-artifact-key semantic)))

(defun etaf--semantic-backend-range-ref (semantic)
  "Return Ebox range ref for direct or slot Range SEMANTIC."
  (if (etaf--semantic-range-p semantic)
      (etaf--semantic-range-range-ref semantic)
    (etaf--semantic-slot-range-range-ref semantic)))

(defun etaf--semantic-backend-range-container-component-id (semantic)
  "Return the Component containing backend Range SEMANTIC's artifact."
  (if (etaf--semantic-range-p semantic)
      (etaf--semantic-range-component-id semantic)
    (etaf--semantic-slot-range-consumer-component-id semantic)))

(defun etaf--generation-semantic (generation identity)
  "Return IDENTITY semantic node from GENERATION."
  (when-let ((id (gethash identity (etaf-generation-identity-index generation))))
    (etaf--pvec-get (etaf-generation-semantic-nodes generation) id)))

(defun etaf--generation-effect-semantic (generation effect-id)
  "Return EFFECT-ID semantic node from GENERATION."
  (when-let ((effect (etaf--pvec-get
                      (etaf-generation-effect-map generation) effect-id)))
    (etaf--pvec-get (etaf-generation-semantic-nodes generation)
                    (etaf--generation-effect-semantic-id effect))))

(defun etaf--generation-effect (generation effect-id)
  "Return immutable EFFECT-ID scheduling record from GENERATION."
  (etaf--pvec-get (etaf-generation-effect-map generation) effect-id))

(defun etaf--runtime-scheduled-semantic-live-p (generation effect semantic)
  "Return whether scheduled EFFECT still has a live owner in GENERATION.

The source index is persistent across local generations, so a removed
semantic node must not be allowed to run merely because an old effect record
is still present during the current overlay.  Root-level ranges/inline ranges
may legitimately have no Component owner; non-root ranges must retain their
owning Component node."
  (and effect semantic
       (let ((nodes (etaf-generation-semantic-nodes generation)))
         (cond
          ((etaf--semantic-component-p semantic)
           (etaf--pvec-get nodes
                           (etaf--semantic-component-semantic-id semantic)))
          ((etaf--semantic-range-p semantic)
           (or (null (etaf--semantic-range-component-id semantic))
               (etaf--pvec-get nodes
                               (etaf--semantic-range-component-id semantic))))
          ((etaf--semantic-slot-range-p semantic)
           (or (null (etaf--semantic-slot-range-consumer-component-id semantic))
               (etaf--pvec-get
                nodes
                (etaf--semantic-slot-range-consumer-component-id semantic))))
          ((etaf--semantic-inline-range-p semantic)
           (or (null (etaf--semantic-inline-range-component-id semantic))
               (etaf--pvec-get
                nodes
                (etaf--semantic-inline-range-component-id semantic))))
          (t nil)))))

(defun etaf--generation-source-effects (generation source)
  "Return current effect ids for SOURCE in GENERATION."
  (etaf--pvec-get (etaf-generation-source-effects generation)
                  (etaf-reactive-source-id source)))

(defvar etaf--runtime-table (make-hash-table :test #'eq)
  "Buffer -> mounted ETAF Runtime table.")

(defvar etaf--runtime-route-registry
  (make-hash-table :test #'eql :weakness 'value)
  "Mount epoch -> live Runtime weak-value registry.")

(defun etaf--runtime-enqueue-effect (runtime effect-id)
  "Append EFFECT-ID once to RUNTIME's stable FIFO work queue."
  (unless (gethash effect-id (etaf-runtime-dirty-effect-ids runtime))
    (puthash effect-id t (etaf-runtime-dirty-effect-ids runtime))
    (setf (etaf-runtime-dirty-effect-queue runtime)
          (nconc (etaf-runtime-dirty-effect-queue runtime)
                 (list effect-id)))))

(defun etaf--runtime-fixed-point-safe-hash (value)
  "Return a stable hash for immutable fixed-point VALUE, or nil.
Candidate semantic output is diagnostic evidence, not authority; malformed or
cyclic diagnostic payloads therefore fail closed without preventing the normal
transaction from deciding whether the value changed."
  (condition-case _err
      (sxhash-equal value)
    (error nil)))

(defun etaf--runtime-candidate-effect (runtime effect-id)
  "Return candidate EFFECT-ID staged in RUNTIME's overlay."
  (let ((table (etaf-runtime-candidate-effects runtime)))
    (and (hash-table-p table) (gethash effect-id table))))

(defun etaf--runtime-effect-semantic-stamp (runtime generation effect)
  "Return candidate-aware semantic facts for EFFECT in GENERATION/RUNTIME."
  (let* ((effect-id (and effect (etaf--generation-effect-effect-id effect)))
         (semantic-id (and effect
                           (etaf--generation-effect-semantic-id effect)))
         (candidate (and semantic-id
                         (hash-table-p
                          (etaf-runtime-candidate-graph-nodes runtime))
                         (gethash semantic-id
                                  (etaf-runtime-candidate-graph-nodes runtime))))
         (semantic (or candidate
                       (and generation semantic-id
                            (etaf--generation-effect-semantic
                             generation effect-id))))
         (facts
          (cond
           ((etaf--semantic-component-p semantic)
            (list (etaf--semantic-component-composition-version semantic)
                  (etaf--semantic-component-input-props semantic)
                  (etaf--semantic-component-input-slots semantic)
                  (etaf--semantic-component-context-deps semantic)
                  (etaf--semantic-component-output-signature semantic)))
           ((etaf--semantic-range-p semantic)
            (list (etaf--semantic-range-composition-version semantic)
                  (etaf--semantic-range-output-signature semantic)
                  (etaf--semantic-range-context-deps semantic)))
           ((etaf--semantic-slot-range-p semantic)
            (list (etaf--semantic-slot-range-composition-version semantic)
                  (etaf--semantic-slot-range-output-signature semantic)
                  (etaf--semantic-slot-range-context-deps semantic)))
           ((etaf--semantic-inline-range-p semantic)
            (list (etaf--semantic-inline-range-composition-version semantic)
                  (etaf--semantic-inline-range-output semantic)
                  (etaf--semantic-inline-range-context-deps semantic)))
           (t nil))))
    (list :effect-id effect-id
          :kind (and effect (etaf--generation-effect-kind effect))
          :semantic-id semantic-id
          :candidate-p (and candidate t)
          :facts-hash (etaf--runtime-fixed-point-safe-hash facts))))

(defun etaf--runtime-effect-input-version-tuple (runtime generation effect-id)
  "Return candidate-aware tuple for EFFECT-ID in RUNTIME GENERATION.
The tuple includes source versions, candidate semantic facts, and the exact
effect-to-source edges.  It is intentionally immutable and suitable as an
`equal' hash key for one flush."
  (let* ((effect (or (etaf--runtime-candidate-effect runtime effect-id)
                     (and generation
                          (etaf--generation-effect generation effect-id))))
         (deps (and effect (etaf--generation-effect-deps effect)))
         (edges
          (sort
           (mapcar (lambda (source)
                     (list (etaf-reactive-source-id source)
                           (cond ((etaf-ref-p source)
                                  (etaf-ref-version source))
                                 ((etaf-computed-p source)
                                  (etaf-computed-version source))
                                 (t 0))))
                   deps)
           (lambda (left right) (< (car left) (car right))))))
    (list :mount-epoch (etaf-runtime-mount-epoch runtime)
          :generation-id (and generation
                              (etaf-generation-generation-id generation))
          :effect (etaf--runtime-effect-semantic-stamp
                   runtime generation effect)
          :edges edges)))

(defun etaf--runtime-fixed-point-graph-size (runtime generation)
  "Return graph-derived counts and a finite flush bound for RUNTIME GENERATION."
  (let ((nodes (or (and (hash-table-p
                        (etaf-runtime-candidate-graph-nodes runtime))
                      (hash-table-count
                       (etaf-runtime-candidate-graph-nodes runtime)))
                   0))
        (edges 0)
        (sources 0)
        (effect-count (max 1 (etaf-runtime-next-effect-id runtime))))
    (when (hash-table-p (etaf-runtime-candidate-effects runtime))
      (maphash
       (lambda (_id effect)
         (cl-incf edges (length (etaf--generation-effect-deps effect))))
       (etaf-runtime-candidate-effects runtime)))
    (when generation
      (let ((root (etaf-generation-effect-sources generation)))
        (cl-labels
            ((walk (node)
               (when node
                 (when (etaf--pvec-node-value node)
                   (cl-incf sources))
                 (let ((children (etaf--pvec-node-children node)))
                   (when children
                     (dotimes (index (length children))
                       (walk (aref children index))))))))
          (walk root))))
    (setq nodes (max nodes effect-count)
          ;; The committed source index may contain effects not staged in the
          ;; candidate.  Count their source edges conservatively from the
          ;; monotonic effect allocator, while retaining the explicit edge
          ;; count for diagnostics and the bound itself.
          edges (max edges effect-count)
          sources (max sources (hash-table-count
                               (etaf-runtime-route-sources runtime))))
    (list :nodes nodes :edges edges :sources sources
          :bound (max 16 (* 2 (+ 1 nodes edges sources))))))

(defun etaf--runtime-record-effect-input-version (runtime generation effect-id)
  "Record one EFFECT-ID tuple for RUNTIME GENERATION, or signal non-convergence."
  (when etaf--runtime-fixed-point-stamps
    (cl-incf etaf--runtime-fixed-point-steps)
    (when (and etaf--runtime-fixed-point-step-bound
               (> etaf--runtime-fixed-point-steps
                  etaf--runtime-fixed-point-step-bound))
      (signal 'etaf-runtime-error
              (list :non-converging-effect-steps
                    :bound etaf--runtime-fixed-point-step-bound
                    :steps etaf--runtime-fixed-point-steps
                    :effect-id effect-id)))
    (let* ((tuple (etaf--runtime-effect-input-version-tuple
                   runtime generation effect-id))
           (entry (list :effect-id effect-id
                        :tuple tuple
                        :edges (plist-get tuple :edges))))
      (when (gethash tuple etaf--runtime-fixed-point-stamps)
        (signal 'etaf-runtime-error
                (list :non-converging-effect-tuple tuple
                      :path (nreverse (cons entry
                                            etaf--runtime-fixed-point-history)))))
      (puthash tuple t etaf--runtime-fixed-point-stamps)
      (push entry etaf--runtime-fixed-point-history))))

(defun etaf--runtime-route-scheduler (route source)
  "Route dirty SOURCE through opaque ROUTE to its current generation."
  (when-let ((runtime
              (gethash (etaf-runtime-route-mount-epoch route)
                       etaf--runtime-route-registry)))
    (when (etaf-runtime-mounted-p runtime)
      (dolist (effect-id
               (etaf--generation-source-effects
                (etaf-runtime-current-generation runtime) source))
        (when (etaf--generation-effect
               (etaf-runtime-current-generation runtime) effect-id)
          (etaf--runtime-enqueue-effect runtime effect-id)
          (when (equal effect-id (etaf-runtime-root-effect-id runtime))
            (setf (etaf-runtime-root-dirty-p runtime) t))))
      (etaf-reactive-enqueue-runtime-flush
       (etaf-runtime-mount-epoch runtime)
       (lambda () (etaf--runtime-request-flush runtime))))))

(defun etaf--runtime-evaluate-root-candidate (runtime)
  "Evaluate RUNTIME root while privately collecting dependencies."
  (let (deps value)
    (let ((etaf--runtime-dependency-collector
           (lambda (source) (cl-pushnew source deps :test #'eq)))
          (etaf--active-effect nil)
          (etaf--render-phase-p t))
      (setq value (etaf--runtime-evaluate-root runtime)))
    (setf (etaf-runtime-candidate-root-deps runtime) (nreverse deps))
    value))

(defvar etaf--current-runtime nil
  "Runtime owning the current setup, lifecycle, or event operation.")

(defun etaf-current-runtime ()
  "Return the dynamically active Runtime, or nil outside a Runtime."
  etaf--current-runtime)

(defun etaf-runtime-set-focus-ref (runtime host-ref)
  "Set RUNTIME's focused Host reference to HOST-REF and return it."
  (setf (etaf-runtime-focus-ref runtime) host-ref)
  host-ref)

(defun etaf-runtime-event-begin (runtime)
  "Enter one logical event batch for mounted RUNTIME."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (cl-incf (etaf-runtime-event-depth runtime))
  runtime)

(defun etaf-runtime-event-end (runtime)
  "Leave RUNTIME's logical event batch and publish pending state once."
  (when (and (etaf-runtime-p runtime)
             (etaf-runtime-mounted-p runtime))
    (setf (etaf-runtime-event-depth runtime)
          (max 0 (1- (etaf-runtime-event-depth runtime))))
    (when (and (zerop (etaf-runtime-event-depth runtime))
               (etaf-runtime-pending-p runtime))
      (setf (etaf-runtime-pending-p runtime) nil)
      (etaf--runtime-request-flush runtime)))
  runtime)

(defun etaf-runtime-for-buffer (buffer-or-name)
  "Return the live Runtime mounted in BUFFER-OR-NAME, or nil."
  (let ((buffer (get-buffer buffer-or-name)))
    (and buffer (gethash buffer etaf--runtime-table))))

(defun etaf-runtime-require-mounted (&optional runtime)
  "Return mounted RUNTIME or the Runtime in the current buffer.

Signal an ETAF runtime error before any downstream action or renderer lookup
when the requested boundary is no longer mounted."
  (let ((runtime (or runtime etaf--current-runtime
                     (and (buffer-live-p (current-buffer))
                          (gethash (current-buffer) etaf--runtime-table)))))
    (unless (and (etaf-runtime-p runtime)
                 (etaf-runtime-mounted-p runtime))
      (signal 'etaf-runtime-error
              (list "ETAF runtime is not mounted")))
    runtime))

(defun etaf--runtime-watch-scheduler (runtime job _flush)
  "Run watcher JOB while RUNTIME remains mounted."
  (when (etaf-runtime-mounted-p runtime)
    (funcall job)))

(defun etaf--runtime-call-with-component-env (runtime component-id function)
  "Call FUNCTION in RUNTIME candidate/committed COMPONENT-ID environment."
  (let* ((generation (etaf-runtime-current-generation runtime))
         (env (and component-id
                   (gethash component-id
                            (etaf-runtime-candidate-component-envs runtime))))
         (base (and component-id generation
                    (etaf--pvec-get (etaf-generation-semantic-nodes generation)
                                    component-id)))
         (component
          (and base
               (or (gethash (etaf--semantic-component-identity base)
                            (etaf-runtime-candidate-semantic-nodes runtime))
                   base)))
         (instance
          (or (plist-get env :instance)
              (and component
                   (gethash (etaf--semantic-component-resource-key component)
                            (etaf-runtime-resource-registry runtime)))))
         (identity
          (or (plist-get env :identity)
              (and component (etaf--semantic-component-identity component))))
         (props
          (or (plist-get env :props)
              (and component (etaf--semantic-component-props component))))
         (slots
          (or (plist-get env :slots)
              (and component (etaf--semantic-component-slots component)))))
    (if (null component-id)
        (let ((etaf--current-component-instance nil)
              (etaf--current-component-identity nil)
              (etaf--current-component-semantic-id nil)
              (etaf--current-component-props nil)
              (etaf--current-component-slots nil))
          (funcall function))
      (let ((etaf--current-runtime runtime)
            (etaf--current-component-instance instance)
            (etaf--current-component-identity identity)
            (etaf--current-component-semantic-id component-id)
            (etaf--current-component-props props)
            (etaf--current-component-slots slots)
            (etaf--current-context
             (or (and component
                      (etaf--semantic-component-context-frame component))
                 (etaf--component-instance-context instance))))
        (funcall function)))))

(defun etaf--runtime-component-env-signature (runtime component-id)
  "Return COMPONENT-ID's candidate or committed input signature in RUNTIME."
  (when component-id
    (or (when-let ((env (gethash component-id
                                 (etaf-runtime-candidate-component-envs runtime))))
          (list (copy-tree (plist-get env :props))
                (copy-tree (plist-get env :slots))))
        (when-let* ((generation (etaf-runtime-current-generation runtime))
                    (component
                     (etaf--pvec-get (etaf-generation-semantic-nodes generation)
                                     component-id)))
          (list (copy-tree (etaf--semantic-component-props component))
                (copy-tree (etaf--semantic-component-slots component)))))))

(defun etaf--context-frame-changed-keys (old new)
  "Return stable keys whose values differ between OLD and NEW frames."
  (let ((seen (make-hash-table :test #'eq)) result)
    (dolist (frame (list old new))
      (when frame
        (maphash (lambda (key _value) (puthash key t seen))
                 (etaf-context-values frame))))
    (maphash
     (lambda (key _)
       (unless (equal (and old (gethash key (etaf-context-values old)
                                        etaf--context-missing))
                      (and new (gethash key (etaf-context-values new)
                                        etaf--context-missing)))
         (push key result)))
     seen)
    (sort result (lambda (left right)
                   (string< (symbol-name left) (symbol-name right))))))

(defun etaf--runtime-enqueue-context-consumers (runtime provider-id old new)
  "Enqueue RUNTIME consumers affected by PROVIDER-ID changing OLD to NEW."
  (dolist (key (etaf--context-frame-changed-keys old new))
    (dolist (effect-id
             (etaf--generation-index-lookup
              (etaf-runtime-current-generation runtime) 'context-consumers
              (cons provider-id key)))
      (etaf--runtime-enqueue-effect runtime effect-id))))

(defun etaf--runtime-context-frame-for-candidate (runtime semantic)
  "Return SEMANTIC Context frame rebased onto RUNTIME candidate provider."
  (let* ((frame (etaf-context-copy
                 (etaf--semantic-component-context-frame semantic)))
         (parent (and frame (etaf-context-parent frame)))
         (provider-id (and parent (etaf-context-owner-id parent)))
         (provider (and provider-id
                        (gethash provider-id
                                 (etaf-runtime-candidate-graph-nodes runtime)))))
    (when (and frame (etaf--semantic-component-p provider))
      (setf (etaf-context-parent frame)
            (etaf--semantic-component-context-frame provider)))
    frame))

(defun etaf--runtime-event-kind (property)
  "Return event symbol represented by callback PROPERTY."
  (intern (substring (symbol-name property) 4)))

(defun etaf--runtime-register-host (runtime props path)
  "Register callback PROPS for the opaque Host reference in RUNTIME at PATH."
  (let ((host-ref (etaf--generated-host-ref props path))
        handlers)
    ;; A local Component rerender can remove and recreate the same stable
    ;; Host reference.  Re-registration cancels the candidate tombstone;
    ;; otherwise the generation contribution index would hide the new
    ;; handler/property entry behind the old removal.
    (setf (etaf-runtime-candidate-removed-host-refs runtime)
          (delete host-ref
                  (etaf-runtime-candidate-removed-host-refs runtime)))
    (puthash host-ref props (etaf-runtime-candidate-host-props runtime))
    (while props
      (let ((key (pop props))
            (value (pop props)))
        (when (and (keywordp key)
                   (string-prefix-p ":on-" (symbol-name key))
                   (functionp value))
          (push (cons (etaf--runtime-event-kind key) value) handlers))))
    (if handlers
        (puthash host-ref handlers (etaf-runtime-candidate-handlers runtime))
      ;; A retained Host can keep its identity while losing its callback
      ;; (for example a pagination button at the first/last page).  Preserve
      ;; a nil handler delta only when the committed generation had one; this
      ;; shadows the old contribution without manufacturing entries for every
      ;; non-interactive Host.
      (when (etaf--generation-index-lookup
             (etaf-runtime-current-generation runtime) 'handlers host-ref)
        (puthash host-ref nil (etaf-runtime-candidate-handlers runtime))))))

(defun etaf--runtime-candidate-add-child (runtime parent-id child-id)
  "Append CHILD-ID to PARENT-ID's candidate semantic order in RUNTIME."
  (puthash parent-id
           (append (gethash parent-id
                            (etaf-runtime-candidate-graph-children runtime))
                   (list child-id))
           (etaf-runtime-candidate-graph-children runtime)))

(defun etaf--runtime-semantic-id-for-identity (runtime identity)
  "Return stable semantic id for IDENTITY in RUNTIME's current candidate."
  (or (gethash identity (etaf-runtime-candidate-identity-entries runtime))
      (and etaf--current-range-item-index
           (gethash identity etaf--current-range-item-index))
      (and (etaf-runtime-current-generation runtime)
           (gethash identity
                    (etaf-generation-identity-index
                     (etaf-runtime-current-generation runtime))))
      (cl-incf (etaf-runtime-next-semantic-id runtime))))

(defun etaf--runtime-register-semantic-host (runtime name props backend-props path)
  "Register visual Host NAME at PATH in RUNTIME and return its semantic id."
  (let* ((key (plist-get props :key))
         (identity (if key
                       (list 'host etaf--current-semantic-parent-id :key key)
                     (list 'host etaf--current-semantic-parent-id
                           :position (copy-tree path))))
         (semantic-id (etaf--runtime-semantic-id-for-identity runtime identity))
         (record (etaf--semantic-host-create
                  :semantic-id semantic-id :identity identity
                  :parent-id etaf--current-semantic-parent-id
                  :host-ref (etaf--generated-host-ref props path)
                  :key key :name name
                  :props-signature (copy-tree backend-props)
                  :path (copy-tree path)
                  :style-identity (copy-tree etaf--render-style-stack))))
    (unless etaf--rendering-range-p
      (puthash identity semantic-id
               (etaf-runtime-candidate-identity-entries runtime)))
    (puthash semantic-id record (etaf-runtime-candidate-graph-nodes runtime))
    (etaf--runtime-candidate-add-child
     runtime etaf--current-semantic-parent-id semantic-id)
    semantic-id))

(defun etaf--runtime-finish-semantic-host
    (runtime semantic-id &optional content content-parts)
  "Seal SEMANTIC-ID Host child order from RUNTIME candidate graph."
  (when-let ((record (gethash semantic-id
                              (etaf-runtime-candidate-graph-nodes runtime))))
    (setf (etaf--semantic-host-child-ids record)
          (copy-sequence
          (gethash semantic-id
                    (etaf-runtime-candidate-graph-children runtime)))
          (etaf--semantic-host-content record) (copy-tree content))
    (setf (etaf--semantic-host-content-parts record)
          (copy-tree content-parts)))
  semantic-id)

(defun etaf--runtime-behavior-specs (value)
  "Normalize `:use' VALUE to a list of Behavior specs."
  (setq value (etaf--resolve-property-value value))
  (cond
   ((null value) nil)
   ((etaf-behavior-spec-p value) (list value))
   ((proper-list-p value)
    (unless (cl-every #'etaf-behavior-spec-p value)
      (signal 'etaf-behavior-error
              (list "Each :use entry must be a Behavior spec")))
    value)
   (t
    (signal 'etaf-behavior-error
            (list ":use must evaluate to a Behavior spec or list")))))

(defun etaf--runtime-target-value-equal-p (left right)
  "Compare LEFT and RIGHT with reactive/function identity rules."
  (cond
   ((or (etaf-ref-p left) (etaf-computed-p left)
        (etaf-ref-p right) (etaf-computed-p right))
    (eq left right))
   ((or (functionp left) (functionp right))
    (eq left right))
   ((and (consp left) (consp right))
    (and (etaf--runtime-target-value-equal-p (car left) (car right))
         (etaf--runtime-target-value-equal-p (cdr left) (cdr right))))
   ((or (consp left) (consp right)) nil)
   (t (equal left right))))

(defun etaf--runtime-behavior-spec-equal-p (left right)
  "Return whether Behavior specs LEFT and RIGHT may share installer state."
  (and (etaf-behavior-spec-p left)
       (etaf-behavior-spec-p right)
       (eq (etaf-behavior-spec-name left)
           (etaf-behavior-spec-name right))
       (eq (etaf-behavior-spec-install left)
           (etaf-behavior-spec-install right))
       (etaf--runtime-target-value-equal-p
        (etaf-behavior-spec-attributes left)
        (etaf-behavior-spec-attributes right))))

(defun etaf--compose-event-callbacks (primary secondary)
  "Compose two event callbacks in declaration order.
PRIMARY is the explicit Host callback and SECONDARY comes from a Behavior.
The composition belongs to the Runtime event layer, so UI Components do not
need to know how Behavior attributes are merged."
  (cond
   ((not (functionp primary)) secondary)
   ((not (functionp secondary)) primary)
   (t
    (lambda (&rest arguments)
      (prog1
          (apply primary arguments)
        (apply secondary arguments))))))

(defun etaf--runtime-install-behavior (runtime spec path props)
  "Install Behavior SPEC for RUNTIME at PATH and return its state."
  (let ((install (etaf-behavior-spec-install spec))
        cleanup)
    (when install
      (let ((etaf--current-behavior-context
             (etaf--behavior-context-create
              :runtime runtime :path path :host-props props)))
        (setq cleanup (funcall install))))
    (unless (or (null cleanup) (functionp cleanup))
      (signal 'etaf-behavior-error
              (list (format "Behavior %S installer must return cleanup"
                            (etaf-behavior-spec-name spec)))))
    (cons spec cleanup)))

(defun etaf--runtime-behavior-node (runtime node path)
  "Install or update NODE's `:use' Behaviors in RUNTIME and return it merged."
  (let* ((props (etaf--resolve-property-plist
                 (etaf--view-node-props node)))
         (specs (etaf--runtime-behavior-specs (plist-get props :use)))
         (merged (copy-sequence props)))
    (dolist (spec specs)
      (let* ((identity (list path (etaf-behavior-spec-name spec)))
             (old (gethash identity (etaf-runtime-behaviors runtime)))
             (same-p (and old
                          (etaf--runtime-behavior-spec-equal-p
                           (car old) spec)))
             (state (if same-p
                        old
                      (etaf--runtime-install-behavior runtime spec path props)))
             (resource-key
                (if same-p
                  (and (hash-table-p
                        (etaf-runtime-behavior-resource-keys runtime))
                       (gethash identity
                                (etaf-runtime-behavior-resource-keys runtime)))
                (cons (etaf-runtime-mount-epoch runtime)
                      (cl-incf (etaf-runtime-next-resource-id runtime))))))
        (puthash identity state (etaf-runtime-candidate-behaviors runtime))
        (puthash identity resource-key
                 (etaf-runtime-candidate-behavior-resource-keys runtime))
        (let ((attributes (etaf-behavior-spec-attributes (car state))))
          (while attributes
            (let ((key (pop attributes))
                  (value (pop attributes)))
              (if (and (keywordp key)
                       (string-prefix-p ":on-" (symbol-name key))
                       (plist-member merged key))
                  (setq merged
                        (plist-put
                         merged key
                         (etaf--compose-event-callbacks
                          (plist-get merged key) value)))
                (unless (plist-member merged key)
                  (setq merged (append merged (list key value))))))))))
    (etaf--view-node-create
     :name (etaf--view-node-name node)
     :props merged
     :children (etaf--view-node-children node))))

(defun etaf--runtime-promote-behaviors (runtime)
  "Publish candidate Behavior state for RUNTIME and dispose old state."
  (let ((old-resources (or (etaf-runtime-behavior-resource-keys runtime)
                           (make-hash-table :test #'equal)))
        (candidate-resources
         (or (etaf-runtime-candidate-behavior-resource-keys runtime)
             (make-hash-table :test #'equal))))
    (dolist (entry (sort (let (entries)
                           (maphash (lambda (key value)
                                      (push (cons key value) entries))
                                    (etaf-runtime-behaviors runtime))
                           entries)
                         (lambda (left right)
                           (string< (prin1-to-string (car left))
                                    (prin1-to-string (car right))))))
      (let* ((identity (car entry)) (old (cdr entry))
             (candidate (gethash identity
                                 (etaf-runtime-candidate-behaviors runtime)))
             (old-key (gethash identity old-resources))
             (candidate-key (gethash identity candidate-resources)))
        (unless (and candidate (eq candidate old))
          (when-let ((cleanup (cdr old)))
            (etaf--runtime-run-contained-cleanup
             runtime 'behavior-remove identity cleanup))
          (when old-key
            (remhash old-key (etaf-runtime-resource-registry runtime))))
        (when (and candidate candidate-key)
          (puthash candidate-key candidate
                   (etaf-runtime-resource-registry runtime)))))
    ;; Candidate resource membership becomes the only generation-visible
    ;; address set after publication; the state map remains a local disposal
    ;; index and is never consulted by generation dispatch.
    (setf (etaf-runtime-behaviors runtime)
          (etaf-runtime-candidate-behaviors runtime)
          (etaf-runtime-behavior-resource-keys runtime) candidate-resources
          (etaf-runtime-candidate-behaviors runtime) nil
          (etaf-runtime-candidate-behavior-resource-keys runtime) nil)))

(defun etaf--runtime-rollback-behaviors (runtime)
  "Dispose Behavior installers created by a failed RUNTIME candidate."
  (when-let ((candidate (etaf-runtime-candidate-behaviors runtime)))
    (dolist (entry (reverse
                    (sort (let (entries)
                            (maphash (lambda (key value)
                                       (push (cons key value) entries))
                                     candidate)
                            entries)
                          (lambda (left right)
                            (string< (prin1-to-string (car left))
                                     (prin1-to-string (car right)))))))
      (let* ((identity (car entry)) (state (cdr entry))
             (old-state (gethash identity (etaf-runtime-behaviors runtime)))
             (candidate-key
              (and (hash-table-p
                    (etaf-runtime-candidate-behavior-resource-keys runtime))
                   (gethash identity
                            (etaf-runtime-candidate-behavior-resource-keys
                             runtime))))
             (old-key
              (and (hash-table-p (etaf-runtime-behavior-resource-keys runtime))
                   (gethash identity
                            (etaf-runtime-behavior-resource-keys runtime))))
             (same-state (eq state old-state)))
       (unless same-state
         (when-let ((cleanup (cdr state)))
           (etaf--runtime-run-contained-cleanup
            runtime 'behavior-rollback identity cleanup))
         (when (and candidate-key (not (equal candidate-key old-key)))
           (remhash candidate-key (etaf-runtime-resource-registry runtime))))))))

(defun etaf--runtime-run-contained-cleanup (runtime phase identity function)
  "Run cleanup FUNCTION for IDENTITY and record PHASE failures in RUNTIME."
  (let ((inhibit-quit t) (quit-flag nil))
    (condition-case condition
        (funcall function)
      ((error quit)
       (push (list :phase phase :identity (copy-tree identity)
                   :condition condition)
             (etaf-runtime-diagnostics runtime)))))
  nil)

(defun etaf--runtime-call-key (call path)
  "Return retained identity for CALL at PATH, honoring an optional `:key'."
  (let* ((props (etaf--component-call-props call))
         (key (and (plist-member props :key)
                   (etaf--resolve-property-value (plist-get props :key)))))
    (when key
      (etaf--validate-key key))
    (if key
        (append (butlast path) (list :key key))
      path)))

(defun etaf--runtime-owned-slots (slots)
  "Attach current caller ownership to unowned normalized SLOTS."
  (mapcar
   (lambda (entry)
     (let ((name (car entry)) (value (cdr entry)))
       (cond
        ((etaf--slot-content-p value) entry)
        ((and (= (length value) 1)
              (etaf--slot-projection-p (car value)))
         (let* ((projection (car value))
                (forwarded (assq (etaf--slot-projection-name projection)
                                 etaf--current-component-slots)))
           (if (and forwarded (etaf--slot-content-p (cdr forwarded)))
               (cons name (cdr forwarded))
             (cons name
                   (etaf--slot-content-create
                    :owner-component-id etaf--current-component-semantic-id
                    :children value)))))
        (t
         (cons name
               (etaf--slot-content-create
                :owner-component-id etaf--current-component-semantic-id
                :children value))))))
   slots))

(defun etaf--runtime-new-instance (runtime spec identity)
  "Create and register IDENTITY's Component instance for RUNTIME from SPEC."
  (let* ((resource-id (cl-incf (etaf-runtime-next-resource-id runtime)))
         (resource-key (cons (etaf-runtime-mount-epoch runtime) resource-id))
         (instance
         (etaf--component-instance-create
          :spec spec
          :identity identity
         :scope (etaf-effect-scope :name identity)
          :context (etaf--context-create :parent etaf--current-context)
          :resource-key resource-key)))
    (push instance (etaf-runtime-candidate-created runtime))
    instance))

(defun etaf--runtime-instance-for-call (runtime call path)
  "Return retained Component instance for CALL at PATH in RUNTIME."
  (let* ((spec (etaf--component-call-spec call))
         (identity (list (etaf--component-spec-name spec)
                         (etaf--runtime-call-key call path)))
         (old-semantic
          (and (etaf-runtime-current-generation runtime)
               (etaf--generation-semantic
                (etaf-runtime-current-generation runtime) identity)))
         (old (and old-semantic
                   (gethash (etaf--semantic-component-resource-key old-semantic)
                            (etaf-runtime-resource-registry runtime))))
         (staged (gethash identity (etaf-runtime-candidate-live runtime)))
         (instance (cond
                    ((etaf--component-instance-p staged) staged)
                    ((and old (eq (etaf--component-instance-spec old) spec)) old)
                    (old
                     (push (list identity old)
                           (etaf-runtime-candidate-old-instances runtime))
                     (etaf--runtime-new-instance runtime spec identity))
                    (t
                     (etaf--runtime-new-instance runtime spec identity)))))
    (puthash identity instance (etaf-runtime-candidate-live runtime))
    instance))

(defun etaf--run-hooks (hooks)
  "Run HOOKS in registration order."
  (dolist (hook (reverse hooks))
    (funcall hook)))

(defun etaf--runtime-render-component-resource
    (runtime instance identity props slots path
             &optional old-output-range-id old-publication-kind old-context-frame)
  "Render RUNTIME candidate IDENTITY from resource INSTANCE without mutation."
  (let* ((spec (etaf--component-instance-spec instance))
         (setup (etaf--component-spec-setup spec)))
    (let ((candidate-context
           (if old-context-frame
               (etaf-context-copy old-context-frame)
             (etaf--component-instance-context instance))))
      (let ((etaf--current-runtime runtime)
          (etaf--current-component-instance instance)
          (etaf--current-component-identity identity)
          (etaf--current-component-props props)
          (etaf--current-component-slots slots)
          (etaf--raw-slot-read-p nil)
          (etaf--current-context candidate-context)
          (etaf--render-runtime runtime)
          (etaf--render-parent-style-stack etaf--render-style-stack)
          (etaf--render-style-stack
           (list
            (cons (etaf--component-spec-styles spec)
                  (append path (list :view))))))
      (when (and setup
                 (null (etaf--component-instance-render-function instance)))
        (let ((render-function
               (etaf-scope-run
                (etaf--component-instance-scope instance)
                (lambda ()
                  (let ((etaf--runtime-dependency-collector nil)
                        (etaf--tracking-enabled-p nil)
                        (etaf--active-effect nil))
                    (funcall setup props slots)))
                :watch-scheduler
                (lambda (job phase)
                  (etaf--runtime-watch-scheduler runtime job phase)))))
          (unless (functionp render-function)
            (signal 'etaf-runtime-error
                    (list (format
                           "Component %S :setup must return a render function"
                           (etaf--component-spec-name spec)))))
          (setf (etaf--component-instance-render-function instance)
                render-function)))
      (let* ((render-function
              (or (etaf--component-instance-render-function instance)
                  (etaf--component-spec-render spec)))
             (rendered (if setup
                           (funcall render-function)
                         (funcall render-function props slots)))
             (transparent-p
              (and (not (eq old-publication-kind 'material))
                   (etaf--runtime-transparent-output-p rendered)))
             (component-id etaf--current-semantic-parent-id)
             (range-id (and transparent-p
                            (or old-output-range-id
                                (cl-incf (etaf-runtime-next-semantic-id runtime)))))
             (old-range (and old-output-range-id
                             (etaf-runtime-current-generation runtime)
                             (etaf--pvec-get
                              (etaf-generation-semantic-nodes
                               (etaf-runtime-current-generation runtime))
                              old-output-range-id)))
             (nodes
              (let ((etaf--current-semantic-parent-id
                     (or range-id etaf--current-semantic-parent-id))
                    (etaf--current-range-item-index
                     (and old-range
                          (etaf--semantic-range-item-identity-index old-range)))
                    ;; Material Components nested below an existing semantic
                    ;; Range flatten their child Range sites into that outer
                    ;; owner; Ebox must never receive nested descriptors.
                    (etaf--rendering-range-p
                     (or transparent-p etaf--rendering-range-p)))
                (etaf--render-value-list rendered
                                         (append path (list :view))))))
        (let ((child-ids
               (copy-sequence
                (gethash range-id
                         (etaf-runtime-candidate-graph-children runtime)))))
          (when (= (length child-ids) (length nodes))
            (setq nodes
                  (cl-mapcan
                   (lambda (child-id node)
                     (let ((child
                            (gethash child-id
                                     (etaf-runtime-candidate-graph-nodes runtime))))
                       (cond
                        ((etaf--semantic-range-p child)
                         (copy-sequence
                          (gethash (etaf--semantic-range-effect-id child)
                                   (etaf-runtime-candidate-range-artifacts
                                    runtime))))
                        ((etaf--semantic-slot-range-p child)
                         (copy-sequence
                          (gethash (etaf--semantic-slot-range-effect-id child)
                                   (etaf-runtime-candidate-range-artifacts
                                    runtime))))
                        (t (list node)))))
                   child-ids nodes))))
        (when (cl-some (lambda (node)
                         (memq node etaf--rendered-range-container-nodes))
                       nodes)
          (setq transparent-p nil))
        ;; An unretained/raw slot projection still owns its structure through
        ;; the Component render target.  Keep that existing material boundary
        ;; until every projection is represented by a semantic slot Range.
        (when etaf--raw-slot-read-p
          (setq transparent-p nil))
        (when (and transparent-p
                   (cl-some
                    (lambda (child-id)
                      (let ((child
                             (gethash child-id
                                      (etaf-runtime-candidate-graph-nodes
                                       runtime))))
                        (or
                         (and (etaf--semantic-component-p child)
                              (eq
                               (etaf--semantic-component-publication-kind child)
                               'material))
                         (and (cl-every #'listp nodes)
                              (or (etaf--semantic-slot-range-p child)
                                  (and (etaf--semantic-range-p child)
                                       (not (eq
                                             (etaf--semantic-range-kind child)
                                             'component-output))))))))
                    (etaf--runtime-candidate-descendant-ids
                     runtime
                     (gethash range-id
                              (etaf-runtime-candidate-graph-children runtime))))
                   ;; A single explicit Host anchor is the reviewed escape
                   ;; for a retained page/slot Range: material Components may
                   ;; live below that Host without collapsing the Range back
                   ;; into its parent Component.  The Host remains the sole
                   ;; visual item and the normal backend identity proof still
                   ;; validates its subtree.
                   (not (and (= (length nodes) 1)
                             (etaf--semantic-host-p
                              (gethash
                               (car (gethash range-id
                                             (etaf-runtime-candidate-graph-children
                                              runtime)))
                                       (etaf-runtime-candidate-graph-nodes
                                        runtime))))))
          (unless (null (cdr nodes))
            (signal 'etaf-runtime-error
                    (list "Transparent sequence containing a material Component requires an explicit Host")))
          (setq transparent-p nil)
          (let ((children
                 (copy-sequence
                  (gethash range-id
                           (etaf-runtime-candidate-graph-children runtime)))))
            (puthash component-id children
                     (etaf-runtime-candidate-graph-children runtime))
            (remhash range-id (etaf-runtime-candidate-graph-children runtime))
            (dolist (child-id children)
              (when-let ((child
                          (gethash child-id
                                   (etaf-runtime-candidate-graph-nodes runtime))))
                (let ((copy (copy-sequence child)))
                  (cond ((etaf--semantic-component-p copy)
                         (setf (etaf--semantic-component-parent-id copy)
                               component-id))
                        ((etaf--semantic-host-p copy)
                         (setf (etaf--semantic-host-parent-id copy) component-id)))
                  (puthash child-id copy
                           (etaf-runtime-candidate-graph-nodes runtime)))))))
        (let ((node
               (unless transparent-p
               (cond
                ((null nodes) (ebox-spacer))
                ((null (cdr nodes)) (car nodes))
                (t (apply #'ebox-column nodes))))))
          (when node
            (let ((range-container-p
                   (memq node etaf--rendered-range-container-nodes)))
              (setq node (copy-sequence node))
              (when range-container-p
                (push node etaf--rendered-range-container-nodes))))
          (let ((host-ref (and node (or (plist-get node :host-ref)
                              (list 'etaf-component
                                    (copy-tree
                                     (etaf--component-instance-identity
                                      instance)))))))
            (when node (setq node (plist-put node :host-ref host-ref)))
            (list node host-ref rendered etaf--raw-slot-read-p
                  nodes (if transparent-p 'transparent 'material)
                  range-id candidate-context))))))))

(defun etaf--runtime-transparent-output-p (value)
  "Return whether VALUE has a transparent Component output boundary."
  (or (null value)
      (and (proper-list-p value) (not (etaf--view-node-p value)))
      (and (etaf--view-node-p value)
           (eq (etaf--view-node-name value) 'fragment))))

(defun etaf--runtime-stage-component-output-range
    (runtime old component-id _component-effect-id semantic-id rendered nodes path)
  "Stage transparent COMPONENT-ID output NODES in RUNTIME from OLD state."
  (let* ((range-ref (or (and old
                             (etaf--semantic-component-output-range-ref old))
                        (list 'etaf-component-output
                              (etaf-runtime-mount-epoch runtime) semantic-id)))
         (old-range (and old
                         (etaf--semantic-component-output-range-id old)
                         (etaf--pvec-get
                          (etaf-generation-semantic-nodes
                           (etaf-runtime-current-generation runtime))
                          (etaf--semantic-component-output-range-id old))))
         (effect-id (or (and old-range
                             (etaf--semantic-range-effect-id old-range))
                        (cl-incf (etaf-runtime-next-effect-id runtime))))
         (identity (list 'component-output-range component-id))
         (child-ids (copy-sequence
                     (gethash semantic-id
                              (etaf-runtime-candidate-graph-children runtime))))
         (all-item-ids
          (etaf--runtime-candidate-descendant-ids runtime child-ids))
         (item-index (make-hash-table :test #'equal))
         (record
          (etaf--semantic-range-create
           :semantic-id semantic-id :identity identity :effect-id effect-id
           :kind 'component-output :parent-id component-id
           :component-id component-id :token 'component-output
           :range-ref range-ref :path (copy-tree path)
           :caller-style-stack (copy-tree etaf--render-style-stack)
           :output-signature (copy-tree rendered) :deps nil
           :artifact-key (list (1+ (etaf-runtime-generation runtime))
                               'component-output effect-id)
           :item-host-ids child-ids :item-identity-index item-index)))
    (dolist (child-id child-ids)
      (when-let ((child (gethash child-id
                                 (etaf-runtime-candidate-graph-nodes runtime))))
        (let ((copy (copy-sequence child)))
          (cond ((etaf--semantic-host-p copy)
                 (setf (etaf--semantic-host-parent-id copy) semantic-id)
                 (puthash (etaf--semantic-host-identity copy) child-id item-index))
                ((etaf--semantic-component-p copy)
                 (setf (etaf--semantic-component-parent-id copy) semantic-id))
                ((etaf--semantic-range-p copy)
                 (setf (etaf--semantic-range-parent-id copy) semantic-id))
                ((etaf--semantic-slot-range-p copy)
                 (setf (etaf--semantic-slot-range-parent-id copy) semantic-id)))
          (puthash child-id copy
                   (etaf-runtime-candidate-graph-nodes runtime)))))
    (dolist (item-id all-item-ids)
      (when-let ((item (gethash item-id
                                (etaf-runtime-candidate-graph-nodes runtime))))
        (when (etaf--semantic-host-p item)
          (puthash (etaf--semantic-host-identity item) item-id item-index))))
    (when old-range
      (let ((new-set (make-hash-table :test #'eql)))
        (dolist (item-id all-item-ids) (puthash item-id t new-set))
        (dolist (old-id
                 (etaf--runtime-generation-descendant-ids
                  (etaf-runtime-current-generation runtime)
                  (etaf--semantic-range-item-host-ids old-range)))
          (unless (gethash old-id new-set)
            (push old-id
                  (etaf-runtime-candidate-removed-semantic-ids runtime))))))
    (puthash identity semantic-id
             (etaf-runtime-candidate-identity-entries runtime))
    (puthash semantic-id record
             (etaf-runtime-candidate-graph-nodes runtime))
    (puthash semantic-id child-ids
             (etaf-runtime-candidate-graph-children runtime))
    (puthash component-id (list semantic-id)
             (etaf-runtime-candidate-graph-children runtime))
    (puthash effect-id
             (etaf--generation-effect-create
              :effect-id effect-id :kind 'component-output
              :semantic-id semantic-id :deps nil)
             (etaf-runtime-candidate-effects runtime))
    (puthash effect-id nodes
             (etaf-runtime-candidate-range-artifacts runtime))
    (dolist (child-id child-ids)
      (when-let ((child (gethash child-id
                                 (etaf-runtime-candidate-graph-nodes runtime))))
        (let ((nested
               (cond
                ((etaf--semantic-component-p child)
                 (and (etaf--semantic-component-output-range-id child)
                      (gethash (etaf--semantic-component-output-range-id child)
                               (etaf-runtime-candidate-graph-nodes runtime))))
                ((or (etaf--semantic-range-p child)
                     (etaf--semantic-slot-range-p child))
                 child))))
          (when nested
            (let ((copy (copy-sequence nested)))
              (if (etaf--semantic-slot-range-p copy)
                  (setf (etaf--semantic-slot-range-range-ref copy) range-ref)
                (setf (etaf--semantic-range-range-ref copy) range-ref))
              (puthash (if (etaf--semantic-slot-range-p copy)
                           (etaf--semantic-slot-range-semantic-id copy)
                         (etaf--semantic-range-semantic-id copy))
                       copy (etaf-runtime-candidate-graph-nodes runtime)))))))
    (list record (apply #'ebox-child-range range-ref nodes))))

(defun etaf--runtime-render-component (runtime call path)
  "Render CALL through retained RUNTIME at PATH to one Ebox node."
  (let* ((parent etaf--current-component-identity)
         (parent-semantic
          (and parent (etaf-runtime-current-generation runtime)
               (etaf--generation-semantic
                (etaf-runtime-current-generation runtime) parent)))
         (parent-resource
          (and parent-semantic
               (gethash (etaf--semantic-component-resource-key parent-semantic)
                        (etaf-runtime-resource-registry runtime))))
         (instance
          (let ((etaf--active-scope
                 (and parent-resource
                      (etaf--component-instance-scope parent-resource))))
            (etaf--runtime-instance-for-call runtime call path)))
         (identity (etaf--component-instance-identity instance))
         (slots (etaf--runtime-owned-slots (etaf--component-call-slots call)))
         (old-generation (etaf-runtime-current-generation runtime))
         (old (and old-generation
                   (etaf--generation-semantic old-generation identity)))
         (input-effect-id
          (or (and old (etaf--semantic-component-input-effect-id old))
              (cl-incf (etaf-runtime-next-effect-id runtime))))
         (effect-id (or (and old (etaf--semantic-component-effect-id old))
                        (cl-incf (etaf-runtime-next-effect-id runtime))))
         (semantic-id (or (and old (etaf--semantic-component-semantic-id old))
                          (cl-incf (etaf-runtime-next-semantic-id runtime))))
         props input-deps render-deps context-deps slot-retargeted-p)
    (unless (etaf-context-owner-id (etaf--component-instance-context instance))
      (setf (etaf-context-owner-id (etaf--component-instance-context instance))
            semantic-id))
    (puthash identity semantic-id
             (etaf-runtime-candidate-identity-entries runtime))
    (etaf--runtime-candidate-add-child
     runtime etaf--current-semantic-parent-id semantic-id)
    (let ((etaf--runtime-dependency-collector
           (lambda (source) (cl-pushnew source input-deps :test #'eq)))
          (etaf--active-effect nil)
          (etaf--render-phase-p t))
      (setq props
            (etaf--resolve-property-plist (etaf--component-call-props call))))
    (puthash semantic-id
             (list :identity identity :instance instance :props props :slots slots)
             (etaf-runtime-candidate-component-envs runtime))
    (when (and old
               (or etaf--rendering-component-effect-p
                   (not (equal-including-properties
                         slots (etaf--semantic-component-slots old))))
               (not (etaf--semantic-component-raw-slot-reader-p old)))
      (setq slot-retargeted-p
            (etaf--runtime-retarget-component-slot-ranges runtime old slots)))
    (if (not (or (null old)
                 etaf--runtime-force-full-component-render-p
                 (gethash input-effect-id
                          (etaf-runtime-dirty-effect-ids runtime))
                 (gethash effect-id (etaf-runtime-dirty-effect-ids runtime))
                 (and slots etaf--rendering-component-effect-p
                      (not slot-retargeted-p))
                 (not (equal-including-properties
                       props (etaf--semantic-component-props old)))
                 (and (not slot-retargeted-p)
                      (not (equal-including-properties
                            slots (etaf--semantic-component-slots old))))))
        (progn
          (when (etaf-runtime-candidate-full-rebuild-p runtime)
            (etaf--runtime-carry-committed-subtree runtime old-generation old))
          (let ((artifact
                 (and (etaf--semantic-component-artifact-key old)
                      (gethash (etaf--semantic-component-artifact-key old)
                               (etaf-runtime-artifact-registry runtime)))))
            (unless artifact
              (setq artifact
                    (etaf--runtime-rebuild-component-artifact
                     runtime old))
              (puthash identity old
                       (etaf-runtime-candidate-semantic-nodes runtime))
              (puthash semantic-id old
                       (etaf-runtime-candidate-graph-nodes runtime))
              (puthash effect-id artifact
                       (etaf-runtime-candidate-artifacts runtime)))
            ;; Local overlays do not copy a whole unchanged descendant
            ;; subtree.  Preserve the artifact root's contribution entry so
            ;; a stable interactive child (for example a Button Component)
            ;; remains dispatchable without traversing unrelated descendants.
            (when-let ((host-ref (plist-get artifact :host-ref)))
              (when-let ((handlers
                          (etaf--generation-index-lookup
                           old-generation 'handlers host-ref)))
                (puthash host-ref (copy-tree handlers)
                         (etaf-runtime-candidate-handlers runtime)))
              (when-let ((host-props
                          (etaf--generation-index-lookup
                           old-generation 'host-props host-ref)))
                (puthash host-ref (copy-tree host-props)
                         (etaf-runtime-candidate-host-props runtime))))
            (plist-get artifact :node)))
      (let (result)
        (let ((etaf--runtime-dependency-collector
               (lambda (source) (cl-pushnew source render-deps :test #'eq)))
              (etaf--context-inject-recorder
               (lambda (frame key)
                 (cl-pushnew (cons (etaf-context-owner-id frame) key)
                             context-deps :test #'equal)))
              (etaf--current-component-semantic-id semantic-id)
              (etaf--current-semantic-parent-id semantic-id)
              (etaf--rendering-component-effect-p t)
              (etaf--active-effect nil)
              (etaf--render-phase-p t))
          (setq result
                 (etaf--runtime-render-component-resource
                 runtime instance identity props slots path
                 (and old (etaf--semantic-component-output-range-id old))
                 (and old (etaf--semantic-component-publication-kind old))
                 (and old (etaf--semantic-component-context-frame old)))))
        (let* ((transparent-p (eq (nth 5 result) 'transparent))
               (output-range
                (and transparent-p
                     (etaf--runtime-stage-component-output-range
                      runtime old semantic-id effect-id (nth 6 result)
                      (nth 2 result)
                      (nth 4 result) path)))
               (publication-node (if transparent-p (cadr output-range)
                                   (car result)))
               (semantic
               (etaf--semantic-component-create
                :semantic-id semantic-id
                :identity (copy-tree identity)
                :input-effect-id input-effect-id :effect-id effect-id
                :resource-key (copy-tree
                               (etaf--component-instance-resource-key instance))
                :props (copy-tree props) :slots (copy-tree slots)
                :input-props (copy-tree (etaf--component-call-props call))
                :input-slots (copy-tree slots)
                :output-signature (copy-tree (nth 2 result))
                :artifact-key effect-id
                :path (copy-tree path)
                :caller-style-stack (copy-tree etaf--render-style-stack)
                :input-deps (nreverse input-deps)
                :deps (nreverse render-deps)
                :parent-id etaf--current-semantic-parent-id
                :caller-component-id etaf--current-component-semantic-id
                :raw-slot-reader-p (nth 3 result)
                :publication-kind (if transparent-p 'transparent 'material)
                :output-range-id (and transparent-p
                                      (etaf--semantic-range-semantic-id
                                       (car output-range)))
                :output-range-ref (and transparent-p
                                       (etaf--semantic-range-range-ref
                                        (car output-range)))
                :context-frame
                (etaf-context-copy (nth 7 result))
                :context-deps (nreverse context-deps)
                :child-ids (copy-sequence
                            (gethash semantic-id
                                     (etaf-runtime-candidate-graph-children
                                      runtime))))))
          (puthash identity semantic
                   (etaf-runtime-candidate-semantic-nodes runtime))
          (puthash semantic-id semantic
                   (etaf-runtime-candidate-graph-nodes runtime))
          (puthash input-effect-id
                   (etaf--generation-effect-create
                    :effect-id input-effect-id :kind 'component-input
                    :semantic-id semantic-id
                    :deps (etaf--semantic-component-input-deps semantic))
                   (etaf-runtime-candidate-effects runtime))
          (puthash effect-id
                   (etaf--generation-effect-create
                    :effect-id effect-id :kind 'component-render
                    :semantic-id semantic-id
                    :deps (etaf--semantic-component-deps semantic))
                   (etaf-runtime-candidate-effects runtime))
          (puthash effect-id (list :node publication-node
                                   :host-ref (copy-tree (cadr result))
                                   :nodes (copy-sequence (nth 4 result))
                                   :range-id (and transparent-p
                                                  (etaf--semantic-range-semantic-id
                                                   (car output-range))))
                   (etaf-runtime-candidate-artifacts runtime))
          (push identity (etaf-runtime-candidate-rendered-identities runtime))
          (if (and transparent-p
                   (or etaf--rendering-range-p
                       (= etaf--current-semantic-parent-id
                          (etaf-runtime-root-range-id runtime))))
              (cons 'component-output-range (copy-sequence (nth 4 result)))
            publication-node))))))

(defun etaf--runtime-lower-semantic-artifact (runtime generation semantic-id)
  "Purely lower SEMANTIC-ID from GENERATION and RUNTIME Range artifacts."
  (let ((semantic (etaf--pvec-get
                   (etaf-generation-semantic-nodes generation) semantic-id)))
    (cond
     ((or (etaf--semantic-range-p semantic)
          (etaf--semantic-slot-range-p semantic))
      (apply #'ebox-child-range
             (etaf--semantic-backend-range-ref semantic)
             (copy-sequence
              (gethash (etaf--semantic-backend-range-artifact-key semantic)
                       (etaf-runtime-range-artifact-registry runtime)))))
     ((etaf--semantic-component-p semantic)
      (let ((nodes (mapcar
                    (lambda (child-id)
                      (etaf--runtime-lower-semantic-artifact
                       runtime generation child-id))
                    (etaf--semantic-component-child-ids semantic))))
        (cond ((null nodes) (ebox-spacer))
              ((null (cdr nodes)) (car nodes))
              (t (apply #'ebox-column nodes)))))
     ((etaf--semantic-inline-range-p semantic)
      (etaf--semantic-inline-range-output semantic))
     ((etaf--semantic-host-p semantic)
      (let* ((name (etaf--semantic-host-name semantic))
             (props (copy-tree (etaf--semantic-host-props-signature semantic)))
             (child-ids (etaf--semantic-host-child-ids semantic))
             (parent-semantic
              (and (etaf--semantic-host-parent-id semantic)
                   (etaf--pvec-get
                    (etaf-generation-semantic-nodes generation)
                    (etaf--semantic-host-parent-id semantic))))
             ;; A semantic Range may contain one material Host anchor whose
             ;; descendants include another Range.  Flatten that nested
             ;; semantic Range at the Renderer boundary so Ebox receives only
             ;; declarative children; the outer Range remains the publication
             ;; identity and ancestor invalidation still follows the graph.
             (flatten-range-children-p
              (or (etaf--semantic-range-p parent-semantic)
                  (etaf--semantic-slot-range-p parent-semantic)))
             (content
              (if (eq name 'text)
                  (if (etaf--semantic-host-content-parts semantic)
                      (apply #'concat
                             (mapcar
                              (lambda (part)
                                (if (integerp part)
                                    (etaf--semantic-inline-range-output
                                     (etaf--pvec-get
                                      (etaf-generation-semantic-nodes generation)
                                      part))
                                  part))
                              (etaf--semantic-host-content-parts semantic)))
                    (etaf--semantic-host-content semantic))
                (etaf--semantic-host-content semantic)))
             (children
              (unless (eq name 'text)
                (cl-mapcan
                 (lambda (child-id)
                   (let ((child (etaf--pvec-get
                                 (etaf-generation-semantic-nodes generation)
                                 child-id)))
                     (if (and flatten-range-children-p
                              (or (etaf--semantic-range-p child)
                                  (etaf--semantic-slot-range-p child)))
                         (copy-sequence
                          (gethash
                           (etaf--semantic-backend-range-artifact-key child)
                           (etaf-runtime-range-artifact-registry runtime)))
                       (list
                        (etaf--runtime-lower-semantic-artifact
                         runtime generation child-id)))))
                 child-ids)))
             (range-child-p
              (and (not flatten-range-children-p)
                   (cl-some
                    (lambda (child-id)
                      (let ((child (etaf--pvec-get
                                    (etaf-generation-semantic-nodes generation)
                                    child-id)))
                        (or (etaf--semantic-range-p child)
                            (etaf--semantic-slot-range-p child))))
                    child-ids))))
        (etaf--lower-resolved-semantic-host
         name props content
         children range-child-p)))
     (t (signal 'etaf-runtime-error
                (list "Missing semantic artifact node" semantic-id))))))

(defun etaf--runtime-rebuild-component-artifact (runtime semantic)
  "Rebuild RUNTIME SEMANTIC Ebox artifact without application code."
  (let* ((generation (etaf-runtime-current-generation runtime))
         (node (etaf--runtime-lower-semantic-artifact
                runtime generation
                (etaf--semantic-component-semantic-id semantic)))
         (host-ref (or (plist-get node :host-ref)
                       (list 'etaf-component
                             (copy-tree
                              (etaf--semantic-component-identity semantic))))))
    (setq node (copy-sequence node))
    (plist-put node :host-ref host-ref)
    (list :node node :host-ref host-ref)))

(defun etaf--runtime-carry-committed-subtree (runtime generation semantic)
  "Carry RUNTIME SEMANTIC and its GENERATION children during Root traversal."
  (let* ((semantic-id
          (cond ((etaf--semantic-component-p semantic)
                 (etaf--semantic-component-semantic-id semantic))
                ((etaf--semantic-host-p semantic)
                 (etaf--semantic-host-semantic-id semantic))
                ((etaf--semantic-range-p semantic)
                 (etaf--semantic-range-semantic-id semantic))
                ((etaf--semantic-slot-range-p semantic)
                 (etaf--semantic-slot-range-semantic-id semantic))
                (t (etaf--semantic-inline-range-semantic-id semantic))))
         (identity
          (cond ((etaf--semantic-component-p semantic)
                 (etaf--semantic-component-identity semantic))
                ((etaf--semantic-host-p semantic)
                 (etaf--semantic-host-identity semantic))
                ((etaf--semantic-range-p semantic)
                 (etaf--semantic-range-identity semantic))
                ((etaf--semantic-slot-range-p semantic)
                 (etaf--semantic-slot-range-identity semantic))
                (t (etaf--semantic-inline-range-identity semantic))))
         (children
          (cond ((etaf--semantic-component-p semantic)
                 (etaf--semantic-component-child-ids semantic))
                ((etaf--semantic-host-p semantic)
                 (etaf--semantic-host-child-ids semantic))
                ((etaf--semantic-range-p semantic)
                 (etaf--semantic-range-item-host-ids semantic))
                ((etaf--semantic-slot-range-p semantic)
                 (etaf--semantic-slot-range-item-host-ids semantic))
                (t nil))))
    (unless (and (etaf--semantic-host-p semantic)
                 (etaf--semantic-range-p
                  (etaf--pvec-get
                   (etaf-generation-semantic-nodes generation)
                   (etaf--semantic-host-parent-id semantic))))
      (puthash identity semantic-id
               (etaf-runtime-candidate-identity-entries runtime)))
    (puthash semantic-id semantic (etaf-runtime-candidate-graph-nodes runtime))
    (when (and (etaf--semantic-host-p semantic)
               (etaf--semantic-host-host-ref semantic))
      (let ((host-ref (etaf--semantic-host-host-ref semantic)))
        (when-let ((handlers
                    (etaf--generation-index-lookup
                     generation 'handlers host-ref)))
          (puthash host-ref (copy-tree handlers)
                   (etaf-runtime-candidate-handlers runtime)))
        (when-let ((props
                    (etaf--generation-index-lookup
                     generation 'host-props host-ref)))
          (puthash host-ref (copy-tree props)
                   (etaf-runtime-candidate-host-props runtime)))))
    (when (etaf--semantic-component-p semantic)
      (puthash identity semantic (etaf-runtime-candidate-semantic-nodes runtime))
      (puthash identity
               (gethash (etaf--semantic-component-resource-key semantic)
                        (etaf-runtime-resource-registry runtime))
               (etaf-runtime-candidate-live runtime))
      (dolist (entry
               (list
                (etaf--generation-effect-create
                 :effect-id (etaf--semantic-component-input-effect-id semantic)
                 :kind 'component-input :semantic-id semantic-id
                 :deps (etaf--semantic-component-input-deps semantic))
                (etaf--generation-effect-create
                 :effect-id (etaf--semantic-component-effect-id semantic)
                 :kind 'component-render :semantic-id semantic-id
                 :deps (etaf--semantic-component-deps semantic))))
        (puthash (etaf--generation-effect-effect-id entry) entry
                 (etaf-runtime-candidate-effects runtime))))
    (when (etaf--semantic-range-p semantic)
      (let ((effect
             (or (etaf--pvec-get
                  (etaf-generation-effect-map generation)
                  (etaf--semantic-range-effect-id semantic))
                 (etaf--generation-effect-create
                  :effect-id (etaf--semantic-range-effect-id semantic)
                  :kind 'range :semantic-id semantic-id
                  :deps (etaf--semantic-range-deps semantic)))))
        (puthash (etaf--generation-effect-effect-id effect) effect
                 (etaf-runtime-candidate-effects runtime))))
    (when (etaf--semantic-inline-range-p semantic)
      (let ((effect
             (etaf--pvec-get
              (etaf-generation-effect-map generation)
              (etaf--semantic-inline-range-effect-id semantic))))
        (puthash (etaf--generation-effect-effect-id effect) effect
                 (etaf-runtime-candidate-effects runtime))))
    (when (etaf--semantic-slot-range-p semantic)
      (let ((effect
             (etaf--pvec-get
              (etaf-generation-effect-map generation)
              (etaf--semantic-slot-range-effect-id semantic))))
        (puthash (etaf--generation-effect-effect-id effect) effect
                 (etaf-runtime-candidate-effects runtime))))
    (puthash semantic-id (copy-sequence children)
             (etaf-runtime-candidate-graph-children runtime))
    (dolist (child-id children)
      (when-let ((child (etaf--pvec-get
                         (etaf-generation-semantic-nodes generation) child-id)))
        (etaf--runtime-carry-committed-subtree runtime generation child)))))

(defun etaf--runtime-render-child-range (runtime expr path &optional kind)
  "Lower RUNTIME direct material-child EXPR at PATH as retained Range KIND."
  (let* ((token (etaf--expr-token expr))
         (identity (list 'range etaf--current-semantic-parent-id
                         (or token (copy-tree path))))
         (old-generation (etaf-runtime-current-generation runtime))
         (old-id (and old-generation
                      (gethash identity
                               (etaf-generation-identity-index old-generation))))
         (old (and old-id
                   (etaf--pvec-get (etaf-generation-semantic-nodes old-generation)
                                   old-id)))
         (candidate (and old-id
                         (gethash old-id
                                  (etaf-runtime-candidate-graph-nodes runtime))))
         (semantic-id (or old-id (cl-incf (etaf-runtime-next-semantic-id runtime))))
         (effect-id (or (and old (etaf--semantic-range-effect-id old))
                        (cl-incf (etaf-runtime-next-effect-id runtime))))
         (range-ref (or (and old (etaf--semantic-range-range-ref old))
                        (list 'etaf-range (etaf-runtime-mount-epoch runtime)
                              semantic-id))))
    (if candidate
        (progn
          (puthash identity semantic-id
                   (etaf-runtime-candidate-identity-entries runtime))
          (etaf--runtime-candidate-add-child
           runtime etaf--current-semantic-parent-id semantic-id)
          (cons 'range
                (list
                 (apply #'ebox-child-range range-ref
                        (copy-sequence
                         (gethash effect-id
                                  (etaf-runtime-candidate-range-artifacts
                                   runtime)))))))
      (if (and old
             (not (gethash effect-id (etaf-runtime-dirty-effect-ids runtime))))
        (progn
          (puthash identity semantic-id
                   (etaf-runtime-candidate-identity-entries runtime))
          (etaf--runtime-candidate-add-child
           runtime etaf--current-semantic-parent-id semantic-id)
          (when (etaf-runtime-candidate-full-rebuild-p runtime)
            (etaf--runtime-carry-committed-subtree runtime old-generation old))
          (cons 'range
                (list
                 (apply #'ebox-child-range range-ref
                        (copy-sequence
                         (gethash (etaf--semantic-range-artifact-key old)
                                  (etaf-runtime-range-artifact-registry
                                   runtime)))))))
      (let (deps context-deps value nodes)
        (let ((collector
               (lambda (source) (cl-pushnew source deps :test #'eq))))
          (let ((etaf--runtime-dependency-collector collector)
                (etaf--context-inject-recorder
                 (lambda (frame key)
                   (cl-pushnew (cons (etaf-context-owner-id frame) key)
                               context-deps :test #'equal)))
                (etaf--active-effect nil)
                (etaf--render-phase-p t))
            (setq value
                  (etaf--runtime-normalize-range-value
                   (funcall (etaf--expr-thunk expr)))))
          (puthash identity semantic-id
                   (etaf-runtime-candidate-identity-entries runtime))
          (etaf--runtime-candidate-add-child
           runtime etaf--current-semantic-parent-id semantic-id)
          (let ((etaf--runtime-dependency-collector collector)
                (etaf--context-inject-recorder
                 (lambda (frame key)
                   (cl-pushnew (cons (etaf-context-owner-id frame) key)
                               context-deps :test #'equal)))
                (etaf--current-semantic-parent-id semantic-id)
                (etaf--current-range-item-index
                 (and old (etaf--semantic-range-item-identity-index old)))
                (etaf--rendering-range-p t)
                (etaf--active-effect nil)
                (etaf--render-phase-p t))
            (setq nodes (etaf--render-value-list value path))))
        (let* ((item-host-ids
                (copy-sequence
                 (gethash semantic-id
                          (etaf-runtime-candidate-graph-children runtime))))
               (all-item-ids
                (etaf--runtime-candidate-descendant-ids runtime item-host-ids))
               (item-index (make-hash-table :test #'equal))
               (record
               (etaf--semantic-range-create
                :semantic-id semantic-id :identity identity :effect-id effect-id
                :kind (or kind 'range)
                :parent-id etaf--current-semantic-parent-id
                :component-id etaf--current-component-semantic-id
                :token token :range-ref range-ref :path (copy-tree path)
                :caller-style-stack (copy-tree etaf--render-style-stack)
                :output-signature (copy-tree value) :deps (nreverse deps)
                :context-deps (nreverse context-deps)
                :artifact-key (cons (1+ (etaf-runtime-generation runtime))
                                    effect-id)
                :item-host-ids item-host-ids
                :item-identity-index item-index)))
          (unless (= (length nodes) (length item-host-ids))
            (signal 'etaf-runtime-error
                    (list "Direct child Range items must be Host Views"
                          (length nodes) (length item-host-ids))))
          (dolist (item-id all-item-ids)
            (let ((item (gethash item-id
                                 (etaf-runtime-candidate-graph-nodes runtime))))
              (unless (etaf--semantic-host-p item)
                (signal 'etaf-runtime-error
                        (list "Direct child Range items must be Host Views")))
              (puthash (etaf--semantic-host-identity item) item-id item-index)))
          (when old
            (let ((new-set (make-hash-table :test #'eql)))
              (dolist (item-id all-item-ids) (puthash item-id t new-set))
              (dolist (old-id
                       (etaf--runtime-generation-descendant-ids
                        old-generation
                        (etaf--semantic-range-item-host-ids old)))
              (unless (gethash old-id new-set)
                (push old-id
                      (etaf-runtime-candidate-removed-semantic-ids runtime))))))
          (puthash semantic-id record
                   (etaf-runtime-candidate-graph-nodes runtime))
          (puthash effect-id
                   (etaf--generation-effect-create
                    :effect-id effect-id :kind (or kind 'range)
                    :semantic-id semantic-id
                    :deps (etaf--semantic-range-deps record) :target expr)
                   (etaf-runtime-candidate-effects runtime))
          (puthash effect-id nodes
                   (etaf-runtime-candidate-range-artifacts runtime))
          (cons 'range
                (list (apply #'ebox-child-range range-ref nodes)))))))))

(defun etaf--runtime-render-fragment-range (runtime fragment path)
  "Lower material-child FRAGMENT at PATH in RUNTIME as one retained Range."
  (let* ((expr (etaf--expr-create
                :token (etaf--view-node-token fragment)
                :thunk (lambda () (etaf--view-node-children fragment)))))
    (etaf--runtime-render-child-range runtime expr path 'fragment)))

(defun etaf--runtime-evaluate-raw-range (raw)
  "Return RAW's resolved public Ebox node and collected dependencies."
  (let (deps node)
    (let ((etaf--runtime-dependency-collector
           (lambda (source) (cl-pushnew source deps :test #'eq)))
          (etaf--active-effect nil)
          (etaf--render-phase-p t))
      (setq node (funcall (etaf--raw-ebox-thunk raw)))
      (unless (listp node)
        (signal 'etaf-runtime-error
                (list "raw-ebox :value must return one public Ebox node")))
      (setq node (copy-tree node))
      (when-let ((key-thunk (etaf--raw-ebox-key-thunk raw)))
        (let ((key (funcall key-thunk)))
          (etaf--validate-key key)
          (setq node (plist-put node :key key)))))
    (cl-values node (nreverse deps))))

(defun etaf--runtime-render-raw-range (runtime raw path)
  "Lower material-child RAW at PATH in RUNTIME as an opaque retained Range."
  (let* ((token (etaf--raw-ebox-token raw))
         (identity (list 'raw-range etaf--current-semantic-parent-id
                         (or token (copy-tree path))))
         (generation (etaf-runtime-current-generation runtime))
         (old-id (and generation
                      (gethash identity
                               (etaf-generation-identity-index generation))))
         (old (and old-id
                   (etaf--pvec-get (etaf-generation-semantic-nodes generation)
                                   old-id)))
         (semantic-id (or old-id (cl-incf (etaf-runtime-next-semantic-id runtime))))
         (effect-id (or (and old (etaf--semantic-range-effect-id old))
                        (cl-incf (etaf-runtime-next-effect-id runtime))))
         (range-ref (or (and old (etaf--semantic-range-range-ref old))
                        (list 'etaf-raw-range
                              (etaf-runtime-mount-epoch runtime) semantic-id))))
    (puthash identity semantic-id
             (etaf-runtime-candidate-identity-entries runtime))
    (etaf--runtime-candidate-add-child
     runtime etaf--current-semantic-parent-id semantic-id)
    (if (and old
             (not (gethash effect-id (etaf-runtime-dirty-effect-ids runtime))))
        (progn
          (when (etaf-runtime-candidate-full-rebuild-p runtime)
            (etaf--runtime-carry-committed-subtree runtime generation old))
          (cons 'range
                (list (apply #'ebox-child-range range-ref
                             (copy-sequence
                              (gethash (etaf--semantic-range-artifact-key old)
                                       (etaf-runtime-range-artifact-registry
                                        runtime)))))))
      (cl-multiple-value-bind (node deps)
          (etaf--runtime-evaluate-raw-range raw)
        (let ((record
               (etaf--semantic-range-create
                :semantic-id semantic-id :identity identity :effect-id effect-id
                :kind 'raw :parent-id etaf--current-semantic-parent-id
                :component-id etaf--current-component-semantic-id
                :token token :range-ref range-ref :path (copy-tree path)
                :caller-style-stack nil :output-signature (copy-tree node)
                :deps deps
                :artifact-key (cons (1+ (etaf-runtime-generation runtime))
                                    effect-id)
                :item-host-ids nil
                :item-identity-index (make-hash-table :test #'equal))))
          (puthash semantic-id record
                   (etaf-runtime-candidate-graph-nodes runtime))
          (puthash effect-id
                   (etaf--generation-effect-create
                    :effect-id effect-id :kind 'raw :semantic-id semantic-id
                    :deps deps :target raw)
                   (etaf-runtime-candidate-effects runtime))
          (puthash effect-id (list node)
                   (etaf-runtime-candidate-range-artifacts runtime))
          (cons 'range (list (ebox-child-range range-ref node))))))))

(defun etaf--runtime-render-slot-range (runtime projection path)
  "Lower material-child PROJECTION at PATH in RUNTIME as a retained slot Range."
  (let* ((name (etaf--slot-projection-name projection))
         (entry (assq name etaf--current-component-slots))
         (content (and entry (cdr entry)))
         (provided-p (and entry t))
         (children (if (etaf--slot-content-p content)
                       (etaf--slot-content-children content)
                     (or content (etaf--slot-projection-fallback projection))))
         (owner-id (if provided-p
                       (and (etaf--slot-content-p content)
                            (etaf--slot-content-owner-component-id content))
                     etaf--current-component-semantic-id))
         (consumer-id etaf--current-component-semantic-id)
         (style-stack (copy-tree (if provided-p
                                     etaf--render-parent-style-stack
                                   etaf--render-style-stack)))
         (token (etaf--slot-projection-token projection))
         (identity (list 'slot-range etaf--current-semantic-parent-id
                         (or token (copy-tree path)) name))
         (generation (etaf-runtime-current-generation runtime))
         (old-id (and generation
                      (gethash identity (etaf-generation-identity-index generation))))
         (old (and old-id
                   (etaf--pvec-get (etaf-generation-semantic-nodes generation)
                                   old-id)))
         (old-effect
          (and old
               (etaf--pvec-get (etaf-generation-effect-map generation)
                               (etaf--semantic-slot-range-effect-id old))))
         (candidate (and old-id
                         (gethash old-id
                                  (etaf-runtime-candidate-graph-nodes runtime))))
         (semantic-id (or old-id (cl-incf (etaf-runtime-next-semantic-id runtime))))
         (effect-id (or (and old (etaf--semantic-slot-range-effect-id old))
                        (cl-incf (etaf-runtime-next-effect-id runtime))))
         (range-ref (or (and old (etaf--semantic-slot-range-range-ref old))
                        (list 'etaf-slot-range (etaf-runtime-mount-epoch runtime)
                              semantic-id)))
         (target (list :children children :owner-id owner-id
                       :owner-input
                       (etaf--runtime-component-env-signature runtime owner-id)
                       :consumer-id consumer-id :style-stack style-stack)))
    (puthash identity semantic-id
             (etaf-runtime-candidate-identity-entries runtime))
    (etaf--runtime-candidate-add-child
     runtime etaf--current-semantic-parent-id semantic-id)
    (cond
     (candidate
      (cons 'range
            (list (apply #'ebox-child-range range-ref
                         (copy-sequence
                          (gethash effect-id
                                   (etaf-runtime-candidate-range-artifacts runtime)))))))
     ((and old
           (equal-including-properties
            target (etaf--generation-effect-target old-effect))
           (not (gethash effect-id (etaf-runtime-dirty-effect-ids runtime))))
      (when (etaf-runtime-candidate-full-rebuild-p runtime)
        (etaf--runtime-carry-committed-subtree runtime generation old))
      (cons 'range
            (list (apply #'ebox-child-range range-ref
                         (copy-sequence
                          (gethash (etaf--semantic-slot-range-artifact-key old)
                                   (etaf-runtime-range-artifact-registry runtime)))))))
     (t
     (cl-multiple-value-bind (value deps nodes context-deps)
          (etaf--runtime-evaluate-slot-target
           runtime target semantic-id
           (and old (etaf--semantic-slot-range-item-identity-index old)) path)
        (let ((result
               (etaf--runtime-finish-slot-range-candidate
                runtime generation old identity semantic-id effect-id range-ref
                name token owner-id consumer-id style-stack path target
                value deps nodes context-deps)))
          (when old
            (let ((candidate-range
                   (gethash semantic-id
                            (etaf-runtime-candidate-graph-nodes runtime))))
              (unless (equal-including-properties
                       (etaf--semantic-slot-range-output-signature old)
                       (etaf--semantic-slot-range-output-signature
                        candidate-range))
                (push (list old candidate-range
                            (copy-sequence
                             (gethash
                              (etaf--semantic-slot-range-artifact-key old)
                              (etaf-runtime-range-artifact-registry runtime)))
                            nodes)
                      (etaf-runtime-candidate-eager-range-changes runtime))
                (etaf--runtime-invalidate-semantic-ancestors
                 runtime (etaf--semantic-slot-range-parent-id old))
                (etaf--runtime-record-slot-owner-update runtime old))))
          result))))))

(defun etaf--runtime-finish-slot-range-candidate
    (runtime generation old identity semantic-id effect-id range-ref
             name token owner-id consumer-id style-stack path target
             value deps nodes context-deps)
  "Finish GENERATION slot Range candidate in RUNTIME.
The candidate uses resolved VALUE, DEPS, and NODES."
  (let* ((item-host-ids
          (copy-sequence
           (gethash semantic-id
                    (etaf-runtime-candidate-graph-children runtime))))
         (all-item-ids
          (etaf--runtime-candidate-descendant-ids runtime item-host-ids))
         (item-index (make-hash-table :test #'equal))
         (record
          (etaf--semantic-slot-range-create
           :semantic-id semantic-id :identity identity :effect-id effect-id
           :parent-id etaf--current-semantic-parent-id
           :owner-component-id owner-id :consumer-component-id consumer-id
           :token token :name name :range-ref range-ref :path (copy-tree path)
           :style-stack (copy-tree style-stack)
           :output-signature (copy-tree value) :deps deps
           :context-deps context-deps
           :artifact-key (cons (1+ (etaf-runtime-generation runtime)) effect-id)
           :item-host-ids item-host-ids :item-identity-index item-index)))
    (dolist (item-id all-item-ids)
      (let ((item (gethash item-id
                           (etaf-runtime-candidate-graph-nodes runtime))))
        (unless (etaf--semantic-host-p item)
          (signal 'etaf-runtime-error
                  (list "Slot Range items require Step4b Host/string output")))
        (puthash (etaf--semantic-host-identity item) item-id item-index)))
    (when old
      (let ((new-set (make-hash-table :test #'eql)))
        (dolist (item-id all-item-ids) (puthash item-id t new-set))
        (dolist (old-item-id
                 (etaf--runtime-generation-descendant-ids
                  generation (etaf--semantic-slot-range-item-host-ids old)))
          (unless (gethash old-item-id new-set)
            (push old-item-id
                  (etaf-runtime-candidate-removed-semantic-ids runtime))))))
    (puthash semantic-id record (etaf-runtime-candidate-graph-nodes runtime))
    (puthash effect-id
             (etaf--generation-effect-create
              :effect-id effect-id :kind 'slot :semantic-id semantic-id
              :deps deps :target target)
             (etaf-runtime-candidate-effects runtime))
    (puthash effect-id nodes (etaf-runtime-candidate-range-artifacts runtime))
    (cons 'range (list (apply #'ebox-child-range range-ref nodes)))))

(defun etaf--runtime-evaluate-slot-target
    (runtime target semantic-id old-item-index path)
  "Evaluate slot TARGET for RUNTIME SEMANTIC-ID and return its candidate data."
  (let (deps context-deps value nodes)
    (let ((collector (lambda (source) (cl-pushnew source deps :test #'eq)))
          (owner-id (plist-get target :owner-id)))
      (etaf--runtime-call-with-component-env
       runtime owner-id
       (lambda ()
         (let ((etaf--runtime-dependency-collector collector)
               (etaf--context-inject-recorder
                (lambda (frame key)
                  (cl-pushnew (cons (etaf-context-owner-id frame) key)
                              context-deps :test #'equal)))
               (etaf--active-effect nil)
               (etaf--render-phase-p t))
           (setq value
                 (etaf--runtime-normalize-range-value
                  (plist-get target :children)))
           (let ((etaf--render-style-stack
                  (copy-tree (plist-get target :style-stack))))
             (setq value (etaf--runtime-style-range-value value path))))
         (let ((etaf--runtime-dependency-collector collector)
               (etaf--context-inject-recorder
                (lambda (frame key)
                  (cl-pushnew (cons (etaf-context-owner-id frame) key)
                              context-deps :test #'equal)))
               (etaf--render-runtime runtime)
               (etaf--current-semantic-parent-id semantic-id)
               (etaf--current-range-item-index old-item-index)
               (etaf--rendering-range-p t)
               (etaf--render-style-stack
                (copy-tree (plist-get target :style-stack)))
               (etaf--active-effect nil)
               (etaf--render-phase-p t))
           (setq nodes (etaf--render-value-list value path))))))
    (cl-values value (nreverse deps) nodes (nreverse context-deps))))

(defun etaf--runtime-style-range-value (value path)
  "Apply active Component style scopes to normalized Range VALUE at PATH."
  (cl-loop for item in value for index from 0 collect
           (if (etaf--view-node-p item)
               (let ((styled
                      (etaf--runtime-style-node
                       item (append path (list index)))))
                 (setf (etaf--view-node-children styled)
                       (etaf--runtime-style-range-value
                        (etaf--view-node-children styled)
                        (append path (list index))))
                 styled)
             item)))

(defun etaf--runtime-normalize-range-value (value)
  "Return Host/string RANGE VALUE with nested expr sites eagerly resolved."
  (cond
   ((null value) nil)
   ((stringp value) (list value))
   ((etaf--expr-p value)
    (etaf--runtime-normalize-range-value (funcall (etaf--expr-thunk value))))
   ((etaf--view-node-p value)
    (if (eq (etaf--view-node-name value) 'fragment)
        (cl-mapcan #'etaf--runtime-normalize-range-value
                   (etaf--view-node-children value))
      (let ((copy (copy-sequence value)))
        (setf (etaf--view-node-children copy)
              (cl-mapcan #'etaf--runtime-normalize-range-value
                         (etaf--view-node-children value)))
        (list copy))))
   ((proper-list-p value)
    (cl-mapcan #'etaf--runtime-normalize-range-value value))
   (t
    (signal 'etaf-runtime-error
            (list "Direct material expr requires Step4b output")))))

(defun etaf--runtime-candidate-descendant-ids (runtime roots)
  "Return ROOTS and all candidate semantic descendants in RUNTIME."
  (let ((queue (copy-sequence roots)) result)
    (while queue
      (let ((semantic-id (pop queue)))
        (push semantic-id result)
        (setq queue
              (nconc queue
                     (copy-sequence
                      (gethash semantic-id
                               (etaf-runtime-candidate-graph-children runtime)))))))
    (nreverse result)))

(defun etaf--runtime-generation-descendant-ids (generation roots)
  "Return ROOTS and all committed semantic descendants in GENERATION."
  (let ((queue (copy-sequence roots)) result)
    (while queue
      (let ((semantic-id (pop queue)))
        (push semantic-id result)
        (setq queue
              (nconc queue
                     (copy-sequence
                      (etaf--pvec-get
                       (etaf-generation-children-table generation)
                       semantic-id))))))
    (nreverse result)))

(defun etaf--runtime-inline-value-string (value surface)
  "Resolve inline VALUE to one string under inherited SURFACE properties."
  (cond
   ((null value) "")
   ((stringp value)
    (etaf--apply-inline-surface-properties value surface))
   ((etaf--expr-p value)
    (etaf--runtime-inline-value-string
     (funcall (etaf--expr-thunk value)) surface))
   ((etaf--view-node-p value)
    (unless (eq (etaf--view-node-name value) 'text)
      (signal 'etaf-runtime-error
              (list "Inline expr requires Step4b non-text output")))
    (let* ((props (etaf--resolve-property-plist
                   (etaf--view-node-props value)))
           (inner (etaf--inline-text-surface-properties props))
           (content
            (mapconcat
             (lambda (child)
               (etaf--runtime-inline-value-string child inner))
             (etaf--view-node-children value) "")))
      (etaf--apply-inline-surface-properties content surface)))
   ((proper-list-p value)
    (mapconcat (lambda (item)
                 (etaf--runtime-inline-value-string item surface))
               value ""))
   (t (signal 'etaf-runtime-error
              (list "Inline expr requires Step4b output")))))

(defun etaf--runtime-render-inline-range
    (runtime host-id expr path surface)
  "Create or reuse one inline EXPR Range owned by HOST-ID in RUNTIME."
  (let* ((token (etaf--expr-token expr))
         (identity (list 'inline-range host-id (or token (copy-tree path))))
         (generation (etaf-runtime-current-generation runtime))
         (old-id (and generation
                      (gethash identity (etaf-generation-identity-index generation))))
         (old (and old-id
                   (etaf--pvec-get (etaf-generation-semantic-nodes generation)
                                   old-id)))
         (candidate (and old-id
                         (gethash old-id
                                  (etaf-runtime-candidate-graph-nodes runtime))))
         (semantic-id (or old-id (cl-incf (etaf-runtime-next-semantic-id runtime))))
         (effect-id (or (and old (etaf--semantic-inline-range-effect-id old))
                        (cl-incf (etaf-runtime-next-effect-id runtime)))))
    (puthash identity semantic-id
             (etaf-runtime-candidate-identity-entries runtime))
    (etaf--runtime-candidate-add-child runtime host-id semantic-id)
    (if candidate
        (cons semantic-id (etaf--semantic-inline-range-output candidate))
      (if (and old (not etaf--rendering-component-effect-p)
             (not (gethash effect-id (etaf-runtime-dirty-effect-ids runtime))))
        (progn
          (when (etaf-runtime-candidate-full-rebuild-p runtime)
            (etaf--runtime-carry-committed-subtree runtime generation old))
          (cons semantic-id (etaf--semantic-inline-range-output old)))
      (let (deps context-deps output)
        (let ((etaf--runtime-dependency-collector
               (lambda (source) (cl-pushnew source deps :test #'eq)))
              (etaf--context-inject-recorder
               (lambda (frame key)
                 (cl-pushnew (cons (etaf-context-owner-id frame) key)
                             context-deps :test #'equal)))
              (etaf--active-effect nil)
              (etaf--render-phase-p t))
          (setq output
                (etaf--runtime-inline-value-string
                 (funcall (etaf--expr-thunk expr)) surface)))
        (let ((record
               (etaf--semantic-inline-range-create
                :semantic-id semantic-id :identity identity :effect-id effect-id
                :parent-id host-id :component-id etaf--current-component-semantic-id
                :token token :path (copy-tree path)
                :surface-properties (copy-tree surface)
                :output (copy-sequence output) :deps (nreverse deps)
                :context-deps (nreverse context-deps))))
          (puthash semantic-id record
                   (etaf-runtime-candidate-graph-nodes runtime))
          (puthash effect-id
                   (etaf--generation-effect-create
                    :effect-id effect-id :kind 'inline
                    :semantic-id semantic-id :deps (etaf--semantic-inline-range-deps record)
                    :target expr)
                   (etaf-runtime-candidate-effects runtime))
          (when (and old
                     (not (equal-including-properties
                           (etaf--semantic-inline-range-output old) output)))
            (cl-pushnew host-id
                        (etaf-runtime-candidate-inline-host-ids runtime)
                        :test #'eql)
            (etaf--runtime-invalidate-semantic-ancestors runtime host-id)
            (when-let ((component
                        (etaf--pvec-get
                         (etaf-generation-semantic-nodes generation)
                         (etaf--semantic-inline-range-component-id old))))
              (cl-pushnew (etaf--semantic-component-identity component)
                          (etaf-runtime-candidate-updated-component-identities
                           runtime)
                          :test #'equal)))
          (cons semantic-id output)))))))

(defun etaf--runtime-render-inline-content
    (runtime host-id values path &optional surface)
  "Return resolved inline content and semantic parts for HOST-ID in RUNTIME."
  (let (parts strings)
    (cl-labels
        ((walk
          (value current-path inherited)
          (cond
           ((null value) nil)
           ((stringp value)
            (let ((text (etaf--apply-inline-surface-properties value inherited)))
              (push text parts) (push text strings)))
           ((etaf--expr-p value)
            (let ((entry (etaf--runtime-render-inline-range
                          runtime host-id value current-path inherited)))
              (push (car entry) parts) (push (cdr entry) strings)))
           ((etaf--view-node-p value)
            (unless (eq (etaf--view-node-name value) 'text)
              (signal 'etaf-runtime-error
                      (list "Inline text requires Step4b Host output")))
            (let* ((props (etaf--resolve-property-plist
                           (etaf--view-node-props value)))
                   (inner (append (etaf--inline-text-surface-properties props)
                                  inherited))
                   (index 0))
              (dolist (child (etaf--view-node-children value))
                (walk child (append current-path (list index)) inner)
                (cl-incf index))))
           ((proper-list-p value)
            (let ((index 0))
              (dolist (item value)
                (walk item (append current-path (list index)) inherited)
                (cl-incf index))))
           (t (signal 'etaf-runtime-error
                      (list "Inline text requires Step4b output"))))))
      (walk values path surface))
    (list (apply #'concat (nreverse strings)) (nreverse parts))))

(defun etaf--runtime-style-node (node path)
  "Apply active Component style scopes to NODE at structural PATH."
  (let ((result node))
    (dolist (scope etaf--render-style-stack result)
      (let ((styles (car scope))
            (root-path (cdr scope)))
        (when (and styles (equal path root-path))
          (setq result (etaf--apply-inline-style-rules result styles t)))
        (when (and styles (not (equal path root-path)))
          (setq result (etaf--apply-inline-style-rules result styles nil)))))))

(defun etaf--runtime-dispose-instance (instance &optional run-hooks-p)
  "Dispose INSTANCE, optionally running hooks when RUN-HOOKS-P is non-nil."
  (when (etaf--component-instance-p instance)
    (when (and run-hooks-p (etaf--component-instance-mounted-p instance))
      (let ((etaf--render-phase-p nil))
        (etaf--run-hooks (etaf--component-instance-unmounted-hooks instance))))
    (setf (etaf--component-instance-mounted-p instance) nil)
    (etaf-scope-stop (etaf--component-instance-scope instance))))

(defun etaf--runtime-dispose-created-candidate (runtime)
  "Dispose RUNTIME's instances created by an uncommitted candidate."
  (dolist (instance (etaf-runtime-candidate-created runtime))
    (remhash (etaf--component-instance-identity instance)
             (etaf-runtime-instances runtime))
    (remhash (etaf--component-instance-resource-key instance)
             (etaf-runtime-resource-registry runtime))
    (etaf--runtime-dispose-instance instance nil))
  (dolist (entry (etaf-runtime-candidate-old-instances runtime))
    (puthash (car entry) (cadr entry) (etaf-runtime-instances runtime)))
  runtime)

(defun etaf--runtime-clear-candidate (runtime)
  "Clear transient candidate bookkeeping in RUNTIME."
  (setf (etaf-runtime-candidate-created runtime) nil
        (etaf-runtime-candidate-old-instances runtime) nil
        (etaf-runtime-candidate-live runtime) nil
        (etaf-runtime-candidate-semantic-nodes runtime) nil
        (etaf-runtime-candidate-component-envs runtime) nil
        (etaf-runtime-candidate-graph-nodes runtime) nil
        (etaf-runtime-candidate-identity-entries runtime) nil
        (etaf-runtime-candidate-graph-children runtime) nil
        (etaf-runtime-candidate-removed-semantic-ids runtime) nil
        (etaf-runtime-candidate-removed-effect-ids runtime) nil
        (etaf-runtime-candidate-removed-host-refs runtime) nil
        (etaf-runtime-candidate-rendered-identities runtime) nil
        (etaf-runtime-candidate-updated-component-identities runtime) nil
        (etaf-runtime-candidate-artifacts runtime)
        (make-hash-table :test #'equal)
        (etaf-runtime-candidate-range-artifacts runtime)
        (make-hash-table :test #'eql)
        (etaf-runtime-candidate-invalidated-artifact-keys runtime) nil
        (etaf-runtime-candidate-inline-host-ids runtime) nil
        (etaf-runtime-candidate-eager-range-changes runtime) nil
        (etaf-runtime-candidate-effects runtime)
        (make-hash-table :test #'eql)
        (etaf-runtime-candidate-source-deltas runtime) nil
        (etaf-runtime-candidate-handlers runtime) nil
        (etaf-runtime-candidate-host-props runtime) nil
        (etaf-runtime-candidate-behaviors runtime) nil
        (etaf-runtime-candidate-behavior-resource-keys runtime) nil))

(defun etaf--runtime-promote (runtime)
  "Promote RUNTIME's successful candidate and return its lifecycle groups."
  (let (removed added existing)
    (maphash
     (lambda (identity instance)
       (if (gethash identity (etaf-runtime-candidate-live runtime))
           (if (etaf--component-instance-mounted-p instance)
               (push instance existing)
             (push instance added))
         (push instance removed)))
     (etaf-runtime-instances runtime))
    ;; Removed descendants are disposed before their parents.
    (dolist (instance (sort removed
                             (lambda (left right)
                               (> (length (etaf--component-instance-identity left))
                                  (length (etaf--component-instance-identity right))))))
      (remhash (etaf--component-instance-identity instance)
               (etaf-runtime-instances runtime))
      (remhash (etaf--component-instance-resource-key instance)
               (etaf-runtime-resource-registry runtime))
      (etaf--runtime-dispose-instance instance t))
    (dolist (entry (etaf-runtime-candidate-old-instances runtime))
      (etaf--runtime-dispose-instance (cadr entry) t))
    (dolist (instance added)
      (setf (etaf--component-instance-mounted-p instance) t))
    (list
     (sort added
           (lambda (left right)
             (< (length (etaf--component-instance-identity left))
                (length (etaf--component-instance-identity right)))))
     existing)))

(defun etaf--runtime-run-lifecycle (groups)
  "Run mounted and updated lifecycle hooks in GROUPS after publication."
  (dolist (instance (car groups))
    (let ((etaf--render-phase-p nil))
      (etaf--run-hooks (etaf--component-instance-mounted-hooks instance))))
  (dolist (instance (cadr groups))
    (let ((etaf--render-phase-p nil))
      (etaf--run-hooks (etaf--component-instance-updated-hooks instance)))))

(defun etaf--runtime-begin-candidate (runtime)
  "Reset candidate bookkeeping before a RUNTIME render."
  (setq etaf--rendered-range-container-nodes nil)
  (setf (etaf-runtime-candidate-live runtime) (make-hash-table :test #'equal)
        (etaf-runtime-candidate-semantic-nodes runtime)
        (make-hash-table :test #'equal)
        (etaf-runtime-candidate-component-envs runtime)
        (make-hash-table :test #'eql)
        (etaf-runtime-candidate-graph-nodes runtime)
        (make-hash-table :test #'eql)
        (etaf-runtime-candidate-identity-entries runtime)
        (make-hash-table :test #'equal)
        (etaf-runtime-candidate-graph-children runtime)
        (make-hash-table :test #'eql)
        (etaf-runtime-candidate-removed-semantic-ids runtime) nil
        (etaf-runtime-candidate-removed-effect-ids runtime) nil
        (etaf-runtime-candidate-removed-host-refs runtime) nil
        (etaf-runtime-candidate-rendered-identities runtime) nil
        (etaf-runtime-candidate-updated-component-identities runtime) nil
        (etaf-runtime-candidate-effects runtime) (make-hash-table :test #'eql)
        (etaf-runtime-candidate-generation-metrics runtime)
        (etaf--generation-metrics-create)
        (etaf-runtime-candidate-full-rebuild-p runtime) nil
        (etaf-runtime-candidate-invalidated-artifact-keys runtime) nil
        (etaf-runtime-candidate-inline-host-ids runtime) nil
        (etaf-runtime-candidate-eager-range-changes runtime) nil
        (etaf-runtime-candidate-root-deps runtime)
        (and (etaf-runtime-current-generation runtime)
             (copy-sequence
              (etaf--pvec-get
               (etaf-generation-effect-sources
                (etaf-runtime-current-generation runtime))
               (etaf-runtime-root-effect-id runtime))))
        (etaf-runtime-candidate-created runtime) nil
        (etaf-runtime-candidate-old-instances runtime) nil
        (etaf-runtime-candidate-handlers runtime)
        (make-hash-table :test #'equal)
        (etaf-runtime-candidate-host-props runtime)
        (make-hash-table :test #'equal)
        (etaf-runtime-candidate-behaviors runtime)
        (make-hash-table :test #'equal)
        (etaf-runtime-candidate-behavior-resource-keys runtime)
        (make-hash-table :test #'equal)))

(defun etaf--runtime-evaluate-root (runtime)
  "Evaluate RUNTIME's root View without lowering Components."
  (let ((root-view (etaf-runtime-root-view runtime)))
    (if (functionp root-view) (funcall root-view) root-view)))

(defun etaf--runtime-render-root (runtime)
  "Lower RUNTIME's cached root View."
  (let ((etaf--current-semantic-parent-id
         (etaf-runtime-root-range-id runtime)))
    (etaf--render-value-list
     (etaf-runtime-root-view-cache runtime) '(root))))

(defun etaf--runtime-stage-root-range (runtime deps)
  "Stage RUNTIME's nonvisual semantic Root Range with DEPS."
  (let* ((semantic-id (etaf-runtime-root-range-id runtime))
         (identity (list 'root-range (etaf-runtime-mount-epoch runtime)))
         (children (copy-sequence
                    (gethash semantic-id
                             (etaf-runtime-candidate-graph-children runtime))))
         (record
          (etaf--semantic-range-create
           :semantic-id semantic-id :identity identity
           :effect-id (etaf-runtime-root-effect-id runtime) :kind 'root
           :parent-id 0 :component-id nil :token 'root :range-ref nil
           :path '(root) :caller-style-stack nil
           :output-signature (copy-tree (etaf-runtime-root-view-cache runtime))
           :deps (copy-sequence deps) :artifact-key nil
           :item-host-ids children
           :item-identity-index (make-hash-table :test #'equal))))
    (puthash identity semantic-id
             (etaf-runtime-candidate-identity-entries runtime))
    (puthash semantic-id record
             (etaf-runtime-candidate-graph-nodes runtime))
    (puthash 0 (list semantic-id)
             (etaf-runtime-candidate-graph-children runtime))))

(defun etaf--runtime-build-generation (runtime &optional base)
  "Build RUNTIME generation, point-copying candidate owners from BASE."
  (let* ((full-p (or (null base) (etaf-runtime-root-dirty-p runtime)))
         (generation-id (1+ (etaf-runtime-generation runtime)))
         (metrics (or (etaf-runtime-candidate-generation-metrics runtime)
                      (etaf--generation-metrics-create)))
         (nodes (and (not full-p) (etaf-generation-semantic-nodes base)))
         (effect-map (and (not full-p) (etaf-generation-effect-map base)))
         (source-effects (and (not full-p) (etaf-generation-source-effects base)))
         (effect-sources (and (not full-p) (etaf-generation-effect-sources base)))
         (resources (and (not full-p) (etaf-generation-resource-membership base)))
         (parent-index (and (not full-p) (etaf-generation-parent-table base)))
         (children-index (and (not full-p) (etaf-generation-children-table base)))
         (identity-index (if (not full-p)
                             (etaf-generation-identity-index base)
                           (make-hash-table :test #'equal)))
         (identity-copy nil)
         (affected-sources (make-hash-table :test #'eq))
         deltas
         node-updates parent-updates children-updates resource-updates)
    (cl-labels
        ((install-effect
          (effect old-deps new-deps)
          (let ((effect-id (etaf--generation-effect-effect-id effect)))
            (setq effect-map
                  (etaf--pvec-put effect-map effect-id effect metrics)
                  effect-sources
                  (etaf--pvec-put effect-sources effect-id
                                  (copy-sequence new-deps) metrics))
            (dolist (source (cl-delete-duplicates
                             (append (copy-sequence old-deps)
                                     (copy-sequence new-deps))
                             :test #'eq))
              (puthash source t affected-sources)
              (let* ((source-id (etaf-reactive-source-id source))
                     (current-effects
                      (copy-sequence
                       (etaf--pvec-get source-effects source-id
                                       metrics 'source)))
                     (new-effects (delq effect-id current-effects)))
                (when (memq source new-deps)
                  (setq new-effects
                        (sort (cons effect-id new-effects) #'<)))
                (unless (equal current-effects new-effects)
                  (setq source-effects
                        (etaf--pvec-put source-effects source-id
                                        new-effects metrics)))))))
         (remove-effect
          (effect-id)
          (when-let ((old-effect
                      (and effect-map
                           (etaf--pvec-get effect-map effect-id metrics
                                           'effect))))
            (let ((deps (etaf--generation-effect-deps old-effect)))
              (setq effect-map
                    (etaf--pvec-put effect-map effect-id nil metrics)
                    effect-sources
                    (etaf--pvec-put effect-sources effect-id nil metrics))
              (dolist (source deps)
                (puthash source t affected-sources)
                (let* ((source-id (etaf-reactive-source-id source))
                       (current-effects
                        (copy-sequence
                         (etaf--pvec-get source-effects source-id metrics
                                         'source)))
                       (new-effects (delq effect-id current-effects)))
                  (unless (equal current-effects new-effects)
                    (setq source-effects
                          (etaf--pvec-put source-effects source-id
                                          new-effects metrics))))))))
         (semantic-effect-ids
          (semantic)
          (cond
           ((etaf--semantic-component-p semantic)
            (delq nil
                  (list (etaf--semantic-component-input-effect-id semantic)
                        (etaf--semantic-component-effect-id semantic))))
           ((etaf--semantic-range-p semantic)
            (list (etaf--semantic-range-effect-id semantic)))
           ((etaf--semantic-slot-range-p semantic)
            (list (etaf--semantic-slot-range-effect-id semantic)))
           ((etaf--semantic-inline-range-p semantic)
            (list (etaf--semantic-inline-range-effect-id semantic)))
           (t nil))))
      (when full-p
        (maphash (lambda (source _) (puthash source t affected-sources))
                 (etaf-runtime-route-sources runtime)))
      (maphash
       (lambda (identity candidate)
         (let* ((semantic (copy-sequence candidate))
                (semantic-id (etaf--semantic-component-semantic-id semantic))
                (effect-id (etaf--semantic-component-effect-id semantic))
                (resource-id
                 (cdr (etaf--semantic-component-resource-key semantic))))
           (when (gethash effect-id (etaf-runtime-candidate-artifacts runtime))
             (setf (etaf--semantic-component-artifact-key semantic)
                   (cons generation-id effect-id)))
           (push (cons semantic-id semantic) node-updates)
           (push (cons semantic-id
                       (etaf--semantic-component-parent-id semantic))
                 parent-updates)
           (push (cons semantic-id
                       (copy-sequence
                        (etaf--semantic-component-child-ids semantic)))
                 children-updates)
           (unless (gethash identity identity-index)
             (unless identity-copy
               (setq identity-index (copy-hash-table identity-index)
                     identity-copy t))
             (puthash (copy-tree identity) semantic-id identity-index))
           (unless (and (not full-p)
                        (etaf--pvec-get resources resource-id))
             (push (cons resource-id
                         (etaf--semantic-component-resource-key semantic))
                   resource-updates))))
       (etaf-runtime-candidate-semantic-nodes runtime))
      (maphash
       (lambda (semantic-id semantic)
         (unless (etaf--semantic-component-p semantic)
           (push (cons semantic-id semantic) node-updates)
           (let ((parent-id
                  (cond ((etaf--semantic-host-p semantic)
                         (etaf--semantic-host-parent-id semantic))
                        ((etaf--semantic-range-p semantic)
                         (etaf--semantic-range-parent-id semantic))
                        ((etaf--semantic-slot-range-p semantic)
                         (etaf--semantic-slot-range-parent-id semantic))
                        (t (etaf--semantic-inline-range-parent-id semantic))))
                 (child-ids
                  (cond ((etaf--semantic-host-p semantic)
                         (etaf--semantic-host-child-ids semantic))
                        ((etaf--semantic-range-p semantic)
                         (etaf--semantic-range-item-host-ids semantic))
                        ((etaf--semantic-slot-range-p semantic)
                         (etaf--semantic-slot-range-item-host-ids semantic))
                        (t nil))))
             (push (cons semantic-id parent-id) parent-updates)
             (push (cons semantic-id (copy-sequence child-ids))
                   children-updates))))
       (etaf-runtime-candidate-graph-nodes runtime))
      (maphash
       (lambda (identity _state)
         (let ((resource-key
                (and (hash-table-p
                     (etaf-runtime-candidate-behavior-resource-keys runtime))
                     (gethash identity
                              (etaf-runtime-candidate-behavior-resource-keys
                               runtime)))))
           (when resource-key
             (push (cons (cdr resource-key) resource-key)
                       resource-updates))))
       (etaf-runtime-candidate-behaviors runtime))
      (dolist (effect-id (etaf-runtime-candidate-removed-effect-ids runtime))
        (remove-effect effect-id))
      (dolist (semantic-id (etaf-runtime-candidate-removed-semantic-ids runtime))
        (when-let ((old-node (and base
                                  (etaf--pvec-get
                                   (etaf-generation-semantic-nodes base)
                                   semantic-id))))
          ;; A stable identity may be reintroduced in this candidate.  In that
          ;; case its new effect is installed below; only remove effects for a
          ;; semantic node that is absent from the candidate graph.
          (unless (gethash semantic-id
                           (etaf-runtime-candidate-graph-nodes runtime))
            (dolist (effect-id (semantic-effect-ids old-node))
              (remove-effect effect-id)))
          (when (and (etaf--semantic-host-p old-node)
                     (etaf--semantic-host-host-ref old-node))
            (let ((host-ref (etaf--semantic-host-host-ref old-node)))
              ;; A dirty Component may remove and recreate the same stable
              ;; Host address in one candidate.  The new contribution wins;
              ;; do not leave a removal tombstone that shadows it.
              (unless (or (gethash host-ref
                                   (etaf-runtime-candidate-host-props runtime))
                          (gethash host-ref
                                   (etaf-runtime-candidate-handlers runtime)))
                (cl-pushnew host-ref
                            (etaf-runtime-candidate-removed-host-refs runtime)
                            :test #'equal)))))
        (push (cons semantic-id nil) node-updates)
        (push (cons semantic-id nil) parent-updates)
        (push (cons semantic-id nil) children-updates))
      (maphash
       (lambda (identity semantic-id)
         (unless (gethash identity identity-index)
           (unless identity-copy
             (setq identity-index (copy-hash-table identity-index)
                   identity-copy t))
           (puthash (copy-tree identity) semantic-id identity-index)))
       (etaf-runtime-candidate-identity-entries runtime))
      (maphash
       (lambda (effect-id effect)
         (let ((old (and base
                         (etaf--pvec-get
                          (etaf-generation-effect-map base)
                          effect-id metrics 'effect))))
           (install-effect effect
                           (and old (etaf--generation-effect-deps old))
                           (etaf--generation-effect-deps effect))))
       (etaf-runtime-candidate-effects runtime))
      (when full-p
        (let* ((effect-id (etaf-runtime-root-effect-id runtime))
               (old-deps (and base
                              (etaf--pvec-get
                               (etaf-generation-effect-sources base) effect-id)))
               (new-deps (etaf-runtime-candidate-root-deps runtime))
               (root (etaf--semantic-root-create
                      :semantic-id 0 :effect-id effect-id
                      :input-signature
                      (copy-tree (etaf-runtime-root-view-cache runtime))
                      :deps (copy-sequence new-deps))))
          (push (cons 0 root) node-updates)
          (push (cons 0
                      (copy-sequence
                       (gethash 0
                                (etaf-runtime-candidate-graph-children runtime))))
                children-updates)
          (install-effect
           (etaf--generation-effect-create
            :effect-id effect-id :kind 'root
            :semantic-id (etaf-runtime-root-range-id runtime) :deps new-deps)
           old-deps new-deps)))
      ;; Apply all semantic/index membership edits in one trie batch.  The
      ;; candidate remains immutable; only the number of copied persistent
      ;; vector spines changes.
      (setq nodes
            (etaf--pvec-put-many nodes node-updates metrics)
            parent-index
            (etaf--pvec-put-many parent-index parent-updates metrics)
            children-index
            (etaf--pvec-put-many children-index children-updates metrics)
            resources
            (etaf--pvec-put-many resources resource-updates metrics))
      (maphash
       (lambda (source _)
         (let ((old-effects
                (and base
                     (etaf--pvec-get (etaf-generation-source-effects base)
                                     (etaf-reactive-source-id source))))
               (new-effects
                (etaf--pvec-get source-effects
                                (etaf-reactive-source-id source))))
           (unless (equal old-effects new-effects)
             (push (list source old-effects new-effects) deltas))))
       affected-sources)
      (setf (etaf-runtime-candidate-source-deltas runtime) (nreverse deltas)
            (etaf-runtime-candidate-generation-metrics runtime) metrics)
      (let ((generation
             (etaf--generation-create
       :generation-id generation-id
       :root-semantic-id 0
       :semantic-nodes nodes
       :effect-map effect-map
       :source-effects source-effects
       :effect-sources effect-sources
       :parent-table parent-index
       :children-table children-index
       :resource-membership resources
       :identity-index identity-index
              :indexes (etaf--runtime-build-contribution-indexes
                        runtime base full-p))))
        (etaf--generation-validate-context-acyclic generation)))))

(defun etaf--runtime-prearm-generation (runtime generation)
  "Prearm RUNTIME GENERATION sources and return the new-source journal."
  (ignore generation)
  (let ((route (etaf-runtime-route-token runtime)) journal completed)
    (unwind-protect
        (progn
          (dolist (delta (etaf-runtime-candidate-source-deltas runtime))
            (let ((source (car delta)) (new-effects (nth 2 delta)))
              (when (and new-effects
                         (not (gethash route
                                       (etaf--source-subscribers source))))
                (push source journal)
                (puthash route t (etaf--source-subscribers source))
                (puthash source t (etaf-runtime-route-sources runtime)))))
          (setq completed t)
          journal)
      (unless completed
        (etaf--runtime-rollback-prearm runtime journal)))))

(defun etaf--runtime-rollback-prearm (runtime journal)
  "Remove RUNTIME route from every newly prearmed source in JOURNAL."
  (dolist (source journal)
    (remhash (etaf-runtime-route-token runtime)
             (etaf--source-subscribers source))
    (remhash source (etaf-runtime-route-sources runtime))))

(defun etaf--runtime-complete-generation (runtime old generation)
  "Complete RUNTIME from OLD through GENERATION and prune obsolete routes."
  (when-let ((focus-ref (etaf-runtime-focus-ref runtime)))
    (let ((props (etaf--generation-index-lookup
                  generation 'host-props focus-ref)))
      (unless (and (numberp (plist-get props :tab-index))
                   (>= (plist-get props :tab-index) 0)
                   (not (plist-get props :disabled)))
        (setf (etaf-runtime-focus-ref runtime) nil))))
  (maphash
   (lambda (_identity semantic)
     (when-let ((instance
                 (gethash (etaf--semantic-component-resource-key semantic)
                          (etaf-runtime-resource-registry runtime))))
       (setf (etaf--component-instance-context instance)
             (etaf--semantic-component-context-frame semantic))))
   (etaf-runtime-candidate-semantic-nodes runtime))
  (dolist (instance (etaf-runtime-candidate-created runtime))
    (puthash (etaf--component-instance-identity instance) instance
             (etaf-runtime-instances runtime)))
  (maphash
   (lambda (effect-id _artifact)
     (when-let* ((old-semantic (and old
                                    (etaf--generation-effect-semantic
                                     old effect-id)))
                 (new-semantic
                  (etaf--generation-effect-semantic generation effect-id))
                 (old-key (etaf--semantic-component-artifact-key old-semantic)))
       (unless (equal old-key
                      (etaf--semantic-component-artifact-key new-semantic))
         (let ((inhibit-quit t) (quit-flag nil))
           (condition-case nil
               (remhash old-key (etaf-runtime-artifact-registry runtime))
             ((error quit) nil))))))
   (etaf-runtime-candidate-artifacts runtime))
  (maphash
   (lambda (effect-id _artifact)
     (when-let* ((old-range (and old
                                 (etaf--generation-effect-semantic
                                  old effect-id)))
                 (new-range
                  (etaf--generation-effect-semantic generation effect-id))
                 (old-key (and old-range
                               (etaf--semantic-backend-range-artifact-key
                                old-range))))
       (unless (equal old-key
                      (etaf--semantic-backend-range-artifact-key new-range))
         (remhash old-key (etaf-runtime-range-artifact-registry runtime)))))
   (etaf-runtime-candidate-range-artifacts runtime))
  (dolist (key (etaf-runtime-candidate-invalidated-artifact-keys runtime))
    (remhash key (etaf-runtime-artifact-registry runtime)))
  (dolist (delta (etaf-runtime-candidate-source-deltas runtime))
    (let ((source (car delta)) (effects (nth 2 delta)))
      (when (null effects)
        (remhash (etaf-runtime-route-token runtime)
                 (etaf--source-subscribers source))
        (remhash source (etaf-runtime-route-sources runtime))))))

(defun etaf--runtime-swap-generation (runtime old candidate)
  "Swap RUNTIME from OLD to CANDIDATE with an exact authority guard."
  (unless (eq (etaf-runtime-current-generation runtime) old)
    (error "ETAF generation authority changed during publication"))
  (setf (etaf-runtime-current-generation runtime) candidate))

(defun etaf--runtime-rollback-generation (runtime old candidate)
  "Idempotently restore OLD when RUNTIME still points at CANDIDATE."
  (when (eq (etaf-runtime-current-generation runtime) candidate)
    (setf (etaf-runtime-current-generation runtime) old)))

(defun etaf--runtime-preinstall-resources (runtime generation)
  "Install RUNTIME resources/artifacts for GENERATION and return journal."
  (let (journal completed)
    (unwind-protect
        (progn
          (dolist (instance (etaf-runtime-candidate-created runtime))
            (let ((key (etaf--component-instance-resource-key instance)))
              (push (list 'resource key instance) journal)
              (puthash key instance (etaf-runtime-resource-registry runtime))))
          (when (and (hash-table-p
                      (etaf-runtime-candidate-behavior-resource-keys runtime))
                     (hash-table-p
                      (etaf-runtime-candidate-behaviors runtime)))
            (maphash
             (lambda (identity resource-key)
               (let ((state (gethash identity
                                     (etaf-runtime-candidate-behaviors runtime))))
                 (when (and resource-key state
                            (not (eq state
                                     (gethash resource-key
                                              (etaf-runtime-resource-registry
                                               runtime)))))
                   (push (list 'behavior-resource resource-key state) journal)
                   (puthash resource-key state
                            (etaf-runtime-resource-registry runtime)))))
             (etaf-runtime-candidate-behavior-resource-keys runtime)))
          (maphash
           (lambda (effect-id artifact)
             (when-let ((semantic
                         (etaf--generation-effect-semantic
                          generation effect-id)))
               (let ((key (etaf--semantic-component-artifact-key semantic)))
                 (push (list 'artifact key artifact) journal)
                 (puthash key artifact
                          (etaf-runtime-artifact-registry runtime)))))
           (etaf-runtime-candidate-artifacts runtime))
          (maphash
           (lambda (effect-id artifact)
             (when-let ((range
                         (etaf--generation-effect-semantic
                          generation effect-id)))
               (let ((key (etaf--semantic-backend-range-artifact-key range)))
                 (push (list 'range-artifact key artifact) journal)
                 (puthash key artifact
                          (etaf-runtime-range-artifact-registry runtime)))))
           (etaf-runtime-candidate-range-artifacts runtime))
          (setq completed t)
          journal)
      (unless completed
        (etaf--runtime-rollback-resource-journal runtime journal)))))

(defun etaf--runtime-rollback-resource-journal (runtime journal)
  "Remove RUNTIME resources still owned by failed JOURNAL entries."
  (dolist (entry journal)
    (pcase (car entry)
      ('resource
       (when (eq (gethash (nth 1 entry)
                          (etaf-runtime-resource-registry runtime))
                 (nth 2 entry))
         (remhash (nth 1 entry) (etaf-runtime-resource-registry runtime))))
      ('behavior-resource
       (when (eq (gethash (nth 1 entry)
                          (etaf-runtime-resource-registry runtime))
                 (nth 2 entry))
         (remhash (nth 1 entry) (etaf-runtime-resource-registry runtime))))
      ('artifact
       (when (eq (gethash (nth 1 entry)
                          (etaf-runtime-artifact-registry runtime))
                 (nth 2 entry))
         (remhash (nth 1 entry) (etaf-runtime-artifact-registry runtime))))
      ('range-artifact
       (when (eq (gethash (nth 1 entry)
                          (etaf-runtime-range-artifact-registry runtime))
                 (nth 2 entry))
         (remhash (nth 1 entry)
                  (etaf-runtime-range-artifact-registry runtime))))))
  nil)

(defun etaf--runtime-participant-publish (participant)
  "Publish PARTICIPANT generation, restoring old authority on any failure."
  (let ((success nil)
        (runtime (etaf--generation-participant-runtime participant))
        (old (etaf--generation-participant-old participant))
        (candidate (etaf--generation-participant-candidate participant)))
    (unwind-protect
        (progn
          (etaf--runtime-swap-generation runtime old candidate)
          (setf (etaf--generation-participant-state participant) 'published
                success t))
      (unless success
        (etaf--runtime-rollback-generation runtime old candidate)))
    participant))

(defun etaf--runtime-participant-rollback (participant)
  "Rollback PARTICIPANT generation exactly and idempotently."
  (etaf--runtime-rollback-generation
   (etaf--generation-participant-runtime participant)
   (etaf--generation-participant-old participant)
   (etaf--generation-participant-candidate participant))
  (setf (etaf--generation-participant-state participant) 'rolled-back)
  participant)

(defun etaf--runtime-begin-component-overlay (runtime generation)
  "Seed RUNTIME candidate tables from committed GENERATION without traversal."
  (etaf--runtime-begin-candidate runtime)
  (ignore generation)
  (setf (etaf-runtime-candidate-behaviors runtime)
        (copy-hash-table (etaf-runtime-behaviors runtime))
        (etaf-runtime-candidate-behavior-resource-keys runtime)
        (copy-hash-table
         (or (etaf-runtime-behavior-resource-keys runtime)
             (make-hash-table :test #'equal)))))

(defun etaf--runtime-evaluate-component-input (runtime semantic)
  "Recompute RUNTIME SEMANTIC input and enqueue render only when it differs."
  (let* ((generation (etaf-runtime-current-generation runtime))
         (caller-id (etaf--semantic-component-caller-component-id semantic))
         (base-caller
          (and caller-id
               (etaf--pvec-get (etaf-generation-semantic-nodes generation)
                               caller-id)))
         (caller
          (and base-caller
               (or (gethash (etaf--semantic-component-identity base-caller)
                            (etaf-runtime-candidate-semantic-nodes runtime))
                   base-caller)))
         (instance
          (and caller
               (gethash (etaf--semantic-component-resource-key caller)
                        (etaf-runtime-resource-registry runtime))))
         deps)
    (let ((etaf--runtime-dependency-collector
           (lambda (source) (cl-pushnew source deps :test #'eq)))
          (etaf--current-runtime runtime)
          (etaf--current-component-instance instance)
          (etaf--current-component-identity
           (and caller (etaf--semantic-component-identity caller)))
          (etaf--current-component-semantic-id caller-id)
          (etaf--current-component-props
           (and caller (etaf--semantic-component-props caller)))
          (etaf--current-component-slots
           (and caller (etaf--semantic-component-slots caller)))
          (etaf--current-context
           (and caller (etaf--semantic-component-context-frame caller)))
          (etaf--active-effect nil)
          (etaf--render-phase-p t))
      (let* ((props (etaf--resolve-property-plist
                     (etaf--semantic-component-input-props semantic)))
             (slots (etaf--semantic-component-input-slots semantic))
             (candidate (copy-sequence semantic))
             (effect-id (etaf--semantic-component-input-effect-id semantic)))
        (setf (etaf--semantic-component-props candidate) (copy-tree props)
              (etaf--semantic-component-slots candidate) (copy-tree slots)
              (etaf--semantic-component-input-deps candidate) (nreverse deps))
        (puthash (etaf--semantic-component-identity semantic) candidate
                 (etaf-runtime-candidate-semantic-nodes runtime))
        (puthash effect-id
                 (etaf--generation-effect-create
                  :effect-id effect-id :kind 'component-input
                  :semantic-id (etaf--semantic-component-semantic-id semantic)
                  :deps (etaf--semantic-component-input-deps candidate))
                 (etaf-runtime-candidate-effects runtime))
        (unless (and (etaf--runtime-target-value-equal-p
                      props (etaf--semantic-component-props semantic))
                     (etaf--runtime-target-value-equal-p
                      slots (etaf--semantic-component-slots semantic)))
          (etaf--runtime-enqueue-effect
           runtime (etaf--semantic-component-effect-id semantic)))))))

(defun etaf--runtime-retarget-component-slot-ranges (runtime semantic slots)
  "Retarget SEMANTIC projection slot effects to candidate SLOTS in RUNTIME."
  (let* ((generation (etaf-runtime-current-generation runtime))
         (descendants
          (etaf--runtime-generation-descendant-ids
           generation (etaf--semantic-component-child-ids semantic)))
         found)
    (dolist (semantic-id descendants)
      (when-let ((slot-range
                  (let ((node (etaf--pvec-get
                               (etaf-generation-semantic-nodes generation)
                               semantic-id)))
                    (and (etaf--semantic-slot-range-p node) node))))
        (setq found t)
        (let* ((name (etaf--semantic-slot-range-name slot-range))
               (entry (assq name slots))
               (content (and entry (cdr entry)))
               (old-effect
                (etaf--generation-effect
                 generation (etaf--semantic-slot-range-effect-id slot-range)))
               (old-target (etaf--generation-effect-target old-effect))
               (owner-id
                (if entry
                    (and (etaf--slot-content-p content)
                         (etaf--slot-content-owner-component-id content))
                  (etaf--semantic-slot-range-consumer-component-id slot-range)))
               (children
                (if entry
                    (if (etaf--slot-content-p content)
                        (etaf--slot-content-children content)
                      content)
                  (plist-get old-target :children)))
               (target
                (list :children children :owner-id owner-id
                      :owner-input
                      (etaf--runtime-component-env-signature runtime owner-id)
                      :consumer-id
                      (etaf--semantic-slot-range-consumer-component-id slot-range)
                      :style-stack (plist-get old-target :style-stack))))
          (unless (etaf--runtime-target-value-equal-p target old-target)
            (let ((effect (copy-sequence old-effect)))
              (setf (etaf--generation-effect-target effect) target)
              (push (etaf--runtime-render-dirty-slot-range
                    runtime effect slot-range)
                    (etaf-runtime-candidate-eager-range-changes runtime)))))))
    (when found
      (let ((candidate (copy-sequence semantic)))
        (setf (etaf--semantic-component-slots candidate) (copy-tree slots)
              (etaf--semantic-component-input-slots candidate) (copy-tree slots))
        (puthash (etaf--semantic-component-identity semantic) candidate
                 (etaf-runtime-candidate-semantic-nodes runtime))))
    found))

(defun etaf--runtime-render-dirty-component (runtime semantic)
  "Render one input-ready SEMANTIC into RUNTIME candidate."
  (let* ((identity (etaf--semantic-component-identity semantic))
         (effect-id (etaf--semantic-component-effect-id semantic))
         (committed
          (etaf--pvec-get
           (etaf-generation-semantic-nodes
            (etaf-runtime-current-generation runtime))
           (etaf--semantic-component-semantic-id semantic)))
         (instance (gethash (etaf--semantic-component-resource-key semantic)
                            (etaf-runtime-resource-registry runtime)))
         (parent-id (etaf--semantic-component-parent-id semantic))
         (parent-record
          (and parent-id
               (etaf--pvec-get
                (etaf-generation-semantic-nodes
                 (etaf-runtime-current-generation runtime))
                parent-id)))
         (parent (and (etaf--semantic-component-p parent-record)
                      (etaf--semantic-component-identity parent-record)))
         (props (etaf--semantic-component-props semantic))
         (slots (etaf--semantic-component-slots semantic))
         deps context-deps result)
    (puthash (etaf--semantic-component-semantic-id semantic)
             (list :identity identity :instance instance :props props :slots slots)
             (etaf-runtime-candidate-component-envs runtime))
    (let ((etaf--current-component-identity parent)
          (etaf--current-component-semantic-id
           (etaf--semantic-component-semantic-id semantic))
          (etaf--current-semantic-parent-id
           (etaf--semantic-component-semantic-id semantic))
          (etaf--render-style-stack
           (copy-tree (etaf--semantic-component-caller-style-stack semantic)))
          (etaf--render-parent-style-stack nil)
          (etaf--rendering-component-effect-p t)
          (etaf--runtime-dependency-collector
           (lambda (source) (cl-pushnew source deps :test #'eq)))
          (etaf--context-inject-recorder
           (lambda (frame key)
             (cl-pushnew (cons (etaf-context-owner-id frame) key)
                         context-deps :test #'equal)))
          (etaf--active-effect nil)
          (etaf--render-phase-p t))
      (setq result
            (etaf--runtime-render-component-resource
             runtime instance identity
             props slots
             (etaf--semantic-component-path semantic)
             (etaf--semantic-component-output-range-id committed)
             (etaf--semantic-component-publication-kind committed)
             (etaf--runtime-context-frame-for-candidate runtime committed))))
    (let* ((transparent-p (eq (nth 5 result) 'transparent))
           (output-range
            (and transparent-p
                 (etaf--runtime-stage-component-output-range
                  runtime committed
                  (etaf--semantic-component-semantic-id semantic)
                  effect-id (nth 6 result) (nth 2 result) (nth 4 result)
                  (etaf--semantic-component-path semantic))))
           (publication-node (if transparent-p (cadr output-range)
                               (car result)))
           (candidate (copy-sequence semantic)))
      (setf (etaf--semantic-component-output-signature candidate)
            (copy-tree (nth 2 result))
            (etaf--semantic-component-props candidate) (copy-tree props)
            (etaf--semantic-component-slots candidate) (copy-tree slots)
            (etaf--semantic-component-deps candidate) (nreverse deps)
            (etaf--semantic-component-raw-slot-reader-p candidate) (nth 3 result)
            (etaf--semantic-component-publication-kind candidate)
            (if transparent-p 'transparent 'material)
            (etaf--semantic-component-output-range-id candidate)
            (and transparent-p
                 (etaf--semantic-range-semantic-id (car output-range)))
            (etaf--semantic-component-output-range-ref candidate)
            (and transparent-p
                 (etaf--semantic-range-range-ref (car output-range)))
            (etaf--semantic-component-context-frame candidate)
            (etaf-context-copy (nth 7 result))
            (etaf--semantic-component-context-deps candidate)
            (nreverse context-deps)
            (etaf--semantic-component-child-ids candidate)
            (copy-sequence
             (gethash (etaf--semantic-component-semantic-id semantic)
                      (etaf-runtime-candidate-graph-children runtime))))
      (etaf--runtime-enqueue-context-consumers
       runtime (etaf--semantic-component-semantic-id semantic)
       (etaf--semantic-component-context-frame committed)
       (etaf--semantic-component-context-frame candidate))
      (let ((new-direct (make-hash-table :test #'eql)))
        (dolist (id (etaf--semantic-component-child-ids candidate))
          (puthash id t new-direct))
        (dolist (old-root (etaf--semantic-component-child-ids committed))
          (unless (gethash old-root new-direct)
            (dolist (old-id
                     (etaf--runtime-generation-descendant-ids
                      (etaf-runtime-current-generation runtime)
                      (list old-root)))
              (cl-pushnew old-id
                          (etaf-runtime-candidate-removed-semantic-ids runtime)
                          :test #'eql)))))
      (puthash identity candidate
               (etaf-runtime-candidate-semantic-nodes runtime))
      (puthash (etaf--semantic-component-semantic-id candidate) candidate
               (etaf-runtime-candidate-graph-nodes runtime))
      (puthash effect-id
               (etaf--generation-effect-create
                :effect-id effect-id :kind 'component-render
                :semantic-id (etaf--semantic-component-semantic-id semantic)
                :deps (etaf--semantic-component-deps candidate))
               (etaf-runtime-candidate-effects runtime))
      (puthash effect-id (list :node publication-node :host-ref (cadr result)
                               :nodes (copy-sequence (nth 4 result))
                               :range-id (and transparent-p
                                              (etaf--semantic-range-semantic-id
                                               (car output-range))))
               (etaf-runtime-candidate-artifacts runtime))
      (push identity (etaf-runtime-candidate-rendered-identities runtime))
      (let ((committed-artifact
             (and (etaf--semantic-component-artifact-key committed)
                  (gethash (etaf--semantic-component-artifact-key committed)
                           (etaf-runtime-artifact-registry runtime)))))
        ;; Descendant-only publications invalidate cached ancestor artifacts
        ;; while retaining the ancestor semantic tree.  When that ancestor
        ;; becomes dirty on a later turn, rebuild its committed backend anchor
        ;; from the immutable generation before diffing the new render.
        (unless committed-artifact
          (setq committed-artifact
                (etaf--runtime-rebuild-component-artifact runtime committed)))
        (list candidate committed-artifact
              (gethash effect-id
                       (etaf-runtime-candidate-artifacts runtime)))))))

(defun etaf--runtime-render-dirty-range (runtime effect range)
  "Evaluate RUNTIME dirty RANGE EFFECT without running its Component owner."
  (let* ((generation (etaf-runtime-current-generation runtime))
         (base-component
          (etaf--pvec-get (etaf-generation-semantic-nodes generation)
                          (etaf--semantic-range-component-id range)))
         (component
          (or (gethash (etaf--semantic-component-identity base-component)
                       (etaf-runtime-candidate-semantic-nodes runtime))
              base-component))
         (instance
          (gethash (etaf--semantic-component-resource-key component)
                   (etaf-runtime-resource-registry runtime)))
         deps context-deps value nodes)
    (let ((collector
           (lambda (source) (cl-pushnew source deps :test #'eq))))
      (let ((etaf--runtime-dependency-collector collector)
            (etaf--context-inject-recorder
             (lambda (frame key)
               (cl-pushnew (cons (etaf-context-owner-id frame) key)
                           context-deps :test #'equal)))
            (etaf--current-runtime runtime)
            (etaf--current-component-instance instance)
            (etaf--current-component-identity
             (etaf--semantic-component-identity component))
            (etaf--current-component-props
             (etaf--semantic-component-props component))
            (etaf--current-component-slots
             (etaf--semantic-component-slots component))
            (etaf--current-context
             (etaf--semantic-component-context-frame component))
            (etaf--active-effect nil)
            (etaf--render-phase-p t))
        (setq value
              (etaf--runtime-normalize-range-value
               (funcall (etaf--expr-thunk
                         (etaf--generation-effect-target effect))))))
      (let ((etaf--runtime-dependency-collector collector)
            (etaf--context-inject-recorder
             (lambda (frame key)
               (cl-pushnew (cons (etaf-context-owner-id frame) key)
                           context-deps :test #'equal)))
            (etaf--render-runtime runtime)
            (etaf--current-component-semantic-id
             (etaf--semantic-range-component-id range))
            (etaf--current-semantic-parent-id
             (etaf--semantic-range-semantic-id range))
            (etaf--current-range-item-index
             (etaf--semantic-range-item-identity-index range))
            (etaf--rendering-range-p t)
            (etaf--active-effect nil)
            (etaf--render-phase-p t)
            (etaf--render-style-stack
             (copy-tree (etaf--semantic-range-caller-style-stack range))))
        (setq nodes (etaf--render-value-list
                     value (etaf--semantic-range-path range)))))
    (let* ((item-host-ids
            (copy-sequence
             (gethash (etaf--semantic-range-semantic-id range)
                      (etaf-runtime-candidate-graph-children runtime))))
           (all-item-ids
            (etaf--runtime-candidate-descendant-ids runtime item-host-ids))
           (item-index (make-hash-table :test #'equal))
           (candidate (copy-sequence range)))
      (unless (= (length nodes) (length item-host-ids))
        (signal 'etaf-runtime-error
                (list "Direct child Range items must be Host Views"
                      (length nodes) (length item-host-ids))))
      (dolist (item-id all-item-ids)
        (let ((item (gethash item-id
                             (etaf-runtime-candidate-graph-nodes runtime))))
          (unless (etaf--semantic-host-p item)
            (signal 'etaf-runtime-error
                    (list "Direct child Range items must be Host Views")))
          (puthash (etaf--semantic-host-identity item) item-id item-index)))
      (let ((new-set (make-hash-table :test #'eql)))
        (dolist (item-id all-item-ids) (puthash item-id t new-set))
        (dolist (old-id
                 (etaf--runtime-generation-descendant-ids
                  (etaf-runtime-current-generation runtime)
                  (etaf--semantic-range-item-host-ids range)))
          (unless (gethash old-id new-set)
            (push old-id
                  (etaf-runtime-candidate-removed-semantic-ids runtime)))))
      (setf (etaf--semantic-range-output-signature candidate) (copy-tree value)
            (etaf--semantic-range-deps candidate) (nreverse deps)
            (etaf--semantic-range-context-deps candidate) (nreverse context-deps)
            (etaf--semantic-range-artifact-key candidate)
            (cons (1+ (etaf-runtime-generation runtime))
                  (etaf--semantic-range-effect-id range))
            (etaf--semantic-range-item-host-ids candidate) item-host-ids
            (etaf--semantic-range-item-identity-index candidate) item-index
            (etaf--semantic-range-composition-version candidate)
            (1+ (etaf--semantic-range-composition-version range)))
      (puthash (etaf--semantic-range-semantic-id range) candidate
               (etaf-runtime-candidate-graph-nodes runtime))
      (puthash (etaf--semantic-range-effect-id range)
               (etaf--generation-effect-create
                :effect-id (etaf--semantic-range-effect-id range)
                :kind (or (etaf--semantic-range-kind range) 'range)
                :semantic-id (etaf--semantic-range-semantic-id range)
                :deps (etaf--semantic-range-deps candidate)
                :target (etaf--generation-effect-target effect))
               (etaf-runtime-candidate-effects runtime))
      (puthash (etaf--semantic-range-effect-id range) nodes
               (etaf-runtime-candidate-range-artifacts runtime))
      (etaf--runtime-invalidate-range-ancestors runtime range)
      (unless (equal-including-properties
               (etaf--semantic-range-output-signature range) value)
        (etaf--runtime-record-range-owner-update runtime range))
      (list range candidate
            (copy-sequence
             (gethash (etaf--semantic-range-artifact-key range)
                      (etaf-runtime-range-artifact-registry runtime)))
            nodes))))

(defun etaf--runtime-render-dirty-raw-range (runtime effect range)
  "Evaluate opaque raw RANGE for EFFECT in RUNTIME."
  (cl-multiple-value-bind (node deps)
      (etaf--runtime-evaluate-raw-range
       (etaf--generation-effect-target effect))
    (let ((candidate (copy-sequence range)))
      (setf (etaf--semantic-range-output-signature candidate) (copy-tree node)
            (etaf--semantic-range-deps candidate) deps
            (etaf--semantic-range-artifact-key candidate)
            (cons (1+ (etaf-runtime-generation runtime))
                  (etaf--semantic-range-effect-id range))
            (etaf--semantic-range-composition-version candidate)
            (1+ (etaf--semantic-range-composition-version range)))
      (puthash (etaf--semantic-range-semantic-id range) candidate
               (etaf-runtime-candidate-graph-nodes runtime))
      (puthash (etaf--semantic-range-effect-id range)
               (etaf--generation-effect-create
                :effect-id (etaf--semantic-range-effect-id range)
                :kind 'raw :semantic-id (etaf--semantic-range-semantic-id range)
                :deps deps :target (etaf--generation-effect-target effect))
               (etaf-runtime-candidate-effects runtime))
      (puthash (etaf--semantic-range-effect-id range) (list node)
               (etaf-runtime-candidate-range-artifacts runtime))
      (unless (equal-including-properties
               (etaf--semantic-range-output-signature range) node)
        (etaf--runtime-invalidate-range-ancestors runtime range)
        (etaf--runtime-record-range-owner-update runtime range))
      (list range candidate
            (copy-sequence
             (gethash (etaf--semantic-range-artifact-key range)
                      (etaf-runtime-range-artifact-registry runtime)))
            (list node)))))

(defun etaf--runtime-record-range-owner-update (runtime range)
  "Record RANGE's lexical Component lifecycle participation in RUNTIME."
  (when-let* ((component-id (etaf--semantic-range-component-id range))
              (component
               (etaf--pvec-get
                (etaf-generation-semantic-nodes
                 (etaf-runtime-current-generation runtime))
                component-id)))
    (cl-pushnew (etaf--semantic-component-identity component)
                (etaf-runtime-candidate-updated-component-identities runtime)
                :test #'equal)))

(defun etaf--runtime-render-dirty-inline-range (runtime effect inline)
  "Evaluate RUNTIME dirty INLINE EFFECT and stage its semantic output."
  (let* ((generation (etaf-runtime-current-generation runtime))
         (base-component
          (etaf--pvec-get (etaf-generation-semantic-nodes generation)
                          (etaf--semantic-inline-range-component-id inline)))
         (component
          (or (gethash (etaf--semantic-component-identity base-component)
                       (etaf-runtime-candidate-semantic-nodes runtime))
              base-component))
         (instance
          (gethash (etaf--semantic-component-resource-key component)
                   (etaf-runtime-resource-registry runtime)))
         deps context-deps output)
    (let ((etaf--runtime-dependency-collector
           (lambda (source) (cl-pushnew source deps :test #'eq)))
          (etaf--context-inject-recorder
           (lambda (frame key)
             (cl-pushnew (cons (etaf-context-owner-id frame) key)
                         context-deps :test #'equal)))
          (etaf--current-runtime runtime)
          (etaf--current-component-instance instance)
          (etaf--current-component-identity
           (etaf--semantic-component-identity component))
          (etaf--current-component-semantic-id
           (etaf--semantic-component-semantic-id component))
          (etaf--current-component-props
           (etaf--semantic-component-props component))
          (etaf--current-component-slots
           (etaf--semantic-component-slots component))
          (etaf--current-context
           (etaf--semantic-component-context-frame component))
          (etaf--active-effect nil)
          (etaf--render-phase-p t))
      (setq output
            (etaf--runtime-inline-value-string
             (funcall
              (etaf--expr-thunk (etaf--generation-effect-target effect)))
             (etaf--semantic-inline-range-surface-properties inline))))
    (let ((candidate (copy-sequence inline)))
      (setf (etaf--semantic-inline-range-output candidate)
            (copy-sequence output)
            (etaf--semantic-inline-range-deps candidate) (nreverse deps)
            (etaf--semantic-inline-range-context-deps candidate)
            (nreverse context-deps)
            (etaf--semantic-inline-range-composition-version candidate)
            (1+ (etaf--semantic-inline-range-composition-version inline)))
      (puthash (etaf--semantic-inline-range-semantic-id inline) candidate
               (etaf-runtime-candidate-graph-nodes runtime))
      (puthash (etaf--semantic-inline-range-effect-id inline)
               (etaf--generation-effect-create
                :effect-id (etaf--semantic-inline-range-effect-id inline)
                :kind 'inline
                :semantic-id (etaf--semantic-inline-range-semantic-id inline)
                :deps (etaf--semantic-inline-range-deps candidate)
                :target (etaf--generation-effect-target effect))
               (etaf-runtime-candidate-effects runtime))
      (unless (equal-including-properties
               (etaf--semantic-inline-range-output inline) output)
        (cl-pushnew (etaf--semantic-inline-range-parent-id inline)
                    (etaf-runtime-candidate-inline-host-ids runtime)
                    :test #'eql)
        (etaf--runtime-invalidate-semantic-ancestors
         runtime (etaf--semantic-inline-range-parent-id inline))
        (when-let ((component
                    (etaf--pvec-get
                     (etaf-generation-semantic-nodes
                      (etaf-runtime-current-generation runtime))
                     (etaf--semantic-inline-range-component-id inline))))
          (cl-pushnew (etaf--semantic-component-identity component)
                      (etaf-runtime-candidate-updated-component-identities runtime)
                      :test #'equal)))
      candidate)))

(defun etaf--runtime-render-dirty-slot-range (runtime effect slot-range)
  "Evaluate dirty SLOT-RANGE for EFFECT in RUNTIME and stage its backend change."
  (let* ((target (etaf--generation-effect-target effect))
         (semantic-id (etaf--semantic-slot-range-semantic-id slot-range))
         (effect-id (etaf--semantic-slot-range-effect-id slot-range)))
    (cl-multiple-value-bind (value deps nodes context-deps)
        (etaf--runtime-evaluate-slot-target
         runtime target semantic-id
         (etaf--semantic-slot-range-item-identity-index slot-range)
         (etaf--semantic-slot-range-path slot-range))
      (etaf--runtime-finish-slot-range-candidate
       runtime (etaf-runtime-current-generation runtime) slot-range
       (etaf--semantic-slot-range-identity slot-range) semantic-id effect-id
       (etaf--semantic-slot-range-range-ref slot-range)
       (etaf--semantic-slot-range-name slot-range)
       (etaf--semantic-slot-range-token slot-range)
       (plist-get target :owner-id) (plist-get target :consumer-id)
       (plist-get target :style-stack)
       (etaf--semantic-slot-range-path slot-range)
       target value deps nodes context-deps)
      (let ((candidate
             (gethash semantic-id
                      (etaf-runtime-candidate-graph-nodes runtime))))
        (unless (equal-including-properties
                 (etaf--semantic-slot-range-output-signature slot-range)
                 (etaf--semantic-slot-range-output-signature candidate))
          (etaf--runtime-invalidate-semantic-ancestors
           runtime (etaf--semantic-slot-range-parent-id slot-range))
          (etaf--runtime-record-slot-owner-update runtime slot-range))
        (list slot-range candidate
              (copy-sequence
               (gethash (etaf--semantic-slot-range-artifact-key slot-range)
                        (etaf-runtime-range-artifact-registry runtime)))
              nodes)))))

(defun etaf--runtime-record-slot-owner-update (runtime slot-range)
  "Record SLOT-RANGE author lifecycle participation in RUNTIME."
  (when-let* ((owner-id
               (etaf--semantic-slot-range-owner-component-id slot-range))
              (owner
               (etaf--pvec-get
                (etaf-generation-semantic-nodes
                 (etaf-runtime-current-generation runtime))
                owner-id)))
    (cl-pushnew (etaf--semantic-component-identity owner)
                (etaf-runtime-candidate-updated-component-identities runtime)
                :test #'equal)))

(defun etaf--runtime-invalidate-range-ancestors (runtime range)
  "Invalidate RUNTIME artifacts above changed RANGE without running effects."
  (etaf--runtime-invalidate-semantic-ancestors
   runtime (etaf--semantic-range-parent-id range)))

(defun etaf--runtime-range-change-has-backend-anchor-p (runtime change)
  "Return whether CHANGE has a live Ebox publication anchor in RUNTIME."
  (let* ((range (car change))
         (ref (and range (etaf--semantic-backend-range-ref range))))
    (and ref
         (ebox-range-ref-present-p (etaf-runtime-buffer runtime) ref))))

(defun etaf--runtime-invalidate-semantic-ancestors (runtime parent-id)
  "Invalidate RUNTIME artifacts from PARENT-ID through semantic ancestors."
  (let* ((generation (etaf-runtime-current-generation runtime))
         (nodes (etaf-generation-semantic-nodes generation)))
    (while (and parent-id (> parent-id 0))
      (let ((record (etaf--pvec-get nodes parent-id)))
        (cond
         ((etaf--semantic-host-p record)
          (let ((candidate (copy-sequence record)))
            (cl-incf (etaf--semantic-host-composition-version candidate))
            (puthash parent-id candidate
                     (etaf-runtime-candidate-graph-nodes runtime))
            (setq parent-id (etaf--semantic-host-parent-id record))))
         ((etaf--semantic-component-p record)
          (let ((candidate
                 (copy-sequence
                  (or (gethash (etaf--semantic-component-identity record)
                               (etaf-runtime-candidate-semantic-nodes runtime))
                      record))))
            (when-let ((key (etaf--semantic-component-artifact-key record)))
              (push key
                    (etaf-runtime-candidate-invalidated-artifact-keys runtime)))
            (setf (etaf--semantic-component-artifact-key candidate) nil)
            (cl-incf (etaf--semantic-component-composition-version candidate))
            (puthash (etaf--semantic-component-identity record) candidate
                     (etaf-runtime-candidate-semantic-nodes runtime))
            (puthash parent-id candidate
                     (etaf-runtime-candidate-graph-nodes runtime))
            (setq parent-id (etaf--semantic-component-parent-id record))))
         (t (setq parent-id nil)))))))

(defun etaf--runtime-compose-inline-parts
    (runtime generation parts &optional candidate-p)
  "Compose inline PARTS from GENERATION and optional RUNTIME candidate nodes."
  (apply
   #'concat
   (mapcar
    (lambda (part)
      (if (integerp part)
          (let ((inline
                 (or (and candidate-p
                          (gethash part
                                   (etaf-runtime-candidate-graph-nodes runtime)))
                     (etaf--pvec-get
                      (etaf-generation-semantic-nodes generation) part))))
            (etaf--semantic-inline-range-output inline))
        part))
    parts)))

(defun etaf--runtime-stage-inline-host (runtime generation host-id)
  "Stage RUNTIME HOST-ID content after inline effects using GENERATION."
  (let* ((old-host (etaf--pvec-get
                    (etaf-generation-semantic-nodes generation) host-id))
         (host (or (gethash host-id
                            (etaf-runtime-candidate-graph-nodes runtime))
                   (copy-sequence old-host)))
         (parts (etaf--semantic-host-content-parts old-host))
         (old-content
          (etaf--runtime-compose-inline-parts runtime generation parts nil))
         (new-content
          (etaf--runtime-compose-inline-parts runtime generation parts t)))
    (setf (etaf--semantic-host-content host) (copy-sequence new-content))
    (puthash host-id host (etaf-runtime-candidate-graph-nodes runtime))
    (list host
          (etaf--lower-resolved-semantic-host
           'text (copy-tree (etaf--semantic-host-props-signature old-host))
           old-content nil nil)
          (etaf--lower-resolved-semantic-host
           'text (copy-tree (etaf--semantic-host-props-signature host))
           new-content nil nil))))

(defun etaf--runtime-inline-host-owner-rendered-p
    (runtime generation host-id rendered-identities)
  "Return whether RUNTIME HOST-ID owner rendered in GENERATION.
RENDERED-IDENTITIES names the Component render participants."
  (let* ((host (or (gethash host-id
                            (etaf-runtime-candidate-graph-nodes runtime))
                   (etaf--pvec-get
                    (etaf-generation-semantic-nodes generation) host-id)))
         (inline-id (cl-find-if #'integerp
                                (etaf--semantic-host-content-parts host)))
         (inline (and inline-id
                      (or (gethash inline-id
                                   (etaf-runtime-candidate-graph-nodes runtime))
                          (etaf--pvec-get
                           (etaf-generation-semantic-nodes generation)
                           inline-id))))
         (component
          (and inline
               (etaf--pvec-get
                (etaf-generation-semantic-nodes generation)
                (etaf--semantic-inline-range-component-id inline)))))
    (and component
         (member (etaf--semantic-component-identity component)
                 rendered-identities))))

(defun etaf--runtime-component-overlay (runtime)
  "Publish RUNTIME dirty Component effects without traversing Root."
  (cl-block etaf--runtime-component-overlay
    (let* ((old (etaf-runtime-current-generation runtime))
         (queued-effect-ids
          (copy-sequence (etaf-runtime-dirty-effect-queue runtime)))
         (retry-effect-ids
          (cl-remove-if-not
           (lambda (effect-id)
             (etaf--generation-effect old effect-id))
           queued-effect-ids))
         changes range-changes inline-changes backend-component-identities
         journal resource-journal candidate-generation participant)
    (etaf--runtime-begin-component-overlay runtime old)
    ;; A source notification can race a generation promotion and leave an old
    ;; effect id in the FIFO.  Keep the dirty-id set and FIFO coherent before
    ;; sorting; stale ids are retired by the candidate generation cleanup.
    (dolist (effect-id queued-effect-ids)
      (unless (etaf--generation-effect old effect-id)
        (remhash effect-id (etaf-runtime-dirty-effect-ids runtime))))
    (setf (etaf-runtime-dirty-effect-queue runtime)
          (sort retry-effect-ids
                (lambda (left right)
                  (let* ((left-effect (etaf--generation-effect old left))
                         (right-effect (etaf--generation-effect old right))
                         (left-priority
                         (pcase (etaf--generation-effect-kind left-effect)
                            ('root 0) ('component-input 1)
            ((or 'range 'fragment 'raw 'slot 'inline) 2) (_ 3)))
                         (right-priority
                         (pcase (etaf--generation-effect-kind right-effect)
                            ('root 0) ('component-input 1)
                            ((or 'range 'fragment 'raw 'slot 'inline) 2) (_ 3))))
                    (if (= left-priority right-priority)
                        (< left right)
                      (< left-priority right-priority))))))
    (while (etaf-runtime-dirty-effect-queue runtime)
      (let* ((effect-id (pop (etaf-runtime-dirty-effect-queue runtime)))
             (effect (etaf--generation-effect old effect-id))
             (base-semantic
              (and effect (etaf--generation-effect-semantic old effect-id)))
             (semantic
              (and base-semantic
                   (if (etaf--semantic-component-p base-semantic)
                       (or (gethash
                            (etaf--semantic-component-identity base-semantic)
                            (etaf-runtime-candidate-semantic-nodes runtime))
                           base-semantic)
                     (or (gethash
                         (etaf--generation-effect-semantic-id effect)
                          (etaf-runtime-candidate-graph-nodes runtime))
                         base-semantic)))))
        (if (and effect semantic
                 (etaf--runtime-scheduled-semantic-live-p
                  old effect base-semantic))
            (progn
              (etaf--runtime-record-effect-input-version
               runtime old effect-id)
          (pcase (etaf--generation-effect-kind effect)
            ('component-input
             (etaf--runtime-evaluate-component-input runtime semantic))
            ('component-render
             (unless (member (etaf--semantic-component-identity semantic)
                             (etaf-runtime-candidate-rendered-identities
                              runtime))
               (push (etaf--runtime-render-dirty-component runtime semantic)
                     changes)))
            ((or 'range 'fragment)
             (push (etaf--runtime-render-dirty-range runtime effect semantic)
                   range-changes))
            ('raw
             (push (etaf--runtime-render-dirty-raw-range
                    runtime effect semantic)
                   range-changes))
            ('slot
             (push (etaf--runtime-render-dirty-slot-range
                    runtime effect semantic)
                   range-changes))
            ('inline
             (etaf--runtime-render-dirty-inline-range
              runtime effect semantic))))
          ;; A route can deliver an effect queued by the previous generation
          ;; after that semantic subtree has already been removed.  Retire the
          ;; effect from the next generation instead of evaluating a nil owner.
          (cl-pushnew effect-id
                      (etaf-runtime-candidate-removed-effect-ids runtime)
                      :test #'eql))))
    (setq range-changes
          (append (nreverse
                   (etaf-runtime-candidate-eager-range-changes runtime))
                  range-changes))
    ;; A semantic Range may be nested below a material Component whose
    ;; backend publication exposes only the ancestor component-output anchor.
    ;; Never submit an address that Ebox cannot resolve against this base;
    ;; discard the local candidate and let the next branch publish one exact
    ;; root candidate.  This is a proof miss, not an exception path.
    (let (fallback-component-effect-ids fallback-p)
      (dolist (change range-changes)
        (unless (etaf--runtime-range-change-has-backend-anchor-p
                runtime change)
          (setq fallback-p t)
          (when-let* ((range (car change))
                      (component-id
                       (etaf--semantic-backend-range-container-component-id
                        range))
                      (component
                       (etaf--pvec-get
                        (etaf-generation-semantic-nodes old) component-id)))
            (cl-pushnew
             (etaf--semantic-component-effect-id component)
             fallback-component-effect-ids :test #'eql))))
      (when fallback-p
        ;; Re-render the material owner during the root fallback.  A root
        ;; rebuild may otherwise carry its old artifact and leave the source
        ;; value visually stale even though the invalid Range was discarded.
        (setf (etaf-runtime-root-dirty-p runtime) t
              (etaf-runtime-dirty-effect-queue runtime) nil)
        (clrhash (etaf-runtime-dirty-effect-ids runtime))
        (dolist (effect-id fallback-component-effect-ids)
          (puthash effect-id t (etaf-runtime-dirty-effect-ids runtime)))
        (etaf--runtime-dispose-created-candidate runtime)
        (etaf--runtime-clear-candidate runtime)
        (cl-return-from etaf--runtime-component-overlay :root-fallback)))
    (let (material-changes)
      (dolist (change changes)
        (let ((candidate (car change)))
          (if (eq (etaf--semantic-component-publication-kind candidate)
                  'transparent)
              (let* ((committed
                      (etaf--pvec-get
                       (etaf-generation-semantic-nodes old)
                       (etaf--semantic-component-semantic-id candidate)))
                     (old-range
                      (etaf--pvec-get
                       (etaf-generation-semantic-nodes old)
                       (etaf--semantic-component-output-range-id committed)))
                     (new-range
                      (gethash (etaf--semantic-component-output-range-id candidate)
                               (etaf-runtime-candidate-graph-nodes runtime))))
                (push (list old-range new-range
                            (copy-sequence (plist-get (nth 1 change) :nodes))
                            (copy-sequence (plist-get (nth 2 change) :nodes)))
                      range-changes))
            (push change material-changes))))
      (setq changes (nreverse material-changes)))
    (setq changes
          (cl-remove-if
           (lambda (change)
             (equal-including-properties
              (plist-get (nth 1 change) :node)
              (plist-get (nth 2 change) :node)))
           changes)
          changes
          (let ((seen (make-hash-table :test #'equal)) result)
            (dolist (change changes (nreverse result))
              (let ((host-ref (plist-get (nth 2 change) :host-ref)))
                (unless (gethash host-ref seen)
                  (puthash host-ref t seen)
                  (push change result)))))
          backend-component-identities
          (mapcar (lambda (change)
                    (etaf--semantic-component-identity (car change)))
                  changes))
    (dolist (host-id (etaf-runtime-candidate-inline-host-ids runtime))
      (unless (etaf--runtime-inline-host-owner-rendered-p
               runtime old host-id backend-component-identities)
        (push (etaf--runtime-stage-inline-host runtime old host-id)
              inline-changes)))
    (setq range-changes
          (cl-remove-if
           (lambda (change)
             (let* ((range (car change))
                    (component
                     (etaf--pvec-get
                      (etaf-generation-semantic-nodes old)
                      (etaf--semantic-backend-range-container-component-id
                       range))))
               (member (etaf--semantic-component-identity component)
                       backend-component-identities)))
           range-changes))
    (setq candidate-generation (etaf--runtime-build-generation runtime old)
          resource-journal (etaf--runtime-preinstall-resources
                            runtime candidate-generation)
          participant (etaf--generation-participant-create
                       :runtime runtime :old old :candidate candidate-generation)
          journal (etaf--runtime-prearm-generation runtime candidate-generation))
    (condition-case err
        (if (and
             (cl-every
              (lambda (change)
                (equal-including-properties
                 (plist-get (nth 1 change) :node)
                 (plist-get (nth 2 change) :node)))
              changes)
             (cl-every
              (lambda (change)
                (equal-including-properties (nth 2 change) (nth 3 change)))
              range-changes)
             (cl-every
              (lambda (change)
                (equal-including-properties (nth 1 change) (nth 2 change)))
              inline-changes))
            (etaf--runtime-participant-publish participant)
          (let ((candidate (ebox-candidate-begin (etaf-runtime-buffer runtime))))
            (dolist (change changes)
              (ebox-candidate-replace-host-ref
               candidate (plist-get (nth 1 change) :host-ref)
               (plist-get (nth 2 change) :node)))
            (dolist (change range-changes)
              (unless (equal-including-properties (nth 2 change) (nth 3 change))
                (ebox-candidate-replace-range-ref
                 candidate (etaf--semantic-backend-range-ref (car change))
                 (nth 3 change))))
            (dolist (change inline-changes)
              (ebox-candidate-replace-host-ref
               candidate (etaf--semantic-host-host-ref (car change))
               (nth 2 change)))
            (ebox-commit
             (etaf-runtime-buffer runtime) candidate
             (lambda (_report)
               (etaf--runtime-participant-publish participant))
             (lambda (_report)
               (etaf--runtime-participant-rollback participant)))))
      ((error quit)
       (etaf--runtime-rollback-prearm runtime journal)
       (etaf--runtime-rollback-resource-journal runtime resource-journal)
       (clrhash (etaf-runtime-dirty-effect-ids runtime))
       (setf (etaf-runtime-dirty-effect-queue runtime) nil)
       (dolist (effect-id retry-effect-ids)
         (etaf--runtime-enqueue-effect runtime effect-id))
       (etaf--runtime-dispose-created-candidate runtime)
       (etaf--runtime-clear-candidate runtime)
       (signal (car err) (cdr err))))
    (etaf--runtime-complete-generation runtime old candidate-generation)
    (maphash (lambda (host-ref handlers)
               (puthash host-ref handlers (etaf-runtime-handlers runtime)))
             (etaf-runtime-candidate-handlers runtime))
    (maphash (lambda (host-ref props)
               (puthash host-ref props (etaf-runtime-host-props runtime)))
             (etaf-runtime-candidate-host-props runtime))
    (clrhash (etaf-runtime-dirty-effect-ids runtime))
    (setf (etaf-runtime-dirty-effect-queue runtime) nil)
    (unwind-protect
        (progn
          (dolist (instance (etaf-runtime-candidate-created runtime))
            (setf (etaf--component-instance-mounted-p instance) t)
            (etaf--run-hooks (etaf--component-instance-mounted-hooks instance)))
          (dolist (entry (etaf--generation-index-entries
                          candidate-generation 'lifecycle))
            (let ((identity (car entry)))
            (when-let* ((semantic (etaf--generation-semantic old identity))
                        (instance
                         (gethash
                          (etaf--semantic-component-resource-key semantic)
                          (etaf-runtime-resource-registry runtime))))
              (etaf--run-hooks
               (etaf--component-instance-updated-hooks instance))))))
      (etaf--runtime-clear-candidate runtime)))))

(defun etaf--runtime-render-effect (runtime)
  "Build and publish one Root-owned candidate for RUNTIME."
  (setf (etaf-runtime-candidate-full-rebuild-p runtime) t)
  (let ((old-generation (etaf-runtime-current-generation runtime))
        next-root candidate-generation journal resource-journal participant)
    (condition-case err
        (let* ((etaf--render-runtime runtime)
               (root-deps (copy-sequence
                           (etaf-runtime-candidate-root-deps runtime)))
               (etaf--runtime-dependency-collector
                (lambda (source) (cl-pushnew source root-deps :test #'eq)))
               (etaf--active-effect nil)
               (nodes (etaf--runtime-render-root runtime)))
          (setf (etaf-runtime-candidate-root-deps runtime)
                (nreverse root-deps))
          (etaf--runtime-stage-root-range
           runtime (etaf-runtime-candidate-root-deps runtime))
          (setq next-root
                (cond
                 ((null nodes) (ebox-spacer))
                 ((null (cdr nodes)) (car nodes))
                 (t (apply #'ebox-column nodes))))
          (setq candidate-generation
                (etaf--runtime-build-generation runtime old-generation)
                resource-journal (etaf--runtime-preinstall-resources
                                  runtime candidate-generation)
                participant (etaf--generation-participant-create
                             :runtime runtime :old old-generation
                             :candidate candidate-generation)
                journal
                (etaf--runtime-prearm-generation runtime candidate-generation))
          (if old-generation
              (let ((candidate (ebox-candidate-begin
                                (etaf-runtime-buffer runtime))))
                (ebox-candidate-replace-root candidate next-root)
                (ebox-commit
                 (etaf-runtime-buffer runtime) candidate
                 (lambda (_report)
                   (etaf--runtime-participant-publish participant))
                 (lambda (_report)
                   (etaf--runtime-participant-rollback participant))))
            (ebox-render-to-buffer (etaf-runtime-buffer runtime) next-root)
            (etaf--runtime-participant-publish participant))
          (etaf--runtime-complete-generation
           runtime old-generation candidate-generation)
          (setf (etaf-runtime-root-node runtime) next-root
                (etaf-runtime-handlers runtime)
                (etaf-runtime-candidate-handlers runtime)
                (etaf-runtime-host-props runtime)
                (etaf-runtime-candidate-host-props runtime)
                (etaf-runtime-root-dirty-p runtime) nil)
          (clrhash (etaf-runtime-dirty-effect-ids runtime))
          (setf (etaf-runtime-dirty-effect-queue runtime) nil))
      ((error quit)
       (etaf--runtime-rollback-prearm runtime journal)
       (etaf--runtime-rollback-resource-journal runtime resource-journal)
       (clrhash (etaf-runtime-dirty-effect-ids runtime))
       (setf (etaf-runtime-dirty-effect-queue runtime) nil)
       (etaf--runtime-dispose-created-candidate runtime)
       (etaf--runtime-rollback-behaviors runtime)
       (etaf--runtime-clear-candidate runtime)
       (signal (car err) (cdr err))))
    ;; Publication has completed.  Lifecycle and cleanup callbacks run after
    ;; the retained state is promoted; their errors remain visible without
    ;; incorrectly rolling back an already published Ebox tree.
    (unwind-protect
        (let ((groups (etaf--runtime-promote runtime)))
          (etaf--runtime-promote-behaviors runtime)
          (etaf--runtime-run-lifecycle groups))
      (etaf--runtime-rollback-behaviors runtime)
      (etaf--runtime-clear-candidate runtime))
    next-root))

(defun etaf--runtime-render-root-turn (runtime &optional force-components-p)
  "Evaluate and publish one full root turn for RUNTIME.
When FORCE-COMPONENTS-P is non-nil, re-evaluate retained Components whose
backend anchor proof failed; ordinary root turns keep their artifact reuse."
  (let ((etaf--runtime-force-full-component-render-p force-components-p))
    (etaf--runtime-record-effect-input-version
     runtime (etaf-runtime-current-generation runtime)
     (etaf-runtime-root-effect-id runtime))
    (etaf--runtime-begin-candidate runtime)
    (setf (etaf-runtime-root-view-cache runtime)
          (etaf--runtime-evaluate-root-candidate runtime))
    (etaf--runtime-render-effect runtime)))

(defun etaf--runtime-request-flush (runtime)
  "Synchronously flush RUNTIME, or mark one follow-up flush while busy."
  (when (etaf-runtime-mounted-p runtime)
    (if (or (> (etaf-runtime-event-depth runtime) 0)
            (etaf-runtime-flushing-p runtime))
        (setf (etaf-runtime-pending-p runtime) t)
      (setf (etaf-runtime-flushing-p runtime) t)
      (let* ((etaf--runtime-fixed-point-stamps
              (make-hash-table :test #'equal))
             (etaf--runtime-fixed-point-steps 0)
             (etaf--runtime-fixed-point-history nil)
             (etaf--runtime-fixed-point-step-bound
              (plist-get
               (etaf--runtime-fixed-point-graph-size
                runtime (etaf-runtime-current-generation runtime))
               :bound)))
        (unwind-protect
            (progn
              (if (etaf-runtime-root-dirty-p runtime)
                  (etaf--runtime-render-root-turn runtime)
                (when (eq (etaf--runtime-component-overlay runtime)
                          :root-fallback)
                  (etaf--runtime-render-root-turn runtime t)))
              (while (etaf-runtime-pending-p runtime)
                (setf (etaf-runtime-pending-p runtime) nil)
                (if (etaf-runtime-root-dirty-p runtime)
                    (etaf--runtime-render-root-turn runtime)
                  (when (eq (etaf--runtime-component-overlay runtime)
                            :root-fallback)
                    (etaf--runtime-render-root-turn runtime t)))))
          (setf (etaf-runtime-flushing-p runtime) nil))))))

;;;###autoload
(defun etaf-runtime-flush (&optional runtime)
  "Flush mounted RUNTIME immediately and return its root Ebox node."
  (let ((runtime (etaf-runtime-require-mounted runtime)))
    (etaf--runtime-request-flush runtime)
    (etaf-runtime-root-node runtime)))

;;;###autoload
(defun etaf-runtime-mount (buffer-or-name view)
  "Mount VIEW into BUFFER-OR-NAME and return the live buffer."
  (let* ((buffer (get-buffer-create buffer-or-name))
         (old (gethash buffer etaf--runtime-table)))
    (when old
      (etaf-runtime-unmount old))
    (let* ((scope (etaf-effect-scope :detached t :name buffer))
           (runtime (etaf--runtime-create
                     :buffer buffer
                     :root-view view
                     :scope scope
                     :instances (make-hash-table :test #'equal)
                     :resource-registry (make-hash-table :test #'equal)
                     :mount-epoch (cl-incf etaf--mount-epoch-counter)
                     :next-resource-id 0
                     :next-effect-id 0
                     :next-semantic-id 1
                     :root-effect-id 0
                     :root-range-id 1
                     :artifact-registry (make-hash-table :test #'equal)
                     :range-artifact-registry (make-hash-table :test #'equal)
                     :candidate-artifacts (make-hash-table :test #'equal)
                     :candidate-range-artifacts (make-hash-table :test #'eql)
                     :route-sources (make-hash-table :test #'eq)
                     :dirty-effect-ids (make-hash-table :test #'eql)
                     :handlers (make-hash-table :test #'equal)
                     :host-props (make-hash-table :test #'equal)
                     :behaviors (make-hash-table :test #'equal)
                     :behavior-resource-keys (make-hash-table :test #'equal)
                     :root-dirty-p t)))
      (puthash buffer runtime etaf--runtime-table)
      (let ((route (etaf-runtime-route-create
                    :runtime-id (etaf-runtime-mount-epoch runtime)
                    :mount-epoch (etaf-runtime-mount-epoch runtime)
                    :scheduler 'etaf--runtime-route-scheduler)))
        (setf (etaf-runtime-route-token runtime) route)
        (puthash (etaf-runtime-mount-epoch runtime) runtime
                 etaf--runtime-route-registry))
      (condition-case err
          (progn
            (etaf--runtime-begin-candidate runtime)
            (setf (etaf-runtime-flushing-p runtime) t
                  (etaf-runtime-root-view-cache runtime)
                  (etaf--runtime-evaluate-root-candidate runtime))
            (unwind-protect
                (etaf--runtime-render-effect runtime)
              (setf (etaf-runtime-flushing-p runtime) nil)))
        ((error quit)
         (remhash buffer etaf--runtime-table)
         (remhash (etaf-runtime-mount-epoch runtime)
                  etaf--runtime-route-registry)
         (etaf-scope-stop scope)
         (signal (car err) (cdr err))))
      (when (etaf-runtime-pending-p runtime)
        (setf (etaf-runtime-pending-p runtime) nil)
        (etaf--runtime-request-flush runtime))
      (when (fboundp 'etaf-events-enable-input)
        (etaf-events-enable-input buffer))
      buffer)))

;;;###autoload
(defun etaf-runtime-unmount (&optional runtime)
  "Unmount RUNTIME and dispose its Component scopes."
  (let ((runtime (etaf-runtime-require-mounted runtime)))
    (setf (etaf-runtime-mounted-p runtime) nil)
    (when (fboundp 'etaf-events-disable-input)
      (etaf-events-disable-input (etaf-runtime-buffer runtime)))
    (remhash (etaf-runtime-buffer runtime) etaf--runtime-table)
    (remhash (etaf-runtime-mount-epoch runtime) etaf--runtime-route-registry)
    (maphash
     (lambda (source _)
       (remhash (etaf-runtime-route-token runtime)
                (etaf--source-subscribers source)))
     (etaf-runtime-route-sources runtime))
    (clrhash (etaf-runtime-route-sources runtime))
    (let (instances)
      (maphash (lambda (_identity instance) (push instance instances))
               (etaf-runtime-instances runtime))
      (dolist (instance (sort instances
                               (lambda (left right)
                                 (> (length (etaf--component-instance-identity left))
                                    (length (etaf--component-instance-identity right))))))
        (etaf--runtime-dispose-instance instance t)))
    (etaf-scope-stop (etaf-runtime-scope runtime))
    (maphash
     (lambda (identity state)
       (when-let ((cleanup (cdr state)))
         (etaf--runtime-run-contained-cleanup
          runtime 'behavior-unmount identity cleanup)))
     (etaf-runtime-behaviors runtime))
    (clrhash (etaf-runtime-instances runtime))
    (clrhash (etaf-runtime-resource-registry runtime))
    runtime))

;;;###autoload
(defun etaf-unmount (&optional runtime)
  "Unmount RUNTIME, defaulting to the active or `current-buffer' Runtime."
  (etaf-runtime-unmount runtime))

;;;###autoload
(defun etaf-on-mounted (callback)
  "Run CALLBACK after the current Component is first published."
  (unless (functionp callback)
    (signal 'wrong-type-argument (list 'functionp callback)))
  (unless etaf--current-component-instance
    (error "ETAF-on-mounted requires Component setup"))
  (push callback
        (etaf--component-instance-mounted-hooks
         etaf--current-component-instance))
  callback)

;;;###autoload
(defun etaf-on-updated (callback)
  "Run CALLBACK after the current Component participates in an update."
  (unless (functionp callback)
    (signal 'wrong-type-argument (list 'functionp callback)))
  (unless etaf--current-component-instance
    (error "ETAF-on-updated requires Component setup"))
  (push callback
        (etaf--component-instance-updated-hooks
         etaf--current-component-instance))
  callback)

;;;###autoload
(defun etaf-on-unmounted (callback)
  "Run CALLBACK when the current Component is disposed."
  (unless (functionp callback)
    (signal 'wrong-type-argument (list 'functionp callback)))
  (unless etaf--current-component-instance
    (error "ETAF-on-unmounted requires Component setup"))
  (push callback
        (etaf--component-instance-unmounted-hooks
         etaf--current-component-instance))
  callback)

(provide 'etaf-runtime)

;;; etaf-runtime.el ends here
