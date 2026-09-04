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

(ert-deftest etaf-render-port-package-metadata-requires-final-v2-stack ()
  "ETAF 0.2.1 declares the Ebox 3 and TP 2 runtime requirements."
  (require 'package)
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "etaf.el" etaf-render-port-test--root))
    (let ((description (package-buffer-info)))
      (should (equal (package-desc-version description) '(0 2 1)))
      (should
       (equal (package-desc-reqs description)
              '((emacs (29 1)) (ebox (3 0 0)) (tp (2 0 0))))))))

(ert-deftest etaf-render-port-selects-valid-v2-immutably ()
  "A valid provider produces one immutable v2 selected port."
  (let* ((port (etaf-render-port--bootstrap))
         (capabilities (etaf-render-port-capabilities port)))
    (should (etaf-render-port-p port))
    (should (eq (etaf-render-port-route port) 'v2))
    (should (= (etaf-render-port-spi-version port) 2))
    (should (eq (etaf-render-port-schema-version port)
                'ebox-framework-spi-schema/v2))
    (should (memq (etaf-render-port-tp-protocol port)
                  etaf-render-port--accepted-tp-protocols))
    (should (eq (etaf-render-port-initial-function port)
                'ebox-framework-spi-initial))
    (should (eq (etaf-render-port-update-function port)
                'ebox-framework-spi-update))
    (should (eq (etaf-render-port-revision-function port)
                'ebox-surface-buffer-revision))
    (should (eq (etaf-render-port-bootstrap-outcome port)
                'valid-v2-selected))
    (setcar capabilities 'mutated)
    (should (eq (car (etaf-render-port-capabilities port))
                'initial-paired-stage-rollback))
    (should-error
     (eval `(setf (etaf-render-port--route ',port) 'broken)))))

(ert-deftest etaf-render-port-requires-v2-provider ()
  "Complete provider absence fails closed instead of selecting a legacy port."
  (let ((original-featurep (symbol-function 'featurep)))
    (cl-letf (((symbol-function 'featurep)
               (lambda (feature)
                 (and (not (eq feature 'ebox-framework-spi-v2))
                      (funcall original-featurep feature))))
              ((symbol-function 'ebox-framework-spi-capabilities) nil))
      (should-error (etaf-render-port--bootstrap)
                    :type 'etaf-spi-bootstrap-error))))

(ert-deftest etaf-render-port-accepts-each-v2-capable-tp-manifest ()
  "Both transitional dual-capability and final v2-only providers are valid."
  (let ((provider (ebox-framework-spi-capabilities)))
    (dolist (protocol '(tp-transaction-protocol-v1+v2
                        tp-transaction-protocol-v2))
      (cl-letf
          (((symbol-function 'ebox-framework-spi-capabilities)
            (lambda () provider))
           ((symbol-function 'ebox-framework-spi-provider-tp-protocol)
            (lambda (_provider) protocol)))
        (should (eq (etaf-render-port-tp-protocol
                     (etaf-render-port--bootstrap))
                    protocol))))))

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

(ert-deftest etaf-render-port-v2-initial-delegates-paired-rollback ()
  "The selected SPI operation owns stage failure and paired rollback."
  (let ((buffer (generate-new-buffer " *etaf-v2-paired-rollback*")) trace)
    (unwind-protect
        (cl-letf (((symbol-function 'ebox-framework-spi-initial)
                   (lambda (_buffer _input stage rollback)
                     (push 'render trace)
                     (condition-case condition
                         (funcall stage nil)
                       (error
                        (funcall rollback nil)
                        (signal (car condition) (cdr condition)))))))
          (should-error
           (etaf-render-port-initial
            buffer 'input
            (lambda (_report)
              (push 'stage trace)
              (error "injected v2 initial failure"))
            (lambda (_report) (push 'rollback trace))))
          (should (equal (nreverse trace) '(render stage rollback))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-render-port-v2-initial-restores-real-ebox-surface ()
  "A failed SPI stage removes Ebox authority and restores buffer content."
  (let ((buffer (generate-new-buffer " *etaf-v2-real-cleanup*"))
        (input (ebox-build '(box "committed")))
        (rollback-count 0)
        captured)
    (unwind-protect
        (progn
          (with-current-buffer buffer (insert "sentinel"))
          (condition-case condition
              (etaf-render-port-initial
               buffer input
               (lambda (_report)
                 (error "injected real v2 stage failure"))
               (lambda (_report) (cl-incf rollback-count)))
            (error (setq captured condition)))
          (should (equal captured '(error "injected real v2 stage failure")))
          (should (= rollback-count 1))
          (should-not (ebox-surface-buffer-mounted-p buffer))
          (should-not (ebox-surface-buffer-observer buffer))
          (should (equal "sentinel"
                         (with-current-buffer buffer (buffer-string)))))
      (when (and (buffer-live-p buffer)
                 (ebox-surface-buffer-mounted-p buffer))
        (ebox-unmount-buffer buffer))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-render-port-v2-failure-restores-exact-editor-custody ()
  "SPI stage rollback preserves Emacs-owned editor identities and undo."
  (let ((buffer (generate-new-buffer " *etaf-v2-editor-custody*"))
        (input (ebox-build '(box "committed")))
        overlay left-marker right-marker snapshot captured)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (buffer-enable-undo)
            (insert (propertize "sentinel" 'face 'bold))
            (undo-boundary)
            (goto-char 4)
            (set-mark 2)
            (setq mark-active t)
            (setq overlay (make-overlay 2 6 buffer t t)
                  left-marker (copy-marker 3 nil)
                  right-marker (copy-marker 5 t))
            (overlay-put overlay 'etaf-test-property '(owned value))
            (narrow-to-region 2 7)
            (set-buffer-modified-p nil)
            (setq snapshot
                  (list
                   :contents
                   (save-restriction
                     (widen)
                     (buffer-substring (point-min) (point-max)))
                   :point (point)
                   :mark-marker (mark-marker)
                   :mark-position (mark t)
                   :mark-insertion-type
                   (marker-insertion-type (mark-marker))
                   :mark-active mark-active
                   :narrow-start (point-min)
                   :narrow-end (point-max)
                   :overlay-start (overlay-start overlay)
                   :overlay-end (overlay-end overlay)
                   :overlay-properties (overlay-properties overlay)
                   :left-position (marker-position left-marker)
                   :left-insertion-type (marker-insertion-type left-marker)
                   :right-position (marker-position right-marker)
                   :right-insertion-type (marker-insertion-type right-marker)
                   :undo-list (copy-tree buffer-undo-list)
                   :modified-p (buffer-modified-p))))
          (condition-case condition
              (etaf-render-port-initial
               buffer input
               (lambda (_report) (error "editor custody primary"))
               #'ignore)
            (error (setq captured condition)))
          (should (equal captured '(error "editor custody primary")))
          (should-not (ebox-surface-buffer-mounted-p buffer))
          (should-not (ebox-surface-buffer-observer buffer))
          (with-current-buffer buffer
            (should
             (equal (save-restriction
                      (widen)
                      (buffer-substring (point-min) (point-max)))
                    (plist-get snapshot :contents)))
            (should (= (point) (plist-get snapshot :point)))
            (should (eq (mark-marker) (plist-get snapshot :mark-marker)))
            (should (= (mark t) (plist-get snapshot :mark-position)))
            (should
             (eq (marker-insertion-type (mark-marker))
                 (plist-get snapshot :mark-insertion-type)))
            (should (eq mark-active (plist-get snapshot :mark-active)))
            (should (= (point-min) (plist-get snapshot :narrow-start)))
            (should (= (point-max) (plist-get snapshot :narrow-end)))
            (should (overlayp overlay))
            (should (eq (overlay-buffer overlay) buffer))
            (should (= (overlay-start overlay)
                       (plist-get snapshot :overlay-start)))
            (should (= (overlay-end overlay)
                       (plist-get snapshot :overlay-end)))
            (should (equal (overlay-properties overlay)
                           (plist-get snapshot :overlay-properties)))
            (should (eq (marker-buffer left-marker) buffer))
            (should (= (marker-position left-marker)
                       (plist-get snapshot :left-position)))
            (should
             (eq (marker-insertion-type left-marker)
                 (plist-get snapshot :left-insertion-type)))
            (should (eq (marker-buffer right-marker) buffer))
            (should (= (marker-position right-marker)
                       (plist-get snapshot :right-position)))
            (should
             (eq (marker-insertion-type right-marker)
                 (plist-get snapshot :right-insertion-type)))
            (should (equal buffer-undo-list (plist-get snapshot :undo-list)))
            (should (eq (buffer-modified-p)
                        (plist-get snapshot :modified-p)))))
      (when (overlayp overlay) (delete-overlay overlay))
      (when (markerp left-marker) (set-marker left-marker nil))
      (when (markerp right-marker) (set-marker right-marker nil))
      (when (and (buffer-live-p buffer)
                 (ebox-surface-buffer-mounted-p buffer))
        (ebox-unmount-buffer buffer))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-render-port-v2-nonlocal-exit-runs-exact-cleanup ()
  "A SPI stage throw cannot escape with mounted or editor state retained."
  (let ((buffer (generate-new-buffer " *etaf-v2-nonlocal-cleanup*"))
        (input (ebox-build '(box "committed")))
        (rollback-count 0))
    (unwind-protect
        (progn
          (with-current-buffer buffer (insert "before"))
          (should
           (eq
            (catch 'etaf-v2-test-escape
              (etaf-render-port-initial
               buffer input
               (lambda (_report)
                 (throw 'etaf-v2-test-escape 'escaped))
               (lambda (_report) (cl-incf rollback-count)))
              'not-escaped)
            'escaped))
          (should (= rollback-count 1))
          (should-not (ebox-surface-buffer-mounted-p buffer))
          (should-not (ebox-surface-buffer-observer buffer))
          (should (equal "before"
                         (with-current-buffer buffer (buffer-string)))))
      (when (and (buffer-live-p buffer)
                 (ebox-surface-buffer-mounted-p buffer))
        (ebox-unmount-buffer buffer))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-render-port-v2-precondition-keeps-existing-mount ()
  "Rejecting an already mounted target must not clean up foreign authority."
  (let ((buffer (generate-new-buffer " *etaf-v1-existing-mount*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer (ebox-build '(box "existing")))
          (let ((revision (ebox-surface-buffer-revision buffer)))
            (should-error
             (etaf-render-port-initial
              buffer (ebox-build '(box "replacement")) #'ignore #'ignore)
             :type 'error)
            (should (ebox-surface-buffer-mounted-p buffer))
            (should (= revision (ebox-surface-buffer-revision buffer)))
            (should (equal "existing"
                           (with-current-buffer buffer (buffer-string))))))
      (when (and (buffer-live-p buffer)
                 (ebox-surface-buffer-mounted-p buffer))
        (ebox-unmount-buffer buffer))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-render-port-v2-rollback-throw-cannot-stop-cleanup-tail ()
  "A framework rollback throw propagates only after SPI cleanup completes."
  (let ((buffer (generate-new-buffer " *etaf-v2-rollback-throw*"))
        (input (ebox-build '(box "committed"))))
    (unwind-protect
        (progn
          (with-current-buffer buffer (insert "before"))
          (should
           (eq
            (catch 'etaf-v2-rollback-escape
              (etaf-render-port-initial
               buffer input
               (lambda (_report) (error "primary before rollback throw"))
               (lambda (_report)
                 (throw 'etaf-v2-rollback-escape 'rollback-escaped)))
              'not-escaped)
            'rollback-escaped))
          (should-not (ebox-surface-buffer-mounted-p buffer))
          (should-not (ebox-surface-buffer-observer buffer))
          (should (equal "before"
                         (with-current-buffer buffer (buffer-string)))))
      (when (and (buffer-live-p buffer)
                 (ebox-surface-buffer-mounted-p buffer))
        (ebox-unmount-buffer buffer))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-render-port-v2-cleanup-fault-keeps-primary-and-continues ()
  "A secondary rollback fault is contained while Ebox cleanup continues."
  (let ((buffer (generate-new-buffer " *etaf-v2-cleanup-fault*"))
        (input (ebox-build '(box "committed")))
        captured)
    (unwind-protect
        (progn
          (with-current-buffer buffer (insert "before"))
          (condition-case condition
              (etaf-render-port-initial
               buffer input
               (lambda (_report) (error "primary stage failure"))
               (lambda (_report) (error "secondary rollback failure")))
            (error (setq captured condition)))
          (should (equal captured '(error "primary stage failure")))
          (should-not (ebox-surface-buffer-mounted-p buffer))
          (should (equal "before"
                         (with-current-buffer buffer (buffer-string)))))
      (when (and (buffer-live-p buffer)
                 (ebox-surface-buffer-mounted-p buffer))
        (ebox-unmount-buffer buffer))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-render-port-revision-fails-closed-for-mounted-surface ()
  "Revision is zero only without a mount; mounted lookup errors stay visible."
  (let ((buffer (generate-new-buffer " *etaf-revision-contract*")))
    (unwind-protect
        (progn
          (should (zerop (etaf-render-port-revision buffer)))
          (ebox-render-to-buffer buffer (ebox-build '(box "mounted")))
          (should (> (etaf-render-port-revision buffer) 0))
          (cl-letf (((symbol-function 'ebox-surface-buffer-revision)
                     (lambda (_buffer) (error "injected report failure"))))
            (should-error (etaf-render-port-revision buffer) :type 'error))
          (cl-letf (((symbol-function 'ebox-surface-buffer-revision)
                     (lambda (_buffer) 0)))
            (should-error (etaf-render-port-revision buffer) :type 'error)))
      (when (and (buffer-live-p buffer)
                 (ebox-surface-buffer-mounted-p buffer))
        (ebox-unmount-buffer buffer))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-render-port-v2-preserves-provider-report-identity ()
  "Initial and update return the exact report seen by framework staging."
  (let ((buffer (generate-new-buffer " *etaf-v2-report-identity*"))
        initial-stage-report update-stage-report)
    (unwind-protect
        (let ((initial-report
               (etaf-render-port-initial
                buffer (ebox-build '(box "one"))
                (lambda (report) (setq initial-stage-report report))
                #'ignore)))
          (should (eq initial-report initial-stage-report))
          (let ((update-report
                 (etaf-render-port-update
                  buffer (ebox-build '(box "two"))
                  (lambda (report) (setq update-stage-report report))
                  #'ignore)))
            (should (eq update-report update-stage-report))
            (should (= (etaf-render-port-revision buffer)
                       (plist-get update-report :surface-revision)))))
      (when (and (buffer-live-p buffer)
                 (ebox-surface-buffer-mounted-p buffer))
        (ebox-unmount-buffer buffer))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

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

(ert-deftest etaf-render-port-owns-all-live-publication-routing ()
  "No ETAF module except the selected-port owner publishes directly to Ebox."
  (dolist (file (directory-files etaf-render-port-test--root t "\\.el\\'"))
    (unless (string= (file-name-nondirectory file) "etaf-render-port.el")
      (with-temp-buffer
        (insert-file-contents file)
        (let ((source (buffer-string)))
          (dolist (call '("(ebox-render-to-buffer"
                           "(ebox-commit"
                           "(ebox-surface-"))
            (should-not (string-match-p (regexp-quote call) source))))))))

(ert-deftest etaf-render-port-production-has-no-v1-render-route ()
  "Production ETAF contains no retired render-port policy or v1 helper."
  (dolist (file (directory-files etaf-render-port-test--root t "\\.el\\'"))
    (with-temp-buffer
      (insert-file-contents file)
      (let ((source (buffer-string)))
        (should-not (string-match-p "etaf-render-port-selection-policy" source))
        (should-not (string-match-p "etaf-render-port--v1" source))))))

(ert-deftest etaf-render-port-routes-standalone-renderer-mount ()
  "The no-Runtime compatibility mount uses the immutable selected port."
  (require 'etaf-renderer)
  (let ((buffer (generate-new-buffer " *etaf-standalone-port-mount*"))
        seen-input seen-viewport)
    (unwind-protect
        (cl-letf (((symbol-function 'etaf-runtime-mount) nil)
                  ((symbol-function 'etaf-render-port-initial)
                   (lambda (target input framework-stage framework-rollback
                                   &optional _observer)
                     (setq seen-input input
                           seen-viewport
                           (list ebox-viewport-width ebox-viewport-height))
                     (funcall framework-stage nil)
                     (ignore framework-rollback)
                     (list :status 'success :buffer target))))
          (should
           (eq (etaf-mount
                buffer (etaf-view (text "standalone"))
                '(:viewport-width 91 :viewport-height 17))
               buffer))
          (should (ebox-canonical-input-p seen-input))
          (should (equal seen-viewport '(91 17))))
      (when (and (buffer-live-p buffer)
                 (ebox-surface-buffer-mounted-p buffer))
        (ebox-unmount-buffer buffer))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-render-port-standalone-render-failure-creates-no-buffer ()
  "Pure lowering must fail before standalone mount allocates its target buffer."
  (require 'etaf-renderer)
  (let ((name " *etaf-standalone-render-failure*"))
    (when-let* ((buffer (get-buffer name))) (kill-buffer buffer))
    (cl-letf (((symbol-function 'etaf-runtime-mount) nil))
      (should-error (etaf-mount name 'invalid-etaf-view)
                    :type 'etaf-renderer-error))
    (should-not (get-buffer name))))

(ert-deftest etaf-render-port-selected-port-is-process-stable ()
  "Every downstream read returns the one bootstrap-selected port identity."
  (let ((selected (etaf-render-port-selected)))
    (should (eq selected (etaf-render-port-selected)))
    (should (eq (etaf-render-port-route selected) 'v2))))

(provide 'etaf-render-port-tests)

;;; etaf-render-port-tests.el ends here
