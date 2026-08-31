;;; etaf-retirement.el --- ETAF postcommit retirement journal -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Defines run-once public lifecycle entries, bounded idempotent structural
;; cleanup, append-only diagnostics, and cause-compatible postcommit condition
;; trailers.  Retirement never owns or rolls back committed generation/surface
;; authority.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(define-error 'etaf-retirement-error "Invalid ETAF retirement journal")

(defvar etaf-retirement--journal-id-counter 0)
(defvar etaf-retirement--entry-id-counter 0)

(cl-defstruct
    (etaf-retirement-entry
     (:constructor etaf-retirement-entry--create))
  "One stable postcommit retirement action."
  id owner kind payload ordering-key
  (attempt-count 0)
  (max-attempts 1)
  policy
  (state 'pending)
  condition)

(cl-defstruct
    (etaf-retirement-journal
     (:constructor etaf-retirement-journal--create))
  "Append-only postcommit retirement and diagnostic journal."
  id operation-id outcome-id generation-id revision
  entries diagnostics
  (state 'open))

(cl-defun etaf-retirement-journal-create
    (&key operation-id outcome-id generation-id revision)
  "Create a journal bound to OPERATION-ID and OUTCOME-ID.
GENERATION-ID and REVISION identify already committed facts."
  (unless (and (integerp operation-id) (>= operation-id 0)
               outcome-id
               (integerp generation-id) (>= generation-id 0)
               (integerp revision) (>= revision 0))
    (signal 'etaf-retirement-error
            (list :invalid-journal-metadata
                  operation-id outcome-id generation-id revision)))
  (etaf-retirement-journal--create
   :id (cl-incf etaf-retirement--journal-id-counter)
   :operation-id operation-id
   :outcome-id outcome-id
   :generation-id generation-id
   :revision revision
   :entries nil
   :diagnostics nil))

(cl-defun etaf-retirement-enqueue
  (journal &key owner kind payload ordering-key policy max-attempts)
  "Append one retirement entry to JOURNAL.
OWNER, KIND, PAYLOAD, ORDERING-KEY, POLICY, and MAX-ATTEMPTS describe the
action."
  (unless (and (etaf-retirement-journal-p journal)
               (eq (etaf-retirement-journal-state journal) 'open)
               owner kind (functionp payload)
               (memq policy '(run-once-public retryable-idempotent
                              contained-once))
               (integerp max-attempts) (> max-attempts 0))
    (signal 'etaf-retirement-error
            (list :invalid-entry owner kind policy max-attempts)))
  (let ((entry
         (etaf-retirement-entry--create
          :id (cl-incf etaf-retirement--entry-id-counter)
          :owner owner
          :kind kind
          :payload payload
          :ordering-key ordering-key
          :policy policy
          :max-attempts max-attempts)))
    (push entry (etaf-retirement-journal-entries journal))
    entry))

(defun etaf-retirement--ordering-value-rank (value)
  "Return a stable type rank for retirement ordering VALUE."
  (cond
   ((null value) 0)
   ((numberp value) 1)
   ((symbolp value) 2)
   ((stringp value) 3)
   ((consp value) 4)
   (t 5)))

(defun etaf-retirement--compare-ordering-values (left right)
  "Compare retirement ordering values LEFT and RIGHT.
Return a negative integer when LEFT precedes RIGHT, zero when their ordering
forms are equal, and a positive integer otherwise."
  (cond
   ((equal left right) 0)
   ((and (numberp left) (numberp right))
    (cond ((= left right) 0) ((< left right) -1) (t 1)))
   ((and (symbolp left) (symbolp right))
    (if (string< (symbol-name left) (symbol-name right)) -1 1))
   ((and (stringp left) (stringp right))
    (if (string< left right) -1 1))
   ((and (consp left) (consp right))
    (let ((left-tail left) (right-tail right) (result 0))
      (while (and (consp left-tail) (consp right-tail) (= result 0))
        (setq result
              (etaf-retirement--compare-ordering-values
               (car left-tail) (car right-tail))
              left-tail (cdr left-tail)
              right-tail (cdr right-tail)))
      (if (= result 0)
          (etaf-retirement--compare-ordering-values left-tail right-tail)
        result)))
   (t
    (let ((left-rank (etaf-retirement--ordering-value-rank left))
          (right-rank (etaf-retirement--ordering-value-rank right)))
      (cond
       ((< left-rank right-rank) -1)
       ((> left-rank right-rank) 1)
       ((string< (prin1-to-string left) (prin1-to-string right)) -1)
       (t 1))))))

(defun etaf-retirement--entry-less-p (left right)
  "Return non-nil when LEFT sorts before RIGHT deterministically."
  (let ((order
         (etaf-retirement--compare-ordering-values
          (etaf-retirement-entry-ordering-key left)
          (etaf-retirement-entry-ordering-key right))))
    (if (= order 0)
        (< (etaf-retirement-entry-id left)
           (etaf-retirement-entry-id right))
      (< order 0))))

(defun etaf-retirement--record-failure (journal entry condition terminal-state)
  "Record ENTRY CONDITION in JOURNAL and assign TERMINAL-STATE."
  (setf (etaf-retirement-entry-condition entry) condition
        (etaf-retirement-entry-state entry) terminal-state)
  (push (list :entry-id (etaf-retirement-entry-id entry)
              :owner (copy-tree (etaf-retirement-entry-owner entry))
              :kind (etaf-retirement-entry-kind entry)
              :policy (etaf-retirement-entry-policy entry)
              :attempt-count (etaf-retirement-entry-attempt-count entry)
              :state terminal-state
              :condition (copy-tree condition))
        (etaf-retirement-journal-diagnostics journal)))

(defun etaf-retirement--run-entry (journal entry)
  "Run JOURNAL ENTRY according to its bounded policy and return a condition."
  (let (condition done)
    (while (and (not done)
                (< (etaf-retirement-entry-attempt-count entry)
                   (etaf-retirement-entry-max-attempts entry)))
      (cl-incf (etaf-retirement-entry-attempt-count entry))
      (setf (etaf-retirement-entry-state entry) 'running)
      (setq condition
            (condition-case failure
                (progn
                  (funcall (etaf-retirement-entry-payload entry))
                  nil)
              ((error quit) failure)))
      (if (null condition)
          (setq done t)
        (unless (eq (etaf-retirement-entry-policy entry)
                    'retryable-idempotent)
          (setq done t))))
    (if (null condition)
        (setf (etaf-retirement-entry-state entry) 'completed)
      (etaf-retirement--record-failure
       journal entry condition 'failed-contained))
    condition))

(defun etaf-retirement-drain (journal)
  "Drain JOURNAL once and return the first public lifecycle condition."
  (unless (and (etaf-retirement-journal-p journal)
               (eq (etaf-retirement-journal-state journal) 'open))
    (signal 'etaf-retirement-error
            (list :journal-not-open
                  (and (etaf-retirement-journal-p journal)
                       (etaf-retirement-journal-state journal)))))
  (let ((entries
         (sort (copy-sequence (etaf-retirement-journal-entries journal))
               #'etaf-retirement--entry-less-p))
        public-condition public-failed-p)
    (dolist (entry entries)
      (cond
       ((and public-failed-p
             (eq (etaf-retirement-entry-policy entry) 'run-once-public))
        (setf (etaf-retirement-entry-state entry) 'abandoned-contained)
        (push (list :entry-id (etaf-retirement-entry-id entry)
                    :owner (copy-tree (etaf-retirement-entry-owner entry))
                    :kind (etaf-retirement-entry-kind entry)
                    :policy 'run-once-public
                    :attempt-count 0
                    :state 'abandoned-contained)
              (etaf-retirement-journal-diagnostics journal)))
       (t
        (when-let* ((condition (etaf-retirement--run-entry journal entry)))
          (when (and (eq (etaf-retirement-entry-policy entry)
                         'run-once-public)
                     (null public-condition))
            (setq public-condition condition
                  public-failed-p t))))))
    (setf (etaf-retirement-journal-entries journal) entries
          (etaf-retirement-journal-diagnostics journal)
          (nreverse (etaf-retirement-journal-diagnostics journal))
          (etaf-retirement-journal-state journal) 'completed)
    public-condition))

(defun etaf-retirement-condition-trailer (journal &optional kind)
  "Return the canonical committed trailer for JOURNAL and optional KIND."
  (list
   :etaf-condition-trailer/v1
   (list :kind (or kind 'postcommit)
         :committed-p t
         :operation-id (etaf-retirement-journal-operation-id journal)
         :outcome-id (etaf-retirement-journal-outcome-id journal)
         :generation-id (etaf-retirement-journal-generation-id journal)
         :revision (etaf-retirement-journal-revision journal)
         :diagnostic-journal-id (etaf-retirement-journal-id journal))))

(defun etaf-condition-postcommit-info (condition)
  "Return validated postcommit payload from CONDITION, or nil."
  (when (and (consp condition) (symbolp (car condition))
             (proper-list-p (cdr condition)) (cdr condition))
    (let* ((trailer (car (last (cdr condition))))
           (payload
            (and (proper-list-p trailer)
                 (= (length trailer) 2)
                 (eq (car trailer) :etaf-condition-trailer/v1)
                 (cadr trailer))))
      (when (and (proper-list-p payload)
                 (eq (plist-get payload :committed-p) t)
                 (eq (plist-get payload :kind) 'postcommit)
                 (integerp (plist-get payload :operation-id))
                 (plist-get payload :outcome-id)
                 (integerp (plist-get payload :generation-id))
                 (integerp (plist-get payload :revision))
                 (integerp (plist-get payload :diagnostic-journal-id)))
        (copy-tree payload)))))

(defun etaf-retirement-resignal (condition journal)
  "Re-signal original CONDITION with JOURNAL's committed trailer appended."
  (unless (and (consp condition) (symbolp (car condition)))
    (signal 'wrong-type-argument (list 'error-condition condition)))
  (if (etaf-condition-postcommit-info condition)
      (signal (car condition) (cdr condition))
    (signal (car condition)
            (append (copy-tree (cdr condition))
                    (list (etaf-retirement-condition-trailer journal))))))

(provide 'etaf-retirement)

;;; etaf-retirement.el ends here
