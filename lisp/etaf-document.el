;;; etaf-document.el --- Edit the source a rendered page stands for  -*- lexical-binding: t; -*-

;;; Commentary:

;; An application that renders a document also knows, for every block it
;; paints, which range of the source that block came from.  This module turns
;; that knowledge into a page a reader can type on: the page stays a rendering,
;; every key it receives runs in the source buffer at the offset the page shows,
;; and the page repaints from the edited source.
;;
;;   (setq doc (etaf-document-open buffer :source source-buffer
;;                                        :entries (my-app-entries)))
;;   (etaf-document-goto doc 120)   ; source offset -> painted cell
;;   (etaf-document-close doc)
;;
;; The application supplies three things and nothing else: the source buffer,
;; the ranges its blocks paint, and its own key bindings if it wants more than
;; the shared ones.  What a block looks like, how its marker is drawn when its
;; text is gone, and which characters a syntax folds away all stay in the
;; application, because only it knows its markup.
;;
;; A key is looked up in the source and run there, at the offset the page
;; shows.  The page only interprets the few keys it must -- a press, and the
;; application's own -- so `undo', `C-k', `C-y', the mark, `TAB', a prefix like
;; `C-x C-s' and everything else behave exactly as they do in the buffer the
;; document lives in.  Nothing here enumerates what a reader may type: a key
;; the page does not claim belongs to the source by definition.
;;
;; The page also paints the source's region, because selecting text is a
;; position in the document, not a decoration of the rendering.

;;; Code:

(require 'cl-lib)
(require 'ebox)
(require 'etaf-runtime)

(defvar etaf-document--sessions (make-hash-table :test #'eq)
  "Editing session of each page buffer.")

(cl-defstruct (etaf-document (:constructor etaf--document-make) (:copier nil))
  "One rendered page bound to the source it paints.
BUFFER shows the page, SOURCE holds the text the keys edit, ENTRIES pairs a
Host reference with the source range its painted text stands for -- or is a
function returning that list, which a page whose blocks change on repaint
needs -- and BINDINGS holds this session's keys, shared ones plus the
application's own."
  buffer source entries (bindings nil) (saved nil) (dirty nil)
  (cached nil) (cached-tick nil) (cached-revision nil)
  (caret nil) (caret-at nil) (last-command nil))

;;;; Reading the page

(defun etaf-document-source-text (document)
  "Return DOCUMENT's source text."
  (when-let* ((source (etaf-document-source document)))
    (with-current-buffer source
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun etaf-document-entries-now (document &optional offset)
  "Return DOCUMENT's current source ranges, or only the one answer for OFFSET.
A page repaints after every edit, and a repaint can replace the Hosts its
blocks live in; a list captured when the session opened would name Hosts that
no longer exist, so a caller may hand over a function instead and have it asked
each time.  With OFFSET the application may answer with the one block that
covers it, which is all a caret move needs to read."
  (let ((entries (etaf-document-entries document)))
    (if (functionp entries) (funcall entries offset) entries)))

(defun etaf-document-projection (document &optional offset)
  "Return DOCUMENT's painted page as source ranges, or nil without a page.
The mapping is derived from the source text and the last paint, so it is kept
until one of them changes.  A key asks for it two or three times -- where the
caret is, where it goes, which run it stands on -- and a page of a few hundred
blocks costs tens of milliseconds to map, which a reader feels on every arrow
key.

With OFFSET the application answers for the one block that covers it, and the
page reads only that block: a caret move lands in one block, and mapping the
whole page for it would put the cost of the document on every key."
  (when-let* ((buffer (etaf-document-buffer document))
              (runtime (and (buffer-live-p buffer)
                            (etaf-runtime-for-buffer buffer)))
              (source (etaf-document-source document)))
    (let ((tick (buffer-chars-modified-tick source))
          (revision (etaf-runtime-revision runtime)))
      (cond
       ((and (null offset)
             (etaf-document-cached document)
             (eql tick (etaf-document-cached-tick document))
             (eql revision (etaf-document-cached-revision document)))
        (etaf-document-cached document))
       (offset
        (etaf-projection runtime (etaf-document-entries-now document offset)
                         (etaf-document-source-text document)))
       (t
        (let ((projection (etaf-projection
                           runtime (etaf-document-entries-now document)
                           (etaf-document-source-text document))))
          (setf (etaf-document-cached document) projection
                (etaf-document-cached-tick document) tick
                (etaf-document-cached-revision document) revision)
          projection))))))

(defun etaf-document-source-offset (document &optional position)
  "Return the source offset the painted POSITION names, by default at point.
The caret stands for the offset this session last placed it at, as long as it
has not moved: a render folds markup away -- a heading's hashes, a bullet, a
quote bar -- and those source positions have no cell of their own, so reading
the painted cell back would answer with the nearest visible one and the next
key would start from there instead of from where the command left the caret."
  (let ((at (or position (point)))
        (caret (etaf-document-caret document)))
    (cond ((and (null position)
                caret
                (eql at (etaf-document-caret-at document)))
           caret)
          ((and (etaf-document-buffer document)
                (eq (current-buffer) (etaf-document-buffer document))
                (>= at (point-max)))
           (length (or (etaf-document-source-text document) "")))
          (t (when-let* ((projection (etaf-document-projection document)))
               (etaf-projection-source-offset projection at))))))

(defun etaf-document-goto (document offset)
  "Put the caret on the painted cell where source OFFSET lives.
A window shows its own point, so every window displaying the page moves too;
otherwise the caret a reader sees never follows the edit."
  (let ((buffer (etaf-document-buffer document))
        (projection (etaf-document-projection document offset)))
    (when (and (buffer-live-p buffer) projection)
      ;; The offset is authoritative even when no cell stands for it: the
      ;; painted caret then keeps the nearest cell while the next key still
      ;; starts from the position the caller asked for.
      (setf (etaf-document-caret document) offset)
      (when-let* ((position (etaf-projection-position projection offset)))
        (setf (etaf-document-caret-at document) position)
        (with-current-buffer buffer
          (goto-char position)
          (dolist (window (get-buffer-window-list buffer nil t))
            (set-window-point window position)))))))

;;;; Editing the source

(defun etaf-document-refresh (document)
  "Repaint DOCUMENT's page from its source, now.
An edit on the page must reach the screen before the next key is read, so the
repaint runs here rather than waiting for a change follower's timer: a deferred
repaint would leave the caret working against an older page."
  (let ((source (etaf-document-source document))
        (buffer (etaf-document-buffer document)))
    (when (and (buffer-live-p source) (buffer-live-p buffer))
      (etaf-document--republish document)
      (let ((runtime (etaf-runtime-for-buffer buffer)))
        (when runtime (etaf-runtime-flush runtime))))))

(defun etaf-document--republish (document)
  "Hand DOCUMENT's runtime the current source text.
The application republishes its own way, so this calls the function it
registered when the session opened."
  (when-let* ((republish (plist-get (etaf-document-saved document) :republish)))
    (funcall republish (etaf-document-source-text document))))

(defun etaf-document-write (document start delete insert)
  "In DOCUMENT's source replace DELETE characters at START with INSERT.
An edit made through the page is not a file edit the reader started, so the
source is left unmodified and the session saves once, when it ends; prompting
to save after every keystroke would interrupt the sentence."
  (when-let* ((source (etaf-document-source document)))
    (with-current-buffer source
      (save-excursion
        (goto-char (1+ start))
        (when (> delete 0) (delete-char delete))
        (when (> (length insert) 0) (insert insert)))
      ;; The source is not left asking to be saved after every keystroke, so
      ;; the session remembers that it owes the file a write and pays it when
      ;; it ends.
      (set-buffer-modified-p nil)
      (setf (etaf-document-dirty document) t))))

(defun etaf-document--edit (document start delete insert caret)
  "Replace DELETE characters at START with INSERT and place the caret at CARET."
  (etaf-document-write document start delete insert)
  (etaf-document-refresh document)
  (etaf-document-goto document caret))

;;;; Keys

(defvar etaf-document-prefix-commands
  '(universal-argument digit-argument negative-argument)
  "Commands that only set the argument the next command receives.
They stay part of the sequence being read, so `C-u 3 C-f' reaches the source
as one command with its argument instead of as three keys the page swallowed.")

