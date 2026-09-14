;;; etaf.el --- Text application framework facade -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: ETAF contributors
;; Version: 0.2.1
;; Package-Requires: ((emacs "29.1") (ebox "3.0.0") (ecss "0.1.0") (tp "2.0.0"))
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
;; Error: etaf-component-call-error
;; Invalid ETAF Component call
;; Catch this condition with condition-case; failed calls do not return a value.
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
;; computed value.
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
;; Function: etaf-data-controller (source &key query (page 1) (page-size 20) selection auto-load name item-key owner-scope initial-result)
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
;; Load CONTROLLER from its source and publish loading, success, or error.
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
;; Run source OPERATION with PAYLOAD, then reload CONTROLLER.
;;
;; Errors are stored in the controller error ref and re-signaled.  Return the
;; source mutation result after the reload succeeds.
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
;; Function: etaf-data-reload (controller)
;;;###autoload (autoload 'etaf-data-reload "etaf" nil nil)
;; Reload CONTROLLER and return the source result.
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
;; never changes the v1 callback.  `:dispose' is optional and runs when the owning
;; controller stops.  `:item-key' optionally returns stable selection identity
;; for one item.  `:provider' may name the source in observation reports and
;; defaults to `data'.
;;
;; Function: etaf-data-source-load-page (source &optional query page page-size)
;;;###autoload (autoload 'etaf-data-source-load-page "etaf" nil nil)
;; Load and normalize one SOURCE page without creating a Controller.
;; QUERY is passed through unchanged.  PAGE and PAGE-SIZE default to 1 and 20.
;; This public preparation boundary performs no reactive publication; callers may
;; use its result as `:initial-result' for `etaf-data-controller'.
;;
;; Function: etaf-data-status (controller)
;;;###autoload (autoload 'etaf-data-status "etaf" nil nil)
;; Return CONTROLLER's status ref.
;;
;; The status value is one of `idle', `loading', `success', or `error'.
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
;;     [:setup SETUP]
;;     :view VIEW
;;     :styles ((SELECTOR ATTR ...)))
;;
;; or:
;;
;;   (etaf-define-component NAME (&key PROPS)
;;     [:bindings ((NAME INITIALIZER) ...)]
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
;; Keep reactive value reads inside the View properties or expressions they
;; update.  Use `etaf-prop' in a binding initializer for a tracked input; a plain
;; prop variable in initialization is an initial snapshot.
;;
;; Props accept NAME or (NAME DEFAULT) after &key.  Defaults evaluate in order
;; on first missing input and can read earlier props.  Explicit nil is supplied.
;; Mounted instances retain successfully published defaults until replacement or
;; unmount; pure rendering evaluates defaults anew.  Default expressions must be
;; safe to retry after rejected publication; allocate mutable values explicitly.
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
;; Function: etaf-dispatch-event (runtime host-ref kind &optional payload (payload-p nil))
;;;###autoload (autoload 'etaf-dispatch-event "etaf" nil nil)
;; Dispatch KIND for HOST-REF through mounted RUNTIME.
;;
;;   When PAYLOAD-P is non-nil, pass PAYLOAD as the callback's only argument;
;; otherwise call the local callback with no arguments.
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
;; Function: etaf-host-ref-bounds (runtime host-ref)
;;;###autoload (autoload 'etaf-host-ref-bounds "etaf" nil nil)
;; Return live Ebox bounds for HOST-REF in mounted RUNTIME.
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
;;
;; TEST optionally compares old and new values.  NAME is used in diagnostics.
;;
;; Function: etaf-ref-p (x)
;;;###autoload (autoload 'etaf-ref-p "etaf" nil nil)
;;
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
;; Function: etaf-resource (loader &key (immediate t) scope name)
;;;###autoload (autoload 'etaf-resource "etaf" nil nil)
;; Create a Resource backed by synchronous LOADER.
;;
;; The Resource owns a child Scope under SCOPE, or under the current active Scope
;; when SCOPE is nil.  Without any parent Scope it creates a detached Scope.
;; When IMMEDIATE is non-nil, load the Resource before returning it.
;;
;; Function: etaf-resource-dispose (resource)
;;;###autoload (autoload 'etaf-resource-dispose "etaf" nil nil)
;; Dispose RESOURCE and return cleanup errors collected by its Scope.
;;
;; Function: etaf-resource-error (resource)
;;;###autoload (autoload 'etaf-resource-error "etaf" nil nil)
;; Return RESOURCE's captured loader condition, or nil when not in error.
;; This reader tracks Resource state and returns the condition directly,
;; without requiring `etaf-value`. Treat the returned condition as read-only.
;;
;; Error: etaf-resource-error
;; Invalid ETAF Resource operation, such as reloading a disposed Resource.
;; Catch with condition-case. Loader failures are instead captured as Resource
;; state and inspected with the same-named reader function.
;;
;; Function: etaf-resource-load (resource)
;;;###autoload (autoload 'etaf-resource-load "etaf" nil nil)
;; Reload RESOURCE and return it.
;;
;; Only LOADER errors are captured into Resource state.  Cleanup failures and
;; wrong Resource usage continue to signal normally.
;;
;; Function: etaf-resource-result (value &key cleanup)
;;;###autoload (autoload 'etaf-resource-result "etaf" nil nil)
;; Return a Resource loader result containing VALUE and optional CLEANUP.
;;
;; CLEANUP must be nil or a zero-argument function.  It runs before the next
;; successful load replaces the resource value, and when the Resource is
;; disposed.
;;
;; Function: etaf-resource-status (resource)
;;;###autoload (autoload 'etaf-resource-status "etaf" nil nil)
;; Return RESOURCE status: `loading', `success', or `error'.
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
;;
;; Function: etaf-runtime-current-generation (runtime)
;;;###autoload (autoload 'etaf-runtime-current-generation "etaf" nil nil)
;; Return RUNTIME's uniquely authoritative committed generation.
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
;; An active Ebox/TP transaction is rejected before requesting work, because
;; its current revision may still be provisional.  No tree is exported.
;; Use `etaf-runtime-snapshot' for an explicit snapshot.
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
;; reads inside an Ebox/TP transaction signal an error.
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
;; Macro: etaf-theme-define-palette (name &rest plist)
;;;###autoload (autoload 'etaf-theme-define-palette "etaf" nil nil 'macro)
;; Define a TP palette NAME from PLIST for the ETAF Theme adapter.
;;
;; The palette registry remains owned by TP; this wrapper keeps an application
;; from depending on the lower-level `tp-define-palette' spelling in its View or
;; Component modules.
;;
;; Function: etaf-theme-from-tp-palettes (bindings mode)
;;;###autoload (autoload 'etaf-theme-from-tp-palettes "etaf" nil nil)
;; Return an ETAF Theme plist from TP palette BINDINGS in MODE.
;;
;; BINDINGS is a keyword plist whose values are `(PALETTE . CHANNEL)' pairs,
;; where PALETTE is a TP palette symbol and CHANNEL is `:fg', `:bg', or
;; `:border'.  MODE is explicitly `light' or `dark'; the current Emacs frame is
;; never consulted, so an application Theme toggle remains independent of frame
;; appearance.
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
;; Macro: etaf-view (form)
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
(require 'etaf-behavior)
(require 'etaf-actions)
(require 'etaf-events)
(require 'etaf-theme-tp)
(require 'etaf-performance)

(unless (fboundp 'ebox-call-with-render-burst)
  (error "ETAF requires an Ebox build with framework render-burst support"))

(provide 'etaf)
;;; etaf.el ends here
