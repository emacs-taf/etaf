;;; etaf-events.el --- ETAF event, activation, and focus ports -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Events are Runtime-owned entry points into local `:on-*' callbacks.  Ebox
;; supplies live Host reference bounds; ETAF decides which callback to invoke
;; and keeps focus state separate from the visual tree.

;;; Code:

(require 'cl-lib)
(require 'ebox)
(require 'etaf-runtime)

(defvar etaf--current-runtime)

(declare-function etaf-runtime-require-mounted "etaf-runtime" (&optional runtime))
(declare-function etaf-runtime-p "etaf-runtime" (value))
(declare-function etaf-runtime-mounted-p "etaf-runtime" (runtime))
(declare-function etaf-runtime-buffer "etaf-runtime" (runtime))
(declare-function etaf-runtime-handlers "etaf-runtime" (runtime))
(declare-function etaf-runtime-host-props "etaf-runtime" (runtime))
(declare-function etaf-runtime-focus-ref "etaf-runtime" (runtime))
(declare-function etaf-runtime-set-focus-ref "etaf-runtime" (runtime host-ref))

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
             (gethash host-ref (etaf-runtime-handlers runtime)))))

;;;###autoload
(cl-defun etaf-dispatch-event
    (runtime host-ref kind &optional payload (payload-p nil))
  "Dispatch KIND for HOST-REF through mounted RUNTIME.

When PAYLOAD-P is non-nil, pass PAYLOAD as the callback's only argument;
otherwise call the local callback with no arguments."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (let ((callback (etaf--event-handler runtime host-ref kind)))
    (unless callback
      (signal 'etaf-event-error
              (list (format "No %S handler for Host reference %S"
                            (etaf-event-kind kind) host-ref))))
    (let ((etaf--current-runtime runtime)
          (etaf--current-event
           (list :runtime runtime :host-ref host-ref
                 :kind (etaf-event-kind kind) :payload payload)))
      (if payload-p
          (funcall callback payload)
        (funcall callback)))))

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

;;;###autoload
(defun etaf-activate (&optional runtime)
  "Dispatch `press' for the smallest active Host containing point.

RUNTIME is the mounted Runtime to activate, or nil for the current Runtime.
Return the callback result.  This command is intentionally a thin adapter;
hit testing remains Ebox's public Host-reference bounds operation."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (let ((position (point)) candidates)
    (maphash
     (lambda (host-ref _handlers)
       (when-let ((bounds (ebox-host-ref-bounds
                           (etaf-runtime-buffer runtime) host-ref)))
         (when (and (<= (car bounds) position) (< position (cdr bounds)))
           (push (cons host-ref (- (cdr bounds) (car bounds))) candidates))))
     (etaf-runtime-handlers runtime))
    (unless candidates
      (user-error "No interactive ETAF Host at point"))
    (let* ((ordered (sort candidates
                          (lambda (left right) (< (cdr left) (cdr right)))))
           (host-ref (car (car ordered))))
      (etaf-dispatch-event runtime host-ref 'press))))

;;;###autoload
(defun etaf-focus (runtime host-ref)
  "Move focus to HOST-REF in mounted RUNTIME and return HOST-REF."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (etaf-host-ref-bounds runtime host-ref)
    (signal 'etaf-event-error
            (list (format "Cannot focus an invisible Host reference: %S"
                          host-ref))))
  (etaf-runtime-set-focus-ref runtime host-ref))

;;;###autoload
(defun etaf-focused-host-ref (&optional runtime)
  "Return the currently focused Host reference in mounted RUNTIME."
  (etaf-runtime-focus-ref (etaf-runtime-require-mounted runtime)))

;;;###autoload
(defun etaf-focus-next (&optional runtime)
  "Focus the next visible Host in mounted RUNTIME.

RUNTIME may be nil to use the current Runtime.  Hosts need a numeric,
non-negative `:tab-index'."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (let (candidates)
    (maphash
     (lambda (host-ref props)
       (let ((tab-index (plist-get props :tab-index)))
         (when (and (numberp tab-index) (>= tab-index 0)
                    (etaf-host-ref-bounds runtime host-ref))
           (push (cons tab-index host-ref) candidates))))
     (etaf-runtime-host-props runtime))
    (setq candidates (sort candidates
                           (lambda (left right)
                             (< (car left) (car right)))))
    (unless candidates
      (user-error "No focusable ETAF Host"))
    (let* ((current (etaf-runtime-focus-ref runtime))
           (ordered (mapcar #'cdr candidates))
           (position (cl-position current ordered :test #'equal))
           (next (if position
                     (or (nth (1+ position) ordered) (car ordered))
                   (car ordered))))
      (etaf-focus runtime next))))

(provide 'etaf-events)

;;; etaf-events.el ends here
