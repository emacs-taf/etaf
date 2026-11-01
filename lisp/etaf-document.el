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
;; A key only ever changes the source.  Typing reaches the source through
;; `self-insert-command', which is also where a system input method's finished
;; characters arrive; deletion and newlines take the same route because the page
;; itself is read-only.  Keys whose meaning is a document position rather than a
;; painted cell -- `C-e', `C-a', `M-f', `M-b', the document edges -- run in the
;; source as well, so `C-e' stops at the end of a paragraph instead of at the
;; end of a padded screen line.

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
  buffer source entries (bindings nil) (saved nil) (dirty nil))

;;;; Reading the page

(defun etaf-document-source-text (document)
  "Return DOCUMENT's source text."
  (when-let* ((source (etaf-document-source document)))
    (with-current-buffer source
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun etaf-document-entries-now (document)
  "Return DOCUMENT's current source ranges.
A page repaints after every edit, and a repaint can replace the Hosts its
blocks live in; a list captured when the session opened would name Hosts that
no longer exist, so a caller may hand over a function instead and have it asked
each time."
  (let ((entries (etaf-document-entries document)))
    (if (functionp entries) (funcall entries) entries)))

(defun etaf-document-projection (document)
  "Return DOCUMENT's painted page as source ranges, or nil without a page."
  (when-let* ((buffer (etaf-document-buffer document))
              (runtime (and (buffer-live-p buffer)
                            (etaf-runtime-for-buffer buffer))))
    (etaf-projection runtime (etaf-document-entries-now document)
                     (etaf-document-source-text document))))

(defun etaf-document-source-offset (document &optional position)
  "Return the source offset the painted POSITION names, by default at point."
  (let ((projection (etaf-document-projection document))
        (at (or position (point))))
    (cond ((and (etaf-document-buffer document)
                (eq (current-buffer) (etaf-document-buffer document))
                (>= at (point-max)))
           (length (or (etaf-document-source-text document) "")))
          (projection (etaf-projection-source-offset projection at)))))

(defun etaf-document-goto (document offset)
  "Put the caret on the painted cell where source OFFSET lives.
A window shows its own point, so every window displaying the page moves too;
otherwise the caret a reader sees never follows the edit."
  (let ((buffer (etaf-document-buffer document))
        (projection (etaf-document-projection document)))
    (when (and (buffer-live-p buffer) projection)
      (when-let* ((position (etaf-projection-position projection offset)))
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

(defun etaf-document--run-key (document key)
  "Run KEY at the page's caret in DOCUMENT's source, then repaint the page.
KEY is the character the reader produced.  A system input method composes
outside Emacs and hands over finished characters, so nothing here translates
keys."
  (let* ((offset (etaf-document-source-offset document))
         (source (etaf-document-source document)))
    (when (and offset (buffer-live-p source))
      (with-current-buffer source
        (goto-char (1+ offset))
        (let* ((event (if (characterp key) key (aref key 0)))
               (last-command-event event)
               (binding (key-binding (vector event))))
          (if (and (commandp binding) (not (eq binding 'undefined)))
              (condition-case nil
                  (call-interactively binding)
                (error (insert (string event))))
            (insert (string event))))
        (let ((target (1- (point))))
          (set-buffer-modified-p nil)
          (etaf-document-refresh document)
          (etaf-document-goto document target))))))

(defun etaf-document--move (document command)
  "Run COMMAND against DOCUMENT's source and put the caret where it lands.
A key on a painted page names a position in the document, not in the rendering,
so the caret goes to the source offset COMMAND reached."
  (let ((offset (etaf-document-source-offset document))
        (source (etaf-document-source document)))
    (when (and offset (buffer-live-p source))
      (with-current-buffer source
        (save-excursion
          (goto-char (1+ offset))
          (call-interactively command)
          (etaf-document-goto document (1- (point))))))))

(defun etaf-document-goto-edge (document &optional end)
  "Put the caret at the source edge of the run it stands on, END or start.
A painted run is one piece of text: a paragraph, a heading's words, a table
cell.  Its edge is where the text a reader sees ends, which is not the line's
end in the source -- a table cell ends at its pipe, a quote at its bar -- so
this is the position `C-e' and `C-a' name."
  (let ((projection (etaf-document-projection document))
        (offset (etaf-document-source-offset document)))
    (when (and projection offset)
      (let ((best nil))
        (dotimes (index (length projection))
          (let ((run (aref projection index)))
            ;; The run the caret stands on, or the next one when it sits just
            ;; before it: a cell starts after the characters that frame it, and
            ;; the caret a reader sees there belongs to that cell.
            (when (or (and (<= (nth 2 run) offset) (<= offset (nth 3 run)))
                      (and (null best) (> (nth 2 run) offset)))
              (setq best run))))
        (when best
          (etaf-document-goto document (if end (nth 3 best) (nth 2 best))))))))

