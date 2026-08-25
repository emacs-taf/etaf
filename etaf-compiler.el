;;; etaf-compiler.el --- Automatic View blueprint lowering -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `etaf-view' lowers supported structured topology into an embedded blueprint
;; as part of ordinary macro expansion.  Runtime instantiation constructs only
;; nodes on paths containing dynamic property holes.  Unsupported structural
;; forms use the existing View expansion unchanged.  There is no standalone
;; App artifact or user-managed precompilation workflow.

;;; Code:

(require 'cl-lib)
(require 'etaf-view)

(defconst etaf-compiler-blueprint-abi "etaf-view-blueprint/1")

(defvar etaf-compiler--static-cache (make-hash-table :test #'equal))
(defvar etaf-compiler--registry-epoch 0)
(defvar etaf-compiler--instantiate-count 0)
(defvar etaf-compiler--fallback-count 0)
(defvar etaf-compiler--last-blueprint nil)

(defun etaf-compiler-note-registry-change ()
  "Invalidate the static Component-call cache after a registry change."
  (cl-incf etaf-compiler--registry-epoch)
  (clrhash etaf-compiler--static-cache))

(defun etaf-compiler-clear-cache ()
  "Clear all process-local compiled View materializations."
  (interactive)
  (clrhash etaf-compiler--static-cache))

(defun etaf-compiler-statistics ()
  "Return a read-only snapshot of compiler runtime statistics."
  (list :abi etaf-compiler-blueprint-abi
        :instantiations etaf-compiler--instantiate-count
        :fallbacks etaf-compiler--fallback-count
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
  (if-let* ((literal (etaf-compiler--literal form)))
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
  (when-let* ((compiled (etaf-compiler--compile-block form '(0) nil)))
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
  "Instantiate automatically lowered View BLUEPRINT with dynamic PROGRAMS."
  (unless (and (eq (plist-get blueprint :kind) 'etaf/view-blueprint)
               (equal (plist-get blueprint :abi)
                      etaf-compiler-blueprint-abi)
               (stringp (plist-get blueprint :id))
               (vectorp programs)
               (= (length programs) (plist-get blueprint :hole-count)))
    (error "Invalid or incompatible ETAF View blueprint"))
  (cl-incf etaf-compiler--instantiate-count)
  (setq etaf-compiler--last-blueprint blueprint)
  (etaf-compiler--materialize
   blueprint (plist-get blueprint :root) programs))

(defun etaf-compiler-expand-view (form &optional slot-mode)
  "Return compiler expansion for View FORM.
SLOT-MODE is forwarded to the legacy compiler."
  (let* ((compiled (etaf-compiler--compile form))
         (blueprint (car compiled))
         (legacy (etaf--compile-view-form form (or slot-mode :projection))))
    (if (and compiled (etaf-compiler--beneficial-blueprint-p blueprint))
        `(etaf-compiler-instantiate
          ',blueprint (vector ,@(cdr compiled)))
      `(progn (cl-incf etaf-compiler--fallback-count) ,legacy))))

(provide 'etaf-compiler)
;;; etaf-compiler.el ends here
