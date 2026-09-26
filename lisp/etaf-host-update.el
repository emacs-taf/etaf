;;; etaf-host-update.el --- Prepared retained Host property updates -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Bind registered reactive Host and inline programs at the settled-generation
;; control boundary.  A ready Host evaluates its
;; existing property programs and publishes through Ebox without reconstructing
;; Views, semantic candidates or property plists.  The committed generation
;; owns the reusable property cells; this module introduces no display authority.
;; Ordinary publication rebuilds the primitive cohort before later input.

;;; Code:

(require 'cl-lib)
(require 'etaf-runtime)

(cl-defstruct (etaf--host-update (:constructor etaf--host-update-create))
  runtime generation semantic inline effect effect-id properties getters values
  provider-values class-projection
  cells old-values guards changed-p dependencies dependency-seen evaluate-function
  enter-function check-dependency queue-node consumed-versions
  ancestor-readers ancestor-writers ancestor-values artifact-keys artifact-values
  old-generation-id old-token old-composition-version old-inline-version staged-p
  lifecycle-instance lifecycle-indices lifecycle-p guard-indices)

(defconst etaf--host-update-geometry-properties
  '(:left :top :width :height :min-width :max-width :min-height :max-height
    :z-index)
  "Geometry holes eligible for preparation by the provider.")

(defconst etaf--host-update-properties
  (append etaf--host-update-geometry-properties
          '(:color :background-color :hover-content :class :border :font-weight
            :visibility))
  "Primitive Host properties eligible for retained provider publication.")

(declare-function etaf--host-cohort-try-flush "etaf-host-cohort" (runtime))
(declare-function etaf--host-cohort-collect "etaf-host-cohort" (runtime))
(declare-function etaf--host-cohort-schedule "etaf-host-cohort" (runtime))

(defun etaf--host-update-value-cell (plist property)
  "Return the retained value cell for PROPERTY in PLIST, or nil."
  (while (and plist (not (eq (car plist) property)))
    (setq plist (cddr plist)))
  (cdr plist))

(defun etaf--host-update-backend-cell (props property)
  "Return PROPERTY's canonical value cell within backend PROPS."
  (etaf--host-update-value-cell
   (if (eq property :hover-content) (plist-get props :interactions) props) property))

