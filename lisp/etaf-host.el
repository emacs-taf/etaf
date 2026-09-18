;;; etaf-host.el --- ETAF Host attach/detach authority -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Owns one mounted Runtime's fixed Host authority token and state machine.
;; Initial attachment registers a bounded Ebox final marker so attached
;; authority and buffer publication share one final-accept boundary.  Detach
;; invalidates authority in O(1) before any unbounded retirement work.

;;; Code:

(require 'cl-lib)
(require 'ebox)

(define-error 'etaf-host-authority-error "Invalid ETAF Host authority state")

(defconst etaf-host--state-slot 0)
(defconst etaf-host--token-slot 1)
(defconst etaf-host--version-slot 2)

(cl-defstruct
    (etaf-host-authority
     (:constructor etaf-host-authority--create))
  "Fixed identity and mutable authority slots for one Runtime Host."
  host-id
  mount-epoch
  buffer
  slots)

(defun etaf-host-authority-create (host-id mount-epoch buffer)
  "Return detached authority for HOST-ID, MOUNT-EPOCH, and BUFFER."
  (unless (and host-id (integerp mount-epoch) (> mount-epoch 0)
               (bufferp buffer))
    (signal 'etaf-host-authority-error
            (list :invalid-host host-id mount-epoch buffer)))
  (etaf-host-authority--create
   :host-id host-id
   :mount-epoch mount-epoch
   :buffer buffer
   :slots (vector 'detached
                  (list 'etaf-host-token mount-epoch (make-symbol "token"))
                  0)))

(defun etaf-host-authority-state (authority)
  "Return AUTHORITY's current Host state."
  (aref (etaf-host-authority-slots authority) etaf-host--state-slot))

(defun etaf-host-authority-token (authority)
  "Return AUTHORITY's current opaque token, or nil after detach."
  (aref (etaf-host-authority-slots authority) etaf-host--token-slot))

(defun etaf-host-authority-version (authority)
  "Return AUTHORITY's monotonic registration version."
  (aref (etaf-host-authority-slots authority) etaf-host--version-slot))

(defun etaf-host-authority-attached-p (authority)
  "Return non-nil when AUTHORITY is publicly attached."
  (and (etaf-host-authority-p authority)
       (eq (etaf-host-authority-state authority) 'attached)
       (etaf-host-authority-token authority)))

(defun etaf-host-authority-accepts-token-p (authority token)
  "Return non-nil when attached AUTHORITY accepts opaque TOKEN."
  (and (etaf-host-authority-attached-p authority)
       (eq token (etaf-host-authority-token authority))))

(defun etaf-host-authority-begin-attach (authority)
  "Move detached AUTHORITY into its private attaching state."
  (unless (eq (etaf-host-authority-state authority) 'detached)
    (signal 'etaf-host-authority-error
            (list :begin-attach (etaf-host-authority-state authority))))
  (aset (etaf-host-authority-slots authority)
        etaf-host--state-slot 'attaching)
  authority)

(defun etaf-host--slot-write (authority index value)
  "Return one prebuilt Ebox marker write for AUTHORITY slot INDEX and VALUE."
  (ebox-final-marker-slot-write-create
   :target (etaf-host-authority-slots authority)
   :index index
   :value value))

(defun etaf-host-authority-stage-attach (authority)
  "Stage AUTHORITY attachment and register its final marker."
  (unless (eq (etaf-host-authority-state authority) 'attaching)
    (signal 'etaf-host-authority-error
            (list :stage-attach (etaf-host-authority-state authority))))
  (let* ((slots (etaf-host-authority-slots authority))
         (token (etaf-host-authority-token authority))
         (version (etaf-host-authority-version authority)))
    (aset slots etaf-host--state-slot 'provisionally-attached)
    (ebox-transaction-register-final-marker
     :owner-key
     (list 'etaf-host
           (etaf-host-authority-host-id authority)
           (etaf-host-authority-mount-epoch authority))
     :expected-token
     (ebox-final-marker-expectation-create
      :target slots :index etaf-host--token-slot :value token)
     :expected-version
     (ebox-final-marker-expectation-create
      :target slots :index etaf-host--version-slot :value version)
     :next-values
     (vector
      (etaf-host--slot-write authority etaf-host--state-slot 'attached)
      (etaf-host--slot-write authority etaf-host--version-slot (1+ version)))
     :inverse-values
     (vector
      (etaf-host--slot-write
       authority etaf-host--state-slot 'provisionally-attached)
      (etaf-host--slot-write authority etaf-host--version-slot version))
     :slot-write-count 2
     :operation-key 'ebox-vector-slots/v1)
    authority))

(defun etaf-host-authority-rollback-attach (authority)
  "Restore failed attaching AUTHORITY to detached, idempotently."
  (pcase (etaf-host-authority-state authority)
    ((or 'attaching 'provisionally-attached 'attached)
     (aset (etaf-host-authority-slots authority)
           etaf-host--state-slot 'detached))
    ((or 'detached 'terminal) nil)
    (state
     (signal 'etaf-host-authority-error (list :rollback-attach state))))
  authority)

(defun etaf-host-authority-finish-attach (authority)
  "Validate and return final-accept attached AUTHORITY."
  (unless (etaf-host-authority-attached-p authority)
    (signal 'etaf-host-authority-error
            (list :finish-attach (etaf-host-authority-state authority))))
  authority)

(defun etaf-host-authority-begin-detach (authority)
  "Move attached AUTHORITY into pre-boundary detaching state."
  (unless (etaf-host-authority-attached-p authority)
    (signal 'etaf-host-authority-error
            (list :begin-detach (etaf-host-authority-state authority))))
  (aset (etaf-host-authority-slots authority)
        etaf-host--state-slot 'detaching)
  authority)

(defun etaf-host-authority-invalidate (authority)
  "Invalidate AUTHORITY token in O(1) and enter detached retirement."
  (unless (memq (etaf-host-authority-state authority)
                '(detaching attaching provisionally-attached detached))
    (signal 'etaf-host-authority-error
            (list :invalidate (etaf-host-authority-state authority))))
  (let* ((slots (etaf-host-authority-slots authority))
         (version (etaf-host-authority-version authority))
         (inhibit-quit t))
    (aset slots etaf-host--state-slot 'detached-retiring)
    (aset slots etaf-host--token-slot nil)
    (aset slots etaf-host--version-slot (1+ version)))
  authority)

(defun etaf-host-authority-finish-detach (authority)
  "Move detached-retiring AUTHORITY to terminal."
  (unless (memq (etaf-host-authority-state authority)
                '(detached-retiring terminal))
    (signal 'etaf-host-authority-error
            (list :finish-detach (etaf-host-authority-state authority))))
  (aset (etaf-host-authority-slots authority)
        etaf-host--state-slot 'terminal)
  authority)

(provide 'etaf-host)

;;; etaf-host.el ends here
