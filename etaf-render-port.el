;;; etaf-render-port.el --- Versioned Ebox renderer port -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This file is ETAF's only Ebox framework-SPI bootstrap owner.  It requires
;; one compatible Ebox v2 provider, snapshots it once, and exposes one immutable
;; port to downstream ETAF code without repeated protocol guesses.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox)

(define-error 'etaf-spi-bootstrap-error
  "Malformed Ebox framework SPI provider")
(define-error 'etaf-spi-incompatible-error
  "Incompatible Ebox framework SPI provider"
  'etaf-spi-bootstrap-error)

(defconst etaf-render-port--required-spi-version 2
  "Ebox framework SPI version consumed by this ETAF build.")

(defconst etaf-render-port--required-schema-version
  'ebox-framework-spi-schema/v2
  "Ebox provider schema consumed by this ETAF build.")

(defconst etaf-render-port--required-capabilities
  '(initial-paired-stage-rollback
    update-paired-stage-rollback
    combined-participant-ordering
    same-object-legacy-report
    initial-observation-replay)
  "Capabilities required from an Ebox framework SPI v2 provider.")

(defconst etaf-render-port--accepted-tp-protocols
  '(tp-transaction-protocol-v1+v2 tp-transaction-protocol-v2)
  "TP protocols accepted from an Ebox SPI v2 provider.
The dual-capability manifest is accepted during dependency-order migration
because it contains v2; ETAF never dispatches through its v1 capability.")

(defconst etaf-render-port--required-stage-order
  '(ebox-mirror/native framework-stage)
  "Required stage order inside the combined Ebox participant.")

(defconst etaf-render-port--required-rollback-order
  '(framework-rollback ebox-mirror/native tp)
  "Required rollback order inside the combined Ebox participant.")

(cl-defstruct
    (etaf-render-port
     (:constructor etaf-render-port--create)
     (:conc-name etaf-render-port--))
  "Immutable selected Ebox rendering capability."
  (route nil :read-only t)
  (spi-version nil :read-only t)
  (schema-version nil :read-only t)
  (capabilities nil :read-only t)
  (tp-protocol nil :read-only t)
  (initial-function nil :read-only t)
  (update-function nil :read-only t)
  (revision-function nil :read-only t)
  (bootstrap-outcome nil :read-only t)
  (provider nil :read-only t))

(defun etaf-render-port-route (port)
  "Return selected PORT route, always `v2'."
  (etaf-render-port--route port))

(defun etaf-render-port-spi-version (port)
  "Return PORT's selected framework SPI version."
  (etaf-render-port--spi-version port))

(defun etaf-render-port-schema-version (port)
  "Return PORT's selected provider schema version."
  (etaf-render-port--schema-version port))

(defun etaf-render-port-capabilities (port)
  "Return a defensive copy of PORT's capabilities."
  (copy-sequence (etaf-render-port--capabilities port)))

(defun etaf-render-port-tp-protocol (port)
  "Return PORT's selected TP transaction protocol."
  (etaf-render-port--tp-protocol port))

(defun etaf-render-port-initial-function (port)
  "Return PORT's initial mount function symbol."
  (etaf-render-port--initial-function port))

(defun etaf-render-port-update-function (port)
  "Return PORT's update function symbol."
  (etaf-render-port--update-function port))

(defun etaf-render-port-revision-function (port)
  "Return PORT's committed-revision query function symbol."
  (etaf-render-port--revision-function port))

(defun etaf-render-port-bootstrap-outcome (port)
  "Return PORT's immutable bootstrap outcome tag."
  (etaf-render-port--bootstrap-outcome port))

(defun etaf-render-port--bootstrap-error (reason &optional detail)
  "Signal a fail-closed bootstrap error for REASON and DETAIL."
  (signal 'etaf-spi-bootstrap-error
          (list :reason reason :detail detail)))

(defun etaf-render-port--ensure-accessors ()
  "Require every public Ebox v2 record accessor before reading a provider."
  (dolist
      (function
       '(ebox-framework-spi-provider-p
         ebox-framework-spi-provider-spi-version
         ebox-framework-spi-provider-schema-version
         ebox-framework-spi-provider-capabilities
         ebox-framework-spi-provider-tp-protocol
         ebox-framework-spi-provider-stage-order
         ebox-framework-spi-provider-rollback-order
         ebox-framework-spi-provider-report-semantics
         ebox-framework-spi-provider-initial-operation
         ebox-framework-spi-provider-update-operation
         ebox-framework-spi-operation-p
         ebox-framework-spi-operation-kind
         ebox-framework-spi-operation-function
         ebox-framework-spi-operation-argument-schema
         ebox-framework-spi-operation-result-schema
         ebox-framework-spi-operation-paired-stage-rollback-p
         ebox-framework-spi-initial-observation-reports))
    (unless (fboundp function)
      (etaf-render-port--bootstrap-error
       'missing-provider-accessor function))))

(defun etaf-render-port--operation-snapshot (operation label)
  "Return validated immutable field snapshot for OPERATION named LABEL."
  (unless (ebox-framework-spi-operation-p operation)
    (etaf-render-port--bootstrap-error
     'malformed-operation (list :label label :value operation)))
  (let ((kind (ebox-framework-spi-operation-kind operation))
        (function (ebox-framework-spi-operation-function operation))
        (arguments
         (ebox-framework-spi-operation-argument-schema operation))
        (result (ebox-framework-spi-operation-result-schema operation))
        (paired
         (ebox-framework-spi-operation-paired-stage-rollback-p operation)))
    (unless (and (symbolp kind)
                 (symbolp function)
                 (fboundp function)
                 (proper-list-p arguments)
                 (cl-every #'symbolp arguments)
                 (symbolp result)
                 (memq paired '(nil t)))
      (etaf-render-port--bootstrap-error
       'malformed-operation-fields
       (list :label label :kind kind :function function
             :arguments arguments :result result :paired paired)))
    (list :kind kind :function function
          :arguments (copy-sequence arguments)
          :result result :paired paired)))

(defun etaf-render-port--provider-snapshot (provider)
  "Return a validated field snapshot of Ebox v2 PROVIDER."
  (etaf-render-port--ensure-accessors)
  (unless (ebox-framework-spi-provider-p provider)
    (etaf-render-port--bootstrap-error 'non-provider-record provider))
  (let ((spi-version (ebox-framework-spi-provider-spi-version provider))
        (schema-version
         (ebox-framework-spi-provider-schema-version provider))
        (capabilities
         (ebox-framework-spi-provider-capabilities provider))
        (tp-protocol (ebox-framework-spi-provider-tp-protocol provider))
        (stage-order (ebox-framework-spi-provider-stage-order provider))
        (rollback-order
         (ebox-framework-spi-provider-rollback-order provider))
        (report-semantics
         (ebox-framework-spi-provider-report-semantics provider)))
    (unless (and (integerp spi-version)
                 (> spi-version 0)
                 (symbolp schema-version)
                 (proper-list-p capabilities)
                 (cl-every #'symbolp capabilities)
                 (symbolp tp-protocol)
                 (proper-list-p stage-order)
                 (cl-every #'symbolp stage-order)
                 (proper-list-p rollback-order)
                 (cl-every #'symbolp rollback-order)
                 (symbolp report-semantics))
      (etaf-render-port--bootstrap-error
       'malformed-provider-fields
       (list :spi-version spi-version :schema-version schema-version
             :capabilities capabilities :tp-protocol tp-protocol
             :stage-order stage-order :rollback-order rollback-order
             :report-semantics report-semantics)))
    (list
     :provider provider
     :spi-version spi-version
     :schema-version schema-version
     :capabilities (copy-sequence capabilities)
     :tp-protocol tp-protocol
     :stage-order (copy-sequence stage-order)
     :rollback-order (copy-sequence rollback-order)
     :report-semantics report-semantics
     :initial
     (etaf-render-port--operation-snapshot
      (ebox-framework-spi-provider-initial-operation provider) 'initial)
     :update
     (etaf-render-port--operation-snapshot
      (ebox-framework-spi-provider-update-operation provider) 'update))))

(defun etaf-render-port--incompatibilities (snapshot)
  "Return deterministic compatibility failures in provider SNAPSHOT."
  (let (failures)
    (unless (eql (plist-get snapshot :spi-version)
                 etaf-render-port--required-spi-version)
      (push (list :spi-version (plist-get snapshot :spi-version)) failures))
    (unless (eq (plist-get snapshot :schema-version)
                etaf-render-port--required-schema-version)
      (push (list :schema-version (plist-get snapshot :schema-version))
            failures))
    (let ((capabilities (plist-get snapshot :capabilities)))
      (dolist (capability etaf-render-port--required-capabilities)
        (unless (memq capability capabilities)
          (push (list :missing-capability capability) failures))))
    (unless (memq (plist-get snapshot :tp-protocol)
                  etaf-render-port--accepted-tp-protocols)
      (push (list :tp-protocol (plist-get snapshot :tp-protocol)) failures))
    (unless (equal (plist-get snapshot :stage-order)
                   etaf-render-port--required-stage-order)
      (push (list :stage-order (plist-get snapshot :stage-order)) failures))
    (unless (equal (plist-get snapshot :rollback-order)
                   etaf-render-port--required-rollback-order)
      (push (list :rollback-order (plist-get snapshot :rollback-order))
            failures))
    (unless (eq (plist-get snapshot :report-semantics)
                'same-object-legacy-report)
      (push (list :report-semantics
                  (plist-get snapshot :report-semantics))
            failures))
    (dolist
        (expectation
         `((:initial initial ebox-framework-spi-initial
                    (buffer canonical-input framework-stage framework-rollback))
           (:update update ebox-framework-spi-update
                    (buffer canonical-input-or-candidate
                            framework-stage framework-rollback))))
      (let* ((slot (nth 0 expectation))
             (operation (plist-get snapshot slot)))
        (unless (and (eq (plist-get operation :kind) (nth 1 expectation))
                     (eq (plist-get operation :function) (nth 2 expectation))
                     (equal (plist-get operation :arguments)
                            (nth 3 expectation))
                     (eq (plist-get operation :result)
                         'ebox-legacy-report/same-object)
                     (eq (plist-get operation :paired) t))
          (push (list slot operation) failures))))
    (nreverse failures)))

(defun etaf-render-port--v2-port (snapshot)
  "Return an immutable selected v2 port from compatible SNAPSHOT."
  (let ((failures (etaf-render-port--incompatibilities snapshot)))
    (when failures
      (signal 'etaf-spi-incompatible-error
              (list :incompatibilities failures)))
    (etaf-render-port--create
     :route 'v2
     :spi-version (plist-get snapshot :spi-version)
     :schema-version (plist-get snapshot :schema-version)
     :capabilities (copy-sequence (plist-get snapshot :capabilities))
     :tp-protocol (plist-get snapshot :tp-protocol)
     :initial-function
     (plist-get (plist-get snapshot :initial) :function)
     :update-function
     (plist-get (plist-get snapshot :update) :function)
     :revision-function 'ebox-surface-buffer-revision
     :bootstrap-outcome 'valid-v2-selected
     :provider (plist-get snapshot :provider))))

(defun etaf-render-port--bootstrap ()
  "Probe Ebox exactly once and return one immutable selected render port."
  (let ((feature-present-p (featurep 'ebox-framework-spi-v2))
        (predicate-present-p (fboundp 'ebox-framework-spi-capabilities)))
    (cond
     ((and (not feature-present-p) (not predicate-present-p))
      (etaf-render-port--bootstrap-error 'v2-provider-missing))
     ((not feature-present-p)
      (etaf-render-port--bootstrap-error 'predicate-without-v2-feature))
     ((not predicate-present-p)
      (etaf-render-port--bootstrap-error 'v2-feature-without-predicate))
     (t
      (condition-case condition
          (etaf-render-port--v2-port
           (etaf-render-port--provider-snapshot
            (ebox-framework-spi-capabilities)))
        ((etaf-spi-incompatible-error etaf-spi-bootstrap-error)
         (signal (car condition) (cdr condition)))
        ((error quit)
         (etaf-render-port--bootstrap-error
          'provider-predicate-failure condition)))))))

(defconst etaf-render-port--selected-port
  (etaf-render-port--bootstrap)
  "Process-wide immutable Ebox render port selected during ETAF bootstrap.")

(defun etaf-render-port-selected ()
  "Return the process-wide immutable Ebox render port."
  etaf-render-port--selected-port)

(defun etaf-render-port-initial
    (buffer input framework-stage framework-rollback &optional observer)
  "Run selected initial operation for BUFFER and canonical INPUT.
FRAMEWORK-STAGE and FRAMEWORK-ROLLBACK are one required callback pair.
OBSERVER, when non-nil, receives TP and Ebox snapshots measured during the
initial v2 publication and replayed only after successful final accept."
  (let ((report
         (funcall
          (etaf-render-port-initial-function etaf-render-port--selected-port)
          buffer input framework-stage framework-rollback)))
    (when observer
      (dolist (provider-report
               (ebox-framework-spi-initial-observation-reports report))
        (funcall observer buffer provider-report)))
    report))

(defun etaf-render-port-update
    (buffer input framework-stage framework-rollback)
  "Run selected update operation for BUFFER and INPUT.
FRAMEWORK-STAGE and FRAMEWORK-ROLLBACK are one required callback pair."
  (funcall (etaf-render-port-update-function
            etaf-render-port--selected-port)
           buffer input framework-stage framework-rollback))

(defun etaf-render-port-unmount (buffer)
  "Release the retained Ebox surface owned by mounted BUFFER."
  (ebox-unmount-buffer (get-buffer buffer)))

(defun etaf-render-port-mounted-p (buffer)
  "Return non-nil when BUFFER owns a live retained Ebox surface."
  (ebox-surface-buffer-mounted-p buffer))

(defun etaf-render-port-revision (buffer)
  "Return BUFFER's committed Ebox revision, or zero when it is unmounted."
  (let ((buffer (get-buffer buffer)))
    (if (not (and (buffer-live-p buffer)
                  (ebox-surface-buffer-mounted-p buffer)))
        0
      (let ((revision
             (funcall
              (etaf-render-port-revision-function
               etaf-render-port--selected-port)
              buffer)))
        (unless (and (integerp revision) (> revision 0))
          (error "Mounted Ebox surface has no committed revision: %S"
                 revision))
        revision))))

(provide 'etaf-render-port)

;;; etaf-render-port.el ends here
