;;; etaf-scheduler-tests.el --- M3a dispatcher context gates -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'cl-lib)
(require 'ert)
(require 'etaf)

(define-error 'etaf-scheduler-test-condition
  "ETAF scheduler test condition")
(define-error 'etaf-scheduler-test-source-condition
  "ETAF scheduler source test condition")
(define-error 'etaf-scheduler-test-projection-condition
  "ETAF scheduler projection test condition")
(define-error 'etaf-scheduler-test-body-condition
  "ETAF scheduler body test condition")
(define-error 'etaf-scheduler-test-render-recovery-condition
  "ETAF scheduler render recovery condition")

(etaf-define-component etaf-scheduler-test-pair (&key left right)
  "Render reactive LEFT and RIGHT values."
  :view
  (text (expr (format "%s/%s" (etaf-value left) (etaf-value right)))))

(etaf-define-component etaf-scheduler-test-single (&key source)
  "Render one reactive SOURCE."
  :view (text (expr (etaf-value source))))

(etaf-define-component etaf-scheduler-test-data (&key controller)
  "Render CONTROLLER status, item count, and total."
  :view
  (text
   (expr
    (format "%s:%d:%d"
            (etaf-value (etaf-data-status controller))
            (length (etaf-value (etaf-data-items controller)))
            (etaf-value (etaf-data-total controller))))))

(etaf-define-component etaf-scheduler-test-data-projection-failure
    (&key controller)
  "Fail rendering when CONTROLLER reaches success."
  :render
  (let ((status (etaf-value (etaf-data-status controller))))
    (when (eq status 'success)
      (signal 'etaf-scheduler-test-projection-condition '("projection")))
    (etaf-node 'text nil (list (symbol-name status)))))

(etaf-define-component etaf-scheduler-test-render-recovery
    (&key source fail)
  "Render SOURCE unless FAIL requests a deterministic render error."
  :render
  (progn
    (when (etaf-value fail)
      (signal 'etaf-scheduler-test-render-recovery-condition
              '("expected render failure" :payload recovery)))
    (etaf-node 'text nil (list (format "Value %s" (etaf-value source))))))

(defun etaf-scheduler-test--text (buffer-name)
  "Return BUFFER-NAME text without properties."
  (with-current-buffer buffer-name
    (substring-no-properties (buffer-string))))

(defun etaf-scheduler-test--metric (context key)
  "Return scheduler CONTEXT metric KEY."
  (plist-get (etaf-scheduler-context-metrics context) key))

(defun etaf-scheduler-test--source (symbol)
  "Return Lisp source text defining SYMBOL."
  (let* ((loaded (symbol-file symbol 'defun))
         (source (if (and loaded (string-suffix-p ".elc" loaded))
                     (substring loaded 0 -1)
                   loaded)))
    (with-temp-buffer
      (insert-file-contents source)
      (buffer-string))))

(ert-deftest etaf-scheduler-is-the-only-dispatch-state-owner ()
  "Reactive semantics use the scheduler and own no process-global queues."
  (let ((reactive (etaf-scheduler-test--source 'etaf--dispatch-source))
        (scheduler
         (etaf-scheduler-test--source 'etaf-scheduler-context-create)))
    (should-not (string-match-p "(defvar etaf--dispatch-" reactive))
    (dolist (field '("source-queue" "runtime-queue" "effect-set"
                     "active-turn-id" "projection-epoch" "fault-state"))
      (should (string-match-p field scheduler)))))

(ert-deftest etaf-scheduler-shared-sources-fan-out-once-per-context ()
  "Two changed refs schedule each isolated Runtime exactly once."
  (let* ((left-buffer " *etaf-scheduler-left*")
         (left-peer-buffer " *etaf-scheduler-left-peer*")
         (right-buffer " *etaf-scheduler-right*")
         (left-context (etaf-scheduler-context-create :name 'left))
         (right-context (etaf-scheduler-context-create :name 'right))
         (left (etaf-ref "A"))
         (right (etaf-ref "1"))
         (view (etaf--view-call
                'etaf-scheduler-test-pair
                (list :left left :right right) nil)))
    (unwind-protect
        (progn
          (etaf-mount left-buffer view
                      (list :scheduler-context left-context))
          (etaf-mount left-peer-buffer view
                      (list :scheduler-context left-context))
          (etaf-mount right-buffer view
                      (list :scheduler-context right-context))
          (let* ((left-runtime (etaf-runtime-for-buffer left-buffer))
                 (left-peer-runtime
                  (etaf-runtime-for-buffer left-peer-buffer))
                 (right-runtime (etaf-runtime-for-buffer right-buffer))
                 (left-generation (etaf-runtime-generation left-runtime))
                 (left-peer-generation
                  (etaf-runtime-generation left-peer-runtime))
                 (right-generation (etaf-runtime-generation right-runtime))
                 (left-source-before
                  (etaf-scheduler-test--metric
                   left-context :source-enqueues))
                 (right-source-before
                  (etaf-scheduler-test--metric
                   right-context :source-enqueues))
                 (left-runtime-before
                  (etaf-scheduler-test--metric
                   left-context :runtime-enqueues))
                 (right-runtime-before
                  (etaf-scheduler-test--metric
                   right-context :runtime-enqueues)))
            (should (eq left-context
                        (etaf-runtime-scheduler-context left-runtime)))
            (should (eq right-context
                        (etaf-runtime-scheduler-context right-runtime)))
            (etaf-reactive-call-with-batch
             (lambda ()
               (setf (etaf-value left) "B")
               (setf (etaf-value right) "2")))
            (should (equal "B/2" (etaf-scheduler-test--text left-buffer)))
            (should (equal "B/2"
                           (etaf-scheduler-test--text left-peer-buffer)))
            (should (equal "B/2" (etaf-scheduler-test--text right-buffer)))
            (should (= 1 (- (etaf-runtime-generation left-runtime)
                            left-generation)))
            (should (= 1 (- (etaf-runtime-generation left-peer-runtime)
                            left-peer-generation)))
            (should (= 1 (- (etaf-runtime-generation right-runtime)
                            right-generation)))
            (should (= 2 (- (etaf-scheduler-test--metric
                             left-context :source-enqueues)
                            left-source-before)))
            (should (= 2 (- (etaf-scheduler-test--metric
                             right-context :source-enqueues)
                            right-source-before)))
            (should (= 2 (- (etaf-scheduler-test--metric
                             left-context :runtime-enqueues)
                            left-runtime-before)))
            (should (= 1 (- (etaf-scheduler-test--metric
                             right-context :runtime-enqueues)
                            right-runtime-before)))
            (should (etaf-scheduler-context-idle-p left-context))
            (should (etaf-scheduler-context-idle-p right-context))))
      (dolist (buffer-name
               (list left-buffer left-peer-buffer right-buffer))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
          (etaf-unmount runtime))
        (when-let* ((buffer (get-buffer buffer-name)))
          (kill-buffer buffer))))))

(ert-deftest etaf-scheduler-cross-context-computed-settles-before-runtime ()
  "A computed in one context settles before another context publishes."
  (let* ((buffer-name " *etaf-scheduler-computed*")
         (computed-context
          (etaf-scheduler-context-create :name 'computed-owner))
         (runtime-context
          (etaf-scheduler-context-create :name 'computed-consumer))
         (base (etaf-ref 1))
         (computed
          (etaf-scheduler-call-with-context
           computed-context
           (lambda ()
             (etaf-computed (lambda () (* 2 (etaf-value base))))))))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf--view-call
            'etaf-scheduler-test-pair
            (list :left base :right computed) nil)
           (list :scheduler-context runtime-context))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-generation runtime))
                 (executions
                  (etaf-scheduler-test--metric
                   runtime-context :runtime-executions)))
            (should (eq computed-context
                        (etaf-effect-scheduler-context
                         (etaf-computed-effect computed))))
            (setf (etaf-value base) 2)
            (should (equal "2/4"
                           (etaf-scheduler-test--text buffer-name)))
            (should (= 1 (- (etaf-runtime-generation runtime) generation)))
            (should (= 1 (- (etaf-scheduler-test--metric
                             runtime-context :runtime-executions)
                            executions)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer))
      (etaf--stop-effect (etaf-computed-effect computed)))))

(ert-deftest etaf-scheduler-context-fault-does-not-suppress-peer ()
  "A failing context is contained until every peer receives the source."
  (let* ((source (etaf-ref 0))
         (left-context (etaf-scheduler-context-create :name 'fault-left))
         (right-context (etaf-scheduler-context-create :name 'fault-right))
         (fail-p nil)
         (right-value nil)
         left-effect right-effect captured)
    (setq left-effect
          (etaf-scheduler-call-with-context
           left-context
           (lambda ()
             (etaf-reactive-effect-create
              (lambda ()
                (prog1 (etaf-value source)
                  (when fail-p
                    (signal 'etaf-scheduler-test-condition '("left")))))))))
    (setq right-effect
          (etaf-scheduler-call-with-context
           right-context
           (lambda ()
             (etaf-reactive-effect-create
              (lambda () (setq right-value (etaf-value source)))))))
    (unwind-protect
        (progn
          (etaf-reactive-effect-run left-effect)
          (etaf-reactive-effect-run right-effect)
          (setq fail-p t)
          (condition-case condition
              (setf (etaf-value source) 1)
            (etaf-scheduler-test-condition (setq captured condition)))
          (should captured)
          (should (= right-value 1))
          (should (eq (car (etaf-scheduler-context-fault-state left-context))
                      'etaf-scheduler-test-condition))
          (should-not (etaf-scheduler-context-fault-state right-context))
          (should (etaf-scheduler-context-idle-p left-context))
          (should (etaf-scheduler-context-idle-p right-context)))
      (etaf--stop-effect left-effect)
      (etaf--stop-effect right-effect))))

(ert-deftest etaf-scheduler-body-error-precedes-drain-error-and-quit-drains ()
  "Body failure wins over drain failure; quit still drains queued effects."
  (let* ((context (etaf-scheduler-context-create :name 'precedence))
         (source (etaf-ref 0))
         (quit-source (etaf-ref 0))
         (fail-p nil) (quit-seen nil) finalizer-ran summary
         effect quit-effect captured quit-captured)
    (setq effect
          (etaf-scheduler-call-with-context
           context
           (lambda ()
             (etaf-reactive-effect-create
              (lambda ()
                (prog1 (etaf-value source)
                  (when fail-p
                    (signal 'etaf-scheduler-test-condition '("drain")))))))))
    (setq quit-effect
          (etaf-scheduler-call-with-context
           context
           (lambda ()
             (etaf-reactive-effect-create
              (lambda ()
                (setq quit-seen (etaf-value quit-source)))))))
    (unwind-protect
        (progn
          (etaf-reactive-effect-run effect)
          (etaf-reactive-effect-run quit-effect)
          (setq fail-p t)
          (let ((etaf-scheduler-projection-observer
                 (lambda (value) (setq summary value))))
            (condition-case condition
                (etaf-reactive-call-with-batch
                 (lambda ()
                   (etaf-scheduler-defer-finalizer
                    (lambda () (error "contained finalizer")))
                   (etaf-scheduler-defer-finalizer
                    (lambda () (setq finalizer-ran t)))
                   (setf (etaf-value source) 1)
                   (signal 'etaf-scheduler-test-body-condition '("body"))))
              (etaf-scheduler-test-body-condition
               (setq captured condition))))
          (should (equal captured
                         '(etaf-scheduler-test-body-condition "body")))
          (should finalizer-ran)
          (should (= 1 (length (plist-get summary :finalizer-errors))))
          (should (eq (car (etaf-scheduler-context-fault-state context))
                      'etaf-scheduler-test-condition))
          (setq fail-p nil)
          (condition-case condition
              (etaf-reactive-call-with-batch
               (lambda ()
                 (setf (etaf-value quit-source) 1)
                 (signal 'quit nil)))
            (quit (setq quit-captured condition)))
          (should (eq (car quit-captured) 'quit))
          (should (= quit-seen 1))
          (should (etaf-scheduler-context-idle-p context)))
      (etaf--stop-effect effect)
      (etaf--stop-effect quit-effect))))

(ert-deftest etaf-scheduler-reentrant-source-runs-in-following-turn ()
  "A same-source reentrant write is deferred to one following turn."
  (let* ((context (etaf-scheduler-context-create :name 'reentrant))
         (source (etaf-ref 0))
         values turns effect)
    (setq effect
          (etaf-scheduler-call-with-context
           context
           (lambda ()
             (etaf-reactive-effect-create
              (lambda ()
                (let ((value (etaf-value source)))
                  (push value values)
                  (push (etaf-scheduler-context-active-turn-id context)
                        turns)
                  (when (= value 1)
                    (setf (etaf-value source) 2))))))))
    (unwind-protect
        (progn
          (etaf-reactive-effect-run effect)
          (let ((deliveries
                 (etaf-scheduler-test--metric
                  context :source-deliveries))
                (turn-count
                 (etaf-scheduler-test--metric context :turn-count)))
            (setf (etaf-value source) 1)
            (should (equal '(0 1 2) (nreverse values)))
            (should (equal '(0 1 2) (nreverse turns)))
            (should (= 2 (- (etaf-scheduler-test--metric
                             context :source-deliveries)
                            deliveries)))
            (should (= 2 (- (etaf-scheduler-test--metric
                             context :turn-count)
                            turn-count)))))
      (etaf--stop-effect effect))))

(ert-deftest etaf-scheduler-cross-context-cycle-is-bounded-and-reusable ()
  "Cross-context ping-pong fails at the exact budget and leaves idle contexts."
  (let* ((left-context
          (etaf-scheduler-context-create
           :name 'cycle-left :fixed-point-step-budget 3))
         (right-context
          (etaf-scheduler-context-create
           :name 'cycle-right :fixed-point-step-budget 3))
         (left-source (etaf-ref 0))
         (right-source (etaf-ref 0))
         left-effect right-effect captured recovery-effect)
    (setq left-effect
          (etaf-scheduler-call-with-context
           left-context
           (lambda ()
             (etaf-reactive-effect-create
              (lambda ()
                (let ((value (etaf-value left-source)))
                  (when (> value 0)
                    (setf (etaf-value right-source) value))))))))
    (setq right-effect
          (etaf-scheduler-call-with-context
           right-context
           (lambda ()
             (etaf-reactive-effect-create
              (lambda ()
                (let ((value (etaf-value right-source)))
                  (when (> value 0)
                    (setf (etaf-value left-source) (1+ value)))))))))
    (unwind-protect
        (progn
          (etaf-reactive-effect-run left-effect)
          (etaf-reactive-effect-run right-effect)
          (condition-case condition
              (setf (etaf-value left-source) 1)
            (etaf-scheduler-error (setq captured condition)))
          (should captured)
          (should (eq 'fixed-point-step-budget
                      (plist-get (cdr captured) :kind)))
          (should (= 4 (plist-get (cdr captured) :steps)))
          (should (= 3 (plist-get (cdr captured) :budget)))
          (should (etaf-scheduler-context-idle-p left-context))
          (should (etaf-scheduler-context-idle-p right-context))
          (etaf--stop-effect left-effect)
          (etaf--stop-effect right-effect)
          (let ((recovery-source (etaf-ref 0)) (seen nil))
            (setq recovery-effect
                  (etaf-scheduler-call-with-context
                   left-context
                   (lambda ()
                     (etaf-reactive-effect-create
                      (lambda ()
                        (setq seen (etaf-value recovery-source)))))))
            (etaf-reactive-effect-run recovery-effect)
            (setf (etaf-value recovery-source) 1)
            (should (= seen 1))
            (should-not
             (etaf-scheduler-context-fault-state left-context))))
      (when (and left-effect (etaf-effect-active-p left-effect))
        (etaf--stop-effect left-effect))
      (when (and right-effect (etaf-effect-active-p right-effect))
        (etaf--stop-effect right-effect))
      (when recovery-effect (etaf--stop-effect recovery-effect)))))

(ert-deftest etaf-scheduler-data-success-is-one-turn-per-context ()
  "One Data success projection coalesces all changed refs in each context."
  (let* ((left-buffer " *etaf-scheduler-data-left*")
         (right-buffer " *etaf-scheduler-data-right*")
         (left-context (etaf-scheduler-context-create :name 'data-left))
         (right-context (etaf-scheduler-context-create :name 'data-right))
         left-runtime-before right-runtime-before
         (source
          (etaf-data-source
           :load
           (lambda (_query _page _page-size)
             (setq left-runtime-before
                   (etaf-scheduler-test--metric
                    left-context :runtime-enqueues)
                   right-runtime-before
                   (etaf-scheduler-test--metric
                    right-context :runtime-enqueues))
             (list :items '(one two three) :total 9))))
         (controller (etaf-data-controller source))
         (view (etaf--view-call
                'etaf-scheduler-test-data
                (list :controller controller) nil)))
    (unwind-protect
        (progn
          (etaf-mount left-buffer view
                      (list :scheduler-context left-context))
          (etaf-mount right-buffer view
                      (list :scheduler-context right-context))
          (etaf-data-load controller)
          (should (equal "success:3:9"
                         (etaf-scheduler-test--text left-buffer)))
          (should (equal "success:3:9"
                         (etaf-scheduler-test--text right-buffer)))
          (should (= 1 (- (etaf-scheduler-test--metric
                           left-context :runtime-enqueues)
                          left-runtime-before)))
          (should (= 1 (- (etaf-scheduler-test--metric
                           right-context :runtime-enqueues)
                          right-runtime-before))))
      (dolist (buffer-name (list left-buffer right-buffer))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
          (etaf-unmount runtime))
        (when-let* ((buffer (get-buffer buffer-name)))
          (kill-buffer buffer)))
      (etaf-data-stop controller))))

(ert-deftest etaf-scheduler-data-separates-source-and-projection-errors ()
  "Source failure sets Data error; render failure leaves successful refs."
  (let* ((buffer-name " *etaf-scheduler-data-projection-error*")
         (context (etaf-scheduler-context-create :name 'data-projection))
         (source
          (etaf-data-source
           :load (lambda (_query _page _page-size)
                   (list :items '(committed) :total 1))))
         (controller (etaf-data-controller source))
         projection-condition)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf--view-call
            'etaf-scheduler-test-data-projection-failure
            (list :controller controller) nil)
           (list :scheduler-context context))
          (condition-case condition
              (etaf-data-load controller)
            (etaf-scheduler-test-projection-condition
             (setq projection-condition condition)))
          (should projection-condition)
          (should (eq 'success
                      (etaf-value (etaf-data-status controller))))
          (should-not (etaf-value (etaf-data-error controller)))
          (should (equal '(committed)
                         (etaf-value (etaf-data-items controller))))
          (should (equal "loading"
                         (etaf-scheduler-test--text buffer-name))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer))
      (etaf-data-stop controller)))
  (let* ((source
          (etaf-data-source
           :load (lambda (_query _page _page-size)
                   (signal 'etaf-scheduler-test-source-condition
                           '("source")))))
         (controller (etaf-data-controller source))
         captured)
    (unwind-protect
        (progn
          (condition-case condition
              (etaf-data-load controller)
            (etaf-scheduler-test-source-condition
             (setq captured condition)))
          (should captured)
          (should (eq 'error (etaf-value (etaf-data-status controller))))
          (should (equal captured
                         (etaf-value (etaf-data-error controller)))))
      (etaf-data-stop controller))))

(ert-deftest etaf-scheduler-render-failure-keeps-retry-fifo-coherent ()
  "A failed Component evaluation retries and visibly recovers on new state."
  (let* ((buffer-name " *etaf-scheduler-render-recovery*")
         (source (etaf-ref "A"))
         (fail (etaf-ref nil))
         captured)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf--view-call
            'etaf-scheduler-test-render-recovery
            (list :source source :fail fail) nil))
          (setf (etaf-value source) "B")
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-generation runtime))
                 (revision
                  (plist-get (ebox-buffer-update-report buffer-name)
                             :surface-revision))
                 (contents
                  (with-current-buffer buffer-name (buffer-string))))
            (condition-case condition
                (setf (etaf-value fail) t)
              (etaf-scheduler-test-render-recovery-condition
               (setq captured condition)))
            (should
             (equal captured
                    '(etaf-scheduler-test-render-recovery-condition
                      "expected render failure" :payload recovery)))
            (should (= generation (etaf-runtime-generation runtime)))
            (should (= revision
                       (plist-get (ebox-buffer-update-report buffer-name)
                                  :surface-revision)))
            (should (equal-including-properties
                     contents (with-current-buffer buffer-name
                                (buffer-string))))
            (should
             (equal (sort (hash-table-keys
                           (etaf-runtime-dirty-effect-ids runtime)) #'<)
                    (sort (copy-sequence
                           (etaf-runtime-dirty-effect-queue runtime)) #'<)))
            (etaf-reactive-call-with-batch
             (lambda ()
               (setf (etaf-value fail) nil)
               (setf (etaf-value source) "C")))
            (should (equal "Value C"
                           (etaf-scheduler-test--text buffer-name)))
            (should (= (1+ generation)
                       (etaf-runtime-generation runtime)))
            (should (= (1+ revision)
                       (plist-get (ebox-buffer-update-report buffer-name)
                                  :surface-revision)))
            (should-not (hash-table-keys
                         (etaf-runtime-dirty-effect-ids runtime)))
            (should-not (etaf-runtime-dirty-effect-queue runtime))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-scheduler-detached-route-does-not-enter-fan-out ()
  "An invalidated Runtime route cannot enqueue work in its old context."
  (let* ((buffer-name " *etaf-scheduler-stale-route*")
         (context (etaf-scheduler-context-create :name 'stale))
         (source (etaf-ref "A")))
    (etaf-mount
     buffer-name
     (etaf--view-call 'etaf-scheduler-test-single (list :source source) nil)
     (list :scheduler-context context))
    (let* ((runtime (etaf-runtime-for-buffer buffer-name))
           (route (etaf-runtime-route-token runtime)))
      (etaf-unmount runtime)
      (let ((before (etaf-scheduler-test--metric context :source-enqueues)))
        (should-not (etaf-runtime-route-active-p route))
        (setf (etaf-value source) "B")
        (should (= before
                   (etaf-scheduler-test--metric
                    context :source-enqueues)))))
    (when-let* ((buffer (get-buffer buffer-name)))
      (kill-buffer buffer))))

(ert-deftest etaf-scheduler-stale-authority-is-filtered-before-fan-out ()
  "Registry, token, attaching, and detached mismatches enqueue no source."
  (let* ((buffer-name " *etaf-scheduler-stale-authority*")
         (context (etaf-scheduler-context-create :name 'stale-authority))
         (source (etaf-ref "A")))
    (etaf-mount
     buffer-name
     (etaf--view-call 'etaf-scheduler-test-single (list :source source) nil)
     (list :scheduler-context context))
    (let* ((runtime (etaf-runtime-for-buffer buffer-name))
           (route (etaf-runtime-route-token runtime))
           (epoch (etaf-runtime-mount-epoch runtime))
           (authority (etaf-runtime-host-authority runtime))
           (slots (etaf-host-authority-slots authority))
           (token (etaf-runtime-route-authority-token route))
           (state (etaf-host-authority-state authority))
           (drops (etaf-scheduler-test--metric
                   context :stale-route-drops))
           (assert-drop
            (lambda (value)
              (let ((before (etaf-scheduler-test--metric
                             context :source-enqueues)))
                (setf (etaf-value source) value)
                (should (= before
                           (etaf-scheduler-test--metric
                            context :source-enqueues)))))))
      (unwind-protect
          (progn
            (remhash epoch etaf--runtime-route-registry)
            (funcall assert-drop "missing-registry")
            (puthash epoch runtime etaf--runtime-route-registry)
            (setf (etaf-runtime-route-authority-token route)
                  (make-symbol "stale-token"))
            (funcall assert-drop "wrong-token")
            (setf (etaf-runtime-route-authority-token route) token)
            (aset slots 0 'attaching)
            (funcall assert-drop "attaching")
            (aset slots 0 'detached)
            (funcall assert-drop "detached")
            (aset slots 0 state)
            (should (= 4 (- (etaf-scheduler-test--metric
                             context :stale-route-drops)
                            drops)))
            (setf (etaf-value source) "live")
            (should (equal "live"
                           (etaf-scheduler-test--text buffer-name))))
        (puthash epoch runtime etaf--runtime-route-registry)
        (setf (etaf-runtime-route-authority-token route) token)
        (aset slots 0 state)
        (when (etaf-runtime-mounted-p runtime)
          (etaf-unmount runtime))))
    (when-let* ((buffer (get-buffer buffer-name)))
      (kill-buffer buffer))))

(ert-deftest etaf-scheduler-operation-report-exposes-cost-counters ()
  "Observed operations expose scheduler enqueue, dedupe, and turn costs."
  (let* ((buffer-name " *etaf-scheduler-observer*")
         (peer-buffer " *etaf-scheduler-observer-peer*")
         (context (etaf-scheduler-context-create :name 'observer))
         (peer-context
          (etaf-scheduler-context-create :name 'observer-peer))
         (left (etaf-ref "A"))
         (right (etaf-ref "1"))
         reports)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf--view-call
            'etaf-scheduler-test-pair
            (list :left left :right right) nil)
           (list :scheduler-context context
                 :observer (lambda (report) (push report reports))))
          (etaf-mount
           peer-buffer
           (etaf--view-call
            'etaf-scheduler-test-pair
            (list :left left :right right) nil)
           (list :scheduler-context peer-context))
          (setq reports nil)
          (let ((runtime (etaf-runtime-for-buffer buffer-name)))
            (etaf-runtime-call-operation
             runtime 'scheduler-test "scheduler counters"
             (lambda ()
               (etaf-reactive-call-with-batch
                (lambda ()
                  (setf (etaf-value left) "B")
                  (setf (etaf-value right) "2")))))
            (let ((final (car reports)))
              (should (eq 'runtime-operation (plist-get final :stage)))
              (should (= (etaf-scheduler-context-id context)
                         (plist-get final :scheduler-context-id)))
              (should (= 2 (plist-get final :scheduler-source-enqueues)))
              (should (= 2 (plist-get final :scheduler-source-deliveries)))
              (should (= 2 (plist-get final :scheduler-subscriber-visits)))
              (should (= 1 (plist-get final :scheduler-runtime-enqueues)))
              (should (= 1 (plist-get final :scheduler-runtime-dedupes)))
              (should (= 1 (plist-get final :scheduler-runtime-executions)))
              (should (= 1 (plist-get final :scheduler-turns)))
              (let ((projection
                     (car (plist-get final :scheduler-projections))))
                (should (= 2 (plist-get projection :context-count)))
                (should (= 4 (plist-get projection :source-enqueues)))
                (should (= 4 (plist-get projection :subscriber-visits)))
                (should (= 2 (plist-get projection :runtime-executions))))
              (should (> (plist-get final :scheduler-projection-epoch-after)
                         (plist-get final
                                    :scheduler-projection-epoch-before))))))
      (dolist (name (list buffer-name peer-buffer))
        (when-let* ((runtime (etaf-runtime-for-buffer name)))
          (when (eq name buffer-name)
            (etaf-runtime-set-observer runtime nil))
          (etaf-unmount runtime))
        (when-let* ((buffer (get-buffer name)))
          (kill-buffer buffer))))))

(ert-deftest etaf-scheduler-real-flush-defers-final-report-to-projection-end ()
  "A direct ref write reports the complete cross-context projection."
  (let* ((buffer-name " *etaf-scheduler-real-flush*")
         (peer-buffer " *etaf-scheduler-real-flush-peer*")
         (context (etaf-scheduler-context-create :name 'real-flush))
         (peer-context
          (etaf-scheduler-context-create :name 'real-flush-peer))
         (source (etaf-ref "A")) reports)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf--view-call
            'etaf-scheduler-test-single (list :source source) nil)
           (list :scheduler-context context
                 :observer (lambda (report) (push report reports))))
          (etaf-mount
           peer-buffer
           (etaf--view-call
            'etaf-scheduler-test-single (list :source source) nil)
           (list :scheduler-context peer-context))
          (setq reports nil)
          (setf (etaf-value source) "B")
          (let* ((final (car reports))
                 (projection
                  (car (plist-get final :scheduler-projections))))
            (should (eq 'runtime-operation (plist-get final :stage)))
            (should (= 2 (plist-get projection :context-count)))
            (should (= 2 (plist-get projection :source-enqueues)))
            (should (= 2 (plist-get projection :subscriber-visits)))
            (should (= 2 (plist-get projection :runtime-executions)))
            (should (equal "B" (etaf-scheduler-test--text buffer-name)))
            (should (equal "B" (etaf-scheduler-test--text peer-buffer)))))
      (dolist (name (list buffer-name peer-buffer))
        (when-let* ((runtime (etaf-runtime-for-buffer name)))
          (when (equal name buffer-name)
            (etaf-runtime-set-observer runtime nil))
          (etaf-unmount runtime))
        (when-let* ((buffer (get-buffer name)))
          (kill-buffer buffer))))))

(ert-deftest etaf-scheduler-scale-matrix-scans-each-subscriber-once ()
  "Source-by-context fan-out has exact linear subscriber and effect costs."
  (let* ((contexts
          (cl-loop for index below 4
                   collect (etaf-scheduler-context-create
                            :name (list 'scale index))))
         (sources (cl-loop repeat 40 collect (etaf-ref 0)))
         effects summary
         (started (float-time)))
    (unwind-protect
        (progn
          (dolist (context contexts)
            (let ((effect
                   (etaf-scheduler-call-with-context
                    context
                    (lambda ()
                      (etaf-reactive-effect-create
                       (lambda ()
                         (mapcar #'etaf-value sources)))))))
              (push effect effects)
              (etaf-reactive-effect-run effect)))
          (let ((etaf-scheduler-projection-observer
                 (lambda (value) (setq summary value))))
            (etaf-reactive-call-with-batch
             (lambda ()
               (cl-loop for source in sources
                        for value from 1
                        do (setf (etaf-value source) value)))))
          (should (= 4 (plist-get summary :context-count)))
          (should (= 160 (plist-get summary :source-enqueues)))
          (should (= 160 (plist-get summary :source-deliveries)))
          (should (= 160 (plist-get summary :subscriber-visits)))
          (should (= 4 (plist-get summary :effect-claims)))
          (should (= 4 (plist-get summary :effect-evaluations)))
          (should (= 4 (plist-get summary :turns)))
          (should (< (* 1000.0 (- (float-time) started)) 1000.0)))
      (dolist (effect effects) (etaf--stop-effect effect)))))

(ert-deftest etaf-scheduler-fifo-cost-counters-are-linear ()
  "A bounded synthetic turn records one enqueue and one dedupe per key."
  (let* ((context (etaf-scheduler-context-create :name 'cost))
         (sources (cl-loop repeat 500 collect (list (make-symbol "source"))))
         (started (float-time)))
    (etaf-scheduler-call-with-projection
     (lambda ()
       (dolist (source sources)
         (etaf-scheduler-enqueue-source context source #'ignore)
         (etaf-scheduler-enqueue-source context source #'ignore))))
    (let ((elapsed-ms (* 1000.0 (- (float-time) started))))
      (should (= 500 (etaf-scheduler-test--metric
                      context :source-enqueues)))
      (should (= 500 (etaf-scheduler-test--metric
                      context :source-dedupes)))
      (should (< elapsed-ms 1000.0))
      (should (etaf-scheduler-context-idle-p context)))))

(provide 'etaf-scheduler-tests)

;;; etaf-scheduler-tests.el ends here
