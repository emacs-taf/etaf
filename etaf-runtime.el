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
(defvar etaf--render-runtime)
(defvar etaf--render-style-stack)
(defvar etaf--current-context)

(define-error 'etaf-runtime-error "ETAF runtime error")

(cl-defstruct (etaf--component-instance
               (:constructor etaf--component-instance-create))
  "Retained state and lifecycle for one logical Component call."
  spec
  identity
  scope
  render-function
  props
  slots
  context
  mounted-hooks
  updated-hooks
  unmounted-hooks
  (mounted-p nil))

(cl-defstruct (etaf-runtime
               (:constructor etaf--runtime-create))
  "Mounted ETAF application runtime."
  buffer
  root-view
  root-node
  scope
  render-effect
  instances
  handlers
  host-props
  focus-ref
  behaviors
  seen
  candidate-handlers
  candidate-host-props
  candidate-behaviors
  candidate-created
  candidate-snapshots
  candidate-old-instances
  generation
  (mounted-p t)
  flushing-p
  pending-p)

(defvar etaf--runtime-table (make-hash-table :test #'eq)
  "Buffer -> mounted ETAF Runtime table.")

(defvar etaf--current-runtime nil
  "Runtime owning the current setup, lifecycle, or event operation.")

(defun etaf-current-runtime ()
  "Return the dynamically active Runtime, or nil outside a Runtime."
  etaf--current-runtime)

(defun etaf-runtime-set-focus-ref (runtime host-ref)
  "Set RUNTIME's focused Host reference to HOST-REF and return it."
  (setf (etaf-runtime-focus-ref runtime) host-ref)
  host-ref)

(defun etaf-runtime-for-buffer (buffer-or-name)
  "Return the live Runtime mounted in BUFFER-OR-NAME, or nil."
  (let ((buffer (get-buffer buffer-or-name)))
    (and buffer (gethash buffer etaf--runtime-table))))

(defun etaf-runtime-require-mounted (&optional runtime)
  "Return mounted RUNTIME or the Runtime in the current buffer.

Signal an ETAF runtime error before any downstream action or renderer lookup
when the requested boundary is no longer mounted."
  (let ((runtime (or runtime etaf--current-runtime
                     (and (derived-mode-p 'special-mode)
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

(defun etaf--runtime-event-kind (property)
  "Return event symbol represented by callback PROPERTY."
  (intern (substring (symbol-name property) 4)))

(defun etaf--runtime-register-host (runtime props path)
  "Register callback PROPS for the opaque Host reference in RUNTIME at PATH."
  (let ((host-ref (etaf--generated-host-ref props path))
        handlers)
    (puthash host-ref props (etaf-runtime-candidate-host-props runtime))
    (while props
      (let ((key (pop props))
            (value (pop props)))
        (when (and (keywordp key)
                   (string-prefix-p ":on-" (symbol-name key))
                   (functionp value))
          (push (cons (etaf--runtime-event-kind key) value) handlers))))
    (when handlers
      (puthash host-ref handlers (etaf-runtime-candidate-handlers runtime)))))

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
             (state (if (and old
                             (equal (etaf-behavior-spec-attributes
                                     (car old))
                                    (etaf-behavior-spec-attributes spec)))
                        old
                      (etaf--runtime-install-behavior runtime spec path props))))
        (puthash identity state (etaf-runtime-candidate-behaviors runtime))
        (let ((attributes (etaf-behavior-spec-attributes (car state))))
          (while attributes
            (let ((key (pop attributes))
                  (value (pop attributes)))
              (unless (plist-member merged key)
                (setq merged (append merged (list key value)))))))))
    (etaf--view-node-create
     :name (etaf--view-node-name node)
     :props merged
     :children (etaf--view-node-children node))))

(defun etaf--runtime-promote-behaviors (runtime)
  "Publish candidate Behavior state for RUNTIME and dispose old state."
  (maphash
   (lambda (identity old)
     (let ((candidate (gethash identity
                               (etaf-runtime-candidate-behaviors runtime))))
       (unless (and candidate (eq candidate old))
         (when-let ((cleanup (cdr old)))
           (funcall cleanup)))))
   (etaf-runtime-behaviors runtime))
  (setf (etaf-runtime-behaviors runtime)
        (etaf-runtime-candidate-behaviors runtime)
        (etaf-runtime-candidate-behaviors runtime) nil))

(defun etaf--runtime-rollback-behaviors (runtime)
  "Dispose Behavior installers created by a failed RUNTIME candidate."
  (when-let ((candidate (etaf-runtime-candidate-behaviors runtime)))
    (maphash
     (lambda (identity state)
       (unless (eq state (gethash identity (etaf-runtime-behaviors runtime)))
         (when-let ((cleanup (cdr state)))
           (funcall cleanup))))
     candidate)))

(defun etaf--runtime-call-key (call path)
  "Return retained identity for CALL at PATH, honoring an optional `:key'."
  (let* ((props (etaf--resolve-property-plist
                 (etaf--component-call-props call)))
         (key (plist-get props :key)))
    (when key
      (etaf--validate-key key))
    (if key
        (append (butlast path) (list :key key))
      path)))

(defun etaf--runtime-snapshot-instance (runtime identity instance)
  "Record INSTANCE's pre-candidate fields once for RUNTIME and IDENTITY."
  (unless (assoc identity (etaf-runtime-candidate-snapshots runtime))
    (push (list identity instance
                (etaf--component-instance-props instance)
                (etaf--component-instance-slots instance)
                (etaf--component-instance-render-function instance))
          (etaf-runtime-candidate-snapshots runtime))))

(defun etaf--runtime-new-instance (runtime spec identity props slots)
  "Create and register IDENTITY's Component instance for RUNTIME from SPEC."
  (let ((instance
         (etaf--component-instance-create
          :spec spec
          :identity identity
         :scope (etaf-effect-scope :name identity)
          :context (etaf--context-create :parent etaf--current-context)
          :props props
          :slots slots)))
    (push instance (etaf-runtime-candidate-created runtime))
    (puthash identity instance (etaf-runtime-instances runtime))
    instance))

(defun etaf--runtime-instance-for-call (runtime call path)
  "Return retained Component instance for CALL at PATH in RUNTIME."
  (let* ((spec (etaf--component-call-spec call))
         (identity (list (etaf--component-spec-name spec)
                         (etaf--runtime-call-key call path)))
         (props (etaf--resolve-property-plist
                 (etaf--component-call-props call)))
         (slots (etaf--component-call-slots call))
         (old (gethash identity (etaf-runtime-instances runtime)))
         (instance (cond
                    ((and old (eq (etaf--component-instance-spec old) spec))
                     (etaf--runtime-snapshot-instance runtime identity old)
                     old)
                    (old
                     (push (list identity old)
                           (etaf-runtime-candidate-old-instances runtime))
                     (etaf--runtime-new-instance runtime spec identity props slots))
                    (t
                     (etaf--runtime-new-instance runtime spec identity props slots)))))
    (setf (etaf--component-instance-props instance) props
          (etaf--component-instance-slots instance) slots)
    (puthash identity t (etaf-runtime-seen runtime))
    instance))

(defun etaf--run-hooks (hooks)
  "Run HOOKS in registration order."
  (dolist (hook (reverse hooks))
    (funcall hook)))

(defun etaf--runtime-render-component (runtime call path)
  "Render CALL through retained RUNTIME at PATH to one Ebox node."
  (let* ((instance (etaf--runtime-instance-for-call runtime call path))
         (spec (etaf--component-instance-spec instance))
         (props (etaf--component-instance-props instance))
         (slots (etaf--component-instance-slots instance))
         (setup (etaf--component-spec-setup spec)))
    (let ((etaf--current-runtime runtime)
          (etaf--current-component-instance instance)
          (etaf--current-component-props props)
          (etaf--current-component-slots slots)
          (etaf--current-context
           (etaf--component-instance-context instance))
          (etaf--render-runtime runtime)
          (etaf--render-style-stack
           (cons
            (cons (etaf--component-spec-styles spec)
                  (append path (list :view)))
            etaf--render-style-stack)))
      (when (and setup
                 (null (etaf--component-instance-render-function instance)))
        (let ((render-function
               (etaf-scope-run
                (etaf--component-instance-scope instance)
                (lambda () (funcall setup props slots))
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
             (nodes (etaf--render-value-list
                     rendered
                     (append path (list :view)))))
        (cond
         ((null nodes) (ebox-spacer))
         ((null (cdr nodes)) (car nodes))
         (t (apply #'ebox-column nodes)))))))

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
    (etaf--runtime-dispose-instance instance nil))
  (dolist (entry (etaf-runtime-candidate-old-instances runtime))
    (puthash (car entry) (cadr entry) (etaf-runtime-instances runtime)))
  (dolist (snapshot (etaf-runtime-candidate-snapshots runtime))
    (let ((instance (cadr snapshot)))
      (setf (etaf--component-instance-props instance) (nth 2 snapshot)
            (etaf--component-instance-slots instance) (nth 3 snapshot)
            (etaf--component-instance-render-function instance)
            (nth 4 snapshot))))
  runtime)

(defun etaf--runtime-clear-candidate (runtime)
  "Clear transient candidate bookkeeping in RUNTIME."
  (setf (etaf-runtime-candidate-created runtime) nil
        (etaf-runtime-candidate-snapshots runtime) nil
        (etaf-runtime-candidate-old-instances runtime) nil
        (etaf-runtime-seen runtime) nil
        (etaf-runtime-candidate-handlers runtime) nil
        (etaf-runtime-candidate-host-props runtime) nil
        (etaf-runtime-candidate-behaviors runtime) nil))

(defun etaf--runtime-promote (runtime)
  "Promote RUNTIME's successful candidate and return its lifecycle groups."
  (let (removed added existing)
    (maphash
     (lambda (identity instance)
       (if (gethash identity (etaf-runtime-seen runtime))
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
  (setf (etaf-runtime-seen runtime) (make-hash-table :test #'equal)
        (etaf-runtime-candidate-created runtime) nil
        (etaf-runtime-candidate-snapshots runtime) nil
        (etaf-runtime-candidate-old-instances runtime) nil
        (etaf-runtime-candidate-handlers runtime)
        (make-hash-table :test #'equal)
        (etaf-runtime-candidate-host-props runtime)
        (make-hash-table :test #'equal)
        (etaf-runtime-candidate-behaviors runtime)
        (make-hash-table :test #'equal)))

(defun etaf--runtime-render-root (runtime)
  "Evaluate and lower RUNTIME's root View."
  (let ((root-view (etaf-runtime-root-view runtime)))
    (etaf--render-value-list
     (if (functionp root-view) (funcall root-view) root-view)
     '(root))))

(defun etaf--runtime-render-effect (runtime)
  "Build and publish one candidate for RUNTIME."
  (etaf--runtime-begin-candidate runtime)
  (let (next-root)
    (condition-case err
        (let* ((etaf--render-runtime runtime)
               (nodes (etaf--runtime-render-root runtime)))
          (setq next-root
                (cond
                 ((null nodes) (ebox-spacer))
                 ((null (cdr nodes)) (car nodes))
                 (t (apply #'ebox-column nodes))))
          (if (etaf-runtime-root-node runtime)
              (ebox-commit (etaf-runtime-buffer runtime) next-root)
            (ebox-render-to-buffer (etaf-runtime-buffer runtime) next-root))
          (setf (etaf-runtime-root-node runtime) next-root
                (etaf-runtime-handlers runtime)
                (etaf-runtime-candidate-handlers runtime)
                (etaf-runtime-host-props runtime)
                (etaf-runtime-candidate-host-props runtime)
                (etaf-runtime-generation runtime)
                (1+ (etaf-runtime-generation runtime))))
      ((error quit)
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

(defun etaf--runtime-request-flush (runtime)
  "Synchronously flush RUNTIME, or mark one follow-up flush while busy."
  (when (etaf-runtime-mounted-p runtime)
    (if (etaf-runtime-flushing-p runtime)
        (setf (etaf-runtime-pending-p runtime) t)
      (setf (etaf-runtime-flushing-p runtime) t)
      (unwind-protect
          (progn
            (etaf--runtime-render-effect runtime)
            (while (etaf-runtime-pending-p runtime)
              (setf (etaf-runtime-pending-p runtime) nil)
              (etaf--runtime-render-effect runtime)))
        (setf (etaf-runtime-flushing-p runtime) nil)))))

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
                     :handlers (make-hash-table :test #'equal)
                     :host-props (make-hash-table :test #'equal)
                     :behaviors (make-hash-table :test #'equal)
                     :generation 0)))
      (puthash buffer runtime etaf--runtime-table)
      (setf (etaf-runtime-render-effect runtime)
            (etaf-scope-run
             scope
             (lambda ()
               (etaf-reactive-effect-create
                (lambda ()
                  (let ((etaf--current-runtime runtime))
                    (etaf--runtime-render-effect runtime)))
                :name 'render
                :scheduler
                (lambda (_effect)
                  (etaf--runtime-request-flush runtime))))))
      (condition-case err
          (etaf-reactive-effect-run
           (etaf-runtime-render-effect runtime) :rendering t)
        ((error quit)
         (remhash buffer etaf--runtime-table)
         (etaf-scope-stop scope)
         (signal (car err) (cdr err))))
      buffer)))

;;;###autoload
(defun etaf-runtime-unmount (&optional runtime)
  "Unmount RUNTIME and dispose its Component scopes."
  (let ((runtime (etaf-runtime-require-mounted runtime)))
    (setf (etaf-runtime-mounted-p runtime) nil)
    (remhash (etaf-runtime-buffer runtime) etaf--runtime-table)
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
     (lambda (_identity state)
       (when-let ((cleanup (cdr state)))
         (funcall cleanup)))
     (etaf-runtime-behaviors runtime))
    (clrhash (etaf-runtime-instances runtime))
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
