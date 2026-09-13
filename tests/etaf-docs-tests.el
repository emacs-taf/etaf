;;; etaf-docs-tests.el --- ETAF documentation contract tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'macroexp)
(require 'etaf)


(defconst etaf-docs-test--root
  (file-name-directory
   (directory-file-name (file-name-directory (or load-file-name
                                                 buffer-file-name))))
  "Absolute path of the ETAF repository under test.")

(defun etaf-docs-test--read (relative-file)
  "Return the contents of RELATIVE-FILE in the repository."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative-file etaf-docs-test--root))
    (buffer-string)))

(defun etaf-docs-test--elisp-blocks (contents)
  "Return the fenced Elisp blocks found in documentation CONTENTS."
  (let (blocks)
    (with-temp-buffer
      (insert contents)
      (goto-char (point-min))
      (while (re-search-forward "^```elisp[[:space:]]*$" nil t)
        (let ((start (line-beginning-position 2)))
          (unless (re-search-forward "^```[[:space:]]*$" nil t)
            (error "Unclosed Elisp documentation block"))
          (push (buffer-substring-no-properties start
                                                 (match-beginning 0))
                blocks))))
    (nreverse blocks)))

(defun etaf-docs-test--read-all (source)
  "Read every form in Elisp documentation SOURCE and return its count."
  (with-temp-buffer
    (insert source)
    (goto-char (point-min))
    (let ((count 0))
      (condition-case err
          (while t
            (read (current-buffer))
            (cl-incf count))
        (end-of-file count)
        (error (error "Cannot read documentation form: %S" err))))))

(defun etaf-docs-test--forms (source)
  "Read and return every form in documentation SOURCE."
  (with-temp-buffer
    (insert source)
    (goto-char (point-min))
    (let (forms)
      (condition-case nil
          (while t (push (read (current-buffer)) forms))
        (end-of-file (nreverse forms))))))

(defun etaf-docs-test--marked-examples (contents)
  "Extract named executable documentation examples from CONTENTS."
  (with-temp-buffer
    (insert contents)
    (goto-char (point-min))
    (let (examples)
      (while (re-search-forward
              "^<!-- etaf-example: \\([^ ]+\\) -->\n```elisp\n" nil t)
        (let ((name (match-string 1))
              (start (point)))
          (unless (re-search-forward "^```$" nil t)
            (error "Unclosed executable example %s" name))
          (push (cons name (buffer-substring-no-properties
                            start (match-beginning 0)))
                examples)))
      (nreverse examples))))

(defun etaf-docs-test--run-fresh (source assertions)
  "Run exact example SOURCE and ASSERTIONS in a fresh core-only Emacs."
  (let ((script (make-temp-file "etaf-readme-" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert source "\n")
            (prin1 assertions (current-buffer))
            (insert "\n(should-not (featurep 'etaf-ui))\n"
                    "(should-not (featurep 'etaf-playground))\n"))
          (with-temp-buffer
            (let ((status
                   (apply #'call-process
                          (expand-file-name invocation-name invocation-directory)
                          nil (current-buffer) nil "-Q" "--batch"
                          (append
                           (cl-loop for directory in '("." "../ebox" "../tp"
                                                       "../ecss")
                                    append (list "-L" (expand-file-name
                                                       directory
                                                       etaf-docs-test--root)))
                           (list "--eval"
                                 (prin1-to-string
                                  '(progn
                                     (require 'ert)
                                     (require 'jka-compr)
                                     (setq load-suffixes '(".el" ".elc")
                                           load-prefer-newer t)))
                                 "-l" script)))))
              (unless (equal status 0)
                (ert-fail (format "Documentation child exited %S:\n%s"
                                  status (buffer-string)))))))
      (delete-file script))))

