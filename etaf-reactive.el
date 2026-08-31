;;; etaf-reactive.el --- Reactive cells and effect scopes -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ETAF has one reactive model.  Refs, computed values, watchers, component
;; renders, and external Effects all use the same dependency graph.  This
;; module deliberately knows nothing about Views, Ebox, or buffers.

;;; Code:

(require 'cl-lib)
(require 'gv)
(require 'etaf-scheduler)

(define-error 'etaf-reactive-error "Invalid ETAF reactive operation")
(define-error 'etaf-render-side-effect-error
  "ETAF render must be side-effect free"
  'etaf-reactive-error)
(define-error 'etaf-render-write-error
  "ETAF state cannot be written while rendering"
  'etaf-render-side-effect-error)

(cl-defstruct (etaf-ref
               (:constructor etaf--ref-create))
  "A writable shallow reactive cell."
  value
  test
  (version 0)
  subscribers
  source-id
  name)

(cl-defstruct (etaf-computed
               (:constructor etaf--computed-create))
  "A lazy cached reactive value."
  getter
  value
  test
  (version 0)
  subscribers
  source-id
  effect
  (dirty-p t)
  evaluated-p
  evaluating-p
  name)

(cl-defstruct (etaf-effect
               (:constructor etaf--effect-create))
  "A dependency-tracked computation owned by a Scope."
  function
  scheduler
  deps
  owner-scope
  scheduler-context
  on-stop
  name
  (active-p t)
  running-p)

(cl-defstruct (etaf-effect-scope
               (:constructor etaf--effect-scope-create))
  "A tree of effects and cleanups with one disposal boundary."
  parent
  effects
  children
  cleanups
  scheduler-context
  name
  (active-p t))

(cl-defstruct (etaf-runtime-route
               (:constructor etaf-runtime-route-create))
  "Opaque Runtime route stored by reactive sources."
  runtime-id mount-epoch authority-token scheduler scheduler-context
  accepts-p
  (active-p t))

(defvar etaf--active-effect nil
  "The effect currently collecting dependencies.")

(defvar etaf--source-id-counter 0)

(defun etaf-reactive-source-id (source)
  "Return stable integer id of reactive SOURCE."
  (cond ((etaf-ref-p source) (etaf-ref-source-id source))
        ((etaf-computed-p source) (etaf-computed-source-id source))
        (t (signal 'wrong-type-argument (list 'etaf-reactive-source-p source)))))

(defvar etaf--active-scope nil
  "The Scope that owns newly created effects and cleanups.")

(defvar etaf--tracking-enabled-p t
  "Whether reactive reads may collect dependencies.")

(defvar etaf--runtime-dependency-collector nil
  "Runtime-local collector called for each reactive source read.")

(defvar etaf--render-phase-p nil
  "Whether the current call is producing a View tree.")

(defun etaf--assert-not-rendering (operation)
  "Reject detectable side-effect OPERATION during pure render."
  (when etaf--render-phase-p
    (signal 'etaf-render-side-effect-error (list operation))))

(defvar etaf--watch-scheduler nil
  "Scheduler for watchers created in the current Scope.

The function receives a zero-argument job and a phase symbol.  Outside a
Runtime, watchers run synchronously.")

(defun etaf--subscriber-scheduler-context (subscriber)
  "Return SUBSCRIBER's scheduler context or the default context."
  (or (cond
       ((etaf-runtime-route-p subscriber)
        (etaf-runtime-route-scheduler-context subscriber))
       ((etaf-effect-p subscriber)
        (etaf-effect-scheduler-context subscriber)))
      etaf-scheduler-default-context))

(defun etaf-runtime-route-live-p (route)
  "Return non-nil when opaque Runtime ROUTE still owns dispatch authority."
  (and (etaf-runtime-route-p route)
       (etaf-runtime-route-active-p route)
       (let ((predicate (etaf-runtime-route-accepts-p route)))
         (or (null predicate)
             (condition-case condition
                 (funcall predicate route)
               ((error quit)
                (etaf-scheduler-record-route-authority-fault
                 (etaf--subscriber-scheduler-context route) condition)
                nil))))))

(defun etaf-reactive-enqueue-runtime-flush
    (runtime function &optional scheduler-context)
  "Queue FUNCTION once for RUNTIME in SCHEDULER-CONTEXT.
The default context preserves the legacy two-argument facade."
  (etaf-scheduler-enqueue-runtime
   (or scheduler-context (etaf-scheduler-current-context))
   runtime function))

(defun etaf--dispatch-subscriber-group
    (context source _projection-epoch subscribers)
  "Notify SOURCE SUBSCRIBERS already grouped for scheduler CONTEXT."
  (let (first-condition)
    (dolist (subscriber subscribers)
      (etaf-scheduler-record-subscriber-visit context)
      (condition-case condition
          (cond
           ((etaf-runtime-route-p subscriber)
            (if (etaf-runtime-route-live-p subscriber)
                (funcall (etaf-runtime-route-scheduler subscriber)
                         subscriber source)
              (etaf-scheduler-record-stale-route-drop context)))
           ((and (etaf-effect-p subscriber)
                 (etaf-effect-active-p subscriber)
                 (etaf-scheduler-claim-effect context subscriber))
            (if-let* ((scheduler (etaf-effect-scheduler subscriber)))
                (funcall scheduler subscriber)
              (etaf-reactive-effect-run subscriber))))
        ((error quit)
         (unless first-condition
           (setq first-condition condition)))))
    (when first-condition
      (signal (car first-condition) (cdr first-condition)))))

(defun etaf--reactive-same-p (left right)
  "Return whether LEFT and RIGHT are equal under ETAF's shallow rule."
  (if (or (consp left) (vectorp left) (hash-table-p left)
          (recordp left) (bufferp left) (windowp left)
          (markerp left) (overlayp left) (processp left))
      (eq left right)
    (equal left right)))

(defun etaf--source-test (source)
  "Return SOURCE's equality predicate."
  (or (and (etaf-ref-p source) (etaf-ref-test source))
      (and (etaf-computed-p source) (etaf-computed-test source))
      #'etaf--reactive-same-p))

(defun etaf--source-subscribers (source)
  "Return the subscriber table of reactive SOURCE."
  (cond
   ((etaf-ref-p source) (etaf-ref-subscribers source))
   ((etaf-computed-p source) (etaf-computed-subscribers source))
   (t (signal 'wrong-type-argument (list 'etaf-reactive-source-p source)))))

(defun etaf--track-source (source)
  "Record SOURCE as a dependency of the active effect."
  (when (and etaf--tracking-enabled-p etaf--runtime-dependency-collector
             (null etaf--active-effect))
    (funcall etaf--runtime-dependency-collector source))
  (when (and etaf--tracking-enabled-p etaf--active-effect
             (etaf-effect-active-p etaf--active-effect))
    (let ((subscribers (etaf--source-subscribers source)))
      (unless (gethash etaf--active-effect subscribers)
        (puthash etaf--active-effect t subscribers)
        (push source (etaf-effect-deps etaf--active-effect))))))

(defun etaf--clear-effect-deps (effect)
  "Remove EFFECT from all reactive sources it previously read."
  (dolist (source (etaf-effect-deps effect))
    (remhash effect (etaf--source-subscribers source)))
  (setf (etaf-effect-deps effect) nil))

(defun etaf--stop-effect (effect)
  "Stop EFFECT and run its one-time cleanup."
  (when (and (etaf-effect-p effect) (etaf-effect-active-p effect))
    (setf (etaf-effect-active-p effect) nil)
    (etaf--clear-effect-deps effect)
    (when-let* ((cleanup (etaf-effect-on-stop effect)))
      (setf (etaf-effect-on-stop effect) nil)
      (funcall cleanup)))
  effect)

(cl-defun etaf-reactive-effect-create
    (function &key scheduler name scope on-stop)
  "Create an effect for FUNCTION.

SCHEDULER receives the effect when a dependency changes.  SCOPE defaults to
the current Scope.  NAME optionally labels the effect.  ON-STOP runs once
when the effect is disposed."
  (etaf--assert-not-rendering 'create-effect)
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (let* ((owner (or scope etaf--active-scope))
         (scheduler-context
          (or (and owner (etaf-effect-scope-scheduler-context owner))
              (etaf-scheduler-current-context)))
         (effect (etaf--effect-create
                  :function function
                  :scheduler scheduler
                  :owner-scope owner
                  :scheduler-context scheduler-context
                  :on-stop on-stop
                  :name name)))
    (when owner
      (unless (etaf-effect-scope-active-p owner)
        (error "Cannot create an effect in a stopped ETAF Scope"))
      (push effect (etaf-effect-scope-effects owner)))
    effect))

(cl-defun etaf-reactive-effect-run (effect &key rendering)
  "Run EFFECT and recollect its dependencies.

When RENDERING is non-nil, `etaf-value' writes are rejected for the duration
of the run."
  (unless (etaf-effect-p effect)
    (signal 'wrong-type-argument (list 'etaf-effect-p effect)))
  (let* ((scheduler-context
          (or (etaf-effect-scheduler-context effect)
              (etaf-scheduler-current-context)))
         (etaf--scheduler-context scheduler-context))
    (etaf-scheduler-record-effect-evaluation scheduler-context)
    (cond
   ((etaf-effect-running-p effect)
    (error "Recursive ETAF effect execution: %S"
           (or (etaf-effect-name effect) effect)))
   ((not (etaf-effect-active-p effect))
    (funcall (etaf-effect-function effect)))
   (t
    (let ((old-deps (copy-sequence (etaf-effect-deps effect)))
          (completed-p nil)
          result)
      (etaf--clear-effect-deps effect)
      (let ((etaf--active-effect effect)
            (etaf--active-scope (etaf-effect-owner-scope effect))
            (etaf--runtime-dependency-collector nil)
            (etaf--tracking-enabled-p t)
            (etaf--render-phase-p (or rendering etaf--render-phase-p)))
        (setf (etaf-effect-running-p effect) t)
        (unwind-protect
            (progn
              (setq result (funcall (etaf-effect-function effect)))
              (setq completed-p t)
              result)
          (setf (etaf-effect-running-p effect) nil)
          (unless completed-p
            (etaf--clear-effect-deps effect)
            (dolist (source old-deps)
              (puthash effect t (etaf--source-subscribers source)))
            (setf (etaf-effect-deps effect) old-deps)))))))))

(defun etaf--dispatch-source (source)
  "Notify every current subscriber of SOURCE once."
  (etaf-scheduler-call-with-projection
   (lambda ()
     (let ((groups (make-hash-table :test #'eq)))
       (maphash
        (lambda (subscriber _)
          (let ((context (etaf--subscriber-scheduler-context subscriber)))
            (cond
             ((etaf-runtime-route-p subscriber)
              (if (etaf-runtime-route-live-p subscriber)
                  (puthash context
                           (cons subscriber (gethash context groups)) groups)
                (etaf-scheduler-record-stale-route-drop context)))
             ((and (etaf-effect-p subscriber)
                   (etaf-effect-active-p subscriber))
              (puthash context
                       (cons subscriber (gethash context groups)) groups)))))
        (etaf--source-subscribers source))
       (let (contexts)
         (maphash (lambda (context _) (push context contexts)) groups)
         (dolist (context
                  (sort contexts
                      (lambda (left right)
                        (< (etaf-scheduler-context-id left)
                           (etaf-scheduler-context-id right)))))
           (let ((subscribers (nreverse (gethash context groups))))
             (etaf-scheduler-enqueue-source
              context source
              (lambda (delivery-context delivery-source projection-epoch)
                (etaf--dispatch-subscriber-group
                 delivery-context delivery-source projection-epoch
                 subscribers))))))))))

(defun etaf-reactive-call-with-batch (function)
  "Call FUNCTION inside one cross-context reactive projection."
  (etaf-scheduler-call-with-projection function))

;;;###autoload
(cl-defun etaf-ref (initial-value &key test name)
  "Create a writable shallow reactive cell containing INITIAL-VALUE.

TEST optionally compares old and new values.  NAME is used in diagnostics."
  (etaf--assert-not-rendering 'create-ref)
  (when (and test (not (functionp test)))
    (signal 'wrong-type-argument (list 'functionp test)))
  (etaf--ref-create :value initial-value
                    :test test
                    :subscribers (make-hash-table :test #'eq)
                    :source-id (cl-incf etaf--source-id-counter)
                    :name name))

(defun etaf--computed-value (computed)
  "Read COMPUTED, evaluating it when its dependencies are dirty."
  (etaf--track-source computed)
  (when (etaf-computed-dirty-p computed)
    (when (etaf-computed-evaluating-p computed)
      (error "Recursive ETAF computed evaluation: %S"
             (or (etaf-computed-name computed) computed)))
    (setf (etaf-computed-evaluating-p computed) t)
    (unwind-protect
        (let* ((old (etaf-computed-value computed))
               (was-evaluated (etaf-computed-evaluated-p computed))
               (new (etaf-reactive-effect-run
                     (etaf-computed-effect computed))))
          (setf (etaf-computed-value computed) new
                (etaf-computed-dirty-p computed) nil
                (etaf-computed-evaluated-p computed) t)
          (when (or (not was-evaluated)
                    (not (funcall (etaf--source-test computed) old new)))
            (cl-incf (etaf-computed-version computed))))
      (setf (etaf-computed-evaluating-p computed) nil)))
  (etaf-computed-value computed))

;;;###autoload
(cl-defun etaf-computed (getter &key test name)
  "Create a lazy cached value computed by zero-argument GETTER.

TEST optionally compares old and new values.  NAME optionally labels the
computed value."
  (etaf--assert-not-rendering 'create-computed)
  (unless (functionp getter)
    (signal 'wrong-type-argument (list 'functionp getter)))
  (when (and test (not (functionp test)))
    (signal 'wrong-type-argument (list 'functionp test)))
  (let ((computed (etaf--computed-create
                   :getter getter :test test :name name
                   :subscribers (make-hash-table :test #'eq)
                   :source-id (cl-incf etaf--source-id-counter))))
    (setf (etaf-computed-effect computed)
          (etaf-reactive-effect-create
           getter
           :name (or name 'computed)
           :scheduler
           (lambda (_effect)
             (unless (etaf-computed-dirty-p computed)
               (setf (etaf-computed-dirty-p computed) t)
               (etaf--dispatch-source computed)))))
    computed))

;;;###autoload
(defun etaf-value (source)
  "Read reactive SOURCE and track the read in the current effect."
  (cond
   ((etaf-ref-p source)
    (etaf--track-source source)
    (etaf-ref-value source))
   ((etaf-computed-p source) (etaf--computed-value source))
   (t (signal 'wrong-type-argument (list 'etaf-reactive-source-p source)))))

(defun etaf-set-value (source new-value)
  "Set writable reactive SOURCE to NEW-VALUE and return NEW-VALUE."
  (when etaf--render-phase-p
    (signal 'etaf-render-write-error
            (list (and (etaf-ref-p source) (etaf-ref-name source)))))
  (unless (etaf-ref-p source)
    (error "ETAF computed values are read-only: %S" source))
  (let ((old-value (etaf-ref-value source)))
    (unless (funcall (etaf--source-test source) old-value new-value)
      (setf (etaf-ref-value source) new-value)
      (cl-incf (etaf-ref-version source))
      (etaf--dispatch-source source)))
  new-value)

(gv-define-setter etaf-value (new-value source)
  `(etaf-set-value ,source ,new-value))

(defun etaf--watch-getter (source)
  "Return a zero-argument getter for watch SOURCE."
  (cond
   ((or (etaf-ref-p source) (etaf-computed-p source))
    (lambda () (etaf-value source)))
   ((functionp source) source)
   (t (error "ETAF watch source must be reactive or callable: %S" source))))

(defun etaf--schedule-watch (job flush)
  "Schedule JOB in FLUSH through the active Runtime scheduler."
  (if etaf--watch-scheduler
      (funcall etaf--watch-scheduler job flush)
    (funcall job)))

;;;###autoload
(cl-defun etaf-watch
    (source callback &key immediate (flush 'pre) test name)
  "Watch SOURCE and call CALLBACK with NEW and OLD values.

IMMEDIATE calls CALLBACK for the initial value.  FLUSH is passed to the
current Runtime scheduler.  TEST and NAME customize comparison and
diagnostics.  Return a stop function."
  (etaf--assert-not-rendering 'watch)
  (unless (functionp callback)
    (signal 'wrong-type-argument (list 'functionp callback)))
  (let* ((getter (etaf--watch-getter source))
         (same-p (or test (and (etaf-ref-p source)
                               (etaf--source-test source))
                            (and (etaf-computed-p source)
                                 (etaf--source-test source))
                            #'etaf--reactive-same-p))
         initialized-p
         old-value
         cleanup
         effect
         job)
    (setq job
          (lambda ()
            (when (etaf-effect-active-p effect)
              (let ((new-value (etaf-reactive-effect-run effect)))
                (when (or (not initialized-p)
                          (not (funcall same-p old-value new-value)))
                  (let ((previous (and initialized-p old-value)))
                    (setq old-value new-value initialized-p t)
                    (when cleanup
                      (funcall cleanup)
                      (setq cleanup nil))
                    (when-let* ((result (funcall callback new-value previous)))
                      (when (functionp result)
                        (setq cleanup result)))))))))
    (setq effect
          (etaf-reactive-effect-create
           getter
           :name (or name 'watch)
           :on-stop (lambda () (when cleanup (funcall cleanup)))
           :scheduler
           (lambda (_effect) (etaf--schedule-watch job flush))))
    (if immediate
        (funcall job)
      (setq old-value (etaf-reactive-effect-run effect)
            initialized-p t))
    (lambda () (etaf--stop-effect effect))))

;;;###autoload
(cl-defun etaf-watch-effect (function &key (flush 'pre) name)
  "Run FUNCTION immediately and again after a reactive dependency change.

FLUSH selects the Runtime scheduler boundary.  NAME optionally labels the
effect.  If FUNCTION returns a function, it cleans up the previous run."
  (etaf--assert-not-rendering 'watch-effect)
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (let (cleanup effect job)
    (setq job
          (lambda ()
            (when (etaf-effect-active-p effect)
              (when cleanup (funcall cleanup) (setq cleanup nil))
              (when-let* ((result (etaf-reactive-effect-run effect)))
                (when (functionp result) (setq cleanup result))))))
    (setq effect
          (etaf-reactive-effect-create
           function
           :name (or name 'watch-effect)
           :on-stop (lambda () (when cleanup (funcall cleanup)))
           :scheduler
           (lambda (_effect) (etaf--schedule-watch job flush))))
    (funcall job)
    (lambda () (etaf--stop-effect effect))))

;;;###autoload
(cl-defun etaf-effect-scope (&key detached name scheduler-context)
  "Create a Scope named NAME, owned by the current Scope unless DETACHED.
SCHEDULER-CONTEXT defaults to the parent or dynamically active context."
  (etaf--assert-not-rendering 'create-scope)
  (let* ((parent (and (not detached) etaf--active-scope))
         (scheduler-context
          (or scheduler-context
              (and parent (etaf-effect-scope-scheduler-context parent))
              (etaf-scheduler-current-context)))
         (scope (etaf--effect-scope-create
                 :parent parent
                 :scheduler-context
                 (etaf-scheduler-context-resolve scheduler-context)
                 :name name)))
    (when parent
      (push scope (etaf-effect-scope-children parent)))
    scope))

;;;###autoload
(defun etaf-current-effect-scope ()
  "Return the active Scope, or nil outside scoped execution."
  etaf--active-scope)

;;;###autoload
(cl-defun etaf-scope-run
    (scope function &key (watch-scheduler nil watch-scheduler-p))
  "Run FUNCTION with active SCOPE and optional WATCH-SCHEDULER."
  (unless (and (etaf-effect-scope-p scope)
               (etaf-effect-scope-active-p scope))
    (error "Cannot enter an inactive ETAF Scope"))
  (let ((etaf--active-scope scope)
        (etaf--scheduler-context
         (etaf-effect-scope-scheduler-context scope))
        (etaf--watch-scheduler
         (if watch-scheduler-p watch-scheduler etaf--watch-scheduler)))
    (funcall function)))

;;;###autoload
(defun etaf-on-scope-dispose (function)
  "Register FUNCTION to run when the current Scope is disposed."
  (etaf--assert-not-rendering 'register-scope-cleanup)
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (unless etaf--active-scope
    (error "ETAF cleanup registration requires an active Scope"))
  (push function (etaf-effect-scope-cleanups etaf--active-scope))
  function)

;;;###autoload
(defun etaf-scope-stop (scope)
  "Dispose SCOPE and return cleanup errors collected during teardown."
  (etaf--assert-not-rendering 'stop-scope)
  (when (and (etaf-effect-scope-p scope)
             (etaf-effect-scope-active-p scope))
    (setf (etaf-effect-scope-active-p scope) nil)
    (let (errors)
      (dolist (child (copy-sequence (etaf-effect-scope-children scope)))
        (setq errors (nconc errors (etaf-scope-stop child))))
      (dolist (effect (copy-sequence (etaf-effect-scope-effects scope)))
        (condition-case err
            (etaf--stop-effect effect)
          ((error quit) (push err errors))))
      (dolist (cleanup (copy-sequence (etaf-effect-scope-cleanups scope)))
        (condition-case err
            (funcall cleanup)
          ((error quit) (push err errors))))
      (setf (etaf-effect-scope-effects scope) nil
            (etaf-effect-scope-children scope) nil
            (etaf-effect-scope-cleanups scope) nil)
      (when-let* ((parent (etaf-effect-scope-parent scope)))
        (setf (etaf-effect-scope-children parent)
              (delq scope (etaf-effect-scope-children parent))))
      (nreverse errors))))

(provide 'etaf-reactive)

;;; etaf-reactive.el ends here
