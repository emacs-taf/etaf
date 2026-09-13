;;; etaf-g1-cross-layer-tests.el --- G1 cross-layer fault gate -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'etaf)
(require 'etaf-render-port)
(require 'tp)
(require 'ebox)
(require 'ebox)
(require 'ebox)

(define-error 'etaf-g1-retirement-error "G1 retirement test error")

(defvar etaf-g1--tp-trace nil)
(defvar etaf-g1--tp-precommit-condition nil)

(defun etaf-g1--tp-precommit-probe ()
  "Record and optionally signal the G1 TP precommit fault."
  (push 'precommit etaf-g1--tp-trace)
  (when etaf-g1--tp-precommit-condition
    (signal (car etaf-g1--tp-precommit-condition)
            (cdr etaf-g1--tp-precommit-condition))))

(defconst etaf-g1--workspace-root
  (expand-file-name "../.."
                    (file-name-directory
                     (or load-file-name buffer-file-name)))
  "Workspace root used by cross-package evidence checks.")

(defconst etaf-g1-fault-matrix
  '((tp-order . etaf-g1-tp-order-precommit-and-rollback-are-atomic)
    (multi-surface . etaf-g1-tp-multi-surface-final-accept-restores-in-order)
    (combined-participant . etaf-g1-ebox-etaf-combined-participant-same-report)
    (spi-branches . etaf-g1-spi-four-branches-and-selected-port-immutability)
    (generation-host-cas . etaf-g1-generation-cas-and-host-lifecycle-guards)
    (v2-runtime-contract . etaf-g1-v2-runtime-contract)
    (runtime-fault-rollback . etaf-g1-runtime-fault-restores-authorities)
    (postcommit-diagnostics . etaf-g1-postcommit-report-fault-keeps-accepted-state)
    (host-unmount-kill . etaf-g1-host-unmount-and-kill-inflight-route)
    (nested-runtime-event . etaf-g1-nested-runtime-event-batches-once)
    (multi-context . etaf-g1-multi-context-runtimes-isolate)
    (native-fallback . etaf-g1-native-fallback-keeps-surface)
    (retirement . etaf-g1-retirement-diagnostics-are-cause-compatible))
  "Auditable G1 fault-gate coverage map.")

(defconst etaf-g1--required-fault-keys
  '(tp-order multi-surface combined-participant spi-branches
    generation-host-cas v2-runtime-contract runtime-fault-rollback
    postcommit-diagnostics host-unmount-kill nested-runtime-event multi-context
    native-fallback retirement)
  "Required unique behavior keys for the G1 cross-layer gate.")

(defun etaf-g1--cleanup-buffer (buffer-or-name)
  "Unmount and kill BUFFER-OR-NAME, signaling any cleanup failure."
  (when-let* ((runtime (etaf-runtime-for-buffer buffer-or-name)))
    (etaf-unmount runtime))
  (when-let* ((buffer (get-buffer buffer-or-name)))
    (when (ebox-surface-buffer-mounted-p buffer)
      (ebox-unmount-buffer buffer))
    (kill-buffer buffer)))

(defun etaf-g1--view (source)
  "Return a small reactive View that exposes SOURCE as styled text."
  (etaf-view
   (text :ref 'g1-value :color "red"
         (expr (format "value=%s" (etaf-value source))))))

(defun etaf-g1--normalized-property-runs (text)
  "Return TEXT property runs with backend identities normalized by topology."
  (let ((identity-map (make-hash-table :test #'equal))
        (next-identity 0)
        (position 0)
        runs)
    (cl-labels
        ((normalize
          (identity)
          (when identity
            (or (gethash identity identity-map)
                (prog1 next-identity
                  (puthash identity next-identity identity-map)
                  (cl-incf next-identity))))))
      (while (< position (length text))
        (let* ((next (or (next-property-change position text)
                         (length text)))
               (properties (copy-tree (text-properties-at position text))))
          (dolist (key '(ebox-content ebox-content-owner))
            (when (plist-member properties key)
              (setq properties
                    (plist-put properties key
                               (normalize (plist-get properties key))))))
          (when (plist-member properties 'ebox-content-owners)
            (setq properties
                  (plist-put
                   properties 'ebox-content-owners
                   (mapcar #'normalize
                           (plist-get properties 'ebox-content-owners)))))
          (push (list :from position :to next :properties properties) runs)
          (setq position next))))
    (nreverse runs)))

(defun etaf-g1--surface-snapshot (buffer)
  "Return public, rollback-sensitive rendering evidence for BUFFER."
  (let* ((text (with-current-buffer buffer
                 (buffer-substring (point-min) (point-max))))
         (semantic-text (copy-sequence text)))
    (remove-text-properties
     0 (length semantic-text)
     '(ebox-content nil ebox-content-owner nil ebox-content-owners nil)
     semantic-text)
    (list :text text
          :semantic-text semantic-text
          :property-runs (etaf-g1--normalized-property-runs text)
          :region-count (length (ebox-region-ids text))
          :mounted (ebox-surface-buffer-mounted-p buffer)
          :revision (and (ebox-surface-buffer-mounted-p buffer)
                         (ebox-surface-buffer-revision buffer))
          :report (and (ebox-surface-buffer-mounted-p buffer)
                       (ebox-buffer-update-report buffer)))))

(defun etaf-g1--report-contract (report)
  "Return route-independent committed fields from REPORT."
  (mapcar (lambda (key) (cons key (plist-get report key)))
          '(:runtime-published :surface-revision :strategy
            :render-scope :publication-scope)))

(defun etaf-g1--surface-contract (buffer)
  "Return route-independent visible surface evidence for BUFFER."
  (let ((snapshot (etaf-g1--surface-snapshot buffer)))
    (list :semantic-text (plist-get snapshot :semantic-text)
          :property-runs (plist-get snapshot :property-runs)
          :region-count (plist-get snapshot :region-count)
          :mounted (plist-get snapshot :mounted)
          :revision (plist-get snapshot :revision))))

(defun etaf-g1--runtime-host-contract (runtime)
  "Return lifecycle and route authority evidence for RUNTIME."
  (let ((authority (etaf-runtime-host-authority runtime))
        (route (etaf-runtime-route-token runtime)))
    (list :host-state (etaf-host-authority-state authority)
          :host-version (etaf-host-authority-version authority)
          :mounted (etaf-runtime-mounted-p runtime)
          :pending (etaf-runtime-pending-p runtime)
          :route-live (and (etaf-runtime-route-live-p route) t))))

(defun etaf-g1--runtime-visible-contract (runtime)
  "Return route-independent visible and authority evidence for RUNTIME."
  (append
   (etaf-g1--surface-contract (etaf-runtime-buffer runtime))
   (list :generation (etaf-runtime-generation runtime)
         :token (etaf-runtime-generation-token runtime)
         :store-versions (copy-tree (etaf-runtime-store-versions runtime)))
   (etaf-g1--runtime-host-contract runtime)))

(defun etaf-g1--runtime-state (runtime)
  "Return rollback-sensitive ETAF, Ebox, route, and store state for RUNTIME."
  (let* ((buffer (etaf-runtime-buffer runtime))
         (surface (etaf-g1--surface-snapshot buffer))
         (report (plist-get surface :report)))
    (list :visible (etaf-g1--runtime-visible-contract runtime)
          :handlers (etaf-runtime-handler-entries runtime)
          :host-props (etaf-runtime-host-props-entries runtime)
          :resource-count
          (hash-table-count (etaf-runtime-resource-registry runtime))
          :artifact-count
          (hash-table-count (etaf-runtime-artifact-registry runtime))
          :range-artifact-count
          (hash-table-count (etaf-runtime-range-artifact-registry runtime))
          :route-source-count
          (hash-table-count (etaf-runtime-route-sources runtime))
          :paint-count
          (hash-table-count (etaf-runtime-theme-paint-slots runtime))
          :behavior-count
          (hash-table-count (etaf-runtime-behaviors runtime))
          :surface-report (and report (etaf-g1--report-contract report)))))

(ert-deftest etaf-g1-fault-matrix-is-auditable ()
  (let ((keys (mapcar #'car etaf-g1-fault-matrix))
        (tests (mapcar #'cdr etaf-g1-fault-matrix)))
    (should (equal keys etaf-g1--required-fault-keys))
    (should (= (length keys) (length (delete-dups (copy-sequence keys)))))
    (should (= (length tests) (length (delete-dups (copy-sequence tests)))))
    (dolist (test tests)
      (should (symbolp test))
      (should (ert-get-test test)))))

(ert-deftest etaf-g1-tp-order-precommit-and-rollback-are-atomic ()
  "TP stages in order and reverses partial-stage and precommit faults."
  (let (etaf-g1--tp-trace)
    (let ((tp--transaction-participant-precommit-allowed-functions nil)
          (tp--transaction-precommit-functions nil))
      (should-error
       (tp-with-transaction
         (tp-transaction-participate-v2
          :key 'tp-first
          :stage (lambda () (push 'first-stage etaf-g1--tp-trace))
          :rollback (lambda () (push 'first-rollback etaf-g1--tp-trace)))
         (tp-transaction-participate-v2
          :key 'tp-second
          :stage (lambda () (push 'second-stage etaf-g1--tp-trace)
                   (error "G1 injected partial apply"))
          :rollback (lambda () (push 'second-rollback etaf-g1--tp-trace))))))
    (should
     (equal (nreverse etaf-g1--tp-trace)
            '(first-stage second-stage second-rollback first-rollback))))
  (let ((etaf-g1--tp-trace nil)
        (etaf-g1--tp-precommit-condition
         '(error "G1 injected precommit failure"))
        (tp--transaction-precommit-functions
         '(etaf-g1--tp-precommit-probe))
        (tp--transaction-precommit-allowed-functions
         '(etaf-g1--tp-precommit-probe)))
    (should-error
     (tp-with-transaction
       (tp-transaction-participate-v2
        :key 'tp-first
        :stage (lambda () (push 'first-stage etaf-g1--tp-trace))
        :rollback (lambda () (push 'first-rollback etaf-g1--tp-trace)))
       (tp-transaction-participate-v2
        :key 'tp-second
        :stage (lambda () (push 'second-stage etaf-g1--tp-trace))
        :rollback (lambda () (push 'second-rollback etaf-g1--tp-trace)))))
    (should
     (equal (nreverse etaf-g1--tp-trace)
            '(first-stage second-stage precommit
              second-rollback first-rollback)))))

(ert-deftest etaf-g1-tp-multi-surface-final-accept-restores-in-order ()
  "One TP publication updates two surfaces atomically and restores both."
  (let* ((source (tp-signal-create 0))
         (left-buffer (generate-new-buffer " *etaf-g1-tp-left*"))
         (right-buffer (generate-new-buffer " *etaf-g1-tp-right*"))
         (left nil) (right nil))
    (unwind-protect
        (progn
          (setq left
                (tp-surface-mount
                 left-buffer
                 (lambda (context)
                   (tp-object-ensure context nil 'root 'text)
                   (tp-surface-plan-create
                    :key 'root :kind 'text
                    :text (format "L%s" (tp-signal-read source))
                    :capability 'content))))
          (setq right
                (tp-surface-mount
                 right-buffer
                 (lambda (context)
                   (tp-object-ensure context nil 'root 'text)
                   (tp-surface-plan-create
                    :key 'root :kind 'text
                    :text (format "R%s" (tp-signal-read source))
                    :capability 'content))))
          (let ((left-before (with-current-buffer left-buffer (buffer-string)))
                (right-before (with-current-buffer right-buffer (buffer-string)))
                (left-revision (tp-surface-revision left))
                (right-revision (tp-surface-revision right))
                condition)
            (cl-letf (((symbol-function 'accept-change-group)
                       (lambda (&rest _)
                         (error "G1 injected final-accept failure"))))
              (setq condition
                    (condition-case error-data
                        (progn (tp-signal-set source 1) nil)
                      ((error quit) error-data))))
            (should condition)
            (should (tp-publication-failure-outcome-p
                     tp--last-transaction-outcome))
            (should (= 2
                       (length
                        (tp-publication-failure-outcome-target-results
                         tp--last-transaction-outcome))))
            (should (equal-including-properties
                     left-before (with-current-buffer left-buffer (buffer-string))))
            (should (equal-including-properties
                     right-before (with-current-buffer right-buffer (buffer-string))))
            (should (= left-revision (tp-surface-revision left)))
            (should (= right-revision (tp-surface-revision right)))
            (should (= 0 (tp-signal-peek source)))
            (should (null (tp--transaction-condition-trailer
                           condition :rollback-failures)))))
      (when (tp-surface-live-p left) (tp-surface-unmount left))
      (when (tp-surface-live-p right) (tp-surface-unmount right))
      (when (buffer-live-p left-buffer) (kill-buffer left-buffer))
      (when (buffer-live-p right-buffer) (kill-buffer right-buffer))
      (when (tp-signal-live-p source) (tp-signal-dispose source)))))

(ert-deftest etaf-g1-ebox-etaf-combined-participant-same-report ()
  "Ebox SPI callbacks share reports while TP outcomes remain observational."
  (let ((buffer (generate-new-buffer " *etaf-g1-combined*"))
        (input (ebox-build '(box "g1")))
        seen)
    (unwind-protect
        (progn
          (let ((report
                 (ebox-framework-spi-initial
                  buffer input
                  (lambda (value) (setq seen value))
                  (lambda (_value) nil))))
            (should (eq report seen))
            (should (eq (plist-get report :framework-participant-state)
                        'completed))
            (should (equal (mapcar (lambda (x) (plist-get x :provider))
                                   (ebox-framework-spi-initial-observation-reports
                                    report))
                           '(tp ebox)))
            (should (tp-committed-success-outcome-p
                     tp--last-transaction-outcome))
            (let ((first (tp--committed-success-outcome-snapshot
                          tp--last-transaction-outcome))
                  (second (tp--committed-success-outcome-snapshot
                           tp--last-transaction-outcome)))
              (should (equal first second))
              (should-not (eq first second))
              (let ((counts (plist-get first :operation-counts)))
                (should (consp counts))
                (setcar counts :g1-mutated-counts)
                (should-not (equal first second))
                (should
                 (equal second
                        (tp--committed-success-outcome-snapshot
                         tp--last-transaction-outcome)))))
            (let (update-seen update-return)
              (setq update-return
                    (ebox-framework-spi-update
                     buffer input (lambda (value) (setq update-seen value)) #'ignore))
              (should (eq update-seen update-return))
              (should (tp-committed-success-outcome-p
                       tp--last-transaction-outcome)))))
      (when (buffer-live-p buffer)
        (when (ebox-surface-buffer-mounted-p buffer)
          (ebox-unmount-buffer buffer))
        (kill-buffer buffer)))))

(ert-deftest etaf-g1-runtime-fault-restores-authorities ()
  "A semantic participant fault restores observable cross-layer authority."
  (let* ((buffer-name (generate-new-buffer-name " *etaf-g1-runtime-fault*"))
         (source (etaf-ref 0))
         (events nil)
         (failure-seen nil))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-g1--view source))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (before (etaf-g1--runtime-state runtime))
                 (old-publish (symbol-function 'etaf--runtime-participant-publish))
                 (old-rollback (symbol-function 'etaf--runtime-participant-rollback))
                 (condition nil))
            (cl-letf
                (((symbol-function 'etaf--runtime-participant-publish)
                  (lambda (participant)
                    (push 'semantic-publish events)
                    (prog1 (funcall old-publish participant)
                      (unless failure-seen
                        (setq failure-seen t)
                        (error "G1 injected semantic participant failure")))))
                 ((symbol-function 'etaf--runtime-participant-rollback)
                  (lambda (participant)
                    (push 'semantic-rollback events)
                    (funcall old-rollback participant))))
              (setq condition
                    (condition-case error-data
                        (progn (setf (etaf-value source) 1) nil)
                      ((error quit) error-data))))
            (should condition)
            (should (equal (nreverse events)
                           '(semantic-publish semantic-rollback)))
            (should
             (equal-including-properties
              before (etaf-g1--runtime-state runtime)))
            (should (etaf-host-authority-attached-p
                     (etaf-runtime-host-authority runtime)))
            (should (etaf-runtime-generation-mirrors-consistent-p runtime))
            (should (tp-publication-failure-outcome-p
                     tp--last-transaction-outcome))
            (should (null (tp--transaction-condition-trailer
                           condition :rollback-failures)))
            ;; A retry is a fresh publication, not a partial continuation of
            ;; the failed candidate.
            (etaf-runtime-flush runtime)
            (should (equal "value=1"
                           (with-current-buffer buffer-name (buffer-string))))))
      (etaf-g1--cleanup-buffer buffer-name))))

(ert-deftest etaf-g1-postcommit-report-fault-keeps-accepted-state ()
  "A report-finalization fault is diagnostic only after commit."
  (let* ((buffer-name (generate-new-buffer-name " *etaf-g1-postcommit*"))
         (source (etaf-ref 0)))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'ebox-surface--participant-complete)
                     (lambda (&rest _)
                       (error "G1 injected report finalization fault"))))
            (etaf-mount buffer-name (etaf-g1--view source)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (report (ebox-buffer-update-report buffer-name))
                 (diagnostics
                  (plist-get report :framework-participant-diagnostics)))
            (should (etaf-host-authority-attached-p
                     (etaf-runtime-host-authority runtime)))
            (should (etaf-runtime-mounted-p runtime))
            (should (= 1 (etaf-runtime-generation runtime)))
            (should (= 1 (etaf-runtime-generation-token runtime)))
            (should (equal "value=0"
                           (with-current-buffer buffer-name (buffer-string))))
            (should (cl-some
                     (lambda (entry)
                       (eq (plist-get entry :phase)
                           'framework-report-finalization))
                     diagnostics))))
      (etaf-g1--cleanup-buffer buffer-name))))

(ert-deftest etaf-g1-host-unmount-and-kill-inflight-route ()
  "Detach invalidates routes before cleanup and never revives dead buffers."
  (let* ((source (etaf-ref 0))
         (explicit-name (generate-new-buffer-name " *etaf-g1-explicit*"))
         (killed-name (generate-new-buffer-name " *etaf-g1-killed*")))
    (unwind-protect
        (progn
          (etaf-mount explicit-name (etaf-g1--view source))
          (let* ((runtime (etaf-runtime-for-buffer explicit-name))
                 (route (etaf-runtime-route-token runtime))
                 (authority (etaf-runtime-host-authority runtime)))
            (etaf-unmount runtime)
            (should (eq (etaf-host-authority-state authority) 'terminal))
            (should-not (etaf-runtime-route-live-p route))
            (should-not (etaf-runtime-for-buffer explicit-name)))
          (etaf-mount killed-name (etaf-g1--view source))
          (let* ((runtime (etaf-runtime-for-buffer killed-name))
                 (route (etaf-runtime-route-token runtime))
                 (authority (etaf-runtime-host-authority runtime)))
            ;; Hold a logical event open so the source write is in-flight;
            ;; killing the buffer must invalidate the route and drop it.
            (etaf-runtime-event-begin runtime)
            (setf (etaf-value source) 1)
            (kill-buffer (get-buffer killed-name))
            (etaf-runtime-event-end runtime)
            (should-not (etaf-runtime-mounted-p runtime))
            (should (eq (etaf-host-authority-state authority) 'terminal))
            (should-not (etaf-runtime-route-live-p route))
            (should-not (etaf-runtime-pending-p runtime))
            (should-not (gethash route (etaf-ref-subscribers source)))
            (setf (etaf-value source) 2)
            (should-not (etaf-runtime-pending-p runtime))))
      (etaf-g1--cleanup-buffer explicit-name)
      (etaf-g1--cleanup-buffer killed-name))))

(ert-deftest etaf-g1-multi-context-runtimes-isolate ()
  "Sibling render roots share a source but isolate scheduler contexts."
  (let* ((source (etaf-ref 0))
         (left-context (etaf-scheduler-context-create :name 'g1-left))
         (right-context (etaf-scheduler-context-create :name 'g1-right))
         (left-name (generate-new-buffer-name " *etaf-g1-left*"))
         (right-name (generate-new-buffer-name " *etaf-g1-right*")))
    (unwind-protect
        (progn
          (etaf-mount left-name (etaf-view (column (text "L")
                                                  (text (expr (format "%s" (etaf-value source))))))
                      (list :scheduler-context left-context))
          (etaf-mount right-name (etaf-view (column (text "R")
                                                   (box (text (expr (format "%s" (etaf-value source)))))))
                      (list :scheduler-context right-context))
          (let ((left (etaf-runtime-for-buffer left-name))
                (right (etaf-runtime-for-buffer right-name)))
            (setf (etaf-value source) 1)
            (should (= 2 (etaf-runtime-generation left)))
            (should (= 2 (etaf-runtime-generation right)))
            (should (equal "L1"
                           (replace-regexp-in-string
                            "\n" ""
                            (with-current-buffer left-name (buffer-string)))))
            (should (equal "R1"
                           (replace-regexp-in-string
                            "\n" ""
                            (with-current-buffer right-name (buffer-string)))))
            (should (etaf-scheduler-context-idle-p left-context))
            (should (etaf-scheduler-context-idle-p right-context))
            (etaf-unmount left)
            (setf (etaf-value source) 2)
            (should (= 3 (etaf-runtime-generation right)))
            (should (equal "R2"
                           (replace-regexp-in-string
                            "\n" ""
                            (with-current-buffer right-name (buffer-string)))))
            (should-not (etaf-runtime-pending-p left))))
      (etaf-g1--cleanup-buffer left-name)
      (etaf-g1--cleanup-buffer right-name))))

(ert-deftest etaf-g1-nested-runtime-event-batches-once ()
  "A nested Runtime event boundary publishes only its final source value."
  (let* ((source (etaf-ref 0))
         (buffer-name (generate-new-buffer-name " *etaf-g1-nested-event*")))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-g1--view source))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (before (etaf-runtime-generation runtime)))
            (etaf-runtime-event-begin runtime)
            (etaf-runtime-event-begin runtime)
            (setf (etaf-value source) 1)
            (should (= before (etaf-runtime-generation runtime)))
            (should (etaf-runtime-pending-p runtime))
            (etaf-runtime-event-end runtime)
            (should (= before (etaf-runtime-generation runtime)))
            (setf (etaf-value source) 2)
            (etaf-runtime-event-end runtime)
            (should (= (1+ before) (etaf-runtime-generation runtime)))
            (should-not (etaf-runtime-pending-p runtime))
            (should
             (equal "value=2"
                    (with-current-buffer buffer-name (buffer-string))))))
      (etaf-g1--cleanup-buffer buffer-name))))

(ert-deftest etaf-g1-native-fallback-keeps-surface ()
  "A forced native execution failure truthfully commits ordinary fallback."
  (let ((buffer (generate-new-buffer " *etaf-g1-native-fallback*"))
        (initial (ebox-build '(column (box :key a "A")
                                      (box :key b "B"))))
        (updated (ebox-build '(column (box :key a "A")
                                      (box :key b "B2")
                                      (box :key c "C"))))
        (native-attempts 0))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 8)
              (ebox-runtime-idle-prewarm nil)
              (ebox-runtime-idle-reflow-cache-prewarm nil))
          ;; Establish an ordinary surface, then explicitly make the
          ;; structural update eligible for native bootstrap.
          (cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p)
                     (lambda () nil)))
            (ebox-render-to-buffer buffer initial))
          (let ((before (with-current-buffer buffer (buffer-string))))
            (cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p)
                       (lambda () t))
                      ((symbol-function 'ebox-style-cascade-active-p)
                       (lambda () nil))
                      ((symbol-function 'ebox-native-reflow-create-session)
                       (lambda (&rest _)
                         (ebox-native-reflow--make-session
                          :handle 'g1-native-session
                          :generation 0
                          :layout-fragment-cache
                          (make-hash-table :test #'equal)
                          :layout-fragment-revision 0)))
                      ((symbol-function 'ebox-native-reflow-release-session)
                       (lambda (session)
                         (setf (ebox-native-reflow-session-released-p session) t)))
                      ((symbol-function 'ebox-native-reflow-execute-session-sync)
                       (lambda (&rest _)
                         (cl-incf native-attempts)
                         (error "G1 forced native failure"))))
              (let ((report (ebox-commit buffer updated)))
                (should (= native-attempts 1))
                (should (equal "AB2C"
                               (replace-regexp-in-string
                                "[[:space:]]" ""
                                (with-current-buffer buffer (buffer-string)))))
                (should (not (equal before (with-current-buffer buffer
                                             (buffer-string)))))
                (should (eq (plist-get report :strategy) 'ordinary-fallback))
                (should (eq (plist-get report :native-attempt) 'failed))
                (should (equal (plist-get report :native-fallback-reason)
                               "G1 forced native failure"))
                (should (eq (plist-get report :render-scope) 'surface))
                (should-not (plist-get report :projection-kind))
                (should-not (plist-get report :native-frame-kind))
                (should (ebox-surface-buffer-mounted-p buffer))))))
      (when (buffer-live-p buffer)
        (when (ebox-surface-buffer-mounted-p buffer)
          (ebox-unmount-buffer buffer))
        (kill-buffer buffer)))))

(ert-deftest etaf-g1-retirement-diagnostics-are-cause-compatible ()
  "Retirement errors retain the business condition and committed metadata."
  (let* ((journal
          (etaf-retirement-journal-create
           :operation-id 17 :outcome-id 18 :generation-id 19 :revision 20))
         captured)
    (condition-case condition
        (etaf-retirement-resignal
         '(etaf-g1-retirement-error "business" (:cause injected)) journal)
      (etaf-g1-retirement-error (setq captured condition)))
    (should captured)
    (should (equal (butlast (cdr captured))
                   '("business" (:cause injected))))
    (should (equal (etaf-condition-postcommit-info captured)
                   (list :kind 'postcommit :committed-p t :operation-id 17
                         :outcome-id 18 :generation-id 19 :revision 20
                         :diagnostic-journal-id
                         (etaf-retirement-journal-id journal))))))

(ert-deftest etaf-g1-spi-four-branches-and-selected-port-immutability ()
  "Absent, valid, malformed and incompatible SPI providers fail distinctly."
  (let ((selected (etaf-render-port-selected))
        (original-featurep (symbol-function 'featurep))
        (provider (ebox-framework-spi-capabilities)))
    (cl-letf (((symbol-function 'featurep)
               (lambda (feature)
                 (and (not (eq feature 'ebox-framework-spi-v2))
                      (funcall original-featurep feature))))
              ((symbol-function 'ebox-framework-spi-capabilities) nil))
      (should-error (etaf-render-port--bootstrap)
                    :type 'etaf-spi-bootstrap-error))
    (should (eq (etaf-render-port-route (etaf-render-port--bootstrap)) 'v2))
    (cl-letf (((symbol-function 'ebox-framework-spi-capabilities)
               (lambda () (error "G1 malformed provider"))))
      (should-error (etaf-render-port--bootstrap)
                    :type 'etaf-spi-bootstrap-error))
    (cl-letf (((symbol-function 'ebox-framework-spi-capabilities)
               (lambda () provider))
              ((symbol-function 'ebox-framework-spi-provider-spi-version)
               (lambda (_provider) 99)))
      (should-error (etaf-render-port--bootstrap)
                    :type 'etaf-spi-incompatible-error))
    (should (eq selected (etaf-render-port-selected)))
    (should-error (eval `(setf (etaf-render-port--route ',selected) 'v1)))))

(ert-deftest etaf-g1-generation-cas-and-host-lifecycle-guards ()
  "Generation authority rejects stale tokens and host authority is revocable."
  (let* ((authority (etaf-generation-authority-create))
         (generation (etaf--generation-create :generation-id 1))
         (token (etaf-generation-authority-token authority))
         (versions (etaf-generation-authority-store-versions authority)))
    (should (= token 0))
    (should (etaf-generation-authority-compare-and-swap
             authority nil token versions generation 1 versions))
    (should-error
     (etaf-generation-authority-compare-and-swap
      authority generation token versions
      (etaf--generation-create :generation-id 2) 2 versions)
     :type 'etaf-generation-error))
  (let ((buffer (generate-new-buffer " *g1-host*"))
        (source (etaf-ref 0)) runtime)
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-g1--view source))
          (setq runtime (etaf-runtime-for-buffer buffer))
          (let* ((host (etaf-runtime-host-authority runtime))
                 (token (etaf-host-authority-token host)))
            (should (etaf-host-authority-accepts-token-p host token))
            (etaf-unmount runtime)
            (setq runtime nil)
            (should-not (etaf-host-authority-accepts-token-p host token))))
      (when runtime (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun etaf-g1--run-selected-render-port-route ()
  "Run one lifecycle through the process-selected port and return evidence."
  (let* ((source (etaf-ref 0))
         (buffer-name (generate-new-buffer-name " *etaf-g1-route*"))
         (original-publish
          (symbol-function 'etaf--runtime-participant-publish))
         runtime initial updated rolled-back lifecycle result injected)
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-g1--view source))
          (setq runtime (etaf-runtime-for-buffer buffer-name)
                initial (etaf-g1--runtime-visible-contract runtime))
          (push (etaf-g1--runtime-host-contract runtime) lifecycle)
          (let ((initial-marker-count
                 (tp-committed-success-outcome-marker-count
                  tp--last-transaction-outcome)))
            (setf (etaf-value source) 1)
            (setq updated (etaf-g1--runtime-visible-contract runtime))
            (push (etaf-g1--runtime-host-contract runtime) lifecycle)
            (let ((update-report
                   (ebox-buffer-update-report
                    (etaf-runtime-buffer runtime)))
                  (update-marker-count
                   (tp-committed-success-outcome-marker-count
                    tp--last-transaction-outcome)))
              (cl-letf
                  (((symbol-function 'etaf--runtime-participant-publish)
                    (lambda (participant)
                      (prog1 (funcall original-publish participant)
                        (unless injected
                          (setq injected t)
                          (error "G1 failed Runtime update"))))))
                (should-error (setf (etaf-value source) 2) :type 'error))
              (should injected)
              (setq rolled-back
                    (etaf-g1--runtime-visible-contract runtime))
              (should (equal-including-properties updated rolled-back))
              (push (etaf-g1--runtime-host-contract runtime) lifecycle)
              (etaf-unmount runtime)
              (push (etaf-g1--runtime-host-contract runtime) lifecycle)
              (setq result
                    (list
                     :initial initial
                     :updated updated
                     :rolled-back rolled-back
                     :update-report
                     (etaf-g1--report-contract update-report)
                     :initial-marker-count initial-marker-count
                     :update-marker-count update-marker-count
                     :lifecycle (nreverse lifecycle))))))
      (etaf-g1--cleanup-buffer buffer-name))
    result))

(defun etaf-g1--selected-route-evidence ()
  "Return lifecycle and dispatcher evidence for the actual selected port."
  (let* ((selected (etaf-render-port-selected))
         (initial-function (etaf-render-port-initial-function selected))
         (update-function (etaf-render-port-update-function selected))
         (original-initial (symbol-function initial-function))
         (original-update (symbol-function update-function))
         (initial-calls 0)
         (update-calls 0)
         lifecycle-evidence)
    (cl-letf (((symbol-function initial-function)
               (lambda (&rest arguments)
                 (setq initial-calls (1+ initial-calls))
                 (apply original-initial arguments)))
              ((symbol-function update-function)
               (lambda (&rest arguments)
                 (setq update-calls (1+ update-calls))
                 (apply original-update arguments))))
      (setq lifecycle-evidence (etaf-g1--run-selected-render-port-route)))
    (list
     :selected-route (etaf-render-port-route selected)
     :bootstrap-outcome (etaf-render-port-bootstrap-outcome selected)
     :generation-mirror-route etaf-generation-mirror-route
     :semantic-commit-route etaf-semantic-commit-route
     :v2-feature-present (featurep 'ebox-framework-spi-v2)
     :v2-predicate-present (fboundp 'ebox-framework-spi-capabilities)
     :selected-stable (eq selected (etaf-render-port-selected))
     :initial-dispatch initial-function
     :update-dispatch update-function
     :initial-dispatch-count initial-calls
     :update-dispatch-count update-calls
     :lifecycle-evidence lifecycle-evidence)))

(defun etaf-g1--emacs-executable ()
  "Return the executable running this test process."
  (or (and invocation-directory
           (let ((path (expand-file-name invocation-name
                                         invocation-directory)))
             (and (file-executable-p path) path)))
      (executable-find invocation-name)
      (error "Cannot resolve current Emacs executable: %S" invocation-name)))

(defun etaf-g1--probe-v2-in-fresh-emacs ()
  "Bootstrap the required v2 port in a fresh Emacs and return its evidence."
  (let* ((etaf-root (expand-file-name "etaf" etaf-g1--workspace-root))
         (test-file (expand-file-name "tests/etaf-g1-cross-layer-tests.el"
                                     etaf-root))
         (load-directories
          (mapcar (lambda (directory)
                    (expand-file-name directory etaf-g1--workspace-root))
                  '("etaf" "etaf/examples" "etaf/scripts"
                    "ebox" "tp" "ecss")))
         (arguments
          (append
           '("-Q" "--batch")
           (apply #'append
                  (mapcar (lambda (directory) (list "-L" directory))
                          load-directories))
           '("--eval" "(setq load-prefer-newer t)")
           (list
            "-l" test-file
            "--eval"
            (concat
             "(princ (concat \"ETAF_G1_ROUTE_EVIDENCE:\" "
             "(base64-encode-string "
             "(prin1-to-string (etaf-g1--selected-route-evidence)) t) "
             "\"\\n\"))"))))
         status output encoded)
    (with-temp-buffer
      (setq status
            (apply #'call-process (etaf-g1--emacs-executable) nil
                   (list (current-buffer) t) nil arguments)
            output (buffer-string))
      (unless (and (integerp status) (zerop status))
        (ert-fail (format "Fresh v2 route probe failed (%S):\n%s"
                          status output)))
      (goto-char (point-min))
      (unless (re-search-forward
               "^ETAF_G1_ROUTE_EVIDENCE:\\([^[:space:]]+\\)$" nil t)
        (ert-fail (format "Fresh v2 route probe emitted no evidence:\n%s"
                          output)))
      (setq encoded (match-string-no-properties 1)))
    (read (base64-decode-string encoded))))

(ert-deftest etaf-g1-v2-runtime-contract ()
  "A fresh v2 bootstrap preserves lifecycle, identity and failed-update state."
  (let* ((v2 (etaf-g1--probe-v2-in-fresh-emacs))
         (lifecycle (plist-get v2 :lifecycle-evidence))
         (initial (plist-get lifecycle :initial))
         (updated (plist-get lifecycle :updated))
         (rolled-back (plist-get lifecycle :rolled-back))
         (host-lifecycle (plist-get lifecycle :lifecycle)))
    (should (eq (plist-get v2 :selected-route) 'v2))
    (should (eq (plist-get v2 :bootstrap-outcome)
                'valid-v2-selected))
    (should (plist-get v2 :v2-feature-present))
    (should (plist-get v2 :v2-predicate-present))
    (should (eq (plist-get v2 :generation-mirror-route) 'project))
    (should (eq (plist-get v2 :semantic-commit-route) 'cas))
    (should (plist-get v2 :selected-stable))
    (should (eq (plist-get v2 :initial-dispatch)
                'ebox-framework-spi-initial))
    (should (eq (plist-get v2 :update-dispatch)
                'ebox-framework-spi-update))
    (should (= 1 (plist-get v2 :initial-dispatch-count)))
    (should (= 2 (plist-get v2 :update-dispatch-count)))
    (should (equal (plist-get initial :semantic-text) "value=0"))
    (should (equal (plist-get updated :semantic-text) "value=1"))
    (should (equal-including-properties updated rolled-back))
    (should (= 4 (length host-lifecycle)))
    (should (eq (plist-get (car host-lifecycle) :host-state) 'attached))
    (should (eq (plist-get (car (last host-lifecycle)) :host-state) 'terminal))
    (should (= 1 (plist-get lifecycle :initial-marker-count)))
    (should (= 0 (plist-get lifecycle :update-marker-count)))))

(provide 'etaf-g1-cross-layer-tests)
;;; etaf-g1-cross-layer-tests.el ends here
