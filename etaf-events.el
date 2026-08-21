;;; etaf-events.el --- ETAF event, activation, and focus ports -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Events are Runtime-owned entry points into local `:on-*' callbacks.  The
;; input minor mode is deliberately small: Runtime only toggles it at mount
;; boundaries, while this module owns key and mouse command definitions.

;;; Code:

(require 'cl-lib)
(require 'ebox)
(require 'etaf-runtime)

(defvar etaf--current-runtime)

(declare-function etaf-runtime-require-mounted "etaf-runtime" (&optional runtime))
(declare-function etaf-runtime-p "etaf-runtime" (value))
(declare-function etaf-runtime-mounted-p "etaf-runtime" (runtime))
(declare-function etaf-runtime-buffer "etaf-runtime" (runtime))
(declare-function etaf-runtime-handler-for "etaf-runtime" (runtime host-ref))
(declare-function etaf-runtime-handler-entries "etaf-runtime" (runtime))
(declare-function etaf-runtime-host-props-for "etaf-runtime" (runtime host-ref))
(declare-function etaf-runtime-host-props-entries "etaf-runtime" (runtime))
(declare-function etaf-runtime-focus-ref "etaf-runtime" (runtime))
(declare-function etaf-runtime-set-focus-ref "etaf-runtime" (runtime host-ref))
(declare-function etaf-runtime-event-begin "etaf-runtime" (runtime))
(declare-function etaf-runtime-event-end "etaf-runtime" (runtime))

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
      (etaf-runtime-event-begin runtime)
      (unwind-protect
          (if payload-p
              (funcall callback payload)
            (funcall callback))
        (etaf-runtime-event-end runtime)))))

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

(defun etaf--position-number (position)
  "Return integer POSITION, or nil when POSITION is not buffer-local."
  (cond
   ((markerp position) (marker-position position))
   ((integerp position) position)
   (t nil)))

(defun etaf--activation-candidate-before-p (left right)
  "Return non-nil when activation candidate LEFT precedes RIGHT."
  (let ((left-length (nth 2 left))
        (right-length (nth 2 right))
        (left-start (nth 1 left))
        (right-start (nth 1 right)))
    (or (< left-length right-length)
        (and (= left-length right-length)
             (or (< left-start right-start)
                 (and (= left-start right-start)
                      (string< (prin1-to-string (car left))
                               (prin1-to-string (car right)))))))))

(defun etaf--activation-at-position (runtime position &optional quiet)
  "Activate the smallest enabled Host at POSITION in RUNTIME.

When QUIET is non-nil, return nil instead of signaling when no callback owns
the position."
  (let (candidates)
    (dolist (entry (etaf-runtime-handler-entries runtime))
      (let ((host-ref (car entry)) (handlers (cdr entry)))
       (let* ((press (assq 'press handlers))
              (props (etaf-runtime-host-props-for runtime host-ref))
              (bounds (ebox-host-ref-bounds
                       (etaf-runtime-buffer runtime) host-ref))
              (start (and bounds (car bounds)))
              (end (and bounds (cdr bounds))))
         (when (and press (not (plist-get props :disabled))
                    start end (<= start position) (< position end))
           (push (list host-ref start (- end start)) candidates)))))
    (setq candidates (sort candidates #'etaf--activation-candidate-before-p))
    (if-let ((candidate (car candidates)))
        (etaf-dispatch-event runtime (car candidate) 'press)
      (unless quiet
        (user-error "No interactive ETAF Host at point")))))

;;;###autoload
(defun etaf-activate (&optional runtime)
  "Dispatch `press' for the smallest enabled Host containing point.

RUNTIME is the mounted Runtime to activate, or nil for the current buffer."
  (interactive)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (let ((position (with-current-buffer (etaf-runtime-buffer runtime)
                    (point))))
    (etaf--activation-at-position runtime position)))

(defun etaf--focus-candidate-before-p (left right)
  "Return non-nil when focus candidate LEFT precedes RIGHT."
  (or (< (nth 0 left) (nth 0 right))
      (and (= (nth 0 left) (nth 0 right))
           (or (< (nth 1 left) (nth 1 right))
               (and (= (nth 1 left) (nth 1 right))
                    (or (< (nth 2 left) (nth 2 right))
                        (and (= (nth 2 left) (nth 2 right))
                             (string< (prin1-to-string (nth 3 left))
                                      (prin1-to-string (nth 3 right))))))))))