(ert-deftest etaf-docs-readme-examples-mount-and-dispatch-in-fresh-emacs ()
  "Both READMEs must work from their exact requires in isolated processes."
  (dolist (file '("README.md" "README.zh-CN.md"))
    (let ((examples (etaf-docs-test--marked-examples
                     (etaf-docs-test--read file))))
      (should (equal '("hello" "card" "counter") (mapcar #'car examples)))
      (dolist (example examples)
        (etaf-docs-test--run-fresh
         (cdr example)
         (pcase (car example)
           ("hello"
            '(let ((runtime (etaf-runtime-for-buffer "*etaf-hello*")))
               (should runtime)
               (should (equal "Hello ETAF"
                              (etaf-dispatch-event runtime 'hello 'press)))
               (etaf-unmount runtime)))
           ("card"
            '(let ((runtime (etaf-runtime-for-buffer "*etaf-card*")))
               (should runtime)
               (with-current-buffer "*etaf-card*"
                 (should (string-match-p
                          "Account[[:space:]]+Connected[[:space:]]+Footer"
                          (buffer-string))))
               (etaf-unmount runtime)))
           ("counter"
            '(let ((runtime (etaf-runtime-for-buffer "*etaf-counter*")))
               (should runtime)
               (etaf-dispatch-event runtime 'increment 'press)
               (with-current-buffer "*etaf-counter*"
                 (should (string-match-p "Count: 1" (buffer-string))))
               (etaf-unmount runtime)))))))))

