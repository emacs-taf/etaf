;;; etaf-runtime.el --- ETAF retained runtime and publication loop -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Runtime is the owner of mounted lifetime, retained Component instances,
;; reactive render effects, and the Ebox commit boundary.  It does not know
;; Ebox's private tree representation; Renderer is the only lowering port.

;;; Code:

(require 'cl-lib)
(require 'ebox)
(require 'ecss)
(require 'etaf-view)
(require 'etaf-component)
(require 'etaf-scheduler)
(require 'etaf-reactive)
(require 'etaf-generation)
(require 'etaf-host)
(require 'etaf-retirement)
(require 'etaf-render-port)
(require 'etaf-renderer)
(require 'etaf-context)
(require 'etaf-behavior)
(require 'etaf-observer)

(defvar etaf--drag-cancel-p)

(declare-function etaf--render-value-list "etaf-renderer" (value path))
(declare-function etaf--generated-host-ref
                  "etaf-renderer" (props path &optional site-token))
(declare-function etaf--ebox-properties
                  "etaf-renderer" (props path &optional site-token runtime host-ref))
(declare-function etaf--lower-resolved-semantic-host
                  "etaf-renderer" (name props content children range-child-p))
(declare-function etaf--ebox-forest-root
                  "etaf-renderer" (nodes source-identity))
(declare-function etaf--ebox-import-input "etaf-renderer" (input))
(declare-function etaf--ebox-input-for-nodes "etaf-renderer" (nodes))
(declare-function ebox-range-ref-present-p "ebox" (buffer-or-name range-ref))
(declare-function ebox-call-with-render-burst
                  "ebox-buffer-backend" (function &rest arguments))
(declare-function ebox-paint-slot-create "ebox" (spec))
(declare-function ebox-paint-slot-installed-p "ebox" (slot))
(declare-function ebox-paint-slot-spec "ebox" (slot))
(declare-function ebox-paint-slot-apply-updates "ebox" (buffer updates))
(declare-function ebox-paint-slot-rollback-updates "ebox" (journal))
(declare-function ebox-transaction-active-p "ebox" ())
(declare-function etaf--host-update-queue-cell
                  "etaf-host-update" (runtime effect-id))
(declare-function etaf--host-update-reset "etaf-host-update" (runtime))
(declare-function etaf--host-update-try-flush "etaf-host-update" (runtime))
(declare-function etaf--host-update-environment "etaf-host-update" (runtime effect-id))
(defvar etaf--render-runtime)
(defvar etaf--render-style-owners)
(defvar etaf--render-parent-style-owners)
(defvar etaf--current-context)
(defvar gcs-done)
(defvar gc-elapsed)

(define-error 'etaf-runtime-error "ETAF runtime error")

(cl-defstruct (etaf--component-instance
               (:constructor etaf--component-instance-create))
  "Retained state and lifecycle for one logical Component call."
  spec
  identity
  scope
  state
  (setup-complete-p nil)
  prop-sources
  style-scope
  local-refs
  context
  mounted-hooks
  updated-hooks
  unmounted-hooks
  resource-key
  (mounted-p nil))

(cl-defstruct (etaf--semantic-component
               (:constructor etaf--semantic-component-create))
  semantic-id identity input-effect-id effect-id resource-key props attrs slots
  defaults
  input-props input-attrs input-slots output-signature
  path caller-style-owners input-deps deps
  parent-id caller-component-id child-ids raw-slot-reader-p
  output-range-id
  context-frame context-deps
  (composition-version 0))

(cl-defstruct (etaf--host-property-binding
               (:constructor etaf--host-property-binding-create))
  "One independently reactive, identity-neutral Host property."
  property expression dependencies)

(cl-defstruct (etaf--semantic-host (:constructor etaf--semantic-host-create))
  semantic-id identity parent-id component-id child-ids host-ref key name effect-id
  property-bindings deps context-deps style-root-p
  ;; Host inputs after Behavior composition and expression resolution, before
  ;; scoped style and Theme resolution.
  ;; Reactive expressions are retained separately in property-bindings.
  base-props
  ;; Canonical Ebox declaration projection used to compare backend updates.
  props-signature content content-parts path site-token style-identity
  (composition-version 0)
  ;; Complete committed Host inputs after resolution/augmentation, before
  ;; lowering to Ebox.  Theme-only updates patch this projection; they must not
  ;; rebuild it from the sparse public Host-props index or append Behaviors again.
  resolved-props property-deps)

(cl-defstruct (etaf--semantic-range (:constructor etaf--semantic-range-create))
  semantic-id identity effect-id kind parent-id component-id token range-ref
  path caller-style-owners output-signature deps artifact-key item-root-ids
  item-identity-index context-deps
  keyed-context-signature keyed-item-signatures keyed-item-root-id-index
  keyed-item-node-span-index keyed-key-order
  (composition-version 0))

(cl-defstruct (etaf--semantic-inline-range
               (:constructor etaf--semantic-inline-range-create))
  semantic-id identity effect-id parent-id component-id token path
  surface-properties output deps context-deps (composition-version 0))

(cl-defstruct (etaf--semantic-slot-range
               (:constructor etaf--semantic-slot-range-create))
  semantic-id identity effect-id parent-id owner-component-id
  consumer-component-id token name range-ref path style-owners
  output-signature deps artifact-key item-root-ids item-identity-index
  context-deps
  (composition-version 0))

(cl-defstruct (etaf--semantic-root (:constructor etaf--semantic-root-create))
  "Immutable semantic Root owner stored at generation node zero."
  semantic-id effect-id input-signature deps child-ids)

(cl-defstruct (etaf--generation-effect
               (:constructor etaf--generation-effect-make))
  "Immutable generation scheduling target."
  effect-id kind semantic-id deps target dependency-versions)

(cl-defun etaf--generation-effect-create
    (&key effect-id kind semantic-id deps target)
  "Compile an evaluated target and its consumed dependency versions."
  (etaf--generation-effect-make
   :effect-id effect-id :kind kind :semantic-id semantic-id :deps deps
   :target target
   :dependency-versions (vconcat (mapcar #'etaf--source-version deps))))

(cl-defstruct (etaf--contribution-index
               (:constructor etaf--contribution-index-create))
  "Persistent generation contribution delta rooted at BASE."
  base handlers host-props contexts themes behaviors context-consumers lifecycle
  host-removals semantic-removals (depth 1))

(defcustom etaf-generation-index-max-depth 16
  "Maximum contribution-delta depth retained by one Runtime generation.
Local publications keep point-sized deltas, but an unbounded base chain makes
handler, Context, Theme, Behavior, and lifecycle reads progressively slower.
ETAF periodically flattens the effective contribution snapshot at this depth;
the operation preserves committed values and removal semantics."
  :type 'positive-integer
  :group 'etaf)

(cl-defstruct (etaf--generation-participant
               (:constructor etaf--generation-participant-create))
  runtime semantic-candidate paint-journal (state 'unpublished))

(cl-defstruct (etaf-generation
               (:constructor etaf--generation-create))
  generation-id root-semantic-id semantic-nodes effect-map
  source-effects effect-sources parent-table children-table
  resource-membership identity-index indexes)

(defun etaf--semantic-parent-id (semantic)
  "Return SEMANTIC's retained parent id, or nil for Root."
  (cond
   ((etaf--semantic-component-p semantic)
    (etaf--semantic-component-parent-id semantic))
   ((etaf--semantic-host-p semantic)
    (etaf--semantic-host-parent-id semantic))
   ((etaf--semantic-range-p semantic)
    (etaf--semantic-range-parent-id semantic))
   ((etaf--semantic-slot-range-p semantic)
    (etaf--semantic-slot-range-parent-id semantic))
   ((etaf--semantic-inline-range-p semantic)
    (etaf--semantic-inline-range-parent-id semantic))))

(defun etaf--semantic-child-ids (semantic)
  "Return SEMANTIC's immutable direct child ids."
  (cond
   ((etaf--semantic-root-p semantic)
    (etaf--semantic-root-child-ids semantic))
   ((etaf--semantic-component-p semantic)
    (etaf--semantic-component-child-ids semantic))
   ((etaf--semantic-host-p semantic)
    (etaf--semantic-host-child-ids semantic))
   ((etaf--semantic-range-p semantic)
    (etaf--semantic-range-item-root-ids semantic))
   ((etaf--semantic-slot-range-p semantic)
    (etaf--semantic-slot-range-item-root-ids semantic))))

(defun etaf--generation-parent-id (generation semantic-id)
  "Return SEMANTIC-ID's parent directly from GENERATION's semantic node."
  (etaf--semantic-parent-id
   (etaf--pvec-get (etaf-generation-semantic-nodes generation) semantic-id)))

(defun etaf--generation-child-ids (generation semantic-id)
  "Return SEMANTIC-ID's children directly from GENERATION's semantic node."
  (etaf--semantic-child-ids
   (etaf--pvec-get (etaf-generation-semantic-nodes generation) semantic-id)))

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
  ;; Retain the old root-node offset for already mounted Runtime records.
  ;; This reserved slot has no current-root authority and is never read/written.
  reserved-root-node
  scope
  scheduler-context
  root-effect-id
  root-range-id
  candidate-root-deps
  root-view-cache
  root-dirty-p
  instances
  resource-registry
  mount-epoch
  host-authority
  next-resource-id
  next-effect-id
  next-semantic-id
  generation-authority
  candidate-effects
  candidate-source-deltas
  route-token
  route-sources
  dirty-effect-ids
  dirty-effect-queue
  handlers
  host-props
  host-geometry-region-ids
  theme-paint-slots
  (interaction-keymaps (make-hash-table :test #'equal))
  candidate-theme-paint-updates
  behaviors
  candidate-live
  candidate-semantic-nodes
  candidate-component-envs
  candidate-computed-snapshots
  candidate-prop-values
  candidate-graph-nodes
  candidate-identity-entries
  candidate-graph-children
  candidate-graph-child-tails
  candidate-removed-semantic-ids
  candidate-removed-effect-ids
  candidate-removed-host-refs
  candidate-rendered-identities
  candidate-updated-component-identities
  candidate-generation-metrics
  candidate-full-rebuild-p
  range-artifact-registry
  candidate-range-artifacts
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
  retirement-journals
  observer
  (next-operation-id 0)
  (next-semantic-candidate-id 0)
  (event-depth 0)
  dirty-effect-queue-tail
  prepared-host-updates prepared-host-generation prepared-host-cohort
  prepared-host-variants prepared-host-binding-token prepared-host-rejections
  flush-function)

(defcustom etaf-generation-mirror-route 'project
  "Compatibility mirror route used after a committed generation changes.
`legacy' preserves incremental Runtime table updates, `project' rebuilds exact
mirrors from the committed generation, and `shadow' runs legacy updates before
checking them against a fresh generation projection."
  :type '(choice (const legacy) (const project) (const shadow))
  :group 'etaf)

(defun etaf--runtime-generation-authority (runtime)
  "Return RUNTIME's generation authority, creating its empty owner if needed."
  (or (etaf-runtime-generation-authority runtime)
      (setf (etaf-runtime-generation-authority runtime)
            (etaf-generation-authority-create))))

(defun etaf-runtime-current-generation (runtime)
  "Return RUNTIME's uniquely authoritative committed generation."
  (let ((authority (etaf--runtime-generation-authority runtime)))
    (unless (and (integerp (etaf-generation-authority-token authority))
                 (>= (etaf-generation-authority-token authority) 0)
                 (etaf-generation-store-versions-p
                  (etaf-generation-authority-store-versions authority)))
      (signal 'etaf-generation-error
              (list :invalid-committed-authority authority)))
    (etaf-generation-authority-current authority)))

(defun etaf-runtime-generation-token (runtime)
  "Return RUNTIME's committed semantic generation token."
  (etaf-generation-authority-token
   (etaf--runtime-generation-authority runtime)))

(defun etaf-runtime-store-versions (runtime)
  "Return RUNTIME's immutable committed store-version snapshot."
  (etaf-generation-authority-store-versions
   (etaf--runtime-generation-authority runtime)))

(defun etaf-runtime--set-current-generation (runtime generation)
  "Set RUNTIME's compatibility generation pointer to GENERATION."
  (etaf-generation-authority-set-current
   (etaf--runtime-generation-authority runtime) generation))

(gv-define-simple-setter etaf-runtime-current-generation
  etaf-runtime--set-current-generation)

(defun etaf--theme-paint-face-spec (property value)
  "Return PROPERTY's Ebox face spec for resolved paint VALUE, or nil."
  (pcase property
    (:color (and value (list :foreground value)))
    ((or :bgcolor :background-color)
     (and value (list :background value)))
    (:border-top-color (list :overline (or value t)))
    (:border-bottom-color
     (list :underline
           (append (list :position t) (and value (list :color value)))))
    ((or :border-left-color :border-right-color)
     (if value (list :background value) (list :inverse-video t)))
    (:border-color
     (if value
         (list :background value :overline value
               :underline (list :position t :color value))
       (list :inverse-video t :overline t
             :underline (list :position t))))
    (_ nil)))

(defun etaf--runtime-theme-paint-property-p (property)
  "Return non-nil when PROPERTY has a geometry-neutral Ebox paint slot."
  (memq property '(:color :bgcolor :background-color
                   :border :border-color
                   :border-top-color :border-bottom-color
                   :border-left-color :border-right-color)))

(defun etaf--theme-border-paint-parts (value)
  "Return `(SHAPE COLOR)' for a stable color-only Ebox border VALUE."
  (condition-case nil
      (let* ((declarations
              (ebox-style-compile-declarations (list :border value) t))
             (width (plist-get declarations 'ebox/border-top-width))
             (style (plist-get declarations 'ebox/border-top-style))
             (color (plist-get declarations 'ebox/border-top-color)))
        (if (stringp value)
            (list 'implicit color)
          (list (list width style) color)))
    (error nil)))

(defun etaf--runtime-interaction-keymap
    (runtime host-ref press drag drag-lock-modifier)
  "Return a native keymap dispatching the committed HOST-REF in RUNTIME."
  (let ((maps (etaf-runtime-interaction-keymaps runtime))
        (key (list host-ref press drag drag-lock-modifier)))
    (or (gethash key maps)
        (let ((map
               (ebox-keymap-create
                :activate
                (when press
                  (lambda () (etaf--dispatch-activation runtime host-ref)))
                :drag
                (when drag
                  (lambda (gesture)
                    (when (and (etaf-runtime-mounted-p runtime)
                               (cdr (assq 'drag
                                          (etaf-runtime-handler-for
                                           runtime host-ref))))
                      (let ((etaf--drag-cancel-p
                             (eq (plist-get gesture :phase) 'cancel)))
                        (etaf-dispatch-event runtime host-ref 'drag gesture t)))))
                :drag-lock-modifier drag-lock-modifier)))
          (when (>= (hash-table-count maps) 512) (clrhash maps))
          (puthash key map maps)
          map))))

(defun etaf--runtime-theme-paint-value
    (runtime property token source resolved)
  "Return RUNTIME's stable paint slot for PROPERTY TOKEN from SOURCE.
RESOLVED is the current projected paint value."
  (if (not (and runtime
                (not (ecss-declaration-value-tagged-p resolved))
                (etaf--runtime-theme-paint-property-p property)
                (or (etaf-ref-p source) (etaf-computed-p source))))
      resolved
    (let* ((sources (etaf-runtime-theme-paint-slots runtime))
           (slots (or (gethash source sources)
                      (let ((created (make-hash-table :test #'equal)))
                        (puthash source created sources)
                        created)))
           (key (list property (copy-tree token)))
           (updates (etaf-runtime-candidate-theme-paint-updates runtime)))
      (unless (hash-table-p updates)
        (error "ETAF Theme paint update requires an active candidate"))
      (if (eq property :border)
          (if-let* ((parts (etaf--theme-border-paint-parts resolved)))
              (let* ((shape (car parts))
                     (color (cadr parts))
                     (spec (etaf--theme-paint-face-spec
                            :border-color color))
                     (entry (gethash key slots))
                     (entry
                      (cond
                       ((and entry (equal shape (plist-get entry :shape)))
                        entry)
                       ((null entry)
                        (let* ((slot (ebox-paint-slot-create spec))
                               (created
                                (list :shape shape :slot slot
                                      :value
                                      (if (eq shape 'implicit)
                                          slot
                                        (list (car shape) (cadr shape)
                                              slot)))))
                          (puthash key created slots)
                          created)))))
                (if (null entry)
                    resolved
                  (let ((slot (plist-get entry :slot)))
                    (unless (and (ebox-paint-slot-installed-p slot)
                                 (equal spec (ebox-paint-slot-spec slot)))
                      (puthash slot spec updates)))
                  (plist-get entry :value)))
            resolved)
        (let* ((spec (etaf--theme-paint-face-spec property resolved))
               (entry (or (gethash key slots)
                          (let* ((slot (ebox-paint-slot-create spec))
                                 (created (list :slot slot :value slot)))
                            (puthash key created slots)
                            created))))
          (let ((slot (plist-get entry :slot)))
            (unless (and (ebox-paint-slot-installed-p slot)
                         (equal spec (ebox-paint-slot-spec slot)))
              (puthash slot spec updates)))
          (plist-get entry :value))))))

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
        (if-let* ((entry (assoc key
                              (etaf--contribution-index-values index slot))))
            (setq found entry)
          (setq index (etaf--contribution-index-base index)))))
    (cdr found)))

(defun etaf--contribution-index-entries (index slot)
  "Return effective committed entries for contribution INDEX SLOT."
  (let ((index index)
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

(defun etaf--generation-index-entries (generation slot)
  "Return effective committed entries for GENERATION SLOT."
  (etaf--contribution-index-entries
   (and generation (etaf-generation-indexes generation)) slot))

(defun etaf--contribution-index-compact (index)
  "Return one base-free effective snapshot of contribution INDEX."
  (etaf--contribution-index-create
   :handlers (copy-tree (etaf--contribution-index-entries index 'handlers))
   :host-props (copy-tree
                (etaf--contribution-index-entries index 'host-props))
   :contexts (copy-tree (etaf--contribution-index-entries index 'contexts))
   :themes (copy-tree (etaf--contribution-index-entries index 'themes))
   :behaviors (copy-tree (etaf--contribution-index-entries index 'behaviors))
   :context-consumers
   (copy-tree (etaf--contribution-index-entries index 'context-consumers))
   :lifecycle (copy-tree
               (etaf--contribution-index-entries index 'lifecycle))
   :depth 1))

(defun etaf--contribution-index-bound-depth (index)
  "Compact contribution INDEX when it exceeds the configured depth."
  (if (> (etaf--contribution-index-depth index)
         (max 1 etaf-generation-index-max-depth))
      (etaf--contribution-index-compact index)
    index))

(defun etaf--generation-validate-context-acyclic (generation)
  "Reject Context provider/consumer cycles in GENERATION."
  (let ((edges (make-hash-table :test #'eql))
        (visiting (make-hash-table :test #'eql))
        (visited (make-hash-table :test #'eql)))
    (dolist (entry (etaf--generation-index-entries
                    generation 'context-consumers))
      (let ((provider-id (caar entry)))
        (dolist (effect-id (cdr entry))
          (when-let* ((effect (etaf--generation-effect generation effect-id)))
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
  (copy-sequence
   (etaf--generation-index-lookup
    (etaf-runtime-current-generation runtime) 'host-props host-ref)))

;;;###autoload
(defun etaf-runtime-update-host-geometries (runtime updates)
  "Incrementally update several HOST-REF geometries in mounted RUNTIME.

This is ETAF's display-side bridge to Ebox's typed geometry operation.  The
caller's controlled state remains authoritative; this function only changes
retained Host low-level geometry and layer facts.  UPDATES is an alist of
`(HOST-REF . GEOMETRY-PLIST)' entries and is committed as one Ebox batch."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (and (listp updates)
               (cl-every (lambda (entry)
                           (and (consp entry) (listp (cdr entry))))
                         updates))
    (signal 'etaf-runtime-error (list "Invalid Host geometry updates" updates)))
  (let (resolved)
    (dolist (entry updates)
      (let* ((host-ref (car entry))
             (geometry (cdr entry))
             (props (gethash host-ref (etaf-runtime-host-props runtime))))
        (unless props
          (signal 'etaf-runtime-error
                  (list "Unknown committed Host" host-ref)))
        (let* ((region-id (or (plist-get props :id) host-ref))
               (cached (gethash host-ref
                                (etaf-runtime-host-geometry-region-ids runtime))))
          (unless (equal cached region-id)
            (puthash host-ref region-id
                     (etaf-runtime-host-geometry-region-ids runtime)))
          (push (list host-ref region-id geometry)
                resolved))))
    (when (ebox-transaction-active-p)
      (signal 'etaf-runtime-error
              (list "Cannot update Host geometry inside an active Ebox transaction")))
    (with-current-buffer (etaf-runtime-buffer runtime)
      (condition-case error-data
          (ebox-call-with-update-batch
           (lambda ()
             (dolist (entry (nreverse resolved))
               (apply #'ebox-region-update-geometry
                      (nth 1 entry) (nth 2 entry)))))
        (error
         (signal 'etaf-runtime-error
                 (list "Host geometry update rejected"
                       (mapcar #'car resolved) error-data)))))))

;;;###autoload
(defun etaf-runtime-update-host-geometry (runtime host-ref &rest geometry)
  "Incrementally update HOST-REF geometry in mounted RUNTIME."
  (etaf-runtime-update-host-geometries
   runtime (list (cons host-ref geometry))))

(defun etaf-runtime-host-props-entries (runtime)
  "Return committed Host contribution entries for RUNTIME."
  (copy-tree (etaf--generation-index-entries
              (etaf-runtime-current-generation runtime) 'host-props)))

(defun etaf-runtime-host-ancestries (runtime host-refs)
  "Return committed semantic ancestries for HOST-REFS in RUNTIME.
This activation-local lookup visits the retained graph at most once, stopping
when all requested Hosts are found.  Callers use it only for overlapping hit
candidates; no second retained identity or layout index is maintained."
  (let* ((generation (etaf-runtime-current-generation runtime))
         (wanted (make-hash-table :test #'equal))
         (result (make-hash-table :test #'equal)))
    (dolist (ref host-refs) (puthash ref t wanted))
    (catch 'complete
      (cl-labels
          ((visit
            (id ancestors)
            (let* ((semantic (etaf--pvec-get
                              (etaf-generation-semantic-nodes generation) id))
                   (lineage (cons id ancestors)))
              (when (etaf--semantic-host-p semantic)
                (let ((ref (etaf--semantic-host-host-ref semantic)))
                  (when (gethash ref wanted)
                    (puthash ref lineage result)
                    (remhash ref wanted)
                    (when (zerop (hash-table-count wanted))
                      (throw 'complete nil)))))
              (dolist (child (etaf--semantic-child-ids semantic))
                (visit child lineage)))))
        (when (and generation host-refs)
          (visit (etaf-generation-root-semantic-id generation) nil))))
    result))

(defun etaf-runtime-host-ancestor-refs (runtime host-ref)
  "Return committed Host references above HOST-REF in RUNTIME.
The nearest semantic Host is first.  The result is derived from the retained
generation graph for one event and is not a second parent index."
  (let* ((generation (etaf-runtime-current-generation runtime))
         (lineage (gethash host-ref
                           (etaf-runtime-host-ancestries runtime (list host-ref))))
         result)
    (dolist (id (cdr lineage) result)
      (when-let* ((semantic (etaf--pvec-get
                             (etaf-generation-semantic-nodes generation) id))
                  ((etaf--semantic-host-p semantic))
                  (ref (etaf--semantic-host-host-ref semantic)))
        (setq result (append result (list ref)))))))

(defun etaf--runtime-generation-mirror-projection (generation)
  "Return exact compatibility mirrors projected from GENERATION."
  (etaf-generation-project-mirrors
   (etaf--generation-index-entries generation 'handlers)
   (etaf--generation-index-entries generation 'host-props)))

(defun etaf--runtime-install-legacy-generation-mirrors (runtime full-p)
  "Install RUNTIME candidate mirrors through the legacy FULL-P route."
  (if full-p
      (setf (etaf-runtime-handlers runtime)
            (etaf-runtime-candidate-handlers runtime)
            (etaf-runtime-host-props runtime)
            (etaf-runtime-candidate-host-props runtime))
    (unless (hash-table-p (etaf-runtime-handlers runtime))
      (setf (etaf-runtime-handlers runtime) (make-hash-table :test #'equal)))
    (unless (hash-table-p (etaf-runtime-host-props runtime))
      (setf (etaf-runtime-host-props runtime)
            (make-hash-table :test #'equal)))
    (maphash
     (lambda (host-ref handlers)
       (puthash host-ref handlers (etaf-runtime-handlers runtime)))
     (etaf-runtime-candidate-handlers runtime))
    (maphash
     (lambda (host-ref props)
       (puthash host-ref props (etaf-runtime-host-props runtime)))
     (etaf-runtime-candidate-host-props runtime))))

(defun etaf--runtime-install-projected-generation-mirrors
    (runtime projection)
  "Install detached generation mirror PROJECTION into RUNTIME."
  (setf (etaf-runtime-handlers runtime) (plist-get projection :handlers)
        (etaf-runtime-host-props runtime) (plist-get projection :host-props)))

(defun etaf-runtime-generation-mirrors-consistent-p (runtime)
  "Return non-nil when RUNTIME mirrors equal its committed generation."
  (let ((projection
         (etaf--runtime-generation-mirror-projection
          (etaf-runtime-current-generation runtime))))
    (and
     (etaf-generation-mirror-equal-p
      (or (etaf-runtime-handlers runtime) (make-hash-table :test #'equal))
      (plist-get projection :handlers))
     (etaf-generation-mirror-equal-p
      (or (etaf-runtime-host-props runtime) (make-hash-table :test #'equal))
      (plist-get projection :host-props)))))

(defun etaf--runtime-install-generation-mirrors
    (runtime generation full-p)
  "Install RUNTIME compatibility mirrors for committed GENERATION.
FULL-P preserves the old route's full-root replacement distinction."
  (let ((projection (etaf--runtime-generation-mirror-projection generation)))
    (pcase etaf-generation-mirror-route
      ('legacy
       (etaf--runtime-install-legacy-generation-mirrors runtime full-p))
      ('project
       (etaf--runtime-install-projected-generation-mirrors runtime projection))
      ('shadow
       (etaf--runtime-install-legacy-generation-mirrors runtime full-p)
       (unless (and
                (etaf-generation-mirror-equal-p
                 (etaf-runtime-handlers runtime)
                 (plist-get projection :handlers))
                (etaf-generation-mirror-equal-p
                 (etaf-runtime-host-props runtime)
                 (plist-get projection :host-props)))
         (signal 'etaf-generation-error
                 (list :compatibility-mirror-drift
                       :generation
                       (and generation
                            (etaf-generation-generation-id generation))))))
      (_
       (signal 'etaf-generation-error
               (list :unknown-mirror-route etaf-generation-mirror-route))))
    runtime))

(defun etaf--runtime-build-contribution-indexes (runtime base full-p)
  "Build RUNTIME immutable generation contributions over BASE.
FULL-P means candidate tables describe the complete mounted tree."
  (let (handler-additions prop-additions context-additions theme-additions
        behavior-membership behavior-removals
        context-consumer-additions lifecycle-membership
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
               (cond ((etaf--semantic-host-p semantic)
                      (etaf--semantic-host-effect-id semantic))
                     ((etaf--semantic-range-p semantic)
                      (etaf--semantic-range-effect-id semantic))
                     ((etaf--semantic-inline-range-p semantic)
                      (etaf--semantic-inline-range-effect-id semantic))
                     ((etaf--semantic-slot-range-p semantic)
                      (etaf--semantic-slot-range-effect-id semantic))))
              (new-deps
               (cond ((etaf--semantic-host-p semantic)
                      (etaf--semantic-host-context-deps semantic))
                     ((etaf--semantic-range-p semantic)
                      (etaf--semantic-range-context-deps semantic))
                     ((etaf--semantic-inline-range-p semantic)
                      (etaf--semantic-inline-range-context-deps semantic))
                     ((etaf--semantic-slot-range-p semantic)
                      (etaf--semantic-slot-range-context-deps semantic))))
              (old (and base effect-id
                        (etaf--pvec-get (etaf-generation-semantic-nodes base)
                                        semantic-id)))
              (old-deps
               (cond ((etaf--semantic-host-p old)
                      (etaf--semantic-host-context-deps old))
                     ((etaf--semantic-range-p old)
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
    (maphash
     (lambda (identity _state)
       (unless (gethash identity (etaf-runtime-candidate-behaviors runtime))
         (push (copy-tree identity) behavior-removals)))
     (etaf-runtime-behaviors runtime))
    (dolist (identity
             (cl-delete-duplicates
              (append (copy-sequence
                       (etaf-runtime-candidate-rendered-identities runtime))
                      (copy-sequence
                       (etaf-runtime-candidate-updated-component-identities
                        runtime)))
              :test #'equal))
      (push (cons (copy-tree identity) 'updated) lifecycle-membership))
    (let ((base-index (and (not full-p) base
                           (etaf-generation-indexes base))))
      (etaf--contribution-index-bound-depth
       (etaf--contribution-index-create
        :base base-index
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
        (append changed-component-ids behavior-removals
                (copy-sequence
                 (etaf-runtime-candidate-removed-semantic-ids runtime)))
        :depth (1+ (if base-index
                       (etaf--contribution-index-depth base-index)
                     0)))))))

(defun etaf-runtime-generation (runtime)
  "Return RUNTIME's committed generation id."
  (if-let* ((generation (etaf-runtime-current-generation runtime)))
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

(defun etaf--semantic-backend-range-semantic-id (semantic)
  "Return retained semantic id for direct or slot Range SEMANTIC."
  (if (etaf--semantic-range-p semantic)
      (etaf--semantic-range-semantic-id semantic)
    (etaf--semantic-slot-range-semantic-id semantic)))

(defun etaf--semantic-backend-range-container-component-id (semantic)
  "Return the Component containing backend Range SEMANTIC's artifact."
  (if (etaf--semantic-range-p semantic)
      (etaf--semantic-range-component-id semantic)
    (etaf--semantic-slot-range-consumer-component-id semantic)))

(defun etaf--semantic-backend-range-item-root-ids (semantic)
  "Return direct material root ids owned by backend Range SEMANTIC."
  (if (etaf--semantic-range-p semantic)
      (etaf--semantic-range-item-root-ids semantic)
    (etaf--semantic-slot-range-item-root-ids semantic)))

(defun etaf--generation-component-output-range (generation component)
  "Return COMPONENT's transparent output Range from GENERATION."
  (let* ((range-id (etaf--semantic-component-output-range-id component))
         (range (and range-id
                     (etaf--pvec-get
                      (etaf-generation-semantic-nodes generation) range-id))))
    (unless (etaf--semantic-range-p range)
      (signal 'etaf-runtime-error
              (list "Transparent Component has no output Range")))
    range))

(defun etaf--runtime-committed-range-input (runtime semantic)
  "Return RUNTIME's committed canonical input for SEMANTIC Range.
An invalidated derived snapshot is composed only when a caller needs it."
  (let* ((key (etaf--semantic-backend-range-artifact-key semantic))
         (registry (etaf-runtime-range-artifact-registry runtime))
         (artifact (gethash key registry)))
    (when (eq artifact :invalid)
      (setq artifact
            (etaf--runtime-snapshot-range-input
             runtime (etaf-runtime-current-generation runtime) semantic nil))
      (puthash key artifact registry))
    (unless (ebox-canonical-input-p artifact)
      (signal 'etaf-runtime-error
              (list "Range artifact has no canonical input")))
    artifact))

(defun etaf--runtime-range-input (runtime semantic)
  "Return RUNTIME's candidate-aware canonical input for SEMANTIC Range."
  (let ((artifact
         (gethash
          (if (etaf--semantic-range-p semantic)
              (etaf--semantic-range-effect-id semantic)
            (etaf--semantic-slot-range-effect-id semantic))
          (etaf-runtime-candidate-range-artifacts runtime))))
    (if (eq artifact :invalid)
        (let ((input (etaf--runtime-snapshot-range-input
                      runtime (etaf-runtime-current-generation runtime)
                      semantic t)))
          (puthash (if (etaf--semantic-range-p semantic)
                       (etaf--semantic-range-effect-id semantic)
                     (etaf--semantic-slot-range-effect-id semantic))
                   input (etaf-runtime-candidate-range-artifacts runtime))
          input)
      (if artifact
        (progn
          (unless (ebox-canonical-input-p artifact)
            (signal 'etaf-runtime-error
                    (list "Candidate Range artifact is not canonical input")))
          artifact)
        (etaf--runtime-committed-range-input runtime semantic)))))

(defun etaf--runtime-output-semantic (runtime generation id candidate-p)
  "Read output ID from GENERATION or RUNTIME's CANDIDATE-P overlay."
  (or (and candidate-p (gethash id (etaf-runtime-candidate-graph-nodes runtime)))
      (and generation (etaf--pvec-get (etaf-generation-semantic-nodes generation) id))))

(defun etaf--runtime-output-forest (runtime generation id candidate-p in-range-p)
  "Lower semantic ID into a canonical forest without evaluating application code.
GENERATION and CANDIDATE-P choose RUNTIME's output facts.  IN-RANGE-P flattens
adjacent semantic Ranges into their single physical Ebox child Range.  A Host
starts a new child layout, where another physical Range may be introduced."
  (let ((node (etaf--runtime-output-semantic runtime generation id candidate-p)))
    (cond
     ((etaf--semantic-component-p node)
      (etaf--runtime-output-forest
       runtime generation (etaf--semantic-component-output-range-id node)
       candidate-p in-range-p))
     ((or (etaf--semantic-range-p node) (etaf--semantic-slot-range-p node))
      (let ((children
             (cl-mapcan (lambda (child)
                          (etaf--runtime-output-forest
                           runtime generation child candidate-p t))
                        (etaf--semantic-backend-range-item-root-ids node))))
        (if (or in-range-p (null (etaf--semantic-backend-range-ref node)))
            children
          (list (apply #'ebox-child-range
                       (etaf--semantic-backend-range-ref node) children)))))
     ((etaf--semantic-host-p node)
      (let* ((text-p (eq (etaf--semantic-host-name node) 'text))
             (parts (etaf--semantic-host-content-parts node))
             (content
              (if (and text-p parts)
                  (apply #'concat
                         (mapcar (lambda (part)
                                   (if (integerp part)
                                       (etaf--semantic-inline-range-output
                                        (etaf--runtime-output-semantic
                                         runtime generation part candidate-p))
                                     part)) parts))
                (etaf--semantic-host-content node)))
             (children
              (unless text-p
                (cl-mapcan (lambda (child)
                             (etaf--runtime-output-forest
                              runtime generation child candidate-p nil))
                           (etaf--semantic-host-child-ids node)))))
        (list (etaf--lower-resolved-semantic-host
               (etaf--semantic-host-name node)
               (etaf--semantic-host-props-signature node) content children
               (cl-some
                (lambda (child)
                  (let ((value (etaf--runtime-output-semantic
                                runtime generation child candidate-p)))
                    (or (etaf--semantic-component-p value)
                        (etaf--semantic-range-p value)
                        (etaf--semantic-slot-range-p value))))
                (etaf--semantic-host-child-ids node))))))
     (t (signal 'etaf-runtime-error (list "Missing output semantic node" id))))))

(defun etaf--runtime-snapshot-range-input (runtime generation range candidate-p)
  "Snapshot RANGE from GENERATION and optional RUNTIME candidate facts."
  (let ((builder (ebox-source-builder-create)))
    (let* ((etaf--ebox-source-builder builder)
           (nodes (etaf--runtime-output-forest
                   runtime generation (etaf--semantic-backend-range-semantic-id range)
                   candidate-p t)))
      (when (and (etaf--semantic-range-p range)
                 (eq (etaf--semantic-range-kind range) 'root))
        (setq nodes (list (etaf--ebox-forest-root
                           nodes (list 'etaf-runtime-root
                                       (etaf-runtime-mount-epoch runtime))))))
      (ebox-canonical-input-create nodes (ebox-source-builder-finish builder)))))

(defun etaf--runtime-range-nodes (runtime semantic)
  "Import SEMANTIC Range's canonical input from RUNTIME and return its nodes."
  (etaf--ebox-import-input (etaf--runtime-range-input runtime semantic)))

(defun etaf--generation-semantic (generation identity)
  "Return IDENTITY semantic node from GENERATION."
  (when-let* ((id (gethash identity (etaf-generation-identity-index generation))))
    (etaf--pvec-get (etaf-generation-semantic-nodes generation) id)))

(defun etaf--generation-effect-semantic (generation effect-id)
  "Return EFFECT-ID semantic node from GENERATION."
  (when-let* ((effect (etaf--pvec-get
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
          ((etaf--semantic-host-p semantic)
           (etaf--pvec-get nodes
                           (etaf--semantic-host-semantic-id semantic)))
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

(defun etaf--runtime-range-effect-staged-p (runtime generation effect)
  "Return non-nil when EFFECT was already recomputed in RUNTIME's candidate.
An ancestor Component or Range can lower this descendant before its queued
committed effect is visited.  Fresh lowering stages a new effect record;
carrying an unchanged subtree keeps the exact record from GENERATION and
must not absorb that subtree's independently dirty work."
  (let* ((effect-id (etaf--generation-effect-effect-id effect))
         (candidate (gethash effect-id
                             (etaf-runtime-candidate-effects runtime))))
    (and candidate
         (not (eq candidate (etaf--generation-effect generation effect-id)))
         (gethash (etaf--generation-effect-semantic-id effect)
                  (etaf-runtime-candidate-graph-nodes runtime)))))

(defun etaf--generation-source-effects (generation source)
  "Return current effect ids for SOURCE in GENERATION."
  (etaf--pvec-get (etaf-generation-source-effects generation)
                  (etaf-reactive-source-id source)))

(defvar etaf--runtime-table (make-hash-table :test #'eq)
  "Buffer -> mounted ETAF Runtime table.")

(defvar etaf--runtime-route-registry
  (make-hash-table :test #'eql :weakness 'value)
  "Mount epoch -> live Runtime weak-value registry.")

(defun etaf--runtime-kill-buffer ()
  "Unmount the ETAF Runtime owned by the current buffer before it dies."
  (when-let* ((runtime (gethash (current-buffer) etaf--runtime-table)))
    (condition-case condition
        (etaf-runtime-call-operation
         runtime 'unmount "buffer kill"
         (lambda () (etaf--runtime-unmount-now runtime 'buffer-kill)))
      ((error quit)
       (etaf--runtime-record-observer-diagnostic
        runtime (list :kind 'buffer-kill-retirement
                      :condition condition))))))

(defun etaf--runtime-enqueue-effect (runtime effect-id &optional source-only)
  "Append EFFECT-ID once to RUNTIME's stable FIFO work queue."
  (let ((queued (gethash effect-id (etaf-runtime-dirty-effect-ids runtime))))
    ;; Explicit candidate input, Context and retry work must still run when
    ;; its ordinary reactive dependencies retained their previous values.
    (puthash effect-id (if (and source-only (not (eq queued t))) 'source t)
             (etaf-runtime-dirty-effect-ids runtime))
    (unless queued
      (let ((cell (or (etaf--host-update-queue-cell runtime effect-id)
                      (list effect-id))))
        (setcdr cell nil)
        (if (etaf-runtime-dirty-effect-queue-tail runtime)
            (setcdr (etaf-runtime-dirty-effect-queue-tail runtime) cell)
          (setf (etaf-runtime-dirty-effect-queue runtime) cell))
        (setf (etaf-runtime-dirty-effect-queue-tail runtime) cell)))))

(defun etaf--runtime-source-effect-changed-p (runtime generation effect)
  "Settle EFFECT's direct inputs and report a changed consumed value.
Only inputs of already queued targets are visited; unobserved computed
branches remain lazy.  Source propagation has finished before this gate."
  (let ((deps (etaf--generation-effect-deps effect))
        (versions (etaf--generation-effect-dependency-versions effect))
        (index 0)
        (etaf--tracking-enabled-p nil)
        (etaf--runtime-dependency-collector nil)
        (etaf--active-effect nil)
        (etaf--render-phase-p t)
        changed)
    (while (and deps (not changed))
      (let ((source (pop deps)))
        (when (and (etaf-computed-p source) (etaf-computed-dirty-p source))
          (setq changed
                (not (etaf--runtime-settle-effect-computed
                      runtime generation effect source))))
        (setq changed (or changed
                          (/= (aref versions index) (etaf--source-version source))))
        (setq index (1+ index))))
    changed))

(defun etaf--runtime-settle-effect-computed (runtime generation effect source)
  "Settle SOURCE in EFFECT's committed environment, or require rendering.
Context reads use the ordinary render path so its dependency recorder remains
authoritative even when a new conditional Context read would return an equal
value.  Such a read unwinds before changing the computed cache."
  (let ((enter (etaf--host-update-environment
                runtime (etaf--generation-effect-effect-id effect)))
        (etaf--context-inject-recorder #'etaf--runtime-defer-settled-context))
    (catch 'etaf-settlement-needs-render
      (if enter
          (funcall enter #'etaf--computed-value source)
        (let* ((semantic (etaf--generation-effect-semantic
			  generation (etaf--generation-effect-effect-id effect)))
               (component-id
		(cond
		 ((etaf--semantic-component-p semantic)
		  (if (eq (etaf--generation-effect-kind effect) 'component-input)
                      (etaf--semantic-component-caller-component-id semantic)
		    (etaf--semantic-component-semantic-id semantic)))
		 ((etaf--semantic-host-p semantic)
		  (etaf--semantic-host-component-id semantic))
		 ((etaf--semantic-range-p semantic)
		  (etaf--semantic-range-component-id semantic))
		 ((etaf--semantic-inline-range-p semantic)
		  (etaf--semantic-inline-range-component-id semantic))
		 ((etaf--semantic-slot-range-p semantic)
		  (etaf--semantic-slot-range-owner-component-id semantic)))))
          (etaf--runtime-call-with-component-env
           runtime component-id (lambda () (etaf--computed-value source)))))
      t)))

(defun etaf--runtime-defer-settled-context (_frame _key)
  "Retain the ordinary rendering path for a Context-dependent computed."
  (throw 'etaf-settlement-needs-render nil))

(defun etaf--runtime-settle-source-effects (runtime)
  "Remove equal derived inputs from RUNTIME's notified work in place.
Retain failed work for retry and preserve every explicit candidate request."
  (let* ((generation (etaf-runtime-current-generation runtime))
         (ids (etaf-runtime-dirty-effect-ids runtime))
         (unshadowed-p
          (and (not (etaf-runtime-root-dirty-p runtime))
               (or (null (cdr (etaf-runtime-dirty-effect-queue runtime)))
                   (etaf--runtime-primitive-queue-p runtime generation))))
         (again t))
    (while again
      (let ((queue (etaf-runtime-dirty-effect-queue runtime))
            previous removed)
        (while queue
          (let* ((effect-id (car queue))
                 (effect (and (eq (gethash effect-id ids) 'source)
                              (etaf--generation-effect generation effect-id))))
            (if (and effect
                     (or unshadowed-p
                         (not (etaf--runtime-source-effect-shadowed-p
                               runtime generation effect ids nil)))
                     (not (etaf--runtime-source-effect-changed-p
                           runtime generation effect)))
                (progn
                  (setq removed t)
                  (remhash effect-id ids)
                  (when (equal effect-id (etaf-runtime-root-effect-id runtime))
                    (setf (etaf-runtime-root-dirty-p runtime) nil))
                  (if previous (setcdr previous (cdr queue))
                    (setf (etaf-runtime-dirty-effect-queue runtime) (cdr queue))))
              (setq previous queue)))
          (setq queue (cdr queue)))
        (setf (etaf-runtime-dirty-effect-queue-tail runtime) previous)
        ;; A source FIFO can put a child before its equal structural parent.
        ;; Revisit only after pruning makes another target eligible.  Each
        ;; additional pass removes at least one queued target.
        (setq again (and removed (not unshadowed-p)
                         (etaf-runtime-dirty-effect-queue runtime)))))))

(defun etaf--runtime-primitive-queue-p (runtime generation)
  "Whether all queued owners are GENERATION's already classified primitives.
The existing binding table also records unsupported primitive owners.  Neither
kind can retire descendants, so no Component ancestry lookup is necessary."
  (when (eq generation (etaf-runtime-prepared-host-generation runtime))
    (let ((table (etaf-runtime-prepared-host-updates runtime))
          (queue (etaf-runtime-dirty-effect-queue runtime))
          (primitive-p t))
      (while (and queue primitive-p)
        (unless (gethash (pop queue) table) (setq primitive-p nil)))
      primitive-p)))

(defun etaf--runtime-source-effect-shadowed-p
    (runtime generation effect ids single-p)
  "Whether pending structural work can retire EFFECT before its next read.
Use only EFFECT's retained parent chain.  A lone local target has no queued
structural peer, so ordinary prepared Host work needs no ancestor lookup."
  (or (and (etaf-runtime-root-dirty-p runtime)
           (not (eq (etaf--generation-effect-kind effect) 'root)))
      (and (not single-p)
           (let* ((effect-id (etaf--generation-effect-effect-id effect))
                  (id (etaf--generation-effect-semantic-id effect))
                  (nodes (etaf-generation-semantic-nodes generation))
                  found)
             (while (and id (not found))
               (let* ((node (etaf--pvec-get nodes id))
                      (owner-effect
                       (cond
                        ((etaf--semantic-component-p node)
                         (etaf--semantic-component-effect-id node))
                        ((etaf--semantic-range-p node)
                         (etaf--semantic-range-effect-id node))
                        ((etaf--semantic-slot-range-p node)
                         (etaf--semantic-slot-range-effect-id node))))
                      (input-effect
                       (and (etaf--semantic-component-p node)
                            (etaf--semantic-component-input-effect-id node))))
                 (setq found
                       (or (and owner-effect (/= owner-effect effect-id)
                                (not (and (eq (etaf--generation-effect-kind effect)
                                              'component-input)
                                          (= id (etaf--generation-effect-semantic-id effect))))
                                (gethash owner-effect ids))
                           (and input-effect (/= input-effect effect-id)
                                (gethash input-effect ids))))
                 (setq id (etaf--generation-parent-id generation id))))
             found))))

(defun etaf--runtime-pop-effect (runtime)
  "Pop and return RUNTIME's next dirty effect id."
  (let ((effect-id (pop (etaf-runtime-dirty-effect-queue runtime))))
    (unless (etaf-runtime-dirty-effect-queue runtime)
      (setf (etaf-runtime-dirty-effect-queue-tail runtime) nil))
    effect-id))

(defun etaf--runtime-clear-dirty-effects (runtime)
  "Clear RUNTIME's dirty effect membership and FIFO."
  (clrhash (etaf-runtime-dirty-effect-ids runtime))
  (setf (etaf-runtime-dirty-effect-queue runtime) nil
        (etaf-runtime-dirty-effect-queue-tail runtime) nil))

(defun etaf--runtime-mark-root-dirty (runtime)
  "Mark RUNTIME for an exact Root-owned rebuild."
  (setf (etaf-runtime-root-dirty-p runtime) t))

(defun etaf--runtime-effect-priority (effect)
  "Return fixed scheduling priority for generation EFFECT."
  (pcase (etaf--generation-effect-kind effect)
    ('root 0)
    ('component-input 1)
    ((or 'range 'fragment 'slot 'inline) 2)
    (_ 3)))

(defun etaf--runtime-sort-dirty-effects (generation effect-ids)
  "Order EFFECT-IDS after their queued semantic ancestors in GENERATION.
Use stable priority/id order among otherwise independent owners.  A
conditional Range must decide child lifetime before that child's input or
render effect can stage work; staged work alone is not proof of attachment."
  (let ((owners (make-hash-table :test #'eql))
        (visited (make-hash-table :test #'eql))
        entries result)
    (dolist (effect-id effect-ids)
      (let ((effect (etaf--generation-effect generation effect-id)))
        (push (list (etaf--runtime-effect-priority effect) effect-id
                    (etaf--generation-effect-semantic-id effect)) entries)))
    (setq entries
          (sort entries (lambda (left right)
                          (if (= (car left) (car right))
                              (< (cadr left) (cadr right))
                            (< (car left) (car right))))))
    (dolist (entry (reverse entries))
      (push (cadr entry) (gethash (nth 2 entry) owners)))
    (cl-labels
        ((visit-owner
          (semantic-id)
          (unless (gethash semantic-id visited)
            (puthash semantic-id t visited)
            (when-let* ((parent-id (etaf--generation-parent-id generation semantic-id)))
              (visit-owner parent-id))
            (dolist (effect-id (gethash semantic-id owners))
              (push effect-id result)))))
      (dolist (entry entries) (visit-owner (nth 2 entry))))
    (nreverse result)))

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
                  (etaf--semantic-component-input-attrs semantic)
                  (etaf--semantic-component-input-slots semantic)
                  (etaf--semantic-component-context-deps semantic)
                  (etaf--semantic-component-output-signature semantic)))
           ((etaf--semantic-host-p semantic)
            (list (etaf--semantic-host-composition-version semantic)
                  (etaf--semantic-host-props-signature semantic)
                  (etaf--semantic-host-context-deps semantic)))
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

(defun etaf--runtime-authorized-route-runtime (route)
  "Return the live Runtime authorized by opaque ROUTE, or nil."
  (when (and (etaf-runtime-route-p route)
             (etaf-runtime-route-active-p route))
    (when-let* ((runtime
                 (gethash (etaf-runtime-route-mount-epoch route)
                          etaf--runtime-route-registry)))
      (and (eq route (etaf-runtime-route-token runtime))
           (eq (etaf-runtime-route-scheduler-context route)
               (etaf-runtime-scheduler-context runtime))
           (etaf-runtime-mounted-p runtime)
           (etaf-host-authority-accepts-token-p
            (etaf-runtime-host-authority runtime)
            (etaf-runtime-route-authority-token route))
           runtime))))

(defun etaf--runtime-route-scheduler (route source)
  "Route dirty SOURCE through opaque ROUTE to its current generation."
  (when-let* ((runtime (etaf--runtime-authorized-route-runtime route)))
      (dolist (effect-id
               (etaf--generation-source-effects
                (etaf-runtime-current-generation runtime) source))
        (when (etaf--generation-effect
               (etaf-runtime-current-generation runtime) effect-id)
          (etaf--runtime-enqueue-effect runtime effect-id t)
          (when (equal effect-id (etaf-runtime-root-effect-id runtime))
            (etaf--runtime-mark-root-dirty runtime))))
      (etaf-reactive-enqueue-runtime-flush
       (etaf-runtime-mount-epoch runtime)
       (etaf-runtime-flush-function runtime)
       (etaf-runtime-scheduler-context runtime))))

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

(defun etaf--runtime-forward-ebox-report (_buffer report)
  "Forward Ebox publication or renderer REPORT into the active operation."
  (etaf-observer-emit report))

(defun etaf--runtime-record-observer-diagnostic (runtime diagnostic)
  "Record contained observer DIAGNOSTIC on RUNTIME."
  (push (append (list :phase 'observer) (copy-tree diagnostic))
        (etaf-runtime-diagnostics runtime))
  nil)

(defcustom etaf-retirement-journal-limit 64
  "Maximum completed retirement journals retained by one Runtime."
  :type 'positive-integer
  :group 'etaf)

(defun etaf--runtime-new-retirement-journal (runtime outcome-id)
  "Create RUNTIME retirement journal correlated with committed OUTCOME-ID."
  (etaf-retirement-journal-create
   :operation-id
   (if etaf--observer-context
       (etaf--observer-context-operation-id etaf--observer-context)
     (or (etaf-runtime-next-operation-id runtime) 0))
   :outcome-id outcome-id
   :generation-id (etaf-runtime-generation runtime)
   :revision (etaf-render-port-revision (etaf-runtime-buffer runtime))))

(defun etaf--runtime-run-postcommit-step (journal owner kind function)
  "Run FUNCTION after commit, recording its condition in JOURNAL.
OWNER and KIND identify the step.  Return the original condition, or nil."
  (condition-case condition
      (progn (funcall function) nil)
    ((error quit)
     (etaf-retirement-record-contained-failure
      journal owner kind condition))))

(defun etaf--runtime-retain-retirement-journal (runtime journal)
  "Retain completed JOURNAL and its diagnostics on RUNTIME."
  (push journal (etaf-runtime-retirement-journals runtime))
  (when (> (length (etaf-runtime-retirement-journals runtime))
           (max 1 etaf-retirement-journal-limit))
    (setcdr (nthcdr (1- (max 1 etaf-retirement-journal-limit))
                    (etaf-runtime-retirement-journals runtime))
            nil))
  (dolist (diagnostic (etaf-retirement-journal-diagnostics journal))
    (push (append (list :phase 'retirement
                        :diagnostic-journal-id
                        (etaf-retirement-journal-id journal))
                  (copy-tree diagnostic))
          (etaf-runtime-diagnostics runtime)))
  journal)

(defun etaf--runtime-drain-retirement (runtime journal &optional contained-p)
  "Drain RUNTIME JOURNAL and re-signal public failure unless CONTAINED-P."
  (let ((condition (etaf-retirement-drain journal)))
    (etaf--runtime-retain-retirement-journal runtime journal)
    (when (and condition (not contained-p))
      (etaf-retirement-resignal condition journal))
    condition))

(defun etaf-runtime-call-operation (runtime kind label function)
  "Call FUNCTION as one observed RUNTIME operation.
KIND is a stable symbol and LABEL is a user-facing string.  Nested calls for
the same Runtime reuse the active operation.  Calls for another Runtime own a
separate operation.  Return FUNCTION's exact result and re-signal its exact
error or quit."
  (unless (and (etaf-runtime-p runtime)
               (etaf-runtime-mounted-p runtime))
    (signal 'etaf-runtime-error (list "ETAF runtime is not mounted")))
  (unless (and (symbolp kind) kind)
    (signal 'wrong-type-argument (list 'symbolp kind)))
  (unless (stringp label)
    (signal 'wrong-type-argument (list 'stringp label)))
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (let* ((runtime-id (etaf-runtime-mount-epoch runtime))
         (current etaf--observer-context)
         (same-runtime
          (and current
               (= runtime-id
                  (etaf--observer-context-runtime-id current))))
         (observer (etaf-runtime-observer runtime)))
    (cond
     (same-runtime
      (funcall function))
     ((null observer)
      ;; A different Runtime must not leak provider reports into the outer
      ;; operation merely because its own observer is disabled.
      (let ((etaf--observer-context nil))
        (funcall function)))
     (t
      (let* ((operation-id
              (1+ (or (etaf-runtime-next-operation-id runtime) 0)))
             (generation-before (etaf-runtime-generation runtime))
             (scheduler-context
              (or (etaf-runtime-scheduler-context runtime)
                  etaf-scheduler-default-context))
             (scheduler-before
              (etaf-scheduler-context-metrics scheduler-context))
             (started (float-time))
             (gc-count-before gcs-done)
             (gc-elapsed-before gc-elapsed)
             (status 'error)
             (context
              (etaf--observer-context-create
               :sink observer
               :operation-id operation-id
               :runtime-id runtime-id
               :buffer-name (buffer-name (etaf-runtime-buffer runtime))
               :diagnostic
               (lambda (diagnostic)
                 (etaf--runtime-record-observer-diagnostic
                  runtime diagnostic))))
             projection-summaries
             result)
        (setf (etaf-runtime-next-operation-id runtime) operation-id)
        (cl-labels
            ((run-body
              ()
              (etaf--observer-call-with-context
               context
               (lambda ()
                 (condition-case condition
                     (prog1 (setq result (funcall function))
                       (setq status 'success))
                   (quit
                    (setq status 'quit)
                    (signal (car condition) (cdr condition)))))))
             (emit-final
              (summaries)
              (let ((scheduler-after
                     (etaf-scheduler-context-metrics scheduler-context)))
                (etaf--observer-call-with-context
                 context
                 (lambda ()
                   (etaf-observer-emit
                    (list
                     :provider 'etaf
                     :stage 'runtime-operation
                     :kind kind
                     :label (copy-sequence label)
                     :generation-before generation-before
                     :generation-after (etaf-runtime-generation runtime)
                     :status status
                     :scheduler-context-id
                     (plist-get scheduler-after :context-id)
                     :scheduler-projection-epoch-before
                     (plist-get scheduler-before :projection-epoch)
                     :scheduler-projection-epoch-after
                     (plist-get scheduler-after :projection-epoch)
                     :scheduler-turns
                     (- (plist-get scheduler-after :turn-count)
                        (plist-get scheduler-before :turn-count))
                     :scheduler-source-enqueues
                     (- (plist-get scheduler-after :source-enqueues)
                        (plist-get scheduler-before :source-enqueues))
                     :scheduler-source-dedupes
                     (- (plist-get scheduler-after :source-dedupes)
                        (plist-get scheduler-before :source-dedupes))
                     :scheduler-source-deliveries
                     (- (plist-get scheduler-after :source-deliveries)
                        (plist-get scheduler-before :source-deliveries))
                     :scheduler-subscriber-visits
                     (- (plist-get scheduler-after :subscriber-visits)
                        (plist-get scheduler-before :subscriber-visits))
                     :scheduler-effect-claims
                     (- (plist-get scheduler-after :effect-claims)
                        (plist-get scheduler-before :effect-claims))
                     :scheduler-effect-evaluations
                     (- (plist-get scheduler-after :effect-evaluations)
                        (plist-get scheduler-before :effect-evaluations))
                     :scheduler-runtime-enqueues
                     (- (plist-get scheduler-after :runtime-enqueues)
                        (plist-get scheduler-before :runtime-enqueues))
                     :scheduler-runtime-dedupes
                     (- (plist-get scheduler-after :runtime-dedupes)
                        (plist-get scheduler-before :runtime-dedupes))
                     :scheduler-runtime-executions
                     (- (plist-get scheduler-after :runtime-executions)
                        (plist-get scheduler-before :runtime-executions))
                     :scheduler-stale-route-drops
                     (- (plist-get scheduler-after :stale-route-drops)
                        (plist-get scheduler-before :stale-route-drops))
                     :scheduler-faults
                     (- (plist-get scheduler-after :fault-count)
                        (plist-get scheduler-before :fault-count))
                     :scheduler-projections (copy-tree summaries)
                     :scheduler-fault-state
                     (plist-get scheduler-after :fault-state)
                     :duration-ms
                     (max 0.0 (* 1000.0 (- (float-time) started)))
                     :gc-count (- gcs-done gc-count-before)
                     :gc-duration-ms
                     (max 0.0
                          (* 1000.0
                             (- gc-elapsed gc-elapsed-before))))))))))
          (if (etaf-scheduler-projection-active-p)
              (unwind-protect
                  (run-body)
                (etaf-scheduler-on-projection-complete
                 (lambda (summary) (emit-final (list summary)))))
            (let ((etaf-scheduler-projection-observer
                   (lambda (summary)
                     (push summary projection-summaries))))
              (unwind-protect
                  (run-body)
                (emit-final (nreverse projection-summaries)))))
          result))))))

(cl-defmacro etaf--runtime-with-operation ((runtime kind label) &rest body)
  "Evaluate BODY in RUNTIME operation KIND and LABEL when observed."
  (declare (indent 1) (debug ((form form form) body)))
  (let ((runtime-value (make-symbol "runtime")))
    `(let ((,runtime-value ,runtime))
       (if (and (null etaf--observer-context)
                (null (etaf-runtime-observer ,runtime-value)))
           (progn ,@body)
         (etaf-runtime-call-operation
          ,runtime-value ,kind ,label (lambda () ,@body))))))

(defun etaf-runtime-event-begin (runtime)
  "Enter one logical event batch for mounted RUNTIME."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (cl-incf (etaf-runtime-event-depth runtime))
  (etaf-scheduler-context-event-begin
   (etaf-runtime-scheduler-context runtime))
  runtime)

(defun etaf-runtime-event-end (runtime)
  "Leave RUNTIME's logical event batch and publish pending state once."
  (when (etaf-runtime-p runtime)
    (setf (etaf-runtime-event-depth runtime)
          (max 0 (1- (etaf-runtime-event-depth runtime))))
    (etaf-scheduler-context-event-end
     (etaf-runtime-scheduler-context runtime))
    (when (and (etaf-runtime-mounted-p runtime)
               (zerop (etaf-runtime-event-depth runtime))
               (etaf-runtime-pending-p runtime))
      (setf (etaf-runtime-pending-p runtime) nil)
      (etaf--runtime-request-flush runtime)))
  runtime)

(defun etaf-runtime-for-buffer (buffer-or-name)
  "Return the live Runtime mounted in BUFFER-OR-NAME, or nil."
  (let* ((buffer (get-buffer buffer-or-name))
         (runtime (and buffer (gethash buffer etaf--runtime-table))))
    (and runtime
         (etaf-runtime-mounted-p runtime)
         (etaf-host-authority-attached-p
          (etaf-runtime-host-authority runtime))
         runtime)))

(defun etaf-runtime-require-mounted (&optional runtime)
  "Return mounted RUNTIME or the Runtime in the current buffer.

Signal an ETAF runtime error before any downstream action or renderer lookup
when the requested boundary is no longer mounted."
  (let ((runtime (or runtime etaf--current-runtime
                     (and (buffer-live-p (current-buffer))
                          (gethash (current-buffer) etaf--runtime-table)))))
    (unless (and (etaf-runtime-p runtime)
                 (etaf-runtime-mounted-p runtime)
                 (etaf-host-authority-attached-p
                  (etaf-runtime-host-authority runtime)))
      (signal 'etaf-runtime-error
              (list "ETAF runtime is not mounted")))
    runtime))

;;;###autoload
(defun etaf-runtime-set-observer (runtime observer-or-nil)
  "Set mounted RUNTIME's observer to OBSERVER-OR-NIL and return it.
The observer receives one immutable flat report argument.  Nil detaches the
Runtime from its Ebox surface.  Replacing observation during an active
operation is rejected so the operation keeps one stable sink."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (or (null observer-or-nil) (functionp observer-or-nil))
    (signal 'wrong-type-argument (list 'functionp observer-or-nil)))
  (unless (eq observer-or-nil (etaf-runtime-observer runtime))
    (when (and etaf--observer-context
               (= (etaf-runtime-mount-epoch runtime)
                  (etaf--observer-context-runtime-id
                   etaf--observer-context)))
      (error "ETAF observer cannot change during an active operation"))
    (ebox-buffer-set-observer
     (etaf-runtime-buffer runtime)
     (and observer-or-nil #'etaf--runtime-forward-ebox-report))
    (setf (etaf-runtime-observer runtime) observer-or-nil))
  observer-or-nil)

;;;###autoload
(defun etaf-runtime-compare-and-set-observer (runtime expected replacement)
  "Replace RUNTIME observer EXPECTED with REPLACEMENT atomically.

EXPECTED and REPLACEMENT are functions or nil.  Return non-nil only when the
current observer is `eq' to EXPECTED; in that case REPLACEMENT is installed
through the ordinary observer boundary.  A mismatch leaves the Runtime
untouched.  This lets optional consumers detach only the sink they own without
reading Runtime storage fields."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (dolist (observer (list expected replacement))
    (unless (or (null observer) (functionp observer))
      (signal 'wrong-type-argument (list 'functionp observer))))
  (when (eq expected (etaf-runtime-observer runtime))
    (etaf-runtime-set-observer runtime replacement)
    t))

(defun etaf--runtime-snapshot-computed (runtime computed)
  "Record COMPUTED before RUNTIME candidate changes its cache or dependencies."
  (when-let* ((journal (etaf-runtime-candidate-computed-snapshots runtime))
              (changes (etaf-runtime-candidate-prop-values runtime))
              ((> (hash-table-count changes) 0)))
    (unless (gethash computed journal)
      (puthash computed
               (list (copy-sequence computed)
                     (copy-sequence (etaf-effect-deps (etaf-computed-effect computed))))
               journal))))

(defun etaf--runtime-restore-computeds (runtime)
  "Restore property-dependent cache edges after rejecting RUNTIME input."
  (when-let* ((journal (etaf-runtime-candidate-computed-snapshots runtime)))
    (let ((affected (make-hash-table :test #'eq))
          (changes (etaf-runtime-candidate-prop-values runtime))
          restore)
      (cl-labels
          ((depends
            (source)
            (or (and changes (gethash source changes))
                (eq (gethash source affected) 'yes)
                (and (etaf-computed-p source)
                     (not (gethash source affected))
                     (progn
                       (puthash source 'visiting affected)
                       (let ((result
                              (or (and changes
                                       (not (eq (gethash source changes :missing) :missing)))
                                  (cl-some #'depends
                                           (append
                                            (cadr (gethash source journal))
                                            (etaf-effect-deps (etaf-computed-effect source)))))))
                         (puthash source (if result 'yes 'no) affected)
                         result))))))
        (maphash (lambda (computed entry)
                   (when (depends computed) (push (cons computed entry) restore))) journal))
      (dolist (item restore)
        (let* ((computed (car item)) (entry (cdr item))
               (old (car entry)) (effect (etaf-computed-effect computed)))
          (when (etaf-effect-active-p effect)
            (etaf--clear-effect-deps effect)
            (dolist (source (cadr entry))
              (puthash effect t (etaf--source-subscribers source)))
            (setf (etaf-effect-deps effect) (cadr entry)))
          (setf (etaf-computed-value computed) (etaf-computed-value old)
                (etaf-computed-version computed) (etaf-computed-version old)
                ;; Business refs are live even when display publication fails.
                ;; Recompute against committed props and those live refs.
                (etaf-computed-dirty-p computed) t
                (etaf-computed-evaluated-p computed) (etaf-computed-evaluated-p old)))))))

(defun etaf--runtime-stage-prop-inputs (runtime instance old-props props)
  "Invalidate INSTANCE property sources for candidate PROPS against OLD-PROPS."
  (let ((generation (etaf-runtime-current-generation runtime))
        (seen (make-hash-table :test #'eq)))
    (cl-labels
        ((invalidate
          (source)
          (unless (gethash source seen)
            (puthash source t seen)
            (etaf--runtime-snapshot-computed runtime source)
            (setf (etaf-computed-dirty-p source) t)
            (when generation
              (dolist (effect-id (etaf--generation-source-effects generation source))
                (etaf--runtime-enqueue-effect runtime effect-id)
                ;; Root renders need to enter retained descendant components
                ;; before their invalidated leaf expressions can be rebuilt.
                (let* ((effect (etaf--generation-effect generation effect-id))
                       (id (and effect (etaf--generation-effect-semantic-id effect))))
                  (while id
                    (let ((node (etaf--pvec-get
                                 (etaf-generation-semantic-nodes generation) id)))
                      (when (and (etaf--semantic-component-p node)
                                 (not (equal (etaf--semantic-component-identity node)
                                             (etaf--component-instance-identity instance))))
                        (etaf--runtime-enqueue-effect
                         runtime (etaf--semantic-component-effect-id node))))
                    (setq id (etaf--generation-parent-id generation id))))))
            (maphash
             (lambda (subscriber _)
               (when (and (etaf-effect-p subscriber)
                          (etaf-effect-active-p subscriber)
                          (etaf-effect-output-source subscriber))
                 (invalidate (etaf-effect-output-source subscriber))))
             (etaf--source-subscribers source)))))
      (dolist (entry (etaf--component-instance-prop-sources instance))
        (let* ((key (car entry)) (source (cdr entry))
               (missing (make-symbol "missing"))
               (last (gethash source (etaf-runtime-candidate-prop-values runtime) missing))
               (before (if (eq last missing) (plist-get old-props key) (cdr last)))
               (next (plist-get props key)))
          (unless (etaf--reactive-same-p before next)
            (puthash source (cons instance next) (etaf-runtime-candidate-prop-values runtime))
            (invalidate source)))))))

(defun etaf--runtime-props-equal-p (left right)
  "Compare input plists LEFT and RIGHT using the reactive shallow value rule.
The property containers are snapshots; application objects remain identities."
  (while (and left right
              (eq (car left) (car right))
              (etaf--reactive-same-p (cadr left) (cadr right)))
    (setq left (cddr left) right (cddr right)))
  (and (null left) (null right)))

(defun etaf--runtime-accept-prop-inputs (runtime)
  "Accept RUNTIME computed caches and notify property watchers after publication."
  (let ((sources (etaf-runtime-candidate-prop-values runtime)))
    (setf (etaf-runtime-candidate-computed-snapshots runtime) nil
          (etaf-runtime-candidate-prop-values runtime) nil)
    (when sources
      (maphash
       (lambda (source change)
         (let* ((instance (car change))
                (semantic (etaf--generation-semantic
                           (etaf-runtime-current-generation runtime)
                           (etaf--component-instance-identity instance))))
           (when (and semantic
                      (equal (etaf--semantic-component-resource-key semantic)
                             (etaf--component-instance-resource-key instance))
                      (etaf-effect-active-p (etaf-computed-effect source)))
             (etaf--dispatch-source source))))
       sources))))

;;;###autoload
(defun etaf-local-ref (name)
  "Return an instance-local Host reference named NAME during Component setup.
NAME must be a non-nil symbol or a string.  Equal names in one retained
instance return the same opaque reference; different instances never share
it.  Pass the result to a Host's :ref property and existing Host query,
focus or event APIs.  Expose it to callers explicitly through props or a
callback when needed.  It does not store state or replace a list key.
The reference resolves only while its Host is successfully mounted.  Failed
candidates do not change its committed target; removing the Host makes
position and bounds queries return nil.  Remounting a disposed Component
creates a new reference even when its list key is reused."
  (unless (and (eq etaf--component-phase 'setup)
               etaf--current-component-instance etaf--current-runtime)
    (etaf--component-definition-error "etaf-local-ref requires Component setup"))
  (unless (and name (or (symbolp name) (stringp name)))
    (etaf--component-definition-error
     "Local reference name must be a non-nil symbol or string: %S" name))
  (let* ((instance etaf--current-component-instance)
         (existing (assoc name (etaf--component-instance-local-refs instance))))
    (or (cdr existing)
        (let ((ref (make-symbol (format "etaf-local-%s" name))))
          (push (cons (if (stringp name) (copy-sequence name) name) ref)
                (etaf--component-instance-local-refs instance))
          ref))))

;;;###autoload
(defun etaf-prop (name)
  "Return the current Component's stable read-only reactive input NAME.
Call during setup, then read the returned source with `etaf-value' inside
computed getters or watchers.  NAME must identify a declared prop; keywords
and ordinary symbols are accepted.  Defaults are included.  A plain prop
variable remains an evaluation snapshot, while this source follows inputs.
Candidate rendering sees candidate inputs; watchers are notified only after
successful publication.  Rejected publication restores derived caches.
The Component owns this source; reads after disposal signal an error."
  (unless (and (eq etaf--component-phase 'setup)
               etaf--current-component-instance etaf--current-runtime)
    (etaf--component-definition-error "etaf-prop requires Component setup"))
  (let* ((instance etaf--current-component-instance)
         (runtime etaf--current-runtime)
         (id etaf--current-component-semantic-id)
         (key (and (symbolp name) (etaf--component-prop-key name)))
         (declared (mapcar #'etaf--component-prop-key
                          (etaf--component-spec-props
                           (etaf--component-instance-spec instance)))))
    (unless (memq key declared)
      (etaf--component-definition-error "Component %S has no declared prop %S"
                                       (car (etaf--component-instance-identity instance)) name))
    (or (cdr (assq key (etaf--component-instance-prop-sources instance)))
        (let* ((validate
                (lambda ()
                  (let* ((generation (etaf-runtime-current-generation runtime))
                         (committed (and generation
                                         (etaf--pvec-get
                                          (etaf-generation-semantic-nodes generation) id)))
                         (env (and (or etaf--render-phase-p
                                       (eq etaf--component-phase 'setup))
                                   (etaf-runtime-candidate-component-envs runtime)
                                   (gethash id (etaf-runtime-candidate-component-envs runtime)))))
                    (unless (and (etaf-effect-scope-active-p
                                  (etaf--component-instance-scope instance))
                                 (or (eq instance (plist-get env :instance))
                                     (and committed
                                          (equal (etaf--component-instance-resource-key instance)
                                                 (etaf--semantic-component-resource-key committed)))))
                      (etaf--component-definition-error "Component prop %S is disposed" name)))))
               (source
                (etaf-computed
                 (lambda ()
                   (funcall validate)
                   (let* ((candidate-p
                           (or etaf--render-phase-p
                               (and (eq etaf--component-phase 'setup)
                                    (eq etaf--current-component-instance instance))))
                          (env (and candidate-p
                                    (etaf-runtime-candidate-component-envs runtime)
                                    (gethash id (etaf-runtime-candidate-component-envs runtime))))
                          (generation (etaf-runtime-current-generation runtime))
                          (component (and generation
                                          (etaf--pvec-get
                                           (etaf-generation-semantic-nodes generation) id))))
                     (plist-get (if (plist-member env :props)
                                    (plist-get env :props)
                                  (and component (etaf--semantic-component-props component))) key)))
                 :name (list 'prop name))))
          (setf (etaf-computed-validator source) validate)
          (push (cons key source) (etaf--component-instance-prop-sources instance))
          source))))

(defun etaf--runtime-watch-scheduler (runtime job _flush)
  "Run watcher JOB while RUNTIME remains mounted."
  (when (etaf-runtime-mounted-p runtime)
    (funcall job)))

(defun etaf--runtime-call-with-component-env (runtime component-id function)
  "Call FUNCTION in RUNTIME candidate/committed COMPONENT-ID environment."
  (let* ((generation (etaf-runtime-current-generation runtime))
         (env (and component-id
                   (etaf-runtime-candidate-component-envs runtime)
                   (gethash component-id
                            (etaf-runtime-candidate-component-envs runtime))))
         (base (and component-id generation
                    (etaf--pvec-get (etaf-generation-semantic-nodes generation)
                                    component-id)))
         (component
          (and base
               (or (and (etaf-runtime-candidate-semantic-nodes runtime)
                        (gethash (etaf--semantic-component-identity base)
                                 (etaf-runtime-candidate-semantic-nodes runtime)))
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
          (if (plist-member env :props)
              (plist-get env :props)
            (and component (etaf--semantic-component-props component))))
         (slots
          (if (plist-member env :slots)
              (plist-get env :slots)
            (and component (etaf--semantic-component-slots component)))))
    (if (null component-id)
        (let ((etaf--current-runtime runtime)
              (etaf--current-component-instance nil)
              (etaf--current-component-identity nil)
              (etaf--current-component-semantic-id nil)
              (etaf--current-component-props nil)
              (etaf--current-component-slots nil)
              (etaf--current-context nil))
          (funcall function))
      (let ((etaf--current-runtime runtime)
            (etaf--current-component-instance instance)
            (etaf--current-component-state
             (and instance (etaf--component-instance-state instance)))
            (etaf--current-component-setup-defined-p
             (and instance
                  (not (null (etaf--component-spec-setup
                              (etaf--component-instance-spec instance))))))
            (etaf--current-component-setup-complete-p
             (and instance
                  (etaf--component-instance-setup-complete-p instance)))
            (etaf--component-phase 'render)
            (etaf--current-component-identity identity)
            (etaf--current-component-semantic-id component-id)
            (etaf--current-component-props props)
            (etaf--current-component-slots slots)
            (etaf--current-context
             (or (and component (etaf-runtime-candidate-graph-nodes runtime)
                      (etaf--runtime-context-frame-for-candidate
                       runtime component))
                 (and component (etaf--semantic-component-context-frame component))
                 (etaf--component-instance-context instance))))
        (funcall function)))))

(defun etaf--runtime-component-env-signature (runtime component-id)
  "Return COMPONENT-ID's candidate or committed input signature in RUNTIME."
  (when component-id
    (or (when-let* ((env (gethash component-id
                                 (etaf-runtime-candidate-component-envs runtime))))
          (list (copy-tree (plist-get env :props))
                (copy-tree (plist-get env :attrs))
                (copy-tree (plist-get env :slots))))
        (when-let* ((generation (etaf-runtime-current-generation runtime))
                    (component
                     (etaf--pvec-get (etaf-generation-semantic-nodes generation)
                                     component-id)))
          (list (copy-tree (etaf--semantic-component-props component))
                (copy-tree (etaf--semantic-component-attrs component))
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

(defun etaf--runtime-register-host
    (runtime props path &optional site-token old-semantic)
  "Register PROPS contributions in RUNTIME for one semantic Host at PATH.
SITE-TOKEN supplies its stable author call-site identity when non-nil.
OLD-SEMANTIC supplies the already-read committed Host, when any."
  (let ((host-ref (etaf--generated-host-ref props path site-token))
        (tail props)
        semantic-p
        handlers
        old-semantic-p
        old-handlers-p)
    (while tail
      (let ((key (pop tail))
            (value (pop tail)))
        (when (and value (etaf--semantic-property-p key))
          (setq semantic-p t))
        (when (and (keywordp key)
                   (string-prefix-p ":on-" (symbol-name key))
                   (functionp value))
          (push (cons (etaf--runtime-event-kind key) value) handlers))))
    (when (etaf--semantic-host-p old-semantic)
      (let ((old-props (etaf--semantic-host-base-props old-semantic)))
        (while old-props
          (let ((key (pop old-props))
                (value (pop old-props)))
            (when (and value (etaf--semantic-property-p key))
              (setq old-semantic-p t))
            (when (and (keywordp key)
                       (string-prefix-p ":on-" (symbol-name key))
                       (functionp value))
              (setq old-handlers-p t))))))
    (when (or semantic-p old-semantic-p handlers old-handlers-p)
      ;; A local Component rerender can remove and recreate the same stable
      ;; Host reference.  Re-registration cancels the candidate tombstone;
      ;; otherwise the generation contribution index would hide the new
      ;; handler/property entry behind the old removal.
      (setf (etaf-runtime-candidate-removed-host-refs runtime)
            (delete host-ref
                    (etaf-runtime-candidate-removed-host-refs runtime)))
      (puthash host-ref (and semantic-p props)
               (etaf-runtime-candidate-host-props runtime))
      (cond
       (handlers
        (puthash host-ref handlers
                 (etaf-runtime-candidate-handlers runtime)))
       (old-handlers-p
        ;; A retained Host can keep its identity while losing its callback.
        (puthash host-ref nil
                 (etaf-runtime-candidate-handlers runtime)))))))

(defun etaf--runtime-begin-child-order (runtime semantic-id)
  "Begin replacing SEMANTIC-ID's child order in RUNTIME's candidate.
An ancestor may render a descendant already evaluated earlier in this turn.
Its new output replaces that earlier order, including the append cursor."
  (puthash semantic-id nil (etaf-runtime-candidate-graph-children runtime))
  (remhash semantic-id (etaf-runtime-candidate-graph-child-tails runtime)))

(defun etaf--runtime-candidate-add-child (runtime parent-id child-id)
  "Append CHILD-ID to PARENT-ID's candidate semantic order in RUNTIME."
  (let* ((children (etaf-runtime-candidate-graph-children runtime))
         (tails (etaf-runtime-candidate-graph-child-tails runtime))
         (cell (list child-id))
         (tail (gethash parent-id tails)))
    (if tail
        (setcdr tail cell)
      (puthash parent-id cell children))
    (puthash parent-id cell tails)))

(defun etaf--runtime-range-must-refresh-for-component-input-p (expr)
  "Return non-nil when EXPR's value is coupled to a Component rerender.
Compiler-owned branch/keyed programs and compiled direct Expr callsites may
read the current Component props while they materialize.  Setup-retained
interpolation programs are opaque values and can safely reuse their Range
when only an unrelated parent structure changed."
  (and etaf--rendering-component-effect-p
       (or (memq (and (etaf--expr-p expr) (etaf--expr-kind expr))
                 '(branch keyed-list))
           (and (etaf--expr-p expr)
                (consp (etaf--expr-token expr))
                (eq (car (etaf--expr-token expr)) 'etaf-compiled-site)))))

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

(defun etaf--runtime-host-property-effect-p (property)
  "Return non-nil when PROPERTY can update without changing Host identity."
  (and (keywordp property)
       (or (ebox-style-schema-id property)
           (memq property '(:class :hover-content)))
       (not (memq property '(:key :ref :use)))
       (not (string-prefix-p ":on-" (symbol-name property)))))

(defun etaf--runtime-resolve-host-properties (props)
  "Resolve Host PROPS and extract independently reactive property bindings.
Return `(RESOLVED BINDINGS DEPS CONTEXT-DEPS)'.  Identity, Behavior, and event
properties stay on the enclosing render effect; only Ebox-local properties
receive an independent Host effect."
  (let (resolved bindings deps context-deps)
    (while props
      (let ((property (pop props))
            (expression (pop props)))
        (if (and (etaf--expr-p expression)
                 (etaf--runtime-host-property-effect-p property))
            (let ((outer-context-recorder etaf--context-inject-recorder)
                  local-deps local-context-deps value)
              (let ((etaf--runtime-dependency-collector
                     (lambda (source)
                       (cl-pushnew source local-deps :test #'eq)))
                    (etaf--context-inject-recorder
                     (lambda (frame key)
                       (cl-pushnew (cons (etaf-context-owner-id frame) key)
                                   local-context-deps :test #'equal)
                       ;; Context-sensitive native content retains its
                       ;; enclosing render owner and lifecycle semantics.
                       (when (and (eq property :hover-content) outer-context-recorder)
                         (funcall outer-context-recorder frame key))))
                    (etaf--active-effect nil)
                    (etaf--render-phase-p t))
                (setq value (etaf--resolve-property-value expression)))
              (if (and (eq property :hover-content) local-context-deps)
                  (dolist (source local-deps) (etaf--track-source source))
                (when (or local-deps local-context-deps)
                  (push (etaf--host-property-binding-create
                         :property property :expression expression
                         :dependencies local-deps)
                        bindings)
                  (dolist (source local-deps)
                    (cl-pushnew source deps :test #'eq))
                  (dolist (dependency local-context-deps)
                    (cl-pushnew dependency context-deps :test #'equal))))
              (push property resolved)
              (push value resolved))
          (setq resolved
                (cons (etaf--resolve-property-value expression)
                      (cons property resolved))))))
    (list (nreverse resolved) (nreverse bindings) (nreverse deps)
          (nreverse context-deps))))

(defun etaf--runtime-register-semantic-host
    (runtime name props backend-props path
             &optional theme-deps
             property-bindings property-deps property-context-deps base-props
             site-token style-root-p)
  "Register visual Host NAME at PATH in RUNTIME and return its semantic id."
  (let* ((key (plist-get props :key))
         (identity (if key
                       (list 'host etaf--current-semantic-parent-id :key key)
                     (if site-token
                         (list 'host etaf--current-semantic-parent-id
                               :site site-token)
                       (list 'host etaf--current-semantic-parent-id
                             :position path))))
         (semantic-id (etaf--runtime-semantic-id-for-identity runtime identity))
         (old
          (and (etaf-runtime-current-generation runtime)
               (etaf--pvec-get
                (etaf-generation-semantic-nodes
                 (etaf-runtime-current-generation runtime))
                semantic-id)))
         (_host-contributions
          (etaf--runtime-register-host
           runtime props path site-token old))
         (effect-id
          (and (or theme-deps property-bindings)
               (or (and (etaf--semantic-host-p old)
                        (etaf--semantic-host-effect-id old))
                   (cl-incf (etaf-runtime-next-effect-id runtime)))))
         (record (etaf--semantic-host-create
                  :semantic-id semantic-id :identity identity
                  :parent-id etaf--current-semantic-parent-id
                  :component-id etaf--current-component-semantic-id
                  :host-ref (etaf--generated-host-ref props path site-token)
                  :key key :name name :effect-id effect-id
                  :property-bindings property-bindings
                  :property-deps property-deps
                  :style-root-p style-root-p
                  :deps (delete-dups
                         (append property-deps theme-deps))
                  :context-deps property-context-deps
                  :base-props base-props
                  :resolved-props props
                  :site-token site-token
                  :props-signature backend-props
                  :path path
                  :style-identity etaf--render-style-owners)))
    (etaf--runtime-begin-child-order runtime semantic-id)
    (etaf--runtime-register-host-behaviors runtime record)
    (unless etaf--rendering-range-p
      (puthash identity semantic-id
               (etaf-runtime-candidate-identity-entries runtime)))
    (puthash semantic-id record (etaf-runtime-candidate-graph-nodes runtime))
    (when (and (etaf--semantic-host-p old)
               (etaf--semantic-host-effect-id old)
               (null effect-id))
      (cl-pushnew (etaf--semantic-host-effect-id old)
                  (etaf-runtime-candidate-removed-effect-ids runtime)
                  :test #'eql))
    (when effect-id
      (puthash effect-id
               (etaf--generation-effect-create
                :effect-id effect-id :kind 'host-properties
                :semantic-id semantic-id
                :deps (copy-sequence (etaf--semantic-host-deps record)))
               (etaf-runtime-candidate-effects runtime)))
    (etaf--runtime-candidate-add-child
     runtime etaf--current-semantic-parent-id semantic-id)
    semantic-id))

(defun etaf--runtime-finish-semantic-host
    (runtime semantic-id &optional content content-parts)
  "Seal SEMANTIC-ID Host child order from RUNTIME candidate graph."
  (when-let* ((record (gethash semantic-id
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
  (cl-labels
      ((resolve
        (entry)
        (cond
         ((etaf-behavior-spec-p entry) entry)
         ((and (symbolp entry) (fboundp entry))
          (let ((spec (funcall entry)))
            (unless (etaf-behavior-spec-p spec)
              (signal 'etaf-behavior-error
                      (list (format "Behavior constructor %S returned %S"
                                    entry spec))))
            spec))
         ((symbolp entry)
          (signal 'etaf-behavior-error
                  (list (format "Unknown Behavior constructor: %S" entry))))
         (t
          (signal 'etaf-behavior-error
                  (list (format "Invalid :use entry: %S" entry)))))))
    (let ((specs
           (cond
            ((null value) nil)
            ((or (symbolp value) (etaf-behavior-spec-p value))
             (list (resolve value)))
            ((proper-list-p value) (mapcar #'resolve value))
            (t
             (signal
              'etaf-behavior-error
              (list ":use must be a Behavior symbol, spec, or proper list"))))))
      (let (names)
        (dolist (spec specs)
          (let ((name (etaf-behavior-spec-name spec)))
            (when (memq name names)
              (signal 'etaf-behavior-error
                      (list (format "Duplicate Behavior on one Host: %S"
                                    name))))
            (push name names))))
      specs)))

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

(defun etaf--runtime-install-behavior (runtime spec props)
  "Install Behavior SPEC for RUNTIME with PROPS and return its state."
  (let ((install (etaf-behavior-spec-install spec))
        cleanup)
    (when install
      (let ((etaf--current-behavior-context
             (etaf--behavior-context-create
              :runtime runtime :host-props (copy-sequence props))))
        (setq cleanup (funcall install))))
    (unless (or (null cleanup) (functionp cleanup))
      (signal 'etaf-behavior-error
              (list (format "Behavior %S installer must return cleanup"
                            (etaf-behavior-spec-name spec)))))
    (cons spec cleanup)))

(defun etaf--runtime-behavior-node (runtime node path)
  "Resolve NODE's `:use' properties before Host registration in RUNTIME at PATH.
Installers run only after semantic Host identity and final props are known."
  (ignore runtime path)
  (if (not (plist-member (etaf--view-node-props node) :use))
      node
    (cl-flet ((resolve-semantics
                (properties)
                (cl-loop for (key value) on properties by #'cddr
                         append
                         (list key
                               (if (etaf--runtime-host-property-effect-p key)
                                   value
                                 (etaf--resolve-property-value value))))))
      (let* ((props (resolve-semantics
                     (etaf--view-node-props node)))
             (specs (etaf--runtime-behavior-specs (plist-get props :use)))
             (merged (copy-sequence props)))
        ;; Retain resolved specifications as the Host's semantic input.  Later
        ;; retirement can compare their names without calling constructors again.
        (setq merged (plist-put merged :use specs))
        ;; Resolve semantic input before any installer can observe it.  Keep
        ;; Ebox/class expressions for ordinary Host property binding extraction.
        ;; In particular a later Behavior can disable an earlier one, and an
        ;; invalid property must fail without acquiring candidate resources.
        (dolist (spec specs)
          (let ((attributes (resolve-semantics
                             (etaf-behavior-spec-attributes spec))))
            (etaf--validate-semantic-properties attributes)
            (while attributes
              (let ((key (pop attributes)) (value (pop attributes)))
                (cond
                 ((or (etaf--event-property-p key) (eq key :disabled)
                      (etaf--owned-semantic-property-p key))
                  (setq merged
                        (etaf--merge-host-attrs
                         merged (list key value) (etaf--view-node-name node)
                         (etaf-behavior-spec-name spec))))
                 ((not (plist-member merged key))
                  (setq merged (append merged (list key value)))))))))
        (etaf--validate-semantic-properties merged)
        (etaf--view-node-create
         :name (etaf--view-node-name node)
         :token (etaf--view-node-token node)
         :props merged
         :children (etaf--view-node-children node))))))

(defun etaf--runtime-drop-candidate-behavior (runtime identity)
  "Remove RUNTIME candidate Behavior IDENTITY, disposing only provisional state."
  (let ((state (gethash identity (etaf-runtime-candidate-behaviors runtime)))
        (key (gethash identity
                      (etaf-runtime-candidate-behavior-resource-keys runtime))))
    (unless (eq state (gethash identity (etaf-runtime-behaviors runtime)))
      (when-let* ((cleanup (cdr state)))
        (etaf--runtime-run-contained-cleanup
         runtime 'behavior-rollback identity cleanup))
      (when key (remhash key (etaf-runtime-resource-registry runtime))))
    (remhash identity (etaf-runtime-candidate-behaviors runtime))
    (remhash identity (etaf-runtime-candidate-behavior-resource-keys runtime))))

(defun etaf--runtime-register-host-behaviors (runtime host)
  "Stage RUNTIME Behavior resources owned by registered semantic HOST.
The existing semantic id, not the current display path or ref, owns lifetime.
Installers receive final Host props including the effective public reference."
  (when-let* ((specs (plist-get (etaf--semantic-host-resolved-props host) :use)))
   (let* ((id (etaf--semantic-host-semantic-id host))
         (props (etaf--semantic-host-resolved-props host))
         (ref (etaf--semantic-host-host-ref host))
         (generation (etaf-runtime-current-generation runtime))
         (old-host (and generation
                        (etaf--pvec-get
                         (etaf-generation-semantic-nodes generation) id)))
         (candidate-host
          (gethash id (etaf-runtime-candidate-graph-nodes runtime))))
    (dolist (spec specs)
      (let* ((identity (list id (etaf-behavior-spec-name spec)))
             (old (gethash identity (etaf-runtime-behaviors runtime)))
             (candidate (gethash identity
                                 (etaf-runtime-candidate-behaviors runtime)))
             (source-host (if (eq candidate old) old-host candidate-host)))
        (if (plist-get props :disabled)
            (etaf--runtime-drop-candidate-behavior runtime identity)
          (let* ((state
                  (cond
                   ((and candidate (etaf--semantic-host-p source-host)
                         (equal ref (etaf--semantic-host-host-ref source-host))
                         (etaf--runtime-behavior-spec-equal-p (car candidate) spec))
                    candidate)
                   ((and old (etaf--semantic-host-p old-host)
                         (equal ref (etaf--semantic-host-host-ref old-host))
                         (etaf--runtime-behavior-spec-equal-p (car old) spec)) old)
                   (t (etaf--runtime-install-behavior
                       runtime spec (etaf--plist-set props :ref ref)))))
                 (key
                  (cond
                   ((and candidate (eq state candidate))
                    (gethash identity
                             (etaf-runtime-candidate-behavior-resource-keys runtime)))
                   ((and old (eq state old))
                    (gethash identity (etaf-runtime-behavior-resource-keys runtime)))
                   (t (cons (etaf-runtime-mount-epoch runtime)
                            (cl-incf (etaf-runtime-next-resource-id runtime)))))))
            (unless (eq state candidate)
              (etaf--runtime-drop-candidate-behavior runtime identity))
            (puthash identity state (etaf-runtime-candidate-behaviors runtime))
            (puthash identity key
                     (etaf-runtime-candidate-behavior-resource-keys runtime)))))))))

(defun etaf--runtime-prune-candidate-behaviors (runtime _generation)
  "Drop Behaviors absent from RUNTIME's changed Hosts over GENERATION.
Only changed or removed Host ids constrain the candidate map; unaffected
subtrees keep their committed resources without being traversed."
  (let ((uses (make-hash-table :test #'equal))
        (missing (make-symbol "etaf-unchanged-behavior-host"))
        (nodes (etaf-runtime-candidate-graph-nodes runtime)))
    (dolist (id (etaf-runtime-candidate-removed-semantic-ids runtime))
      (puthash id nil uses))
    (maphash
     (lambda (_id node)
       (when (etaf--semantic-host-p node)
         (puthash (etaf--semantic-host-semantic-id node)
                  (mapcar #'etaf-behavior-spec-name
                          (plist-get (etaf--semantic-host-base-props node) :use))
                  uses)))
     nodes)
    (maphash
     (lambda (identity _state)
       (let ((names (gethash (car identity) uses missing)))
         (when (and (not (eq names missing))
                    (not (memq (cadr identity) names)))
           (etaf--runtime-drop-candidate-behavior runtime identity))))
     (etaf-runtime-candidate-behaviors runtime))))

(defun etaf--runtime-promote-behaviors (runtime retirement-journal)
  "Publish RUNTIME Behaviors and enqueue cleanup in RETIREMENT-JOURNAL."
  (let ((old-resources (or (etaf-runtime-behavior-resource-keys runtime)
                           (make-hash-table :test #'equal)))
        (candidate-resources
         (or (etaf-runtime-candidate-behavior-resource-keys runtime)
             (make-hash-table :test #'equal))))
    (cl-loop for entry in (sort (let (entries)
                           (maphash (lambda (key value)
                                      (push (cons key value) entries))
                                    (etaf-runtime-behaviors runtime))
                           entries)
                         (lambda (left right)
                           (string< (prin1-to-string (car left))
                                    (prin1-to-string (car right)))))
             for index from 0
             do
      (let* ((identity (car entry)) (old (cdr entry))
             (candidate (gethash identity
                                 (etaf-runtime-candidate-behaviors runtime)))
             (old-key (gethash identity old-resources))
             (candidate-key (gethash identity candidate-resources)))
        (unless (and candidate (eq candidate old))
          (when old-key
            (remhash old-key (etaf-runtime-resource-registry runtime)))
          (when-let* ((cleanup (cdr old)))
            (if retirement-journal
                (let ((callback cleanup))
                  (etaf-retirement-enqueue
                   retirement-journal
                   :owner (copy-tree identity)
                   :kind 'behavior-remove
                   :payload callback
                   :ordering-key (list 4 index)
                   :policy 'retryable-idempotent
                   :max-attempts 2))
              (etaf--runtime-run-contained-cleanup
               runtime 'behavior-remove identity cleanup))))
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
  (when-let* ((candidate (etaf-runtime-candidate-behaviors runtime)))
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
         (when-let* ((cleanup (cdr state)))
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
    (list :parent etaf--current-semantic-parent-id
          (if key :key :position)
          (or key (nthcdr (length etaf--render-parent-path) path)))))

(defun etaf--runtime-owned-slots (slots)
  "Attach current caller ownership to unowned normalized SLOTS."
  (mapcar
   (lambda (entry)
     (let* ((name (car entry)) (value (cdr entry))
            ;; Code-mode forwarding uses `etaf-current-slot', which exposes
            ;; the owned child list rather than the private SlotContent
            ;; wrapper.  Recover the wrapper by spine identity so the
            ;; original author Component remains the lifecycle owner.
            (forwarded-content
             (cl-loop for forwarded in etaf--current-component-slots
                      for content = (cdr forwarded)
                      when (and (etaf--slot-content-p content)
                                value
                                (or (eq value
                                        (etaf--slot-content-children content))
                                    (equal-including-properties
                                     value
                                     (etaf--slot-content-children content))))
                      return content)))
       (cond
        ((etaf--slot-content-p value) entry)
        (forwarded-content (cons name forwarded-content))
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
          :scope (let ((etaf--render-phase-p nil))
                   (etaf-effect-scope :name identity))
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

(defun etaf--runtime-dirty-descendant-p (runtime generation semantic-id)
  "Return non-nil when SEMANTIC-ID contains queued work in GENERATION."
  (cl-some
   (lambda (effect-id)
     (let ((walk (when-let* ((effect (etaf--generation-effect generation effect-id)))
                   (etaf--generation-effect-semantic-id effect))))
       (while (and walk (not (eql walk semantic-id)))
         (setq walk (etaf--generation-parent-id generation walk)))
       (eql walk semantic-id)))
   (etaf-runtime-dirty-effect-queue runtime)))

(defun etaf--runtime-render-component-resource
    (runtime instance identity props attrs slots path
             &optional old-output-range-id old-context-frame)
  "Render RUNTIME candidate IDENTITY from resource INSTANCE without mutation."
  (let* ((spec (etaf--component-instance-spec instance))
         (setup (etaf--component-spec-setup spec)))
    (let ((candidate-context
           (if old-context-frame
               (etaf-context-copy old-context-frame)
             (etaf--component-instance-context instance))))
      (let ((etaf--current-runtime runtime)
          (etaf--current-component-instance instance)
          (etaf--current-component-state
           (etaf--component-instance-state instance))
          (etaf--current-component-setup-defined-p (not (null setup)))
          (etaf--current-component-setup-complete-p
           (etaf--component-instance-setup-complete-p instance))
          (etaf--component-phase 'render)
          (etaf--current-component-identity identity)
          (etaf--current-component-props props)
          (etaf--current-component-slots slots)
          (etaf--raw-slot-read-p nil)
          (etaf--current-context candidate-context)
          (etaf--render-runtime runtime)
          (etaf--render-parent-style-owners etaf--render-style-owners)
          (etaf--render-style-owners
           (list
            (etaf--style-owner-create
             :scope (or (etaf--component-instance-style-scope instance)
                        (setf (etaf--component-instance-style-scope instance)
                              (ebox-style-scope-create nil)))
             :rules (etaf--component-spec-styles spec)))))
      (when (and setup
                 (not (etaf--component-instance-setup-complete-p instance)))
        (let ((state
               (etaf-scope-run
                (etaf--component-instance-scope instance)
                (lambda ()
                  (let ((etaf--runtime-dependency-collector nil)
                        (etaf--tracking-enabled-p nil)
                        (etaf--active-effect nil)
                        (etaf--render-phase-p nil)
                        (etaf--component-phase 'setup))
                    (funcall setup props slots)))
                :watch-scheduler
                (lambda (job phase)
                  (etaf--runtime-watch-scheduler runtime job phase)))))
          (when (functionp state)
            (signal 'etaf-runtime-error
                    (list (format
                           "Component %S :setup returned a function"
                           (etaf--component-spec-name spec)))))
          (setf (etaf--component-instance-state instance) state
                (etaf--component-instance-setup-complete-p instance) t
                etaf--current-component-state state
                etaf--current-component-setup-complete-p t)))
      (let* ((render-function (etaf--component-spec-render spec))
             (rendered
              (etaf--validate-component-render-result
               (funcall render-function props slots)
               (etaf--component-spec-name spec)))
             (rendered
              (etaf--apply-component-attrs
               rendered attrs (etaf--component-spec-name spec)))
             (range-id (or old-output-range-id
                           (cl-incf (etaf-runtime-next-semantic-id runtime))))
             (old-range (and old-output-range-id
                             (etaf-runtime-current-generation runtime)
                             (etaf--pvec-get
                              (etaf-generation-semantic-nodes
                               (etaf-runtime-current-generation runtime))
                              old-output-range-id)))
             (nodes
              (let ((etaf--current-semantic-parent-id
                     (or range-id etaf--current-semantic-parent-id))
                    (etaf--render-parent-path (append path (list :view)))
                    (etaf--current-range-item-index
                     (or (and old-range
                              (etaf--semantic-range-item-identity-index
                               old-range))
                         etaf--current-range-item-index))
                    ;; Every Component owns one stable output Range.  Hosts
                    ;; inside it start independent physical child lists.
                    (etaf--rendering-range-p t))
                (etaf--runtime-begin-child-order
                 runtime etaf--current-component-semantic-id)
                (when range-id
                  (etaf--runtime-begin-child-order runtime range-id))
                (etaf--render-value-list rendered
                                         (append path (list :view))))))
        (list rendered etaf--raw-slot-read-p nodes range-id candidate-context))))))

(defun etaf--runtime-stage-component-output-range
    (runtime old component-id semantic-id rendered path)
  "Stage COMPONENT-ID output Range in RUNTIME from OLD, RENDERED and PATH."
  (let* ((old-range (and old
                         (etaf--semantic-component-output-range-id old)
                         (etaf--pvec-get
                          (etaf-generation-semantic-nodes
                           (etaf-runtime-current-generation runtime))
                          (etaf--semantic-component-output-range-id old))))
         (range-ref (or (and old-range
                             (etaf--semantic-range-range-ref old-range))
                        (list 'etaf-component-output
                              (etaf-runtime-mount-epoch runtime) semantic-id)))
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
           :caller-style-owners (copy-tree etaf--render-style-owners)
           :output-signature (copy-tree rendered) :deps nil
           :artifact-key (list (1+ (etaf-runtime-generation runtime))
                               'component-output effect-id)
           :item-root-ids child-ids :item-identity-index item-index)))
    (dolist (child-id child-ids)
      (when-let* ((child (gethash child-id
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
      (when-let* ((item (gethash item-id
                                (etaf-runtime-candidate-graph-nodes runtime))))
        (when (etaf--semantic-host-p item)
          (puthash (etaf--semantic-host-identity item) item-id item-index))))
    (when old-range
      (let ((new-set (make-hash-table :test #'eql)))
        (dolist (item-id all-item-ids) (puthash item-id t new-set))
        (dolist (old-id
                 (etaf--runtime-generation-descendant-ids
                  (etaf-runtime-current-generation runtime)
                  (etaf--semantic-range-item-root-ids old-range)))
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
    (dolist (child-id child-ids)
      (when-let* ((child (gethash child-id
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
    record))

(defun etaf--runtime-render-component (runtime call path)
  "Render CALL through retained RUNTIME at PATH to its output Range."
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
         (input-props (etaf--component-business-props call))
         (input-attrs (etaf--component-call-attrs call))
         props attrs defaults input-deps render-deps context-deps slot-retargeted-p)
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
      (let ((resolved
             (etaf--component-resolve-input
              (etaf--component-instance-spec instance)
              (etaf--resolve-property-plist input-props)
              (and old
                   (equal (etaf--component-instance-resource-key instance)
                          (etaf--semantic-component-resource-key old))
                   (etaf--semantic-component-defaults old)))))
        (setq props (car resolved) defaults (cdr resolved)
              attrs (etaf--resolve-property-plist input-attrs))))
    (puthash semantic-id
             (list :identity identity :instance instance
                   :props props :attrs attrs :slots slots)
             (etaf-runtime-candidate-component-envs runtime))
    (when old
      (etaf--runtime-stage-prop-inputs
       runtime instance (etaf--semantic-component-props old) props))
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
                 (etaf--runtime-dirty-descendant-p runtime old-generation semantic-id)
                 (and slots etaf--rendering-component-effect-p
                      (not slot-retargeted-p))
                 (not (etaf--runtime-props-equal-p
                       defaults (etaf--semantic-component-defaults old)))
                 (not (etaf--runtime-props-equal-p
                       props (etaf--semantic-component-props old)))
                 (not (equal-including-properties
                       attrs (etaf--semantic-component-attrs old)))
                 (and (not slot-retargeted-p)
                      (not (equal-including-properties
                            slots (etaf--semantic-component-slots old))))))
        (progn
          (when (or (etaf-runtime-candidate-full-rebuild-p runtime)
                    etaf--rendering-range-p)
            (etaf--runtime-carry-committed-subtree runtime old-generation old))
          (let* ((range (or (gethash (etaf--semantic-component-output-range-id old)
                                     (etaf-runtime-candidate-graph-nodes runtime))
                            (etaf--generation-component-output-range old-generation old)))
                 (input (etaf--runtime-range-input runtime range)))
            (if (or etaf--rendering-range-p
                    (= etaf--current-semantic-parent-id (etaf-runtime-root-range-id runtime)))
                (cons 'component-output-range input)
              (list 'component-output-anchor (etaf--semantic-range-range-ref range) input))))
      (let ((builder (ebox-source-builder-create)) result)
        (let ((etaf--runtime-dependency-collector
               (lambda (source) (cl-pushnew source render-deps :test #'eq)))
              (etaf--context-inject-recorder
               (lambda (frame key)
                 (cl-pushnew (cons (etaf-context-owner-id frame) key)
                             context-deps :test #'equal)))
              (etaf--current-component-semantic-id semantic-id)
              (etaf--current-semantic-parent-id semantic-id)
              (etaf--ebox-source-builder builder)
              (etaf--rendering-component-effect-p t)
              (etaf--active-effect nil)
              (etaf--render-phase-p t))
          (setq result
                 (etaf--runtime-render-component-resource
                 runtime instance identity props attrs slots path
                 (and old (etaf--semantic-component-output-range-id old))
                 (and old (etaf--semantic-component-context-frame old)))))
        (cl-destructuring-bind
            (output-signature raw-slot-reader-p output-nodes range-id context-frame)
            result
          (let* ((output-range
                  (etaf--runtime-stage-component-output-range
                   runtime old semantic-id range-id output-signature path))
                 (input (ebox-canonical-input-create
                         (copy-sequence output-nodes) (ebox-source-builder-finish builder)))
                 (semantic
                  (etaf--semantic-component-create
                   :semantic-id semantic-id
                   :identity (copy-tree identity)
                   :input-effect-id input-effect-id :effect-id effect-id
                   :resource-key
                   (copy-tree (etaf--component-instance-resource-key instance))
                   :props (copy-sequence props) :attrs (copy-tree attrs)
                   :defaults defaults
                   :slots (copy-tree slots)
                   :input-props (copy-sequence input-props)
                   :input-attrs (copy-tree input-attrs)
                   :input-slots (copy-tree slots)
                   :output-signature (copy-tree output-signature)
                   :path (copy-tree path)
                   :caller-style-owners (copy-tree etaf--render-style-owners)
                   :input-deps (nreverse input-deps)
                   :deps (nreverse render-deps)
                   :parent-id etaf--current-semantic-parent-id
                   :caller-component-id etaf--current-component-semantic-id
                   :raw-slot-reader-p raw-slot-reader-p
                   :output-range-id (etaf--semantic-range-semantic-id output-range)
                   :context-frame (etaf-context-copy context-frame)
                   :context-deps (nreverse context-deps)
                   :child-ids
                   (copy-sequence
                    (gethash semantic-id
                             (etaf-runtime-candidate-graph-children runtime))))))
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
            (puthash (etaf--semantic-range-effect-id output-range) input
                     (etaf-runtime-candidate-range-artifacts runtime))
            (push identity (etaf-runtime-candidate-rendered-identities runtime))
            (if (or etaf--rendering-range-p
                    (= etaf--current-semantic-parent-id (etaf-runtime-root-range-id runtime)))
                (cons 'component-output-range input)
              (list 'component-output-anchor
                    (etaf--semantic-range-range-ref output-range) input))))))))

(defun etaf--runtime-lower-semantic-host-content-input (semantic content)
  "Lower SEMANTIC Host with resolved CONTENT into one atomic input."
  (let ((builder (ebox-source-builder-create)))
    (let* ((etaf--ebox-source-builder builder)
           (node
           (etaf--lower-resolved-semantic-host
             (etaf--semantic-host-name semantic)
             ;; The committed props signature is immutable for the duration
             ;; of this lowering pass.  Renderer and source-builder boundaries
             ;; take their own snapshots where ownership changes; copying the
             ;; complete plist here duplicated that work for every content
             ;; patch, including interaction keymaps and scope metadata.
             (etaf--semantic-host-props-signature semantic)
             (copy-sequence (or content ""))
             nil nil)))
      (ebox-canonical-input-create
       (list node) (ebox-source-builder-finish builder)))))

(defun etaf--runtime-lower-semantic-host-shallow (semantic)
  "Lower only SEMANTIC Host into one atomic input for a property patch."
  (etaf--runtime-lower-semantic-host-content-input
   semantic (etaf--semantic-host-content semantic)))

(defun etaf--runtime-carry-committed-subtree (runtime generation semantic)
  "Carry RUNTIME SEMANTIC and unstaged GENERATION descendants into a candidate."
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
                 (etaf--semantic-range-item-root-ids semantic))
                ((etaf--semantic-slot-range-p semantic)
                 (etaf--semantic-slot-range-item-root-ids semantic))
                (t nil))))
    (unless (and (etaf--semantic-host-p semantic)
                 (etaf--semantic-range-p
                  (etaf--pvec-get
                   (etaf-generation-semantic-nodes generation)
                   (etaf--semantic-host-parent-id semantic))))
      (puthash identity semantic-id
               (etaf-runtime-candidate-identity-entries runtime)))
    (when (etaf--semantic-host-p semantic)
      (etaf--runtime-register-host-behaviors runtime semantic))
    (puthash semantic-id semantic (etaf-runtime-candidate-graph-nodes runtime))
    (when (and (etaf--semantic-host-p semantic)
               (etaf--semantic-host-host-ref semantic))
      (let ((host-ref (etaf--semantic-host-host-ref semantic)))
        (when-let* ((handlers
                    (etaf--generation-index-lookup
                     generation 'handlers host-ref)))
          (puthash host-ref (copy-tree handlers)
                   (etaf-runtime-candidate-handlers runtime)))
        (when-let* ((props
                    (etaf--generation-index-lookup
                     generation 'host-props host-ref)))
          (puthash host-ref (copy-tree props)
                   (etaf-runtime-candidate-host-props runtime)))))
    (when (and (etaf--semantic-host-p semantic)
               (etaf--semantic-host-effect-id semantic))
      (let ((effect
             (or (etaf--pvec-get
                  (etaf-generation-effect-map generation)
                  (etaf--semantic-host-effect-id semantic))
                 (etaf--generation-effect-create
                  :effect-id (etaf--semantic-host-effect-id semantic)
                  :kind 'host-properties :semantic-id semantic-id
                  :deps (etaf--semantic-host-deps semantic)))))
        (puthash (etaf--generation-effect-effect-id effect) effect
                 (etaf-runtime-candidate-effects runtime))))
    (when (etaf--semantic-component-p semantic)
      (puthash identity semantic (etaf-runtime-candidate-semantic-nodes runtime))
      (puthash identity
               (gethash (etaf--semantic-component-resource-key semantic)
                        (etaf-runtime-resource-registry runtime))
               (etaf-runtime-candidate-live runtime))
      (dolist (entry
               (list
                (etaf--generation-effect
                 generation (etaf--semantic-component-input-effect-id semantic))
                (etaf--generation-effect
                 generation (etaf--semantic-component-effect-id semantic))))
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
      (when-let* ((child
                   (and (not (gethash child-id
                                      (etaf-runtime-candidate-graph-nodes runtime)))
                        (not (memq child-id
                                   (etaf-runtime-candidate-removed-semantic-ids
                                    runtime)))
                        (etaf--pvec-get
                         (etaf-generation-semantic-nodes generation) child-id))))
        (etaf--runtime-carry-committed-subtree runtime generation child)))))

(defun etaf--runtime-render-child-range (runtime expr path &optional kind)
  "Lower RUNTIME structural child EXPR at PATH as retained Range KIND."
  (let* ((token (etaf--render-site-token (etaf--expr-token expr)))
         (identity (list 'range etaf--current-semantic-parent-id
                         (or token (copy-tree path))))
         (old-generation (etaf-runtime-current-generation runtime))
         (old-id (and old-generation
                      (gethash identity
                               (etaf-generation-identity-index old-generation))))
         (old (and old-id
                   (etaf--pvec-get (etaf-generation-semantic-nodes old-generation)
                                   old-id)))
         (path (if old (etaf--semantic-range-path old) path))
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
                         (etaf--runtime-range-nodes runtime candidate))))))
      (if (and old
             ;; A stable site keeps ownership, but a fresh program may close
             ;; over a changed keyed item or lexical parent input.
             (eq expr
                 (etaf--generation-effect-target
                  (etaf--generation-effect old-generation effect-id)))
             ;; A parent Component may rerender because a preceding static
             ;; sibling changed while this direct Range did not.  Its stable
             ;; site token and retained artifact are sufficient to reuse the
             ;; Range; a genuinely dirty Range effect still takes the render
             ;; branch below.
             (not (etaf--runtime-range-must-refresh-for-component-input-p
                   expr))
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
                         (etaf--runtime-range-nodes runtime old))))))
      (let (deps context-deps value nodes keyed-snapshot range-render)
        (let ((collector
               (lambda (source) (cl-pushnew source deps :test #'eq))))
          (let ((etaf--runtime-dependency-collector collector)
                (etaf--context-inject-recorder
                 (lambda (frame key)
                   (cl-pushnew (cons (etaf-context-owner-id frame) key)
                               context-deps :test #'equal)))
                (etaf--active-effect nil)
                (etaf--render-phase-p t))
            (setq keyed-snapshot
                  (etaf--runtime-keyed-range-snapshot expr))
            (setq value
                  (if keyed-snapshot
                      ;; A key owns a forest, including an empty forest.
                      ;; Normalize within each item rather than flattening
                      ;; away the grouping used by incremental node spans.
                      (mapcar
                       (lambda (output)
                         (etaf--runtime-normalize-range-value output path))
                       (etaf--keyed-program-outputs expr keyed-snapshot))
                    (etaf--runtime-normalize-range-value
                     (funcall (etaf--expr-thunk expr)) path))))
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
                (etaf--render-parent-path path)
                (etaf--current-range-item-index
                 (and old (etaf--semantic-range-item-identity-index old)))
                (etaf--rendering-range-p t)
                (etaf--active-effect nil)
                (etaf--render-phase-p t))
            (setq range-render
                  (etaf--runtime-render-range-items
                   value path expr keyed-snapshot)
                  nodes (plist-get range-render :nodes))))
        (let* ((item-root-ids
                (copy-sequence
                 (gethash semantic-id
                          (etaf-runtime-candidate-graph-children runtime))))
               (all-item-ids
                (etaf--runtime-candidate-descendant-ids runtime item-root-ids))
               (item-index (make-hash-table :test #'equal))
               (keyed
                (etaf--runtime-keyed-range-metadata
                 expr keyed-snapshot
                 (plist-get range-render :item-root-groups)
                 (plist-get range-render :item-node-counts)))
               (input (etaf--ebox-input-for-nodes nodes))
               (record
               (etaf--semantic-range-create
                :semantic-id semantic-id :identity identity :effect-id effect-id
                :kind (or kind 'range)
                :parent-id etaf--current-semantic-parent-id
                :component-id etaf--current-component-semantic-id
                :token token :range-ref range-ref :path (copy-tree path)
                :caller-style-owners (copy-tree etaf--render-style-owners)
                :output-signature (copy-tree value) :deps (nreverse deps)
                :context-deps (nreverse context-deps)
                :artifact-key (cons (1+ (etaf-runtime-generation runtime))
                                    effect-id)
                :item-root-ids item-root-ids
                :item-identity-index item-index
                :keyed-context-signature (plist-get keyed :context)
                :keyed-item-signatures (plist-get keyed :signatures)
                :keyed-item-root-id-index (plist-get keyed :root-id-index)
                :keyed-item-node-span-index
                (plist-get keyed :node-span-index)
                :keyed-key-order (plist-get keyed :keys))))
          (etaf--runtime-index-range-item-identities
           runtime all-item-ids item-index)
          (when old
            (let ((new-set (make-hash-table :test #'eql)))
              (dolist (item-id all-item-ids) (puthash item-id t new-set))
              (dolist (old-id
                       (etaf--runtime-generation-descendant-ids
                        old-generation
                        (etaf--semantic-range-item-root-ids old)))
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
          (puthash effect-id input
                   (etaf-runtime-candidate-range-artifacts runtime))
          (when (and old
                     (not (ebox-canonical-input-equal-p
                           (etaf--runtime-committed-range-input runtime old)
                           input)))
            (push (list old record
                        (etaf--runtime-committed-range-input runtime old)
                        input nil)
                  (etaf-runtime-candidate-eager-range-changes runtime))
            (etaf--runtime-invalidate-range-ancestors runtime old)
            (etaf--runtime-record-range-owner-update runtime old))
          (cons 'range
                (list (apply #'ebox-child-range range-ref nodes)))))))))

(defun etaf--runtime-render-fragment-range (runtime fragment path)
  "Lower material-child FRAGMENT at PATH in RUNTIME as one retained Range."
  (let* ((expr (etaf--expr-create
                :token (etaf--view-node-token fragment)
                :thunk (lambda () (etaf--view-node-children fragment)))))
    (etaf--runtime-render-child-range runtime expr path 'fragment)))

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
         (style-owners (copy-tree (if provided-p
                                     etaf--render-parent-style-owners
                                   etaf--render-style-owners)))
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
                       :consumer-id consumer-id :style-owners style-owners)))
    (puthash identity semantic-id
             (etaf-runtime-candidate-identity-entries runtime))
    (etaf--runtime-candidate-add-child
     runtime etaf--current-semantic-parent-id semantic-id)
    (cond
     (candidate
      (cons 'range
            (list (apply #'ebox-child-range range-ref
                         (copy-sequence
                          (etaf--runtime-range-nodes runtime candidate))))))
     ((and old
           (equal-including-properties
            target (etaf--generation-effect-target old-effect))
           (not (gethash effect-id (etaf-runtime-dirty-effect-ids runtime))))
      (when (etaf-runtime-candidate-full-rebuild-p runtime)
        (etaf--runtime-carry-committed-subtree runtime generation old))
      (cons 'range
            (list (apply #'ebox-child-range range-ref
                         (copy-sequence
                          (etaf--runtime-range-nodes runtime old))))))
     (t
     (cl-multiple-value-bind (value deps nodes context-deps)
          (etaf--runtime-evaluate-slot-target
           runtime target semantic-id
           (and old (etaf--semantic-slot-range-item-identity-index old)) path)
        (let ((result
               (etaf--runtime-finish-slot-range-candidate
                runtime generation old identity semantic-id effect-id range-ref
                name token owner-id consumer-id style-owners path target
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
                            (etaf--runtime-committed-range-input runtime old)
                            (etaf--runtime-range-input runtime candidate-range)
                            nil)
                      (etaf-runtime-candidate-eager-range-changes runtime))
                (etaf--runtime-invalidate-semantic-ancestors
                 runtime (etaf--semantic-slot-range-parent-id old))
                (etaf--runtime-record-slot-owner-update runtime old))))
          result))))))

(defun etaf--runtime-finish-slot-range-candidate
    (runtime generation old identity semantic-id effect-id range-ref
             name token owner-id consumer-id style-owners path target
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
           :style-owners (copy-tree style-owners)
           :output-signature (copy-tree value) :deps deps
           :context-deps context-deps
           :artifact-key (cons (1+ (etaf-runtime-generation runtime)) effect-id)
           :item-root-ids item-host-ids :item-identity-index item-index)))
    (etaf--runtime-index-range-item-identities
     runtime all-item-ids item-index)
    (when old
      (let ((new-set (make-hash-table :test #'eql)))
        (dolist (item-id all-item-ids) (puthash item-id t new-set))
        (dolist (old-item-id
                 (etaf--runtime-generation-descendant-ids
                  generation (etaf--semantic-slot-range-item-root-ids old)))
          (unless (gethash old-item-id new-set)
            (push old-item-id
                  (etaf-runtime-candidate-removed-semantic-ids runtime))))))
    (puthash semantic-id record (etaf-runtime-candidate-graph-nodes runtime))
    (puthash effect-id
             (etaf--generation-effect-create
              :effect-id effect-id :kind 'slot :semantic-id semantic-id
              :deps deps :target target)
             (etaf-runtime-candidate-effects runtime))
    (puthash effect-id (etaf--ebox-input-for-nodes nodes)
             (etaf-runtime-candidate-range-artifacts runtime))
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
                  (plist-get target :children))))
         (let ((etaf--runtime-dependency-collector collector)
               (etaf--context-inject-recorder
                (lambda (frame key)
                  (cl-pushnew (cons (etaf-context-owner-id frame) key)
                              context-deps :test #'equal)))
               (etaf--render-runtime runtime)
               (etaf--current-semantic-parent-id semantic-id)
               (etaf--render-parent-path path)
               (etaf--current-range-item-index old-item-index)
               (etaf--rendering-range-p t)
               (etaf--render-style-owners
                (copy-tree (plist-get target :style-owners)))
               (etaf--active-effect nil)
               (etaf--render-phase-p t))
           (setq nodes (etaf--render-value-list value path))))))
    (cl-values value (nreverse deps) nodes (nreverse context-deps))))

(defun etaf--runtime-normalize-range-value (value &optional path)
  "Normalize structural View VALUE at the current Range boundary PATH.
Host descendants retain their programs for the ordinary renderer, so nested
expressions and keyed lists keep independent dependencies and ownership."
  (cond
   ((null value) nil)
   ((stringp value) (list value))
   ((or (etaf--component-call-p value) (etaf--slot-projection-p value))
    (list value))
   ((etaf--expr-p value)
    (etaf--runtime-normalize-range-value
     (funcall (etaf--expr-thunk value)) path))
   ((etaf--view-node-p value)
    (if (eq (etaf--view-node-name value) 'fragment)
        (cl-mapcan (lambda (child)
                     (etaf--runtime-normalize-range-value
                      child path))
                   (etaf--view-node-children value))
      (list value)))
   ((proper-list-p value)
    (cl-mapcan (lambda (child)
                 (etaf--runtime-normalize-range-value
                  child path))
               value))
   (t
    (signal 'etaf-runtime-error
            (list (format "Component %S View at %S expected nil, string, typed View, or proper sequence; received %S"
                          (or (car-safe etaf--current-component-identity) 'root)
                          path value))))))

(defun etaf--runtime-keyed-range-snapshot (expr)
  "Return EXPR's validated keyed Range snapshot, or nil."
  (if (eq (etaf--expr-kind expr) 'keyed-list)
      (etaf--keyed-program-snapshot expr)
    (when-let* ((snapshot-function (etaf--expr-range-snapshot expr)))
    (let ((key-function (etaf--expr-range-key expr))
          (item-function (etaf--expr-range-item expr))
          (snapshot (funcall snapshot-function)))
      (when snapshot
        (unless (and (functionp key-function)
                     (functionp item-function)
                     (proper-list-p snapshot)
                     (plist-member snapshot :items)
                     (proper-list-p (plist-get snapshot :items)))
          (signal 'etaf-runtime-error
                  (list "Invalid keyed Range program snapshot")))
        snapshot)))))

(defun etaf--runtime-keyed-range-keys (expr snapshot)
  "Return validated keys for EXPR aligned with keyed SNAPSHOT items."
  (if (plist-member snapshot :keys)
      (plist-get snapshot :keys)
      (let ((key-function (etaf--expr-range-key expr)))
        (unless (functionp key-function)
          (signal 'etaf-runtime-error
                  (list "Keyed Range lacks a key function")))
        (mapcar (lambda (item)
                  (etaf--validate-key (funcall key-function item)))
                (plist-get snapshot :items)))))

(defun etaf--runtime-keyed-range-item-path (path key)
  "Return stable PATH below one keyed Range item KEY."
  (append path (list (list :range-item (copy-tree key)))))

(defun etaf--runtime-render-range-items (value path expr snapshot)
  "Render normalized Range VALUE at PATH using optional keyed SNAPSHOT.
With SNAPSHOT, VALUE retains one normalized forest per logical item.
EXPR supplies the key function.  Keyed item paths encode stable keys rather
than transient positions, so reordering changes geometry without changing any
generated descendant identity.  Return a plist containing flat backend NODES
and, for keyed input, the semantic root groups and backend node counts owned by
each logical item."
  (if (null snapshot)
      (list :nodes (etaf--render-value-list value path))
    (let ((items (plist-get snapshot :items))
          (keys (etaf--runtime-keyed-range-keys expr snapshot))
          (seen (make-hash-table :test #'equal))
          nodes root-groups node-counts)
      (unless (and (= (length value) (length items))
                   (= (length items) (length keys)))
        (signal 'etaf-runtime-error
                (list "Keyed Range item/output cardinality mismatch")))
      (cl-mapc
       (lambda (output _item key)
         (let ((key (etaf--validate-key key)))
           (when (gethash key seen)
             (signal 'etaf-runtime-error
                     (list "Keyed Range keys must be unique" key)))
           (puthash key t seen)
           (let* ((before
                   (length
                    (gethash etaf--current-semantic-parent-id
                             (etaf-runtime-candidate-graph-children
                              etaf--render-runtime))))
                  (rendered
                   (etaf--render-value-list
                    output (etaf--runtime-keyed-range-item-path path key)))
                  (children
                   (gethash etaf--current-semantic-parent-id
                            (etaf-runtime-candidate-graph-children
                             etaf--render-runtime)))
                  (roots (copy-sequence (nthcdr before children))))
             (setq nodes (nconc nodes rendered))
             (push roots root-groups)
             (push (length rendered) node-counts))))
       value items keys)
      (list :nodes nodes
            :item-root-groups (nreverse root-groups)
            :item-node-counts (nreverse node-counts)))))

(defun etaf--runtime-keyed-range-metadata
    (expr snapshot item-root-groups item-node-counts)
  "Return retained metadata for EXPR and SNAPSHOT.
ITEM-ROOT-GROUPS and ITEM-NODE-COUNTS describe aligned item spans."
  (when snapshot
    (let ((items (plist-get snapshot :items))
          (snapshot-keys (etaf--runtime-keyed-range-keys expr snapshot))
          (signatures (make-hash-table :test #'equal))
          (root-id-index (make-hash-table :test #'equal))
          (node-span-index (make-hash-table :test #'equal))
          (seen (make-hash-table :test #'equal))
          (node-offset 0)
          keys)
      (unless (and (= (length items) (length item-root-groups))
                   (= (length items) (length item-node-counts)))
        (signal 'etaf-runtime-error
                (list "Keyed Range item/span cardinality mismatch")))
      (cl-mapc
       (lambda (item root-ids node-count key)
         (let ((key (etaf--validate-key key)))
           (when (gethash key seen)
             (signal 'etaf-runtime-error
                     (list "Keyed Range keys must be unique" key)))
           (unless (and (proper-list-p root-ids)
                        (natnump node-count))
             (signal 'etaf-runtime-error
                     (list "Invalid keyed Range item span" key)))
           (puthash key t seen)
           (puthash key item signatures)
           (puthash key (copy-sequence root-ids) root-id-index)
           (puthash key (cons node-offset node-count) node-span-index)
           (cl-incf node-offset node-count)
           (push key keys)))
       items item-root-groups item-node-counts
       snapshot-keys)
      (list :context (copy-tree (plist-get snapshot :context))
            :signatures signatures
            :root-id-index root-id-index
            :node-span-index node-span-index
            :keys (nreverse keys)))))

(defun etaf--runtime-index-range-item-identities
    (runtime semantic-ids identity-index)
  "Validate RUNTIME SEMANTIC-IDS and index Hosts in IDENTITY-INDEX."
  (dolist (semantic-id semantic-ids)
    (let ((semantic
           (gethash semantic-id
                    (etaf-runtime-candidate-graph-nodes runtime))))
      (unless (or (etaf--semantic-host-p semantic)
                  (etaf--semantic-component-p semantic)
                  (etaf--semantic-range-p semantic)
                  (etaf--semantic-slot-range-p semantic)
                  (etaf--semantic-inline-range-p semantic))
        (signal 'etaf-runtime-error
                (list "Invalid semantic root below Range" semantic-id)))
      (when (etaf--semantic-host-p semantic)
        (puthash (etaf--semantic-host-identity semantic)
                 semantic-id identity-index)))))

(defun etaf--runtime-candidate-descendant-ids (runtime roots)
  "Complete and return ROOTS' reachable candidate semantic graph in RUNTIME."
  (let ((queue (copy-sequence roots))
        (generation (etaf-runtime-current-generation runtime))
        result)
    (while queue
      (let ((semantic-id (pop queue)))
        ;; Local Component reuse may leave descendants implicit in the base
        ;; generation.  A Range owns an explicit subtree for indexing and
        ;; removal, including descendants across Component output boundaries.
        (when (and generation
                   (not (gethash semantic-id
                                 (etaf-runtime-candidate-graph-nodes runtime)))
                   (not (memq semantic-id
                              (etaf-runtime-candidate-removed-semantic-ids
                               runtime))))
          (when-let* ((retained
                       (etaf--pvec-get
                        (etaf-generation-semantic-nodes generation) semantic-id)))
            (etaf--runtime-carry-committed-subtree runtime generation retained)))
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
                      (etaf--generation-child-ids
                       generation semantic-id))))))
    (nreverse result)))

(defun etaf--runtime-inline-value-string (value surface)
  "Return inline VALUE when it is a string.
SURFACE is retained in the Range record for ABI stability but never applies
raw Emacs properties; Text presentation is projected by Ebox."
  (ignore surface)
  (cond
   ((null value) "")
   ((stringp value) value)
   (t
    (signal 'etaf-runtime-error
            (list "Text expr must resolve to nil or one string")))))

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
         (semantic-id (or old-id
                          (cl-incf (etaf-runtime-next-semantic-id runtime))))
         (effect-id (or (and old (etaf--semantic-inline-range-effect-id old))
                        (cl-incf (etaf-runtime-next-effect-id runtime)))))
    (puthash identity semantic-id
             (etaf-runtime-candidate-identity-entries runtime))
    (etaf--runtime-candidate-add-child runtime host-id semantic-id)
    (if candidate
        (cons semantic-id (etaf--semantic-inline-range-output candidate))
      (if (and old (not etaf--rendering-component-effect-p)
               (eq expr
                   (etaf--generation-effect-target
                    (etaf--generation-effect generation effect-id)))
               (not (gethash effect-id
                             (etaf-runtime-dirty-effect-ids runtime))))
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
            (when-let* ((component-id
                         (etaf--semantic-inline-range-component-id old))
                        (component
                         (etaf--pvec-get
                          (etaf-generation-semantic-nodes generation)
                          component-id)))
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
            (push value parts) (push value strings))
           ((etaf--expr-p value)
            (let ((entry (etaf--runtime-render-inline-range
                          runtime host-id value current-path inherited)))
              (push (car entry) parts) (push (cdr entry) strings)))
           ((etaf--view-node-p value)
            (signal 'etaf-runtime-error
                    (list (format "Text at %S cannot contain a View node: %S"
                                  current-path value))))
           ((proper-list-p value)
            (let ((index 0))
              (dolist (item value)
                (walk item (append current-path (list index)) inherited)
                (cl-incf index))))
           (t (signal 'etaf-runtime-error
                      (list (format "Component %S Text at %S expected string or nil; received %S"
                                    (or (car-safe etaf--current-component-identity)
                                        'root)
                                    current-path value)))))))
      (walk values path surface))
    (list (apply #'concat (nreverse strings)) (nreverse parts))))

(defun etaf--runtime-style-ancestor-p (runtime parent-id scope)
  "Return whether a Host above PARENT-ID belongs to SCOPE in RUNTIME."
  (let ((generation (etaf-runtime-current-generation runtime)) found)
    (while (and parent-id (not found))
      (let ((node (or (gethash parent-id (etaf-runtime-candidate-graph-nodes runtime))
                      (and generation
                           (etaf--pvec-get (etaf-generation-semantic-nodes generation) parent-id)))))
        (when (etaf--semantic-host-p node)
          (setq found
                (cl-some (lambda (owner) (eq scope (etaf--style-owner-scope owner)))
                         (etaf--semantic-host-style-identity node))))
        (setq parent-id (etaf--semantic-parent-id node))))
    found))

(defun etaf--runtime-enqueue-instance-hooks
    (runtime journal instance kind hooks ordering-prefix)
  "Enqueue INSTANCE HOOKS of KIND into JOURNAL after ORDERING-PREFIX.

Keep RUNTIME dynamically available while a lifecycle callback runs.  A
callback may be drained while the caller is visiting another buffer (for
example when `etaf-mount' receives a buffer name), so `current-buffer' alone
does not identify the mounted target."
  (cl-loop for hook in (reverse hooks)
           for index from 0
           do
           (let ((callback hook))
             (etaf-retirement-enqueue
              journal
              :owner (copy-tree (etaf--component-instance-identity instance))
              :kind kind
              :payload (lambda ()
                         (let ((etaf--render-phase-p nil)
                               (etaf--current-runtime runtime))
                           (funcall callback)))
              :ordering-key (append ordering-prefix (list 0 index))
              :policy 'run-once-public
              :max-attempts 1))))

(defun etaf--runtime-dispose-instance
  (runtime instance &optional run-hooks-p retirement-journal ordering-prefix)
  "Dispose INSTANCE and run public hooks when RUN-HOOKS-P is non-nil.
When RETIREMENT-JOURNAL is non-nil, enqueue public hooks and structural scope
cleanup after ORDERING-PREFIX instead of running them inline."
  (when (etaf--component-instance-p instance)
    (let ((mounted-p (etaf--component-instance-mounted-p instance))
          (scope (etaf--component-instance-scope instance)))
      ;; Authority is removed before any user or structural cleanup runs.
      (setf (etaf--component-instance-mounted-p instance) nil)
      (if retirement-journal
          (progn
            (when (and run-hooks-p mounted-p)
              (etaf--runtime-enqueue-instance-hooks
               runtime retirement-journal instance 'unmounted
               (etaf--component-instance-unmounted-hooks instance)
               ordering-prefix))
            (etaf-retirement-enqueue
             retirement-journal
             :owner (copy-tree (etaf--component-instance-identity instance))
             :kind 'scope-stop
             :payload
             (lambda ()
               (when-let* ((errors (etaf-scope-stop scope)))
                 (signal (caar errors) (cdar errors))))
             :ordering-key (append ordering-prefix '(1 0))
             :policy 'contained-once
             :max-attempts 1))
        (progn
          (when (and run-hooks-p mounted-p)
            (let ((etaf--render-phase-p nil))
              (etaf--run-hooks
               (etaf--component-instance-unmounted-hooks instance))))
          (etaf-scope-stop scope))))))

(defun etaf--runtime-dispose-created-candidate (runtime)
  "Dispose RUNTIME's instances created by an uncommitted candidate."
  (dolist (instance (etaf-runtime-candidate-created runtime))
    (remhash (etaf--component-instance-identity instance)
             (etaf-runtime-instances runtime))
    (remhash (etaf--component-instance-resource-key instance)
             (etaf-runtime-resource-registry runtime))
    (etaf--runtime-dispose-instance runtime instance nil))
  (dolist (entry (etaf-runtime-candidate-old-instances runtime))
    (puthash (car entry) (cadr entry) (etaf-runtime-instances runtime)))
  runtime)

(defun etaf--runtime-clear-candidate (runtime)
  "Clear transient candidate bookkeeping in RUNTIME."
  (etaf--runtime-restore-computeds runtime)
  (setf (etaf-runtime-candidate-computed-snapshots runtime) nil
        (etaf-runtime-candidate-prop-values runtime) nil
        (etaf-runtime-candidate-created runtime) nil
        (etaf-runtime-candidate-old-instances runtime) nil
        (etaf-runtime-candidate-live runtime) nil
        (etaf-runtime-candidate-semantic-nodes runtime) nil
        (etaf-runtime-candidate-component-envs runtime) nil
        (etaf-runtime-candidate-graph-nodes runtime) nil
        (etaf-runtime-candidate-identity-entries runtime) nil
        (etaf-runtime-candidate-graph-children runtime) nil
        (etaf-runtime-candidate-graph-child-tails runtime) nil
        (etaf-runtime-candidate-removed-semantic-ids runtime) nil
        (etaf-runtime-candidate-removed-effect-ids runtime) nil
        (etaf-runtime-candidate-removed-host-refs runtime) nil
        (etaf-runtime-candidate-rendered-identities runtime) nil
        (etaf-runtime-candidate-updated-component-identities runtime) nil
        (etaf-runtime-candidate-range-artifacts runtime)
        (make-hash-table :test #'eql)
        (etaf-runtime-candidate-inline-host-ids runtime) nil
        (etaf-runtime-candidate-eager-range-changes runtime) nil
        (etaf-runtime-candidate-effects runtime)
        (make-hash-table :test #'eql)
        (etaf-runtime-candidate-source-deltas runtime) nil
        (etaf-runtime-candidate-handlers runtime) nil
        (etaf-runtime-candidate-host-props runtime) nil
        (etaf-runtime-candidate-theme-paint-updates runtime) nil
        (etaf-runtime-candidate-behaviors runtime) nil
        (etaf-runtime-candidate-behavior-resource-keys runtime) nil))

(defun etaf--runtime-retire-detached-components
    (runtime old generation retirement-journal)
  "Retire RUNTIME Components detached from OLD in committed GENERATION.
RETIREMENT-JOURNAL owns hooks and Scope disposal after successful publication."
  (let (removed)
    (dolist (semantic-id
             (delete-dups
              (copy-sequence (etaf-runtime-candidate-removed-semantic-ids runtime))))
      (unless (etaf--pvec-get (etaf-generation-semantic-nodes generation)
                              semantic-id)
        (let ((semantic (etaf--pvec-get (etaf-generation-semantic-nodes old)
                                       semantic-id)))
          (when (etaf--semantic-component-p semantic)
            (push semantic removed)))))
    (cl-loop
     for semantic in (sort removed
                           (lambda (left right)
                             (> (length (etaf--semantic-component-path left))
                                (length (etaf--semantic-component-path right)))))
     for index from 0
     for key = (etaf--semantic-component-resource-key semantic)
     for identity = (etaf--semantic-component-identity semantic)
     for instance = (gethash key (etaf-runtime-resource-registry runtime))
     when instance do
     (when (eq instance (gethash identity (etaf-runtime-instances runtime)))
       (remhash identity (etaf-runtime-instances runtime)))
     (remhash key (etaf-runtime-resource-registry runtime))
     (etaf--runtime-dispose-instance
      runtime instance t retirement-journal (list 0 index)))))

(defun etaf--runtime-promote (runtime retirement-journal)
  "Promote RUNTIME candidate and enqueue removals in RETIREMENT-JOURNAL."
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
    (cl-loop for instance in (sort removed
                             (lambda (left right)
                               (> (length (etaf--component-instance-identity left))
                                  (length (etaf--component-instance-identity right)))))
             for index from 0
             do
      (remhash (etaf--component-instance-identity instance)
               (etaf-runtime-instances runtime))
      (remhash (etaf--component-instance-resource-key instance)
               (etaf-runtime-resource-registry runtime))
      (etaf--runtime-dispose-instance
       runtime instance t retirement-journal (list 0 index)))
    (cl-loop for entry in (etaf-runtime-candidate-old-instances runtime)
             for index from 0
             do (etaf--runtime-dispose-instance
                 runtime (cadr entry) t retirement-journal (list 1 index)))
    (dolist (instance added)
      (setf (etaf--component-instance-mounted-p instance) t))
    (list
     (sort added
           (lambda (left right)
             (< (length (etaf--component-instance-identity left))
                (length (etaf--component-instance-identity right)))))
     existing)))

(defun etaf--runtime-run-lifecycle (runtime groups retirement-journal)
  "Enqueue mounted and updated GROUPS in RETIREMENT-JOURNAL."
  (cl-loop for instance in (car groups)
           for index from 0
           do (etaf--runtime-enqueue-instance-hooks
               runtime retirement-journal instance 'mounted
               (etaf--component-instance-mounted-hooks instance)
               (list 2 index)))
  (cl-loop for instance in (cadr groups)
           for index from 0
           do (etaf--runtime-enqueue-instance-hooks
               runtime retirement-journal instance 'updated
               (etaf--component-instance-updated-hooks instance)
               (list 3 index))))

(defun etaf--runtime-begin-candidate (runtime)
  "Reset candidate bookkeeping before a RUNTIME render."
  (setq etaf--rendered-range-container-nodes nil)
  (setf (etaf-runtime-candidate-computed-snapshots runtime) (make-hash-table :test #'eq)
        (etaf-runtime-candidate-prop-values runtime) (make-hash-table :test #'eq)
        (etaf-runtime-candidate-live runtime) (make-hash-table :test #'equal)
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
        (etaf-runtime-candidate-graph-child-tails runtime)
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
        (etaf-runtime-candidate-theme-paint-updates runtime)
        (make-hash-table :test #'eq)
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
         (etaf-runtime-root-range-id runtime))
        (etaf--render-parent-path '(root)))
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
           :path '(root) :caller-style-owners nil
           :output-signature (copy-tree (etaf-runtime-root-view-cache runtime))
           :deps (copy-sequence deps) :artifact-key nil
           :item-root-ids children
           :item-identity-index (make-hash-table :test #'equal))))
    (puthash identity semantic-id
             (etaf-runtime-candidate-identity-entries runtime))
    (puthash semantic-id record
             (etaf-runtime-candidate-graph-nodes runtime))
    (puthash 0 (list semantic-id)
             (etaf-runtime-candidate-graph-children runtime))))

(defun etaf--runtime-record-detached-candidate-subtrees (runtime base)
  "Record BASE subtrees detached by RUNTIME's changed candidate edges.

Changed edges determine attachment through their parents up to Root.  Staging
a node under a detached parent does not keep it alive.  A child reattached to
a live parent retains its committed subtree.  Retire detached nodes together
with staged effects and contributions before building the next Generation."
  (when base
    (let ((candidate-children
           (etaf-runtime-candidate-graph-children runtime))
          (candidate-nodes (etaf-runtime-candidate-graph-nodes runtime))
          (attachment (make-hash-table :test #'eql))
          (removed (make-hash-table :test #'eql))
          (missing (make-symbol "etaf-attachment-unresolved")))
      (cl-labels
          ((candidate-attached-p
            (semantic-id)
            (if (eql semantic-id 0) t
              (let ((known (gethash semantic-id attachment missing)))
                (if (not (eq known missing)) known
                  ;; A cycle cannot establish a path to Root.
                  (puthash semantic-id nil attachment)
                  (let* ((node (or (gethash semantic-id candidate-nodes)
                                   (etaf--pvec-get
                                    (etaf-generation-semantic-nodes base)
                                    semantic-id)))
                         (parent-id (etaf--semantic-parent-id node))
                         (siblings
                          (and parent-id
                               (gethash parent-id candidate-children missing))))
                    (puthash
                     semantic-id
                     (and parent-id (candidate-attached-p parent-id)
                          (memq semantic-id
                                (if (eq siblings missing)
                                    (etaf--generation-child-ids base parent-id)
                                  siblings)))
                     attachment))))))
           (record-detached
            (semantic-id)
            (unless (or (candidate-attached-p semantic-id)
                        (gethash semantic-id removed))
              (puthash semantic-id t removed)
              (cl-pushnew semantic-id
                          (etaf-runtime-candidate-removed-semantic-ids runtime))
              (dolist (child-id
                       (append (etaf--generation-child-ids base semantic-id)
                               (gethash semantic-id candidate-children)))
                (record-detached child-id)))))
        ;; Explicit removals can already contain staged ancestors.  Walk them
        ;; too; the removal journal is not a visited set for this traversal.
        (dolist (id (etaf-runtime-candidate-removed-semantic-ids runtime))
          (record-detached id))
        (maphash
         (lambda (parent-id children)
           (dolist (old-child-id
                    (etaf--generation-child-ids base parent-id))
             (unless (memq old-child-id children)
               (record-detached old-child-id))))
         candidate-children)
        (maphash (lambda (id _node) (record-detached id)) candidate-nodes))
      ;; Reused Component records can be staged without copying their graph
      ;; subtree.  Prune this registry by semantic identity independently of
      ;; graph staging, or generation construction can resurrect a Component
      ;; whose children and Scope have already been retired.
      (maphash
       (lambda (identity semantic)
         (when (gethash (etaf--semantic-component-semantic-id semantic) removed)
           (remhash identity (etaf-runtime-candidate-semantic-nodes runtime))
           (remhash identity (etaf-runtime-candidate-live runtime))))
       (etaf-runtime-candidate-semantic-nodes runtime))
      (maphash
       (lambda (id _removed)
         (when-let* ((node (gethash id candidate-nodes)))
           (when (etaf--semantic-host-p node)
             (let ((ref (etaf--semantic-host-host-ref node)))
               (remhash ref (etaf-runtime-candidate-host-props runtime))
               (remhash ref (etaf-runtime-candidate-handlers runtime)))))
         (remhash id candidate-nodes)
         (remhash id (etaf-runtime-candidate-component-envs runtime)))
       removed)
      (maphash
       (lambda (effect-id effect)
         (when (gethash (etaf--generation-effect-semantic-id effect) removed)
           (remhash effect-id (etaf-runtime-candidate-effects runtime))
           (remhash effect-id (etaf-runtime-candidate-range-artifacts runtime))))
       (etaf-runtime-candidate-effects runtime))
      (maphash
       (lambda (identity id)
         (when (gethash id removed)
           (remhash identity (etaf-runtime-candidate-identity-entries runtime))))
       (etaf-runtime-candidate-identity-entries runtime))
      ;; Speculative instances that never reach Root have no mounted lifecycle.
      ;; Existing instances are retired only after publication succeeds.
      (dolist (instance (etaf-runtime-candidate-created runtime))
        (unless (gethash (etaf--component-instance-identity instance)
                         (etaf-runtime-candidate-live runtime))
          (setf (etaf-runtime-candidate-created runtime)
                (delq instance (etaf-runtime-candidate-created runtime)))
          (etaf--runtime-dispose-instance runtime instance nil)))
      ;; A stable semantic address may be reused while its public Host ref
      ;; changes.  Retire the previous contribution even though the semantic
      ;; node itself remains attached and is overwritten in place.
      (maphash
       (lambda (semantic-id semantic)
         (when-let* ((old (etaf--pvec-get
                          (etaf-generation-semantic-nodes base) semantic-id)))
           (when (and (etaf--semantic-host-p old)
                      (etaf--semantic-host-p semantic)
                      (not (equal (etaf--semantic-host-host-ref old)
                                  (etaf--semantic-host-host-ref semantic))))
             (cl-pushnew
              (etaf--semantic-host-host-ref old)
              (etaf-runtime-candidate-removed-host-refs runtime)
              :test #'equal))))
       candidate-nodes))))

(defun etaf--runtime-build-generation (runtime &optional base)
  "Build RUNTIME generation, point-copying candidate owners from BASE."
  (etaf--runtime-record-detached-candidate-subtrees runtime base)
  (unless (etaf-runtime-candidate-full-rebuild-p runtime)
    (etaf--runtime-prune-candidate-behaviors runtime base))
  (let* ((full-p (or (null base) (etaf-runtime-root-dirty-p runtime)))
         (generation-id (1+ (etaf-runtime-generation runtime)))
         (metrics (or (etaf-runtime-candidate-generation-metrics runtime)
                      (etaf--generation-metrics-create)))
         (nodes (and (not full-p) (etaf-generation-semantic-nodes base)))
         (effect-map (and (not full-p) (etaf-generation-effect-map base)))
         (source-effects (and (not full-p) (etaf-generation-source-effects base)))
         (effect-sources (and (not full-p) (etaf-generation-effect-sources base)))
         (resources (and (not full-p) (etaf-generation-resource-membership base)))
         (identity-index (if (not full-p)
                             (etaf-generation-identity-index base)
                           (make-hash-table :test #'equal)))
         (identity-copy nil)
         (affected-sources (make-hash-table :test #'eq))
         (effect-map-shadow (make-hash-table :test #'eql))
         (effect-sources-shadow (make-hash-table :test #'eql))
         (source-effects-shadow (make-hash-table :test #'eql))
         (missing-index-value (make-symbol "etaf-missing-index-value"))
         deltas
         node-updates resource-updates
         effect-map-update-ids effect-sources-update-ids
         source-effects-update-ids)
    (cl-labels
        ((index-value
          (shadow root id kind)
          (let ((value (gethash id shadow missing-index-value)))
            (if (eq value missing-index-value)
                (etaf--pvec-get root id metrics kind)
              value)))
         (stage-index-value
          (shadow ids id value)
          (let ((new-p (eq (gethash id shadow missing-index-value)
                           missing-index-value)))
            (puthash id value shadow)
            (if new-p (cons id ids) ids)))
         (staged-index-entries
          (shadow ids)
          (mapcar (lambda (id) (cons id (gethash id shadow)))
                  (nreverse ids)))
         (install-effect
          (effect old-deps new-deps)
          (let ((effect-id (etaf--generation-effect-effect-id effect)))
            (setq effect-map-update-ids
                  (stage-index-value effect-map-shadow effect-map-update-ids
                                     effect-id effect)
                  effect-sources-update-ids
                  (stage-index-value effect-sources-shadow
                                     effect-sources-update-ids effect-id
                                     (copy-sequence new-deps)))
            (dolist (source (cl-delete-duplicates
                             (append (copy-sequence old-deps)
                                     (copy-sequence new-deps))
                             :test #'eq))
              (puthash source t affected-sources)
              (let* ((source-id (etaf-reactive-source-id source))
                     (current-effects
                      (copy-sequence
                       (index-value source-effects-shadow source-effects
                                    source-id 'source)))
                     (new-effects (delq effect-id current-effects)))
                (when (memq source new-deps)
                  (setq new-effects
                        (sort (cons effect-id new-effects) #'<)))
                (unless (equal current-effects new-effects)
                  (setq source-effects-update-ids
                        (stage-index-value source-effects-shadow
                                           source-effects-update-ids
                                           source-id new-effects)))))))
         (remove-effect
          (effect-id)
          (when-let* ((old-effect
                      (index-value effect-map-shadow effect-map effect-id
                                   'effect)))
            (let ((deps (etaf--generation-effect-deps old-effect)))
              (setq effect-map-update-ids
                    (stage-index-value effect-map-shadow effect-map-update-ids
                                       effect-id nil)
                    effect-sources-update-ids
                    (stage-index-value effect-sources-shadow
                                       effect-sources-update-ids effect-id nil))
              (dolist (source deps)
                (puthash source t affected-sources)
                (let* ((source-id (etaf-reactive-source-id source))
                       (current-effects
                        (copy-sequence
                         (index-value source-effects-shadow source-effects
                                      source-id 'source)))
                       (new-effects (delq effect-id current-effects)))
                  (unless (equal current-effects new-effects)
                    (setq source-effects-update-ids
                          (stage-index-value source-effects-shadow
                                             source-effects-update-ids
                                             source-id new-effects))))))))
         (semantic-effect-ids
          (semantic)
          (cond
           ((etaf--semantic-component-p semantic)
            (delq nil
                  (list (etaf--semantic-component-input-effect-id semantic)
                        (etaf--semantic-component-effect-id semantic))))
           ((etaf--semantic-host-p semantic)
            (delq nil (list (etaf--semantic-host-effect-id semantic))))
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
                (resource-id
                 (cdr (etaf--semantic-component-resource-key semantic))))
           (push (cons semantic-id semantic) node-updates)
           (unless (eql semantic-id (gethash identity identity-index))
             (unless identity-copy
               (setq identity-index (copy-hash-table identity-index)
                     identity-copy t))
             (puthash identity semantic-id identity-index))
           (unless (and (not full-p)
                        (etaf--pvec-get resources resource-id))
             (push (cons resource-id
                         (etaf--semantic-component-resource-key semantic))
                   resource-updates))))
       (etaf-runtime-candidate-semantic-nodes runtime))
      (maphash
        (lambda (semantic-id semantic)
         (unless (etaf--semantic-component-p semantic)
           (push (cons semantic-id semantic) node-updates)))
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
      (maphash
       (lambda (identity old-key)
         (unless (equal old-key
                        (gethash identity
                                 (etaf-runtime-candidate-behavior-resource-keys
                                  runtime)))
           (push (cons (cdr old-key) nil) resource-updates)))
       (etaf-runtime-behavior-resource-keys runtime))
      (dolist (effect-id (etaf-runtime-candidate-removed-effect-ids runtime))
        (remove-effect effect-id))
      (dolist (semantic-id (etaf-runtime-candidate-removed-semantic-ids runtime))
        (let ((live-p
               (gethash semantic-id
                        (etaf-runtime-candidate-graph-nodes runtime))))
          ;; Replacement may reintroduce a stable descendant below a new
          ;; ancestor.  Candidate liveness wins over the old subtree's removal
          ;; journal for both the node and its effects.
          (unless live-p
            (when-let* ((old-node (and base
                                      (etaf--pvec-get
                                       (etaf-generation-semantic-nodes base)
                                       semantic-id))))
              (dolist (effect-id (semantic-effect-ids old-node))
                (remove-effect effect-id))
              (when (etaf--semantic-component-p old-node)
                (push (cons (cdr (etaf--semantic-component-resource-key old-node))
                            nil)
                      resource-updates))
              (when (and (etaf--semantic-host-p old-node)
                         (etaf--semantic-host-host-ref old-node))
                (let ((host-ref (etaf--semantic-host-host-ref old-node)))
                  (unless (or
                           (gethash host-ref
                                    (etaf-runtime-candidate-host-props runtime))
                           (gethash host-ref
                                    (etaf-runtime-candidate-handlers runtime)))
                    (cl-pushnew
                     host-ref
                     (etaf-runtime-candidate-removed-host-refs runtime)
                     :test #'equal)))))
            (push (cons semantic-id nil) node-updates))))
      (maphash
       (lambda (identity semantic-id)
         (unless (eql semantic-id (gethash identity identity-index))
           (unless identity-copy
             (setq identity-index (copy-hash-table identity-index)
                   identity-copy t))
           (puthash identity semantic-id identity-index)))
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
               (root-children
                (copy-sequence
                 (gethash 0
                          (etaf-runtime-candidate-graph-children runtime))))
               (root (etaf--semantic-root-create
                      :semantic-id 0 :effect-id effect-id
                      :input-signature
                      (copy-tree (etaf-runtime-root-view-cache runtime))
                      :deps (copy-sequence new-deps)
                      :child-ids root-children)))
          (push (cons 0 root) node-updates)
          (install-effect
           (etaf--generation-effect-create
            :effect-id effect-id :kind 'root
            :semantic-id (etaf-runtime-root-range-id runtime) :deps new-deps)
           old-deps new-deps)))
      ;; Apply all semantic/index membership edits in one trie batch.  The
      ;; candidate remains immutable; only the number of copied persistent
      ;; vector spines changes.
      (setq effect-map
            (etaf--pvec-put-many effect-map
                                 (staged-index-entries
                                  effect-map-shadow effect-map-update-ids)
                                 metrics)
            effect-sources
            (etaf--pvec-put-many effect-sources
                                 (staged-index-entries
                                  effect-sources-shadow
                                  effect-sources-update-ids)
                                 metrics)
            source-effects
            (etaf--pvec-put-many source-effects
                                 (staged-index-entries
                                  source-effects-shadow
                                  source-effects-update-ids)
                                 metrics)
            nodes
            (etaf--pvec-put-many nodes node-updates metrics)
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
       :parent-table nil
       :children-table nil
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

(defun etaf--runtime-complete-generation (runtime)
  "Complete RUNTIME publication and prune obsolete routes."
  (dolist (delta (etaf-runtime-candidate-source-deltas runtime))
    (let ((source (car delta)) (effects (nth 2 delta)))
      (when (null effects)
        (remhash (etaf-runtime-route-token runtime)
                 (etaf--source-subscribers source))
        (remhash source (etaf-runtime-route-sources runtime))))))

(defun etaf--runtime-new-semantic-candidate (runtime generation)
  "Return RUNTIME's next versioned semantic candidate for GENERATION."
  (let ((candidate-id
         (cl-incf (etaf-runtime-next-semantic-candidate-id runtime)))
        (operation-id
         (if etaf--observer-context
             (etaf--observer-context-operation-id etaf--observer-context)
           0)))
    (etaf-semantic-candidate-create
     (etaf--runtime-generation-authority runtime)
     generation operation-id candidate-id
     (etaf-runtime-mount-epoch runtime)
     (etaf-runtime-mount-epoch runtime))))

(defun etaf--runtime-swap-generation
    (runtime old candidate &optional semantic-candidate)
  "Swap RUNTIME from OLD to CANDIDATE with an exact authority guard.
SEMANTIC-CANDIDATE selects the versioned token/store CAS path."
  (if semantic-candidate
      (progn
        (unless (and
                 (eq old
                     (etaf-semantic-candidate-expected-generation
                      semantic-candidate))
                 (eq candidate
                     (etaf-semantic-candidate-candidate-generation
                      semantic-candidate)))
          (signal 'etaf-generation-error
                  (list :participant-candidate-mismatch)))
        (etaf-semantic-candidate-stage semantic-candidate))
    (unless (eq (etaf-runtime-current-generation runtime) old)
      (error "ETAF generation authority changed during publication"))
    (setf (etaf-runtime-current-generation runtime) candidate)))

(defun etaf--runtime-rollback-generation
    (runtime old candidate &optional semantic-candidate)
  "Idempotently restore OLD when RUNTIME still points at CANDIDATE."
  (if semantic-candidate
      (etaf-semantic-candidate-rollback semantic-candidate)
    (when (eq (etaf-runtime-current-generation runtime) candidate)
      (setf (etaf-runtime-current-generation runtime) old))))

(defun etaf--runtime-preinstall-resources (runtime old generation)
  "Install RUNTIME resources/artifacts for GENERATION and return journal.
OLD supplies the retained artifact generation whose obsolete entries are
removed inside the same rollback journal."
  (let ((removed-keys (make-hash-table :test #'equal)) journal completed)
    (cl-labels
        ((remove-retained
           (kind registry key)
           (when key
             (let ((address (list kind key))
                   (missing (make-symbol "etaf-artifact-missing")))
               (unless (gethash address removed-keys)
                 (puthash address t removed-keys)
                 (let ((value (gethash key registry missing)))
                   (unless (eq value missing)
                     (push (list kind key value) journal)
                     (remhash key registry))))))))
      (unwind-protect
          (progn
            (dolist (instance (etaf-runtime-candidate-created runtime))
              (let* ((key (etaf--component-instance-resource-key instance))
                     (identity (etaf--component-instance-identity instance))
                     (missing (make-symbol "etaf-instance-missing"))
                     (old-instance
                      (gethash identity (etaf-runtime-instances runtime)
                               missing)))
		(push (list 'resource key instance) journal)
		(puthash key instance (etaf-runtime-resource-registry runtime))
                (push (list 'instance identity
                            (not (eq old-instance missing)) old-instance instance)
                      journal)
                (puthash identity instance (etaf-runtime-instances runtime))))
            (maphash
             (lambda (_identity semantic)
               (when-let* ((instance
                            (gethash
                             (etaf--semantic-component-resource-key semantic)
                             (etaf-runtime-resource-registry runtime))))
                 (let ((old-context
                        (etaf--component-instance-context instance))
                       (new-context
                        (etaf--semantic-component-context-frame semantic)))
                   (unless (eq old-context new-context)
                     (push (list 'instance-context instance
                                 old-context new-context)
                           journal)
                     (setf (etaf--component-instance-context instance)
                           new-context)))))
             (etaf-runtime-candidate-semantic-nodes runtime))
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
               (unless (or (eq artifact :invalid)
                           (ebox-canonical-input-p artifact))
		 (signal 'etaf-runtime-error
			 (list "Range artifact is not canonical input")))
               (when-let* ((range
                            (etaf--generation-effect-semantic
                             generation effect-id)))
		 (let ((key (etaf--semantic-backend-range-artifact-key range)))
                   (push (list 'range-artifact key artifact) journal)
                   (puthash key artifact
                            (etaf-runtime-range-artifact-registry runtime)))))
             (etaf-runtime-candidate-range-artifacts runtime))
            (maphash
             (lambda (effect-id _artifact)
               (when-let* ((old-range
                            (and old
                                 (etaf--generation-effect-semantic
                                  old effect-id)))
                           (new-range
                            (etaf--generation-effect-semantic
                             generation effect-id))
                           (old-key
                            (etaf--semantic-backend-range-artifact-key
                             old-range)))
                 (unless (equal
                          old-key
                          (etaf--semantic-backend-range-artifact-key new-range))
                   (remove-retained
                    'range-artifact-removal
                    (etaf-runtime-range-artifact-registry runtime) old-key))))
             (etaf-runtime-candidate-range-artifacts runtime))
            (setq completed t)
            journal)
        (unless completed
          (etaf--runtime-rollback-resource-journal runtime journal))))))

(defun etaf--runtime-rollback-resource-journal (runtime journal)
  "Remove RUNTIME resources still owned by failed JOURNAL entries."
  (dolist (entry journal)
    (pcase (car entry)
      ('instance
       (let ((identity (nth 1 entry))
             (present-p (nth 2 entry))
             (old (nth 3 entry))
             (candidate (nth 4 entry)))
         (when (eq (gethash identity (etaf-runtime-instances runtime))
                   candidate)
           (if present-p
               (puthash identity old (etaf-runtime-instances runtime))
             (remhash identity (etaf-runtime-instances runtime))))))
      ('instance-context
       (let ((instance (nth 1 entry))
             (old-context (nth 2 entry))
             (new-context (nth 3 entry)))
         (when (eq (etaf--component-instance-context instance) new-context)
           (setf (etaf--component-instance-context instance) old-context))))
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
      ('range-artifact
       (when (eq (gethash (nth 1 entry)
                          (etaf-runtime-range-artifact-registry runtime))
                 (nth 2 entry))
         (remhash (nth 1 entry)
                  (etaf-runtime-range-artifact-registry runtime))))
      ('range-artifact-removal
       (let* ((registry (etaf-runtime-range-artifact-registry runtime))
              (key (nth 1 entry))
              (value (nth 2 entry))
              (missing (make-symbol "etaf-artifact-missing"))
              (current (gethash key registry missing)))
         (cond
          ((eq current missing) (puthash key value registry))
          ((eq current value) nil)
          (t
           (error "ETAF artifact authority changed during rollback: %S" key)))))))
  nil)

(defun etaf--runtime-bind-semantic-inverse-journal
    (candidate runtime resource-journal route-journal)
  "Bind CANDIDATE inverse journals for RUNTIME before authority staging.
RESOURCE-JOURNAL and ROUTE-JOURNAL remain opaque owner-local entries."
  (setf (etaf-semantic-candidate-inverse-journal candidate)
        (list :runtime runtime
              :resource-journal resource-journal
              :route-journal route-journal
              :state 'armed))
  candidate)

(defun etaf--runtime-rollback-semantic-inverse-journal (candidate)
  "Rollback CANDIDATE route/resource journals exactly once."
  (when-let* ((inverse (etaf-semantic-candidate-inverse-journal candidate))
              ((eq (plist-get inverse :state) 'armed)))
    (let ((runtime (plist-get inverse :runtime)))
      (plist-put inverse :state 'rolling-back)
      (unwind-protect
          (progn
            (etaf--runtime-rollback-prearm
             runtime (plist-get inverse :route-journal))
            (etaf--runtime-rollback-resource-journal
             runtime (plist-get inverse :resource-journal)))
        (plist-put inverse :state 'rolled-back))))
  candidate)

(defun etaf--runtime-commit-semantic-inverse-journal (candidate)
  "Mark CANDIDATE inverse journal committed and no longer rollback-capable."
  (when-let* ((inverse (etaf-semantic-candidate-inverse-journal candidate)))
    (unless (eq (plist-get inverse :state) 'armed)
      (signal 'etaf-generation-error
              (list :inverse-journal-not-armed
                    (plist-get inverse :state))))
    (plist-put inverse :state 'committed))
  candidate)

(defun etaf--runtime-participant-publish (participant)
  "Publish PARTICIPANT generation, restoring old authority on any failure."
  (let* ((success nil)
        (runtime (etaf--generation-participant-runtime participant))
        (semantic-candidate
         (etaf--generation-participant-semantic-candidate participant))
        (old (etaf-semantic-candidate-expected-generation semantic-candidate))
        (candidate
         (etaf-semantic-candidate-candidate-generation semantic-candidate))
        paint-updates)
    (when-let* ((table
                (etaf-runtime-candidate-theme-paint-updates runtime)))
      (maphash (lambda (slot spec)
                 (push (cons slot (copy-tree spec)) paint-updates))
               table))
    (unwind-protect
        (progn
          (when paint-updates
            (setf (etaf--generation-participant-paint-journal participant)
                  (ebox-paint-slot-apply-updates
                   (etaf-runtime-buffer runtime) paint-updates)))
          (etaf--runtime-swap-generation
           runtime old candidate semantic-candidate)
          (setf (etaf--generation-participant-state participant) 'published
                success t))
      (unless success
        (etaf--runtime-participant-rollback participant)))
    participant))

(defun etaf--runtime-participant-rollback (participant)
  "Rollback PARTICIPANT generation exactly and idempotently."
  (unless (eq (etaf--generation-participant-state participant) 'rolled-back)
    (let ((semantic-candidate
           (etaf--generation-participant-semantic-candidate participant)))
      (etaf--runtime-rollback-generation
       (etaf--generation-participant-runtime participant)
       (etaf-semantic-candidate-expected-generation semantic-candidate)
       (etaf-semantic-candidate-candidate-generation semantic-candidate)
       semantic-candidate)
      (when-let* ((paint-journal
                  (etaf--generation-participant-paint-journal participant)))
        (ebox-paint-slot-rollback-updates paint-journal)
        (setf (etaf--generation-participant-paint-journal participant) nil))
      (etaf--runtime-rollback-semantic-inverse-journal semantic-candidate)
      (setf (etaf--generation-participant-state participant) 'rolled-back)))
  participant)

(defun etaf--runtime-participant-commit (participant)
  "Commit PARTICIPANT semantic candidate after render final accept."
  (let ((candidate
         (etaf--generation-participant-semantic-candidate participant)))
    (etaf-semantic-candidate-commit candidate)
    (etaf--runtime-commit-semantic-inverse-journal candidate)
    (setf (etaf--generation-participant-state participant) 'committed)
    participant))

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
  (let* ((caller-id (etaf--semantic-component-caller-component-id semantic))
         deps)
    (etaf--runtime-call-with-component-env
     runtime caller-id
     (lambda ()
       (let ((etaf--runtime-dependency-collector
              (lambda (source) (cl-pushnew source deps :test #'eq)))
             (etaf--active-effect nil)
             (etaf--render-phase-p t))
         (let* ((instance
                 (gethash (etaf--semantic-component-resource-key semantic)
                          (etaf-runtime-resource-registry runtime)))
                (resolved
                 (etaf--component-resolve-input
                  (etaf--component-instance-spec instance)
                  (etaf--resolve-property-plist
                   (etaf--semantic-component-input-props semantic))
                  (etaf--semantic-component-defaults semantic)))
                (props (car resolved))
                (attrs (etaf--resolve-property-plist
                        (etaf--semantic-component-input-attrs semantic)))
                (slots (etaf--semantic-component-input-slots semantic))
                (candidate (copy-sequence semantic))
                (effect-id
                 (etaf--semantic-component-input-effect-id semantic)))
           (setf (etaf--semantic-component-defaults candidate) (cdr resolved)
                 (etaf--semantic-component-props candidate) (copy-sequence props)
                 (etaf--semantic-component-attrs candidate) (copy-tree attrs)
                 (etaf--semantic-component-slots candidate) (copy-tree slots)
                 (etaf--semantic-component-input-deps candidate)
                 (nreverse deps))
           (puthash (etaf--semantic-component-identity semantic) candidate
                    (etaf-runtime-candidate-semantic-nodes runtime))
           (puthash (etaf--semantic-component-semantic-id semantic)
                    (list :instance instance :identity (etaf--semantic-component-identity semantic)
                          :props props :attrs attrs :slots slots)
                    (etaf-runtime-candidate-component-envs runtime))
           (etaf--runtime-stage-prop-inputs
            runtime instance (etaf--semantic-component-props semantic) props)
           (puthash effect-id
                    (etaf--generation-effect-create
                     :effect-id effect-id :kind 'component-input
                     :semantic-id
                     (etaf--semantic-component-semantic-id semantic)
                     :deps (etaf--semantic-component-input-deps candidate))
                    (etaf-runtime-candidate-effects runtime))
           (unless
               (and (etaf--runtime-props-equal-p
                     props (etaf--semantic-component-props semantic))
                    (etaf--runtime-target-value-equal-p
                     attrs (etaf--semantic-component-attrs semantic))
                    (etaf--runtime-target-value-equal-p
                     slots (etaf--semantic-component-slots semantic)))
             (etaf--runtime-enqueue-effect
              runtime (etaf--semantic-component-effect-id semantic)))))))))

(defun etaf--runtime-retarget-component-slot-ranges (runtime semantic slots)
  "Retarget SEMANTIC projection slot effects to candidate SLOTS in RUNTIME."
  (let* ((generation (etaf-runtime-current-generation runtime))
         (descendants
          (etaf--runtime-generation-descendant-ids
           generation (etaf--semantic-component-child-ids semantic)))
         (slot-ranges
          (cl-loop for semantic-id in descendants
                   for node = (etaf--pvec-get
                               (etaf-generation-semantic-nodes generation)
                               semantic-id)
                   when (and (etaf--semantic-slot-range-p node)
                             (eql (etaf--semantic-slot-range-consumer-component-id
                                   node)
                                  (etaf--semantic-component-semantic-id semantic)))
                   collect node))
         found)
    ;; Descendant Components own their projections.  A missing input must
    ;; re-run this consumer's ordinary View to select its declared fallback.
    (when (cl-every (lambda (slot-range)
                      (assq (etaf--semantic-slot-range-name slot-range) slots))
                    slot-ranges)
      (dolist (slot-range slot-ranges)
        (setq found t)
        (let* ((name (etaf--semantic-slot-range-name slot-range))
               (entry (assq name slots))
               (content (cdr entry))
               (old-effect
                (etaf--generation-effect
                 generation (etaf--semantic-slot-range-effect-id slot-range)))
               (old-target (etaf--generation-effect-target old-effect))
               (owner-id
                (and (etaf--slot-content-p content)
                     (etaf--slot-content-owner-component-id content)))
               (children
                (if (etaf--slot-content-p content)
                    (etaf--slot-content-children content)
                  content))
               (target
                (list :children children :owner-id owner-id
                      :owner-input
                      (etaf--runtime-component-env-signature runtime owner-id)
                      :consumer-id
                      (etaf--semantic-slot-range-consumer-component-id slot-range)
                      :style-owners (plist-get old-target :style-owners))))
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

(defun etaf--runtime-hover-input-changed-p (effect bindings)
  "Whether EFFECT's hover BINDINGS consumed changed enclosing-owner inputs."
  (let ((deps (etaf--generation-effect-deps effect))
        (versions (etaf--generation-effect-dependency-versions effect))
        changed)
    (dolist (binding bindings)
      (when (eq (etaf--host-property-binding-property binding) :hover-content)
        (dolist (source (etaf--host-property-binding-dependencies binding))
          (let ((index (cl-position source deps :test #'eq)))
            (when (or (null index)
                      (/= (aref versions index) (etaf--source-version source)))
              (setq changed t))))))
    changed))

(defun etaf--runtime-defer-hover-owner (_frame _key)
  "Return a newly Context-dependent hover program to its enclosing render."
  (throw 'etaf-hover-owner-render nil))

(defun etaf--runtime-render-dirty-host-properties (runtime effect semantic)
  "Resolve EFFECT for Host SEMANTIC into RUNTIME's candidate graph."
  (cl-block etaf--runtime-render-dirty-host-properties
    (let* ((base
            (or (gethash (etaf--semantic-host-semantic-id semantic)
			 (etaf-runtime-candidate-graph-nodes runtime))
		semantic))
           (candidate (copy-sequence base))
           (host-ref (etaf--semantic-host-host-ref base))
           (old-bindings (etaf--semantic-host-property-bindings base))
           (property-bindings
            (mapcar #'copy-sequence old-bindings))
           (host-props (copy-tree (etaf--semantic-host-base-props base)))
           theme-scope style-props deps property-deps context-deps next-base-props)
      ;; Property expressions and style/Theme transforms are one Host render
      ;; evaluation.  Share its owner, write guard, paint slots and dependency
      ;; collectors; no user transform may escape into publication scope.
      (unless (catch 'etaf-hover-owner-render
		(etaf--runtime-call-with-component-env
		 runtime (etaf--semantic-host-component-id base)
		 (lambda ()
		   (let ((etaf--render-runtime runtime)
			 (etaf--runtime-dependency-collector
			  (lambda (source) (cl-pushnew source deps :test #'eq)))
			 (etaf--context-inject-recorder
			  (lambda (frame key)
			    (cl-pushnew (cons (etaf-context-owner-id frame) key)
					context-deps :test #'equal)))
			 (etaf--active-effect nil)
			 (etaf--render-phase-p t))
		     (dolist (binding property-bindings)
		       (let* ((binding-deps nil)
			      (etaf--context-inject-recorder
			       (if (eq (etaf--host-property-binding-property binding) :hover-content)
				   #'etaf--runtime-defer-hover-owner etaf--context-inject-recorder))
			      (etaf--runtime-dependency-collector
			       (lambda (source)
				 (cl-pushnew source binding-deps :test #'eq)
				 (cl-pushnew source deps :test #'eq))))
			 (setq host-props
			       (plist-put host-props
					  (etaf--host-property-binding-property binding)
					  (etaf--resolve-property-value
					   (etaf--host-property-binding-expression binding))))
			 (setf (etaf--host-property-binding-dependencies binding) binding-deps)))
		     (setq property-deps (copy-sequence deps)
			   next-base-props (copy-tree host-props))
		     ;; Theme and style transforms track their reactive sources
		     ;; through DEPS.  As in the initial render, their Context
		     ;; reads belong to the enclosing Component, not the Host.
		     (let* ((etaf--context-inject-recorder nil)
			    (etaf--render-style-owners (etaf--semantic-host-style-identity base))
			    (style-result (etaf--host-component-style-properties
					   nil (etaf--semantic-host-style-root-p base)))
			    (theme-result (etaf--resolve-host-theme
					   (etaf--semantic-host-name base) host-props host-ref)))
		       (setq style-props (car style-result))
		       (dolist (source (cadr style-result)) (cl-pushnew source deps :test #'eq))
		       (setq host-props (nth 0 theme-result)
			     theme-scope (nth 2 theme-result))
		       (dolist (source (nth 1 theme-result))
			 (cl-pushnew source deps :test #'eq))))))
		t)
	(let* ((component-id (etaf--semantic-host-component-id base))
               (component (and component-id
                               (etaf--pvec-get
				(etaf-generation-semantic-nodes
				 (etaf-runtime-current-generation runtime)) component-id))))
          (if component
              (etaf--runtime-enqueue-effect
               runtime (etaf--semantic-component-effect-id component))
            (etaf--runtime-mark-root-dirty runtime))
          (cl-return-from etaf--runtime-render-dirty-host-properties
            (and (null component) :root-fallback))))
      (let ((backend-props
             (etaf--host-theme-properties
              (etaf--ebox-properties host-props
                                     (etaf--semantic-host-path base)
                                     (etaf--semantic-host-site-token base) runtime host-ref)
              theme-scope)))
	(dolist (field '(:ecss-scopes :ecss-scope-roots))
          (when (plist-get style-props field)
            (setq backend-props (etaf--merge-property
				 backend-props field
				 (append (plist-get backend-props field)
					 (plist-get style-props field))))))
	(setf (etaf--semantic-host-property-bindings candidate) property-bindings
              (etaf--semantic-host-property-deps candidate) property-deps
              (etaf--semantic-host-base-props candidate) next-base-props
              (etaf--semantic-host-resolved-props candidate) host-props
              (etaf--semantic-host-props-signature candidate) backend-props
              (etaf--semantic-host-deps candidate) (nreverse deps)
              (etaf--semantic-host-context-deps candidate)
              (nreverse context-deps)
              (etaf--semantic-host-composition-version candidate)
              (1+ (etaf--semantic-host-composition-version base)))
	(puthash (etaf--semantic-host-semantic-id candidate) candidate
		 (etaf-runtime-candidate-graph-nodes runtime))
	(etaf--runtime-invalidate-semantic-ancestors
	 runtime (etaf--semantic-host-parent-id candidate))
	(when (etaf--runtime-hover-input-changed-p effect old-bindings)
	  (when-let* ((component-id (etaf--semantic-host-component-id base))
                      (component (etaf--pvec-get
				  (etaf-generation-semantic-nodes
				   (etaf-runtime-current-generation runtime)) component-id)))
            (cl-pushnew (etaf--semantic-component-identity component)
			(etaf-runtime-candidate-updated-component-identities runtime)
			:test #'equal)))
	(puthash host-ref host-props (etaf-runtime-candidate-host-props runtime))
	(puthash (etaf--generation-effect-effect-id effect)
		 (etaf--generation-effect-create
		  :effect-id (etaf--generation-effect-effect-id effect)
		  :kind 'host-properties
		  :semantic-id (etaf--semantic-host-semantic-id candidate)
		  :deps (etaf--semantic-host-deps candidate))
		 (etaf-runtime-candidate-effects runtime))
	candidate))))

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
         (attrs (etaf--semantic-component-attrs semantic))
         (slots (etaf--semantic-component-slots semantic))
         (builder (ebox-source-builder-create))
         deps context-deps result)
    (puthash (etaf--semantic-component-semantic-id semantic)
             (list :identity identity :instance instance
                   :props props :attrs attrs :slots slots)
             (etaf-runtime-candidate-component-envs runtime))
    (let ((etaf--current-component-identity parent)
          (etaf--current-component-semantic-id
           (etaf--semantic-component-semantic-id semantic))
          (etaf--current-semantic-parent-id
           (etaf--semantic-component-semantic-id semantic))
          (etaf--render-style-owners
           (copy-tree (etaf--semantic-component-caller-style-owners semantic)))
          (etaf--render-parent-style-owners nil)
          (etaf--ebox-source-builder builder)
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
             props attrs slots
             (etaf--semantic-component-path semantic)
             (etaf--semantic-component-output-range-id committed)
             (etaf--runtime-context-frame-for-candidate runtime committed))))
    (cl-destructuring-bind
        (output-signature raw-slot-reader-p output-nodes range-id context-frame)
        result
      (let* ((output-range
              (etaf--runtime-stage-component-output-range
               runtime committed (etaf--semantic-component-semantic-id semantic)
               range-id output-signature (etaf--semantic-component-path semantic)))
             (input (ebox-canonical-input-create
                     (copy-sequence output-nodes) (ebox-source-builder-finish builder)))
             (candidate (copy-sequence semantic)))
        (setf (etaf--semantic-component-output-signature candidate)
              (copy-tree output-signature)
              (etaf--semantic-component-props candidate) (copy-sequence props)
              (etaf--semantic-component-attrs candidate) (copy-tree attrs)
              (etaf--semantic-component-slots candidate) (copy-tree slots)
              (etaf--semantic-component-deps candidate) (nreverse deps)
              (etaf--semantic-component-raw-slot-reader-p candidate)
              raw-slot-reader-p
              (etaf--semantic-component-output-range-id candidate)
              (etaf--semantic-range-semantic-id output-range)
              (etaf--semantic-component-context-frame candidate)
              (etaf-context-copy context-frame)
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
        (puthash (etaf--semantic-range-effect-id output-range) input
                 (etaf-runtime-candidate-range-artifacts runtime))
        (etaf--runtime-invalidate-semantic-ancestors runtime parent-id)
        (push identity (etaf-runtime-candidate-rendered-identities runtime))
        candidate))))

(defun etaf--runtime-render-keyed-range
    (runtime effect range)
  "Render EFFECT's changed items in keyed RANGE for RUNTIME.
The caller supplies the retained owner environment.  Return nil when the
range is not eligible for keyed incremental rendering."
  (let* ((expr (etaf--generation-effect-target effect))
         (snapshot-function (and (etaf--expr-p expr)
                                 (etaf--expr-range-snapshot expr)))
         (key-function (and (etaf--expr-p expr)
                            (etaf--expr-range-key expr)))
         (item-function (and (etaf--expr-p expr)
                             (etaf--expr-range-item expr)))
         (old-signatures (etaf--semantic-range-keyed-item-signatures range))
         (old-root-id-index
          (etaf--semantic-range-keyed-item-root-id-index range))
         (old-node-span-index
          (etaf--semantic-range-keyed-item-node-span-index range))
         (old-keys (etaf--semantic-range-keyed-key-order range)))
    (when (and snapshot-function item-function
               (or key-function (eq (etaf--expr-kind expr) 'keyed-list))
               (hash-table-p old-signatures)
               (hash-table-p old-root-id-index)
               (hash-table-p old-node-span-index)
               (proper-list-p old-keys))
      (let (deps context-deps snapshot)
        (let ((etaf--runtime-dependency-collector
               (lambda (source) (cl-pushnew source deps :test #'eq)))
              (etaf--context-inject-recorder
               (lambda (frame key)
                 (cl-pushnew (cons (etaf-context-owner-id frame) key)
                             context-deps :test #'equal)))
              (etaf--active-effect nil)
              (etaf--render-phase-p t))
          (setq snapshot (etaf--runtime-keyed-range-snapshot expr)))
        (when snapshot
          (let* ((generation (etaf-runtime-current-generation runtime))
                 (items (plist-get snapshot :items))
                 (snapshot-keys
                  (etaf--runtime-keyed-range-keys expr snapshot))
                 (context (plist-get snapshot :context))
                 (context-stable-p
                  (equal-including-properties
                   context
                   (etaf--semantic-range-keyed-context-signature range)))
                 (old-input (etaf--runtime-range-input runtime range))
                 (old-nodes (ebox-canonical-input-roots old-input))
                 (seen (make-hash-table :test #'equal))
                 (missing (make-symbol "etaf-keyed-span-missing"))
                 (old-node-offset 0)
                 (new-node-offset 0)
                 nodes keys signatures reuse-map reused-roots
                 item-root-groups item-node-counts)
            (dolist (key old-keys)
              (let ((span (gethash key old-node-span-index missing)))
                (unless (and (consp span)
                             (natnump (car span))
                             (natnump (cdr span))
                             (= (car span) old-node-offset)
                             (<= (+ (car span) (cdr span))
                                 (length old-nodes)))
                  (signal 'etaf-runtime-error
                          (list "Keyed Range retained node spans are invalid"
                                key)))
                (cl-incf old-node-offset (cdr span))))
            (unless (= old-node-offset (length old-nodes))
              (signal 'etaf-runtime-error
                      (list "Keyed Range retained artifact is misaligned")))
            (let ((etaf--runtime-dependency-collector
                   (lambda (source) (cl-pushnew source deps :test #'eq)))
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
                  (etaf--render-parent-path (etaf--semantic-range-path range))
                  (etaf--rendering-range-p t)
                  (etaf--active-effect nil)
                  (etaf--render-phase-p t)
                  (etaf--render-style-owners
                   (copy-tree
                    (etaf--semantic-range-caller-style-owners range))))
              (cl-loop
               for item in items
               for key in snapshot-keys
               for index from 0
               do
               (let* ((key (etaf--validate-key key))
                      (old-signature (gethash key old-signatures))
                      (old-root-ids
                       (gethash key old-root-id-index missing))
                      (old-node-span
                       (gethash key old-node-span-index missing))
                      (reuse-p
                       (and context-stable-p
                            (not (eq old-root-ids missing))
                            (not (eq old-node-span missing))
                            (etaf--reactive-same-p item old-signature))))
                 (when (gethash key seen)
                   (signal 'etaf-runtime-error
                           (list "Keyed Range keys must be unique" key)))
                 (puthash key t seen)
                 (push key keys)
                 (push item signatures)
                 (if reuse-p
                     (let* ((old-start (car old-node-span))
                            (old-count (cdr old-node-span))
                            (old-item-nodes
                             (cl-subseq old-nodes old-start
                                        (+ old-start old-count))))
                       (unless (proper-list-p old-root-ids)
                         (signal 'etaf-runtime-error
                                 (list "Keyed Range retained roots are invalid"
                                       key)))
                       (dolist (old-root-id old-root-ids)
                         (let ((semantic
                                (etaf--pvec-get
                                 (etaf-generation-semantic-nodes generation)
                                 old-root-id)))
                           (unless semantic
                             (signal 'etaf-runtime-error
                                     (list "Keyed Range retained root is missing"
                                           key old-root-id)))
                           (etaf--runtime-candidate-add-child
                            runtime (etaf--semantic-range-semantic-id range)
                            old-root-id)
                           (etaf--runtime-carry-committed-subtree
                            runtime generation semantic)))
                       (cl-loop for offset below old-count
                                do (push
                                    (cons (+ new-node-offset offset)
                                          (+ old-start offset))
                                    reuse-map))
                       (setq nodes (nconc nodes old-item-nodes)
                             reused-roots
                             (nconc reused-roots
                                    (copy-sequence old-item-nodes)))
                       (push (copy-sequence old-root-ids) item-root-groups)
                       (push old-count item-node-counts)
                       (cl-incf new-node-offset old-count))
                   (let* ((before
                           (length
                            (gethash
                             (etaf--semantic-range-semantic-id range)
                             (etaf-runtime-candidate-graph-children runtime))))
                          (value
                           (etaf--runtime-normalize-range-value
                            (funcall item-function item context)
                            (etaf--semantic-range-path range)))
                          (rendered
                           (etaf--render-value-list
                            value
                            (etaf--runtime-keyed-range-item-path
                             (etaf--semantic-range-path range) key)))
                          (children
                           (gethash
                            (etaf--semantic-range-semantic-id range)
                            (etaf-runtime-candidate-graph-children runtime)))
                          (root-ids
                           (copy-sequence (nthcdr before children)))
                          (node-count (length rendered)))
                     (setq nodes (nconc nodes rendered))
                     (push root-ids item-root-groups)
                     (push node-count item-node-counts)
                     (cl-incf new-node-offset node-count)))))
            (ebox-canonical-input-import-roots
             old-input reused-roots etaf--ebox-source-builder)
            (list :nodes nodes
                  :snapshot snapshot
                  :value (list :keyed-range
                               (copy-tree context)
                               (nreverse keys)
                               (nreverse signatures))
                  :item-root-groups (nreverse item-root-groups)
                  :item-node-counts (nreverse item-node-counts)
                  :deps (nreverse deps)
                  :context-deps (nreverse context-deps)
                  :reuse-map (nreverse reuse-map)
                  ;; Ebox validates every non-reused slot against this input's
                  ;; source generation; reused slots are replaced by their
                  ;; exact published objects from the explicit reuse map.
                  :retain-item-identities-p t))))))))

(defun etaf--runtime-render-dirty-range (runtime effect range)
  "Evaluate RUNTIME dirty RANGE EFFECT without running its Component owner."
  (let ((builder (ebox-source-builder-create))
        deps context-deps value nodes keyed-snapshot
        item-root-groups item-node-counts)
    (let ((etaf--ebox-source-builder builder))
      (let ((keyed
             (etaf--runtime-call-with-component-env
              runtime (etaf--semantic-range-component-id range)
              (lambda ()
                (etaf--runtime-render-keyed-range runtime effect range)))))
        (if keyed
            (setq deps (plist-get keyed :deps)
                  context-deps (plist-get keyed :context-deps)
                  value (plist-get keyed :value)
                  nodes (plist-get keyed :nodes)
                  keyed-snapshot (plist-get keyed :snapshot)
                  item-root-groups (plist-get keyed :item-root-groups)
                  item-node-counts (plist-get keyed :item-node-counts))
          ;; A root-owned expression has no Component.  The same environment
          ;; helper handles it and preserves lexical props through lowering.
          (etaf--runtime-call-with-component-env
           runtime (etaf--semantic-range-component-id range)
           (lambda ()
             (let ((etaf--runtime-dependency-collector
                    (lambda (source) (cl-pushnew source deps :test #'eq)))
                   (etaf--context-inject-recorder
                    (lambda (frame key)
                      (cl-pushnew (cons (etaf-context-owner-id frame) key)
                                  context-deps :test #'equal)))
                   (etaf--render-runtime runtime)
                   (etaf--current-semantic-parent-id
                    (etaf--semantic-range-semantic-id range))
                   (etaf--render-parent-path (etaf--semantic-range-path range))
                   (etaf--current-range-item-index
                    (etaf--semantic-range-item-identity-index range))
                   (etaf--rendering-range-p t)
                   (etaf--active-effect nil)
                   (etaf--render-phase-p t)
                   (etaf--render-style-owners
                    (copy-tree (etaf--semantic-range-caller-style-owners range))))
               (setq value
                     (etaf--runtime-normalize-range-value
                      (funcall (etaf--expr-thunk
                                (etaf--generation-effect-target effect)))
                      (etaf--semantic-range-path range))
                     nodes
                     (etaf--render-value-list
                      value (etaf--semantic-range-path range)))))))
    (let* ((item-root-ids
            (copy-sequence
             (gethash (etaf--semantic-range-semantic-id range)
                      (etaf-runtime-candidate-graph-children runtime))))
           (all-item-ids
            (etaf--runtime-candidate-descendant-ids runtime item-root-ids))
           (item-index (make-hash-table :test #'equal))
           (keyed-metadata
            (and keyed-snapshot
                 (etaf--runtime-keyed-range-metadata
                  (etaf--generation-effect-target effect)
                  keyed-snapshot item-root-groups item-node-counts)))
           (candidate (copy-sequence range)))
      (etaf--runtime-index-range-item-identities
       runtime all-item-ids item-index)
      (let ((new-set (make-hash-table :test #'eql)))
        (dolist (item-id all-item-ids) (puthash item-id t new-set))
        (dolist (old-id
                 (etaf--runtime-generation-descendant-ids
                  (etaf-runtime-current-generation runtime)
                  (etaf--semantic-range-item-root-ids range)))
          (unless (gethash old-id new-set)
            (push old-id
                  (etaf-runtime-candidate-removed-semantic-ids runtime)))))
      (setf (etaf--semantic-range-output-signature candidate) (copy-tree value)
            (etaf--semantic-range-deps candidate) (nreverse deps)
            (etaf--semantic-range-context-deps candidate) (nreverse context-deps)
            (etaf--semantic-range-artifact-key candidate)
            (cons (1+ (etaf-runtime-generation runtime))
                  (etaf--semantic-range-effect-id range))
            (etaf--semantic-range-item-root-ids candidate) item-root-ids
            (etaf--semantic-range-item-identity-index candidate) item-index
            (etaf--semantic-range-keyed-context-signature candidate)
            (plist-get keyed-metadata :context)
            (etaf--semantic-range-keyed-item-signatures candidate)
            (plist-get keyed-metadata :signatures)
            (etaf--semantic-range-keyed-item-root-id-index candidate)
            (plist-get keyed-metadata :root-id-index)
            (etaf--semantic-range-keyed-item-node-span-index candidate)
            (plist-get keyed-metadata :node-span-index)
            (etaf--semantic-range-keyed-key-order candidate)
            (plist-get keyed-metadata :keys)
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
      (puthash (etaf--semantic-range-effect-id range)
               (etaf--ebox-input-for-nodes nodes)
               (etaf-runtime-candidate-range-artifacts runtime))
      (etaf--runtime-invalidate-range-ancestors runtime range)
      (unless (equal-including-properties
               (etaf--semantic-range-output-signature range) value)
        (etaf--runtime-record-range-owner-update runtime range))
      (list range candidate
            (etaf--runtime-committed-range-input runtime range)
            (etaf--runtime-range-input runtime candidate)
            (plist-get keyed :reuse-map)
            ;; A keyed render with no reused item owns every payload node in
            ;; this candidate source generation.  Ebox rechecks that proof
            ;; before retaining identity; other Range paths keep copy-based
            ;; fallback semantics.
            (plist-get keyed :retain-item-identities-p)))))))

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
  (let (deps context-deps output)
    (etaf--runtime-call-with-component-env
     runtime (etaf--semantic-inline-range-component-id inline)
     (lambda ()
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
                (funcall
                 (etaf--expr-thunk (etaf--generation-effect-target effect)))
                (etaf--semantic-inline-range-surface-properties inline))))))
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
        (when-let* ((component-id
                     (etaf--semantic-inline-range-component-id inline))
                    (component
                    (etaf--pvec-get
                     (etaf-generation-semantic-nodes
                      (etaf-runtime-current-generation runtime))
                     component-id)))
          (cl-pushnew (etaf--semantic-component-identity component)
                      (etaf-runtime-candidate-updated-component-identities runtime)
                      :test #'equal)))
      candidate)))

(defun etaf--runtime-render-dirty-slot-range (runtime effect slot-range)
  "Evaluate dirty SLOT-RANGE for EFFECT in RUNTIME and stage its backend change."
  (let* ((target (etaf--generation-effect-target effect))
         (semantic-id (etaf--semantic-slot-range-semantic-id slot-range))
         (effect-id (etaf--semantic-slot-range-effect-id slot-range))
         (etaf--current-semantic-parent-id
          (etaf--semantic-slot-range-parent-id slot-range))
         (builder (ebox-source-builder-create)))
    (let ((etaf--ebox-source-builder builder))
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
         (plist-get target :style-owners)
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
              (etaf--runtime-committed-range-input runtime slot-range)
              (etaf--runtime-range-input runtime candidate)
              nil))))))

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

(defun etaf--runtime-publication-range (runtime generation range)
  "Return RANGE's nearest physical publication owner in RUNTIME GENERATION.
Adjacent semantic Ranges share a child list.  Slot projection can flatten a
semantic boundary further; Ebox's committed address query decides whether
that list is independently published.  Otherwise use its enclosing owner."
  (catch 'owner
    (let ((owner range)
          (parent (etaf--semantic-parent-id range)))
      (while (and parent (> parent 0))
        (let ((node (etaf--pvec-get (etaf-generation-semantic-nodes generation) parent)))
          (when (and (etaf--semantic-host-p node)
                     (ebox-range-ref-present-p
                      (etaf-runtime-buffer runtime)
                      (etaf--semantic-backend-range-ref owner)))
            (throw 'owner owner))
          (when (or (etaf--semantic-range-p node) (etaf--semantic-slot-range-p node))
            (setq owner node))
          (setq parent (etaf--semantic-parent-id node))))
      owner)))

(defun etaf--runtime-normalize-range-changes (runtime generation candidate changes)
  "Compose CHANGES from final CANDIDATE facts over RUNTIME GENERATION.
Semantic Ranges sharing a physical child list publish through that list's
owner.  Hosts keep independent child lists.  The semantic root uses Ebox's
root operation, without discarding and rerunning application effects."
  (let ((owners (make-hash-table :test #'eql)) result)
    (dolist (change changes)
      (when-let* ((range (car change))
                  (owner (etaf--runtime-publication-range runtime generation range))
                  (id (etaf--semantic-backend-range-semantic-id owner))
                  (next (etaf--pvec-get (etaf-generation-semantic-nodes candidate) id)))
        (puthash id (cons owner next) owners)))
    (maphash
     (lambda (id pair)
       (let ((parent (etaf--generation-parent-id generation id)) absorbed)
         (while (and parent (not absorbed))
           (setq absorbed (gethash parent owners)
                 parent (etaf--generation-parent-id generation parent)))
         (unless absorbed
           (let ((old-input (etaf--runtime-snapshot-range-input runtime generation (car pair) nil))
                 (next-input (etaf--runtime-snapshot-range-input runtime candidate (cdr pair) nil)))
             (unless (ebox-canonical-input-equal-p old-input next-input)
               (push (list (car pair) (cdr pair) old-input next-input nil nil) result))))))
     owners)
    (nreverse result)))

(defun etaf--runtime-invalidate-semantic-ancestors (runtime parent-id)
  "Invalidate RUNTIME artifacts from PARENT-ID through semantic ancestors."
  (let* ((generation (etaf-runtime-current-generation runtime))
         (nodes (etaf-generation-semantic-nodes generation)))
    (while (and parent-id (> parent-id 0))
      (let ((record (or (gethash parent-id (etaf-runtime-candidate-graph-nodes runtime))
                        (etaf--pvec-get nodes parent-id))))
        (cond
         ((or (etaf--semantic-range-p record) (etaf--semantic-slot-range-p record))
          (unless (and (etaf--semantic-range-p record)
                       (eq (etaf--semantic-range-kind record) 'root))
            (let* ((candidate (copy-sequence record))
                   (effect-id (if (etaf--semantic-range-p record)
                                  (etaf--semantic-range-effect-id record)
                                (etaf--semantic-slot-range-effect-id record)))
                   (key (cons (1+ (etaf-runtime-generation runtime)) effect-id)))
              (if (etaf--semantic-range-p candidate)
                  (setf (etaf--semantic-range-artifact-key candidate) key)
                (setf (etaf--semantic-slot-range-artifact-key candidate) key))
              (puthash parent-id candidate (etaf-runtime-candidate-graph-nodes runtime))
              (puthash effect-id :invalid (etaf-runtime-candidate-range-artifacts runtime))))
          (setq parent-id (etaf--semantic-parent-id record)))
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
          (etaf--runtime-lower-semantic-host-content-input
           old-host old-content)
          (etaf--runtime-lower-semantic-host-content-input
           host new-content))))

(defun etaf--runtime-restore-component-overlay-retry
    (runtime retry-effect-ids)
  "Restore failed RUNTIME overlay work for RETRY-EFFECT-IDS."
  (etaf--runtime-clear-dirty-effects runtime)
  (dolist (effect-id retry-effect-ids)
    (etaf--runtime-enqueue-effect runtime effect-id))
  (etaf--runtime-dispose-created-candidate runtime)
  (etaf--runtime-rollback-behaviors runtime)
  (etaf--runtime-clear-candidate runtime))

(defun etaf--runtime-component-overlay (runtime)
  "Publish RUNTIME Component, Range and Host effects in one candidate."
  (cl-block etaf--runtime-component-overlay
    (let* ((etaf--computed-snapshot-observer
             (lambda (computed) (etaf--runtime-snapshot-computed runtime computed)))
           (old (etaf-runtime-current-generation runtime))
         (queued-effect-ids
          (copy-sequence (etaf-runtime-dirty-effect-queue runtime)))
         (retry-effect-ids
          (cl-remove-if-not
           (lambda (effect-id)
             (etaf--generation-effect old effect-id))
           queued-effect-ids))
         range-changes inline-changes host-property-semantics host-changes
         journal resource-journal candidate-generation semantic-candidate
         participant)
    (let ((evaluation-completed-p nil))
      (unwind-protect
          (progn
            (etaf--runtime-begin-component-overlay runtime old)
    ;; A source notification can race a generation promotion and leave an old
    ;; effect id in the FIFO.  Keep the dirty-id set and FIFO coherent before
    ;; sorting; stale ids are retired by the candidate generation cleanup.
    (dolist (effect-id queued-effect-ids)
      (unless (etaf--generation-effect old effect-id)
        (remhash effect-id (etaf-runtime-dirty-effect-ids runtime))))
    (setf (etaf-runtime-dirty-effect-queue runtime)
          (etaf--runtime-sort-dirty-effects old retry-effect-ids)
          (etaf-runtime-dirty-effect-queue-tail runtime)
          (last (etaf-runtime-dirty-effect-queue runtime)))
    (while (etaf-runtime-dirty-effect-queue runtime)
      (let* ((effect-id (etaf--runtime-pop-effect runtime))
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
                 (not (memq (etaf--generation-effect-semantic-id effect)
                            (etaf-runtime-candidate-removed-semantic-ids runtime)))
                 (etaf--runtime-scheduled-semantic-live-p
                  old effect base-semantic))
            (progn
              (etaf--runtime-record-effect-input-version
               runtime old effect-id)
              (unless (and (memq (etaf--generation-effect-kind effect)
                                 '(range fragment slot inline))
                           (etaf--runtime-range-effect-staged-p runtime old effect))
                (pcase (etaf--generation-effect-kind effect)
                  ('component-input
                   (etaf--runtime-evaluate-component-input runtime semantic)
                   ;; Input evaluation may enqueue the Component render while
                   ;; lower-priority inline/Range effects are already waiting
                   ;; in this turn.  Restore the priority order immediately
                   ;; so the render observes the final input before those
                   ;; effects can seed a stale candidate.
                   (setf (etaf-runtime-dirty-effect-queue runtime)
                         (etaf--runtime-sort-dirty-effects
                          old
                          (etaf-runtime-dirty-effect-queue runtime))
                         (etaf-runtime-dirty-effect-queue-tail runtime)
                         (last (etaf-runtime-dirty-effect-queue runtime)))
                   ;; Finish this input's render before already queued child
                   ;; work.  The ancestor-aware sort also preserves this order
                   ;; when both input and render were queued initially.
                   (let ((render-id
                          (etaf--semantic-component-effect-id semantic)))
                     (when (gethash render-id
                                    (etaf-runtime-dirty-effect-ids runtime))
                       (setf (etaf-runtime-dirty-effect-queue runtime)
                             (cons
                              render-id
                              (delq render-id
                                   (etaf-runtime-dirty-effect-queue runtime)))
                             (etaf-runtime-dirty-effect-queue-tail runtime)
                             (last (etaf-runtime-dirty-effect-queue runtime))))))
                  ('component-render
                   (unless (member (etaf--semantic-component-identity semantic)
                                   (etaf-runtime-candidate-rendered-identities
                                    runtime))
                     (etaf--runtime-render-dirty-component runtime semantic)))
                  ('host-properties
                   (let ((host (etaf--runtime-render-dirty-host-properties
                                runtime effect semantic)))
                     (cond
                      ((eq host :root-fallback)
                       (cl-return-from etaf--runtime-component-overlay :root-fallback))
                      (host (push host host-property-semantics)))))
                  ((or 'range 'fragment)
                   (push (etaf--runtime-render-dirty-range
                          runtime effect semantic)
                         range-changes))
                  ('slot
                   (push (etaf--runtime-render-dirty-slot-range
                          runtime effect semantic)
                         range-changes))
                  ('inline
                   (etaf--runtime-render-dirty-inline-range
                    runtime effect semantic)))))
          ;; A route can deliver an effect queued by the previous generation
          ;; after that semantic subtree has already been removed.  Retire the
          ;; effect from the next generation instead of evaluating a nil owner.
          (cl-pushnew effect-id
                      (etaf-runtime-candidate-removed-effect-ids runtime)
                      :test #'eql))))
            (setq evaluation-completed-p t))
        (unless evaluation-completed-p
          (etaf--runtime-restore-component-overlay-retry
           runtime retry-effect-ids))))
    ;; Lowering can reject a value after the render effects have completed.
    ;; Keep that preparation inside the same retry boundary as evaluation.
    (condition-case error-data
        (progn
          (setq range-changes
                (append (nreverse
                         (etaf-runtime-candidate-eager-range-changes runtime))
                        range-changes))
          (setq range-changes
                (cl-remove-if
                 (lambda (change)
                   (ebox-canonical-input-equal-p
                    (nth 2 change) (nth 3 change)))
                 range-changes))
          ;; A parent render may render nested Components without scheduling their
          ;; effects separately.  Collect all accepted output owners, then compose
          ;; their publication from the final graph rather than intermediate trees.
          (dolist (identity (etaf-runtime-candidate-rendered-identities runtime))
            (when-let* ((component (etaf--generation-semantic old identity))
                        (range (etaf--generation-component-output-range old component)))
              (push (list range) range-changes)))
          (dolist (host-id (etaf-runtime-candidate-inline-host-ids runtime))
            (push (etaf--runtime-stage-inline-host runtime old host-id) inline-changes))
          (setq candidate-generation (etaf--runtime-build-generation runtime old)
                range-changes (etaf--runtime-normalize-range-changes
                               runtime old candidate-generation range-changes))
          ;; Only final attached owners may publish.  A descendant can have staged
          ;; work before another owner removes its enclosing branch in this turn.
          (setq range-changes
                (cl-remove-if-not
                 (lambda (change)
                   (etaf--pvec-get
                    (etaf-generation-semantic-nodes candidate-generation)
                    (etaf--semantic-backend-range-semantic-id (car change))))
                 range-changes)
                inline-changes
                (cl-remove-if-not
                 (lambda (change)
                   (etaf--pvec-get
                    (etaf-generation-semantic-nodes candidate-generation)
                    (etaf--semantic-host-semantic-id (car change))))
                 inline-changes))
          (dolist (host (nreverse host-property-semantics))
            (when (etaf--pvec-get
                   (etaf-generation-semantic-nodes candidate-generation)
                   (etaf--semantic-host-semantic-id host))
              (let* ((semantic-id (etaf--semantic-host-semantic-id host))
                     (old-host
                      (etaf--pvec-get (etaf-generation-semantic-nodes old)
                                      semantic-id)))
                (unless
                    (equal-including-properties
                     (etaf--semantic-host-props-signature old-host)
                     (etaf--semantic-host-props-signature host))
                  (push
                   (list old-host
                         (etaf--runtime-lower-semantic-host-shallow old-host)
                         (etaf--runtime-lower-semantic-host-shallow host))
                   host-changes)))))
          (setq host-changes (nreverse host-changes))
          (setq semantic-candidate
                (etaf--runtime-new-semantic-candidate
                 runtime candidate-generation)))
      ((error quit)
       (etaf--runtime-restore-component-overlay-retry runtime retry-effect-ids)
       (signal (car error-data) (cdr error-data))))
    (condition-case err
        (progn
          (setq resource-journal
                (etaf--runtime-preinstall-resources
                 runtime old candidate-generation)
                participant
                (etaf--generation-participant-create
                 :runtime runtime :semantic-candidate semantic-candidate)
                journal
                (etaf--runtime-prearm-generation runtime candidate-generation))
          (etaf--runtime-bind-semantic-inverse-journal
           semantic-candidate runtime resource-journal journal)
          (if (and (null range-changes)
                   (cl-every
                    (lambda (change)
                      (equal-including-properties
                       (nth 1 change) (nth 2 change)))
                    inline-changes)
                   (null host-changes))
              (etaf--runtime-participant-publish participant)
            (let ((candidate
                   (ebox-candidate-begin (etaf-runtime-buffer runtime))))
              (dolist (change range-changes)
                (let ((range (car change)))
                  (if (and (etaf--semantic-range-p range)
                           (eq (etaf--semantic-range-kind range) 'root))
                      (ebox-candidate-replace-root candidate (nth 3 change))
                    (ebox-candidate-replace-range-ref
                     candidate (etaf--semantic-backend-range-ref range)
                     (nth 3 change)))))
              (dolist (change inline-changes)
                (ebox-candidate-replace-host-ref
                 candidate (etaf--semantic-host-host-ref (car change))
                 (nth 2 change)))
              (dolist (change host-changes)
                (ebox-candidate-update-host-properties
                 candidate (etaf--semantic-host-host-ref (car change))
                 (nth 1 change) (nth 2 change)))
              (etaf-render-port-update
               (etaf-runtime-buffer runtime) candidate
               (lambda (_report)
                 (etaf--runtime-participant-publish participant))
               (lambda (_report)
                 (etaf--runtime-participant-rollback participant))))))
      ((error quit)
       (when semantic-candidate
         (etaf-semantic-candidate-rollback semantic-candidate)
         (etaf--runtime-rollback-semantic-inverse-journal
          semantic-candidate))
       (etaf--runtime-rollback-prearm runtime journal)
       (etaf--runtime-rollback-resource-journal runtime resource-journal)
       (etaf--runtime-restore-component-overlay-retry
        runtime retry-effect-ids)
       (signal (car err) (cdr err))))
    (etaf--runtime-participant-commit participant)
    (let ((retirement
           (etaf--runtime-new-retirement-journal
            runtime (etaf-semantic-candidate-candidate-id semantic-candidate)))
          updated first-condition public-condition)
      (cl-labels
          ((run-step
            (kind function)
            (when-let* ((condition
                         (etaf--runtime-run-postcommit-step
                          retirement 'component-overlay kind function)))
              (unless first-condition
                (setq first-condition condition)))))
        (run-step
         'generation-completion
         (lambda ()
           (etaf--runtime-complete-generation runtime)))
        (run-step
         'generation-mirror-projection
         (lambda ()
           (etaf--runtime-install-generation-mirrors
            runtime candidate-generation nil)))
        (etaf--runtime-clear-dirty-effects runtime)
        (run-step 'prop-input-notification
                  (lambda () (etaf--runtime-accept-prop-inputs runtime)))
        (unwind-protect
            (progn
              (run-step
               'lifecycle-preparation
               (lambda ()
                 ;; Local Component and Range updates acquire the same
                 ;; Behavior resources as Root renders.  Promote them before
                 ;; candidate disposal and before mounted hooks may enqueue
                 ;; another update, preserving reuse and teardown ownership.
                 (etaf--runtime-promote-behaviors runtime retirement)
                 (etaf--runtime-retire-detached-components
                  runtime old candidate-generation retirement)
                 (dolist (instance (etaf-runtime-candidate-created runtime))
                   (setf (etaf--component-instance-mounted-p instance) t))
                 (dolist (entry (etaf--generation-index-entries
                                 candidate-generation 'lifecycle))
                   (let ((identity (car entry)))
                     (when-let*
                         ((semantic (etaf--generation-semantic old identity))
                          (instance
                           (gethash
                            (etaf--semantic-component-resource-key semantic)
                            (etaf-runtime-resource-registry runtime))))
                       (push instance updated))))
                 (etaf--runtime-run-lifecycle
                  runtime
                 (list (etaf-runtime-candidate-created runtime)
                        (nreverse updated))
                  retirement)))
              (run-step 'primitive-preparation
                        (lambda () (etaf--host-update-reset runtime)))
              (setq public-condition
                    (etaf--runtime-drain-retirement runtime retirement t))
              (when-let* ((condition (or first-condition public-condition)))
                (etaf-retirement-resignal condition retirement)))
          (etaf--runtime-clear-candidate runtime)))))))

(defun etaf--runtime-render-effect (runtime)
  "Build and publish one Root-owned candidate for RUNTIME."
  (setf (etaf-runtime-candidate-full-rebuild-p runtime) t)
  (let ((etaf--computed-snapshot-observer
         (lambda (computed) (etaf--runtime-snapshot-computed runtime computed)))
        (old-generation (etaf-runtime-current-generation runtime))
        (retry-effect-ids (copy-sequence (etaf-runtime-dirty-effect-queue runtime)))
        next-root root-node candidate-generation semantic-candidate
        journal resource-journal participant)
    (condition-case err
        (let* ((source-builder (ebox-source-builder-create))
               (etaf--render-runtime runtime)
               (etaf--ebox-source-builder source-builder)
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
          (setq root-node
                (etaf--ebox-forest-root
                 nodes
                 (list 'etaf-runtime-root
                       (etaf-runtime-mount-epoch runtime)))
                next-root
                (ebox-canonical-input-create
                 (list root-node)
                 (ebox-source-builder-finish source-builder)))
          (setq candidate-generation
                (etaf--runtime-build-generation runtime old-generation)
                semantic-candidate
                (etaf--runtime-new-semantic-candidate
                 runtime candidate-generation)
                resource-journal (etaf--runtime-preinstall-resources
                                  runtime old-generation candidate-generation)
                participant (etaf--generation-participant-create
                             :runtime runtime
                             :semantic-candidate semantic-candidate)
                journal
                (etaf--runtime-prearm-generation runtime candidate-generation))
          (etaf--runtime-bind-semantic-inverse-journal
           semantic-candidate runtime resource-journal journal)
          (if old-generation
              (let ((candidate (ebox-candidate-begin
                                (etaf-runtime-buffer runtime))))
                (ebox-candidate-replace-root candidate next-root)
                (etaf-render-port-update
                 (etaf-runtime-buffer runtime) candidate
                 (lambda (_report)
                   (etaf--runtime-participant-publish participant))
                 (lambda (_report)
                   (etaf--runtime-participant-rollback participant))))
            (let ((host-authority (etaf-runtime-host-authority runtime)))
              (etaf-render-port-initial
               (etaf-runtime-buffer runtime) next-root
               (lambda (_report)
                 (etaf--runtime-participant-publish participant)
                 (etaf-host-authority-stage-attach host-authority))
               (lambda (_report)
                 (etaf-host-authority-rollback-attach host-authority)
                 (etaf--runtime-participant-rollback participant))
               (and (etaf-runtime-observer runtime)
                    #'etaf--runtime-forward-ebox-report))
              (etaf-host-authority-finish-attach host-authority))))
      ((error quit)
       (when semantic-candidate
         (etaf-semantic-candidate-rollback semantic-candidate)
         (etaf--runtime-rollback-semantic-inverse-journal
          semantic-candidate))
       (etaf--runtime-rollback-prearm runtime journal)
       (etaf--runtime-rollback-resource-journal runtime resource-journal)
       (etaf--runtime-clear-dirty-effects runtime)
       ;; Application refs are not rolled back with a failed publication.
       ;; Keep their committed-generation work pending for the repaired input.
       (dolist (effect-id retry-effect-ids)
         (when (etaf--generation-effect old-generation effect-id)
           (etaf--runtime-enqueue-effect runtime effect-id)))
       (etaf--runtime-dispose-created-candidate runtime)
       (etaf--runtime-rollback-behaviors runtime)
       (etaf--runtime-clear-candidate runtime)
       (signal (car err) (cdr err))))
    (etaf--runtime-participant-commit participant)
    ;; Publication has completed.  Lifecycle and cleanup callbacks run after
    ;; the retained state is promoted; their errors remain visible without
    ;; incorrectly rolling back an already published Ebox tree.
    (let ((retirement
           (etaf--runtime-new-retirement-journal
            runtime (etaf-semantic-candidate-candidate-id semantic-candidate)))
          groups first-condition public-condition)
      (cl-labels
          ((run-step
            (kind function)
            (when-let* ((condition
                         (etaf--runtime-run-postcommit-step
                          retirement 'root-render kind function)))
              (unless first-condition
                (setq first-condition condition)))))
        (run-step
         'generation-completion
         (lambda ()
           (etaf--runtime-complete-generation runtime)))
        (run-step
         'generation-mirror-projection
         (lambda ()
           (etaf--runtime-install-generation-mirrors
            runtime candidate-generation t)))
        (setf (etaf-runtime-root-dirty-p runtime) nil)
        (etaf--runtime-clear-dirty-effects runtime)
        (run-step 'prop-input-notification
                  (lambda () (etaf--runtime-accept-prop-inputs runtime)))
        (unwind-protect
            (progn
              (run-step
               'authority-retirement-preparation
               (lambda ()
                 (setq groups (etaf--runtime-promote runtime retirement))
                 (etaf--runtime-promote-behaviors runtime retirement)
                 (etaf--runtime-run-lifecycle runtime groups retirement)))
              (run-step 'primitive-preparation
                        (lambda () (etaf--host-update-reset runtime)))
              (setq public-condition
                    (etaf--runtime-drain-retirement runtime retirement t))
              (when-let* ((condition (or first-condition public-condition)))
                (etaf-retirement-resignal condition retirement)))
          (etaf--runtime-rollback-behaviors runtime)
          (etaf--runtime-clear-candidate runtime))))
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

(defun etaf--runtime-request-flush-now (runtime)
  "Flush RUNTIME now, or mark one follow-up flush while busy."
  (let ((etaf--scheduler-context
         (or (etaf-runtime-scheduler-context runtime)
             etaf-scheduler-default-context)))
    (when (etaf-runtime-mounted-p runtime)
    (cond
     ((or (> (etaf-runtime-event-depth runtime) 0)
          (etaf-runtime-flushing-p runtime))
      (setf (etaf-runtime-pending-p runtime) t))
     ((and (progn (etaf--runtime-settle-source-effects runtime) t)
           (not (etaf-runtime-root-dirty-p runtime))
           (null (etaf-runtime-dirty-effect-queue runtime)))
      (setf (etaf-runtime-pending-p runtime) nil))
     ((etaf--host-update-try-flush runtime))
     (t
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
          (setf (etaf-runtime-flushing-p runtime) nil))))))))

(defun etaf--runtime-request-flush (runtime)
  "Flush RUNTIME within one optional Runtime operation boundary."
  (if (or (etaf-runtime-observer runtime) etaf--observer-context)
      (etaf--runtime-with-operation (runtime 'flush "reactive flush")
        (etaf--runtime-request-flush-now runtime))
    (etaf--runtime-request-flush-now runtime)))

;;;###autoload
(defun etaf-runtime-flush (&optional runtime)
  "Request mounted RUNTIME's pending work and return its committed revision.
This returns an integer, not an Ebox node.  Busy or batched work may remain
pending; the result identifies the currently committed Ebox publication.
An active Ebox transaction is rejected before requesting work, because
its current revision may still be provisional.  No tree is exported.
Use `etaf-runtime-snapshot' for an explicit snapshot."
  (let ((runtime (etaf-runtime-require-mounted runtime)))
    (when (ebox-transaction-active-p)
      (signal 'etaf-runtime-error
              (list "Cannot flush inside an active Ebox transaction")))
    ;; A retry can publish lifecycle hooks without arriving through source
    ;; dispatch.  Keep their writes in the same projection so follow-up work
    ;; drains after the currently publishing Runtime releases its busy guard.
    (etaf-scheduler-call-with-projection (etaf-runtime-flush-function runtime))
    (etaf-render-port-revision (etaf-runtime-buffer runtime))))

;;;###autoload
(defun etaf-runtime-snapshot (&optional runtime)
  "Export mounted RUNTIME's currently committed Ebox snapshot.
Return a plist with `:input' (a canonical Ebox input), `:revision', and
`:mount-id'.  The export costs O(N), detaches mutable node payload, and keeps
opaque callback identities.  It neither drains pending work nor evaluates
Components, publishes, or increments the revision.  Unmounted Runtimes and
reads inside an Ebox transaction signal an error."
  (let ((runtime (etaf-runtime-require-mounted runtime)))
    (etaf-render-port-snapshot (etaf-runtime-buffer runtime))))

(eval-and-compile
  ;; Hot reload must also remove the former cl-defstruct accessor's inliner
  ;; and setter metadata.  Future callers must execute the explicit query.
  (dolist (property '(compiler-macro gv-expander gv-setter
                     side-effect-free pure document-generalized-variable))
    (cl-remprop 'etaf-runtime-root-node property)))

(defun etaf-runtime-root-node (runtime)
  "Return RUNTIME's current root through an explicit detached snapshot.
This obsolete read-compatible getter costs O(N); no root mirror is stored.
Use `etaf-runtime-snapshot' to retain the root's matching source facts."
  (declare (obsolete etaf-runtime-snapshot "2026-09-06"))
  (let ((roots (ebox-canonical-input-roots
                (plist-get (etaf-runtime-snapshot runtime) :input))))
    (unless (and roots (null (cdr roots)))
      (signal 'etaf-runtime-error
              (list "Mounted Ebox snapshot must contain one root")))
    (car roots)))

(defun etaf--runtime-mount-now
    (buffer-or-name view observer &optional scheduler-context)
  "Mount VIEW into BUFFER-OR-NAME with OBSERVER and SCHEDULER-CONTEXT."
  (setq scheduler-context
        (or scheduler-context etaf-scheduler-default-context))
  (let ((etaf--scheduler-context scheduler-context))
    (let* ((buffer (get-buffer-create buffer-or-name))
         (old (gethash buffer etaf--runtime-table)))
    (when old
      (etaf-runtime-unmount old))
    (let* ((scope (etaf-effect-scope
                   :detached t :name buffer
                   :scheduler-context scheduler-context))
           (mount-epoch (cl-incf etaf--mount-epoch-counter))
           (host-authority
            (etaf-host-authority-create
             (list 'etaf-runtime mount-epoch) mount-epoch buffer))
           (runtime (etaf--runtime-create
                     :buffer buffer
                     :root-view view
                     :scope scope
                     :scheduler-context scheduler-context
                     :instances (make-hash-table :test #'equal)
                     :resource-registry (make-hash-table :test #'equal)
                     :mount-epoch mount-epoch
                     :host-authority host-authority
                     :next-resource-id 0
                     :next-effect-id 0
                     :next-semantic-id 1
                     :generation-authority
                     (etaf-generation-authority-create)
                     :root-effect-id 0
                     :root-range-id 1
                     :range-artifact-registry (make-hash-table :test #'equal)
                     :candidate-range-artifacts (make-hash-table :test #'eql)
                     :route-sources (make-hash-table :test #'eq)
                     :dirty-effect-ids (make-hash-table :test #'eql)
                     :handlers (make-hash-table :test #'equal)
                     :host-props (make-hash-table :test #'equal)
                     :host-geometry-region-ids (make-hash-table :test #'equal)
                     :theme-paint-slots (make-hash-table :test #'eq)
                     :behaviors (make-hash-table :test #'equal)
                     :behavior-resource-keys (make-hash-table :test #'equal)
                     :observer observer
                     :root-dirty-p t)))
      (setf (etaf-runtime-flush-function runtime)
            (lambda () (etaf--runtime-request-flush runtime)))
      (etaf-host-authority-begin-attach host-authority)
      (puthash buffer runtime etaf--runtime-table)
      (with-current-buffer buffer
        (add-hook 'kill-buffer-hook #'etaf--runtime-kill-buffer nil t))
      (let ((route (etaf-runtime-route-create
                    :runtime-id (etaf-runtime-mount-epoch runtime)
                    :mount-epoch (etaf-runtime-mount-epoch runtime)
                    :authority-token
                    (etaf-host-authority-token host-authority)
                    :scheduler 'etaf--runtime-route-scheduler
                    :scheduler-context scheduler-context
                    :accepts-p 'etaf--runtime-authorized-route-runtime)))
        (setf (etaf-runtime-route-token runtime) route)
        (puthash (etaf-runtime-mount-epoch runtime) runtime
                 etaf--runtime-route-registry))
      (condition-case err
          (etaf--runtime-with-operation
              (runtime 'mount
                       (format "mount %s" (buffer-name buffer)))
            (etaf--runtime-begin-candidate runtime)
            (setf (etaf-runtime-flushing-p runtime) t
                  (etaf-runtime-root-view-cache runtime)
                  (etaf--runtime-evaluate-root-candidate runtime))
            (unwind-protect
                (etaf--runtime-render-effect runtime)
              (setf (etaf-runtime-flushing-p runtime) nil))
            (when (etaf-runtime-pending-p runtime)
              (setf (etaf-runtime-pending-p runtime) nil)
              (etaf--runtime-request-flush runtime))
            buffer)
        ((error quit)
         ;; Postaccept lifecycle errors leave an attached Runtime queryable.
         ;; Preaccept failures have no Host authority and discard registration.
         (unless (etaf-host-authority-attached-p host-authority)
           (setf (etaf-runtime-mounted-p runtime) nil)
           (when-let* ((route (etaf-runtime-route-token runtime)))
             (setf (etaf-runtime-route-active-p route) nil))
           (etaf-host-authority-rollback-attach host-authority)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (remove-hook 'kill-buffer-hook
                            #'etaf--runtime-kill-buffer t)))
           (remhash buffer etaf--runtime-table)
           (remhash (etaf-runtime-mount-epoch runtime)
                    etaf--runtime-route-registry)
           (etaf-scope-stop scope))
         (signal (car err) (cdr err))))
      buffer))))

(defun etaf--runtime-validate-mount-options (options)
  "Validate and return mount OPTIONS."
  (let ((tail options))
    (while tail
      (let ((key (pop tail)))
        (unless tail
          (error "ETAF mount option %S has no value" key))
        (pop tail)
        (unless (memq key '(:viewport-width :viewport-height :observer
                            :scheduler-context))
          (error "Unknown ETAF mount option: %S" key)))))
  (when-let* ((width (plist-get options :viewport-width)))
    (unless (and (numberp width) (> width 0))
      (error "ETAF mount :viewport-width must be positive: %S" width)))
  (when-let* ((height (plist-get options :viewport-height)))
    (unless (and (numberp height) (> height 0))
      (error "ETAF mount :viewport-height must be positive: %S" height)))
  (when (and (plist-member options :observer)
             (not (or (null (plist-get options :observer))
                      (functionp (plist-get options :observer)))))
    (signal 'wrong-type-argument
            (list 'functionp (plist-get options :observer))))
  (when (and (plist-member options :scheduler-context)
             (not (etaf-scheduler-context-p
                   (plist-get options :scheduler-context))))
    (signal 'wrong-type-argument
            (list 'etaf-scheduler-context-p
                  (plist-get options :scheduler-context))))
  options)

;;;###autoload
(defun etaf-runtime-mount (buffer-or-name view &optional options)
  "Mount VIEW into BUFFER-OR-NAME and return the live buffer.
Setup, reactive publication, Ebox rendering, and lifecycle work share one
framework render-burst allocation budget when the installed Ebox supports it.
OPTIONS may provide `:viewport-width' in pixels, `:viewport-height' in lines,
`:observer' as a one-argument flat-report sink, and `:scheduler-context' for
explicit dispatch isolation.  The observer is installed before publication."
  (etaf--assert-not-rendering 'mount-runtime)
  (setq options (etaf--runtime-validate-mount-options options))
  (let ((ebox-viewport-width (plist-get options :viewport-width))
        (ebox-viewport-height (plist-get options :viewport-height)))
    (ebox-call-with-render-burst
     #'etaf--runtime-mount-now buffer-or-name view
     (plist-get options :observer)
     (or (plist-get options :scheduler-context)
         etaf-scheduler-default-context))))

(defun etaf--runtime-unmount-now (runtime &optional cause)
  "Unmount RUNTIME idempotently and retire its Component scopes.
CAUSE is `buffer-kill' for the contained dead-buffer path, or nil for explicit
unmount.  Host authority is invalidated before any unbounded cleanup."
  (unless (etaf-runtime-p runtime)
    (signal 'wrong-type-argument (list 'etaf-runtime-p runtime)))
  (if (not (etaf-runtime-mounted-p runtime))
      runtime
    (let* ((authority (etaf-runtime-host-authority runtime))
           (retirement
            (etaf--runtime-new-retirement-journal
             runtime
             (list 'host-detach
                   (etaf-runtime-mount-epoch runtime)
                   (etaf-host-authority-version authority)))))
      (when (etaf-host-authority-attached-p authority)
        (etaf-host-authority-begin-detach authority))
      (unless (eq (etaf-host-authority-state authority) 'terminal)
        (etaf-host-authority-invalidate authority))
      (when-let* ((route (etaf-runtime-route-token runtime)))
        (setf (etaf-runtime-route-active-p route) nil))
      ;; Invalidation is the one-way boundary for every queued/in-flight
      ;; delivery.  Clear pending work at that same boundary so a Runtime
      ;; retained by a buffer-kill hook cannot advertise an impossible tail
      ;; after its route and buffer are dead.
      (setf (etaf-runtime-mounted-p runtime) nil
            (etaf-runtime-pending-p runtime) nil)
      (unwind-protect
          (progn
            (when (buffer-live-p (etaf-runtime-buffer runtime))
              (with-current-buffer (etaf-runtime-buffer runtime)
                (remove-hook 'kill-buffer-hook #'etaf--runtime-kill-buffer t)))
            (unless (eq cause 'buffer-kill)
              (when (etaf-render-port-mounted-p
                     (etaf-runtime-buffer runtime))
                (let ((buffer (etaf-runtime-buffer runtime)))
                  (etaf-retirement-enqueue
                   retirement
                   :owner (list 'ebox (etaf-runtime-mount-epoch runtime))
                   :kind 'ebox-unmount
                   :payload (lambda () (etaf-render-port-unmount buffer))
                   :ordering-key '(0 0)
                   :policy 'retryable-idempotent
                   :max-attempts 2))))
            (remhash (etaf-runtime-buffer runtime) etaf--runtime-table)
            (remhash (etaf-runtime-mount-epoch runtime)
                     etaf--runtime-route-registry)
            (maphash
             (lambda (source _)
               (remhash (etaf-runtime-route-token runtime)
                        (etaf--source-subscribers source)))
             (etaf-runtime-route-sources runtime))
            (clrhash (etaf-runtime-route-sources runtime))
            (let (instances)
              (maphash (lambda (_identity instance) (push instance instances))
                       (etaf-runtime-instances runtime))
              (cl-loop
               for instance in
               (sort instances
                     (lambda (left right)
                       (> (length (etaf--component-instance-identity left))
                          (length
                           (etaf--component-instance-identity right)))))
               for index from 0
               do
               (remhash (etaf--component-instance-identity instance)
                        (etaf-runtime-instances runtime))
               (remhash (etaf--component-instance-resource-key instance)
                        (etaf-runtime-resource-registry runtime))
               (etaf--runtime-dispose-instance
                runtime instance t retirement (list 1 index))))
            (let ((scope (etaf-runtime-scope runtime)))
              (etaf-retirement-enqueue
               retirement
               :owner (list 'runtime-scope
                            (etaf-runtime-mount-epoch runtime))
               :kind 'runtime-scope-stop
               :payload
               (lambda ()
                 (when-let* ((errors (etaf-scope-stop scope)))
                   (signal (caar errors) (cdar errors))))
               :ordering-key '(8 0)
               :policy 'contained-once
               :max-attempts 1))
            (let (behavior-entries)
            (maphash
             (lambda (identity state)
                 (push (cons identity state) behavior-entries))
               (etaf-runtime-behaviors runtime))
              (clrhash (etaf-runtime-behaviors runtime))
              (cl-loop for entry in behavior-entries
                       for index from 0
                       do
                       (when-let* ((resource-key
                                   (gethash
                                    (car entry)
                                    (etaf-runtime-behavior-resource-keys
                                     runtime))))
                         (remhash resource-key
                                  (etaf-runtime-resource-registry runtime)))
                       (when-let* ((cleanup (cdr (cdr entry))))
                         (let ((callback cleanup))
                           (etaf-retirement-enqueue
                            retirement
                            :owner (copy-tree (car entry))
                            :kind 'behavior-unmount
                            :payload callback
                            :ordering-key (list 7 index)
                            :policy 'retryable-idempotent
                            :max-attempts 2)))))
            (clrhash (etaf-runtime-instances runtime))
            (clrhash (etaf-runtime-resource-registry runtime))
            (etaf--runtime-drain-retirement
             runtime retirement (eq cause 'buffer-kill))
            runtime)
        (etaf-host-authority-finish-detach authority)))))

;;;###autoload
(defun etaf-runtime-unmount (&optional runtime)
  "Unmount RUNTIME, report the operation, and detach its observer."
  (etaf--assert-not-rendering 'unmount-runtime)
  (let* ((runtime (etaf-runtime-require-mounted runtime))
         (observer (etaf-runtime-observer runtime))
         (buffer (etaf-runtime-buffer runtime)))
    (unwind-protect
        (etaf--runtime-with-operation (runtime 'unmount "unmount")
          (etaf--runtime-unmount-now runtime))
      (when observer
        (condition-case condition
            (when (buffer-live-p buffer)
              (ebox-buffer-set-observer buffer nil))
          ((error quit)
           (etaf--runtime-record-observer-diagnostic
            runtime (list :kind 'detach-failure :condition condition))))
        (setf (etaf-runtime-observer runtime) nil)))))

;;;###autoload
(defun etaf-unmount (&optional runtime)
  "Unmount RUNTIME, defaulting to the active or `current-buffer' Runtime."
  (etaf-runtime-unmount runtime))

;;;###autoload
(defun etaf-on-mounted (callback)
  "Run CALLBACK after the current Component is first published."
  (unless (functionp callback)
    (signal 'wrong-type-argument (list 'functionp callback)))
  (unless (and etaf--current-component-instance
               (eq etaf--component-phase 'setup))
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
  (unless (and etaf--current-component-instance
               (eq etaf--component-phase 'setup))
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
  (unless (and etaf--current-component-instance
               (eq etaf--component-phase 'setup))
    (error "ETAF-on-unmounted requires Component setup"))
  (push callback
        (etaf--component-instance-unmounted-hooks
         etaf--current-component-instance))
  callback)

(provide 'etaf-runtime)

;;; etaf-runtime.el ends here
