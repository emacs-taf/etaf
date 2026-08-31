;;; etaf-generation.el --- ETAF committed generation authority -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Owns the single mutable pointer to ETAF's committed semantic generation and
;; pure construction/comparison of compatibility mirrors.  Runtime mirrors are
;; projections only; they never authorize semantic queries or publication.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(define-error 'etaf-generation-error "Invalid ETAF generation authority")

(cl-defstruct
    (etaf-generation-authority
     (:constructor etaf-generation-authority--create))
  "Mutable authority for one Runtime's committed generation."
  generation
  (token 0))

(defun etaf-generation-authority-create (&optional generation)
  "Return fresh authority initially pointing at GENERATION."
  (etaf-generation-authority--create :generation generation :token 0))

(defun etaf-generation-authority-current (authority)
  "Return AUTHORITY's current committed generation."
  (unless (etaf-generation-authority-p authority)
    (signal 'wrong-type-argument
            (list 'etaf-generation-authority-p authority)))
  (etaf-generation-authority-generation authority))

(defun etaf-generation-authority-set-current (authority generation)
  "Set AUTHORITY's current committed GENERATION and return GENERATION.
This compatibility mutation does not advance the semantic commit token; the
versioned compare-and-swap boundary owns token changes."
  (unless (etaf-generation-authority-p authority)
    (signal 'wrong-type-argument
            (list 'etaf-generation-authority-p authority)))
  (setf (etaf-generation-authority-generation authority) generation)
  generation)

(defun etaf-generation-project-mirror (entries &optional test)
  "Project immutable contribution ENTRIES into a fresh hash table.
TEST defaults to `equal'.  Duplicate keys are rejected so a compatibility
mirror cannot silently choose a second semantic truth."
  (unless (proper-list-p entries)
    (signal 'wrong-type-argument (list 'proper-list-p entries)))
  (let ((table (make-hash-table :test (or test #'equal)))
        (missing (make-symbol "etaf-generation-mirror-missing")))
    (dolist (entry entries)
      (unless (consp entry)
        (signal 'etaf-generation-error
                (list :malformed-mirror-entry entry)))
      (let ((key (car entry)))
        (unless (eq (gethash key table missing) missing)
          (signal 'etaf-generation-error
                  (list :duplicate-mirror-key key)))
        (puthash (copy-tree key) (copy-tree (cdr entry)) table)))
    table))

(defun etaf-generation-project-mirrors (handler-entries host-prop-entries)
  "Return fresh mirrors from HANDLER-ENTRIES and HOST-PROP-ENTRIES."
  (list :handlers
        (etaf-generation-project-mirror handler-entries #'equal)
        :host-props
        (etaf-generation-project-mirror host-prop-entries #'equal)))

(defun etaf-generation-mirror-equal-p (left right)
  "Return non-nil when hash tables LEFT and RIGHT contain equal facts."
  (and (hash-table-p left)
       (hash-table-p right)
       (= (hash-table-count left) (hash-table-count right))
       (let ((missing (make-symbol "etaf-generation-mirror-missing"))
             equal-p)
         (setq equal-p t)
         (maphash
          (lambda (key value)
            (unless (equal value (gethash key right missing))
              (setq equal-p nil)))
          left)
         equal-p)))

(provide 'etaf-generation)

;;; etaf-generation.el ends here