(ert-deftest etaf-docs-context-and-theme-examples-mount-in-fresh-emacs ()
  "Run exact Context and Theme examples without prior definitions or imports."
  (dolist (file '("docs/manual.md" "docs/manual.zh-CN.md"
                  "docs/architecture.md" "docs/architecture.zh-CN.md"))
    (let ((examples (etaf-docs-test--marked-examples
                     (etaf-docs-test--read file))))
      (should (equal '("context" "theme")
                     (sort (mapcar #'car examples) #'string<)))
      (dolist (example examples)
        (etaf-docs-test--run-fresh
         (cdr example)
         (pcase (car example)
           ("context"
            '(let ((runtime (etaf-runtime-for-buffer "*etaf-context*")))
               (should runtime)
               (with-current-buffer "*etaf-context*"
                 (should (string-match-p "Service: demo-service"
                                         (buffer-string))))
               (etaf-unmount runtime)))
           ("theme"
            '(let* ((runtime (etaf-runtime-for-buffer "*etaf-theme*"))
                    (props (gethash 'themed-content
                                    (etaf-runtime-host-props runtime))))
               (should runtime)
               (should (equal "#F4F6FB" (plist-get props :color)))
               (should (equal "#202634" (plist-get props :background-color)))
               (with-current-buffer "*etaf-theme*"
                 (goto-char (point-min))
                 (should (search-forward "Themed content" nil t))
                 (let ((face (get-text-property (1- (point)) 'face)))
                   (should (string-match-p "#F4F6FB" (format "%S" face)))
                   (should (string-match-p "#202634" (format "%S" face)))))
               (etaf-unmount runtime)))))))))

(defun etaf-docs-test--mounted-collection-probe (forms)
  "Load exact documentation FORMS and mount the collection composition."
  (etaf-component-redefine-run
   (lambda ()
     (dolist (form forms)
       (eval form t))))
  (let ((buffer (generate-new-buffer " *etaf-docs-m0b*")))
    (unwind-protect
        (progn
          (let ((view
                 (eval
                  '(etaf-view
                    (etaf-docs-collection-card
                     :items '((1 . "One") (2 . "Two"))
                     :footer-view (etaf-view (text "Dynamic"))
                     (slot :name 'footer (text "Footer"))))
                  t)))
            (etaf-mount buffer view))
          (let ((text (with-current-buffer buffer (buffer-string))))
            (dolist (expected '("One" "Two" "Dynamic" "Footer"))
              (should (string-match-p expected text)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest etaf-docs-user-surface-has-one-current-vocabulary ()
  "Reject old public entry names and stale View examples in user docs."
  (dolist (file '("README.md" "README.zh-CN.md"
                  "README.md" "README.zh-CN.md"
                  "docs/architecture.md" "docs/architecture.zh-CN.md"
                  "docs/manual.md" "docs/manual.zh-CN.md"
                  "docs/architecture.md"
                  "docs/architecture.zh-CN.md"))
    (let ((contents (etaf-docs-test--read file)))
      (should-not
       (string-match-p
        (regexp-opt '("etaf-template" "etaf-create-app" "expr :value"
                      "ETAF also registers the short alias"
                      "registry assigns a semantic"
                      "ETAF 也会注册短 alias"
                      "注册表会分配语义明确的"))
        contents))
      (should-not (string-match-p "(text \"[^\"]+\" :" contents))))
  (let ((guide (etaf-docs-test--read "docs/manual.md")))
    (dolist (token '("etaf-view" "etaf-mount" "etaf-define-component"
                     "etaf-data-grid" "etaf-resource"))
      (should (string-match-p (regexp-quote token) guide)))))

(ert-deftest etaf-docs-elisp-examples-are-readable ()
  "Keep fenced Elisp examples syntactically readable by Emacs."
  (dolist (file '("README.md" "README.zh-CN.md"
                  "README.md" "README.zh-CN.md"
                  "docs/architecture.md" "docs/architecture.zh-CN.md"
                  "docs/manual.md" "docs/manual.zh-CN.md"
                  "docs/architecture.md"
                  "docs/architecture.zh-CN.md"))
    (dolist (block (etaf-docs-test--elisp-blocks
                    (etaf-docs-test--read file)))
      (should (> (etaf-docs-test--read-all block) 0)))))

(ert-deftest etaf-docs-component-contract-is-current ()
  "Keep public Component prose aligned with the authoritative macro contract."
  (dolist (file '("docs/architecture.md" "docs/architecture.zh-CN.md"
                  "docs/manual.md" "docs/manual.zh-CN.md"
                  "docs/architecture.md"
                  "docs/architecture.zh-CN.md"))
    (let ((contents (etaf-docs-test--read file)))
      (should (string-match-p (regexp-quote ":view") contents))
      (should (string-match-p (regexp-quote ":render") contents))
      (should (string-match-p (regexp-quote ":setup") contents))
      (should (string-match-p (regexp-opt '("opaque state" "opaque 状态"))
                              contents))
      (should-not
       (string-match-p
        (regexp-opt '("setup returns a zero-argument render function"
                      ":setup` runs once per retained identity and returns a zero-argument render function"
                      ":setup` runs once for a retained Component instance and must return a zero-argument render function"
                      "返回零参数 render 函数"
                      "必须返回零参数 render 函数"))
        contents)))))

(ert-deftest etaf-docs-data-grid-selection-contract-is-current ()
  "Document only selection inputs actually declared by `etaf-data-grid'."
  (dolist (file '("docs/manual.md" "docs/manual.zh-CN.md"))
    (let ((contents (etaf-docs-test--read file)))
      (should (string-match-p (regexp-quote ":row-selected-p") contents))
      (should-not (string-match-p (regexp-quote ":selected-key") contents)))))

(ert-deftest etaf-docs-interaction-contract-is-current ()
  "Keep the public Action/Behavior/event composition contract explicit."
  (dolist (file '("docs/architecture.md" "docs/architecture.zh-CN.md"
                  "docs/manual.md" "docs/manual.zh-CN.md"))
    (let ((contents (etaf-docs-test--read file)))
      (dolist (token '("Host" "Behavior" "short-circuit" "first"
                       "capture" "bubble" "application" "feature"
                       "etaf-action-redefine-run" "dispatch"))
        (should (string-match-p (regexp-quote token) contents))))))

(defun etaf-docs-test--snapshot-probe (forms)
  "Run exact snapshot FORMS after one local publication in the documented app."
  (let ((label (etaf-ref "Before"))
        (buffer-name "*etaf-hello*"))
    (should-not (get-buffer buffer-name))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (text (expr (etaf-value label)))))
          (setf (etaf-value label) "Current")
          (let ((result (eval (cons 'progn forms) t)))
            (should (= 3 (length result)))
            (should (and (integerp (nth 0 result)) (> (nth 0 result) 0)))
            (should (integerp (nth 1 result)))
            (should (equal "Current" (substring-no-properties (nth 2 result))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-source-uses-only-public-ebox-names ()
  "Reject Ebox private functions, fields and dynamic construction context."
  (dolist (file
           (append
            (directory-files (expand-file-name "lisp" etaf-docs-test--root) t "\\.el\\'")
            (directory-files
             (expand-file-name "examples" etaf-docs-test--root)
             t "\\.el\\'")))
    (with-temp-buffer
      (insert-file-contents file)
      ;; Include module-qualified names such as canonical input accessors;
      ;; checking only the facade prefix misses those boundary violations.
      (should-not (re-search-forward "\\_<ebox[-[:alnum:]]*--" nil t)))))

(ert-deftest etaf-examples-use-only-public-etaf-names ()
  "Keep executable examples on the public ETAF contract."
  (dolist (file
           (directory-files
            (expand-file-name "examples" etaf-docs-test--root)
            t "\\.el\\'"))
    (with-temp-buffer
      (insert-file-contents file)
      (should-not
       (re-search-forward (regexp-opt '("etaf--" "ebox--")) nil t)))))

;;; etaf-docs-tests.el ends here
