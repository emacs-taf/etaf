;;; etaf-runtime-publication-tests.el --- Ebox publication integration -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Exercise committed-query and observation contracts through public APIs.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'ebox)
(require 'etaf)

(ert-deftest etaf-runtime-committed-queries-exclude-active-publication ()
  "Provisional publication cannot leak into committed Runtime queries."
  (let ((buffer (generate-new-buffer " *etaf-publication-query*")) runtime)
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-view (text "Committed")))
          (setq runtime (etaf-runtime-for-buffer buffer))
          (let* ((before (etaf-runtime-snapshot runtime))
                 (revision (plist-get before :revision))
                 (mount-id (plist-get before :mount-id)))
            (ebox-with-transaction
              (should (ebox-transaction-active-p))
              (should-error (etaf-runtime-flush runtime)
                            :type 'etaf-runtime-error)
              (should-error (etaf-runtime-snapshot runtime)))
            (should-not (ebox-transaction-active-p))
            (should (etaf-runtime-mounted-p runtime))
            (should (= revision (etaf-runtime-flush runtime)))
            (should (= mount-id
                       (plist-get (etaf-runtime-snapshot runtime) :mount-id)))
            (should (equal "Committed"
                           (with-current-buffer buffer
                             (buffer-substring-no-properties
                              (point-min) (point-max)))))))
      (when runtime (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-performance-correlates-render-and-publication-reports ()
  "One event exposes Ebox render and publication evidence in one operation."
  (let ((buffer (generate-new-buffer " *etaf-publication-observer*"))
        (count (etaf-ref 0)) runtime)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (text :ref 'counter
                  :on-press (lambda () (cl-incf (etaf-value count)))
                  (expr (number-to-string (etaf-value count))))))
          (setq runtime (etaf-runtime-for-buffer buffer))
          (etaf-performance-start runtime)
          (etaf-performance-call-operation
           runtime 'test "Publication integration"
           (lambda () (etaf-dispatch-event runtime 'counter 'press)))
          (let* ((operation
                  (cl-find "Publication integration"
                           (etaf-performance-records)
                           :key #'etaf-performance-operation-label
                           :test #'equal))
                 (stages (etaf-performance-operation-stages operation))
                 (publication
                  (cl-find 'ebox-publication stages
                           :key #'etaf-performance-stage-provider))
                 (render
                  (cl-find 'ebox stages
                           :key #'etaf-performance-stage-provider)))
            (should publication)
            (should render)
            (let ((transaction-id
                   (plist-get (etaf-performance-stage-metadata publication)
                              :transaction-id)))
              (should (integerp transaction-id))
              (should (eql transaction-id
                           (plist-get
                            (etaf-performance-stage-metadata render)
                            :publication-transaction-id)))))
          (should (= 1 (etaf-value count)))
          (should (equal "1"
                         (with-current-buffer buffer
                           (buffer-substring-no-properties
                            (point-min) (point-max))))))
      (when runtime
        (etaf-performance-stop runtime)
        (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'etaf-runtime-publication-tests)
;;; etaf-runtime-publication-tests.el ends here
