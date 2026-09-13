;;; etaf-events.el --- ETAF event, activation, and focus ports -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Events are Runtime-owned entry points into local `:on-*' callbacks.  The
;; input minor mode is deliberately small: Runtime only toggles it at mount
;; boundaries, while this module owns key and mouse command definitions.

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
(declare-function etaf-runtime-event-begin "etaf-runtime" (runtime))
(declare-function etaf-runtime-event-end "etaf-runtime" (runtime))
(declare-function etaf-runtime-observer "etaf-runtime" (runtime))
(declare-function etaf-runtime-call-operation
                  "etaf-runtime" (runtime kind label function))
(declare-function ebox-call-with-render-burst
                  "ebox-buffer-backend" (function &rest arguments))

(define-error 'etaf-event-error "Invalid ETAF Event")

(defvar etaf--current-event nil
  "Event context active while one Runtime callback runs.")

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
           (when (plist-get (etaf-runtime-host-props-for runtime host-ref)
                            :disabled)
             (signal 'etaf-event-error
                     (list (format "Cannot dispatch to disabled Host reference: %S"
                                   host-ref))))
           (let ((callback (etaf--event-handler runtime host-ref kind)))
             (unless callback
               (signal 'etaf-event-error
                       (list (format "No %S handler for Host reference %S"
                                     (etaf-event-kind kind) host-ref))))
             (let ((etaf--current-runtime runtime)
                   (etaf--current-event
                    (list :runtime runtime :host-ref host-ref
                          :kind (etaf-event-kind kind) :payload payload)))
               (etaf-runtime-event-begin runtime)
               (unwind-protect
                   (if payload-p
                       (funcall callback payload)
                     (funcall callback))
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

(defun etaf--focused-activation-ref (runtime)
  "Return RUNTIME's focused target when point still addresses it."
  (let ((ref (ebox-focused-host-ref (etaf-runtime-buffer runtime))))
    (and ref (equal (with-current-buffer (etaf-runtime-buffer runtime) (point))
                    (etaf-host-ref-position runtime ref)) ref)))

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
  (if-let* ((ref (etaf--focused-activation-ref runtime)))
      (etaf--dispatch-activation runtime ref)
    (with-current-buffer (etaf-runtime-buffer runtime)
      (ebox-activate))))

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

(defvar etaf-input-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'etaf-focus-next)
    (define-key map [tab] #'etaf-focus-next)
    (define-key map (kbd "<backtab>") #'etaf-focus-previous)
    (define-key map [backtab] #'etaf-focus-previous)
    (define-key map (kbd "S-TAB") #'etaf-focus-previous)
    (define-key map (kbd "RET") #'etaf-activate)
    (define-key map (kbd "<return>") #'etaf-activate)
    map)
  "Keymap for mounted ETAF Runtime input.")

;;;###autoload
(define-minor-mode etaf-input-mode
  "Enable keyboard focus and activation commands for a mounted ETAF Runtime."
  :init-value nil
  :lighter " ETAF"
  :keymap etaf-input-mode-map)

;;;###autoload
(defun etaf-events-enable-input (buffer)
  "Enable `etaf-input-mode' in mounted BUFFER."
  (with-current-buffer buffer
    (etaf-input-mode 1)))

;;;###autoload
(defun etaf-events-disable-input (buffer)
  "Disable `etaf-input-mode' in BUFFER after Runtime unmount."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (bound-and-true-p etaf-input-mode)
        (etaf-input-mode -1)))))

(provide 'etaf-events)

;;; etaf-events.el ends here
