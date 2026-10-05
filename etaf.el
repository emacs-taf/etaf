;;; etaf.el --- Text application framework facade -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: ETAF contributors
;; Version: 0.2.1
;; Package-Requires: ((emacs "29.1") (ebox "3.0.0") (ecss "0.1.0"))
;; Keywords: ui, tools, convenience
;; URL: https://github.com/ginqi7/etaf

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf) after adding the repository
;; root to load-path.
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen. Do not require files below lisp/ from consumers.
;; This Commentary is the authoritative export list; implementations and precise
;; docstrings remain beside their definitions. The manual contains workflows.
;;
;; Macro: etaf-action-define (name arguments &rest body)
;;;###autoload (autoload 'etaf-action-define "etaf" nil nil 'macro)
;; Define and register named Action NAME with ARGUMENTS and BODY.
;;
;; The generated function receives RUNTIME as its first argument when called
;; through `etaf-dispatch'.
;;
;; Error: etaf-action-error
;; Invalid ETAF Action
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Error: etaf-async-error
;; Invalid asynchronous adapter or timeout; parent is etaf-reactive-error.
;; Error: etaf-async-timeout
;; Asynchronous wait exceeded its timeout; parent is etaf-async-error.
;; Error: etaf-async-cancelled
;; Pending work was cancelled; parent is etaf-async-error.
;; These conditions are recorded in Resource/Data error state. Cancellation or
;; timeout never certifies rollback of external writes.
;;
;; Function: etaf-async (start)
;;;###autoload (autoload 'etaf-async "etaf" nil nil)
;; Describe a lazy asynchronous loader using START.
;; Return this value from a Resource loader or Data source operation.  START
;; receives RESOLVE and REJECT functions and may return a zero-argument cancel
;; function.  It starts work without blocking and completes once: RESOLVE takes
;; the ordinary loader result; REJECT takes Emacs condition data.  Returning nil
;; means the work cannot be cancelled, but obsolete completion is still ignored.
;; The owning Resource or Controller starts and releases the operation; this is
;; not a standalone promise.  Native timers and processes may call completion
;; functions later on the Emacs thread.
;;
;; Function: etaf-action-redefine-run (function)
;;;###autoload (autoload 'etaf-action-redefine-run "etaf" nil nil)
;; Run FUNCTION while allowing intentional Action redefinition.
;;
;; Normal duplicate registrations remain errors.  This dynamic authoring
;; boundary replaces only the process-global name binding used by future
;; `etaf-dispatch' calls; it does not flush or rerender mounted Runtimes.
;;
;; Function: etaf-activate (&optional runtime)
;;;###autoload (autoload 'etaf-activate "etaf" nil t)
;; Dispatch `press' for the focused Host, or the interaction boundary at point.
;;
;; RUNTIME is the mounted Runtime to activate, or nil for the current buffer.
;; Position lookup uses committed Ebox node keymaps. Enabled press handlers are
;; native activation/navigation targets; disabled or callbackless controls block
;; ancestor activation. Ebox owns keyboard focus precedence and target selection.
;;
;; Function: etaf-behavior-context-info (context)
;;;###autoload (autoload 'etaf-behavior-context-info "etaf" nil nil)
;; Return CONTEXT's installation facts as a fresh plist.
;; CONTEXT comes from `etaf-current-behavior-context` during an installer.
;; Keys are :runtime (the owning Runtime), :host-ref (the effective Host reference)
;; and :properties (installation-time semantic Host properties).
;; The plist and property container are fresh; contained values retain identity
;; and must be treated as read-only. These facts remain readable after cleanup,
;; but do not certify that the candidate published or the Host is still mounted.
;; Use Runtime public queries for committed state, and return installer cleanup
;; to release resources on replacement, rollback or unmount.
;; Invalid CONTEXT signals `etaf-behavior-error`.
;;
;; Function: etaf-behavior-create (name &rest attributes)
;;;###autoload (autoload 'etaf-behavior-create "etaf" nil nil)
;; Create a Behavior spec named NAME from keyword ATTRIBUTES.
;;
;; The reserved `:install' attribute is an optional zero-argument installer that
;; returns nil or a cleanup function; it is not merged into Host properties.
;;
;; Error: etaf-behavior-error
;; Invalid ETAF Behavior
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Macro: etaf-batch (&rest body)
;;;###autoload (autoload 'etaf-batch "etaf" nil nil 'macro)
;; Evaluate BODY in one reactive batch and return its last value, or nil for
;; an empty body. Nested batches join the outermost scope. Use for several
;; related state writes; the function form and failure contract follow below.
;;
;; Function: etaf-call-with-batch (function)
;;;###autoload (autoload 'etaf-call-with-batch "etaf" nil nil)
;; Call zero-argument FUNCTION and return its result after pending reactive
;; work finishes. Ref writes are immediately readable; existing observers and
;; Runtime updates wait for the outermost batch. Events and Actions use this
;; same boundary, so explicit batches compose with their callbacks.
;; If FUNCTION errors or quits, pending work still drains before its original
;; condition is re-signaled. Written refs remain changed; the batch provides
;; neither rollback nor atomic publication across Runtimes. If only draining
;; fails, that condition signals. FUNCTION must be callable; use outside
;; rendering on the main Emacs event loop. This scope is synchronous: later
;; asynchronous callbacks must establish their own batch. No resource or
;; Runtime ownership is transferred to the batch.
;;
;; Error: etaf-component-call-error
;; Invalid ETAF Component call
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-check-prop (property value valid-p expected &optional component)
;;;###autoload (autoload 'etaf-check-prop "etaf" nil nil)
;; Return VALUE when VALID-P is non-nil; otherwise report an input error.
;; PROPERTY is a keyword and EXPECTED is a description string. COMPONENT names
;; the input owner, defaulting to the Component whose :validate form is running.
;; Helpers outside validation supply COMPONENT explicitly. Checks must not mutate
;; input values or perform external effects. Failure signals etaf-component-call-error
;; naming the component, property, received value and expectation. Large values
;; are abbreviated; no resources are copied or owned.
;; Use (etaf-check-prop :count count (natnump count) "a nonnegative integer")
;; in a Component's ordinary Elisp :validate form. Malformed check metadata
;; signals etaf-component-definition-error.
;;
;; Error: etaf-component-definition-error
;; Invalid ETAF Component definition
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-component-redefine-run (function)
;;;###autoload (autoload 'etaf-component-redefine-run "etaf" nil nil)
;; Run FUNCTION while allowing intentional Component redefinition.
;;
;; Normal duplicate Component definitions remain errors.  Authoring tools may
;; use this narrow public boundary after disposing the old Runtime, so hot reload
;; does not depend on ETAF's private registry flag.
;;
;; Function: etaf-component-set-styles (name styles)
;;;###autoload (autoload 'etaf-component-set-styles "etaf" nil nil)
;; Replace the static style form for Component NAME with STYLES.
;;
;; STYLES must use the same `((SELECTOR PROPERTY VALUE ...) ...)'
;; contract accepted by `etaf-define-component'.  This small runtime authoring
;; hook is useful to tools which reload a stylesheet without redefining the
;; Component itself, such as a source/preview playground.  The next mount or
;; render observes the replacement; existing mounted runtimes are not flushed
;; implicitly.
;;
;; Function: etaf-computed (getter &key test name)
;;;###autoload (autoload 'etaf-computed "etaf" nil nil)
;; Create a lazy cached value computed by zero-argument GETTER.
;;
;; TEST optionally compares old and new values.  NAME optionally labels the
;; computed value. Mounted consumers retain their publication when all their
;; reactive inputs compare unchanged; getters reading ambient Context use the
;; ordinary render path to preserve Context tracking. Unobserved computations
;; stay lazy.
;;
;; Function: etaf-computed-p (x)
;;;###autoload (autoload 'etaf-computed-p "etaf" nil nil)
;;
;;
;; Error: etaf-context-error
;; Invalid ETAF Context operation
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-current-behavior-context ()
;;;###autoload (autoload 'etaf-current-behavior-context "etaf" nil nil)
;; Return the Behavior context active during an installer, or nil.
;;
;; Function: etaf-current-prop (name)
;;;###autoload (autoload 'etaf-current-prop "etaf" nil nil)
;; Return current Component prop NAME.
;;
;; NAME is normally an ordinary symbol used by the `:setup' lexical shorthand.
;; The function is also useful to code that deliberately avoids that shorthand.
;;
;; Function: etaf-current-slot (name &optional fallback)
;;;###autoload (autoload 'etaf-current-slot "etaf" nil nil)
;; Return composable children for slot NAME, or FALLBACK when absent.
;; Supplied children retain caller Context and style ownership when passed,
;; appended or wrapped as View children. Treat each child value as opaque;
;; use only during Component render and do not retain beyond its Runtime.
;;
;; Function: etaf-current-slots ()
;;;###autoload (autoload 'etaf-current-slots "etaf" nil nil)
;; Return the current Component's slot alist of opaque composable children.
;; Values follow etaf-current-slot ownership and lifecycle constraints.
;;
;; Function: etaf-data-cancel (controller)
;;;###autoload (autoload 'etaf-data-cancel "etaf" nil nil)
;; Cancel CONTROLLER's pending request without stopping it; return CONTROLLER.
;; Loaded items remain available.  A cancelled write has unknown external
;; certainty unless its provider already reported a committed result; cancelling
;; its subsequent refresh never changes that known result.
;;
;; Function: etaf-data-controller (source &key query (page 1) (page-size 20) selection auto-load name item-key owner-scope initial-result timeout)
;;;###autoload (autoload 'etaf-data-controller "etaf" nil nil)
;; Create a reactive Data Controller for SOURCE.
;;
;; QUERY, PAGE, PAGE-SIZE, result ITEMS, TOTAL, STATUS, ERROR, and SELECTION are
;; stored in refs.  When AUTO-LOAD is non-nil, the controller loads immediately
;; and reloads after query or pagination refs change.  NAME optionally labels the
;; controller for diagnostics.  ITEM-KEY identifies selection and selected-item
;; state; it defaults to the source's `:item-key' capability when available.
;; When OWNER-SCOPE is supplied, or when a current ETAF Scope exists, the
;; controller's own child Scope is disposed with that owner; otherwise it keeps
;; the detached Scope behavior.  INITIAL-RESULT may be a normalized source result
;; for QUERY/PAGE/PAGE-SIZE; it seeds a successful Controller without another
;; load.  INITIAL-RESULT and AUTO-LOAD are mutually exclusive.
;; TIMEOUT is nil or positive seconds for each asynchronous operation.
;; Loads retain previously accepted items while refreshing, after error and after
;; cancellation.  Stopping the Controller cancels pending work and ignores late
;; completion without undoing external writes.
;;
;; Function: etaf-data-error (controller)
;;;###autoload (autoload 'etaf-data-error "etaf" nil nil)
;; Return CONTROLLER's observable error ref; read its value with `etaf-value`.
;; The value is nil without a captured failure, otherwise condition data.
;; The controller owns this ref; consumers observe it and do not write it.
;;
;; Error: etaf-data-error
;; Invalid ETAF data operation; parent condition for Data contract failures.
;; Catch with condition-case. This condition is distinct from calling the
;; same-named reader function to inspect a controller's captured failure.
;;
;; Function: etaf-data-item-identity (controller item)
;;;###autoload (autoload 'etaf-data-item-identity "etaf" nil nil)
;; Return ITEM's stable selection identity in CONTROLLER.
;;
;; The identity comes from the Controller's explicit `:item-key', then from its
;; source capability, and otherwise is ITEM itself.
;;
;; Function: etaf-data-items (controller)
;;;###autoload (autoload 'etaf-data-items "etaf" nil nil)
;; Return CONTROLLER's loaded items ref.
;;
;; Function: etaf-data-load (controller)
;;;###autoload (autoload 'etaf-data-load "etaf" nil nil)
;; Start CONTROLLER's source load; return the synchronous result or nil pending.
;; Loading before first success uses `loading'; later reads use `refreshing' and
;; retain items.  Completion publishes `success', `error' or `cancelled'.
;; Synchronous source errors are recorded and re-signaled.  Asynchronous source
;; errors are recorded; projection/rendering errors still signal from completion.
;; A new load cancels the old request.  Superseding a pending write records unknown
;; external certainty; it does not imply rollback.
;;
;; Function: etaf-data-memory-source (items &key id-key name)
;;;###autoload (autoload 'etaf-data-memory-source "etaf" nil nil)
;; Create an in-memory Data source over ITEMS.
;;
;; ID-KEY identifies records for `replace', `update', and `delete' mutations,
;; and is exposed to Data Controllers as the source's stable item identity.
;; NAME optionally labels the source for diagnostics.
;; Queries may be nil, a predicate, a search string, a plist, an alist, or an
;; exact value.  Supported mutations are `insert', `replace', `update', `delete',
;; and `reset'.
;;
;; Function: etaf-data-mutate (controller operation payload)
;;;###autoload (autoload 'etaf-data-mutate "etaf" nil nil)
;; Run source OPERATION with PAYLOAD and then reconcile its result.
;; Synchronous writes return their result.  An asynchronous write returns nil
;; while pending; inspect status and mutation outcome after completion.  A second
;; write is rejected while the first write is pending.  Cancellation, timeout or
;; an unclassified external failure never implies that the write was rolled back.
;;
;; Function: etaf-data-mutate-many (controller operations)
;;;###autoload (autoload 'etaf-data-mutate-many "etaf" nil nil)
;; Apply OPERATIONS to CONTROLLER's source and reconcile once.
;; OPERATIONS is a non-empty list of (OPERATION PAYLOAD) pairs applied in order.
;; A source with the optional `:mutate-batch' capability applies the whole list
;; atomically; any other source runs the v1 `:mutate' callback for each pair.
;; The committed result is a plist whose `:operation' is `mutate-many' with
;; `:results' in order and `:changes' when the results report it.  Signals
;; `etaf-data-error' for an empty or malformed list or an asynchronous source
;; result.  A signaled operation stops the batch, publishes an external-unknown
;; failure outcome carrying the completed results under `:results', and is
;; re-signaled after publication.
;;
;; Function: etaf-data-mutation-outcome (controller)
;;;###autoload (autoload 'etaf-data-mutation-outcome "etaf" nil nil)
;; Return a copy of CONTROLLER's latest mutation outcome envelope.
;;
;; The envelope contains `:certainty' (`committed', `rolled-back', or
;; `external-unknown'), the raw mutation result, and an opaque reconciliation
;; token.  A batch failure additionally carries the completed prefix under
;; `:results'.  While an asynchronous write is outstanding, :pending-p is non-nil and
;; certainty is external-unknown.  After completion :pending-p is nil or absent.
;; The reader tracks mutation changes in reactive Views and effects; callers
;; do not write its state.  Treat the token as opaque.  No outcome means
;; no mutation has started.  Stopped Controllers reject access.
;;
;; Function: etaf-data-next-page (controller)
;;;###autoload (autoload 'etaf-data-next-page "etaf" nil nil)
;; Move CONTROLLER to the next page and return the new page.
;;
;; Function: etaf-data-page (controller)
;;;###autoload (autoload 'etaf-data-page "etaf" nil nil)
;; Return CONTROLLER's page ref.
;;
;; Function: etaf-data-page-size (controller)
;;;###autoload (autoload 'etaf-data-page-size "etaf" nil nil)
;; Return CONTROLLER's page-size ref.
;;
;; Function: etaf-data-previous-page (controller)
;;;###autoload (autoload 'etaf-data-previous-page "etaf" nil nil)
;; Move CONTROLLER to the previous page and return the new page.
;;
;; Error: etaf-data-projection-conflict
;; ETAF Data projection expected-version conflict
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Error: etaf-data-projection-error
;; ETAF Data projection failed
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-data-query (controller)
;;;###autoload (autoload 'etaf-data-query "etaf" nil nil)
;; Return CONTROLLER's query ref.
;;
;; Function: etaf-data-reconciliation-state (controller)
;;;###autoload (autoload 'etaf-data-reconciliation-state "etaf" nil nil)
;; Return CONTROLLER's current reconciliation state symbol, if any.
;;
;; Function: etaf-data-retry-reconciliation (controller)
;;;###autoload (autoload 'etaf-data-retry-reconciliation "etaf" nil nil)
;; Reload a committed mutation without replaying its source mutation.
;;
;; The operation is allowed only for a committed outcome with a pending token;
;; unknown and rolled-back outcomes are deliberately not retried.
;; Return the synchronous loaded page, or nil when asynchronous work is pending
;; or no retry is eligible.  Observe status and `etaf-data-reconciliation-state'
;; to distinguish completion.  No automatic write retry is performed.
;;
;; Function: etaf-data-reload (controller)
;;;###autoload (autoload 'etaf-data-reload "etaf" nil nil)
;; Reload CONTROLLER; return the synchronous result or nil while pending.
;;
;; Function: etaf-data-select (controller identity &optional (selected-p t))
;;;###autoload (autoload 'etaf-data-select "etaf" nil nil)
;; Select or deselect IDENTITY in CONTROLLER.
;;
;; When SELECTED-P is nil, remove IDENTITY from the selection.
;;
;; Function: etaf-data-select-one (controller identity)
;;;###autoload (autoload 'etaf-data-select-one "etaf" nil nil)
;; Replace CONTROLLER selection with the single IDENTITY.
;;
;; Use this explicit single-selection operation for tables and list views.  The
;; existing `etaf-data-select' API remains additive for multi-select controls.
;;
;; Function: etaf-data-selected-item (controller &optional item-key)
;;;###autoload (autoload 'etaf-data-selected-item "etaf" nil nil)
;; Return the loaded item matching CONTROLLER's first selected identity.
;;
;; ITEM-KEY overrides the function supplied to `etaf-data-controller'.  When no
;; key function is available, item identity is compared directly.  Return nil
;; when the selection or current page has no matching item.
;;
;; Function: etaf-data-selected-ref (controller identity)
;;;###autoload (autoload 'etaf-data-selected-ref "etaf" nil nil)
;; Return CONTROLLER's stable boolean selection ref for IDENTITY.
;;
;; The returned ref changes only when IDENTITY enters or leaves the controller's
;; selection.  Repeated calls for the same identity return the same ref for the
;; controller lifetime.  Updates made through the selection APIs or by writing
;; the public `etaf-data-selection' ref directly are both reflected.
;;
;; Function: etaf-data-selection (controller)
;;;###autoload (autoload 'etaf-data-selection "etaf" nil nil)
;; Return CONTROLLER's selected identity list ref.
;;
;; Function: etaf-data-set-page (controller page)
;;;###autoload (autoload 'etaf-data-set-page "etaf" nil nil)
;; Set CONTROLLER page to PAGE and return PAGE.
;;
;; Function: etaf-data-set-page-size (controller page-size)
;;;###autoload (autoload 'etaf-data-set-page-size "etaf" nil nil)
;; Set CONTROLLER page size to PAGE-SIZE and return PAGE-SIZE.
;;
;; Function: etaf-data-set-query (controller query)
;;;###autoload (autoload 'etaf-data-set-query "etaf" nil nil)
;; Set CONTROLLER query to QUERY and return QUERY.
;;
;; Function: etaf-data-source (&rest capabilities)
;;;###autoload (autoload 'etaf-data-source "etaf" nil nil)
;; Create a Data source from callable CAPABILITIES.
;;
;; CAPABILITIES is a plist.  `:load' is required and receives QUERY, PAGE, and
;; PAGE-SIZE.  It must return a plist containing at least `:items', and may return
;; `:total', `:page', and `:page-size'.  `:mutate' is optional and receives
;; OPERATION and PAYLOAD.  An optional `:mutate-v2' capability has the same
;; arguments but may return a tagged commit-certainty outcome; it is additive and
;; never changes the v1 callback.  An optional `:mutate-batch' capability
;; receives a list of (OPERATION PAYLOAD) pairs and returns one result per pair;
;; a transactional backend turns the list into one atomic write and
;; `etaf-data-mutate-many' reconciles the Controller once for the batch.
;; `:dispose' is optional and runs when the owning
;; controller stops.  `:item-key' optionally returns stable selection identity
;; for one item.  `:provider' may name the source in observation reports and
;; defaults to `data'.
;; Load and mutation callbacks may instead return `etaf-async'; resolve with the
;; ordinary result and reject with condition data.  A v2 result has :certainty
;; committed/rolled-back/external-unknown, :result for committed, and :error
;; condition data for rolled-back.  A v1 normal return means committed.
;; A rejection, cancellation or timeout leaves external write certainty unknown.
;; Each Controller owns its source disposal; use separate source lifecycles for
;; independent Controllers.
;;
;; Function: etaf-data-source-capabilities (source)
;;;###autoload (autoload 'etaf-data-source-capabilities "etaf" nil nil)
;; Return a fresh plist of SOURCE's supported :load, :mutate, :mutate-v2,
;; :mutate-batch, :dispose, :item-key, :provider and :name entries when present.
;; Callbacks
;; and metadata retain identity; replacing entries leaves SOURCE unchanged.
;; Use to compose an adapter with etaf-data-source without inspecting private
;; representation. Preserve callback inputs/results and forward disposal.
;; The adapted source has one owning Controller; do not give its underlying
;; source another owner. Reading capabilities starts no work and transfers
;; no ownership. Invalid sources signal wrong-type-argument.
;;
;; Function: etaf-data-source-load-page (source &optional query page page-size)
;;;###autoload (autoload 'etaf-data-source-load-page "etaf" nil nil)
;; Load and normalize one SOURCE page without creating a Controller.
;; QUERY is passed through unchanged.  PAGE and PAGE-SIZE default to 1 and 20.
;; This public preparation boundary performs no reactive publication; callers may
;; use its result as `:initial-result' for `etaf-data-controller'.
;; Only synchronous sources are supported; an asynchronous descriptor signals
;; `etaf-async-error' without starting its work.
;;
;; Function: etaf-data-status (controller)
;;;###autoload (autoload 'etaf-data-status "etaf" nil nil)
;; Return CONTROLLER's status ref.
;;
;; The status is idle, loading, refreshing, success, error or cancelled.
;; Read-only reloads use refreshing after an accepted result; writes use loading.
;; Previous items remain readable until a successful load replaces them.
;;
;; Function: etaf-data-stop (controller)
;;;###autoload (autoload 'etaf-data-stop "etaf" nil nil)
;; Stop CONTROLLER, dispose its Scope, and return cleanup errors.
;;
;; Error: etaf-data-stopped-error
;; ETAF data controller has been stopped
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-data-total (controller)
;;;###autoload (autoload 'etaf-data-total "etaf" nil nil)
;; Return CONTROLLER's total matching item count ref.
;;
;; Macro: etaf-define-behavior (name arguments &rest body)
;;;###autoload (autoload 'etaf-define-behavior "etaf" nil nil 'macro)
;; Define ordinary Behavior constructor NAME with ARGUMENTS and BODY.
;;
;; The constructor must return `etaf-behavior-create' data.  This is a function
;; definition convenience, not a second runtime or visual node model.
;;
;; Macro: etaf-define-component (name arguments &rest clauses)
;;;###autoload (autoload 'etaf-define-component "etaf" nil nil 'macro)
;; Define Component NAME from prop ARGUMENTS and CLAUSES.
;;
;; Choose exactly one authoring frontend:
;;
;;   (etaf-define-component NAME (&key PROPS)
;;     [:bindings ((NAME INITIALIZER) ...)]
;;     [:validate ORDINARY-ELISP]
;;     [:setup SETUP]
;;     :view VIEW
;;     :styles ((SELECTOR ATTR ...)))
;;
;; or:
;;
;;   (etaf-define-component NAME (&key PROPS)
;;     [:bindings ((NAME INITIALIZER) ...)]
;;     [:validate ORDINARY-ELISP]
;;     [:setup SETUP]
;;     :render ORDINARY-ELISP
;;     :styles ((SELECTOR ATTR ...)))
;;
;; `:bindings' initializes named values once, in let* order, before optional
;; `:setup'.  Initializers can use initial props and earlier bindings.  Setup,
;; both View frontends and their callbacks can refer directly to these stable
;; values.  Names must be distinct ordinary symbols, not declared props.
;; Ref/computed/watch/local-ref ownership remains the Component Scope; failed
;; initialization disposes it.  Reorder retains values; replacement/unmount
;; releases the instance.  Rebinding a lexical name with setq does not replace
;; its stored value: mutate refs explicitly through `etaf-value'.
;;
;; With named bindings, optional `:setup' performs initialization; its return
;; value is ignored.  Without bindings, setup can return opaque state read by
;; the advanced `etaf-state' accessor, but not a render function.  `:view'
;; is unquoted DSL; `:render' is ordinary Elisp returning the same typed View,
;; usually through `etaf-view'.  `etaf-node' also constructs Views
;; programmatically.  Both frontends use the same prop and slot rules.  Declared
;; props are lexical snapshots for each setup or render evaluation; callbacks
;; may refer to them directly.  Passed refs retain identity and live value reads.
;; Business prop values use the reactive shallow equality rule: replacing an
;; object updates the retained instance even when its contents compare equal.
;; Keyed list items follow the same rule; keys retain instances, not old inputs.
;; Keep reactive value reads inside the View properties or expressions they
;; update.  Use `etaf-prop' in a binding initializer for a tracked input; a plain
;; prop variable in initialization is an initial snapshot.
;;
;; A fragment result keeps its children in the enclosing Host layout, including
;; projected slots and stateful children. Component retention adds no visual
;; container. Declare a layout Host explicitly when the Component needs one.
;; Output may change between nil, one View and a fragment without resetting the
;; Component's bindings. Keyed children retain state while present; removal
;; releases their own instances even when the parent remains mounted.
;;
;; Props accept NAME or (NAME DEFAULT) after &key.  Defaults evaluate in order
;; on first missing input and can read earlier props.  Explicit nil is supplied.
;; Mounted instances retain successfully published defaults until replacement or
;; unmount; pure rendering evaluates defaults anew.  Default expressions must be
;; safe to retry after rejected publication; allocate mutable values explicitly.
;;
;; Optional :validate runs ordinary Elisp with resolved lexical props after
;; defaults, before bindings/setup or updated inputs are published. Its return
;; is ignored; etaf-check-prop or any signaled error rejects the input. Pure
;; rendering and mounted input evaluation share this phase. Validation must be
;; pure and may run again; it cannot use instance bindings, state, slots or
;; lifecycle. Check reactive handles by type and keep their live value reads and
;; value-dependent checks in rendering. Rejected input preserves the published
;; props and callbacks but does not undo the caller's business ref write.
;;
;; Component rules use ECSS author origin, specificity, source order and
;; importance through Ebox. &/:scope match each topmost owned Host; ordinary
;; selectors match owned descendants. Slots retain caller ownership and fallback
;; retains the consumer's scope. Inline declarations remain separate cascade input.
;;
;; Function: etaf-dispatch (action &rest arguments)
;;;###autoload (autoload 'etaf-dispatch "etaf" nil nil)
;; Dispatch named ACTION through the active Runtime with ARGUMENTS.
;;
;; An explicit Runtime may be supplied as the first argument: `(etaf-dispatch
;; RUNTIME ACTION ...)'.  Action functions receive Runtime first.
;;
;; Function: etaf-call-with-input (reader)
;;;###autoload (autoload 'etaf-call-with-input "etaf" nil nil)
;; Run zero-argument native input READER from the current Host event callback.
;; Ebox restores logical focus and checks that the same mounted Host remains
;; visible and enabled; invalidation signals a subtype of quit. Return the
;; reader result without applying application state. Reader errors and user
;; quit propagate. Calls outside events signal etaf-event-error. Native editing
;; owns its minibuffer or separate buffer; it must not edit the rendered surface.
;;
;; Function: etaf-dispatch-event (runtime host-ref kind &optional payload (payload-p nil))
;;;###autoload (autoload 'etaf-dispatch-event "etaf" nil nil)
;; Dispatch KIND for HOST-REF through mounted RUNTIME.
;; Native Hosts support :on-press activation and :on-drag gestures. ON-DRAG
;; receives the gesture plist documented by `ebox-keymap-create' :drag, once
;; per start/move/end/cancel phase. Each phase runs in its own reactive event
;; batch and publishes before the next pointer event. Primary-button tracking
;; belongs to Ebox; when both handlers are supplied, press is keyboard-only.
;; Generated pointer gestures publish Ebox :active state through component
;; styles while held; pointer activation clears it before invoking :on-press.
;; Explicit event dispatch and keyboard activation do not create pointer state.
;; Callbacks follow the current committed Host. A retained disabled Host can
;; receive native cancellation; removed or unmounted Hosts receive no more
;; application callbacks. Their Component scopes clean up normally. Other
;; :on-* names require explicit dispatch and do not imply native event support.
;; `:on-press-capture' is the one explicit ancestor hook: after a target press
;; callback succeeds, committed ancestor capture handlers run nearest-first.
;; Ordinary :on-press callbacks never bubble implicitly.
;;
;;   When PAYLOAD-P is non-nil, pass PAYLOAD as the callback's only argument;
;; otherwise call the local callback with no arguments.
;;
;; Function: etaf-event-target-within-p (host-ref)
;;;###autoload (autoload 'etaf-event-target-within-p "etaf" nil nil)
;; Return non-nil when the current event's target is HOST-REF or inside it.
;; Call from an event callback.  In an ancestor `:on-press-capture' callback the
;; target is the Host whose press callback ran; in any other callback it is the
;; callback's own Host.  HOST-REF is compared with `equal' against the target and
;; its committed Host ancestors, so a root shell can tell a press inside an open
;; panel from one on the surface around it.  Outside an event callback signal
;; `etaf-event-error'.
;;
;; Function: etaf-effect-scope (&key detached name scheduler-context)
;;;###autoload (autoload 'etaf-effect-scope "etaf" nil nil)
;; Create a Scope named NAME, owned by the current Scope unless DETACHED.
;; SCHEDULER-CONTEXT defaults to the parent or dynamically active context.
;; The parent disposes child scopes automatically. Without a parent, or when
;; DETACHED is non-nil, the caller must use `etaf-scope-stop` for cleanup.
;;
;; Function: etaf-error-boundary-run (function handler &key name)
;;;###autoload (autoload 'etaf-error-boundary-run "etaf" nil nil)
;; Run FUNCTION and handle its signaled error with HANDLER.
;;
;; HANDLER receives the raw condition object and its return value becomes the
;; boundary result.  NAME is accepted for caller diagnostics and does not change
;; control flow.  Errors signaled outside FUNCTION, or by HANDLER itself, are not
;; swallowed by this boundary.
;;
;; Error: etaf-event-error
;; Invalid ETAF Event
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-focus (&optional runtime host-ref)
;;;###autoload (autoload 'etaf-focus "etaf" nil t)
;; Move focus to HOST-REF in mounted RUNTIME and move point to its position.
;;
;; Ebox owns mounted focus, navigation and publication, including :focus
;; component rules and their paint/layout changes. Pure views carry no focus.
;; Without HOST-REF, select its first eligible tab stop; an empty list leaves
;; focus and point unchanged and signals user-error. Explicit invalid targets signal
;; etaf-event-error. Negative or absent tab indexes still allow explicit focus.
;; Removal, hiding and disabling clear focus; a tab-index change alone does not.
;; Layout follows point only when it stayed at the target; manual point stays
;; at its numeric position clamped to the accessible buffer. Rejection restores
;; focus and point. No window is selected.
;;
;; Function: etaf-focus-next (&optional runtime)
;;;###autoload (autoload 'etaf-focus-next "etaf" nil t)
;; Focus the next visible Host in mounted RUNTIME.
;;
;; Function: etaf-focus-previous (&optional runtime)
;;;###autoload (autoload 'etaf-focus-previous "etaf" nil t)
;; Focus the previous visible Host in mounted RUNTIME.
;;
;; Function: etaf-focus-within (runtime host-ref &optional count)
;;;###autoload (autoload 'etaf-focus-within "etaf" nil nil)
;; Navigate inside HOST-REF's committed subtree in RUNTIME (nil: current buffer).
;; Nil COUNT selects its first eligible stop; integer COUNT moves with wrapping,
;; negative moves backward and zero queries current focus membership. Ebox owns
;; ordering, visibility and identity. Missing/inaccessible roots or stops signal
;; user-error without changing focus or point. Focus changes require an accepted
;; publication boundary. This installs no input bindings or persistent trap.
;;
;; Function: etaf-focusable (&rest attributes)
;;;###autoload (autoload 'etaf-focusable "etaf" nil nil)
;; Return a focusable Behavior from ATTRIBUTES.
;;
;; When ATTRIBUTES does not specify `:tab-index', the Behavior supplies the
;; standard first tab stop, zero.  An explicit nil excludes it from tab navigation.
;;
;; Function: etaf-focused-host-ref (&optional runtime)
;;;###autoload (autoload 'etaf-focused-host-ref "etaf" nil nil)
;; Return Ebox's current focus Host reference in mounted RUNTIME.
;; Direct Ebox focus operations and these APIs observe the same buffer owner.
;;
;; Error: etaf-generation-conflict
;; Stale ETAF semantic generation candidate
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Error: etaf-generation-error
;; Invalid ETAF generation authority
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-generation-p (x)
;;;###autoload (autoload 'etaf-generation-p "etaf" nil nil)
;;
;;
;; Function: etaf-generation-root-semantic-id (x)
;;;###autoload (autoload 'etaf-generation-root-semantic-id "etaf" nil nil)
;; Access slot "root-semantic-id" of `etaf-generation' struct X.
;;
;;
;; Error: etaf-host-authority-error
;; Invalid ETAF Host authority state
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-input-begin (runtime host-ref)
;;;###autoload (autoload 'etaf-input-begin "etaf" nil nil)
;; Start native editing of a mounted Host's published text; return a session.
;; ETAF defers this Runtime's publications while the session is active and
;; Ebox refuses them, so keystrokes, point, selection and undo stay native in
;; the real buffer. Host, Runtime, window and single-session rules are errors.
;;
;; Function: etaf-input-text (session)
;;;###autoload (autoload 'etaf-input-text "etaf" nil nil)
;; Return a session's current property-free user text.
;;
;; Function: etaf-input-end (session)
;;;###autoload (autoload 'etaf-input-end "etaf" nil nil)
;; End a session, restore the published text, and return the user's text.
;; Update application state with the accepted value and flush afterwards.
;;
;; Function: etaf-input-active-p (&optional runtime)
;;;###autoload (autoload 'etaf-input-active-p "etaf" nil nil)
;; Return a mounted Runtime's active input session, or nil.
;;
;; Function: etaf-host-ref-bounds (runtime host-ref)
;;;###autoload (autoload 'etaf-host-ref-bounds "etaf" nil nil)
;; Return live Ebox bounds for HOST-REF in mounted RUNTIME.
;;
;; Function: etaf-host-ref-size (runtime host-ref)
;;;###autoload (autoload 'etaf-host-ref-size "etaf" nil nil)
;; Return the committed painted border-box size as (WIDTH-PIXELS . HEIGHT-ROWS).
;; RUNTIME must be mounted. Margins and neighbouring columns are excluded;
;; clipping reduces the result, and absent or wholly hidden Hosts return nil.
;; Read after layout to prepare resources; the query does not publish and is
;; not intended for per-frame polling.
;;
;; Function: etaf-host-ref-position (runtime host-ref)
;;;###autoload (autoload 'etaf-host-ref-position "etaf" nil nil)
;; Return the first live Ebox position for HOST-REF in RUNTIME.
;;
;; Function: etaf-inject (key &optional default (required-p nil required-p-supplied-p))
;;;###autoload (autoload 'etaf-inject "etaf" nil nil)
;; Return the nearest provided value for KEY.
;;
;; DEFAULT is returned when KEY is absent.  When REQUIRED-P is non-nil, absence
;; signals an error.  The optional third argument is explicit so a provided nil
;; can be distinguished from a missing dependency.
;;
;; Function: etaf-mount (buffer-or-name view &optional options)
;;;###autoload (autoload 'etaf-mount "etaf" nil nil)
;; Mount normalized VIEW into BUFFER-OR-NAME and return its buffer.
;; OPTIONS is forwarded to `etaf-runtime-mount' when the Runtime is loaded.
;;
;; Function: etaf-node (tag props children &optional named-slots)
;;;###autoload (autoload 'etaf-node "etaf" nil nil)
;; Construct one typed View node from evaluated ordinary Elisp values.
;; TAG is an exact Host or Component registry symbol.  PROPS is a keyword plist,
;; CHILDREN is a list of typed View children, and NAMED-SLOTS is a Component-only
;; alist from stable slot symbols to typed child lists.
;;
;; Hosts also accept Ebox native :help-echo (string, native three-argument
;; help function, or nil), :pointer (Ebox pointer symbol or nil), and
;; :hover-style (Ebox color/text-decoration paint plist or nil). These are
;; inherited capabilities, including through Component root attributes;
;; explicit nil blocks inheritance. Ebox validates and paints them. They do
;; not create an activation boundary or an ETAF hover event/state.
;;
;; Error: etaf-observer-error
;; Invalid ETAF observer operation
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-on-mounted (callback)
;;;###autoload (autoload 'etaf-on-mounted "etaf" nil nil)
;; Run CALLBACK after the current Component is first published.
;;
;; Function: etaf-on-unmounted (callback)
;;;###autoload (autoload 'etaf-on-unmounted "etaf" nil nil)
;; Run CALLBACK when the current Component is disposed.
;;
;; Function: etaf-on-updated (callback)
;;;###autoload (autoload 'etaf-on-updated "etaf" nil nil)
;; Run CALLBACK after the current Component participates in an update.
;;
;; Function: etaf-performance-call-operation (runtime kind label function)
;;;###autoload (autoload 'etaf-performance-call-operation "etaf" nil nil)
;; Call FUNCTION as KIND and LABEL through RUNTIME's operation boundary.
;;
;; Function: etaf-performance-clear ()
;;;###autoload (autoload 'etaf-performance-clear "etaf" nil t)
;; Clear completed and unfinished performance records.
;;
;; Function: etaf-performance-copy-report ()
;;;###autoload (autoload 'etaf-performance-copy-report "etaf" nil t)
;; Copy all retained performance records to the kill ring.
;;
;; Function: etaf-performance-environment-data ()
;;;###autoload (autoload 'etaf-performance-environment-data "etaf" nil nil)
;; Return the environment snapshot used to interpret latency records.
;;
;; Function: etaf-performance-export (file)
;;;###autoload (autoload 'etaf-performance-export "etaf" nil t)
;; Export all retained performance records to FILE.
;;
;; When called interactively, suggest a timestamped `.eld' file.  Refuse to
;; overwrite an existing file.
;;
;; Variable: etaf-performance-max-records
;; Maximum completed operations retained by the recorder.
;;
;; Function: etaf-performance-mode (&optional arg)
;;;###autoload (autoload 'etaf-performance-mode "etaf" nil t)
;; Record operations for the Runtime mounted in the current buffer.
;;
;; This is a minor mode.  If called interactively, toggle the
;; `ETAF-Performance mode' mode.  If the prefix argument is positive,
;; enable the mode, and if it is zero or negative, disable the mode.
;;
;; If called from Lisp, toggle the mode if ARG is `toggle'.  Enable the
;; mode if ARG is nil, omitted, or is a positive number.  Disable the mode
;; if ARG is a negative number.
;;
;; To check whether the minor mode is enabled in the current buffer,
;; evaluate the variable `etaf-performance-mode'.
;;
;; The mode's hook is called both when the mode is enabled and when it is
;; disabled.
;;
;; Function: etaf-performance-operation-elapsed (x)
;;;###autoload (autoload 'etaf-performance-operation-elapsed "etaf" nil nil)
;; Access slot "elapsed" of `etaf-performance-operation' struct X.
;;
;;
;; Function: etaf-performance-operation-gc-count (x)
;;;###autoload (autoload 'etaf-performance-operation-gc-count "etaf" nil nil)
;; Access slot "gc-count" of `etaf-performance-operation' struct X.
;;
;;
;; Function: etaf-performance-operation-gc-elapsed (x)
;;;###autoload (autoload 'etaf-performance-operation-gc-elapsed "etaf" nil nil)
;; Access slot "gc-elapsed" of `etaf-performance-operation' struct X.
;;
;;
;; Function: etaf-performance-operation-id (x)
;;;###autoload (autoload 'etaf-performance-operation-id "etaf" nil nil)
;; Access slot "id" of `etaf-performance-operation' struct X.
;;
;;
;; Function: etaf-performance-operation-kind (x)
;;;###autoload (autoload 'etaf-performance-operation-kind "etaf" nil nil)
;; Access slot "kind" of `etaf-performance-operation' struct X.
;;
;;
;; Function: etaf-performance-operation-label (x)
;;;###autoload (autoload 'etaf-performance-operation-label "etaf" nil nil)
;; Access slot "label" of `etaf-performance-operation' struct X.
;;
;;
;; Function: etaf-performance-operation-p (x)
;;;###autoload (autoload 'etaf-performance-operation-p "etaf" nil nil)
;;
;;
;; Function: etaf-performance-operation-stage-summary (operation)
;;;###autoload (autoload 'etaf-performance-operation-stage-summary "etaf" nil nil)
;; Summarize flat provider stages in OPERATION by category.
;;
;; Each result contains `:category', `:count', and `:duration-ms'.  Provider
;; durations may overlap and are therefore never presented as exclusive time.
;;
;; Function: etaf-performance-operation-stages (x)
;;;###autoload (autoload 'etaf-performance-operation-stages "etaf" nil nil)
;; Access slot "stages" of `etaf-performance-operation' struct X.
;;
;;
;; Function: etaf-performance-operation-status (x)
;;;###autoload (autoload 'etaf-performance-operation-status "etaf" nil nil)
;; Access slot "status" of `etaf-performance-operation' struct X.
;;
;;
;; Function: etaf-performance-records (&optional runtime-id)
;;;###autoload (autoload 'etaf-performance-records "etaf" nil nil)
;; Return newest-first immutable snapshots of completed records.
;; When RUNTIME-ID is non-nil, select only that integer observer report identity,
;; as exposed by `etaf-performance-operation-runtime-id'.  This also selects
;; historical records after unmount or reuse of a buffer name.  Omitted or nil
;; RUNTIME-ID selects all retained records.
;;
;; Function: etaf-performance-report-data (&optional (records (etaf-performance-records)))
;;;###autoload (autoload 'etaf-performance-report-data "etaf" nil nil)
;; Return a detached portable report for completed RECORDS. Omitted RECORDS
;; selects retained records; explicit nil selects none. The versioned plist
;; includes :format-version, :environment, :summary and :operations. Operations
;; identify :id, :runtime-id and :buffer-name and contain flat :stages with
;; :provider, :stage, :duration-ms and provider :metadata. Nested provider
;; durations may overlap. This read-only operation does not clear recordings,
;; install observers, change the Runtime or invoke recorded application code.
;;
;; Function: etaf-performance-show ()
;;;###autoload (autoload 'etaf-performance-show "etaf" nil t)
;; Show retained ETAF operations and stages in a tabulated panel.
;;
;; Function: etaf-performance-stage-category (x)
;;;###autoload (autoload 'etaf-performance-stage-category "etaf" nil nil)
;; Access slot "category" of `etaf-performance-stage' struct X.
;;
;;
;; Function: etaf-performance-stage-duration (x)
;;;###autoload (autoload 'etaf-performance-stage-duration "etaf" nil nil)
;; Access slot "duration" of `etaf-performance-stage' struct X.
;;
;;
;; Function: etaf-performance-stage-metadata (x)
;;;###autoload (autoload 'etaf-performance-stage-metadata "etaf" nil nil)
;; Access slot "metadata" of `etaf-performance-stage' struct X.
;;
;;
;; Function: etaf-performance-stage-name (x)
;;;###autoload (autoload 'etaf-performance-stage-name "etaf" nil nil)
;; Access slot "name" of `etaf-performance-stage' struct X.
;;
;;
;; Function: etaf-performance-stage-provider (x)
;;;###autoload (autoload 'etaf-performance-stage-provider "etaf" nil nil)
;; Access slot "provider" of `etaf-performance-stage' struct X.
;;
;;
;; Function: etaf-performance-stage-status (x)
;;;###autoload (autoload 'etaf-performance-stage-status "etaf" nil nil)
;; Access slot "status" of `etaf-performance-stage' struct X.
;;
;;
;; Function: etaf-performance-start (runtime)
;;;###autoload (autoload 'etaf-performance-start "etaf" nil nil)
;; Attach the recorder to mounted RUNTIME and return RUNTIME.
;;
;; Attachment is idempotent for this recorder.  A Runtime already owned by a
;;   different observer is rejected rather than replaced.
;;
;; Function: etaf-performance-stop (runtime)
;;;###autoload (autoload 'etaf-performance-stop "etaf" nil nil)
;; Detach this recorder from RUNTIME and return RUNTIME.
;;
;; If another observer replaced the recorder sink, leave that observer intact.
;;
;; Function: etaf-performance-summary (&optional (records (etaf-performance-records)))
;;;###autoload (autoload 'etaf-performance-summary "etaf" nil nil)
;; Summarize completed RECORDS by operation kind and label.
;; Omitted RECORDS selects all retained records; explicit nil selects none.
;;
;; Macro: etaf-performance-with-operation ((runtime kind label) &rest body)
;;;###autoload (autoload 'etaf-performance-with-operation "etaf" nil nil 'macro)
;; Evaluate BODY through RUNTIME's canonical operation boundary.
;;
;; Function: etaf-local-ref (name)
;;;###autoload (autoload 'etaf-local-ref "etaf" nil nil)
;; During Component setup, obtain a stable opaque Host reference for NAME,
;; a non-nil symbol or string. Equal names share a handle only within one
;; retained instance. Pass it to :ref and Host query, focus or event APIs;
;; expose it to callers explicitly when needed. It is neither state nor a key.
;; Only a committed Host resolves: failure preserves its previous target,
;; removal makes bounds/position queries return nil, and a new instance gets
;; a new handle. Calls outside setup or with invalid names signal
;; `etaf-component-definition-error`.
;;
;; Function: etaf-prop (name)
;;;###autoload (autoload 'etaf-prop "etaf" nil nil)
;; Return the current Component's stable read-only reactive input NAME.
;; Call during setup, then read with `etaf-value` in computed getters or watches.
;; NAME is a declared prop name or keyword; defaults are included. Plain prop
;; variables remain snapshots. Candidate rendering reads candidate input;
;; watchers are notified after successful publication. Rejection restores caches.
;; The Component owns the source; reads after disposal signal an error.
;;
;; Function: etaf-provide (key value)
;;;###autoload (autoload 'etaf-provide "etaf" nil nil)
;; Provide VALUE under stable Context KEY to the current subtree.
;;
;; Error: etaf-reactive-error
;; Invalid ETAF reactive operation
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-ref (initial-value &key test name)
;;;###autoload (autoload 'etaf-ref "etaf" nil nil)
;; Create a writable shallow reactive cell containing INITIAL-VALUE.
;; Lists, vectors, hash tables, records, functions and editor handles compare by
;; identity; other values use equal. Replacing an object notifies dependents
;; even when its contents match.
;;
;; TEST optionally compares old and new values.  NAME is used in diagnostics.
;;
;; Function: etaf-ref-p (x)
;;;###autoload (autoload 'etaf-ref-p "etaf" nil nil)
;;
;;
;; Function: etaf-refit (&optional runtime window)
;;;###autoload (autoload 'etaf-refit "etaf" nil nil)
;; Refit a mounted Runtime to the display window's current viewport size.
;; RUNTIME defaults to the Runtime of the current buffer, and WINDOW to the
;; window showing that buffer.  The width is the renderer's display-safe window
;; width, so the result matches what the renderer itself uses after a resize.
;; Return (WIDTH . HEIGHT) in pixels and lines, or nil when there is no mounted
;; Runtime or live window, which makes a call from a window-change hook a safe
;; no-op.  The framework already refits every mounted Runtime once a window
;; resize settles (see `etaf-runtime-viewport'), so call this only for windows
;; the resize notification does not cover, such as a buffer mounted before the
;; window manager displayed it.
;;
;; Function: etaf-render (view)
;;;###autoload (autoload 'etaf-render "etaf" nil nil)
;; Lower normalized VIEW to one atomic canonical Ebox input.
;; Host class/id, non-nil role and explicitly supplied aria-* attributes reach
;; Ebox selector subjects. ARIA nil remains a present nil attribute; comparison
;; uses ECSS value formatting. Ebox derives the disabled state from the same
;; :disabled interaction input used for focus and activation protection.
;; Selector relationships follow the rendered Host tree. Use Ebox's public
;; selector queries on the result; :selector-attributes and :selector-state
;; are adapter facts and cannot be supplied as View properties.
;;
;; This pure entry supports stateless Components.  Stateful Components require a
;;   Runtime because their setup Scope must have a lifecycle owner.
;;
;; Error: etaf-render-side-effect-error
;; ETAF render must be side-effect free
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Error: etaf-render-write-error
;; ETAF state cannot be written while rendering
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Error: etaf-renderer-error
;; ETAF rendering error
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-resource (loader &key (immediate t) scope name timeout keep-value)
;;;###autoload (autoload 'etaf-resource "etaf" nil nil)
;; Create a Scope-owned Resource backed by LOADER.
;; LOADER returns a value, `etaf-resource-result', or a lazy `etaf-async' operation.
;; IMMEDIATE starts loading before returning; otherwise status starts as `idle'.
;; TIMEOUT is nil or positive seconds, applied to asynchronous waiting only.
;; With KEEP-VALUE non-nil, reload reports `refreshing' and retains the last
;; successful value until a replacement succeeds.  Failure or cancellation also
;; retains it.  Otherwise reload clears and cleans up the old value immediately.
;; The Resource owns a child Scope under SCOPE or the current Scope; without a
;; parent it is detached and the caller must dispose it.
;;
;; Function: etaf-resource-cancel (resource)
;;;###autoload (autoload 'etaf-resource-cancel "etaf" nil nil)
;; Cancel RESOURCE's pending load without disposing it, and return RESOURCE.
;; The first late completion is discarded, even when external work cannot be
;; cancelled.  The Resource may be loaded again.  No pending request is a no-op.
;;
;; Function: etaf-resource-dispose (resource)
;;;###autoload (autoload 'etaf-resource-dispose "etaf" nil nil)
;; Dispose RESOURCE and return cleanup errors collected by its Scope.
;;
;; Function: etaf-resource-error (resource)
;;;###autoload (autoload 'etaf-resource-error "etaf" nil nil)
;; Return RESOURCE's current loader failure or cancellation condition, or nil.
;;
;; Error: etaf-resource-error
;; Invalid ETAF Resource operation, such as reloading a disposed Resource.
;; Catch with condition-case. Loader failures are instead captured as Resource
;; state and inspected with the same-named reader function.
;;
;; Function: etaf-resource-load (resource)
;;;###autoload (autoload 'etaf-resource-load "etaf" nil nil)
;; Reload RESOURCE and return it, without waiting for asynchronous completion.
;; Cancel the previous request before starting the next.  Only the current
;; request can publish a result.  Loader failures become observable state;
;; cleanup and rendering failures still signal normally.  Reload after error,
;; timeout or cancellation retries the loader; no automatic retry is performed.
;;
;; Function: etaf-resource-result (value &key cleanup)
;;;###autoload (autoload 'etaf-resource-result "etaf" nil nil)
;; Return a Resource loader result containing VALUE and optional CLEANUP.
;;
;; CLEANUP must be nil or a zero-argument function.  The Resource runs it when
;; clearing or replacing the value and on disposal.  A first completion arriving
;; after cancellation is discarded and cleaned up; duplicate completions are
;; ignored.  A loader must transfer each result to only one Resource.
;;
;; Function: etaf-resource-status (resource)
;;;###autoload (autoload 'etaf-resource-status "etaf" nil nil)
;; Return RESOURCE status: idle, loading, refreshing, success, error or cancelled.
;;
;; Function: etaf-resource-value (resource)
;;;###autoload (autoload 'etaf-resource-value "etaf" nil nil)
;; Return RESOURCE's successful value, or nil before success.
;;
;; Error: etaf-retirement-error
;; Invalid ETAF retirement journal
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-runtime-buffer (x)
;;;###autoload (autoload 'etaf-runtime-buffer "etaf" nil nil)
;; Access slot "buffer" of `etaf-runtime' struct X.
;;
;; Function: etaf-current-runtime ()
;;;###autoload (autoload 'etaf-current-runtime "etaf" nil nil)
;; Return the Runtime that owns the current setup, lifecycle, or event
;; callback, or nil outside a Runtime operation.  Lifecycle code that needs
;; the mounted buffer must use `(etaf-runtime-buffer
;; (etaf-current-runtime))`; `current-buffer' is the caller's buffer and is
;; not guaranteed to be the mounted target when `etaf-mount' receives a name.
;;
;;
;; Function: etaf-runtime-current-generation (runtime)
;;;###autoload (autoload 'etaf-runtime-current-generation "etaf" nil nil)
;; Return RUNTIME's uniquely authoritative committed generation.
;; The opaque object may retain identity across prepared scalar updates. Use
;; `etaf-runtime-generation' or the committed Ebox revision for settlement;
;; `etaf-runtime-snapshot' exports a detached snapshot.
;;
;; Error: etaf-runtime-error
;; ETAF runtime error
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-runtime-flush (&optional runtime)
;;;###autoload (autoload 'etaf-runtime-flush "etaf" nil nil)
;; Request mounted RUNTIME's pending work and return its committed revision.
;; This returns an integer, not an Ebox node.  Busy or batched work may remain
;; pending; the result identifies the currently committed Ebox publication.
;; An active Ebox transaction is rejected before requesting work, because
;; its current revision may still be provisional.  No tree is exported.
;; Use `etaf-runtime-snapshot' for an explicit snapshot.
;;
;; Function: etaf-runtime-set-input-finisher (runtime finisher)
;;;###autoload (autoload 'etaf-runtime-set-input-finisher "etaf" nil nil)
;; Set mounted RUNTIME's native input session finisher to FINISHER or nil.
;; The catalog's in-place text input registers a function while its session
;; is open; the framework runs it before a `press' dispatches to another
;; Host, so a superseded editing session finishes instead of deferring every
;; publication forever.  FINISHER receives RUNTIME and should finish the
;; session with the application's own keep/edit policy.  Setting nil removes
;; it.  A non-mounted Runtime or a non-function FINISHER signals an error.
;;
;; Function: etaf-runtime-input-finisher (x)
;;;###autoload (autoload 'etaf-runtime-input-finisher "etaf" nil nil)
;; Access slot "input-finisher" of `etaf-runtime' struct X.
;;
;; Function: etaf-runtime-for-buffer (buffer-or-name)
;;;###autoload (autoload 'etaf-runtime-for-buffer "etaf" nil nil)
;; Return the live Runtime mounted in BUFFER-OR-NAME, or nil.
;;
;; Function: etaf-runtime-generation (runtime)
;;;###autoload (autoload 'etaf-runtime-generation "etaf" nil nil)
;; Return RUNTIME's committed generation id.
;;
;; Function: etaf-runtime-handler-entries (runtime)
;;;###autoload (autoload 'etaf-runtime-handler-entries "etaf" nil nil)
;; Return committed handler contribution entries for RUNTIME.
;;
;; Function: etaf-runtime-host-ancestries (runtime host-refs)
;;;###autoload (autoload 'etaf-runtime-host-ancestries "etaf" nil nil)
;; Return committed semantic ancestries for HOST-REFS in RUNTIME.
;; This activation-local lookup visits the retained graph at most once, stopping
;; when all requested Hosts are found.  Callers use it only for overlapping hit
;; candidates; no second retained identity or layout index is maintained.
;;
;; Function: etaf-runtime-host-props-entries (runtime)
;;;###autoload (autoload 'etaf-runtime-host-props-entries "etaf" nil nil)
;; Return committed Host contribution entries for RUNTIME.
;;
;; Function: etaf-runtime-host-props-for (runtime host-ref)
;;;###autoload (autoload 'etaf-runtime-host-props-for "etaf" nil nil)
;; Return committed semantic Host props for HOST-REF in RUNTIME.
;; The plist spine is fresh; contained values preserve identity and are
;; read-only. Later geometry publication does not replace fields in this copy.
;;
;; Function: etaf-runtime-update-host-content (runtime host-ref content)
;;;###autoload (autoload 'etaf-runtime-update-host-content "etaf" nil nil)
;; Replace HOST-REF's published content with CONTENT in mounted RUNTIME.
;;
;; This is the content half of the retained Host display boundary, next to
;; `etaf-runtime-update-host-geometry'.  CONTENT is a string, published as the
;; Host's text, or an image object as returned by `create-image', published as
;; one image cell showing that image at its own size; a caller that keeps a
;; fixed-size Host live with per-frame images (video, charts, captures) passes
;; a new image object per update. Strings retain caller-owned display
;; properties, including image slices. Use a Text Host for changing media:
;; replacing a Box's content changes its child structure instead.
;; The update replaces only the addressed Host
;; and publishes once through Ebox, so a caller whose controlled state changed
;; one value skips an ordinary ETAF publication.  The next ordinary publication
;; must render the same content, or the retained Host is reconciled to it.  A
;; committed update returns t.  Unknown Hosts, unmounted Runtimes, CONTENT that
;; is neither a string nor an image, and Hosts whose retained node cannot hold
;; content signal `etaf-runtime-error' without a partial update.
;;
;; Function: etaf-runtime-update-host-contents (runtime updates)
;;;###autoload (autoload 'etaf-runtime-update-host-contents "etaf" nil nil)
;; Replace several HOST-REF contents in one retained Ebox publication.
;;
;; UPDATES is an alist of committed Host references to replacement strings or
;; image objects.  Every target validates before the first replacement, so a
;; caller keeping several small contents live (text and frames together)
;; publishes once per change instead of once per node.  A committed update
;; returns t.  Invalid targets or updates, unmounted Runtimes, active Ebox
;; transactions, and rejected content signal `etaf-runtime-error' without a
;; partial update.
;;
;; Function: etaf-runtime-update-host-geometry (runtime host-ref &rest geometry)
;;;###autoload (autoload 'etaf-runtime-update-host-geometry "etaf" nil nil)
;; Apply Ebox's typed incremental geometry update to HOST-REF in mounted RUNTIME.
;; GEOMETRY contains only low-level position, size and layer facts accepted by
;; `ebox-region-update-geometry'.  This is a display projection boundary for a
;; caller's already-updated controlled state: it does not change Component
;; props or implement window policy.  The next ordinary ETAF publication must
;; provide the same values, or the retained Host will be reconciled to that
;; publication.  A committed update returns t.  Invalid targets or geometry,
;; unmounted Runtimes, active Ebox transactions, and rejected geometry signal
;; `etaf-runtime-error' without a partial update.
;;
;; Function: etaf-runtime-update-host-geometries (runtime updates)
;;;###autoload (autoload 'etaf-runtime-update-host-geometries "etaf" nil nil)
;; Apply several HOST-REF/GEOMETRY pairs in one retained Ebox publication.
;; UPDATES is an alist whose keys are committed Host references and whose values
;; are geometry plists.  All targets validate before the batch starts.  A single
;; entry first reuses RUNTIME's retained `ebox-geometry-prepare' operation for
;; that Host and property set, so repeated moves and fixed-text resizes publish
;; without ordinary layout; declined or multi-Host updates use the ordinary
;; geometry batch with the same result.  A committed update returns t.  Invalid
;; targets or updates, unmounted Runtimes, active Ebox transactions, and
;; rejected geometry signal `etaf-runtime-error' without a partial update.
;;
;; Function: etaf-runtime-instances (x)
;;;###autoload (autoload 'etaf-runtime-instances "etaf" nil nil)
;; Access slot "instances" of `etaf-runtime' struct X.
;;
;;
;; Function: etaf-runtime-mounted-p (x)
;;;###autoload (autoload 'etaf-runtime-mounted-p "etaf" nil nil)
;; Access slot "mounted-p" of `etaf-runtime' struct X.
;;
;;
;; Function: etaf-runtime-refit (runtime viewport-width &optional viewport-height)
;;;###autoload (autoload 'etaf-runtime-refit "etaf" nil nil)
;; Refit mounted RUNTIME to VIEWPORT-WIDTH pixels and VIEWPORT-HEIGHT lines.
;; The call re-resolves viewport units and viewport-dependent layout through
;; the selected renderer port, so the framework's publication accounting sees
;; it like any other publication.  Return non-nil when the renderer refitted a
;; mounted surface; RUNTIME defaults to the Runtime in the current buffer, and
;; a non-mounted Runtime signals `etaf-runtime-error'.
;;
;; Function: etaf-runtime-viewport (&optional runtime)
;;;###autoload (autoload 'etaf-runtime-viewport "etaf" nil nil)
;; Return mounted RUNTIME's canvas viewport as (WIDTH . HEIGHT).
;; WIDTH is pixels and HEIGHT is lines; the value matches the renderer's
;; display-safe window size and follows `etaf-runtime-refit', including the
;; automatic refit after a window size change.  RUNTIME defaults to the Runtime
;; in the current buffer, and a non-mounted Runtime signals
;; `etaf-runtime-error'.
;;
;; Function: etaf-runtime-root-node (runtime)
;;;###autoload (autoload 'etaf-runtime-root-node "etaf" nil nil)
;; Return RUNTIME's current root through an explicit detached snapshot.
;; This obsolete read-compatible getter costs O(N); no root mirror is stored.
;; Use `etaf-runtime-snapshot' to retain the root's matching source facts.
;;
;; Function: etaf-runtime-snapshot (&optional runtime)
;;;###autoload (autoload 'etaf-runtime-snapshot "etaf" nil nil)
;; Export mounted RUNTIME's currently committed Ebox snapshot.
;; Return a plist with `:input' (a canonical Ebox input), `:revision', and
;; `:mount-id'.  The export costs O(N), detaches mutable node payload, and keeps
;; opaque callback identities.  It neither drains pending work nor evaluates
;; Components, publishes, or increments the revision.  Unmounted Runtimes and
;; reads inside an Ebox transaction signal an error.
;;
;; Error: etaf-scheduler-error
;; Invalid ETAF scheduler operation
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-scope-run (scope function &key (watch-scheduler nil watch-scheduler-p))
;;;###autoload (autoload 'etaf-scope-run "etaf" nil nil)
;; Run FUNCTION with active SCOPE and optional WATCH-SCHEDULER.
;;
;; Function: etaf-scope-stop (scope)
;;;###autoload (autoload 'etaf-scope-stop "etaf" nil nil)
;; Dispose SCOPE and return cleanup conditions collected during teardown.
;; Stop child Scopes and owned effects, then run registered cleanup functions.
;; Errors and quits from cleanup are returned as condition data, not re-signaled;
;; remaining cleanup still runs. Stopping an already stopped Scope returns nil.
;; After stopping, SCOPE cannot be entered or accept effects or cleanup.
;; Call outside rendering; Component-owned Scopes are stopped automatically.
;;
;; Function: etaf-on-scope-dispose (function)
;;;###autoload (autoload 'etaf-on-scope-dispose "etaf" nil nil)
;; Register zero-argument FUNCTION for the current active Scope's disposal.
;; Return FUNCTION. Cleanup runs once, in reverse registration order, after
;; child Scopes and effects stop. A missing or stopped Scope signals an error.
;; Cleanup errors are collected by `etaf-scope-stop` without aborting teardown.
;;
;; Function: etaf-set-value (source new-value)
;;;###autoload (autoload 'etaf-set-value "etaf" nil nil)
;; Set writable reactive SOURCE to NEW-VALUE and return NEW-VALUE.
;;
;; Error: etaf-spi-bootstrap-error
;; Malformed Ebox framework SPI provider
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Error: etaf-spi-incompatible-error
;; Incompatible Ebox framework SPI provider
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-state ()
;;;###autoload (autoload 'etaf-state "etaf" nil nil)
;; Return the current Component instance's exact setup result.
;; The accessor is valid only while rendering a Component that declares setup.
;; A defined setup may return nil; setup presence is tracked independently.
;; Prefer named `:bindings' for handles used by the View and event callbacks.
;; Components using named bindings cannot also use this accessor.
;;
;; Function: etaf-theme-current-mode ()
;;;###autoload (autoload 'etaf-theme-current-mode "etaf" nil nil)
;; Return the current frame color mode as `light' or `dark'.
;;
;; This is only the default mode for palette resolution.  An application-owned
;; Theme toggle should pass its explicit mode to `etaf-theme-resolve-palette'
;; instead of changing the Emacs frame.
;;
;; Function: etaf-theme-provide (theme)
;;;###autoload (autoload 'etaf-theme-provide "etaf" nil nil)
;; Provide THEME property defaults to the current Component subtree.
;;
;; THEME is a property plist such as `(:color "#F4F6FB" :bgcolor "#202634")'.
;; Defaults enter Ebox as UA-origin declarations and follow ECSS precedence,
;; including UA-important precedence over author-important values. Normal Host
;; and Component declarations override normal defaults. Reactive ref/computed
;; plists remain tracked; invalid resolved values reject candidate publication.
;;
;; Function: etaf-theme-resolve-palette (palette mode)
;;;###autoload (autoload 'etaf-theme-resolve-palette "etaf" nil nil)
;; Resolve semantic PALETTE token specs for explicit MODE.
;;
;; PALETTE is a keyword plist.  Each value may be a color string, a
;; `(LIGHT . DARK)' pair, or a `(:light LIGHT :dark DARK)' plist.  MODE is
;; `light' or `dark'.  The result is an ordinary Theme plist suitable for
;; `etaf-theme-provide'.  ETAF owns this semantic contract; a renderer-specific
;; palette package may adapt its own registry into this shape at the boundary.
;;
;; Function: etaf-theme-token (key &optional default transform)
;;;###autoload (autoload 'etaf-theme-token "etaf" nil nil)
;; Return a deferred Theme token for a static Component style.
;;
;; KEY is resolved when ETAF lowers the Component's `:styles' declaration, so a
;; static rule can use the current inherited Theme without turning every retained
;; Host into an inline dynamic property.  DEFAULT is used when KEY is absent.
;; TRANSFORM, when non-nil, is a pure function applied after nested defaults have
;; resolved; it lets a semantic color token lower to a backend value such as a
;; border specification without reading Theme during Component render.
;; The returned list is intentionally data, which also makes it safe to place
;; directly in a quoted `((SELECTOR PROPERTY VALUE ...) ...)' form.
;;
;; Function: etaf-theme-token-p (value)
;;;###autoload (autoload 'etaf-theme-token-p "etaf" nil nil)
;; Return non-nil when VALUE is a deferred ETAF Theme token.
;;
;; Function: etaf-toggleable (&rest attributes)
;;;###autoload (autoload 'etaf-toggleable "etaf" nil nil)
;; Return a Behavior converting ATTRIBUTES into a toggleable press action.
;;
;; `:value' and `:on-change' configure the action; all other attributes remain
;; part of the returned Behavior.
;;
;; Function: etaf-draggable-controlled (read on-change &key axis delta on-start on-move on-end on-cancel)
;;;###autoload (autoload 'etaf-draggable-controlled "etaf" nil nil)
;; Return a controlled drag Behavior for aggregate geometry state.  READ returns
;; a plist with :x/:y facts; ON-CHANGE receives the next detached plist.  AXIS
;; selects x, y or both.  DELTA converts Ebox pixel movement to caller units.
;; The Behavior retains only a transient gesture origin.  Construct the
;; Behavior once in a retained `:bindings' owner (or another retained owner),
;; not inside `:render': a render-created closure is a new handler identity and
;; cannot carry an active gesture across a parent projection.
;;
;; Function: etaf-resizable-controlled (read on-change &key edges min-width max-width min-height max-height delta on-start on-resize on-end on-cancel)
;;;###autoload (autoload 'etaf-resizable-controlled "etaf" nil nil)
;; Return a controlled resize Behavior for aggregate :x/:y/:width/:height
;; state.  EDGES defaults to right and bottom; READ supplies the current
;; numeric geometry and ON-CHANGE receives the next detached geometry plist.
;; Bounds and DELTA conversion are applied before the callback.  The Behavior
;; does not retain persistent application geometry.  Construct it once in a
;; retained `:bindings' owner when a parent may render during a gesture; a
;; render-created closure intentionally starts a fresh Behavior lifecycle.
;;
;; Function: etaf-draggable (&key x y axis delta on-start on-move on-end on-cancel)
;;;###autoload (autoload 'etaf-draggable "etaf" nil nil)
;; Return a Behavior that moves caller-owned numeric coordinate refs from Ebox
;; drag deltas.  X and Y must be writable `etaf-ref' values for the selected
;; AXIS (nil infers x, y, or both).  Each move and end writes the refs through
;; the normal reactive boundary; Ebox retains the gesture target and ETAF owns
;; no window or pointer state.  Optional callbacks receive the source gesture;
;; move/end run after writes and cancel leaves the last accepted values.
;;
;; Function: etaf-resizable (&key x y width height edges min-width max-width min-height max-height delta on-start on-resize on-end on-cancel)
;;;###autoload (autoload 'etaf-resizable "etaf" nil nil)
;; Return a Behavior that resizes caller-owned numeric geometry refs from Ebox
;; drag deltas.  EDGES defaults to right and bottom; left/top also update X/Y
;; so the opposite edge stays fixed.  WIDTH/HEIGHT and required coordinate refs
;; must be writable `etaf-ref' values.  Numeric min/max bounds clamp candidates
;; before publication.  Optional callbacks receive the source gesture and
;; resize/end run after refs are updated.  This Behavior has no desktop-window
;; policy and does not call Ebox private APIs.
;;
;; Function: etaf-unmount (&optional runtime)
;;;###autoload (autoload 'etaf-unmount "etaf" nil nil)
;; Unmount RUNTIME, defaulting to the active or `current-buffer' Runtime.
;;
;; Function: etaf-value (source)
;;;###autoload (autoload 'etaf-value "etaf" nil nil)
;; Read reactive SOURCE and track the read in the current effect.
;;
;; Function: etaf-update-value (source function &rest arguments)
;;;###autoload (autoload 'etaf-update-value "etaf" nil nil)
;; Replace writable ref SOURCE with FUNCTION applied to its current value and
;; ARGUMENTS, returning the replacement.  For example:
;; (etaf-update-value count #'+ 2).  FUNCTION runs once; it must return a new
;; value without mutating the old value or performing external effects.
;; Rendering and read-only sources are rejected before FUNCTION runs.  An
;; updater error leaves the ref unchanged.  A later publication error retains
;; the application write, as with `etaf-set-value'.  Existing shallow equality,
;; reactive tracking and event batching apply; there is no implicit deep copy.
;;
;; Component: etaf-video (&key src (columns 100) (rows 30) (mode 'image) (ramp etaf-video-density-ramp) (audio etaf-video-audio) (volume etaf-video-audio-volume) (speed 1) (autoplay t) handle device-pixel-ratio display-fps position left top z-index)
;; Render a live video source in a fixed COLUMNS by ROWS canvas.
;;
;; SRC is nil for the built-in demo, a local file name, an HTTP(S) URL, or a
;; plist accepted by the video source normalizer.  MODE is `image' (one scaled
;; JPEG per frame, graphical frames only, falling back to `ascii' elsewhere),
;; `ascii' (one density-ramp character per pixel) or `color' (two full-color
;; pixels per `▀' half-block cell).  RAMP defaults to
;; `etaf-video-density-ramp', AUDIO/VOLUME/SPEED configure playback, and
;; AUTOPLAY starts it at mount; without AUTOPLAY the first frame is shown
;; paused.  DEVICE-PIXEL-RATIO overrides the display's device pixel ratio for
;; `image' frames so Retina screens stay sharp.  DISPLAY-FPS is nil (use
;; `etaf-video-display-fps') or a positive integer presentation-rate cap.
;; Image frames share one image across row-height slices so adjacent content
;; and controls below the canvas retain their normal line heights.  POSITION,
;; LEFT, TOP and Z-INDEX place the canvas; they are declared on the canvas node
;; itself so the retained content route can prove an inline placement winner
;; even when the canvas sits deep in an application layout.
;; AUDIO, VOLUME and SPEED also accept refs/computed sources; the Component
;; reads them in its playback effect, not its View. Live volume must stay
;; within 0..100 and speed must remain positive. Their identity can stay fixed
;; while a shared UI control updates the value without rebuilding the shell.
;;
;; HANDLE is a symbol registered while mounted for the `etaf-video-play'
;; family of control functions; a video without a handle still plays itself.
;;
;; Function: etaf-video-play (handle)
;;;###autoload (autoload 'etaf-video-play "etaf" nil nil)
;; Start or resume the mounted video identified by HANDLE.
;;
;; Function: etaf-video-pause (handle)
;;;###autoload (autoload 'etaf-video-pause "etaf" nil nil)
;; Pause the mounted video identified by HANDLE, keeping the last picture.
;;
;; Function: etaf-video-toggle-playback (handle)
;;;###autoload (autoload 'etaf-video-toggle-playback "etaf" nil nil)
;; Toggle the mounted video identified by HANDLE between play and pause.
;;
;; Function: etaf-video-step (handle)
;;;###autoload (autoload 'etaf-video-step "etaf" nil nil)
;; Pause the mounted video identified by HANDLE and present one more frame.
;;
;; Function: etaf-video-seek (handle seconds)
;;;###autoload (autoload 'etaf-video-seek "etaf" nil nil)
;; Move the mounted video identified by HANDLE to SECONDS.
;;
;; Function: etaf-video-set-speed (handle speed)
;;;###autoload (autoload 'etaf-video-set-speed "etaf" nil nil)
;; Set the playback rate of the mounted video identified by HANDLE.
;;
;; Function: etaf-video-set-volume (handle volume)
;;;###autoload (autoload 'etaf-video-set-volume "etaf" nil nil)
;; Set the audio volume of the mounted video identified by HANDLE, 0 to 100.
;;
;; Function: etaf-video-set-audio (handle audio)
;;;###autoload (autoload 'etaf-video-set-audio "etaf" nil nil)
;; Turn the audio sidecar of the mounted video identified by HANDLE on or off.
;;
;; Function: etaf-video-source-info (source)
;;;###autoload (autoload 'etaf-video-source-info "etaf" nil nil)
;; Return SOURCE's normalized playback metadata as a plist.
;;
;; SOURCE is nil for the built-in demo, a local file name, an HTTP(S) URL, or
;; a plist accepted by the `etaf-video' Component.  The result holds `:kind',
;; `:file', `:url', `:target', `:width', `:height', `:duration', `:fps' and
;; `:audio'.  Values come from ffprobe when it runs; a missing ffprobe keeps
;; documented defaults.  The result is authoritative metadata and can be
;; passed back as the Component's `:src' without another probe, so an
;; application that resizes or restarts a video keeps them.  Unsupported
;; sources and unreadable files signal `user-error'.
;;
;; Function: etaf-video-state (handle)
;;;###autoload (autoload 'etaf-video-state "etaf" nil nil)
;; Return the mounted video identified by HANDLE as a detached plist.
;; Keys are `:handle', `:mode', `:source', `:playing', `:position',
;; `:duration', `:speed', `:format', `:width', `:height', `:display-fps',
;; `:source-fps', `:received', `:presented', `:dropped', `:audio' and
;; `:ended'.  A handle with no mounted video signals `user-error'.
;;
;; Variable: etaf-video-audio
;; Whether new videos play their source's audio track by default.
;; A `etaf-video' Component's `:audio' property overrides it per instance.
;;
;; Variable: etaf-video-audio-volume
;; Default audio volume for new videos, from 0 to 100.
;;
;; Variable: etaf-video-density-ramp
;; Characters used for one video pixel in the `ascii' render mode,
;; from darkest to lightest; must be nonempty and single-line.
;;
;; Variable: etaf-video-display-fps
;; Display timer rate in frames per second for new video playback.
;; It caps the presented frame rate; values below 1 are raised to 1.
;;
;; Variable: etaf-video-ffmpeg-program
;; Name or absolute path of the ffmpeg executable used to decode video.
;;
;; Variable: etaf-video-ffplay-program
;; Name or absolute path of the ffplay executable used for audio.
;;
;; Variable: etaf-video-ffprobe-program
;; Name or absolute path of the ffprobe executable used for metadata.
;;
;; Macro: etaf-view (form &optional _environment)
;;;###autoload (autoload 'etaf-view "etaf" nil nil 'macro)
;; Construct a normalized ETAF View from structural FORM.
;;
;; FORM uses one grammar for Hosts and Component calls:
;;
;;   (NAME :PROPERTY VALUE ... CHILD ...)
;;
;; Properties must come first and children must come last.  Property values are
;; ordinary Elisp expressions.  In structural child positions, `(expr FORM)'
;; returns nil, strings, typed Views, or proper sequences of those values.
;; Inside a `text' Host, an expression must return one string.
;;
;; The core Hosts are `text', `box', `row', `column', `flex', `grid' and
;; `image'.  `image' renders one local media file as a fixed cell grid and
;; takes :src (a file path), :columns and :rows (positive integers) plus an
;; optional :adapter (`auto', `text' or `placeholder').  Unreadable or
;; undecodable sources become a placeholder instead of failing the render, and
;; the image owns its size, clipping and wrapping; wrap it in ordinary Boxes
;; for spacing, paint and interaction.
;;
;; Error: etaf-view-error
;; Invalid ETAF View
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Error: etaf-view-syntax-error
;; Invalid ETAF View syntax
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-watch (source callback &key immediate (flush 'pre) test name)
;;;###autoload (autoload 'etaf-watch "etaf" nil nil)
;; Watch SOURCE and call CALLBACK with NEW and OLD values.
;;
;; IMMEDIATE calls CALLBACK for the initial value.  FLUSH is passed to the
;; current Runtime scheduler.  TEST and NAME customize comparison and
;; diagnostics.  Return a stop function.
;;
;; Function: etaf-watch-effect (function &key (flush 'pre) name)
;;;###autoload (autoload 'etaf-watch-effect "etaf" nil nil)
;; Run FUNCTION immediately and again after a reactive dependency change.
;;
;; FLUSH selects the Runtime scheduler boundary.  NAME optionally labels the
;; effect.  If FUNCTION returns a function, it cleans up the previous run.
;;

;; Function: etaf-retained-resize-open (&optional buffer-or-name)
;;;###autoload (autoload 'etaf-retained-resize-open "etaf" nil t)
;; Mount a fixed-text resize example, returning BUFFER-OR-NAME (default
;; *ETAF Retained Resize*). Interactive calls display it. Native drag and
;; Shift-locked drag resize a clipped panel through controlled state and the
;; ordinary mounted Runtime; Escape restores its starting dimensions.
;; This example does not implement catalog window chrome or paragraph reflow.
;; Reopening replaces its existing mount; unrelated nonempty buffers are refused.
;; Unmount or kill the buffer to release it.
;;
;; Function: etaf-resource-example-open ()
;;;###autoload (autoload 'etaf-resource-example-open "etaf" nil t)
;; Mount the asynchronous Resource example in *ETAF Resource Example* and
;; return that buffer. Interactive calls display it. Reloading, simulated
;; failure and cancellation use the displayed buttons. Repeated opens replace
;; the previous mount, releasing its pending work and loaded value.
;;
;; Function: etaf-resource-example-close ()
;;;###autoload (autoload 'etaf-resource-example-close "etaf" nil t)
;; Unmount and kill *ETAF Resource Example*. Repeated closing is harmless.
;;
;; Function: etaf-list-cache-create (&key interval grace max-backoff stop-codes)
;;;###autoload (autoload 'etaf-list-cache-create "etaf" nil nil)
;; Return a list cache with INTERVAL seconds of freshness and GRACE seconds.
;; A session keeps one cache and stores each list under its own key together
;; with the time it arrived, so a list can be shown at once and compared with a
;; fresh reply in the background (stale-while-revalidate).  INTERVAL defaults
;; to 120 and GRACE to 3: no background refresh starts in the first GRACE
;; seconds after the cache is started or armed.  Failed refreshes back off
;; (doubling up to MAX-BACKOFF seconds, default 1800) and one that fails with
;; a STOP-CODE (auth and blocked by default) pauses them until a load
;; succeeds.
;;
;; Function: etaf-list-cache-put (cache key rows total &key version at)
;;;###autoload (autoload 'etaf-list-cache-put "etaf" nil nil)
;; Cache ROWS and TOTAL under KEY and return the stored entry.
;; The entry records its arrival time, which is what the staleness rule and the
;; background refresh order read; the backend reply stays the source of truth.
;; VERSION, when the backend offers a version token, is stored so a caller can
;; send it with the next request. AT optionally supplies a persisted observation
;; time (nonnegative seconds since epoch); future times are clamped to now.
;; Omitting AT records the current time. Invalid AT leaves the cache unchanged.
;;
;; Function: etaf-list-cache-version (cache key)
;;;###autoload (autoload 'etaf-list-cache-version "etaf" nil nil)
;; Return KEY's stored version token, or nil.
;;
;; Function: etaf-list-cache-touch (cache key &optional version)
;;;###autoload (autoload 'etaf-list-cache-touch "etaf" nil nil)
;; Mark KEY's entry as just checked without replacing its rows.
;; A backend that answers that nothing changed for a conditional request
;; reports it here, so the entry is fresh again and no repaint happens.
;;
;; Function: etaf-list-cache-note-success (cache)
;;;###autoload (autoload 'etaf-list-cache-note-success "etaf" nil nil)
;; Record that a load succeeded: clear the failure backoff and any pause.
;;
;; Function: etaf-list-cache-note-failure (cache &optional code)
;;;###autoload (autoload 'etaf-list-cache-note-failure "etaf" nil nil)
;; Record that a load failed with error CODE and throttle the retries.
;; An unknown CODE backs the next attempt off; a stop-code (auth, blocked)
;; pauses background refreshes until a load succeeds.
;;
;; Function: etaf-list-cache-blocked-p (cache)
;;;###autoload (autoload 'etaf-list-cache-blocked-p "etaf" nil nil)
;; Return non-nil when CACHE paused background refreshes until a load succeeds.
;;
;; Function: etaf-list-cache-retry-at (cache)
;;;###autoload (autoload 'etaf-list-cache-retry-at "etaf" nil nil)
;; Return the time before which CACHE starts no background refresh, or nil.
;;
;; Function: etaf-list-cache-entry (cache key)
;;;###autoload (autoload 'etaf-list-cache-entry "etaf" nil nil)
;; Return KEY's cached entry (:rows :total :at), or nil.
;;
;; Function: etaf-list-cache-rows (cache key)
;;;###autoload (autoload 'etaf-list-cache-rows "etaf" nil nil)
;; Return KEY's cached rows, or nil.
;;
;; Function: etaf-list-cache-total (cache key)
;;;###autoload (autoload 'etaf-list-cache-total "etaf" nil nil)
;; Return KEY's cached total, or 0.
;;
;; Function: etaf-list-cache-stale-p (cache key &optional now interval)
;;;###autoload (autoload 'etaf-list-cache-stale-p "etaf" nil nil)
;; Return non-nil when KEY's entry is older than INTERVAL seconds.
;; NOW defaults to the current time and INTERVAL to the cache's own interval;
;; a key without an entry is missing rather than stale.
;;
;; Function: etaf-list-cache-unchanged-p (cache key rows total)
;;;###autoload (autoload 'etaf-list-cache-unchanged-p "etaf" nil nil)
;; Return non-nil when ROWS and TOTAL equal what KEY already holds.
;; A caller uses this to leave the page untouched when a background reply did
;; not change anything.
;;
;; Function: etaf-list-cache-next (cache keys &optional now interval)
;;;###autoload (autoload 'etaf-list-cache-next "etaf" nil nil)
;; Return the KEY that a background refresh should load next, or nil.
;; KEYS is the caller's ordered list of candidates; the stalest stale entry
;; comes first, and when every entry is fresh the first KEY without an entry is
;; warmed.  Nil while the cache is busy, inside its grace period, or when every
;; KEY is fresh and cached, so one refresh runs at a time.
;;
;; Function: etaf-list-cache-start (cache)
;;;###autoload (autoload 'etaf-list-cache-start "etaf" nil nil)
;; Start CACHE: begin its grace period and allow background refreshes.
;; A caller that already runs its own timer starts the cache once and then asks
;; `etaf-list-cache-next' what to load.
;;
;; Function: etaf-list-cache-arm (cache function &key interval)
;;;###autoload (autoload 'etaf-list-cache-arm "etaf" nil nil)
;; Arm CACHE to call FUNCTION every INTERVAL seconds until disarmed.
;; Uses INTERVAL, or the cache's own interval.  Arming again replaces the
;; previous timer and restarts the grace period; FUNCTION takes no arguments
;; and usually loads the key `etaf-list-cache-next' returns.
;;
;; Function: etaf-list-cache-armed-p (cache)
;;;###autoload (autoload 'etaf-list-cache-armed-p "etaf" nil nil)
;; Return non-nil when CACHE has a background refresh timer armed.
;;
;; Function: etaf-list-cache-busy-p (cache)
;;;###autoload (autoload 'etaf-list-cache-busy-p "etaf" nil nil)
;; Return non-nil when CACHE has a background refresh in flight.
;;
;; Function: etaf-list-cache-set-busy (cache busy)
;;;###autoload (autoload 'etaf-list-cache-set-busy "etaf" nil nil)
;; Record that CACHE has, or has not, a background refresh in flight.
;;
;; Function: etaf-list-cache-disarm (cache)
;;;###autoload (autoload 'etaf-list-cache-disarm "etaf" nil nil)
;; Stop CACHE's background refresh and clear its busy marker.
;; Call it when the owning session is disposed; a disarmed cache reports no
;; background work even after its entries grow old.
;;
;;; Code:

;;;###autoload
(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name "lisp"
                                 (file-name-directory
                                  (or load-file-name
                                      (bound-and-true-p byte-compile-current-file)
                                      buffer-file-name)))))

(require 'etaf-view)
(require 'etaf-compiler)
(require 'etaf-component)
(require 'etaf-scheduler)
(require 'etaf-reactive)
(require 'etaf-observer)
(require 'etaf-context)
(require 'etaf-resource)
(require 'etaf-data)
(require 'etaf-generation)
(require 'etaf-host)
(require 'etaf-retirement)
(require 'etaf-render-port)
(require 'etaf-renderer)
(require 'etaf-runtime)
(require 'etaf-host-update)
(require 'etaf-host-cohort)
(require 'etaf-behavior)
(require 'etaf-controlled-behavior)
(require 'etaf-actions)
(require 'etaf-list-cache)
(require 'etaf-events)
(require 'etaf-performance)
(require 'etaf-video-component)

(autoload 'etaf-retained-resize-open "examples/etaf-retained-resize" nil t)
(autoload 'etaf-resource-example-open "examples/etaf-resource-example" nil t)
(autoload 'etaf-resource-example-close "examples/etaf-resource-example" nil t)

(unless (fboundp 'ebox-call-with-render-burst)
  (error "ETAF requires an Ebox build with framework render-burst support"))

(provide 'etaf)
;;; etaf.el ends here
