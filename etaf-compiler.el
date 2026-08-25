;;; etaf-compiler.el --- AOT View blueprints for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This is the first compiler slice: structured View topology and literal
;; values are emitted into an immutable blueprint during byte compilation.
;; Runtime instantiation constructs only nodes on paths containing dynamic
;; property holes.  Unsupported structural forms use the existing View
;; compiler unchanged.

;;; Code:

(require 'cl-lib)
(require 'etaf-view)

(defvar read-eval)

(defconst etaf-compiler-blueprint-abi "etaf-view-blueprint/1")
(defconst etaf-compiler-app-artifact-abi "etaf-app/3")

(define-error 'etaf-compiler-artifact-error "Invalid ETAF App artifact")
(define-error 'etaf-compiler-stale-artifact "Stale ETAF App artifact"
  'etaf-compiler-artifact-error)

(defvar etaf-compiler--static-cache (make-hash-table :test #'equal))
(defvar etaf-compiler--artifact-blueprints (make-hash-table :test #'equal))
(defvar etaf-compiler--artifact-blueprint-owners
  (make-hash-table :test #'equal))
(defvar etaf-compiler--active-artifacts (make-hash-table :test #'equal))
(defvar etaf-compiler--registry-epoch 0)
(defvar etaf-compiler--instantiate-count 0)
(defvar etaf-compiler--fallback-count 0)
(defvar etaf-compiler--last-blueprint nil)
(defvar etaf-compiler--artifact-hit-count 0)
(defvar etaf-compiler--artifact-miss-count 0)
(defvar etaf-compiler--last-artifact-status nil)

(defun etaf-compiler-deactivate-app-artifact (name)
  "Remove App NAME's active artifact and unowned blueprints."
  (when-let ((artifact (gethash name etaf-compiler--active-artifacts)))
    (dolist (entry (plist-get artifact :blueprints))
      (let* ((id (plist-get entry :id))
             (owners (delete name
                             (copy-sequence
                              (gethash id
                                       etaf-compiler--artifact-blueprint-owners)))))
        (if owners
            (puthash id owners etaf-compiler--artifact-blueprint-owners)
          (remhash id etaf-compiler--artifact-blueprint-owners)
          (remhash id etaf-compiler--artifact-blueprints))))
    (remhash name etaf-compiler--active-artifacts)))

(defun etaf-compiler-note-registry-change ()
  "Invalidate the static Component-call cache after a registry change."
  (cl-incf etaf-compiler--registry-epoch)
  (clrhash etaf-compiler--static-cache))

(defun etaf-compiler-clear-cache ()
  "Clear all process-local compiled View materializations."
  (interactive)
  (clrhash etaf-compiler--static-cache))

(defun etaf-compiler-note-artifact-miss (reason)
  "Record a rejected or unavailable App artifact REASON."
  (cl-incf etaf-compiler--artifact-miss-count)
  (setq etaf-compiler--last-artifact-status reason))

(defun etaf-compiler-statistics ()
  "Return a read-only snapshot of compiler runtime statistics."
  (list :abi etaf-compiler-blueprint-abi
        :instantiations etaf-compiler--instantiate-count
        :fallbacks etaf-compiler--fallback-count
        :artifact-hits etaf-compiler--artifact-hit-count
        :artifact-misses etaf-compiler--artifact-miss-count
        :last-artifact-status etaf-compiler--last-artifact-status
        :static-cache-entries (hash-table-count etaf-compiler--static-cache)
        :last-blueprint
        (and etaf-compiler--last-blueprint
             (list :id (plist-get etaf-compiler--last-blueprint :id)
                   :static-nodes
                   (plist-get etaf-compiler--last-blueprint :static-nodes)
                   :dynamic-nodes
                   (plist-get etaf-compiler--last-blueprint :dynamic-nodes)
                   :hole-count
                   (plist-get etaf-compiler--last-blueprint :hole-count)))
        :registry-epoch etaf-compiler--registry-epoch))

(defun etaf-compiler--read-forms (file)
  "Read every inert Lisp form from FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((read-eval nil) forms form done)
      (while (not done)
        (condition-case nil
            (progn (setq form (read (current-buffer))) (push form forms))
          (end-of-file (setq done t))))
      (nreverse forms))))

(defun etaf-compiler--read-single-form (file)
  "Read exactly one inert Lisp form from FILE."
  (let ((forms (etaf-compiler--read-forms file)))
    (unless (= (length forms) 1)
      (signal 'etaf-compiler-artifact-error
              (list :expected-one-form file (length forms))))
    (car forms)))

(defun etaf-compiler--collect-blueprints (form)
  "Return compiled blueprints found below source FORM."
  (let (blueprints)
    (cl-labels
        ((visit (value)
           (when (consp value)
             (cond
              ((memq (car value) '(quote function)) nil)
              ((and (memq (car value) '(etaf-view etaf-compiled-view))
                    (cadr value))
               (when-let* ((compiled (etaf-compiler--compile (cadr value)))
                           (blueprint (car compiled))
                           ((etaf-compiler--beneficial-blueprint-p blueprint)))
                 (push blueprint blueprints)))
              (t (visit (car value))
                 (visit (cdr value)))))))
      (visit form))
    (nreverse blueprints)))

(defun etaf-compiler--source-record (file)
  "Return the content hash record for FILE."
  (list :file (file-name-nondirectory file)
        :sha256 (with-temp-buffer
                  (insert-file-contents-literally file)
                  (secure-hash 'sha256 (current-buffer)))))

(defun etaf-compiler--write-artifact (artifact output)
  "Atomically write data-only ARTIFACT to OUTPUT."
  (let* ((directory (file-name-directory (expand-file-name output)))
         (_ (make-directory directory t))
         (temporary (make-temp-file (expand-file-name ".etafc-" directory))))
    (unwind-protect
        (progn
          (with-temp-file temporary
            (let ((print-circle nil) (print-length nil) (print-level nil))
              (prin1 artifact (current-buffer))
              (insert "\n")))
          (rename-file temporary output t)
          (setq temporary nil)
          output)
      (when (and temporary (file-exists-p temporary))
        (delete-file temporary)))))

;;;###autoload
(cl-defun etaf-compiler-write-app-artifact
    (&key name source static style output)
  "Compile one App into data-only OUTPUT.
NAME identifies the App.  SOURCE is its Elisp companion, STATIC its inert
`.etaf' input, and STYLE its optional `.ecss' input."
  (unless (and (stringp name) (file-readable-p source)
               (file-readable-p static) (stringp output))
    (signal 'wrong-type-argument
            (list 'etaf-app-source name source static output)))
  (let (blueprints)
    (dolist (form (etaf-compiler--read-forms source))
      (setq blueprints
            (append blueprints
                    (etaf-compiler--collect-blueprints form))))
    (setq blueprints
          (delete-dups blueprints))
    (let ((artifact
           (list :kind 'etaf/app-artifact
                 :abi etaf-compiler-app-artifact-abi
                 :app name
                 :sources
                 (delq nil
                       (list (etaf-compiler--source-record source)
                             (etaf-compiler--source-record static)
                             (and style (etaf-compiler--source-record style))))
                 :static-form (etaf-compiler--read-single-form static)
                 :style-form (and style
                                  (etaf-compiler--read-single-form style))
                 :blueprints
                 (mapcar (lambda (blueprint)
                           (list :id (plist-get blueprint :id)
                                 :blueprint blueprint))
                         blueprints))))
      (etaf-compiler--write-artifact artifact output))))

(defun etaf-compiler--validate-source-records (artifact base-directory)
  "Signal when ARTIFACT does not match BASE-DIRECTORY."
  (dolist (record (plist-get artifact :sources))
    (let ((file (expand-file-name (plist-get record :file) base-directory)))
      (unless (and (file-readable-p file)
                   (equal (with-temp-buffer
                            (insert-file-contents-literally file)
                            (secure-hash 'sha256 (current-buffer)))
                          (plist-get record :sha256)))
        (signal 'etaf-compiler-stale-artifact
                (list :source file))))))

;;;###autoload
(defun etaf-load-app-artifact (file base-directory)
  "Load FILE after validating it against BASE-DIRECTORY."
  (let ((artifact (etaf-compiler--read-single-form file)))
    (unless (and (eq (plist-get artifact :kind) 'etaf/app-artifact)
                 (equal (plist-get artifact :abi)
                        etaf-compiler-app-artifact-abi)
                 (stringp (plist-get artifact :app)))
      (signal 'etaf-compiler-artifact-error (list :manifest file)))
    (etaf-compiler--validate-source-records artifact base-directory)
    (etaf-compiler-deactivate-app-artifact (plist-get artifact :app))
    (dolist (entry (plist-get artifact :blueprints))
      (let ((blueprint (plist-get entry :blueprint)))
        (unless (and (equal (plist-get entry :id) (plist-get blueprint :id))
                     (equal (plist-get blueprint :abi)
                            etaf-compiler-blueprint-abi))
          (signal 'etaf-compiler-artifact-error
                  (list :blueprint entry)))
        (puthash (plist-get entry :id) blueprint
                 etaf-compiler--artifact-blueprints)
        (cl-pushnew (plist-get artifact :app)
                    (gethash (plist-get entry :id)
                             etaf-compiler--artifact-blueprint-owners)
                    :test #'equal)))
    (puthash (plist-get artifact :app) artifact
             etaf-compiler--active-artifacts)
    (setq etaf-compiler--last-artifact-status 'loaded)
    artifact))

(defun etaf-compiler--literal (form)
  "Return `(t . VALUE)' when FORM is a portable literal, otherwise nil."
  (cond
   ((or (null form) (eq form t) (numberp form) (stringp form)
        (characterp form) (keywordp form))
    (cons t form))
   ((and (consp form) (eq (car form) 'quote) (null (cddr form)))
    (cons t (cadr form)))
   (t nil)))

(defun etaf-compiler--compile-property (form programs)
  "Compile property FORM, returning `(DESCRIPTOR . PROGRAMS)'."
  (if-let ((literal (etaf-compiler--literal form)))
      (cons (list :kind 'static :value (cdr literal)) programs)
    (let ((index (length programs)))
      (cons (list :kind 'hole :index index)
            (append programs (list `(lambda () ,form)))))))

(defun etaf-compiler--compile-block (form path programs)
  "Compile View FORM at PATH, returning `(BLOCK PROGRAMS)' or nil."
  (cond
   ((or (null form) (stringp form))
    (list (list :kind 'literal :value form :path path :static-p t) programs))
   ((not (and (consp form) (symbolp (car form)))) nil)
   ((eq (car form) 'expr)
    (let ((index (length programs)))
      (list (list :kind 'expr :path path :hole index :static-p nil)
            (append programs
                    (list `(lambda () ,(etaf--parse-expr-form (cdr form))))))))
   ((memq (car form) '(slot raw-ebox)) nil)
   ((etaf--ordinary-expression-head-p (car form)) nil)
   (t
    (let* ((parts (etaf--parse-attributes-and-children (cdr form)))
           (props (car parts))
           (children (cdr parts))
           (compiled-props nil)
           (compiled-children nil)
           (all-static t)
           (tail props)
           (child-index 0)
           result)
      (while tail
        (let* ((key (pop tail))
               (value (pop tail))
               (compiled (etaf-compiler--compile-property value programs))
               (descriptor (car compiled)))
          (setq programs (cdr compiled))
          (unless (eq (plist-get descriptor :kind) 'static)
            (setq all-static nil))
          (setq compiled-props
                (append compiled-props (list key descriptor)))))
      (while (and children (not (eq result 'unsupported)))
        (let ((compiled
               (etaf-compiler--compile-block
                (pop children) (append path (list child-index)) programs)))
          (if (not compiled)
              (setq result 'unsupported)
            (let ((block (car compiled)))
              (setq programs (cadr compiled)
                    compiled-children (append compiled-children (list block)))
              (unless (plist-get block :static-p) (setq all-static nil)))))
        (cl-incf child-index))
      (unless (eq result 'unsupported)
        (list (list :kind 'node :name (car form) :path path
                    :props compiled-props :children compiled-children
                    :static-p all-static)
              programs))))))

(defun etaf-compiler--block-counts (block)
  "Return `(STATIC . DYNAMIC)' node counts below BLOCK."
  (if (eq (plist-get block :kind) 'literal)
      (cons 0 0)
    (let ((static (if (plist-get block :static-p) 1 0))
          (dynamic (if (plist-get block :static-p) 0 1)))
      (dolist (child (plist-get block :children))
        (pcase-let ((`(,child-static . ,child-dynamic)
                     (etaf-compiler--block-counts child)))
          (cl-incf static child-static)
          (cl-incf dynamic child-dynamic)))
      (cons static dynamic))))

(defun etaf-compiler--beneficial-blueprint-p (blueprint)
  "Return non-nil when BLUEPRINT can reuse at least one static node."
  (> (or (plist-get blueprint :static-nodes) 0) 0))

(defun etaf-compiler--compile (form)
  "Compile FORM into `(BLUEPRINT PROGRAM-CODE...)', or return nil."
  (when-let ((compiled (etaf-compiler--compile-block form '(0) nil)))
    (let* ((root (car compiled))
           (programs (cadr compiled))
           (id (secure-hash 'sha256 (prin1-to-string form)))
           (counts (etaf-compiler--block-counts root)))
      (cons (list :kind 'etaf/view-blueprint
                  :abi etaf-compiler-blueprint-abi
                  :id id :root root
                  :static-nodes (car counts)
                  :dynamic-nodes (cdr counts)
                  :hole-count (length programs))
            programs))))

(defun etaf-compiler--materialize (blueprint block programs)
  "Materialize BLOCK from BLUEPRINT using PROGRAMS."
  (let* ((static-p (plist-get block :static-p))
         (cache-key (and static-p
                         (list (plist-get blueprint :id)
                               (plist-get block :path)
                               etaf-compiler--registry-epoch)))
         (missing (make-symbol "etaf-compiled-missing"))
         (cached (and cache-key
                      (gethash cache-key etaf-compiler--static-cache missing))))
    (if (and cache-key (not (eq cached missing)))
        cached
      (let ((value
             (pcase (plist-get block :kind)
               ('literal (plist-get block :value))
               ('expr
                (etaf--expr-create
                 :token (list 'etaf-compiled-site
                              (plist-get blueprint :id)
                              (plist-get block :path))
                 :thunk (aref programs (plist-get block :hole))))
               ('node
                (let ((props nil))
                  (cl-loop for (key descriptor) on (plist-get block :props)
                           by #'cddr
                           do (setq props
                                   (append
                                    props
                                    (list
                                     key
                                     (if (eq (plist-get descriptor :kind)
                                             'static)
                                         (plist-get descriptor :value)
                                       (etaf--expr-create
                                        :thunk
                                        (aref programs
                                              (plist-get descriptor
                                                         :index))))))))
                  (etaf--view-call
                   (plist-get block :name) props
                   (mapcar (lambda (child)
                             (etaf-compiler--materialize
                              blueprint child programs))
                           (plist-get block :children))
                   (list 'etaf-compiled-site
                         (plist-get blueprint :id)
                         (plist-get block :path)))))
               (_ (error "Unknown ETAF compiled block: %S" block)))))
        (when cache-key
          (puthash cache-key value etaf-compiler--static-cache))
        value))))

;;;###autoload
(defun etaf-compiler-instantiate (blueprint programs)
  "Instantiate compiled View BLUEPRINT with dynamic PROGRAMS."
  (unless (and (eq (plist-get blueprint :kind) 'etaf/view-blueprint)
               (equal (plist-get blueprint :abi)
                      etaf-compiler-blueprint-abi)
               (stringp (plist-get blueprint :id))
               (vectorp programs)
               (= (length programs) (plist-get blueprint :hole-count)))
    (error "Invalid or incompatible ETAF View blueprint"))
  (let ((artifact-blueprint
         (gethash (plist-get blueprint :id)
                  etaf-compiler--artifact-blueprints)))
    (if artifact-blueprint
        (progn
          (cl-incf etaf-compiler--artifact-hit-count)
          (setq etaf-compiler--last-artifact-status 'hit
                blueprint artifact-blueprint))
      (cl-incf etaf-compiler--artifact-miss-count)
      (setq etaf-compiler--last-artifact-status 'embedded-fallback))
    (cl-incf etaf-compiler--instantiate-count)
    (setq etaf-compiler--last-blueprint blueprint)
    (etaf-compiler--materialize
     blueprint (plist-get blueprint :root) programs)))

(defun etaf-compiler-expand-view
    (form &optional slot-mode artifact-required count-fallback)
  "Return compiler expansion for View FORM.
SLOT-MODE is forwarded to the legacy compiler.  ARTIFACT-REQUIRED keeps the
legacy path unless a manually loaded artifact contains the blueprint.
COUNT-FALLBACK records an unsupported explicit compiler request."
  (let* ((compiled (etaf-compiler--compile form))
         (blueprint (car compiled))
         (legacy (etaf--compile-view-form form (or slot-mode :projection))))
    (if (and compiled (etaf-compiler--beneficial-blueprint-p blueprint))
        (let ((instantiate
               `(etaf-compiler-instantiate
                 ',blueprint (vector ,@(cdr compiled)))))
          (if artifact-required
              `(if (gethash ,(plist-get blueprint :id)
                            etaf-compiler--artifact-blueprints)
                   ,instantiate
                 ,legacy)
            instantiate))
      (if count-fallback
          `(progn (cl-incf etaf-compiler--fallback-count) ,legacy)
        legacy))))

;;;###autoload
(defmacro etaf-compiled-view (form)
  "Compatibility spelling for explicitly compiled View FORM."
  (declare (indent 1) (debug (form)))
  (etaf-compiler-expand-view form :projection nil t))

(provide 'etaf-compiler)
;;; etaf-compiler.el ends here
