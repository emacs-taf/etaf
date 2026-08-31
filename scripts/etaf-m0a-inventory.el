;;; etaf-m0a-inventory.el --- M0a current-contract inventory -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This is a read-only M0a inventory surface.  It records current contracts,
;; known pre-activation baselines, and the condition handlers present in ETAF
;; source files.  It intentionally does not turn future architecture targets
;; into passing assertions.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'json)
(require 'macroexp)

(defconst etaf-m0a-package-root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Absolute ETAF package root inferred when this inventory is loaded.")

(defconst etaf-m0a-current-contract-inventory
  '((:id component-definition
     :evidence-mode current-contract
     :summary ":view or :render is required; :setup/:styles are optional"
     :tests (etaf-component-frontends-definition-boundary-is-strict
             etaf-component-definition-keywords-have-one-owner))
    (:id host-attrs
     :evidence-mode current-contract
     :summary "undeclared Host attrs fall through a single-root Component chain"
     :tests (etaf-component-host-attrs-fall-through-one-root-chain
             etaf-component-host-attrs-reject-ambiguous-or-invalid-targets
             etaf-component-host-attrs-rollback-root-shape-failure))
    (:id slots-key-lifecycle-rollback
     :evidence-mode current-contract
     :summary "slots retain caller ownership; key is framework-owned; lifecycle and rollback are ordered"
     :tests (etaf-component-frontends-project-default-and-named-slots
             etaf-component-key-is-framework-owned-and-render-result-is-typed
             etaf-component-lifecycle-and-scope-cleanup-are-ordered
             etaf-component-render-side-effect-rolls-back-completely))
    (:id action-registration
     :evidence-mode observed-baseline
     :activation-milestone M0b
     :owner etaf-actions
     :summary "registering an existing Action name replaces the current spec"
     :tests (etaf-m0a-action-registration-replaces-current-definition))
    (:id behavior-duplicates
     :evidence-mode observed-baseline
     :activation-milestone M0b
     :owner etaf-runtime
     :summary "same-name Behaviors are currently processed in declaration order; no pre-install duplicate gate exists"
     :tests (etaf-runtime-composes-host-and-behavior-events-in-order
             etaf-behavior-replacement-disposes-previous-installer))
    (:id event-rules
     :evidence-mode current-contract
     :summary "event names normalize keyword/symbol/string on-* spellings; Host callback precedes Behavior callback"
     :tests (etaf-m0a-event-kind-normalizes-current-spellings
             etaf-runtime-composes-host-and-behavior-events-in-order))
    (:id dependency-only-publication
     :evidence-mode current-contract
     :summary "semantic generation advances without Ebox commit or TP surface revision"
     :tests (etaf-m0a-dependency-only-skips-ebox-and-tp-publication))
    (:id initial-attach
     :evidence-mode current-contract
     :summary "initial observed publication reports TP, Ebox, then ETAF"
     :tests (etaf-runtime-observer-covers-initial-publication))
    (:id unmount-kill
     :evidence-mode current-contract
     :summary "unmount disposes lifecycle before scope cleanup; kill follows unmount; repeated public unmount signals"
     :tests (etaf-component-lifecycle-and-scope-cleanup-are-ordered
             etaf-runtime-killed-buffer-unmounts-owned-scope
             etaf-m0a-repeated-public-unmount-signals-runtime-error))
    (:id condition-trailer
     :evidence-mode current-contract
     :activation-milestone M3a
     :owner etaf-runtime
     :summary "postcommit errors preserve the raw condition symbol/data prefix and append the v1 committed trailer"
     :tests (etaf-m0a-public-update-preserves-raw-condition-symbol-and-data))
    (:id document-examples
     :evidence-mode observed-baseline
     :activation-milestone M0b
     :owner etaf-documentation
     :summary "all user-facing fenced Elisp blocks have reviewed read, macroexpand, load-safety, and drift outcomes"
     :tests (etaf-m0a-document-example-inventory-matches-reviewed-golden)))
  "Machine-readable M0a ledger for ETAF current behavior and future gates.")

