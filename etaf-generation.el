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
(define-error 'etaf-generation-conflict
  "Stale ETAF semantic generation candidate"
  'etaf-generation-error)

(cl-defstruct
    (etaf-generation-store-versions
     (:constructor etaf-generation-store-versions--create))
  "Committed versions for ETAF's independently journaled stores."
  (instances 0 :read-only t)
  (resources 0 :read-only t)
  (artifacts 0 :read-only t)
  (routes 0 :read-only t))

(defun etaf-generation-store-versions-create ()
  "Return an immutable zeroed ETAF store-version snapshot."
  (etaf-generation-store-versions--create))

(defun etaf-generation-store-versions-next (versions)
  "Return the immutable successor of store VERSIONS snapshot."
  (unless (etaf-generation-store-versions-p versions)
    (signal 'wrong-type-argument
            (list 'etaf-generation-store-versions-p versions)))
  (etaf-generation-store-versions--create
   :instances (1+ (etaf-generation-store-versions-instances versions))
   :resources (1+ (etaf-generation-store-versions-resources versions))
   :artifacts (1+ (etaf-generation-store-versions-artifacts versions))
   :routes (1+ (etaf-generation-store-versions-routes versions))))

(cl-defstruct
    (etaf-generation-authority
     (:constructor etaf-generation-authority--create))
  "Mutable authority for one Runtime's committed generation."
  generation
  (token 0)
  (store-versions (etaf-generation-store-versions-create)))

(defun etaf-generation-authority-create (&optional generation)
  "Return fresh authority initially pointing at GENERATION."
  (etaf-generation-authority--create
   :generation generation
   :token 0
   :store-versions (etaf-generation-store-versions-create)))

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

(defun etaf-generation-authority-snapshot (authority)
  "Return AUTHORITY's immutable generation/token/version snapshot."
  (unless (etaf-generation-authority-p authority)
    (signal 'wrong-type-argument
            (list 'etaf-generation-authority-p authority)))
  (list :generation (etaf-generation-authority-generation authority)
        :token (etaf-generation-authority-token authority)
        :store-versions
        (etaf-generation-authority-store-versions authority)))

(defun etaf-generation-authority-validate
    (authority expected-generation expected-token expected-store-versions)
  "Validate AUTHORITY against EXPECTED-GENERATION and EXPECTED-TOKEN.
EXPECTED-STORE-VERSIONS must also equal the committed version snapshot."
  (unless (and (eq (etaf-generation-authority-generation authority)
                   expected-generation)
               (eql (etaf-generation-authority-token authority)
                    expected-token)
               (equal (etaf-generation-authority-store-versions authority)
                      expected-store-versions))
    (signal 'etaf-generation-conflict
            (list
             :expected-generation expected-generation
             :actual-generation
             (etaf-generation-authority-generation authority)
             :expected-token expected-token
             :actual-token (etaf-generation-authority-token authority)
             :expected-store-versions expected-store-versions
             :actual-store-versions
             (etaf-generation-authority-store-versions authority))))
  t)

(defun etaf-generation-authority-compare-and-swap
    (authority expected-generation expected-token expected-store-versions
               next-generation next-token next-store-versions)
  "Atomically swap AUTHORITY from EXPECTED-GENERATION to NEXT-GENERATION.
EXPECTED-TOKEN and EXPECTED-STORE-VERSIONS guard the old authority;
NEXT-TOKEN and NEXT-STORE-VERSIONS become committed together."
  (etaf-generation-authority-validate
   authority expected-generation expected-token expected-store-versions)
  (unless (and (integerp next-token) (> next-token expected-token))
    (signal 'etaf-generation-error
            (list :invalid-next-token next-token)))
  (unless (etaf-generation-store-versions-p next-store-versions)
    (signal 'wrong-type-argument
            (list 'etaf-generation-store-versions-p next-store-versions)))
  (let ((inhibit-quit t))
    (setf (etaf-generation-authority-generation authority) next-generation
          (etaf-generation-authority-token authority) next-token
          (etaf-generation-authority-store-versions authority)
          next-store-versions))
  next-generation)

(defun etaf-generation-authority-rollback-swap
    (authority expected-generation expected-token expected-store-versions
               candidate-generation candidate-token candidate-store-versions)
  "Restore EXPECTED-GENERATION and EXPECTED-TOKEN in AUTHORITY.
EXPECTED-STORE-VERSIONS are restored only while CANDIDATE-GENERATION,
CANDIDATE-TOKEN, and CANDIDATE-STORE-VERSIONS still match exactly."
  (when (and (eq (etaf-generation-authority-generation authority)
                 candidate-generation)
             (eql (etaf-generation-authority-token authority) candidate-token)
             (equal (etaf-generation-authority-store-versions authority)
                    candidate-store-versions))
    (let ((inhibit-quit t))
      (setf (etaf-generation-authority-generation authority)
            expected-generation
            (etaf-generation-authority-token authority) expected-token
            (etaf-generation-authority-store-versions authority)
            expected-store-versions))
    t))

(defcustom etaf-semantic-commit-route 'cas
  "Semantic generation commit route.
`legacy' changes only the compatibility generation pointer, `cas' performs the
versioned token/store compare-and-swap, and `shadow' validates the same expected
facts before using the CAS route."
  :type '(choice (const legacy) (const cas) (const shadow))
  :group 'etaf)

(cl-defstruct
    (etaf-semantic-candidate
     (:constructor etaf-semantic-candidate--create))
  "One-shot ETAF semantic authority candidate."
  operation-id
  candidate-id
  runtime-id
  mount-epoch
  authority
  expected-generation
  candidate-generation
  expected-store-versions
  candidate-store-versions
  expected-token
  candidate-token
  inverse-journal
  route
  (state 'prepared))

(defun etaf-semantic-candidate-create
    (authority candidate-generation operation-id candidate-id runtime-id
               mount-epoch)
  "Prepare a semantic candidate for AUTHORITY and CANDIDATE-GENERATION.
OPERATION-ID, CANDIDATE-ID, RUNTIME-ID, and MOUNT-EPOCH provide immutable
correlation and authority identity."
  (unless (etaf-generation-authority-p authority)
    (signal 'wrong-type-argument
            (list 'etaf-generation-authority-p authority)))
  (let* ((snapshot (etaf-generation-authority-snapshot authority))
         (expected-token (plist-get snapshot :token))
         (expected-versions (plist-get snapshot :store-versions)))
    (etaf-semantic-candidate--create
     :operation-id operation-id
     :candidate-id candidate-id
     :runtime-id runtime-id
     :mount-epoch mount-epoch
     :authority authority
     :expected-generation (plist-get snapshot :generation)
     :candidate-generation candidate-generation
     :expected-store-versions expected-versions
     :candidate-store-versions
     (etaf-generation-store-versions-next expected-versions)
     :expected-token expected-token
     :candidate-token (1+ expected-token))))

(defun etaf-semantic-candidate-stage (candidate)
  "Install CANDIDATE provisionally through its selected authority route."
  (unless (eq (etaf-semantic-candidate-state candidate) 'prepared)
    (signal 'etaf-generation-error
            (list :candidate-not-prepared
                  (etaf-semantic-candidate-state candidate))))
  (let ((authority (etaf-semantic-candidate-authority candidate))
        (route etaf-semantic-commit-route))
    (pcase route
      ('legacy
       (etaf-generation-authority-validate
        authority
        (etaf-semantic-candidate-expected-generation candidate)
        (etaf-semantic-candidate-expected-token candidate)
        (etaf-semantic-candidate-expected-store-versions candidate))
       (etaf-generation-authority-set-current
        authority (etaf-semantic-candidate-candidate-generation candidate)))
      ((or 'cas 'shadow)
       (etaf-generation-authority-compare-and-swap
        authority
        (etaf-semantic-candidate-expected-generation candidate)
        (etaf-semantic-candidate-expected-token candidate)
        (etaf-semantic-candidate-expected-store-versions candidate)
        (etaf-semantic-candidate-candidate-generation candidate)
        (etaf-semantic-candidate-candidate-token candidate)
        (etaf-semantic-candidate-candidate-store-versions candidate)))
      (_
       (signal 'etaf-generation-error
               (list :unknown-semantic-commit-route route))))
    (setf (etaf-semantic-candidate-route candidate) route
          (etaf-semantic-candidate-state candidate) 'staged)
    candidate))

(defun etaf-semantic-candidate-commit (candidate)
  "Mark provisionally installed CANDIDATE committed exactly once."
  (unless (eq (etaf-semantic-candidate-state candidate) 'staged)
    (signal 'etaf-generation-error
            (list :candidate-not-staged
                  (etaf-semantic-candidate-state candidate))))
  (let ((authority (etaf-semantic-candidate-authority candidate)))
    (unless (eq (etaf-generation-authority-generation authority)
                (etaf-semantic-candidate-candidate-generation candidate))
      (signal 'etaf-generation-conflict
              (list :candidate-generation-lost
                    (etaf-semantic-candidate-candidate-id candidate))))
    (unless (or (eq (etaf-semantic-candidate-route candidate) 'legacy)
                (eql (etaf-generation-authority-token authority)
                     (etaf-semantic-candidate-candidate-token candidate)))
      (signal 'etaf-generation-conflict
              (list :candidate-token-lost
                    (etaf-semantic-candidate-candidate-id candidate))))
    (setf (etaf-semantic-candidate-state candidate) 'committed)
    candidate))

(defun etaf-semantic-candidate-rollback (candidate)
  "Rollback staged CANDIDATE exactly once and return CANDIDATE."
  (pcase (etaf-semantic-candidate-state candidate)
    ('prepared
     (setf (etaf-semantic-candidate-state candidate) 'rolled-back))
    ('staged
     (let ((authority (etaf-semantic-candidate-authority candidate)))
       (if (eq (etaf-semantic-candidate-route candidate) 'legacy)
           (when (eq (etaf-generation-authority-generation authority)
                     (etaf-semantic-candidate-candidate-generation candidate))
             (etaf-generation-authority-set-current
              authority
              (etaf-semantic-candidate-expected-generation candidate)))
         (etaf-generation-authority-rollback-swap
          authority
          (etaf-semantic-candidate-expected-generation candidate)
          (etaf-semantic-candidate-expected-token candidate)
          (etaf-semantic-candidate-expected-store-versions candidate)
          (etaf-semantic-candidate-candidate-generation candidate)
          (etaf-semantic-candidate-candidate-token candidate)
          (etaf-semantic-candidate-candidate-store-versions candidate)))
       (setf (etaf-semantic-candidate-state candidate) 'rolled-back)))
    ('rolled-back nil)
    (_
     (signal 'etaf-generation-error
             (list :candidate-not-rollback-capable
                   (etaf-semantic-candidate-state candidate)))))
  candidate)

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
