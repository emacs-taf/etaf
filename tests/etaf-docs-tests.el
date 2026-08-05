;;; etaf-docs-tests.el --- ETAF documentation contract tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cl-lib)

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
                                                 (line-beginning-position))
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

(ert-deftest etaf-docs-have-paired-long-lived-files ()
  "Keep the public architecture, guide, and plan in both languages."
  (dolist (file '("README.md"
                  "README.zh-CN.md"
                  "DESIGN.md"
                  "DESIGN.zh-CN.md"
                  "examples/README.md"
                  "examples/README.zh-CN.md"
                  "docs/architecture.en.md"
                  "docs/architecture.zh.md"
                  "docs/user-guide.en.md"
                  "docs/user-guide.zh.md"
                  "docs/implementation-plan.en.md"
                  "docs/implementation-plan.zh.md"
                  "postmortem/2026-08-05-executable-core-examples.en.md"
                  "postmortem/2026-08-05-executable-core-examples.zh.md"))
    (should (file-exists-p (expand-file-name file etaf-docs-test--root)))))

(ert-deftest etaf-docs-user-surface-has-one-current-vocabulary ()
  "Reject old public entry names and stale View examples in user docs."
  (dolist (file '("README.md" "README.zh-CN.md"
                  "examples/README.md" "examples/README.zh-CN.md"
                  "docs/architecture.en.md" "docs/architecture.zh.md"
                  "docs/user-guide.en.md" "docs/user-guide.zh.md"
                  "docs/implementation-plan.en.md"
                  "docs/implementation-plan.zh.md"))
    (let ((contents (etaf-docs-test--read file)))
      (should-not
       (string-match-p
        (regexp-opt '("etaf-template" "etaf-create-app")) contents))
      (should-not (string-match-p "(text \"[^\"]+\" :" contents))))
  (let ((guide (etaf-docs-test--read "docs/user-guide.en.md")))
    (dolist (token '("etaf-view" "etaf-mount" "etaf-define-component"
                     "etaf-data-grid" "etaf-resource"))
      (should (string-match-p (regexp-quote token) guide)))))

(ert-deftest etaf-docs-elisp-examples-are-readable ()
  "Keep fenced Elisp examples syntactically readable by Emacs."
  (dolist (file '("README.md" "README.zh-CN.md"
                  "examples/README.md" "examples/README.zh-CN.md"
                  "docs/architecture.en.md" "docs/architecture.zh.md"
                  "docs/user-guide.en.md" "docs/user-guide.zh.md"
                  "docs/implementation-plan.en.md"
                  "docs/implementation-plan.zh.md"))
    (dolist (block (etaf-docs-test--elisp-blocks
                    (etaf-docs-test--read file)))
      (should (> (etaf-docs-test--read-all block) 0)))))

(ert-deftest etaf-source-uses-only-public-ebox-names ()
  "Keep the ETAF implementation independent of Ebox private functions."
  (dolist (file
           (append
            (directory-files etaf-docs-test--root t "\\.el\\'")
            (directory-files
             (expand-file-name "examples" etaf-docs-test--root)
             t "\\.el\\'")))
    (with-temp-buffer
      (insert-file-contents file)
      (should-not (re-search-forward "ebox--" nil t)))))

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