(defface etaf-document-region-face
  '((t :inherit region))
  "Face of the painted cells the source has selected."
  :group 'etaf)

(defun etaf-document-forward-key ()
  "Run the command this key names against the document the page paints.
Every key the page does not claim itself belongs to the source: this looks the
sequence up in the source buffer, runs it with the caret at the offset the page
shows, and repaints.  A prefix key reads the rest of its sequence where the
key's own maps live, so `C-x C-s' saves the document and `C-u 3 C-f' moves
three characters, exactly as they do in the buffer the text came from."
  (interactive)
  (cond
   ;; A pointer event is not something the document does: it moves the viewport
   ;; or the point on the page.  It runs the binding it has without this map,
   ;; which is the runtime's own scroll or press handling and keeps the painted
   ;; viewport in step with the window.
   ((etaf-document--pointer-event-p (this-command-keys-vector))
    (etaf-document--run-buffer-key (this-command-keys-vector)))
   (t
    (let ((document (gethash (current-buffer) etaf-document--sessions)))
      (cond
       (document (etaf-document--forward-key document))
       ;; The page was opened once and only lost the table that held it, which
       ;; a load of this module while it is open does: it puts itself back and
       ;; takes the key, so the reader keeps typing into the same document.
       ((functionp etaf-document--opener)
        (funcall etaf-document--opener)
        (if-let* ((rebuilt (gethash (current-buffer) etaf-document--sessions)))
            (etaf-document--forward-key rebuilt)
          (etaf-document--fallback-key)))
       (t (etaf-document--fallback-key)))))))

(defun etaf-document--pointer-event-p (keys)
  "Return non-nil when KEYS begins with a mouse event."
  (and (> (length keys) 0)
       (let ((event (aref keys 0)))
         (or (mouse-event-p event)
             (memq (car-safe event) '(mouse-1 mouse-2 mouse-3 wheel-up wheel-down))))))

(defvar etaf-document--dispatching nil
  "Non-nil while a page runs one of its own keys.
The page carries keys as text properties too, so looking a key up without this
map can answer with the command that is reading it; running that would recurse
until Emacs gives up.")

(defun etaf-document--run-buffer-key (keys)
  "Run KEYS through this buffer's own maps, unless that names this command.
A page's own key names this command in the map that put it there and in the text
properties the runtime painted, so a lookup without this map still answers with
it: running it again would nest until the evaluation depth runs out."
  (unless etaf-document--dispatching
    (let* ((etaf-document--dispatching t)
           (binding (let ((overriding-local-map nil)) (key-binding keys t))))
      (when (and (commandp binding)
                 (not (eq binding #'etaf-document-forward-key)))
        (let ((this-command binding)
              (last-command-event (aref keys (1- (length keys)))))
          (call-interactively binding))))))

(defun etaf-document--fallback-key ()
  "Run the key being read from this buffer's own maps, once.
A page can outlive the session that made it editable: the session ends while a
key is in flight, or the buffer is handed back to its application.  The map is
then a leftover, so it is dropped and the key means what it means here.  The key
is run directly rather than fed back to the command loop: a page can carry its
keys as text properties too, and a key put back for those maps to pick up would
land on this same command again and loop forever."
  (setq-local overriding-local-map nil)
  (let ((binding (ignore-errors (key-binding (this-command-keys-vector)))))
    (unless (eq binding #'etaf-document-forward-key)
      (etaf-document--run-buffer-key (this-command-keys-vector)))))

(defvar-local etaf-document--pending nil
  "Non-nil while this page waits for the repaint that follows a key.")

(defvar-local etaf-document--opener nil
  "Function that puts this page back into editing, or nil.
A page outlives the session table that made it editable -- the module can be
loaded again while a page stays open -- so the page keeps what it was opened
with and can hand its keys to a document again instead of reporting an error for
every one of them.")

(defun etaf-document--defer (document)
  "Repaint DOCUMENT's page on the next frame instead of now.
The page answered the key itself, so the repaint that follows the source can
wait: one repaint covers every key pressed before it comes."
  (let ((buffer (etaf-document-buffer document)))
    (when (and (buffer-live-p buffer)
               (not (buffer-local-value 'etaf-document--pending buffer)))
      (with-current-buffer buffer (setq etaf-document--pending t))
      (run-at-time 0 nil
                   (lambda ()
                     (when (buffer-live-p buffer)
                       (with-current-buffer buffer (setq etaf-document--pending nil))
                       (when (eq (gethash buffer etaf-document--sessions) document)
                         (etaf-document-settle buffer))))))))

(defun etaf-document-settle (&optional buffer)
  "Make BUFFER's page, by default the current one, show its document now.
A page repaints on the next frame after a key, which is what keeps typing
responsive; this runs that repaint immediately, for a caller that is about to
read the page or show it."
  (when-let* ((document (gethash (or buffer (current-buffer)) etaf-document--sessions)))
    (let ((target (etaf-document-buffer document)))
      (when (buffer-live-p target)
        (with-current-buffer target (setq etaf-document--pending nil))))
    (etaf-document-refresh document)
    (etaf-document-goto document (or (etaf-document-caret document) 0))
    (etaf-document--paint-region document)))

(defvar etaf-document--forward-run-limit 300
  "Keys this page forwards one after another before it assumes a loop.
A reader types a handful of keys at a time; a page that takes hundreds within a
second is repeating one key, and the frame would never come back.  Lowered by
scenarios that check the guard.")

(defvar etaf-document--forward-run nil
  "Cons of the count and start time of the current run of forwarded keys.")

(defun etaf-document--forward-runaway-p ()
  "Return non-nil when this page has been forwarding the same burst forever.
The frame cannot return while one key keeps reaching the document, so the key is
dropped with a quit instead of leaving the editor frozen."
  (let* ((now (float-time))
         (run (or etaf-document--forward-run (cons 0 now))))
    (setq run (cons (1+ (car run)) (cdr run))
          etaf-document--forward-run run)
    (when (and (> (car run) etaf-document--forward-run-limit)
               (< (- now (cdr run)) 3))
      (setq etaf-document--forward-run nil)
      t)))

(defun etaf-document--forward-key (document)
  "Run the key being read against DOCUMENT's source and repaint the page."
  (unless (eq last-command #'etaf-document-forward-key)
    (setq etaf-document--forward-run nil))
  (when (etaf-document--forward-runaway-p)
    (message "ETAF: %s stopped a runaway key" (this-command-keys-vector))
    (keyboard-quit))
  (let* ((keys (this-command-keys-vector))
         (source (etaf-document-source document))
         (offset (etaf-document-source-offset document)))
    (when (and offset (buffer-live-p source))
      (with-current-buffer source
        (goto-char (1+ offset))
        ;; A prefix argument belongs to the sequence being read, not to the
        ;; command loop: the page runs the whole sequence as one command.
        (let ((prefix-arg prefix-arg)
              (tick (buffer-chars-modified-tick))
              (binding nil)
              (event nil))
          (setq keys keys
                event (aref keys (1- (length keys)))
                binding (key-binding keys t))
          ;; Continue the sequence while the source wants more keys: a prefix
          ;; key holds a keymap, and a prefix argument is a command one key long.
          (while (cond
                  ((and (keymapp binding) (not (eq binding 'undefined)))
                   (setq keys (vconcat keys (vector (read-event nil nil)))
                         event (aref keys (1- (length keys)))
                         binding (key-binding keys t))
                   t)
                  ((memq binding etaf-document-prefix-commands)
                   ;; A prefix argument applies to the key after it, so its own
                   ;; key leaves the sequence: `C-u 3 C-f' is two arguments and
                   ;; one command, not the binding `C-u 3'.
                   (let ((this-command binding)
                         (current-prefix-arg prefix-arg)
                         (last-command-event event))
                     (call-interactively binding))
                   (setq keys (vector (read-event nil nil))
                         event (aref keys 0)
                         binding (key-binding keys t))
                   t))
            nil)
          (when (and (commandp binding) (not (eq binding 'undefined)))
            ;; The source's own command is what ran, so the record says so:
            ;; Emacs folds a run of the same command into one undo step, and
            ;; three typed characters have to undo together as they do in the
            ;; buffer itself.
            (let ((this-command binding)
                  (last-command (etaf-document-last-command document))
                  (current-prefix-arg prefix-arg)
                  (last-command-event event))
              (setf (etaf-document-last-command document) binding)
              (call-interactively binding)))
          (unless (eql tick (buffer-chars-modified-tick))
            (set-buffer-modified-p nil))
          (setq offset (1- (point)))
          ;; A key that changed neither the document nor the caret leaves the
          ;; page alone.  Scrolling is such a key: placing the caret again
          ;; would pull the window back to where it was, and the two would keep
          ;; undoing each other.
          (unless (and (eql tick (buffer-chars-modified-tick))
                       (eql offset (etaf-document-caret document)))
            ;; The page answered the key already, so the repaint that shows what
            ;; the source did lands on the next frame.  The offset is what the
            ;; next key starts from, even while the paint behind it is still the
            ;; old one.
            (setf (etaf-document-caret document) offset)
            (setf (etaf-document-caret-at document)
                  (with-current-buffer (etaf-document-buffer document) (point)))
            (etaf-document--defer document)))))))

(defun etaf-document--paint-region (document)
  "Mark the painted cells DOCUMENT's source holds selected.
A selection is a position in the document like any other, so the page paints
it over the cells the projection gives: what a reader marked has to look
marked before they can cut or replace it."
  (let ((buffer (etaf-document-buffer document))
        (source (etaf-document-source document)))
    (when (and (buffer-live-p buffer) (buffer-live-p source))
      (let ((range (with-current-buffer source
                     (when (region-active-p)
                       (cons (min (point) (mark t)) (max (point) (mark t)))))))
        (when range
          (let ((projection (etaf-document-projection document))
                (beg (1- (car range)))
                (end (1- (cdr range))))
            (when projection
              (with-current-buffer buffer
                (dotimes (index (length projection))
                  (let* ((run (aref projection index))
                         (run-beg (nth 2 run))
                         (run-end (nth 3 run)))
                    (when (and (< run-beg end) (> run-end beg))
                      (let ((from (max run-beg beg))
                            (to (min run-end end)))
                        (add-face-text-property
                         (+ (car run) (- from run-beg))
                         (+ (car run) (- to run-beg))
                         'etaf-document-region-face t)))))))))))))

(defun etaf-document--current ()
  "Return the session of the current page, or signal a `user-error'."
  (or (gethash (current-buffer) etaf-document--sessions)
      (user-error "This buffer is not an editable document page")))

;;;;; Commands

(defun etaf-document-insert (text)
  "Insert TEXT into the document at the painted caret and repaint the page.
This is the command form of typing, for applications and scripts that hand
over text instead of a key."
  (interactive "sInsert: ")
  (let* ((document (etaf-document--current))
         (offset (etaf-document-source-offset document)))
    (when offset
      (etaf-document--edit document offset 0 text (+ offset (length text))))))

(defun etaf-document-delete-char (&optional backward)
  "Delete one document character at the painted caret and repaint the page.
The command form of a deletion key, for applications and scripts."
  (interactive "P")
  (let* ((document (etaf-document--current))
         (offset (etaf-document-source-offset document))
         (start (and offset (- offset (if backward 1 0)))))
    (when (and start
               (> (if backward 1 0) 0)
               (>= start 0)
               (< start (length (or (etaf-document-source-text document) ""))))
      (etaf-document--edit document start 1 "" start))))

(defvar etaf-document-keymap
  (let ((map (make-sparse-keymap)))
    ;; A press places a caret the reader must see, so the page keeps its own
    ;; pointer handling.  Every other key names something the document does,
    ;; so the page forwards it: the source decides what `RET', `TAB', `C-k' or
    ;; `C-x C-s' mean, and this list never grows into a second key map.
    (dolist (event '(down-mouse-1 drag-mouse-1 mouse-1))
      (define-key map (vector event) #'mouse-set-point))
    ;; The viewport belongs to the page: these scroll the window that shows it
    ;; and never touch the document, whose point would then have to be placed
    ;; again and would drag the view back.
    (dolist (key '("C-v" "next")) (define-key map (kbd key) #'scroll-up-command))
    (dolist (key '("M-v" "prior")) (define-key map (kbd key) #'scroll-down-command))
    (define-key map [t] #'etaf-document-forward-key)
    map)
  "Keys a rendered page uses while it accepts typing.
An application extends this with `etaf-document-keys' rather than replacing it,
so every document page reacts the same way to the same key: a key the page does
not claim runs in the source the page renders.")

;;;; Session

(defun etaf-document-keys (document keys)
  "Add KEYS to DOCUMENT's page, keeping the shared bindings.
KEYS is an alist of (KEY . COMMAND), as an application's own root keys."
  (dolist (entry keys)
    (define-key (etaf-document-bindings document) (kbd (car entry)) (cdr entry)))
  document)

;;;###autoload
(cl-defun etaf-document-open (buffer &key source entries republish keymap)
  "Make BUFFER, a mounted page, accept typing that edits SOURCE.
ENTRIES pairs a Host reference with the source range its painted text stands
for; REPUBLISH is called with the source text to redraw the page; KEYMAP adds
the application's own keys.  Return the session, which
`etaf-document-close' ends.

The page keeps its rendering: text typed on it is written to SOURCE and the
page repaints from there.  A system input method composes outside Emacs, so its
characters arrive as ordinary typing and need no channel of their own."
  (unless (and (buffer-live-p buffer) (buffer-live-p source))
    (user-error "An editable page needs a live page buffer and a live source"))
  (unless (etaf-runtime-for-buffer buffer)
    (user-error "This page is not mounted"))
  (when (gethash buffer etaf-document--sessions)
    (etaf-document-close (gethash buffer etaf-document--sessions)))
  (let ((document (etaf--document-make
                   :buffer buffer :source source :entries entries
                   :bindings (copy-keymap etaf-document-keymap)
                   :saved (list :republish republish))))
    (when keymap
      (dolist (entry keymap)
        (define-key (etaf-document-bindings document) (kbd (car entry)) (cdr entry))))
    (puthash buffer document etaf-document--sessions)
    (with-current-buffer buffer
      (setq-local etaf-document--opener
                  (lambda ()
                    (etaf-document-open buffer
                                        :source source :entries entries
                                        :republish republish :keymap keymap)))
      (setq-local overriding-local-map (etaf-document-bindings document))
      (setq-local buffer-read-only t)
      (setq-local cursor-type 'bar)
      ;; A press on the page places a caret the reader must see, so the cursor
      ;; keeps showing instead of following the pointer's hidden style.
      (setq-local etaf-cursor-follows-input-modality nil))
    document))

(defun etaf-document-close (document)
  "End DOCUMENT's editing session and save what was written through it."
  (let ((buffer (etaf-document-buffer document))
        (source (etaf-document-source document)))
    (remhash buffer etaf-document--sessions)
    ;; The map belongs to this session alone: a page that ended up carrying it
    ;; after the buffer was replaced would answer every key with an error about
    ;; a document it no longer has.
    (dolist (other (buffer-list))
      (with-current-buffer other
        (when (eq overriding-local-map (etaf-document-bindings document))
          (setq-local overriding-local-map nil))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq-local overriding-local-map nil)
        (setq-local buffer-read-only t)
        (kill-local-variable 'cursor-type)
        (kill-local-variable 'etaf-cursor-follows-input-modality)))
    ;; The page wrote through the source while it was edited, so the file gets
    ;; the text once the session ends instead of prompting mid-sentence.
    (when (and (buffer-live-p source) (etaf-document-dirty document))
      (with-current-buffer source
        ;; A source without a file is not something to save: it was handed over
        ;; for editing and its owner reads it back.
        (when (buffer-file-name)
          (set-buffer-modified-p t)
          (save-buffer))
        (setf (etaf-document-dirty document) nil))))
  document)

(defun etaf-document-editing-p (&optional buffer)
  "Return non-nil when BUFFER, by default the current one, accepts typing."
  (and (gethash (or buffer (current-buffer)) etaf-document--sessions) t))

(provide 'etaf-document)

;;; etaf-document.el ends here
