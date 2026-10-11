;;; etaf-keys.el --- Scoped Host keys, regions and the command palette -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A Host declares `:keys', a list of (KEY COMMAND [LABEL]) entries, and the
;; key works while focus (or point) is inside that Host.  Each Runtime buffer
;; owns one emulation keymap holding every key any Host has declared; each
;; binding is a menu-item filter that resolves the key when it is pressed:
;;
;; 1. The scope starts at the focused Host, else the Host at point.  When a
;;    visible `:focus-scope modal' Host does not contain it, the scope starts
;;    at that modal Host instead.
;; 2. The registered Host and its ancestors are searched nearest first; the
;;    search stops after the first `:focus-scope modal' Host, so keys outside
;;    an open dialog are unreachable.  A disabled Host contributes no keys.
;; 3. The first entry matching the key wins.  Without one, the framework
;;    defaults apply: `M-g' opens region selection, Escape dispatches the
;;    nearest `:on-dismiss', `?' opens `etaf-help', Tab moves one tab stop,
;;    and an arrow key runs `etaf-direction' (the nearest `:on-direction'
;;    handler, a focused separator or slider step, then movement inside the
;;    surrounding region and its adjacent regions).  An open modal scope
;;    ignores unbound printing keys so they never reach the application
;;    behind it.
;; 4. Otherwise the key falls through to the buffer's other keymaps.  Keys
;;    also fall through while a native input session edits the buffer.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox)
(require 'etaf-reactive)
(require 'etaf-runtime)
(require 'etaf-events)
(require 'etaf-regions)

(defvar etaf--current-runtime)
(defvar etaf--current-event)
(defvar etaf--runtimes)

(defvar-local etaf--keys-alist nil
  "Emulation keymap alist holding the Runtime's scoped key bindings.")
(put 'etaf--keys-alist 'permanent-local t)

(add-to-list 'emulation-mode-map-alists 'etaf--keys-alist)

(defconst etaf--keys-dismiss-events (list [escape])
  "Events that dismiss the nearest Host with `:on-dismiss'.
C-g is never bound: it keeps Emacs's native keyboard-quit semantics.")

(defconst etaf--keys-selector-event [?\M-g]
  "Event entering region selection; `etaf-region-select' answers it.")

(defconst etaf--keys-direction-events
  '(([left] . left) ([right] . right) ([up] . up) ([down] . down))
  "Arrow events mapped to direction symbols for `etaf-direction'.")

(defconst etaf--keys-vim-direction-events
  '(([?\h] . left) ([?\j] . down) ([?\k] . up) ([?\l] . right))
  "Vim direction events mapped to direction symbols.")

(defconst etaf--keys-tab-events
  (list (vconcat (kbd "TAB")) (vconcat (kbd "<tab>"))
        (vconcat (kbd "S-TAB")) (vconcat (kbd "<backtab>")))
  "Events that move focus one tab stop, in either terminal or GUI encoding.")

(defconst etaf--keys-backtab-events
  (list (vconcat (kbd "S-TAB")) (vconcat (kbd "<backtab>")))
  "Tab events that move focus backward.")

(defconst etaf--keys-reserved-events
  (append (list [escape] etaf--keys-selector-event [?\C-g] [??])
          etaf--keys-tab-events
          (mapcar #'car etaf--keys-direction-events))
  "Events a Host `:keys' may not bind as the first event of an entry.
Escape, the region selector entry, native quit, the help key, Tab and the
direction keys are framework-owned; applications express direction behavior
through `:on-direction' instead of binding these keys.")

(defun etaf-keymap-reserved-events (keymap)
  "Return the framework-reserved events bound at the top level of KEYMAP.
Escape, the region selector entry, native quit, `?', Tab and the direction
keys are framework-owned: no application or component scope may override
them, and direction behavior is expressed through `:on-direction' instead.
Return a list of event vectors in binding order, or nil when KEYMAP is nil,
not a keymap, or free of conflicts.  Component authors use this to reject a
caller-supplied `:keymap' during validation."
  (when (keymapp keymap)
    (let (conflicts)
      (map-keymap
       (lambda (event _binding)
         (let ((sequence (vector event)))
           (when (member sequence etaf--keys-reserved-events)
             (push sequence conflicts))))
       keymap)
      (nreverse conflicts))))

(defvar etaf-direction-scheme 'arrows
  "Direction scheme of the key layer: `arrows' or `vim'.
`arrows' uses the physical arrow keys and leaves `h', `j', `k' and `l' to
the application.  `vim' additionally dispatches those letters as direction
keys in navigation state.  Set it through `etaf-set-direction-scheme' so a
conflicting Runtime is reported instead of shadowed.")

(defconst etaf--keys-step-events
  `(([left] . (-1 . 0)) ([right] . (1 . 0)) ([up] . (0 . -1)) ([down] . (0 . 1))
    ([?\C-b] . (-1 . 0)) ([?\C-f] . (1 . 0)) ([?\C-p] . (0 . -1)) ([?\C-n] . (0 . 1)))
  "Events that step a focused separator or slider, with their column/row step.")

(defconst etaf--keys-printing-events
  (mapcar #'vector (number-sequence ?\s ?~))
  "Printing events an open modal scope swallows when nothing binds them.")

(defun etaf--keys-event (key)
  "Return the event vector of KEY, a `kbd' string or a key vector."
  (vconcat (if (stringp key) (kbd key) key)))

(defun etaf--keys-validate (keys)
  "Signal `etaf-renderer-error' unless KEYS is a valid `:keys' value."
  (unless (proper-list-p keys)
    (signal 'etaf-renderer-error (list ":keys must be a list of (KEY COMMAND [LABEL])")))
  (dolist (entry keys)
    (unless (and (proper-list-p entry) (<= 2 (length entry) 3)
                 (or (stringp (car entry)) (vectorp (car entry)))
                 (functionp (nth 1 entry))
                 (or (null (nth 2 entry)) (stringp (nth 2 entry))))
      (signal 'etaf-renderer-error
              (list (format ":keys entry must be (KEY COMMAND [LABEL]): %S" entry))))
    (let ((events (etaf--keys-event (car entry))))
      (when (= (length events) 0)
        (signal 'etaf-renderer-error
                (list (format ":keys entry binds no key: %S" entry))))
      ;; Printing keys are single-key commands (and modal guards), so they
      ;; cannot also start a sequence.
      (when (and (> (length events) 1)
                 (member (vector (aref events 0)) etaf--keys-printing-events))
        (signal 'etaf-renderer-error
                (list (format ":keys sequence %s starts with a printing key"
                              (key-description events)))))
      (when (member (vector (aref events 0)) etaf--keys-reserved-events)
        (signal 'etaf-renderer-error
                (list (format ":keys sequence %s binds a framework-reserved key"
                              (key-description events)))))
      (when (and (eq etaf-direction-scheme 'vim)
                 (member (vector (aref events 0))
                         (mapcar #'car etaf--keys-vim-direction-events)))
        (signal 'etaf-renderer-error
                (list (format ":keys sequence %s shadows the Vim direction scheme"
                              (key-description events)))))))
  keys)

(defvar etaf--keys-sequences (make-hash-table :test #'eq :weakness 'key)
  "Map from a Runtime key map to the key sequences defined in it.")

(defun etaf--keys-prefix-p (prefix sequence)
  "Return non-nil when PREFIX is a proper prefix of SEQUENCE."
  (and (< (length prefix) (length sequence))
       (equal prefix (substring sequence 0 (length prefix)))))

(defun etaf--keys-define (map event)
  "Bind key sequence EVENT in MAP to its dynamic scoped resolution, once.
A sequence that extends or prefixes another bound sequence is a render error:
one key cannot both run a command and start a longer sequence."
  (let ((defined (gethash map etaf--keys-sequences)))
    (unless (member event defined)
      (when (cl-find-if (lambda (other)
                          (or (etaf--keys-prefix-p other event)
                              (etaf--keys-prefix-p event other)))
                        defined)
        (signal 'etaf-renderer-error
                (list (format ":keys sequence %s conflicts with a prefix binding"
                              (key-description event)))))
      (puthash map (cons event defined) etaf--keys-sequences)
      (define-key map event
                  (list 'menu-item "" nil
                        :filter (lambda (_binding) (etaf--keys-binding event)))))))

(defun etaf--keys-install (runtime)
  "Give RUNTIME's buffer its scoped key map with the framework defaults."
  (let ((map (make-sparse-keymap)))
    (dolist (event (append etaf--keys-dismiss-events
                           (list [??] etaf--keys-selector-event)
                           (mapcar #'car etaf--keys-step-events)
                           etaf--keys-tab-events
                           etaf--keys-printing-events))
      (etaf--keys-define map event))
    (setf (etaf-runtime-keymap runtime) map)
    (with-current-buffer (etaf-runtime-buffer runtime)
      (add-hook 'ebox-focus-change-functions #'etaf--keys-focus-enter nil t)
      (etaf--regions-install runtime)
      (setq etaf--keys-alist (list (cons t map)))
      ;; Host keys are the most specific bindings, so they precede any
      ;; emulation map the application installed in this buffer.
      (setq-local emulation-mode-map-alists
                  (cons 'etaf--keys-alist
                        (remq 'etaf--keys-alist emulation-mode-map-alists))))))

(defun etaf--keys-uninstall (runtime)
  "Remove RUNTIME's scoped key map from its buffer."
  (setf (etaf-runtime-keymap runtime) nil)
  (let ((buffer (etaf-runtime-buffer runtime)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (remove-hook 'ebox-focus-change-functions #'etaf--keys-focus-enter t)
        (etaf--regions-uninstall runtime)
        (kill-local-variable 'etaf--keys-alist)))))

(defun etaf--keys-focus-enter (previous node)
  "Dispatch `:on-focus-enter' on the Hosts focus entered moving PREVIOUS to NODE.
Each Host containing NODE but not PREVIOUS is entered, nearest first."
  (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
              (ref (and node (etaf-runtime-node-host-ref runtime node))))
    (let* ((old (and previous (etaf-runtime-node-host-ref runtime previous)))
           (left (and old (cons old (etaf-runtime-host-ancestor-refs runtime old)))))
      (dolist (each (cons ref (etaf-runtime-host-ancestor-refs runtime ref)))
        (unless (member each left)
          (let ((props (etaf--keys-props runtime each)))
            (when (and (functionp (plist-get props :on-focus-enter))
                       (not (plist-get props :disabled)))
              (etaf-dispatch-event runtime each 'focus-enter))))))))

(defun etaf--keys-register (runtime keys)
  "Add the events of a Host's KEYS to RUNTIME's scoped key map."
  (when-let* ((map (etaf-runtime-keymap runtime)))
    (dolist (entry keys)
      (etaf--keys-define map (etaf--keys-event (car entry))))))

(defun etaf--keys-props (runtime ref)
  "Return RUNTIME's committed semantic props of Host REF without copying."
  (let ((seg (etaf--runtime-host-seg runtime ref)))
    (and seg (etaf--host-props (etaf--seg-data seg)))))

(defun etaf--keys-chain (runtime)
  "Return RUNTIME's key scope: Host references from the focus outward.
Focus answers while point lies inside it; once a command moves point
elsewhere, the node at point answers instead."
  (let* ((buffer (etaf-runtime-buffer runtime))
         (scope (ebox-focus-scope buffer))
         (focus (ebox-focused-node buffer))
         (here (ebox-node-at (point) buffer))
         (node (if (and focus (or (null here) (eq here focus)
                                  (ebox-node-ancestor-p focus here)))
                   focus
                 (or here focus)))
         (node (if (and node (or (eq node scope) (ebox-node-ancestor-p scope node)))
                   node
                 scope))
         (ref (and node (etaf-runtime-node-host-ref runtime node)))
         chain)
    (when ref
      (catch 'done
        (dolist (each (cons ref (etaf-runtime-host-ancestor-refs runtime ref)))
          (push each chain)
          (when (eq (plist-get (etaf--keys-props runtime each) :focus-scope) 'modal)
            (throw 'done nil)))))
    (nreverse chain)))

(defun etaf--keys-entries (runtime chain)
  "Return the effective ((REF . ENTRY) ...) of CHAIN in RUNTIME.
Entries are ordered nearest first; a key bound by a nearer Host shadows the
same key further out."
  (let (seen result)
    (dolist (ref chain)
      (let ((props (etaf--keys-props runtime ref)))
        (unless (plist-get props :disabled)
          (dolist (entry (plist-get props :keys))
            (let ((event (etaf--keys-event (car entry))))
              (unless (member event seen)
                (push event seen)
                (push (cons ref entry) result)))))))
    (nreverse result)))

(defun etaf--keys-run (runtime ref command)
  "Run key COMMAND for Host REF in RUNTIME like a keymap binding.
No batch surrounds COMMAND, so it sees each of its writes published: it can
move point to or begin input on a Host it just revealed, exactly as when a
keymap or M-x runs it."
  (unless (etaf-runtime-mounted-p runtime)
    (user-error "The ETAF Runtime is no longer mounted"))
  (when (symbolp command) (setq this-command command))
  (let ((etaf--current-runtime runtime)
        (etaf--current-event (list :runtime runtime :host-ref ref
                                   :kind 'key :payload nil)))
    (etaf-runtime-event-begin runtime)
    (unwind-protect
        (if (commandp command)
            (call-interactively command)
          (funcall command))
      (etaf-runtime-event-end runtime))))

(defun etaf--keys-command (runtime ref command)
  "Return an interactive command running COMMAND for Host REF in RUNTIME."
  (lambda ()
    (interactive)
    (etaf--keys-run runtime ref command)))

(defun etaf--keys-dismiss-ref (runtime chain)
  "Return the nearest enabled Host in CHAIN with a dismiss handler."
  (cl-find-if (lambda (ref)
                (let ((props (etaf--keys-props runtime ref)))
                  (and (functionp (plist-get props :on-dismiss))
                       (not (plist-get props :disabled)))))
              chain))

(defun etaf--keys-step-ref (runtime event)
  "Return the focused separator or slider that EVENT steps, or nil."
  (when-let* ((step (cdr (assoc event etaf--keys-step-events)))
              (node (ebox-focused-node (etaf-runtime-buffer runtime)))
              (ref (etaf-runtime-node-host-ref runtime node))
              (props (etaf--keys-props runtime ref)))
    (let ((role (format "%s" (plist-get props :role)))
          (orientation (format "%s" (plist-get props :aria-orientation))))
      (and (member role '("separator" "slider"))
           (functionp (plist-get props :on-drag))
           (not (plist-get props :disabled))
           ;; A vertical rule moves sideways; a horizontal one moves up/down.
           (cond ((equal orientation "vertical") (/= (car step) 0))
                 ((equal orientation "horizontal") (/= (cdr step) 0))
                 (t t))
           ref))))

(defun etaf--keys-direction-of (event)
  "Return the direction EVENT selects under the active scheme, or nil."
  (or (cdr (assoc event etaf--keys-direction-events))
      (and (eq etaf-direction-scheme 'vim)
           (cdr (assoc event etaf--keys-vim-direction-events)))))

(defun etaf--keys-direction-command (runtime event)
  "Return a command moving RUNTIME's focus in EVENT's direction."
  (let ((direction (etaf--keys-direction-of event)))
    (lambda ()
      (interactive)
      (etaf-direction direction runtime))))

(defun etaf--keys-binding (event)
  "Return the command EVENT runs in the current Runtime buffer, or nil."
  (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
    (when (and runtime (not (ebox-input-active-p (current-buffer))))
      (let* ((chain (etaf--keys-chain runtime))
             (found (cl-find event (etaf--keys-entries runtime chain)
                             :key (lambda (item) (etaf--keys-event (cadr item)))
                             :test #'equal)))
        (cond
         (found (etaf--keys-command runtime (car found) (nth 2 found)))
         ((equal event etaf--keys-selector-event)
          #'etaf-region-select)
         ((member event etaf--keys-dismiss-events)
          (when-let* ((ref (etaf--keys-dismiss-ref runtime chain)))
            (lambda ()
              (interactive)
              (etaf-dispatch-event runtime ref 'dismiss))))
         ((etaf--keys-direction-of event)
          (etaf--keys-direction-command runtime event))
         ((member event etaf--keys-tab-events)
          (let ((backward (member event etaf--keys-backtab-events)))
            (lambda ()
              (interactive)
              (if backward
                  (etaf-focus-previous runtime)
                (etaf-focus-next runtime)))))
         ((equal event [??])
          #'etaf-help)
         ((etaf--keys-step-ref runtime event)
          (let ((ref (etaf--keys-step-ref runtime event))
                (step (cdr (assoc event etaf--keys-step-events))))
            (lambda ()
              (interactive)
              (etaf-drag-step runtime ref (car step) (cdr step)))))
         ;; An open dialog keeps typed letters from reaching the application
         ;; behind it, including keymaps that are not Host `:keys'.
         ((and (member event etaf--keys-printing-events)
               (eq (plist-get (etaf--keys-props runtime (car (last chain)))
                              :focus-scope)
                   'modal))
          #'ignore))))))

;;;###autoload
(defun etaf-drag-step (runtime host-ref columns rows)
  "Drag HOST-REF in mounted RUNTIME by COLUMNS and ROWS from the keyboard.
Dispatch one `start' and one `end' gesture to the Host's `:on-drag' with
a delta of COLUMNS character widths and ROWS line heights in pixels, the
units of a pointer drag, so every drag handler also works from the keyboard.
The gestures carry `:keyboard' t.  Return HOST-REF."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (and (numberp columns) (numberp rows))
    (signal 'etaf-event-error (list "Drag step COLUMNS and ROWS must be numbers")))
  (let* ((buffer (etaf-runtime-buffer runtime))
         (node (or (etaf-runtime-host-node runtime host-ref)
                   (signal 'etaf-event-error
                           (list "No committed Host reference" host-ref))))
         (window (or (get-buffer-window buffer) (selected-window)))
         (frame (window-frame window))
         (delta (cons (* columns (frame-char-width frame))
                      (* rows (frame-char-height frame))))
         (base (list :event last-input-event :node node :window window
                     :buffer buffer :start (cons 0 0) :reason nil :keyboard t)))
    (etaf-dispatch-event runtime host-ref 'drag
                         (append (list :phase 'start :position (cons 0 0)
                                       :delta (cons 0 0))
                                 base)
                         t)
    (etaf-dispatch-event runtime host-ref 'drag
                         (append (list :phase 'end :position delta :delta delta)
                                 base)
                         t)
    host-ref))

(defun etaf--keys-current-step (columns rows)
  "Drag the Host whose `:keys' entry is running by COLUMNS and ROWS."
  (let ((runtime (plist-get etaf--current-event :runtime))
        (ref (plist-get etaf--current-event :host-ref)))
    (unless (and runtime ref)
      (signal 'etaf-event-error (list "Keyboard drag requires a Host key event")))
    (etaf-drag-step runtime ref columns rows)))

(defun etaf--keys-move-bindings (axis)
  "Return the `:keys' moving a draggable Host along AXIS with M-arrows."
  (let (keys)
    (when (memq axis '(nil x both))
      (push (list "M-<left>" (lambda () (etaf--keys-current-step -1 0)) "Move left") keys)
      (push (list "M-<right>" (lambda () (etaf--keys-current-step 1 0)) "Move right") keys))
    (when (memq axis '(nil y both))
      (push (list "M-<up>" (lambda () (etaf--keys-current-step 0 -1)) "Move up") keys)
      (push (list "M-<down>" (lambda () (etaf--keys-current-step 0 1)) "Move down") keys))
    (nreverse keys)))

(defun etaf--keys-resize-bindings (edges)
  "Return the `:keys' resizing a Host with EDGES by M-S-arrows.
Right and down grow the Host and left and up shrink it, whichever edge
the Host drags."
  (let ((dx (cond ((memq 'right edges) 1) ((memq 'left edges) -1)))
        (dy (cond ((memq 'bottom edges) 1) ((memq 'top edges) -1)))
        keys)
    (when dx
      (push (list "M-S-<right>" (lambda () (etaf--keys-current-step dx 0)) "Wider") keys)
      (push (list "M-S-<left>" (lambda () (etaf--keys-current-step (- dx) 0)) "Narrower")
            keys))
    (when dy
      (push (list "M-S-<down>" (lambda () (etaf--keys-current-step 0 dy)) "Taller") keys)
      (push (list "M-S-<up>" (lambda () (etaf--keys-current-step 0 (- dy))) "Shorter")
            keys))
    (nreverse keys)))

;;;; Command palette

(defun etaf--keys-control-label (runtime ref node)
  "Return the palette label of control NODE registered as REF in RUNTIME."
  (let* ((props (and ref (etaf--keys-props runtime ref)))
         (label (plist-get props :aria-label))
         (bounds (and (not label) (ebox-node-bounds node t)))
         (text (or (and label (format "%s" label))
                   (and bounds
                        (with-current-buffer (etaf-runtime-buffer runtime)
                          (buffer-substring-no-properties (car bounds) (cdr bounds)))))))
    (when text
      (setq text (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " text)))
      (unless (string-empty-p text)
        (truncate-string-to-width text 60 nil nil "…")))))

(defun etaf--keys-palette-candidates (runtime)
  "Return palette entries (LABEL ANNOTATION FUNCTION) for RUNTIME."
  (let* ((buffer (etaf-runtime-buffer runtime))
         (chain (etaf--keys-chain runtime))
         candidates)
    (dolist (item (etaf--keys-entries runtime chain))
      (let ((ref (car item)) (entry (cdr item)))
        (when (nth 2 entry)
          (push (list (nth 2 entry) (key-description (etaf--keys-event (car entry)))
                      (lambda () (etaf--keys-run runtime ref (nth 1 entry))))
                candidates))))
    (when-let* ((ref (etaf--keys-dismiss-ref runtime chain)))
      (unless (cl-find [escape] (etaf--keys-entries runtime chain)
                       :key (lambda (item) (etaf--keys-event (cadr item)))
                       :test #'equal)
        (push (list "Close" "<escape>"
                    (lambda () (etaf-dispatch-event runtime ref 'dismiss)))
              candidates)))
    (dolist (node (ebox-focus-stops buffer))
      (let* ((ref (etaf-runtime-node-host-ref runtime node))
             (label (etaf--keys-control-label runtime ref node))
             (props (and ref (etaf--keys-props runtime ref)))
             (role (plist-get props :role)))
        (when label
          (push (list label (if role (format "%s" role) "control")
                      (lambda ()
                        (ebox-focus node buffer)
                        (when (and (functionp (plist-get props :on-press))
                                   (not (plist-get props :disabled)))
                          (etaf-dispatch-event runtime ref 'press))))
                candidates))))
    (nreverse candidates)))

;;;###autoload
(defun etaf-help (&optional runtime)
  "Show the effective ETAF keys of mounted RUNTIME in a read-only buffer.
The help lists the regions of the current focus scope, the labelled `:keys'
the current focus reaches with their source, the framework keys and the
focusable controls.  It never runs a command.  `?' opens it in a Runtime
buffer; `etaf-palette' stays
available through `M-x' for running a command or pressing a control."
  (interactive)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (let ((buffer (get-buffer-create "*ETAF Help*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (etaf--keys-help-text runtime)))
      (special-mode)
      (goto-char (point-min)))
    (display-buffer buffer)
    buffer))

;;;###autoload
(defun etaf-palette (&optional runtime)
  "Choose and run a command or control of mounted RUNTIME by name.
The candidates are the labelled `:keys' that the current focus reaches,
Close when an `:on-dismiss' Host is in scope, and every focusable control
in the modal scope, named by its `:aria-label' or painted text.  Choosing a
key runs its command; choosing a control focuses and presses it.  The
palette is an execution surface and stays reachable from `M-x'; `?' opens
`etaf-help' instead so that viewing never runs anything."
  (interactive)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (with-current-buffer (etaf-runtime-buffer runtime)
    (let* ((candidates (etaf--keys-palette-candidates runtime))
           (table (make-hash-table :test #'equal))
           names)
      (unless candidates (user-error "No ETAF command is reachable here"))
      (dolist (candidate candidates)
        (let* ((base (car candidate)) (name base) (count 1))
          (while (gethash name table)
            (setq count (1+ count) name (format "%s <%d>" base count)))
          (puthash name candidate table)
          (push name names)))
      (setq names (nreverse names))
      (let* ((completion-extra-properties
              (list :annotation-function
                    (lambda (name)
                      (when-let* ((candidate (gethash name table)))
                        (concat "  " (propertize (nth 1 candidate)
                                                 'face 'completions-annotations))))))
             (choice (completing-read
                      "Command: "
                      (lambda (string predicate action)
                        (if (eq action 'metadata)
                            '(metadata (display-sort-function . identity))
                          (complete-with-action action names string predicate)))
                      nil t)))
        (funcall (nth 2 (gethash choice table)))))))

(defun etaf--keys-source-name (runtime ref)
  "Return REF's readable name in RUNTIME, or nil."
  (when-let* ((props (etaf--keys-props runtime ref)))
    (let ((label (plist-get props :aria-label)))
      (cond ((and label (not (string-empty-p (format "%s" label))))
             (format "%s" label))
            ((symbolp ref) (format "%s" ref))))))

(defun etaf--keys-help-text (runtime)
  "Return the read-only key help text of RUNTIME's current scope."
  (let* ((chain (etaf--keys-chain runtime))
         (entries (etaf--keys-entries runtime chain))
         (regions (etaf--regions-in-scope runtime))
         (current (etaf--regions-current runtime regions))
         (lines (list "ETAF keyboard help" "")))
    (when (or regions current)
      (push (format "Scope: %s"
                    (if current
                        (etaf--regions-label current)
                      "application"))
            lines)
      (when regions
        (push (format "Regions: %s"
                      (mapconcat
                       (lambda (region)
                         (let ((key (plist-get region :key)))
                           (format "%s%s"
                                   (if key (format "[%c] " (etaf--regions-key-char key)) "")
                                   (etaf--regions-label region))))
                       regions "  "))
              lines))
      (push "" lines))
    (push "Keys:" lines)
    (if entries
        (dolist (item entries)
          (let ((entry (cdr item))
                (source (etaf--keys-source-name runtime (car item))))
            (when (nth 2 entry)
              (push (format "  %-10s %s%s"
                            (key-description (etaf--keys-event (car entry)))
                            (nth 2 entry)
                            (if source (format "  (%s)" source) ""))
                    lines))))
      (push "  (no Host `:keys' in scope)" lines))
    (push "" lines)
    (push "Framework:" lines)
    (dolist (line (list "  M-g        Select region"
                    (if (eq etaf-direction-scheme 'vim)
                        "  h j k l    Move focus (Vim scheme)"
                      "  ←↑↓→        Move focus")
                    "  Tab        Next focus stop (S-Tab previous)"
                    "  Escape     Close the nearest dismissible Host"
                    "  ?          This help"
                    "  M-x etaf-palette   Run a command or press a control by name"))
      (push line lines))
    (push "" lines)
    (push "Controls:" lines)
    (let ((controls
           (delq nil
                 (mapcar
                  (lambda (node)
                    (let* ((ref (etaf-runtime-node-host-ref runtime node))
                           (label (and ref (etaf--keys-control-label runtime ref node))))
                      (and label (format "  %s" label))))
                  (ebox-focus-stops (etaf-runtime-buffer runtime))))))
      (if controls
          (dolist (line controls) (push line lines))
        (push "  (no focusable controls)" lines)))
    (mapconcat #'identity (nreverse lines) "\n")))

;;;; Region and direction navigation

(defun etaf--direction-handler (runtime ref direction)
  "Run the nearest Host `:on-direction' handler above REF in RUNTIME.
Return the handler's result symbol, or nil when no handler is in scope."
  (when ref
    (let ((chain (cons ref (etaf-runtime-host-ancestor-refs runtime ref))))
      (cl-loop for candidate in chain
               for handler = (plist-get (etaf--keys-props runtime candidate) :on-direction)
               when (functionp handler)
               return (let ((result (funcall handler direction)))
                        (unless (memq result '(handled hold release))
                          (signal 'etaf-event-error
                                  (list (format ":on-direction returned %S; expected handled, hold or release"
                                                result))))
                        result)))))

(defun etaf--direction-step (runtime ref direction)
  "Step a focused separator or slider REF in DIRECTION; return REF or nil."
  (when ref
    (let* ((event (car (rassoc direction etaf--keys-direction-events)))
           (step (and event (cdr (assoc event etaf--keys-step-events)))))
      (when (and step (eq (etaf--keys-step-ref runtime event) ref))
        (etaf-drag-step runtime ref (car step) (cdr step))
        ref))))

(defun etaf--direction-move (runtime ref direction)
  "Move focus from REF in DIRECTION, crossing region boundaries.
Inside a declared region the movement is limited to that region; at its edge
the adjacent region's entry is focused.  Without a region the Ebox spatial
movement applies and the viewport scrolls at its edge.  Return the focused
Host reference or nil."
  (let* ((buffer (etaf-runtime-buffer runtime))
         (regions (etaf--regions-collect runtime))
         (region (and ref
                      (cl-find-if (lambda (item)
                                    (etaf--regions-contains-p runtime (plist-get item :ref) ref))
                                  regions)))
         (root (and region (etaf-runtime-host-node runtime (plist-get region :ref)))))
    (if region
        (if-let* ((node (and root (ebox-focus-direction direction buffer root))))
            (etaf-runtime-node-host-ref runtime node)
          (when-let* ((target (etaf--regions-neighbor runtime regions direction)))
            (etaf--regions-focus runtime
                                 (cl-find target regions
                                          :key (lambda (item) (plist-get item :id))))))
      (if-let* ((node (ebox-focus-direction direction buffer)))
          (etaf-runtime-node-host-ref runtime node)
        (pcase direction
          ('down (ebox-scroll-down))
          ('up (ebox-scroll-up)))
        nil))))

;;;###autoload
(defun etaf-direction (direction &optional runtime)
  "Move DIRECTION in mounted RUNTIME and return the focused Host reference.
DIRECTION is `up', `down', `left' or `right'.  Order: the nearest Host
`:on-direction' handler (it returns `handled', `hold' or `release'); a
focused separator or slider step; then focus movement inside the surrounding
region, entering the adjacent region at its edge.  Without a surrounding
region the Ebox spatial movement applies and the viewport scrolls at the
edge.  Return nil when nothing moves."
  (interactive
   (list (intern (completing-read "Direction: " '("up" "down" "left" "right")
                                  nil t nil nil "down"))))
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (memq direction '(up down left right))
    (signal 'etaf-event-error (list (format "Unknown direction %S" direction))))
  (let* ((buffer (etaf-runtime-buffer runtime))
         (focused (and (not (ebox-input-active-p buffer))
                       (ebox-focused-node buffer)))
         (ref (or (and focused (etaf-runtime-node-host-ref runtime focused))
                  ;; Without focus, the Host at point answers directions, so
                  ;; read-only readers keep the key semantics of their rows.
                  (etaf-host-ref-at runtime)
                  (when-let* ((node (ebox-node-at (point) buffer)))
                    (etaf-runtime-node-host-ref runtime node)))))
    (if (memq (etaf--direction-handler runtime ref direction) '(handled hold))
        (etaf-focused-host-ref runtime)
      (or (etaf--direction-step runtime ref direction)
          (etaf--direction-move runtime ref direction)))))

(defun etaf--direction-vim-conflicts (runtime)
  "Return Vim-scheme conflicts in RUNTIME as readable strings."
  (let ((letters (mapcar (lambda (pair) (aref (car pair) 0))
                         etaf--keys-vim-direction-events))
        conflicts)
    (dolist (entry (etaf-runtime-host-props-entries runtime))
      (dolist (binding (plist-get (cdr entry) :keys))
        (let ((events (etaf--keys-event (car binding))))
          (when (and (> (length events) 0)
                     (memq (aref events 0) letters))
            (push (format "Host %s binds %s" (car entry) (key-description events))
                  conflicts)))))
    (dolist (region (etaf--regions-collect runtime))
      (let ((char (etaf--regions-key-char (plist-get region :key))))
        (when (and char (memq char letters))
          (push (format "region %s uses hint %c" (plist-get region :id) char)
                conflicts))))
    (nreverse conflicts)))

;;;###autoload
(defun etaf-set-direction-scheme (scheme &optional runtime)
  "Select the direction SCHEME, `arrows' or `vim', after conflict checks.
Vim requires every mounted Runtime to be free of Host `:keys' and region hint
letters using `h', `j', `k' or `l'; conflicts are reported and the previous
scheme stays in effect.  RUNTIME limits the check to that Runtime and
defaults to the active one.  Return SCHEME."
  (interactive
   (list (intern (completing-read "Direction scheme: " '("arrows" "vim")
                                  nil t nil nil (symbol-name etaf-direction-scheme)))))
  (unless (memq scheme '(arrows vim))
    (signal 'etaf-event-error (list (format "Unknown direction scheme %S" scheme))))
  (when (eq scheme 'vim)
    (let (conflicts)
      (dolist (item (if runtime
                        (list (etaf-runtime-require-mounted runtime))
                      (let (runtimes)
                        (maphash (lambda (_ item)
                                   (when (etaf-runtime-mounted-p item)
                                     (push item runtimes)))
                                 etaf--runtimes)
                        runtimes)))
        (setq conflicts (append conflicts (etaf--direction-vim-conflicts item))))
      (when conflicts
        (user-error "Vim direction scheme conflicts: %s" (string-join conflicts "; ")))))
  (setq etaf-direction-scheme scheme)
  scheme)

(provide 'etaf-keys)

;;; etaf-keys.el ends here
