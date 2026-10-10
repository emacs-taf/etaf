;;; etaf-keys-tests.el --- Scoped keys, dismissal, keyboard drag and palette -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'etaf-test-support)

(defun etaf-keys-test-press (key)
  "Run the command KEY is bound to in the current buffer, or signal."
  (let ((command (key-binding (kbd key) t)))
    (unless (commandp command) (error "Key %s runs %S" key command))
    (call-interactively command)
    command))

(defun etaf-keys-test-press-maybe (key)
  "Run KEY's scoped Host command when it has one and return it, else nil."
  (let ((command (key-binding (kbd key) t)))
    (when (and (commandp command) (not (symbolp command)))
      (call-interactively command)
      command)))

(ert-deftest etaf-keys-resolve-from-focus-outward-and-nearest-wins ()
  "A Host's :keys work inside it; the nearest Host binding a key wins."
  (let (log)
    (etaf-test-with-mount (runtime (etaf-view
                                    (column :ref 'app
                                            :keys (list (list "n" (lambda () (push 'app-n log)) "Next")
                                                        (list "x" (lambda () (push 'app-x log)) "Delete"))
                                            (box :ref 'first :tab-index 0 "first")
                                            (column :ref 'pane
                                                    :keys (list (list "n" (lambda () (push 'pane-n log))))
                                                    (box :ref 'second :tab-index 0 "second")))))
      (etaf-focus runtime 'first)
      (etaf-keys-test-press "n")
      (etaf-keys-test-press "x")
      (etaf-focus runtime 'second)
      (etaf-keys-test-press "n")
      (etaf-keys-test-press "x")
      (should (equal (nreverse log) '(app-n app-x pane-n app-x))))))

(ert-deftest etaf-keys-sequences-are-scoped-and-share-prefixes ()
  "A prefix sequence works inside its Host and falls back to the buffer's map."
  (let (log)
    (etaf-test-with-mount (runtime (etaf-view
                                    (column (box :ref 'inside :tab-index 0
                                                 :keys (list (list "C-c C-u" (lambda () (push 'host log))))
                                                 "inside")
                                            (box :ref 'outside :tab-index 0 "outside"))))
      (let ((map (make-sparse-keymap)))
        (define-key map (kbd "C-c C-u") (lambda () (interactive) (push 'buffer-u log)))
        (define-key map (kbd "C-c C-k") (lambda () (interactive) (push 'buffer-k log)))
        (use-local-map map))
      (etaf-focus runtime 'inside)
      (etaf-keys-test-press "C-c C-u")
      (etaf-keys-test-press "C-c C-k")
      (etaf-focus runtime 'outside)
      (etaf-keys-test-press "C-c C-u")
      (should (equal (nreverse log) '(host buffer-k buffer-u))))))

(ert-deftest etaf-keys-commands-act-on-hosts-they-reveal ()
  "A key command sees its own writes published, like a keymap command."
  (let ((open (etaf-ref nil)) found)
    (etaf-test-with-mount (runtime (etaf-view
                                    (column :keys (list (list "o" (lambda ()
                                                                    (etaf-set-value open t)
                                                                    (setq found (etaf-host-ref-position
                                                                                 runtime 'field))
                                                                    (etaf-focus runtime 'field))))
                                            (box :ref 'start :tab-index 0 "start")
                                            (box :if (etaf-value open)
                                                 :ref 'field :tab-index 0 "field"))))
      (etaf-focus runtime 'start)
      (etaf-keys-test-press "o")
      (should found)
      (should (eq (etaf-focused-host-ref runtime) 'field)))))

(ert-deftest etaf-keys-focus-enter-runs-when-focus-moves-into-a-host ()
  "`:on-focus-enter' runs on each Host focus enters, not on moves inside it."
  (let (log)
    (etaf-test-with-mount (runtime (etaf-view
                                    (column
                                     (box :ref 'outside :tab-index 0 "outside")
                                     (column :ref 'window
                                             :on-focus-enter (lambda () (push 'window log))
                                             (box :ref 'a :tab-index 0 "a")
                                             (box :ref 'b :tab-index 0
                                                  :on-focus-enter (lambda () (push 'b log))
                                                  "b")))))
      (etaf-focus runtime 'outside)
      (etaf-focus-next runtime)
      (etaf-focus-next runtime)
      (etaf-focus runtime 'outside)
      (etaf-focus runtime 'b)
      (should (equal (nreverse log) '(window b b window))))))

(ert-deftest etaf-keys-modal-scope-hides-outer-keys-and-escape-dismisses ()
  "An open modal Host confines keys, ignores stray letters; Escape/C-g dismiss."
  (let ((open (etaf-ref t)) (log nil))
    (etaf-test-with-mount (runtime (etaf-view
                                    (column :keys (list (list "q" (lambda () (push 'quit log))))
                                            (box :ref 'outside :tab-index 0 "outside")
                                            (column :if (etaf-value open)
                                                    :ref 'dialog :focus-scope 'modal
                                                    :on-dismiss (lambda ()
                                                                  (push 'dismiss log)
                                                                  (etaf-set-value open nil))
                                                    (box :ref 'ok :tab-index 0 "ok")))))
      (etaf-focus runtime 'outside)
      (should-not (etaf-keys-test-press-maybe "q"))
      (should (eq (key-binding "w" t) #'ignore))
      (etaf-keys-test-press "<escape>")
      (should (equal log '(dismiss)))
      (etaf-focus runtime 'outside)
      (etaf-keys-test-press "q")
      (should (equal log '(quit dismiss)))
      (should-not (eq (key-binding "w" t) #'ignore))
      (etaf-set-value open t)
      (etaf-focus runtime 'ok)
      (etaf-keys-test-press "C-g")
      (should (equal log '(dismiss quit dismiss)))
      (should-not (etaf-value open)))))

(ert-deftest etaf-keys-behaviors-move-and-resize-from-the-keyboard ()
  "Draggable and resizable Behaviors accept M-arrows and M-S-arrows."
  (let* ((x (etaf-ref 10)) (y (etaf-ref 5))
         (width (etaf-ref 20)) (height (etaf-ref 4))
         (move (etaf-draggable :x x :y y))
         (resize (etaf-resizable :width width :height height
                                 :min-width 19)))
    (etaf-test-with-mount (runtime (etaf-view
                                    (column
                                     (box :ref 'title :tab-index 0 :use (list move) "title")
                                     (box :ref 'grip :tab-index 0 :use (list resize) "grip"))))
      (etaf-focus runtime 'title)
      (etaf-keys-test-press "M-<right>")
      (etaf-keys-test-press "M-<down>")
      (should (equal (list (etaf-value x) (etaf-value y))
                     (list (+ 10 (frame-char-width)) (+ 5 (frame-char-height)))))
      (should-not (etaf-keys-test-press-maybe "M-S-<right>"))
      (etaf-focus runtime 'grip)
      (etaf-keys-test-press "M-S-<right>")
      (should (= (etaf-value width) (+ 20 (frame-char-width))))
      (etaf-keys-test-press "M-S-<left>")
      (etaf-keys-test-press "M-S-<left>")
      (should (= (etaf-value width) 19))
      (etaf-keys-test-press "M-S-<up>")
      (should (= (etaf-value height) (- 4 (frame-char-height)))))))

(ert-deftest etaf-keys-drag-step-and-arrows-step-a-focused-separator ()
  "`etaf-drag-step' drives :on-drag; arrows step a focused separator."
  (let (gestures)
    (etaf-test-with-mount (runtime (etaf-view
                                    (column
                                     (box :ref 'above :tab-index 0 "above")
                                     (box :ref 'split :tab-index 0 :role 'separator
                                          :aria-orientation 'vertical
                                          :on-drag (lambda (gesture) (push gesture gestures))
                                          "|"))))
      (should (eq (etaf-drag-step runtime 'split 2 0) 'split))
      (should (equal (mapcar (lambda (g) (plist-get g :phase)) gestures) '(end start)))
      (should (equal (plist-get (car gestures) :delta) (cons (* 2 (frame-char-width)) 0)))
      (should (plist-get (car gestures) :keyboard))
      (setq gestures nil)
      (etaf-focus runtime 'split)
      (etaf-keys-test-press "<left>")
      (should (equal (plist-get (car gestures) :delta) (cons (- (frame-char-width)) 0)))
      (setq gestures nil)
      (etaf-keys-test-press "<up>")
      (should-not gestures)
      (should (equal (etaf-focused-host-ref runtime) 'above)))))

(ert-deftest etaf-keys-palette-lists-labelled-keys-and-controls ()
  "`?' opens the palette; it runs labelled keys and presses controls."
  (let (log offered)
    (etaf-test-with-mount (runtime (etaf-view
                                    (column :keys (list (list "r" (lambda () (push 'reload log)) "Reload")
                                                        (list "z" (lambda () (push 'hidden log))))
                                            (box :ref 'save :tab-index 0
                                                 :on-press (lambda () (push 'save log))
                                                 "Save file")
                                            (box :ref 'gear :tab-index 0 :aria-label "Settings"
                                                 :on-press (lambda () (push 'settings log))
                                                 "*"))))
      (etaf-focus runtime 'save)
      (should (eq (key-binding (kbd "?") t) 'etaf-palette))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (setq offered (all-completions "" collection))
                   (car (member "Settings" offered)))))
        (etaf-palette runtime))
      (should (equal offered '("Reload" "Save file" "Settings")))
      (should (equal log '(settings)))
      (should (equal (etaf-focused-host-ref runtime) 'gear))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "Reload")))
        (etaf-palette runtime))
      (should (equal log '(reload settings)))
      (let ((map (make-sparse-keymap)))
        (define-key map "?" #'describe-mode)
        (use-local-map map))
      (should (eq (key-binding (kbd "?") t) 'describe-mode)))))

(ert-deftest etaf-keys-reject-invalid-bindings ()
  "Malformed :keys, :focus-group and :focus-scope values are render errors."
  (dolist (props (list (list :keys '(("n")))
                       (list :keys (list (list "g g" #'ignore)))
                       (list :keys (list (list "C-c" #'ignore) (list "C-c n" #'ignore)))
                       (list :keys (list (list "n" #'ignore 'label)))
                       (list :focus-group 'diagonal)
                       (list :focus-scope 'global)))
    (should-error (etaf-test-with-mount (_runtime (etaf-node 'box props (list "x"))))
                  :type 'etaf-renderer-error)))

;;; etaf-keys-tests.el ends here
