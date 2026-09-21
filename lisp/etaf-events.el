;;; etaf-events.el --- ETAF event, activation, and focus ports -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Events are Runtime-owned entry points into committed `:on-*' callbacks.
;; Ebox owns native targeting, focus and input lifetime; this module connects
;; those capabilities to application callbacks and reactive batches.

;;; Code:

(require 'cl-lib)
(require 'ebox)
(require 'etaf-scheduler)
(require 'etaf-reactive)
(require 'etaf-runtime)

(defvar etaf--current-runtime)
(defvar etaf--observer-context)

(declare-function etaf-runtime-require-mounted "etaf-runtime" (&optional runtime))
(declare-function etaf-runtime-p "etaf-runtime" (value))
(declare-function etaf-runtime-mounted-p "etaf-runtime" (runtime))
(declare-function etaf-runtime-buffer "etaf-runtime" (runtime))
(declare-function etaf-runtime-handler-for "etaf-runtime" (runtime host-ref))
(declare-function etaf-runtime-handler-entries "etaf-runtime" (runtime))
(declare-function etaf-runtime-host-props-for "etaf-runtime" (runtime host-ref))
(declare-function etaf-runtime-host-props-entries "etaf-runtime" (runtime))
(declare-function etaf-runtime-host-ancestries "etaf-runtime" (runtime host-refs))
(declare-function etaf-runtime-host-ancestor-refs "etaf-runtime" (runtime host-ref))
(declare-function etaf-runtime-event-begin "etaf-runtime" (runtime))
(declare-function etaf-runtime-event-end "etaf-runtime" (runtime))
(declare-function etaf-runtime-observer "etaf-runtime" (runtime))
(declare-function etaf-runtime-call-operation
                  "etaf-runtime" (runtime kind label function))
(declare-function ebox-call-with-render-burst
                  "ebox-buffer-backend" (function &rest arguments))
(declare-function ebox-call-with-input "ebox" (host-ref reader &optional buffer-or-name))

(define-error 'etaf-event-error "Invalid ETAF Event")

(defvar etaf--current-event nil
  "Event context active while one Runtime callback runs.")

(defvar etaf--drag-cancel-p nil
  "Non-nil while Ebox delivers the terminal cancellation of an active drag.")

(defvar etaf--event-bubbling nil
  "Non-nil while dispatching one event's ancestor capture callbacks.")

;;;###autoload
(defun etaf-call-with-input (reader)
  "Run native input READER for the current event's committed Host.
Call from an event callback; no Runtime or Host reference is needed.  Ebox
owns target validity and focus restoration, while READER owns the native
editing session.  Return its result only if the target is still valid.
Errors and user quit propagate; target invalidation signals a subtype of
`quit'.  No application value is applied by this function."
  (etaf--assert-not-rendering 'read-input)
  (unless etaf--current-event
    (signal 'etaf-event-error (list "Native input requires a Host event callback")))
  (let ((runtime (plist-get etaf--current-event :runtime))
        (host-ref (plist-get etaf--current-event :host-ref)))
    (ebox-call-with-input host-ref reader (etaf-runtime-buffer runtime))))

(defun etaf-event-kind (kind)
  "Normalize event KIND to a non-keyword symbol."
  (let ((name (cond
               ((keywordp kind) (substring (symbol-name kind) 1))
               ((symbolp kind) (symbol-name kind))
               ((stringp kind) kind)
               (t (signal 'etaf-event-error
                          (list (format "Invalid event kind: %S" kind)))))))
    (setq name (if (string-prefix-p "on-" name)
                   (substring name 3)
                 name))
    (intern name)))

(defun etaf--event-handler (runtime host-ref kind)
  "Return callback for HOST-REF and KIND in RUNTIME, or nil."
  (cdr (assq (etaf-event-kind kind)
             (etaf-runtime-handler-for runtime host-ref))))

;;;###autoload
(cl-defun etaf-dispatch-event
    (runtime host-ref kind &optional payload (payload-p nil))
  "Dispatch KIND for HOST-REF through mounted RUNTIME.

  When PAYLOAD-P is non-nil, pass PAYLOAD as the callback's only argument;
otherwise call the local callback with no arguments."
  (etaf--assert-not-rendering 'dispatch-event)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (let* ((dispatch
         (lambda ()
           (when (and (plist-get (etaf-runtime-host-props-for runtime host-ref) :disabled)
                      (not (and etaf--drag-cancel-p (eq (etaf-event-kind kind) 'drag))))
             (signal 'etaf-event-error
                     (list (format "Cannot dispatch to disabled Host reference: %S"
                                   host-ref))))
           (let* ((event-kind (etaf-event-kind kind))
                  (callback (etaf--event-handler runtime host-ref event-kind)))
             (unless callback
               (signal 'etaf-event-error
                       (list (format "No %S handler for Host reference %S"
                                     event-kind host-ref))))
             (let ((etaf--current-runtime runtime)
                   (etaf--current-event
                    (list :runtime runtime :host-ref host-ref
                          :kind event-kind :payload payload)))
               (etaf-runtime-event-begin runtime)
               (unwind-protect
                   (let ((result (if payload-p
                                     (funcall callback payload)
                                   (funcall callback))))
                     ;; UI shells can install a capture callback on an
                     ;; ancestor Host.  This keeps activation and focus
                     ;; policy out of every leaf component while preserving
                     ;; the target callback's return value.
                     (when (and (eq event-kind 'press)
                                (not etaf--event-bubbling))
                       (let ((etaf--event-bubbling t))
                         (dolist (ancestor
                                  (etaf-runtime-host-ancestor-refs
                                   runtime host-ref))
                           (when-let* ((capture
                                       (etaf--event-handler
                                        runtime ancestor 'press-capture)))
                             (let ((etaf--current-event
                                    (list :runtime runtime
                                          :host-ref ancestor
                                          :target-host-ref host-ref
                                          :kind 'press-capture
                                          :payload payload)))
                               (if payload-p
                                   (funcall capture payload)
                                 (funcall capture)))))))
                     result)
                 (etaf-runtime-event-end runtime))))))
         (run
          (lambda ()
            (etaf-scheduler-call-with-context
             (etaf-runtime-scheduler-context runtime)
             (lambda ()
               (etaf-reactive-call-with-batch dispatch))))))
    (if (or etaf--observer-context (etaf-runtime-observer runtime))
        (etaf-runtime-call-operation
         runtime 'event
         (format "%s %S" (etaf-event-kind kind) host-ref)
         (lambda () (ebox-call-with-render-burst run)))
      (ebox-call-with-render-burst run))))

;;;###autoload
(defun etaf-host-ref-bounds (runtime host-ref)
  "Return live Ebox bounds for HOST-REF in mounted RUNTIME."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (ebox-host-ref-bounds (etaf-runtime-buffer runtime) host-ref))

;;;###autoload
(defun etaf-host-ref-position (runtime host-ref)
  "Return the first live Ebox position for HOST-REF in RUNTIME."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (ebox-host-ref-position (etaf-runtime-buffer runtime) host-ref))

(defun etaf--dispatch-activation (runtime host-ref)
  "Dispatch an enabled committed HOST-REF activation in RUNTIME."
  (if (and (not (plist-get (etaf-runtime-host-props-for runtime host-ref) :disabled))
           (etaf--event-handler runtime host-ref 'press))
      (etaf-dispatch-event runtime host-ref 'press)
    (user-error "No interactive ETAF Host at point")))

;;;###autoload
(defun etaf-activate (&optional runtime)
  "Dispatch `press' for the focused Host, or the interaction boundary at point.

RUNTIME is the mounted Runtime to activate, or nil for the current buffer."
  (interactive)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (with-current-buffer (etaf-runtime-buffer runtime)
    (ebox-activate)))

;;;###autoload
(defun etaf-focus (&optional runtime host-ref)
  "Move focus to HOST-REF in mounted RUNTIME and move point to its position.

Ebox owns focus and its publication lifecycle.  Without HOST-REF, select the
first eligible tab stop without changing existing focus if no stop exists.
Invalid explicit targets signal `etaf-event-error'.  Tab index affects only
navigation; a negative or absent index permits explicit focus."
  (interactive)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (let ((buffer (etaf-runtime-buffer runtime)))
    (condition-case condition
        (if host-ref (ebox-focus host-ref buffer) (ebox-focus-first buffer))
      (user-error
       (if host-ref
           (signal 'etaf-event-error (cdr condition))
         (signal (car condition) (cdr condition)))))))

;;;###autoload
(defun etaf-focused-host-ref (&optional runtime)
  "Return the currently focused Host reference in mounted RUNTIME."
  (ebox-focused-host-ref
   (etaf-runtime-buffer (etaf-runtime-require-mounted runtime))))

;;;###autoload
(defun etaf-focus-next (&optional runtime)
  "Focus the next visible Host in mounted RUNTIME."
  (interactive)
  (ebox-focus-next 1 t (etaf-runtime-buffer (etaf-runtime-require-mounted runtime))))

;;;###autoload
(defun etaf-focus-previous (&optional runtime)
  "Focus the previous visible Host in mounted RUNTIME."
  (interactive)
  (ebox-focus-previous 1 t (etaf-runtime-buffer (etaf-runtime-require-mounted runtime))))

;;;###autoload
(defun etaf-focus-within (runtime host-ref &optional count)
  "Focus a stop inside HOST-REF's committed subtree in RUNTIME.
Nil COUNT selects the first stop.  Integer COUNT moves forward or backward
with wrapping; zero queries current focus membership.  Ebox owns ordering,
visibility and retained identity.  Missing roots or stops signal `user-error'.
This creates no persistent focus restriction or additional input bindings."
  (ebox-focus-within host-ref count t
                     (etaf-runtime-buffer (etaf-runtime-require-mounted runtime))))

(provide 'etaf-events)

;;; etaf-events.el ends here
