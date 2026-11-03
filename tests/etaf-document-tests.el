;;; etaf-document-tests.el --- Editing the source a page paints  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A page stays a rendering while it accepts typing: keys reach the source and
;; the page repaints from it.  These scenarios drive that contract through the
;; public API only, so an application that supplies its own ranges cannot drift
;; from it.

;;; Code:

(require 'etaf-test-support)

(etaf-define-component etaf-document-test-page (&key first second)
  "Render FIRST and SECOND in two Hosts a caller can name."
  :view
  (column
   (box :ref 'first (text (expr first)))
   (box :ref 'second (text (expr second)))))

(defvar etaf-document-test--repaints nil
  "Text each repaint of the page under test received.")

(defun etaf-document-test--page (source)
  "Mount a page painting SOURCE as two blocks and return its buffer.
The first block paints SOURCE's first word and the second the rest, so the
ranges a caller supplies are the ones a markup renderer would supply."
  (let ((repaints nil)
        (words (split-string (string-trim source) " " t))
        (buffer (generate-new-buffer " *etaf-document-test*")))
    (etaf-mount buffer
                (etaf-view (etaf-document-test-page
                            :first (car words)
                            :second (mapconcat #'identity (cdr words) " ")))
                (list :viewport-width 400 :viewport-height 20))
    (list buffer repaints)))

(ert-deftest etaf-document-typing-edits-the-source-not-the-page ()
  "A typed character reaches the source and the page repaints from it.
The page must never hold the character itself: text painted into a rendering
cannot be repainted away, so it would survive the next edit as a ghost."
  (let* ((source (generate-new-buffer " *etaf-document-source*"))
         (built (etaf-document-test--page "alpha beta"))
         (buffer (car built))
         (repaints (cadr built)))
    (unwind-protect
        (progn
          (with-current-buffer source (insert "alpha beta"))
          (let ((document (etaf-document-open
                           buffer :source source
                           :entries (list (cons 'first (cons 0 5))
                                          (cons 'second (cons 6 10)))
                           :republish (lambda (text) (push text repaints)))))
            (should (etaf-document-editing-p buffer))
            (should (buffer-local-value 'buffer-read-only buffer))
            (with-current-buffer buffer
              ;; The caret names a cell; inserting there writes that offset.
              (goto-char (point-min))
              (etaf-document-insert "X"))
            (should (equal "Xalpha beta"
                           (with-current-buffer source
                             (buffer-substring-no-properties (point-min) (point-max)))))
            (should (equal "Xalpha beta" (car repaints)))
            (should-not (string-match-p "X"
                                        (with-current-buffer buffer
                                          (buffer-substring-no-properties
                                           (point-min) (point-max)))))
            (etaf-document-close document)
            (should-not (etaf-document-editing-p buffer))))
      (kill-buffer buffer)
      (kill-buffer source))))

(ert-deftest etaf-document-deletion-and-newline-follow-the-caret ()
  "Deletion removes the source character the caret stands on.
A page cannot delete its own text: it is read-only, so deletion is a source
edit like typing."
  (let* ((source (generate-new-buffer " *etaf-document-source*"))
         (buffer (car (etaf-document-test--page "alpha beta"))))
    (unwind-protect
        (progn
          (with-current-buffer source (insert "alpha beta"))
          (let ((document (etaf-document-open
                           buffer :source source
                           :entries (list (cons 'first (cons 0 5))
                                          (cons 'second (cons 6 10)))
                           :republish #'ignore)))
            (with-current-buffer buffer
              ;; The caret at the start of the page names the start of the
              ;; source, where there is nothing before it to delete.
              (goto-char (point-min))
              (should (= 0 (etaf-document-source-offset document)))
              (etaf-document-delete-char t)
              (should (equal "alpha beta"
                             (with-current-buffer source
                               (buffer-substring-no-properties (point-min) (point-max)))))
              (etaf-document-goto document 3)
              (etaf-document-delete-char t))
            (should (equal "alha beta"
                           (with-current-buffer source
                             (buffer-substring-no-properties (point-min) (point-max)))))
            (with-current-buffer buffer
              (etaf-document-goto document 0)
              (etaf-document-insert "\n"))
            (should (equal "\nalha beta"
                           (with-current-buffer source
                             (buffer-substring-no-properties (point-min) (point-max)))))
            (etaf-document-close document)))
      (kill-buffer buffer)
      (kill-buffer source))))

(ert-deftest etaf-document-close-saves-what-the-page-wrote ()
  "An edit made through the page reaches the file when the session ends.
Prompting after each keystroke would interrupt the sentence the reader is in
the middle of writing."
  (let* ((file (make-temp-file "etaf-document" nil ".md"))
         (source nil)
         (buffer (car (etaf-document-test--page "alpha beta"))))
    (unwind-protect
        (progn
          (with-temp-file file (insert "alpha beta"))
          (setq source (find-file-noselect file))
          (let ((document (etaf-document-open
                           buffer :source source
                           :entries (list (cons 'first (cons 0 5))
                                          (cons 'second (cons 6 10)))
                           :republish #'ignore)))
            (with-current-buffer buffer
              (goto-char (point-min))
              (should (= 0 (etaf-document-source-offset document)))
              (etaf-document-insert "Y"))
            ;; Typing through the page is not a file edit the reader started,
            ;; so the source is not left asking to be saved.
            (should-not (buffer-modified-p source))
            (etaf-document-close document)
            (should (equal "Yalpha beta"
                           (with-temp-buffer
                             (insert-file-contents file)
                             (buffer-substring-no-properties (point-min) (point-max)))))))
      (when (buffer-live-p source) (kill-buffer source))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-file file))))

(provide 'etaf-document-tests)

(ert-deftest etaf-document-a-closed-page-gives-the-keyboard-back ()
  "Ending a session leaves no key map behind in its page.
The map lives in the page buffer, so a page whose session ended elsewhere would
otherwise answer every key with an error about a document it no longer has."
  (let* ((source (generate-new-buffer " *etaf-document-source*"))
         (built (etaf-document-test--page "alpha beta"))
         (buffer (car built)))
    (unwind-protect
        (progn
          (with-current-buffer source (insert "alpha beta"))
          (let ((document (etaf-document-open
                           buffer :source source
                           :entries (list (cons 'first (cons 0 5)))
                           :republish #'ignore)))
            (should (buffer-local-value 'overriding-local-map buffer))
            (etaf-document-close document)
            (should-not (buffer-local-value 'overriding-local-map buffer))
            (with-current-buffer buffer
              ;; A key typed at a page that stopped accepting typing runs the
              ;; buffer's own command instead of reporting an error.
              (should (null (condition-case nil
                                (progn (execute-kbd-macro "x") nil)
                              (error t)))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest etaf-document-a-key-that-finds-no-session-runs-once ()
  "A key typed at a page whose session is gone neither errors nor repeats.
The page can carry its keys as text properties, so handing the key back to the
command loop would deliver it to this same command again and the frame would
never come back."
  (let* ((source (generate-new-buffer " *etaf-document-source*"))
         (built (etaf-document-test--page "alpha beta"))
         (buffer (car built))
         (document nil))
    (unwind-protect
        (progn
          (with-current-buffer source
            (insert "alpha beta")
            (goto-char (point-min)))
          (set-window-buffer (selected-window) buffer)
          (setq document (etaf-document-open
                          buffer :source source
                          :entries (list (cons 'first (cons 0 5)))
                          :republish #'ignore))
          (with-current-buffer buffer
            ;; The session ends while the page still maps its keys, which is
            ;; what a page outliving its session looks like.
            (etaf-document-close document)
            (let ((quit nil))
              (condition-case nil
                  (execute-kbd-macro "x")
                (quit (setq quit t)))
              (should-not quit)
              (should-not (buffer-local-value 'overriding-local-map buffer))
              (should (= 1 (point))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest etaf-document-a-key-loop-stops-instead-of-freezing ()
  "A document that keeps putting the same key back stops instead of pinning Emacs.
A loop here is not slow: it keeps redisplay from ever returning, so the page
drops the burst and quits instead of leaving the editor frozen."
  (let* ((source (generate-new-buffer " *etaf-document-source*"))
         (built (etaf-document-test--page "alpha beta"))
         (buffer (car built))
         (document nil))
    (unwind-protect
        (progn
          (with-current-buffer source
            (insert "alpha beta")
            (goto-char (point-min))
            ;; The document hands the key straight back, which is the shape a
            ;; runaway looks like from the page's side.
            (local-set-key (kbd "x")
                           (lambda () (interactive) (push ?x unread-command-events))))
          (set-window-buffer (selected-window) buffer)
          (setq document (etaf-document-open
                          buffer :source source
                          :entries (list (cons 'first (cons 0 5)))
                          :republish #'ignore))
          (with-current-buffer buffer
            (let ((quit nil))
              (condition-case nil
                  (execute-kbd-macro "x")
                (quit (setq quit t)))
              (should quit))))
      (when (and document (buffer-live-p buffer))
        (with-current-buffer buffer (ignore-errors (etaf-document-close document))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest etaf-document-scrolling-a-page-is-not-an-edit ()
  "A viewport key scrolls the page and leaves the document alone.
The page claims the viewport itself: forwarding `C-v' to the source would scroll
the window that shows the page and then place the caret again, and the two would
keep undoing each other."
  (let* ((text (mapconcat #'identity (make-list 60 "line of text") "\n"))
         (source (generate-new-buffer " *etaf-document-source*"))
         (built (etaf-document-test--page text))
         (buffer (car built))
         (document nil))
    (unwind-protect
        (progn
          (with-current-buffer source
            (insert text)
            (goto-char (point-min))
            ;; A key the page forwards runs here, so a source binding that
            ;; writes marks whether the page let the viewport key through.
            (local-set-key (kbd "C-v")
                           (lambda () (interactive) (insert "FORWARDED"))))
          (set-window-buffer (selected-window) buffer)
          (setq document (etaf-document-open
                          buffer :source source
                          :entries (lambda (&optional _)
                                     (list (cons 'first (cons 0 12))))
                          :republish #'ignore))
          (with-current-buffer buffer
            (goto-char (point-min))
            (let ((start (window-start)))
              (execute-kbd-macro (kbd "C-v"))
              (should (= (length text) (with-current-buffer source (buffer-size))))
              (should (> (window-start) start)))))
      (when (and document (buffer-live-p buffer))
        (with-current-buffer buffer (ignore-errors (etaf-document-close document))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (buffer-live-p source) (kill-buffer source)))))

;;; etaf-document-tests.el ends here