(defconst etaf-m0a-document-example-files
  '("README.md"
    "README.zh-CN.md"
    "examples/README.md"
    "examples/README.zh-CN.md"
    "docs/architecture.en.md"
    "docs/architecture.zh.md"
    "docs/user-guide.en.md"
    "docs/user-guide.zh.md"
    "docs/implementation-plan.en.md"
    "docs/implementation-plan.zh.md")
  "User-facing documents whose fenced Elisp blocks belong to M0a inventory.")

(defun etaf-m0a--condition-handler-symbols (clause)
  "Return the condition symbols handled by `condition-case' CLAUSE."
  (let ((head (car-safe clause)))
    (cond
     ((symbolp head) (list head))
     ((proper-list-p head) (cl-remove-if-not #'symbolp head))
     (t nil))))

(defun etaf-m0a--condition-policy (conditions)
  "Return the current handling policy for CONDITIONS."
  (if (cl-every (lambda (condition) (memq condition '(error quit))) conditions)
      'generic-containment
    'specific-compatibility))

(defun etaf-m0a--walk-condition-consumers (form file line)
  "Return condition consumer records below FORM from FILE at LINE."
  (let (records)
    (when (consp form)
      (unless (memq (car form) '(quote function))
        (when (memq (car form) '(condition-case condition-case-unless-debug))
          (dolist (clause (cdddr form))
            (let ((conditions (etaf-m0a--condition-handler-symbols clause)))
              (when conditions
                (push (list :file file :line line :form (car form)
                            :conditions conditions
                            :owner (intern (file-name-base file))
                            :policy (etaf-m0a--condition-policy conditions))
                      records)))))
        (setq records
              (nconc records
                     (etaf-m0a--walk-condition-consumers
                      (car form) file line)
                     (etaf-m0a--walk-condition-consumers
                      (cdr form) file line)))))
    records))

(defun etaf-m0a-condition-consumer-inventory (&optional directory)
  "Return condition consumers in top-level ETAF sources under DIRECTORY.

DIRECTORY defaults to the package root inferred from this script.  Test and
example files are excluded so this inventory describes product consumers."
  (let* ((root (file-name-as-directory
                (expand-file-name
                 (or directory etaf-m0a-package-root))))
         (files (sort (directory-files root t "\\`etaf-.*\\.el\\'")
                      #'string<))
         records)
    (dolist (file files)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (condition-case nil
            (while t
              (let ((line (line-number-at-pos))
                    (form (read (current-buffer))))
                (setq records
                      (nconc records
                             (etaf-m0a--walk-condition-consumers
                              form (file-relative-name file root) line)))))
          (end-of-file nil))))
    (sort records
          (lambda (left right)
            (or (string< (plist-get left :file) (plist-get right :file))
                (and (equal (plist-get left :file) (plist-get right :file))
                     (< (plist-get left :line) (plist-get right :line))))))))

(defun etaf-m0a-condition-consumer-signatures (&optional directory)
  "Return stable golden signatures for source consumers under DIRECTORY.

Line numbers remain available in the diagnostic inventory but are excluded
from this signature so unrelated line movement does not rewrite the golden."
  (mapcar
   (lambda (entry)
     (list :file (plist-get entry :file)
           :form (plist-get entry :form)
           :conditions (plist-get entry :conditions)
           :owner (plist-get entry :owner)
           :policy (plist-get entry :policy)))
   (etaf-m0a-condition-consumer-inventory directory)))

(defun etaf-m0a--document-elisp-blocks (file root)
  "Return fenced Elisp blocks from FILE below ROOT."
  (with-temp-buffer
    (insert-file-contents (expand-file-name file root))
    (goto-char (point-min))
    (let ((index 0) blocks)
      (while (re-search-forward "^```elisp[[:space:]]*$" nil t)
        (let ((line (line-number-at-pos))
              (start (line-beginning-position 2)))
          (unless (re-search-forward "^```[[:space:]]*$" nil t)
            (error "Unclosed Elisp block in %s" file))
          (cl-incf index)
          (push (list :index index :line line
                      :source (buffer-substring-no-properties
                               start (match-beginning 0)))
                blocks)))
      (nreverse blocks))))

(defun etaf-m0a--read-document-forms (source)
  "Read all forms from documentation SOURCE and return a result plist."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert source)
    (goto-char (point-min))
    (let (forms failure)
      (condition-case condition
          (while (progn
                   (skip-chars-forward " \t\r\n")
                   (< (point) (point-max)))
            (push (read (current-buffer)) forms))
        (error (setq failure (car condition))))
      (if failure
          (list :status 'error :detail failure :forms nil)
        (list :status 'ok :detail (length forms) :forms (nreverse forms))))))

(defun etaf-m0a--macroexpand-document-forms (forms)
  "Macroexpand FORMS and return a stable outcome plist."
  (condition-case condition
      (progn
        (mapc #'macroexpand-all forms)
        (list :status 'ok :detail (length forms)))
    (error (list :status 'error :detail (car condition)))))

(defun etaf-m0a-document-example-inventory (&optional directory)
  "Return current read/macroexpand/load outcomes for user documentation.

DIRECTORY defaults to `etaf-m0a-package-root'.
Arbitrary documentation code is never evaluated in the agent process: it may
mount buffers, mutate files, start async work, or depend on user state.  Every
block therefore has an explicit skipped load outcome and safety reason."
  (let ((root (file-name-as-directory
               (expand-file-name (or directory etaf-m0a-package-root)))))
    (mapcar
     (lambda (file)
       (list
        :file file
        :blocks
        (mapcar
         (lambda (block)
           (let* ((source (plist-get block :source))
                  (read-result (etaf-m0a--read-document-forms source))
                  (macro-result
                   (if (eq 'ok (plist-get read-result :status))
                       (etaf-m0a--macroexpand-document-forms
                        (plist-get read-result :forms))
                     (list :status 'skipped :detail 'read-failed)))
                  (drift
                   (cond
                    ((eq 'error (plist-get read-result :status)) 'read-error)
                    ((eq 'error (plist-get macro-result :status))
                     'macroexpand-error)
                    (t 'none))))
             (list :index (plist-get block :index)
                   :line (plist-get block :line)
                   :sha256 (secure-hash 'sha256 source)
                   :read-status (plist-get read-result :status)
                   :read-detail (plist-get read-result :detail)
                   :macroexpand-status (plist-get macro-result :status)
                   :macroexpand-detail (plist-get macro-result :detail)
                   :load-status 'skipped-unsafe
                   :load-reason 'arbitrary-document-code
                   :drift drift)))
         (etaf-m0a--document-elisp-blocks file root))))
     etaf-m0a-document-example-files)))

(defun etaf-m0a-document-example-signatures (&optional directory)
  "Return stable golden signatures for documentation under DIRECTORY."
  (mapcar
   (lambda (file-entry)
     (list
      :file (plist-get file-entry :file)
      :blocks
      (mapcar
       (lambda (block)
         (list (plist-get block :index)
               (plist-get block :sha256)
               (plist-get block :read-status)
               (plist-get block :read-detail)
               (plist-get block :macroexpand-status)
               (plist-get block :macroexpand-detail)
               (plist-get block :load-status)
               (plist-get block :load-reason)
               (plist-get block :drift)))
       (plist-get file-entry :blocks))))
   (etaf-m0a-document-example-inventory directory)))

(defun etaf-m0a-inventory-json (&optional directory)
  "Return the current M0a ledger and condition inventory as JSON.

DIRECTORY is forwarded to `etaf-m0a-condition-consumer-inventory'."
  (json-encode
   (list :schema-version 1
         :contract-inventory (vconcat etaf-m0a-current-contract-inventory)
         :condition-consumers
         (vconcat (etaf-m0a-condition-consumer-inventory directory))
         :document-examples
         (vconcat
          (mapcar
           (lambda (entry)
             (let ((copy (copy-sequence entry)))
               (plist-put copy :blocks
                          (vconcat (plist-get copy :blocks)))))
           (etaf-m0a-document-example-inventory directory))))))

(when noninteractive
  (when (member "--etaf-m0a-print-inventory" command-line-args-left)
    (setq command-line-args-left
          (delete "--etaf-m0a-print-inventory" command-line-args-left))
    (princ (etaf-m0a-inventory-json))
    (terpri)))

(provide 'etaf-m0a-inventory)
;;; etaf-m0a-inventory.el ends here