(defun etaf--focus-candidates (runtime)
  "Return RUNTIME's visible focus candidates in stable buffer order."
  (let (candidates)
    (dolist (entry (etaf-runtime-host-props-entries runtime))
      (let ((host-ref (car entry)) (props (cdr entry)))
       (let ((tab-index (plist-get props :tab-index))
             (bounds (ebox-host-ref-bounds
                      (etaf-runtime-buffer runtime) host-ref)))
         (when (and (numberp tab-index) (>= tab-index 0)
                    (not (plist-get props :disabled)) bounds)
           (push (list tab-index (car bounds) (cdr bounds) host-ref)
                 candidates)))))
    (sort candidates #'etaf--focus-candidate-before-p)))

;;;###autoload
(defun etaf-focus (&optional runtime host-ref)
  "Move focus to HOST-REF in mounted RUNTIME and move point to its position.

When called interactively without arguments, focus the first visible Host."
  (interactive)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless host-ref
    (setq host-ref (nth 3 (car (etaf--focus-candidates runtime))))
    (unless host-ref
      (user-error "No focusable ETAF Host")))
  (let ((position (etaf-host-ref-position runtime host-ref)))
    (unless position
      (signal 'etaf-event-error
              (list (format "Cannot focus an invisible Host reference: %S"
                            host-ref))))
    (etaf-runtime-set-focus-ref runtime host-ref)
    (with-current-buffer (etaf-runtime-buffer runtime)
      (goto-char position))
    host-ref))

;;;###autoload
(defun etaf-focused-host-ref (&optional runtime)
  "Return the currently focused Host reference in mounted RUNTIME."
  (etaf-runtime-focus-ref (etaf-runtime-require-mounted runtime)))

(defun etaf--focus-cycle (runtime step)
  "Move focus by STEP positions through RUNTIME's ordered candidates."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (let* ((candidates (etaf--focus-candidates runtime))
         (ordered (mapcar (lambda (entry) (nth 3 entry)) candidates))
         (current (etaf-runtime-focus-ref runtime))
         (position (cl-position current ordered :test #'equal)))
    (unless ordered
      (user-error "No focusable ETAF Host"))
    (etaf-focus runtime
                (if position
                    (nth (mod (+ position step) (length ordered)) ordered)
                  (if (> step 0) (car ordered) (car (last ordered)))))))

;;;###autoload
(defun etaf-focus-next (&optional runtime)
  "Focus the next visible Host in mounted RUNTIME."
  (interactive)
  (etaf--focus-cycle runtime 1))

;;;###autoload
(defun etaf-focus-previous (&optional runtime)
  "Focus the previous visible Host in mounted RUNTIME."
  (interactive)
  (etaf--focus-cycle runtime -1))

(defun etaf-activate-mouse (event)
  "Activate the enabled Host at the real mouse EVENT position."
  (interactive "e")
  (let* ((start (event-start event))
         (window (posn-window start))
         (position (etaf--position-number (posn-point start))))
    (when (and (windowp window) position)
      (let ((buffer (window-buffer window)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when-let ((runtime (etaf-runtime-for-buffer buffer)))
              (goto-char position)
              (etaf--activation-at-position runtime position t))))))))

(defvar etaf-input-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'etaf-focus-next)
    (define-key map [tab] #'etaf-focus-next)
    (define-key map (kbd "<backtab>") #'etaf-focus-previous)
    (define-key map [backtab] #'etaf-focus-previous)
    (define-key map (kbd "S-TAB") #'etaf-focus-previous)
    (define-key map (kbd "RET") #'etaf-activate)
    (define-key map (kbd "<return>") #'etaf-activate)
    (define-key map [mouse-1] #'etaf-activate-mouse)
    map)
  "Keymap for mounted ETAF Runtime input.")

;;;###autoload
(define-minor-mode etaf-input-mode
  "Enable keyboard and mouse input for a mounted ETAF Runtime."
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
