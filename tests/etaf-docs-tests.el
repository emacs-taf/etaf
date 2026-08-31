;;; etaf-docs-tests.el --- ETAF documentation contract tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'macroexp)
(require 'etaf)

(declare-function etaf-m0b-component-manifest-write-json
                  "etaf-m0b-component-manifest" ())

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

(ert-deftest etaf-docs-component-contract-is-current ()
  "Keep public Component prose aligned with the authoritative macro contract."
  (dolist (file '("docs/architecture.en.md" "docs/architecture.zh.md"
                  "docs/user-guide.en.md" "docs/user-guide.zh.md"
                  "docs/implementation-plan.en.md"
                  "docs/implementation-plan.zh.md"))
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
  (dolist (file '("docs/user-guide.en.md" "docs/user-guide.zh.md"))
    (let ((contents (etaf-docs-test--read file)))
      (should (string-match-p (regexp-quote ":row-selected-p") contents))
      (should-not (string-match-p (regexp-quote ":selected-key") contents)))))

(ert-deftest etaf-docs-superseded-proposals-not-current-contract ()
  "Keep the old Component proposal explicitly historical."
  (let ((contents
         (etaf-docs-test--read "docs/proposals/component-definition.zh.md")))
    (should (string-match-p "SUPERSEDED" contents))
    (should (string-match-p "historical" contents))
    (should (string-match-p (regexp-quote "docs/architecture.zh.md") contents))
    (should-not (string-match-p "尚未实现" contents))))

(ert-deftest etaf-docs-module-boundaries-target-vocabulary-is-paired ()
  "Keep the English and Chinese target Component vocabulary equivalent."
  (dolist (file '("docs/proposals/module-boundaries.en.md"
                  "docs/proposals/module-boundaries.zh.md"))
    (let ((contents (etaf-docs-test--read file)))
      (dolist (token '(":view" ":render" ":setup" "etaf-state" "etaf-node"
                       "opaque"))
        (should (string-match-p (regexp-quote token) contents))))))

(ert-deftest etaf-docs-interaction-contract-is-current ()
  "Keep the public Action/Behavior/event composition contract explicit."
  (dolist (file '("docs/architecture.en.md" "docs/architecture.zh.md"
                  "docs/user-guide.en.md" "docs/user-guide.zh.md"))
    (let ((contents (etaf-docs-test--read file)))
      (dolist (token '("Host" "Behavior" "short-circuit" "first"
                       "capture" "bubble" "application" "feature"
                       "etaf-action-redefine-run" "dispatch"))
        (should (string-match-p (regexp-quote token) contents))))))

(ert-deftest etaf-docs-component-manifest-is-machine-readable ()
  "Validate the three-column Component manifest and observed evidence."
  (let* ((script (expand-file-name "scripts/etaf-m0b-component-manifest.el"
                                   etaf-docs-test--root))
         (json-object-type 'alist)
         (json-array-type 'list)
         (manifest
          (with-temp-buffer
            (let ((standard-output (current-buffer)))
              (load script nil t)
              (etaf-m0b-component-manifest-write-json))
            (goto-char (point-min))
            (json-read))))
    (should (equal 1 (alist-get 'schema-version manifest)))
    (should (equal "observed" (alist-get 'evidence-mode manifest)))
    (dolist (entry (alist-get 'components manifest))
      (should (alist-get 'declared-business-props entry))
      (should (alist-get 'forwarded-host-attrs entry))
      (should (alist-get 'root-shape-forwarding-guarantee entry))
      (should (eq t (alist-get 'mounted-validation entry))))))

(ert-deftest etaf-docs-executable-suite-is-fail-closed ()
  "Classify exact blocks before macroexpansion, loading, or mounted smoke."
  (let ((fixture (expand-file-name
                  "tests/fixtures/etaf-m0b-doc-examples.sexp"
                  etaf-docs-test--root)))
    (should (file-readable-p fixture))
    (let ((records (with-temp-buffer
                     (insert-file-contents fixture)
                     (goto-char (point-min))
                     (read (current-buffer)))))
      (should records)
      (dolist (record records)
        (let* ((file (plist-get record :file))
               (index (plist-get record :block))
               (classification (plist-get record :classification))
               (blocks (etaf-docs-test--elisp-blocks
                        (etaf-docs-test--read file)))
               (source (nth (1- index) blocks)))
          (should source)
          (should (equal (secure-hash 'sha256 source)
                         (plist-get record :sha256)))
          (should (memq classification
                        '(macroexpand-only load-safe mounted-smoke)))
          (pcase classification
            ('macroexpand-only
             (should (> (etaf-docs-test--read-all source) 0)))
            ((or 'load-safe 'mounted-smoke)
             (let ((forms (etaf-docs-test--forms source)))
               (dolist (form forms)
                 (should (macroexpand-all (copy-tree form))))
               (pcase (plist-get record :probe)
                 ('collection-composition
                  (etaf-docs-test--mounted-collection-probe forms))
                 ('nil (dolist (form forms) (eval form t)))
                 (_ (ert-fail "Unknown safe documentation probe")))))))))))

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
