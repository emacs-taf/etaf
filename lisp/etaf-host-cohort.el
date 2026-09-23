;;; etaf-host-cohort.el --- Retained primitive publication groups -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Reuse one provider operation for a known set of primitive Host and text
;; effects.  Members own their bound semantic cells and getter programs;
;; the group owns atomic staging and one publication/lifecycle boundary.

;;; Code:

(require 'cl-lib)
(require 'etaf-host-update)

(declare-function ebox-update-prepare "ebox"
                  (buffer-or-name specifications &optional stage rollback after-commit))
(declare-function ebox-update-valid-p "ebox" (operation))
(declare-function ebox-update-apply "ebox" (operation values changed-indices &optional count))

(cl-defstruct (etaf--host-cohort (:constructor etaf--host-cohort-create))
  runtime generation members values changed-indices (changed-count 0)
  operation owner-indices owners owner-changed)

(defun etaf--host-cohort-stage (cohort)
  "Stage COHORT's changed semantic cells under one generation token."
  (let* ((runtime (etaf--host-cohort-runtime cohort))
         (generation (etaf--host-cohort-generation cohort))
         (members (etaf--host-cohort-members cohort))
         (indices (etaf--host-cohort-changed-indices cohort))
         (inhibit-quit t))
    (unless (eq generation (etaf-runtime-current-generation runtime))
      (signal 'etaf-generation-conflict '(prepared-cohort-generation)))
    (dotimes (position (etaf--host-cohort-changed-count cohort))
      (etaf--host-update-stage (aref members (aref indices position)) t))
    (cl-incf (etaf-generation-generation-id generation))
    (cl-incf (etaf-generation-authority-token
             (etaf-runtime-generation-authority runtime)))))

(defun etaf--host-cohort-rollback (cohort)
  "Restore COHORT's semantic writes in reverse staging order."
  (let ((members (etaf--host-cohort-members cohort))
        (indices (etaf--host-cohort-changed-indices cohort))
        (position (etaf--host-cohort-changed-count cohort)))
    (while (> position 0)
      (setq position (1- position))
      (etaf--host-update-rollback (aref members (aref indices position))))))

(defun etaf--host-cohort-after-commit (cohort)
  "Consume COHORT work and deliver each changed inline owner's hooks once."
  (let* ((runtime (etaf--host-cohort-runtime cohort))
         (members (etaf--host-cohort-members cohort))
         (owners (etaf--host-cohort-owners cohort))
         (changed (etaf--host-cohort-owner-changed cohort))
         journal)
    (setf (etaf-runtime-dirty-effect-queue runtime) nil
          (etaf-runtime-dirty-effect-queue-tail runtime) nil
          (etaf-runtime-pending-p runtime) nil)
    (dotimes (index (length members))
      (etaf--host-update-consume (aref members index)))
    (dotimes (index (length owners))
      (when (aref changed index)
        (let* ((instance (aref owners index))
               (hooks (etaf--component-instance-updated-hooks instance)))
          (when hooks
            (unless journal
              (setq journal
                    (etaf--runtime-new-retirement-journal
                     runtime (cl-incf (etaf-runtime-next-semantic-candidate-id runtime)))))
            (etaf--runtime-enqueue-instance-hooks
             runtime journal instance 'updated hooks (list 3 index))))))
    (when journal (etaf--runtime-drain-retirement runtime journal))))

(defun etaf--host-cohort-bind-owners (cohort)
  "Compile COHORT's owner order and per-member lifecycle indices."
  (let* ((members (etaf--host-cohort-members cohort))
         (ordinals (make-hash-table :test #'eq))
         owners)
    (dotimes (index (length members))
      (when-let* ((instance (etaf--host-update-lifecycle-instance (aref members index))))
        (cl-pushnew instance owners :test #'eq)))
    (setq owners (vconcat (nreverse owners)))
    (dotimes (index (length owners)) (puthash (aref owners index) index ordinals))
    (let ((indices (make-vector (length members) nil)))
      (dotimes (index (length members))
        (aset indices index
              (gethash (etaf--host-update-lifecycle-instance (aref members index)) ordinals)))
      (setf (etaf--host-cohort-owner-indices cohort) indices
            (etaf--host-cohort-owners cohort) owners
            (etaf--host-cohort-owner-changed cohort) (make-vector (length owners) nil)))))

(defun etaf--host-cohort-prepare (runtime)
  "Compile RUNTIME's current primitive work into one reusable provider cohort."
  (catch 'etaf-host-cohort-unsupported
    (let (members)
      (dolist (effect-id (etaf-runtime-dirty-effect-queue runtime))
        (let ((member (etaf--host-update-for-effect runtime effect-id)))
          (unless member (throw 'etaf-host-cohort-unsupported nil))
          (push member members)))
      (setq members (vconcat (nreverse members)))
      (let* ((count (length members))
             (specifications (make-vector count nil))
             (values (make-vector count nil))
             (cohort (etaf--host-cohort-create
                      :runtime runtime :generation (etaf-runtime-current-generation runtime)
                      :members members :values values :changed-indices (make-vector count 0))))
        (dotimes (index count)
          (let ((member (aref members index)))
            (aset specifications index
                  (vector (etaf--semantic-host-host-ref (etaf--host-update-semantic member))
                          (etaf--host-update-properties member)))
            (aset values index (etaf--host-update-values member))))
        (setf (etaf--host-cohort-operation cohort)
              (ebox-update-prepare
               (etaf-runtime-buffer runtime) specifications
               (lambda () (etaf--host-cohort-stage cohort))
               (lambda () (etaf--host-cohort-rollback cohort))
               (lambda () (etaf--host-cohort-after-commit cohort))))
        (when (etaf--host-cohort-operation cohort)
          (etaf--host-cohort-bind-owners cohort)
          (push cohort (etaf-runtime-prepared-host-cohorts runtime))
          cohort)))))

(defun etaf--host-cohort-for-queue (runtime)
  "Find RUNTIME's compiled cohort by queue membership without constructing keys."
  (let ((count (length (etaf-runtime-dirty-effect-queue runtime)))
        (ids (etaf-runtime-dirty-effect-ids runtime))
        (cohorts (etaf-runtime-prepared-host-cohorts runtime))
        found)
    (while (and cohorts (not found))
      (let* ((cohort (pop cohorts))
             (members (etaf--host-cohort-members cohort))
             (index 0))
        (when (and (= count (length members))
                   (eq (etaf--host-cohort-generation cohort)
                       (etaf-runtime-current-generation runtime)))
          (while (and (< index count)
                      (gethash (etaf--host-update-effect-id (aref members index)) ids))
            (setq index (1+ index)))
          (when (and (= index count)
                     (ebox-update-valid-p (etaf--host-cohort-operation cohort)))
            (setq found cohort)))))
    (or found (etaf--host-cohort-prepare runtime))))

(defun etaf--host-cohort-evaluate (cohort)
  "Evaluate COHORT's members and collect changed indices in retained storage."
  (let ((members (etaf--host-cohort-members cohort))
        (indices (etaf--host-cohort-changed-indices cohort))
        (owner-indices (etaf--host-cohort-owner-indices cohort))
        (owners (etaf--host-cohort-owner-changed cohort))
        (count 0))
    (fillarray owners nil)
    (setf (etaf--host-cohort-changed-count cohort) 0)
    (dotimes (index (length members))
      (let ((member (aref members index)))
        (setf (etaf--host-update-staged-p member) nil)
        (funcall (etaf--host-update-evaluate-function member))
        (when (etaf--host-update-changed-p member)
          (aset indices count index)
          (setq count (1+ count))
          (when-let* ((owner (aref owner-indices index))) (aset owners owner t)))))
    (setf (etaf--host-cohort-changed-count cohort) count))
  t)

(defun etaf--host-cohort-try-flush (runtime)
  "Publish RUNTIME's eligible primitive work as one atomic retained cohort."
  (when (and (etaf-runtime-dirty-effect-queue runtime)
             (not (etaf-runtime-root-dirty-p runtime)))
    (when-let* ((cohort (etaf--host-cohort-for-queue runtime)))
      (setf (etaf-runtime-flushing-p runtime) t)
      (unwind-protect
          (when (catch 'etaf-host-update-declined (etaf--host-cohort-evaluate cohort))
            (if (zerop (etaf--host-cohort-changed-count cohort))
                (progn (etaf--host-cohort-after-commit cohort) t)
              (ebox-update-apply
               (etaf--host-cohort-operation cohort) (etaf--host-cohort-values cohort)
               (etaf--host-cohort-changed-indices cohort) (etaf--host-cohort-changed-count cohort))))
        (setf (etaf-runtime-flushing-p runtime) nil)))))

(provide 'etaf-host-cohort)
;;; etaf-host-cohort.el ends here
