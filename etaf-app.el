;;; etaf-app.el --- ETAF App registry and compile workflow -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This module owns the user-facing App boundary.  The compiler remains a pure
;; engine; hosts such as etaf-playground register source manifests here and use
;; the same compile/status/fallback workflow as any other ETAF application.

;;; Code:

(require 'cl-lib)
(require 'etaf-compiler)

(cl-defstruct (etaf-app-spec (:constructor etaf-app--spec-create))
  name source-file static-file style-file artifact-file)

(defvar etaf-app--registry (make-hash-table :test #'equal))
(defvar etaf-app--warning-state (make-hash-table :test #'equal))
(defvar etaf-app--status-cache (make-hash-table :test #'equal))

(declare-function ebox-native-reflow-load "ebox-native-reflow" ())
(declare-function ebox-native-reflow-layout-ready-p "ebox-native-reflow" ())

(defun etaf-app--prepare-runtime-accelerator ()
  "Load the optional compiled Ebox runtime and return its status."
  (if (not (require 'ebox-native-reflow nil t))
      'unavailable
    (condition-case _error
        (progn
          (ebox-native-reflow-load)
          (if (ebox-native-reflow-layout-ready-p) 'ready 'unavailable))
      (error 'unavailable))))

(defcustom etaf-app-warn-on-artifact-fallback t
  "Whether running an uncompiled or stale App emits a warning."
  :type 'boolean
  :group 'etaf)

;;;###autoload
(cl-defun etaf-register-app
    (name &key source static style artifact)
  "Register App NAME and its SOURCE, STATIC, STYLE, and ARTIFACT files."
  (setq name (if (symbolp name) (symbol-name name) name))
  (unless (and (stringp name) (stringp source) (stringp static)
               (stringp artifact))
    (signal 'wrong-type-argument
            (list 'etaf-app-manifest name source static style artifact)))
  (let ((spec (etaf-app--spec-create
               :name name
               :source-file (expand-file-name source)
               :static-file (expand-file-name static)
               :style-file (and style (expand-file-name style))
               :artifact-file (expand-file-name artifact))))
    (unless (equal spec (gethash name etaf-app--registry))
      (remhash name etaf-app--status-cache))
    (puthash name spec etaf-app--registry)
    spec))

(defun etaf-app-names ()
  "Return registered App names in stable order."
  (let (names)
    (maphash (lambda (name _spec) (push name names)) etaf-app--registry)
    (sort names #'string<)))

(defun etaf-app-spec (name)
  "Return registered App NAME or signal a user error."
  (setq name (if (symbolp name) (symbol-name name) name))
  (or (gethash name etaf-app--registry)
      (user-error "Unknown ETAF App: %s" name)))

(defun etaf-app--interactive-name (prompt)
  "Read a registered App name using PROMPT."
  (let ((names (etaf-app-names)))
    (unless names (user-error "No ETAF Apps are registered"))
    (completing-read prompt names nil t nil nil (car names))))

(defun etaf-app--file-fingerprint (file)
  "Return a cheap invalidation fingerprint for FILE."
  (when-let ((attributes (and file (file-attributes file 'string))))
    (list file
          (file-attribute-size attributes)
          (file-attribute-modification-time attributes)
          (file-attribute-inode-number attributes))))

(defun etaf-app--spec-fingerprint (spec)
  "Return source/artifact invalidation facts for SPEC."
  (mapcar #'etaf-app--file-fingerprint
          (list (etaf-app-spec-source-file spec)
                (etaf-app-spec-static-file spec)
                (etaf-app-spec-style-file spec)
                (etaf-app-spec-artifact-file spec))))

(defun etaf-app--status (name &optional use-cache)
  "Return App NAME's compilation status plist.
USE-CACHE reuses a fully validated result while file fingerprints are stable."
  (let* ((spec (etaf-app-spec name))
         (file (etaf-app-spec-artifact-file spec))
         (fingerprint (etaf-app--spec-fingerprint spec))
         (cached (and use-cache (gethash name etaf-app--status-cache)))
         (source-directory
          (file-name-directory (etaf-app-spec-source-file spec))))
    (if (and cached (equal fingerprint (car cached)))
        (cdr cached)
      (let ((status
             (if (not (file-readable-p file))
                 (list :app (etaf-app-spec-name spec)
                       :status 'missing :file file)
               (condition-case err
                   (let ((artifact
                          (etaf-load-app-artifact file source-directory)))
                     (list :app (etaf-app-spec-name spec)
                           :status 'current :file file
                           :blueprints
                           (length (plist-get artifact :blueprints))
                           :artifact artifact))
                 (etaf-compiler-stale-artifact
                  (list :app (etaf-app-spec-name spec) :status 'stale
                        :file file :error err))
                 (etaf-compiler-artifact-error
                  (list :app (etaf-app-spec-name spec) :status 'invalid
                        :file file :error err))
                 (error
                  (list :app (etaf-app-spec-name spec) :status 'invalid
                        :file file :error err))))))
        (puthash name (cons fingerprint status) etaf-app--status-cache)
        (unless (eq (plist-get status :status) 'current)
          (etaf-compiler-deactivate-app-artifact name))
        status))))

;;;###autoload
(defun etaf-app-compile-status (&optional name)
  "Show and return compilation status for App NAME."
  (interactive (list (etaf-app--interactive-name "ETAF App status: ")))
  (setq name (or name (car (etaf-app-names))))
  (let* ((status (etaf-app--status name))
         (state (plist-get status :status))
         (detail
          (pcase state
            ('current (format "compiled, current, %d blueprints"
                              (plist-get status :blueprints)))
            ('missing "not compiled")
            ('stale "compiled artifact is stale")
            (_ "compiled artifact is invalid"))))
    (when (called-interactively-p 'interactive)
      (message "ETAF App %s: %s (%s)"
               name detail (plist-get status :file)))
    status))

;;;###autoload
(defun etaf-compile-app (&optional name)
  "Compile registered App NAME into its standalone `.etafc' artifact."
  (interactive (list (etaf-app--interactive-name "Compile ETAF App: ")))
  (setq name (or name (car (etaf-app-names))))
  (let* ((spec (etaf-app-spec name))
         (output (etaf-app-spec-artifact-file spec)))
    (etaf-compiler-write-app-artifact
     :name (etaf-app-spec-name spec)
     :source (etaf-app-spec-source-file spec)
     :static (etaf-app-spec-static-file spec)
     :style (etaf-app-spec-style-file spec)
     :output output)
    (remhash name etaf-app--warning-state)
    (remhash name etaf-app--status-cache)
    (let ((status (etaf-app--status name)))
      (unless (eq (plist-get status :status) 'current)
        (error "ETAF App compilation produced an unusable artifact: %S"
               status))
      (when (called-interactively-p 'interactive)
        (message "Compiled ETAF App %s: %s (%d blueprints)"
                 name output (plist-get status :blueprints)))
      (setq status
            (plist-put (copy-sequence status) :runtime-accelerator
                       (etaf-app--prepare-runtime-accelerator)))
      status)))

(defun etaf-app--warn-fallback (name status)
  "Warn once that App NAME is using source fallback because of STATUS."
  (when (and etaf-app-warn-on-artifact-fallback
             (not noninteractive)
             (not (eq (gethash name etaf-app--warning-state) status)))
    (puthash name status etaf-app--warning-state)
    (display-warning
     'etaf
     (format (concat "ETAF App %s is %s; running the slower source fallback. "
                     "Run M-x etaf-compile-app.")
             name status)
     :warning)))

(defun etaf-app-load-artifact-or-warn (name)
  "Return App NAME's current artifact, or warn and return nil."
  (let* ((status (etaf-app--status name t))
         (state (plist-get status :status)))
    (if (eq state 'current)
        (progn
          (etaf-app--prepare-runtime-accelerator)
          (plist-get status :artifact))
      (etaf-compiler-note-artifact-miss state)
      (etaf-app--warn-fallback name state)
      nil)))

(provide 'etaf-app)
;;; etaf-app.el ends here
