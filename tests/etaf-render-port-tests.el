;;; etaf-render-port-tests.el --- M3a renderer-port gates -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'cl-lib)
(require 'ert)
(require 'etaf-render-port)

(defconst etaf-render-port-test--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "ETAF package root used by static bootstrap-owner checks.")

(ert-deftest etaf-render-port-selects-valid-v2-immutably ()
  "A valid provider produces one immutable v2 selected port."
  (let* ((port (etaf-render-port--bootstrap))
         (capabilities (etaf-render-port-capabilities port)))
    (should (etaf-render-port-p port))
    (should (eq (etaf-render-port-route port) 'v2))
    (should (= (etaf-render-port-spi-version port) 2))
    (should (eq (etaf-render-port-schema-version port)
                'ebox-framework-spi-schema/v2))
    (should (eq (etaf-render-port-tp-protocol port)
                'tp-transaction-protocol-v1+v2))
    (should (eq (etaf-render-port-initial-function port)
                'ebox-framework-spi-initial))
    (should (eq (etaf-render-port-update-function port)
                'ebox-framework-spi-update))
    (should (eq (etaf-render-port-bootstrap-outcome port)
                'valid-v2-selected))
    (setcar capabilities 'mutated)
    (should (eq (car (etaf-render-port-capabilities port))
                'initial-paired-stage-rollback))
    (should-error
     (eval `(setf (etaf-render-port--route ',port) 'broken)))))

(ert-deftest etaf-render-port-falls-back-only-when-v2-is-fully-absent ()
  "Only complete feature/predicate absence selects the immutable v1 port."
  (let ((original-featurep (symbol-function 'featurep)))
    (cl-letf (((symbol-function 'featurep)
               (lambda (feature)
                 (and (not (eq feature 'ebox-framework-spi-v2))
                      (funcall original-featurep feature))))
              ((symbol-function 'ebox-framework-spi-capabilities) nil))
      (let ((port (etaf-render-port--bootstrap)))
        (should (eq (etaf-render-port-route port) 'v1))
        (should (= (etaf-render-port-spi-version port) 1))
        (should (eq (etaf-render-port-initial-function port)
                    'etaf-render-port--v1-initial))
        (should (eq (etaf-render-port-update-function port)
                    'etaf-render-port--v1-update))
        (should (eq (etaf-render-port-bootstrap-outcome port)
                    'v2-absent-v1-selected))))))

(ert-deftest etaf-render-port-rejects-half-present-v2 ()
  "Feature-only and predicate-only providers fail instead of downgrading."
  (cl-letf (((symbol-function 'ebox-framework-spi-capabilities) nil))
    (should-error (etaf-render-port--bootstrap)
                  :type 'etaf-spi-bootstrap-error))
  (let ((original-featurep (symbol-function 'featurep)))
    (cl-letf (((symbol-function 'featurep)
               (lambda (feature)
                 (and (not (eq feature 'ebox-framework-spi-v2))
                      (funcall original-featurep feature)))))
      (should-error (etaf-render-port--bootstrap)
                    :type 'etaf-spi-bootstrap-error))))

(ert-deftest etaf-render-port-rejects-broken-v2-provider ()
  "Throwing, non-record, and malformed providers fail closed."
  (cl-letf
      (((symbol-function 'ebox-framework-spi-capabilities)
        (lambda () (error "injected provider failure"))))
    (should-error (etaf-render-port--bootstrap)
                  :type 'etaf-spi-bootstrap-error))
  (cl-letf
      (((symbol-function 'ebox-framework-spi-capabilities)
        (lambda () 'not-a-provider)))
    (should-error (etaf-render-port--bootstrap)
                  :type 'etaf-spi-bootstrap-error))
  (let ((provider (ebox-framework-spi-capabilities)))
    (cl-letf
        (((symbol-function 'ebox-framework-spi-capabilities)
          (lambda () provider))
         ((symbol-function 'ebox-framework-spi-provider-capabilities)
          (lambda (_provider) "not-a-capability-list")))
      (should-error (etaf-render-port--bootstrap)
                    :type 'etaf-spi-bootstrap-error))))

(ert-deftest etaf-render-port-rejects-incompatible-v2-provider ()
  "Version, required-capability, and TP protocol mismatches are incompatible."
  (let ((provider (ebox-framework-spi-capabilities)))
    (cl-letf
        (((symbol-function 'ebox-framework-spi-capabilities)
          (lambda () provider))
         ((symbol-function 'ebox-framework-spi-provider-spi-version)
          (lambda (_provider) 99)))
      (should-error (etaf-render-port--bootstrap)
                    :type 'etaf-spi-incompatible-error))
    (cl-letf
        (((symbol-function 'ebox-framework-spi-capabilities)
          (lambda () provider))
         ((symbol-function 'ebox-framework-spi-provider-capabilities)
          (lambda (_provider)
            '(initial-paired-stage-rollback
              update-paired-stage-rollback
              same-object-legacy-report))))
      (should-error (etaf-render-port--bootstrap)
                    :type 'etaf-spi-incompatible-error))
    (cl-letf
        (((symbol-function 'ebox-framework-spi-capabilities)
          (lambda () provider))
         ((symbol-function 'ebox-framework-spi-provider-tp-protocol)
          (lambda (_provider) 'tp-transaction-protocol-v0)))
      (should-error (etaf-render-port--bootstrap)
                    :type 'etaf-spi-incompatible-error))))

(ert-deftest etaf-render-port-v1-initial-runs-manual-framework-cleanup ()
  "A failed legacy initial stage invokes its paired cleanup exactly once."
  (let (trace)
    (cl-letf (((symbol-function 'ebox-render-to-buffer)
               (lambda (&rest _arguments)
                 (push 'render trace)
                 'rendered-buffer)))
      (should-error
       (etaf-render-port--v1-initial
        'buffer 'input
        (lambda (_report)
          (push 'stage trace)
          (error "injected v1 initial failure"))
        (lambda (_report) (push 'rollback trace))))
      (should (equal (nreverse trace) '(render stage rollback))))))

(ert-deftest etaf-render-port-is-the-only-protocol-probe-owner ()
  "No downstream ETAF module probes Ebox framework SPI protocol state."
  (dolist (file (directory-files etaf-render-port-test--root t "\\.el\\'"))
    (unless (string= (file-name-nondirectory file) "etaf-render-port.el")
      (with-temp-buffer
        (insert-file-contents file)
        (let ((source (buffer-string)))
          (should-not (string-match-p "ebox-framework-spi" source))
          (should-not (string-match-p "ebox-framework-spi-v2" source)))))))

(ert-deftest etaf-render-port-owns-runtime-update-routing ()
  "Runtime updates use the selected port instead of calling Ebox directly."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "etaf-runtime.el" etaf-render-port-test--root))
    (let ((source (buffer-string)))
      (should (string-match-p "(etaf-render-port-update" source))
      (should-not (string-match-p "(ebox-commit" source)))))

(ert-deftest etaf-render-port-selected-port-is-process-stable ()
  "Every downstream read returns the one bootstrap-selected port identity."
  (should (eq (etaf-render-port-selected)
              (etaf-render-port-selected)))
  (should (memq (etaf-render-port-route (etaf-render-port-selected))
                '(v1 v2))))

(provide 'etaf-render-port-tests)

;;; etaf-render-port-tests.el ends here
