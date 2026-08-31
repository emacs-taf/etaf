;;; etaf-generation-tests.el --- M3a generation authority gates -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'etaf)
(require 'etaf-generation)

(etaf-define-component etaf-generation-test-dependency-only (&key source)
  "Track SOURCE while producing an equal Ebox artifact."
  :view
  (text (expr (progn (etaf-value source) "same"))))

(etaf-define-component etaf-generation-test-visible (&key source)
  "Render SOURCE as visible text for semantic conflict tests."
  :view
  (text (expr (format "value=%s" (etaf-value source)))))

(defun etaf-generation-test--view (visible)
  "Return a root View selected by reactive VISIBLE."
  (if (etaf-value visible)
      (etaf-view
       (text :ref 'generation-target :role 'button
             :on-press #'ignore "visible"))
    (etaf-view (text :ref 'generation-other "other"))))

(ert-deftest etaf-generation-authority-is-runtime-single-source ()
  "Runtime compatibility access reads and writes one authority object."
  (let* ((runtime (etaf--runtime-create))
         (first (etaf--generation-create :generation-id 1))
         (second (etaf--generation-create :generation-id 2)))
    (should-not (etaf-runtime-current-generation runtime))
    (setf (etaf-runtime-current-generation runtime) first)
    (let ((authority (etaf-runtime-generation-authority runtime)))
      (should (etaf-generation-authority-p authority))
      (should (eq first (etaf-generation-authority-current authority)))
      (should (eq first (etaf-runtime-current-generation runtime)))
      (setf (etaf-runtime-current-generation runtime) second)
      (should (eq authority (etaf-runtime-generation-authority runtime)))
      (should (eq second (etaf-runtime-current-generation runtime)))
      (should (zerop (etaf-generation-authority-token authority))))))

(ert-deftest etaf-generation-projection-is-detached-and-rejects-duplicates ()
  "Compatibility projections copy facts and reject ambiguous keys."
  (let* ((handlers '((host . ((press . callback)))))
         (projection
          (etaf-generation-project-mirrors handlers '((host :role button))))
         (handler-table (plist-get projection :handlers))
         (props-table (plist-get projection :host-props)))
    (setcdr (car handlers) 'mutated)
    (should (equal (gethash 'host handler-table) '((press . callback))))
    (should (equal (gethash 'host props-table) '(:role button)))
    (should-error
     (etaf-generation-project-mirror '((host . one) (host . two)))
     :type 'etaf-generation-error)))

(ert-deftest etaf-generation-mirrors-follow-committed-generation ()
  "Every commit projects exact mirrors and removes stale Host facts."
  (let ((buffer-name " *etaf-generation-mirror-test*")
        (visible (etaf-ref t)))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (lambda () (etaf-generation-test--view visible)))
          (let ((runtime (etaf-runtime-for-buffer buffer-name)))
            (should (etaf-runtime-generation-mirrors-consistent-p runtime))
            (should (etaf-runtime-handler-for runtime 'generation-target))
            (should (gethash 'generation-target
                             (etaf-runtime-handlers runtime)))
            (setf (etaf-value visible) nil)
            (should (etaf-runtime-generation-mirrors-consistent-p runtime))
            (should-not (etaf-runtime-handler-for runtime 'generation-target))
            (should-not (gethash 'generation-target
                                 (etaf-runtime-handlers runtime)))
            (should (gethash 'generation-other
                             (etaf-runtime-host-props runtime)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-generation-query-ignores-compatibility-mirror-drift ()
  "Corrupting a mirror never changes committed generation queries."
  (let ((buffer-name " *etaf-generation-query-test*")
        (visible (etaf-ref t)))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (lambda () (etaf-generation-test--view visible)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (committed
                  (copy-tree
                   (etaf-runtime-handler-for runtime 'generation-target))))
            (puthash 'generation-target 'corrupt
                     (etaf-runtime-handlers runtime))
            (should-not (etaf-runtime-generation-mirrors-consistent-p runtime))
            (should (equal committed
                           (etaf-runtime-handler-for
                            runtime 'generation-target)))
            (setf (etaf-value visible) nil)
            (setf (etaf-value visible) t)
            (should (etaf-runtime-generation-mirrors-consistent-p runtime))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-generation-shadow-route-proves-legacy-equivalence ()
  "The shadow route accepts a legacy projection only when facts are equal."
  (let ((buffer-name " *etaf-generation-shadow-test*")
        (visible (etaf-ref t))
        (etaf-generation-mirror-route 'shadow))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (lambda () (etaf-generation-test--view visible)))
          (setf (etaf-value visible) nil)
          (let ((runtime (etaf-runtime-for-buffer buffer-name)))
            (should (etaf-runtime-generation-mirrors-consistent-p runtime))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-generation-rejects-unknown-mirror-route ()
  "An unknown compatibility route cannot silently publish mirrors."
  (let ((runtime (etaf--runtime-create
                  :generation-authority
                  (etaf-generation-authority-create)))
        (etaf-generation-mirror-route 'unknown))
    (should-error
     (etaf--runtime-install-generation-mirrors runtime nil t)
     :type 'etaf-generation-error)))

(ert-deftest etaf-semantic-candidate-cas-and-rollback-are-exactly-once ()
  "CAS stages generation/token/versions together and rollback restores all."
  (let* ((old (list 'old-generation))
         (next (list 'next-generation))
         (authority (etaf-generation-authority-create old))
         (candidate
          (etaf-semantic-candidate-create
           authority next 7 11 13 17)))
    (etaf-semantic-candidate-stage candidate)
    (should (eq next (etaf-generation-authority-current authority)))
    (should (= (etaf-generation-authority-token authority) 1))
    (should
     (equal (etaf-generation-authority-store-versions authority)
            (etaf-semantic-candidate-candidate-store-versions candidate)))
    (should-error (etaf-semantic-candidate-stage candidate)
                  :type 'etaf-generation-error)
    (etaf-semantic-candidate-rollback candidate)
    (should (eq old (etaf-generation-authority-current authority)))
    (should (zerop (etaf-generation-authority-token authority)))
    (should
     (equal (etaf-generation-authority-store-versions authority)
            (etaf-semantic-candidate-expected-store-versions candidate)))
    (etaf-semantic-candidate-rollback candidate)
    (should-error (etaf-semantic-candidate-commit candidate)
                  :type 'etaf-generation-error)))

(ert-deftest etaf-semantic-candidate-rejects-stale-authority-snapshots ()
  "Generation, token, and store-version conflicts fail before authority swap."
  (dolist (kind '(generation token stores))
    (let* ((old (list 'old-generation))
           (next (list 'next-generation))
           (authority (etaf-generation-authority-create old))
           (candidate
            (etaf-semantic-candidate-create authority next 1 2 3 4)))
      (pcase kind
        ('generation
         (etaf-generation-authority-set-current authority (list 'foreign)))
        ('token
         (setf (etaf-generation-authority-token authority) 9))
        ('stores
         (setf (etaf-generation-authority-store-versions authority)
               (etaf-generation-store-versions-next
                (etaf-generation-authority-store-versions authority)))))
      (should-error (etaf-semantic-candidate-stage candidate)
                    :type 'etaf-generation-conflict)
      (should (eq (etaf-semantic-candidate-state candidate) 'prepared)))))

(ert-deftest etaf-semantic-candidate-commit-is-terminal ()
  "A committed semantic candidate cannot rollback or commit twice."
  (let* ((authority (etaf-generation-authority-create 'old))
         (candidate
          (etaf-semantic-candidate-create authority 'next 1 2 3 4)))
    (etaf-semantic-candidate-stage candidate)
    (etaf-semantic-candidate-commit candidate)
    (should (eq (etaf-semantic-candidate-state candidate) 'committed))
    (should-error (etaf-semantic-candidate-commit candidate)
                  :type 'etaf-generation-error)
    (should-error (etaf-semantic-candidate-rollback candidate)
                  :type 'etaf-generation-error)
    (should (eq (etaf-generation-authority-current authority) 'next))))

(ert-deftest etaf-semantic-only-commit-advances-token-without-ebox-or-tp ()
  "Equal output commits semantic token/version only, with no surface revision."
  (let ((buffer-name " *etaf-semantic-token-test*")
        (source (etaf-ref 0))
        (ebox-updates 0))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf--view-call 'etaf-generation-test-dependency-only
                            (list :source source) nil))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (surface (with-current-buffer buffer-name
                            (car tp--buffer-surfaces)))
                 (generation (etaf-runtime-generation runtime))
                 (token (etaf-runtime-generation-token runtime))
                 (versions (etaf-runtime-store-versions runtime))
                 (revision (tp-surface-revision surface))
                 (original
                  (symbol-function 'etaf-render-port-update)))
            (cl-letf (((symbol-function 'etaf-render-port-update)
                       (lambda (&rest arguments)
                         (cl-incf ebox-updates)
                         (apply original arguments))))
              (setf (etaf-value source) 1))
            (should (= (1+ generation)
                       (etaf-runtime-generation runtime)))
            (should (= (1+ token)
                       (etaf-runtime-generation-token runtime)))
            (should
             (equal (etaf-generation-store-versions-next versions)
                    (etaf-runtime-store-versions runtime)))
            (should (zerop ebox-updates))
            (should (= revision (tp-surface-revision surface)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-semantic-store-conflict-restores-and-retries ()
  "A stale store version leaves generation/buffer old and a fresh retry wins."
  (let ((buffer-name " *etaf-semantic-conflict-test*")
        (source (etaf-ref 0)))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf--view-call 'etaf-generation-test-visible
                            (list :source source) nil))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (authority (etaf-runtime-generation-authority runtime))
                 (generation (etaf-runtime-current-generation runtime))
                 (token (etaf-runtime-generation-token runtime))
                 (versions (etaf-runtime-store-versions runtime))
                 (original
                  (symbol-function 'etaf--runtime-participant-publish)))
            (cl-letf
                (((symbol-function 'etaf--runtime-participant-publish)
                  (lambda (participant)
                    (setf (etaf-generation-authority-store-versions authority)
                          (etaf-generation-store-versions-next versions))
                    (funcall original participant))))
              (should-error (setf (etaf-value source) 1)
                            :type 'etaf-generation-conflict))
            (should (eq generation
                        (etaf-runtime-current-generation runtime)))
            (should (= token (etaf-runtime-generation-token runtime)))
            (should (equal "value=0"
                           (with-current-buffer buffer-name
                             (buffer-string))))
            (etaf-runtime-flush runtime)
            (should (= (1+ token) (etaf-runtime-generation-token runtime)))
            (should (equal "value=1"
                           (with-current-buffer buffer-name
                             (buffer-string))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-semantic-postcommit-mirror-failure-keeps-token-committed ()
  "A postcommit mirror error cannot reverse generation/token or TP facts."
  (let ((buffer-name " *etaf-semantic-postcommit-test*")
        (source (etaf-ref 0)))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf--view-call 'etaf-generation-test-dependency-only
                            (list :source source) nil))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (surface (with-current-buffer buffer-name
                            (car tp--buffer-surfaces)))
                 (generation (etaf-runtime-generation runtime))
                 (token (etaf-runtime-generation-token runtime))
                 (revision (tp-surface-revision surface)))
            (cl-letf
                (((symbol-function 'etaf--runtime-install-generation-mirrors)
                  (lambda (&rest _arguments)
                    (error "injected postcommit mirror failure"))))
              (should-error (setf (etaf-value source) 1) :type 'error))
            (should (= (1+ generation)
                       (etaf-runtime-generation runtime)))
            (should (= (1+ token)
                       (etaf-runtime-generation-token runtime)))
            (should (= revision (tp-surface-revision surface)))
            (should (equal "same"
                           (with-current-buffer buffer-name
                             (buffer-string))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-semantic-render-rollback-restores-all-authority-in-callback ()
  "Framework rollback restores token, stores, and journals before TP returns."
  (let ((buffer-name " *etaf-semantic-render-rollback-test*")
        (source (etaf-ref 0))
        rollback-evidence)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf--view-call 'etaf-generation-test-visible
                            (list :source source) nil))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-current-generation runtime))
                 (token (etaf-runtime-generation-token runtime))
                 (versions (etaf-runtime-store-versions runtime))
                 (original-precommit
                  (symbol-function 'tp--run-transaction-precommit-functions))
                 (original-rollback
                  (symbol-function 'etaf--runtime-participant-rollback)))
            (cl-letf
                (((symbol-function 'tp--run-transaction-precommit-functions)
                  (lambda ()
                    (funcall original-precommit)
                    (error "injected precommit failure")))
                 ((symbol-function 'etaf--runtime-participant-rollback)
                  (lambda (participant)
                    (prog1 (funcall original-rollback participant)
                      (let* ((semantic
                              (etaf--generation-participant-semantic-candidate
                               participant))
                             (inverse
                              (etaf-semantic-candidate-inverse-journal semantic)))
                        (setq rollback-evidence
                              (list
                               :generation
                               (eq generation
                                   (etaf-runtime-current-generation runtime))
                               :token
                               (= token (etaf-runtime-generation-token runtime))
                               :versions
                               (equal versions
                                      (etaf-runtime-store-versions runtime))
                               :candidate-state
                               (etaf-semantic-candidate-state semantic)
                               :journal-state
                               (plist-get inverse :state))))))))
              (should-error (setf (etaf-value source) 1) :type 'error))
            (should
             (equal rollback-evidence
                    '(:generation t :token t :versions t
                      :candidate-state rolled-back
                      :journal-state rolled-back)))
            (should (equal "value=0"
                           (with-current-buffer buffer-name
                             (buffer-string))))
            (etaf-runtime-flush runtime)
            (should (equal "value=1"
                           (with-current-buffer buffer-name
                             (buffer-string))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-semantic-legacy-and-shadow-routes-remain-recoverable ()
  "Legacy keeps its token while shadow validates and advances the CAS token."
  (dolist (route '(legacy shadow))
    (let ((buffer-name
           (format " *etaf-semantic-%s-route-test*" route))
          (source (etaf-ref 0))
          (etaf-semantic-commit-route route))
      (unwind-protect
          (progn
            (etaf-mount
             buffer-name
             (etaf--view-call 'etaf-generation-test-visible
                              (list :source source) nil))
            (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                   (generation (etaf-runtime-generation runtime))
                   (token (etaf-runtime-generation-token runtime)))
              (setf (etaf-value source) 1)
              (should (= (1+ generation)
                         (etaf-runtime-generation runtime)))
              (should (= (etaf-runtime-generation-token runtime)
                         (if (eq route 'legacy) token (1+ token))))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
          (etaf-unmount runtime))
        (when-let* ((buffer (get-buffer buffer-name)))
          (kill-buffer buffer))))))

(provide 'etaf-generation-tests)

;;; etaf-generation-tests.el ends here
