;;; etaf-scheduler.el --- Explicit reactive dispatcher contexts -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Owns ETAF's cross-source dispatch queues.  Contexts isolate FIFO and dedupe
;; authority, while a short-lived projection coordinates fan-out across every
;; context touched by one logical reactive publication.

;;; Code:

(require 'cl-lib)

(define-error 'etaf-scheduler-error "Invalid ETAF scheduler operation")

(defgroup etaf-scheduler nil
  "Explicit ETAF reactive dispatcher contexts."
  :group 'applications
  :prefix "etaf-scheduler-")

(defcustom etaf-scheduler-default-step-budget 128
  "Maximum dispatcher turns one context may run in one projection."
  :type 'positive-integer
  :group 'etaf-scheduler)

(defvar etaf-scheduler--context-id-counter 0)
(defvar etaf-scheduler--projection-id-counter 0)

(cl-defstruct
    (etaf-scheduler-context
     (:constructor etaf-scheduler-context--create))
  "Mutable queues and diagnostics for one isolated dispatcher."
  id name
  source-queue source-queue-tail source-set
  deferred-source-queue deferred-source-queue-tail deferred-source-set
  delivered-source-set
  runtime-queue runtime-queue-tail runtime-set
  effect-set
  (active-turn-id 0)
  (projection-epoch 0)
  (completed-projection-epoch 0)
  (depth 0)
  (event-depth 0)
  (busy-depth 0)
  phase
  fixed-point-step-budget
  fault-state diagnostics
  (source-enqueue-count 0)
  (source-dedupe-count 0)
  (source-delivery-count 0)
  (subscriber-visit-count 0)
  (effect-claim-count 0)
  (effect-evaluation-count 0)
  (runtime-enqueue-count 0)
  (runtime-dedupe-count 0)
  (runtime-execution-count 0)
  (stale-route-drop-count 0)
  (projection-fault-count 0)
  (turn-count 0))

(cl-defstruct
    (etaf-scheduler--projection
     (:constructor etaf-scheduler--projection-create))
  "One cross-context reactive projection."
  id all-contexts all-context-set context-before finalizers
  completion-observers)

(cl-defun etaf-scheduler-context-create (&key name fixed-point-step-budget)
  "Create an isolated scheduler context named NAME.
FIXED-POINT-STEP-BUDGET is optional diagnostic metadata for its owner."
  (when (and fixed-point-step-budget
             (not (and (integerp fixed-point-step-budget)
                       (> fixed-point-step-budget 0))))
    (signal 'etaf-scheduler-error
            (list :invalid-fixed-point-step-budget fixed-point-step-budget)))
  (etaf-scheduler-context--create
   :id (cl-incf etaf-scheduler--context-id-counter)
   :name name
   :source-set (make-hash-table :test #'eq)
   :deferred-source-set (make-hash-table :test #'eq)
   :delivered-source-set (make-hash-table :test #'eq)
   :runtime-set (make-hash-table :test #'eq)
   :effect-set (make-hash-table :test #'eq)
   :fixed-point-step-budget
   (or fixed-point-step-budget etaf-scheduler-default-step-budget)))

(defvar etaf-scheduler-default-context
  (etaf-scheduler-context-create :name 'default)
  "Default scheduler context used by the compatibility facade.")

(defvar etaf--scheduler-context nil
  "Dynamically active scheduler context, or nil for the default context.")

(defvar etaf-scheduler--active-projection nil
  "Dynamically active cross-context projection.")

(defvar etaf-scheduler-projection-observer nil
  "Optional function receiving each completed projection summary.")

(defun etaf-scheduler-current-context ()
  "Return the dynamically active scheduler context or the default context."
  (or etaf--scheduler-context etaf-scheduler-default-context))

(defun etaf-scheduler-context-resolve (context)
  "Return validated CONTEXT, defaulting nil to the current context."
  (setq context (or context (etaf-scheduler-current-context)))
  (unless (etaf-scheduler-context-p context)
    (signal 'wrong-type-argument
            (list 'etaf-scheduler-context-p context)))
  context)

(defun etaf-scheduler-call-with-context (context function)
  "Call FUNCTION with CONTEXT as the active scheduler context."
  (setq context (etaf-scheduler-context-resolve context))
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (cl-incf (etaf-scheduler-context-depth context))
  (let ((etaf--scheduler-context context))
    (unwind-protect
        (funcall function)
      (setf (etaf-scheduler-context-depth context)
            (max 0 (1- (etaf-scheduler-context-depth context)))))))

(defun etaf-scheduler-context-event-begin (context)
  "Increment CONTEXT's logical event nesting depth."
  (setq context (etaf-scheduler-context-resolve context))
  (cl-incf (etaf-scheduler-context-event-depth context))
  context)

(defun etaf-scheduler-context-event-end (context)
  "Decrement CONTEXT's logical event nesting depth."
  (setq context (etaf-scheduler-context-resolve context))
  (setf (etaf-scheduler-context-event-depth context)
        (max 0 (1- (etaf-scheduler-context-event-depth context))))
  context)

(defun etaf-scheduler--append-context (projection context)
  "Register CONTEXT with PROJECTION once."
  (unless (gethash context
                   (etaf-scheduler--projection-all-context-set projection))
    (puthash context t
             (etaf-scheduler--projection-all-context-set projection))
    (puthash context (etaf-scheduler-context-metrics context)
             (etaf-scheduler--projection-context-before projection))
    (push context (etaf-scheduler--projection-all-contexts projection))))

(defun etaf-scheduler--append-source (context source)
  "Append SOURCE to CONTEXT's FIFO in constant time."
  (let ((cell (list source)))
    (if (etaf-scheduler-context-source-queue-tail context)
        (setcdr (etaf-scheduler-context-source-queue-tail context) cell)
      (setf (etaf-scheduler-context-source-queue context) cell))
    (setf (etaf-scheduler-context-source-queue-tail context) cell)))

(defun etaf-scheduler--append-runtime (context runtime)
  "Append RUNTIME to CONTEXT's FIFO in constant time."
  (let ((cell (list runtime)))
    (if (etaf-scheduler-context-runtime-queue-tail context)
        (setcdr (etaf-scheduler-context-runtime-queue-tail context) cell)
      (setf (etaf-scheduler-context-runtime-queue context) cell))
    (setf (etaf-scheduler-context-runtime-queue-tail context) cell)))

(defun etaf-scheduler--append-deferred-source (context source)
  "Append SOURCE to CONTEXT's following-turn FIFO."
  (let ((cell (list source)))
    (if (etaf-scheduler-context-deferred-source-queue-tail context)
        (setcdr
         (etaf-scheduler-context-deferred-source-queue-tail context) cell)
      (setf (etaf-scheduler-context-deferred-source-queue context) cell))
    (setf (etaf-scheduler-context-deferred-source-queue-tail context) cell)))

(defun etaf-scheduler--enqueue-source-now
    (projection context source delivery)
  "Enqueue SOURCE and DELIVERY in CONTEXT under PROJECTION."
  (etaf-scheduler--append-context projection context)
  (let ((set (etaf-scheduler-context-source-set context))
        (deferred-set
         (etaf-scheduler-context-deferred-source-set context)))
    (cond
     ((or (gethash source set) (gethash source deferred-set))
      (cl-incf (etaf-scheduler-context-source-dedupe-count context)))
     ((and (eq (etaf-scheduler-context-phase context) 'source)
           (gethash source
                    (etaf-scheduler-context-delivered-source-set context)))
      (puthash source delivery deferred-set)
      (etaf-scheduler--append-deferred-source context source)
      (cl-incf (etaf-scheduler-context-source-enqueue-count context)))
     (t
      (puthash source delivery set)
      (etaf-scheduler--append-source context source)
      (cl-incf (etaf-scheduler-context-source-enqueue-count context))))))

(defun etaf-scheduler--enqueue-runtime-now
    (projection context runtime function)
  "Enqueue RUNTIME and FUNCTION in CONTEXT under PROJECTION."
  (etaf-scheduler--append-context projection context)
  (let ((set (etaf-scheduler-context-runtime-set context)))
    (if (gethash runtime set)
        (cl-incf (etaf-scheduler-context-runtime-dedupe-count context))
      (puthash runtime function set)
      (etaf-scheduler--append-runtime context runtime)
      (cl-incf (etaf-scheduler-context-runtime-enqueue-count context)))))

(defun etaf-scheduler-enqueue-source (context source delivery)
  "Queue DELIVERY of SOURCE once in CONTEXT for the active projection.
DELIVERY receives CONTEXT, SOURCE, and the projection epoch."
  (setq context (etaf-scheduler-context-resolve context))
  (unless (functionp delivery)
    (signal 'wrong-type-argument (list 'functionp delivery)))
  (if etaf-scheduler--active-projection
      (etaf-scheduler--enqueue-source-now
       etaf-scheduler--active-projection context source delivery)
    (etaf-scheduler-call-with-projection
     (lambda ()
       (etaf-scheduler--enqueue-source-now
        etaf-scheduler--active-projection context source delivery))))
  source)

(defun etaf-scheduler-enqueue-runtime (context runtime function)
  "Queue FUNCTION once for RUNTIME in CONTEXT after source delivery."
  (setq context (etaf-scheduler-context-resolve context))
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (if etaf-scheduler--active-projection
      (etaf-scheduler--enqueue-runtime-now
       etaf-scheduler--active-projection context runtime function)
    (etaf-scheduler-call-with-projection
     (lambda ()
       (etaf-scheduler--enqueue-runtime-now
        etaf-scheduler--active-projection context runtime function))))
  runtime)

(defun etaf-scheduler-claim-effect (context effect)
  "Return non-nil after claiming EFFECT once in CONTEXT's projection."
  (setq context (etaf-scheduler-context-resolve context))
  (unless (gethash effect (etaf-scheduler-context-effect-set context))
    (puthash effect t (etaf-scheduler-context-effect-set context))
    (cl-incf (etaf-scheduler-context-effect-claim-count context))
    t))

(defun etaf-scheduler-record-subscriber-visit (context)
  "Record one subscriber visit in scheduler CONTEXT."
  (setq context (etaf-scheduler-context-resolve context))
  (when etaf-scheduler--active-projection
    (etaf-scheduler--append-context
     etaf-scheduler--active-projection context))
  (cl-incf (etaf-scheduler-context-subscriber-visit-count context)))

(defun etaf-scheduler-record-effect-evaluation (context)
  "Record one reactive effect evaluation in scheduler CONTEXT."
  (setq context (etaf-scheduler-context-resolve context))
  (when etaf-scheduler--active-projection
    (etaf-scheduler--append-context
     etaf-scheduler--active-projection context))
  (cl-incf (etaf-scheduler-context-effect-evaluation-count context)))

(defun etaf-scheduler-record-stale-route-drop (context)
  "Record one stale route filtered before fan-out in CONTEXT."
  (setq context (etaf-scheduler-context-resolve context))
  (when etaf-scheduler--active-projection
    (etaf-scheduler--append-context
     etaf-scheduler--active-projection context))
  (cl-incf (etaf-scheduler-context-stale-route-drop-count context)))

(defun etaf-scheduler-defer-finalizer (function)
  "Run FUNCTION after the active projection drains, or immediately if idle."
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (if etaf-scheduler--active-projection
      (push function
            (etaf-scheduler--projection-finalizers
             etaf-scheduler--active-projection))
    (funcall function))
  function)

(defun etaf-scheduler-projection-active-p ()
  "Return non-nil while a scheduler projection is active."
  (not (null etaf-scheduler--active-projection)))

(defun etaf-scheduler-on-projection-complete (function)
  "Call FUNCTION with the active projection summary when it completes."
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (if etaf-scheduler--active-projection
      (push function
            (etaf-scheduler--projection-completion-observers
             etaf-scheduler--active-projection))
    (funcall function nil))
  function)

(defun etaf-scheduler--reset-pending (context)
  "Discard CONTEXT's pending queues and dedupe membership."
  (setf (etaf-scheduler-context-source-queue context) nil
        (etaf-scheduler-context-source-queue-tail context) nil
        (etaf-scheduler-context-deferred-source-queue context) nil
        (etaf-scheduler-context-deferred-source-queue-tail context) nil
        (etaf-scheduler-context-runtime-queue context) nil
        (etaf-scheduler-context-runtime-queue-tail context) nil
        (etaf-scheduler-context-phase context) nil)
  (clrhash (etaf-scheduler-context-source-set context))
  (clrhash (etaf-scheduler-context-deferred-source-set context))
  (clrhash (etaf-scheduler-context-delivered-source-set context))
  (clrhash (etaf-scheduler-context-runtime-set context))
  context)

(defun etaf-scheduler--promote-deferred-sources (context)
  "Move CONTEXT's deferred sources into its following-turn FIFO."
  (let ((deferred (etaf-scheduler-context-deferred-source-queue context))
        (deferred-set
         (etaf-scheduler-context-deferred-source-set context))
        (source-set (etaf-scheduler-context-source-set context)))
    (setf (etaf-scheduler-context-deferred-source-queue context) nil
          (etaf-scheduler-context-deferred-source-queue-tail context) nil)
    (dolist (source deferred)
      (let ((delivery (gethash source deferred-set)))
        (remhash source deferred-set)
        (unless (gethash source source-set)
          (puthash source delivery source-set)
          (etaf-scheduler--append-source context source)))))
  context)

(defun etaf-scheduler--projection-contexts (projection)
  "Return PROJECTION contexts in first-touch order."
  (nreverse
   (copy-sequence (etaf-scheduler--projection-all-contexts projection))))

(defun etaf-scheduler--projection-source-work-p (projection)
  "Return non-nil when PROJECTION has pending source work."
  (cl-some #'etaf-scheduler-context-source-queue
           (etaf-scheduler--projection-contexts projection)))

(defun etaf-scheduler--projection-work-p (projection)
  "Return non-nil when PROJECTION has pending source or Runtime work."
  (cl-some
   (lambda (context)
     (or (etaf-scheduler-context-source-queue context)
         (etaf-scheduler-context-runtime-queue context)))
   (etaf-scheduler--projection-contexts projection)))

(defun etaf-scheduler--mark-turn
    (context projection-id marked-contexts context-steps)
  "Mark CONTEXT for PROJECTION-ID in MARKED-CONTEXTS and CONTEXT-STEPS."
  (unless (gethash context marked-contexts)
    (let* ((steps (1+ (gethash context context-steps 0)))
           (budget (etaf-scheduler-context-fixed-point-step-budget context)))
      (when (> steps budget)
        (signal 'etaf-scheduler-error
                (list :kind 'fixed-point-step-budget
                      :context-id (etaf-scheduler-context-id context)
                      :projection-id projection-id
                      :steps steps :budget budget)))
      (puthash context steps context-steps))
    (puthash context t marked-contexts)
    (setf (etaf-scheduler-context-projection-epoch context) projection-id)
    (clrhash (etaf-scheduler-context-delivered-source-set context))
    (clrhash (etaf-scheduler-context-effect-set context))
    (cl-incf (etaf-scheduler-context-active-turn-id context))
    (cl-incf (etaf-scheduler-context-turn-count context))))

(defun etaf-scheduler--call-context-work (context function)
  "Call FUNCTION as busy work owned by scheduler CONTEXT."
  (cl-incf (etaf-scheduler-context-busy-depth context))
  (unwind-protect
      (etaf-scheduler-call-with-context context function)
    (setf (etaf-scheduler-context-busy-depth context)
          (max 0 (1- (etaf-scheduler-context-busy-depth context))))))

(defun etaf-scheduler--drain-context-sources (context projection-id)
  "Drain one CONTEXT source turn and return its first condition.
PROJECTION-ID identifies the bounded projection owning the detached turn."
  (let ((turn (etaf-scheduler-context-source-queue context)) first-condition)
    ;; New sources discovered by TURN belong to the next bounded scheduler
    ;; turn.  Detaching the current FIFO prevents a chain of distinct source
    ;; identities from monopolizing one unbudgeted drain.
    (setf (etaf-scheduler-context-source-queue context) nil
          (etaf-scheduler-context-source-queue-tail context) nil
          (etaf-scheduler-context-phase context) 'source)
    (etaf-scheduler--call-context-work
     context
     (lambda ()
       (dolist (source turn)
         (let ((delivery
                (gethash source
                         (etaf-scheduler-context-source-set context))))
           (remhash source (etaf-scheduler-context-source-set context))
           (puthash source t
                    (etaf-scheduler-context-delivered-source-set context))
           (cl-incf (etaf-scheduler-context-source-delivery-count context))
           (when delivery
             (condition-case condition
                 (funcall delivery context source projection-id)
               ((error quit)
                (unless first-condition
                  (setq first-condition condition)))))))))
    first-condition))

(defun etaf-scheduler--detach-runtime-turns (projection)
  "Detach and return PROJECTION's Runtime queues in context order."
  (let (turns)
    (dolist (context (etaf-scheduler--projection-contexts projection))
      (when-let* ((turn (etaf-scheduler-context-runtime-queue context)))
        (setf (etaf-scheduler-context-runtime-queue context) nil
              (etaf-scheduler-context-runtime-queue-tail context) nil)
        (push (cons context turn) turns)))
    (nreverse turns)))

(defun etaf-scheduler--run-runtime-turn (context turn)
  "Run detached Runtime TURN in CONTEXT and return its first condition."
  (let (first-condition)
    (setf (etaf-scheduler-context-phase context) 'runtime)
    (etaf-scheduler--call-context-work
     context
     (lambda ()
       (dolist (runtime turn)
         (let ((function
                (gethash runtime
                         (etaf-scheduler-context-runtime-set context))))
           (remhash runtime (etaf-scheduler-context-runtime-set context))
           (when function
             (cl-incf (etaf-scheduler-context-runtime-execution-count context))
             (condition-case condition
                 (funcall function)
               ((error quit)
                (unless first-condition
                  (setq first-condition condition)))))))))
    first-condition))

(defun etaf-scheduler--record-fault
    (context projection-id condition &optional phase)
  "Record CONTEXT failure CONDITION for PROJECTION-ID and optional PHASE."
  (setf (etaf-scheduler-context-fault-state context) (copy-tree condition))
  (cl-incf (etaf-scheduler-context-projection-fault-count context))
  (push (append (list :projection-epoch projection-id
                      :turn-id
                      (etaf-scheduler-context-active-turn-id context))
                (and phase (list :phase phase))
                (list :condition (copy-tree condition)))
        (etaf-scheduler-context-diagnostics context))
  (when (> (length (etaf-scheduler-context-diagnostics context)) 64)
    (setcdr (nthcdr 63 (etaf-scheduler-context-diagnostics context)) nil))
  condition)

(defun etaf-scheduler-record-route-authority-fault (context condition)
  "Record contained Host route authority CONDITION in scheduler CONTEXT."
  (setq context (etaf-scheduler-context-resolve context))
  (unless (consp condition)
    (signal 'wrong-type-argument (list 'consp condition)))
  (when etaf-scheduler--active-projection
    (etaf-scheduler--append-context etaf-scheduler--active-projection context))
  (etaf-scheduler--record-fault
   context
   (if etaf-scheduler--active-projection
       (etaf-scheduler--projection-id etaf-scheduler--active-projection)
     (etaf-scheduler-context-projection-epoch context))
   condition 'route-authority))

(defun etaf-scheduler--drain-projection (projection)
  "Drain PROJECTION source-first and re-signal its first context fault."
  (let ((projection-id (etaf-scheduler--projection-id projection))
        (failed-contexts (make-hash-table :test #'eq))
        (context-steps (make-hash-table :test #'eq))
        first-condition)
    (while (etaf-scheduler--projection-work-p projection)
      (let ((marked-contexts (make-hash-table :test #'eq)))
        ;; All source propagation across every context settles before any
        ;; Runtime can observe and publish the resulting reactive state.
        (while (etaf-scheduler--projection-source-work-p projection)
          ;; Each source wave is one bounded turn.  A wave snapshots every
          ;; context's current FIFO, so newly discovered distinct sources
          ;; consume another step and peers get an opportunity to run.
          (setq marked-contexts (make-hash-table :test #'eq))
          (dolist (context (etaf-scheduler--projection-contexts projection))
            (cond
             ((gethash context failed-contexts)
              (etaf-scheduler--reset-pending context))
             ((etaf-scheduler-context-source-queue context)
              (condition-case condition
                  (progn
                    (etaf-scheduler--mark-turn
                     context projection-id marked-contexts context-steps)
                    (when-let* ((source-condition
                                 (etaf-scheduler--drain-context-sources
                                  context projection-id)))
                      (signal (car source-condition)
                              (cdr source-condition))))
                ((error quit)
                 (puthash context t failed-contexts)
                 (unless first-condition (setq first-condition condition))
                 (etaf-scheduler--record-fault
                  context projection-id condition)
                 (etaf-scheduler--reset-pending context)))))))
        ;; Detach every context's Runtime queue before callbacks run.  A write
        ;; from one callback therefore belongs to the following scheduler turn.
        (dolist (entry (etaf-scheduler--detach-runtime-turns projection))
          (let ((context (car entry)) (turn (cdr entry)))
            (unless (gethash context failed-contexts)
              (condition-case condition
                  (progn
                    (etaf-scheduler--mark-turn
                     context projection-id marked-contexts context-steps)
                    (when-let* ((runtime-condition
                                 (etaf-scheduler--run-runtime-turn
                                  context turn)))
                      (signal (car runtime-condition)
                              (cdr runtime-condition))))
                ((error quit)
                 (puthash context t failed-contexts)
                 (unless first-condition (setq first-condition condition))
                 (etaf-scheduler--record-fault
                  context projection-id condition)
                 (etaf-scheduler--reset-pending context))))))
        (dolist (context (etaf-scheduler--projection-contexts projection))
          (setf (etaf-scheduler-context-phase context) nil)
          (unless (gethash context failed-contexts)
            (etaf-scheduler--promote-deferred-sources context)))))
    (dolist (context (etaf-scheduler--projection-contexts projection))
      (unless (gethash context failed-contexts)
        (setf (etaf-scheduler-context-completed-projection-epoch context)
              projection-id
              (etaf-scheduler-context-fault-state context) nil)))
    (when first-condition
      (signal (car first-condition) (cdr first-condition)))))

(defun etaf-scheduler--finish-projection (projection)
  "Restore PROJECTION invariants and return contained finalizer errors."
  (let (errors)
    (dolist (context (etaf-scheduler--projection-all-contexts projection))
      (when (or (etaf-scheduler-context-source-queue context)
                (etaf-scheduler-context-deferred-source-queue context)
                (etaf-scheduler-context-runtime-queue context))
        (etaf-scheduler--reset-pending context))
      (setf (etaf-scheduler-context-phase context) nil)
      (clrhash (etaf-scheduler-context-delivered-source-set context))
      (clrhash (etaf-scheduler-context-effect-set context)))
    (let ((etaf-scheduler--active-projection nil))
      (dolist (finalizer
               (nreverse (etaf-scheduler--projection-finalizers projection)))
        (condition-case condition
            (funcall finalizer)
          ((error quit) (push condition errors)))))
    (setf (etaf-scheduler--projection-finalizers projection) nil)
    (nreverse errors)))

(defun etaf-scheduler--notify-projection-complete (projection summary)
  "Notify PROJECTION observers with detached SUMMARY, containing failures."
  (let ((etaf-scheduler--active-projection nil)
        errors)
    (when (functionp etaf-scheduler-projection-observer)
      (condition-case condition
          (funcall etaf-scheduler-projection-observer (copy-tree summary))
        ((error quit) (push condition errors))))
    (dolist
        (observer
         (nreverse
          (etaf-scheduler--projection-completion-observers projection)))
      (condition-case condition
          (funcall observer (copy-tree summary))
        ((error quit) (push condition errors))))
    (setf (etaf-scheduler--projection-completion-observers projection) nil)
    (nreverse errors)))

(defun etaf-scheduler--metric-delta (before after key)
  "Return non-negative KEY delta between BEFORE and AFTER metric plists."
  (max 0 (- (or (plist-get after key) 0)
            (or (plist-get before key) 0))))

(defun etaf-scheduler--projection-summary (projection condition)
  "Return detached PROJECTION metrics with optional failure CONDITION."
  (let ((before-table
         (etaf-scheduler--projection-context-before projection))
        context-summaries
        (source-enqueues 0) (source-dedupes 0) (source-deliveries 0)
        (subscriber-visits 0) (effect-claims 0) (effect-evaluations 0)
        (runtime-enqueues 0) (runtime-dedupes 0) (runtime-executions 0)
        (stale-route-drops 0) (turns 0) (faults 0))
    (dolist (context (etaf-scheduler--projection-contexts projection))
      (let* ((before (gethash context before-table))
             (after (etaf-scheduler-context-metrics context))
             (entry
              (list
               :context-id (etaf-scheduler-context-id context)
               :source-enqueues
               (etaf-scheduler--metric-delta
                before after :source-enqueues)
               :source-dedupes
               (etaf-scheduler--metric-delta before after :source-dedupes)
               :source-deliveries
               (etaf-scheduler--metric-delta
                before after :source-deliveries)
               :subscriber-visits
               (etaf-scheduler--metric-delta
                before after :subscriber-visits)
               :effect-claims
               (etaf-scheduler--metric-delta before after :effect-claims)
               :effect-evaluations
               (etaf-scheduler--metric-delta
                before after :effect-evaluations)
               :runtime-enqueues
               (etaf-scheduler--metric-delta before after :runtime-enqueues)
               :runtime-dedupes
               (etaf-scheduler--metric-delta before after :runtime-dedupes)
               :runtime-executions
               (etaf-scheduler--metric-delta
                before after :runtime-executions)
               :stale-route-drops
               (etaf-scheduler--metric-delta
                before after :stale-route-drops)
               :turns (etaf-scheduler--metric-delta before after :turn-count)
               :faults
               (etaf-scheduler--metric-delta before after :fault-count))))
        (cl-incf source-enqueues (plist-get entry :source-enqueues))
        (cl-incf source-dedupes (plist-get entry :source-dedupes))
        (cl-incf source-deliveries (plist-get entry :source-deliveries))
        (cl-incf subscriber-visits (plist-get entry :subscriber-visits))
        (cl-incf effect-claims (plist-get entry :effect-claims))
        (cl-incf effect-evaluations (plist-get entry :effect-evaluations))
        (cl-incf runtime-enqueues (plist-get entry :runtime-enqueues))
        (cl-incf runtime-dedupes (plist-get entry :runtime-dedupes))
        (cl-incf runtime-executions (plist-get entry :runtime-executions))
        (cl-incf stale-route-drops (plist-get entry :stale-route-drops))
        (cl-incf turns (plist-get entry :turns))
        (cl-incf faults (plist-get entry :faults))
        (push entry context-summaries)))
    (list :projection-id (etaf-scheduler--projection-id projection)
          :completed-p (null condition)
          :context-count (length context-summaries)
          :source-enqueues source-enqueues
          :source-dedupes source-dedupes
          :source-deliveries source-deliveries
          :subscriber-visits subscriber-visits
          :effect-claims effect-claims
          :effect-evaluations effect-evaluations
          :runtime-enqueues runtime-enqueues
          :runtime-dedupes runtime-dedupes
          :runtime-executions runtime-executions
          :stale-route-drops stale-route-drops
          :turns turns :faults faults
          :condition (and condition (copy-tree condition))
          :contexts (nreverse context-summaries))))

(defun etaf-scheduler-call-with-projection (function)
  "Call FUNCTION and drain all contexts touched by its reactive writes.
Nested calls join the active projection.  If FUNCTION signals after changing
state, queued notifications still drain before the original condition is
re-signaled."
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (if etaf-scheduler--active-projection
      (funcall function)
    (let* ((projection
            (etaf-scheduler--projection-create
             :id (cl-incf etaf-scheduler--projection-id-counter)
             :all-context-set (make-hash-table :test #'eq)
             :context-before (make-hash-table :test #'eq)))
           result primary-condition drain-condition summary finalizer-errors)
      (let ((etaf-scheduler--active-projection projection))
        (unwind-protect
            (progn
              (condition-case condition
                  (setq result (funcall function))
                ((error quit) (setq primary-condition condition)))
              (condition-case condition
                  (etaf-scheduler--drain-projection projection)
                ((error quit) (setq drain-condition condition)))
              (setq summary
                    (etaf-scheduler--projection-summary
                     projection drain-condition)))
          (setq finalizer-errors
                (etaf-scheduler--finish-projection projection))
          (when finalizer-errors
            (setq summary
                  (plist-put summary :completed-p nil)
                  summary
                  (plist-put summary :finalizer-errors
                             (copy-tree finalizer-errors))))
          (etaf-scheduler--notify-projection-complete
           projection summary)))
      (cond
       (primary-condition
        (signal (car primary-condition) (cdr primary-condition)))
       (drain-condition
        (signal (car drain-condition) (cdr drain-condition)))
       (t result)))))

(defun etaf-scheduler-context-idle-p (context)
  "Return non-nil when CONTEXT has no queued or running dispatcher work."
  (setq context (etaf-scheduler-context-resolve context))
  (and (null (etaf-scheduler-context-source-queue context))
       (null (etaf-scheduler-context-deferred-source-queue context))
       (null (etaf-scheduler-context-runtime-queue context))
       (zerop (hash-table-count
               (etaf-scheduler-context-source-set context)))
       (zerop (hash-table-count
               (etaf-scheduler-context-runtime-set context)))
       (zerop (etaf-scheduler-context-busy-depth context))))

(defun etaf-scheduler-context-metrics (context)
  "Return a detached metrics plist for scheduler CONTEXT."
  (setq context (etaf-scheduler-context-resolve context))
  (list :context-id (etaf-scheduler-context-id context)
        :projection-epoch (etaf-scheduler-context-projection-epoch context)
        :completed-projection-epoch
        (etaf-scheduler-context-completed-projection-epoch context)
        :active-turn-id (etaf-scheduler-context-active-turn-id context)
        :turn-count (etaf-scheduler-context-turn-count context)
        :source-enqueues
        (etaf-scheduler-context-source-enqueue-count context)
        :source-dedupes
        (etaf-scheduler-context-source-dedupe-count context)
        :source-deliveries
        (etaf-scheduler-context-source-delivery-count context)
        :subscriber-visits
        (etaf-scheduler-context-subscriber-visit-count context)
        :effect-claims
        (etaf-scheduler-context-effect-claim-count context)
        :effect-evaluations
        (etaf-scheduler-context-effect-evaluation-count context)
        :runtime-enqueues
        (etaf-scheduler-context-runtime-enqueue-count context)
        :runtime-dedupes
        (etaf-scheduler-context-runtime-dedupe-count context)
        :runtime-executions
        (etaf-scheduler-context-runtime-execution-count context)
        :stale-route-drops
        (etaf-scheduler-context-stale-route-drop-count context)
        :fault-count
        (etaf-scheduler-context-projection-fault-count context)
        :fault-state
        (copy-tree (etaf-scheduler-context-fault-state context))))

(provide 'etaf-scheduler)

;;; etaf-scheduler.el ends here