(defun etaf-document-line-start ()
  "Move the caret to the start of the painted text it stands on."
  (interactive)
  (etaf-document-goto-edge (etaf-document--current) nil))

(defun etaf-document-line-end ()
  "Move the caret to the end of the painted text it stands on."
  (interactive)
  (etaf-document-goto-edge (etaf-document--current) t))

(defun etaf-document--move-command (command)
  "Return an interactive command that runs COMMAND against the document."
  (lambda () (interactive) (etaf-document--move (etaf-document--current) command)))

(defun etaf-document--current ()
  "Return the session of the current page, or signal a `user-error'."
  (or (gethash (current-buffer) etaf-document--sessions)
      (user-error "This buffer is not an editable document page")))

;;;;; Commands

(defun etaf-document-self-insert ()
  "Insert the character the reader produced into the document, not the page.
A system input method composes outside Emacs and hands over finished
characters, so they arrive as `self-insert-command' rather than through
`input-method-function'; this is where they reach the source."
  (interactive)
  (etaf-document--run-key (etaf-document--current) last-command-event))

(defun etaf-document-delete-backward ()
  "Delete the document character before the caret and repaint the page."
  (interactive)
  (etaf-document-delete-char t))

(defun etaf-document-delete-forward ()
  "Delete the document character after the caret and repaint the page."
  (interactive)
  (etaf-document-delete-char nil))

(defun etaf-document-newline ()
  "Break the document line at the caret and repaint the page."
  (interactive)
  (etaf-document-insert "\n"))

(defun etaf-document-insert (text)
  "Insert TEXT into the document at the painted caret and repaint the page."
  (interactive "sInsert: ")
  (let* ((document (etaf-document--current))
         (offset (etaf-document-source-offset document)))
    (when offset
      (etaf-document--edit document offset 0 text (+ offset (length text))))))

(defun etaf-document-delete-char (&optional backward)
  "Delete one document character at the painted caret and repaint the page."
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
    ;; The page is read-only, so its own deletion and line-breaking commands
    ;; cannot run; these run against the source instead.
    (dolist (key '("DEL" "<backspace>"))
      (define-key map (kbd key) #'etaf-document-delete-backward))
    (define-key map (kbd "C-d") #'etaf-document-delete-forward)
    (dolist (key '("RET" "<return>"))
      (define-key map (kbd key) #'etaf-document-newline))
    ;; A canvas normally binds these to focus navigation, because a painted
    ;; page is an interface rather than text.  While the page accepts typing the
    ;; caret is text, and these keys name document positions.
    ;; These name a document position, so they run their command in the source
    ;; and bring the caret back.  The line edges are not line commands at all:
    ;; a painted run is a paragraph or a cell, and its edge is what they mean.
    (dolist (key '("<home>" "<end>" "C-a" "C-e"))
      (define-key map (kbd key)
                  (if (string-match-p "home\|C-a" key)
                      #'etaf-document-line-start
                    #'etaf-document-line-end)))
    (dolist (entry '(("<left>" . backward-char) ("C-b" . backward-char)
                     ("<right>" . forward-char) ("C-f" . forward-char)
                     ("M-f" . forward-word) ("M-b" . backward-word)
                     ("M-<" . beginning-of-buffer) ("M->" . end-of-buffer)))
      (define-key map (kbd (car entry))
                      (etaf-document--move-command (cdr entry))))
    (dolist (event '(down-mouse-1 drag-mouse-1 mouse-1))
      (define-key map (vector event) #'mouse-set-point))
    (define-key map [remap self-insert-command] #'etaf-document-self-insert)
    map)
  "Keys a rendered page uses while it accepts typing.
An application extends this with `etaf-document-keys' rather than replacing it,
so every document page reacts the same way to the same key.")

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