(defun etaf--host-update-direct-value-p (property value previous)
  "Return whether VALUE preserves PROPERTY's prepared PREVIOUS value form."
  (cond
   ((memq property '(:color :background-color))
    (or (null value) (stringp value) (ebox-paint-slot-p value)))
   ((memq property '(:hover-content :content))
    (or (null value) (stringp value)))
   ;; These forms only describe the caller's scalar inputs.  The provider
   ;; additionally proves finite selector variants, fixed border geometry,
   ;; and measured normal/bold equivalence before admitting the binding.
   ((eq property :class)
    (or (null value) (stringp value) (symbolp value) (proper-list-p value)))
   ((eq property :font-weight) (memq value '(normal bold)))
   ((eq property :visibility) (memq value '(visible hidden)))
   ((eq property :border)
    (and (proper-list-p value) (= (length value) 3)
         (proper-list-p previous) (= (length previous) 3)
         (equal (car value) (car previous))
         (eq (cadr value) (cadr previous))
         (stringp (nth 2 value))))
   ((eq property :z-index) (integerp value))
   (t (if (and (consp previous) (consp (cdr previous))
             (null (cddr previous)) (numberp (cadr previous)))
        (and (consp value) (eq (car previous) (car value))
             (consp (cdr value)) (null (cddr value))
             (numberp (cadr value)))
        (equal value previous)))))

(defun etaf--host-update-queue-cell (runtime effect-id)
  "Return RUNTIME's reusable FIFO cell for prepared EFFECT-ID, or nil."
  (when-let* ((table (etaf-runtime-prepared-host-updates runtime))
              (update (gethash effect-id table))
              ((etaf--host-update-p update)))
    (etaf--host-update-queue-node update)))

(defun etaf--host-update-environment (runtime effect-id)
  "Return the cold-bound environment entry for RUNTIME EFFECT-ID, if present."
  (when (eq (etaf-runtime-prepared-host-generation runtime)
            (etaf-runtime-current-generation runtime))
    (when-let* ((table (etaf-runtime-prepared-host-updates runtime))
                (update (gethash effect-id table))
                ((etaf--host-update-p update)))
      (etaf--host-update-enter-function update))))

(defun etaf--host-update-write (update values)
  "Write VALUES into UPDATE's already bound committed property cells."
  (if-let* ((inline (etaf--host-update-inline update)))
      (setf (etaf--semantic-inline-range-output inline) (aref values 0)
            (etaf--semantic-host-content (etaf--host-update-semantic update))
            (aref values 0))
    (let ((cells (etaf--host-update-cells update)))
    (dotimes (index (length cells))
      (let ((targets (aref cells index)) (value (aref values index)))
        (dotimes (target (length targets))
          (setcar (aref targets target) value)))))))

(defun etaf--host-update-stage (update &optional grouped-p)
  "Stage UPDATE's scalar state in its single committed authority."
  (let* ((runtime (etaf--host-update-runtime update))
         (generation (etaf--host-update-generation update))
         (semantic (etaf--host-update-semantic update))
         (authority (etaf-runtime-generation-authority runtime))
         (inhibit-quit t))
    (unless (eq generation (etaf-runtime-current-generation runtime))
      (signal 'etaf-generation-conflict '(prepared-host-generation)))
    (setf (etaf--host-update-old-generation-id update)
          (etaf-generation-generation-id generation)
          (etaf--host-update-old-token update)
          (etaf-generation-authority-token authority)
          (etaf--host-update-old-composition-version update)
          (etaf--semantic-host-composition-version semantic)
          (etaf--host-update-staged-p update) t)
    (etaf--host-update-write update (etaf--host-update-values update))
    (when-let* ((inline (etaf--host-update-inline update)))
      (setf (etaf--host-update-old-inline-version update)
            (etaf--semantic-inline-range-composition-version inline))
      (cl-incf (etaf--semantic-inline-range-composition-version inline)))
    (dotimes (index (length (etaf--host-update-ancestor-readers update)))
      (let ((value (funcall (aref (etaf--host-update-ancestor-readers update)
                                  index))))
        (aset (etaf--host-update-ancestor-values update) index value)
        (funcall (aref (etaf--host-update-ancestor-writers update) index)
                 (1+ value))))
    (let ((registry (etaf-runtime-range-artifact-registry runtime)))
      (dotimes (index (length (etaf--host-update-artifact-keys update)))
        (let ((key (aref (etaf--host-update-artifact-keys update) index)))
          (aset (etaf--host-update-artifact-values update) index
                (gethash key registry 'etaf-host-update-missing))
          (puthash key :invalid registry))))
    (unless grouped-p
      (cl-incf (etaf-generation-generation-id generation))
      (cl-incf (etaf-generation-authority-token authority)))
    (cl-incf (etaf--semantic-host-composition-version semantic))))

(defun etaf--host-update-rollback (update)
  "Restore UPDATE's previously committed scalar state after rejection."
  (when (etaf--host-update-staged-p update)
    (etaf--host-update-write update (etaf--host-update-old-values update))
    (when-let* ((inline (etaf--host-update-inline update)))
      (setf (etaf--semantic-inline-range-composition-version inline)
            (etaf--host-update-old-inline-version update)))
    (dotimes (index (length (etaf--host-update-ancestor-writers update)))
      (funcall (aref (etaf--host-update-ancestor-writers update) index)
               (aref (etaf--host-update-ancestor-values update) index)))
    (let ((registry (etaf-runtime-range-artifact-registry
                     (etaf--host-update-runtime update))))
      (dotimes (index (length (etaf--host-update-artifact-keys update)))
        (let ((key (aref (etaf--host-update-artifact-keys update) index))
              (value (aref (etaf--host-update-artifact-values update) index)))
          (if (eq value 'etaf-host-update-missing)
              (remhash key registry)
            (puthash key value registry)))))
    (setf (etaf-generation-generation-id
           (etaf--host-update-generation update))
          (etaf--host-update-old-generation-id update)
          (etaf-generation-authority-token
           (etaf-runtime-generation-authority
            (etaf--host-update-runtime update)))
          (etaf--host-update-old-token update)
          (etaf--semantic-host-composition-version
           (etaf--host-update-semantic update))
          (etaf--host-update-old-composition-version update)
          (etaf--host-update-staged-p update) nil)))

(defconst etaf--host-update-theme-token-properties '(:color :background-color)
  "Properties whose expressions may publish a Theme token as its paint slot.")

(defun etaf--host-update-token-binding-p (property base resolved backend)
  "Whether PROPERTY's Theme-token BASE is prepared through RESOLVED and BACKEND."
  (and (memq property etaf--host-update-theme-token-properties)
       (etaf-theme-token-p base)
       (equal-including-properties resolved backend)))

(defun etaf--host-update-paint-value (update property value)
  "Return VALUE for PROPERTY as UPDATE publishes it.
A Theme token lowers to the paint slot that ordinary publication installed
for it; a token without an installed slot declines to that path."
  (if (not (etaf-theme-token-p value))
      value
    (let* ((etaf--context-inject-recorder nil)
           (source (etaf--theme-source))
           (resolved (etaf--theme-token-resolve-from-source value source))
           (paint (etaf--runtime-installed-theme-paint-value
                   (etaf--host-update-runtime update) property value source
                   resolved)))
      (when (eq paint etaf--runtime-missing-paint)
        (throw 'etaf-host-update-declined nil))
      paint)))

(defun etaf--host-update-evaluate (update)
  "Evaluate UPDATE's bound getters into its reusable value vector."
  (let ((getters (etaf--host-update-getters update))
        (values (etaf--host-update-values update))
        (old (etaf--host-update-old-values update))
        (cells (etaf--host-update-cells update))
        (etaf--runtime-dependency-collector
         (etaf--host-update-check-dependency update))
        (etaf--context-inject-recorder #'etaf--host-update-decline-context)
        (etaf--active-effect nil)
        (etaf--render-phase-p t))
    (setf (etaf--host-update-changed-p update) nil
          (etaf--host-update-lifecycle-p update) nil)
    (fillarray (etaf--host-update-dependency-seen update) nil)
    ;; Theme and style sources feed the Host through transforms that no
    ;; property getter re-runs.  A prepared write is valid only while every
    ;; such guarded source still holds the version this binding was built on.
    (let* ((effect (etaf--host-update-effect update))
           (versions (etaf--generation-effect-dependency-versions effect))
           (deps (etaf--generation-effect-deps effect))
           (indices (etaf--host-update-guard-indices update)))
      (dotimes (position (length indices))
        (let* ((index (aref indices position))
               (source (nth index deps)))
          (when (or (and (etaf-computed-p source) (etaf-computed-dirty-p source))
                    (/= (aref versions index) (etaf--source-version source)))
            (throw 'etaf-host-update-declined nil)))))
    (dotimes (index (length (etaf--host-update-guards update)))
      (let* ((guard (aref (etaf--host-update-guards update) index))
             (next (etaf--resolve-property-value (car guard)))
             (previous (car (cdr guard))))
        (unless (if (and (stringp next) (stringp previous))
                    (equal-including-properties next previous)
                  (etaf--runtime-target-value-equal-p next previous))
          (throw 'etaf-host-update-declined nil))))
    (dotimes (index (length getters))
      (aset old index (car (aref (aref cells index) 0)))
      (aset values index
            (etaf--host-update-paint-value
             update (aref (etaf--host-update-properties update) index)
             (etaf--resolve-property-value (aref getters index))))
      (unless (etaf--host-update-direct-value-p
               (aref (etaf--host-update-properties update) index)
               (aref values index) (aref old index))
        (throw 'etaf-host-update-declined nil))
      (let ((provider-values (etaf--host-update-provider-values update)))
        (if (eq (aref (etaf--host-update-properties update) index) :class)
            (let ((projection (gethash (aref values index)
                                       (etaf--host-update-class-projection update))))
              (unless projection (throw 'etaf-host-update-declined nil))
              (aset provider-values index (cdr projection)))
          (unless (eq provider-values values)
            (aset provider-values index (aref values index)))))
      (unless (equal-including-properties (aref old index) (aref values index))
        (setf (etaf--host-update-changed-p update) t)))
    ;; Native hover content previously belonged to the enclosing Component
    ;; render.  Preserve that owner's participation when its own inputs
    ;; changed, even if the resulting native text happens to compare equal.
    (let* ((effect (etaf--host-update-effect update))
           (versions (etaf--generation-effect-dependency-versions effect))
           (indices (etaf--host-update-lifecycle-indices update))
           (deps (etaf--generation-effect-deps effect)))
      (dotimes (position (length indices))
        (let ((index (aref indices position)))
          (unless (= (aref versions index) (etaf--source-version (nth index deps)))
            (setf (etaf--host-update-lifecycle-p update) t
                  (etaf--host-update-changed-p update) t)))))
    (dotimes (index (length (etaf--host-update-dependency-seen update)))
      (unless (aref (etaf--host-update-dependency-seen update) index)
        (throw 'etaf-host-update-declined nil))))
  t)

(defun etaf--host-update-capture-versions (update)
  "Capture UPDATE's evaluated dependency versions before publication callbacks."
  (let ((versions (etaf--host-update-consumed-versions update)) (index 0))
    (dolist (source (etaf--generation-effect-deps (etaf--host-update-effect update)))
      (aset versions index (etaf--source-version source))
      (setq index (1+ index)))))

(defun etaf--host-update-evaluate-inline (update)
  "Evaluate UPDATE's sole inline program into retained text publication cells."
  (let* ((inline (etaf--host-update-inline update))
         (old (etaf--semantic-inline-range-output inline))
         (etaf--runtime-dependency-collector
          (etaf--host-update-check-dependency update))
         (etaf--context-inject-recorder #'etaf--host-update-decline-context)
         (etaf--active-effect nil)
         (etaf--render-phase-p t)
         output)
    (fillarray (etaf--host-update-dependency-seen update) nil)
    (setq output
          (etaf--runtime-inline-value-string
           (funcall (aref (etaf--host-update-getters update) 0)) nil))
    (aset (etaf--host-update-old-values update) 0 old)
    (setf (etaf--host-update-changed-p update)
          (not (equal-including-properties old output)))
    (setf (etaf--host-update-lifecycle-p update) (etaf--host-update-changed-p update))
    (aset (etaf--host-update-values update) 0
          (if (etaf--host-update-changed-p update) (copy-sequence output) old))
    (dotimes (index (length (etaf--host-update-dependency-seen update)))
      (unless (aref (etaf--host-update-dependency-seen update) index)
        (throw 'etaf-host-update-declined nil))))
  t)

(defun etaf--host-update-decline-context (_frame _key)
  "Send a newly observed Context dependency through ordinary preparation."
  (throw 'etaf-host-update-declined nil))

(defun etaf--host-update-bind-invalidations (update)
  "Compile UPDATE's enclosing artifact invalidations once at preparation."
  (let* ((generation (etaf--host-update-generation update))
         (nodes (etaf-generation-semantic-nodes generation))
         (parent-id (etaf--semantic-host-parent-id
                     (etaf--host-update-semantic update)))
         readers writers keys)
    (while (and parent-id (> parent-id 0))
      (let ((record (etaf--pvec-get nodes parent-id)))
        (cond
         ((etaf--semantic-host-p record)
          (push (lambda () (etaf--semantic-host-composition-version record))
                readers)
          (push (lambda (value)
                  (setf (etaf--semantic-host-composition-version record) value))
                writers))
         ((etaf--semantic-component-p record)
          (push (lambda () (etaf--semantic-component-composition-version record))
                readers)
          (push (lambda (value)
                  (setf (etaf--semantic-component-composition-version record)
                        value)) writers))
         ((or (etaf--semantic-range-p record)
              (etaf--semantic-slot-range-p record))
          (unless (and (etaf--semantic-range-p record)
                       (eq (etaf--semantic-range-kind record) 'root))
            (push (etaf--semantic-backend-range-artifact-key record) keys))))
        (setq parent-id (etaf--semantic-parent-id record))))
    (setf (etaf--host-update-ancestor-readers update) (vconcat readers)
          (etaf--host-update-ancestor-writers update) (vconcat writers)
          (etaf--host-update-ancestor-values update)
          (make-vector (length readers) nil)
          (etaf--host-update-artifact-keys update) (vconcat keys)
          (etaf--host-update-artifact-values update)
          (make-vector (length keys) nil))))

(defun etaf--host-update-bind-evaluator (update)
  "Bind UPDATE's committed Component environment on the cold path."
  (let* ((runtime (etaf--host-update-runtime update))
         (component-id
          (if (etaf--host-update-inline update)
              (etaf--semantic-inline-range-component-id (etaf--host-update-inline update))
            (etaf--semantic-host-component-id (etaf--host-update-semantic update))))
         (component
          (and component-id
               (etaf--pvec-get
                (etaf-generation-semantic-nodes
                 (etaf--host-update-generation update)) component-id)))
         (instance
          (and component
               (gethash (etaf--semantic-component-resource-key component)
                        (etaf-runtime-resource-registry runtime))))
         (state (and instance (etaf--component-instance-state instance)))
         (setup-defined
          (and instance (etaf--component-spec-setup
                         (etaf--component-instance-spec instance))))
         (setup-complete
          (and instance (etaf--component-instance-setup-complete-p instance)))
         (identity (and component (etaf--semantic-component-identity component)))
         (props (and component (etaf--semantic-component-props component)))
         (slots (and component (etaf--semantic-component-slots component)))
         (context (and instance (etaf--component-instance-context instance))))
    (when (> (length (etaf--host-update-lifecycle-indices update)) 0)
      (setf (etaf--host-update-lifecycle-instance update) instance))
    (setf (etaf--host-update-enter-function update)
          (lambda (function argument)
            (let ((etaf--current-runtime runtime)
                  (etaf--render-runtime runtime)
                  (etaf--current-component-instance instance)
                  (etaf--current-component-state state)
                  (etaf--current-component-setup-defined-p setup-defined)
                  (etaf--current-component-setup-complete-p setup-complete)
                  (etaf--current-component-identity identity)
                  (etaf--current-component-semantic-id component-id)
                  (etaf--current-component-props props)
                  (etaf--current-component-slots slots)
                  (etaf--component-phase 'render)
                  (etaf--current-context context))
              (funcall function argument))))
    (let ((enter (etaf--host-update-enter-function update))
          (evaluate (if (etaf--host-update-inline update)
                        #'etaf--host-update-evaluate-inline #'etaf--host-update-evaluate)))
      (setf (etaf--host-update-evaluate-function update)
            (lambda () (funcall enter evaluate update))))))

(defun etaf--host-update-bind (runtime generation effect semantic)
  "Bind one primitive Host EFFECT on SEMANTIC in RUNTIME GENERATION."
  (let* ((all-bindings (etaf--semantic-host-property-bindings semantic))
         (bindings
          (cl-remove-if-not
           (lambda (binding)
             (memq (etaf--host-property-binding-property binding)
                   etaf--host-update-properties))
           all-bindings))
         (dependencies (etaf--semantic-host-property-deps semantic))
         (effect-deps (etaf--generation-effect-deps effect))
         (guard-indices
          (let ((index -1) indices)
            (dolist (source effect-deps)
              (setq index (1+ index))
              (unless (memq source dependencies) (push index indices)))
            (vconcat (nreverse indices)))))
    (when (and bindings
               (null (etaf--semantic-host-context-deps semantic))
               (cl-every (lambda (source) (memq source effect-deps))
                         dependencies)
               ;; Extra Host sources are Theme/style transforms.  They are
               ;; guarded by version at evaluation instead of re-run.
               (cl-every (lambda (source)
                           (or (memq source dependencies)
                               (etaf-ref-p source) (etaf-computed-p source)))
                         effect-deps)
               ;; A prepared write cannot bypass Theme/default transforms or
               ;; restore several different declarations from one scalar.
               ;; A paint Theme token is the one transform evaluation
               ;; replays, through the token's installed paint slot.
               (cl-every
                (lambda (binding)
                  (let* ((property (etaf--host-property-binding-property binding))
                         (base (plist-get (etaf--semantic-host-base-props semantic)
                                          property))
                         (resolved (plist-get
                                    (etaf--semantic-host-resolved-props semantic)
                                    property))
                         (backend (car (etaf--host-update-backend-cell
                                        (etaf--semantic-host-props-signature semantic)
                                        property))))
                    (or (and (equal base resolved)
                             (equal-including-properties base backend))
                        (etaf--host-update-token-binding-p
                         property base resolved backend))))
                bindings))
      (let* ((host-ref (etaf--semantic-host-host-ref semantic))
             (properties (vconcat (mapcar
                                   #'etaf--host-property-binding-property
                                   bindings)))
             (count (length properties))
             (update
              (etaf--host-update-create
               :runtime runtime :generation generation :semantic semantic
               :effect effect :effect-id (etaf--generation-effect-effect-id effect)
               :properties properties
               :getters (vconcat (mapcar
                                  #'etaf--host-property-binding-expression
                                  bindings))
               :values (make-vector count nil)
               :old-values (make-vector count nil)
               :cells (make-vector count nil)
               :dependencies dependencies
               :dependency-seen (make-vector (length dependencies) nil)
               :consumed-versions (make-vector (length effect-deps) 0)
               :guard-indices guard-indices
               :queue-node (list (etaf--generation-effect-effect-id effect)))))
        ;; Detach only the property spines in this cold preparation.  Getter
        ;; results, callbacks and reactive sources retain their identities.
        (setf (etaf--semantic-host-base-props semantic)
              (copy-sequence (etaf--semantic-host-base-props semantic))
              (etaf--semantic-host-resolved-props semantic)
              (copy-sequence (etaf--semantic-host-resolved-props semantic))
              (etaf--semantic-host-props-signature semantic)
              (copy-sequence (etaf--semantic-host-props-signature semantic)))
        (when (cl-position :hover-content properties)
          (setf (etaf--semantic-host-props-signature semantic)
                (plist-put
                 (etaf--semantic-host-props-signature semantic) :interactions
                 (copy-sequence
                  (plist-get (etaf--semantic-host-props-signature semantic) :interactions)))))
        ;; An absent class is equivalent to nil metadata.  Style declarations
        ;; are different: a nil length/font value must remain omitted, because
        ;; adding it would change the canonical input's validation semantics.
        (dotimes (slot count)
          (let ((property (aref properties slot)))
            (when (and (eq property :class)
                       (not (plist-member (etaf--semantic-host-props-signature semantic) property)))
              (setf (etaf--semantic-host-props-signature semantic)
                    (plist-put (etaf--semantic-host-props-signature semantic) property nil)))))
        (let* ((index (etaf-generation-indexes generation))
               (props (etaf--generation-index-lookup
                       generation 'host-props host-ref))
               (public (and props (copy-sequence props)))
               (mirror (and props (copy-sequence props)))
               (sources
                (delq nil
                      (list (etaf--semantic-host-base-props semantic)
                            (etaf--semantic-host-resolved-props semantic)
                            public mirror))))
          (when props
            (setf (etaf--contribution-index-host-props index)
                  (cons (cons host-ref public)
                        (assoc-delete-all
                         host-ref
                         (copy-sequence
                          (etaf--contribution-index-host-props index)))))
            (puthash host-ref mirror (etaf-runtime-host-props runtime)))
          (dotimes (slot count)
            (let ((property (aref properties slot)) targets)
              (when-let* ((cell (etaf--host-update-backend-cell
                                (etaf--semantic-host-props-signature semantic) property)))
                (push cell targets))
              (dolist (source sources)
                (when-let* ((cell (etaf--host-update-value-cell source property)))
                  (push cell targets)))
              (aset (etaf--host-update-cells update) slot (vconcat targets)))))
        (setf (etaf--host-update-guards update)
              (vconcat
               (cl-loop for binding in all-bindings
                        unless (memq binding bindings)
                        collect
                        (cons (etaf--host-property-binding-expression binding)
                              (etaf--host-update-value-cell
                               (etaf--semantic-host-base-props semantic)
                               (etaf--host-property-binding-property binding))))))
        (etaf--host-update-bind-invalidations update)
        (setf (etaf--host-update-provider-values update) (etaf--host-update-values update))
        (let ((deps (etaf--generation-effect-deps effect)) indices)
          (dolist (binding bindings)
            (when (eq (etaf--host-property-binding-property binding) :hover-content)
              (dolist (source (etaf--host-property-binding-dependencies binding))
                (when-let* ((index (cl-position source deps :test #'eq)))
                  (cl-pushnew index indices)))))
          (setf (etaf--host-update-lifecycle-indices update) (vconcat indices)))
        (etaf--host-update-bind-evaluator update)
        (etaf--host-update-bind-dependencies update)
        update))))

(defun etaf--host-update-bind-dependencies (update)
  "Compile UPDATE's stable source membership guard."
  (let ((indexes (make-hash-table :test #'eq))
        (seen (etaf--host-update-dependency-seen update))
        (ordinal 0))
    (dolist (source (etaf--host-update-dependencies update))
      (puthash source ordinal indexes)
      (setq ordinal (1+ ordinal)))
    (setf (etaf--host-update-check-dependency update)
          (lambda (source)
            (let ((index (gethash source indexes)))
              (unless index (throw 'etaf-host-update-declined nil))
              (aset seen index t))))))

(defun etaf--host-update-bind-inline (runtime generation effect inline)
  "Bind one sole INLINE text program for EFFECT in RUNTIME GENERATION."
  (let* ((host (etaf--pvec-get
                (etaf-generation-semantic-nodes generation)
                (etaf--semantic-inline-range-parent-id inline)))
         (parts (and (etaf--semantic-host-p host)
                     (etaf--semantic-host-content-parts host)))
         (deps (etaf--generation-effect-deps effect)))
    (when (and (null (etaf--semantic-inline-range-context-deps inline))
               (= (length parts) 1)
               (eql (car parts) (etaf--semantic-inline-range-semantic-id inline)))
      (let* ((component-id (etaf--semantic-inline-range-component-id inline))
             (component (and component-id
                             (etaf--pvec-get
                              (etaf-generation-semantic-nodes generation)
                              component-id)))
             (update
              (etaf--host-update-create
               :runtime runtime :generation generation :semantic host :inline inline
               :effect effect :effect-id (etaf--generation-effect-effect-id effect)
               :properties [:content]
               :getters (vector (etaf--expr-thunk (etaf--generation-effect-target effect)))
               :values (vector nil) :old-values (vector nil)
               :dependencies deps :dependency-seen (make-vector (length deps) nil)
               :consumed-versions (make-vector (length deps) 0)
               :queue-node (list (etaf--generation-effect-effect-id effect))
               :lifecycle-instance
               (and component
                    (gethash (etaf--semantic-component-resource-key component)
                             (etaf-runtime-resource-registry runtime))))))
        (etaf--host-update-bind-invalidations update)
        (setf (etaf--host-update-provider-values update) (etaf--host-update-values update))
        (etaf--host-update-bind-evaluator update)
        (etaf--host-update-bind-dependencies update)
        update))))

(defun etaf--host-update-reset (runtime)
  "Rebind RUNTIME's registered primitive programs at a publication boundary.
This control-plane operation completes before mounted or updated hooks run.
It never evaluates application getters or creates unused computed branches.
Binding the semantic members is cheap; compiling them into the provider's
retained scene is not, so `etaf--host-cohort-collect' only records the member
pool and `etaf--host-cohort-schedule' compiles it when Emacs is idle or the
first sparse flush needs it."
  (if (etaf-runtime-prepared-host-updates runtime)
      (clrhash (etaf-runtime-prepared-host-updates runtime))
    (setf (etaf-runtime-prepared-host-updates runtime)
          (make-hash-table :test #'eql)))
  (unless (etaf-runtime-prepared-host-variants runtime)
    (setf (etaf-runtime-prepared-host-variants runtime)
          (make-hash-table :test #'equal)))
  (setf (etaf-runtime-prepared-host-generation runtime)
        (etaf-runtime-current-generation runtime)
        (etaf-runtime-prepared-host-cohort runtime) nil
        (etaf-runtime-prepared-host-binding-token runtime) nil
        (etaf-runtime-prepared-host-rejections runtime)
        (make-hash-table :test #'eql))
  (etaf--host-cohort-collect runtime)
  (etaf--host-cohort-schedule runtime))

(defun etaf--host-update-for-effect (runtime effect-id)
  "Return or prepare RUNTIME's ready operation for dirty EFFECT-ID only."
  (let* ((generation (etaf-runtime-current-generation runtime))
         (effect (etaf--generation-effect generation effect-id)))
    (when (and effect
               (memq (etaf--generation-effect-kind effect) '(host-properties inline)))
      (unless (eq generation (etaf-runtime-prepared-host-generation runtime))
        (etaf--host-update-reset runtime))
      (let* ((table (etaf-runtime-prepared-host-updates runtime))
             (cached (gethash effect-id table)))
        (cond
         ((eq cached 'unsupported) nil)
         (cached cached)
         (t
          (let* ((semantic (etaf--generation-effect-semantic generation effect-id))
                 (update
                  (if (etaf--semantic-host-p semantic)
                      (etaf--host-update-bind runtime generation effect semantic)
                    (and (etaf--semantic-inline-range-p semantic)
                         (etaf--host-update-bind-inline
                          runtime generation effect semantic)))))
            (puthash effect-id (or update 'unsupported) table)
            update)))))))

(defun etaf--host-update-newer-input-p (update)
  "Whether UPDATE received newer input after its evaluated version snapshot.
A dirty computed is pending even before its value version advances; leave its
getter to the next settlement boundary rather than reading during acceptance."
  (let ((deps (etaf--generation-effect-deps (etaf--host-update-effect update)))
        (versions (etaf--host-update-consumed-versions update))
        (index 0) newer)
    (while (and deps (not newer))
      (let ((source (pop deps)))
        (setq newer (or (and (etaf-computed-p source) (etaf-computed-dirty-p source))
                        (/= (aref versions index) (etaf--source-version source))))
        (setq index (1+ index))))
    newer))

(defun etaf--host-update-consume (update &optional pending-p)
  "Accept UPDATE's evaluated dependency snapshot after publication."
  (let ((versions (etaf--generation-effect-dependency-versions
                   (etaf--host-update-effect update)))
        (consumed (etaf--host-update-consumed-versions update)))
    (dotimes (index (length versions))
      (aset versions index (aref consumed index))))
  (setf (etaf--host-update-staged-p update) nil)
  (unless pending-p
    (remhash (etaf--host-update-effect-id update)
             (etaf-runtime-dirty-effect-ids (etaf--host-update-runtime update)))))

(defun etaf--host-update-try-flush (runtime)
  "Publish ready primitive RUNTIME work through its existing bound cohort."
  (etaf--host-cohort-try-flush runtime))

(provide 'etaf-host-update)
;;; etaf-host-update.el ends here
