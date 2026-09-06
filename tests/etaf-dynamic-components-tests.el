;;; etaf-dynamic-components-tests.el --- Dynamic View ownership -*- lexical-binding: t; -*-

;;; Commentary:
;; Ordinary structural expressions use the same retained Components as DSL
;; calls.  These tests exercise identity, local publication, and retirement.

;;; Code:

(require 'ert)
(require 'etaf)

(defvar etaf-dynamic-test-setups nil)
(defvar etaf-dynamic-test-disposals nil)
(defvar etaf-dynamic-test-hooks nil)
(defvar etaf-dynamic-test-actions nil)

(etaf-define-component etaf-dynamic-test-counter (&key label)
  :setup
  (let ((count (etaf-ref 0)) (initial label))
    (push (cons initial count) etaf-dynamic-test-setups)
    (etaf-on-scope-dispose
     (lambda () (push initial etaf-dynamic-test-disposals)))
    (etaf-on-mounted
     (lambda () (push (cons initial 'mounted) etaf-dynamic-test-hooks)))
    (etaf-on-updated
     (lambda () (push (cons initial 'updated) etaf-dynamic-test-hooks)))
    (etaf-on-unmounted
     (lambda () (push (cons initial 'unmounted) etaf-dynamic-test-hooks)))
    count)
  :render
  (let ((count (etaf-state)) (snapshot label))
    (etaf-node
     'box
     (list :on-press
           (lambda ()
             (push snapshot etaf-dynamic-test-actions)
             (setf (etaf-value count) (1+ (etaf-value count)))))
     (list (format "%s:%d" label (etaf-value count))))))

(etaf-define-component etaf-dynamic-test-owner (&key source)
  :view (column (expr (etaf-value source))))

(etaf-define-component etaf-dynamic-test-slot-inner ()
  :view (column (slot (text "FALLBACK"))))

(etaf-define-component etaf-dynamic-test-slot-outer (&key label)
  :view
  (etaf-dynamic-test-slot-inner
    (box :ref 'etaf-dynamic-slot-snapshot
         :on-press (let ((snapshot (list label (not (null (etaf-current-slots))))))
                     (lambda () (push snapshot etaf-dynamic-test-actions)))
      (text (expr (or label "EMPTY")))
      (text (expr (if (etaf-current-slot 'default) "HAS-SLOT" "NO-SLOT"))))))

(etaf-define-component etaf-dynamic-test-context-provider (&key cell)
  :setup (progn (etaf-provide 'etaf-dynamic-slot-context "INNER") nil)
  :view (column (slot) (expr (funcall cell))))

(etaf-define-component etaf-dynamic-test-context-reader ()
  :setup (etaf-inject 'etaf-dynamic-slot-context "ROOT")
  :view (text (expr (etaf-state))))

(etaf-define-component etaf-dynamic-test-context-author (&key label cell)
  :view
  (etaf-dynamic-test-context-provider :cell cell
    (text (expr (concat (etaf-inject 'etaf-dynamic-slot-context "ROOT")
                        ":" (etaf-value label))))
    (etaf-dynamic-test-context-reader)))

(etaf-define-component etaf-dynamic-test-pure (&key label)
  :view (text (expr label)))

(etaf-define-component etaf-dynamic-test-pair ()
  :view (fragment (etaf-dynamic-test-counter :label "A")
                  (etaf-dynamic-test-counter :label "B")))

(etaf-define-component etaf-dynamic-test-range-pair (&key left right)
  :view (fragment (etaf-dynamic-test-owner :source left)
                  (etaf-dynamic-test-owner :source right)))

(etaf-define-component etaf-dynamic-test-wrapper (&key label)
  :view (column (etaf-dynamic-test-counter :label label)))

(defun etaf-dynamic-test--counter (label &optional key)
  "Return one counter description for LABEL with optional KEY."
  (etaf-node 'etaf-dynamic-test-counter
             (append (list :label label) (and key (list :key key))) nil))

(etaf-define-component etaf-dynamic-test-programmatic-keyed-item (&key entry)
  :render
  (etaf-node 'column (list :key (car entry))
             (list (etaf-node 'row nil
                              (list (etaf-dynamic-test--counter (cdr entry)))))))

(defun etaf-dynamic-test--text (buffer)
  "Return the visible text in BUFFER."
  (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-dynamic-test--close (buffer)
  "Unmount and kill test BUFFER if it exists."
  (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
    (etaf-unmount runtime))
  (when (buffer-live-p buffer) (kill-buffer buffer)))

(defmacro etaf-dynamic-test--with-runtime (view &rest body)
  "Mount VIEW, evaluate BODY with buffer/runtime bindings, then dispose."
  (declare (indent 1) (debug (form body)))
  `(let ((buffer (generate-new-buffer " *etaf-dynamic-test*"))
         (etaf-dynamic-test-setups nil)
         (etaf-dynamic-test-disposals nil)
         (etaf-dynamic-test-hooks nil)
         (etaf-dynamic-test-actions nil))
     (unwind-protect
         (progn
           (etaf-mount buffer ,view)
           (let ((runtime (etaf-runtime-for-buffer buffer)))
             ,@body))
       (etaf-dynamic-test--close buffer))))

(etaf-define-component etaf-dynamic-test-snapshot-owner
    (&key label rows width palette calls)
  :setup (etaf-theme-provide palette)
  :render
  (progn
    (cl-incf (aref calls 0))
    (etaf-view
     (column :width (etaf-value width) :color (etaf-theme-token :fg)
       (text (expr (progn (cl-incf (aref calls 1)) (etaf-value label))))
       (expr (progn
               (cl-incf (aref calls 2))
               (mapcar (lambda (value) (etaf-node 'text nil (list value)))
                       (etaf-value rows))))))))

(defun etaf-dynamic-test--snapshot-text (node)
  "Return the material text strings below public canonical NODE."
  (if (ebox-text-node-p node)
      (list (substring-no-properties (ebox-text-node-value node)))
    (mapcan #'etaf-dynamic-test--snapshot-text (ebox-box-node-children node))))

(defun etaf-dynamic-test--paint-foreground (buffer color)
  "Read COLOR's currently published foreground in BUFFER."
  (if (tp-paint-slot-p color)
      (with-current-buffer buffer
        (plist-get (cadr (assq (tp-paint-slot-face color) face-remapping-alist))
                   :foreground))
    color))

(ert-deftest etaf-dynamic-components-snapshot-observes-local-publications ()
  "Explicit exports observe Text, props, Range, and Theme without evaluating."
  (let ((label (etaf-ref "A")) (rows (etaf-ref '("R1")))
        (width (etaf-ref '(120)))
        (palette (etaf-ref '(:fg "#111111")))
        (calls (vector 0 0 0)))
    (etaf-dynamic-test--with-runtime
        (etaf-view (etaf-dynamic-test-snapshot-owner
                     :label label :rows rows :width width
                     :palette palette :calls calls))
      (cl-labels
          ((check (expected-text expected-width expected-color)
             (let ((generation (etaf-runtime-current-generation runtime))
                   (revision (etaf-render-port-revision buffer))
                   (before (copy-sequence calls)) snapshot)
               (cl-letf (((symbol-function 'etaf-render-port-update)
                          (lambda (&rest _) (error "Snapshot published")))
                         ((symbol-function 'etaf--runtime-render-root-turn)
                          (lambda (&rest _) (error "Snapshot rebuilt Root"))))
                 (setq snapshot (etaf-runtime-snapshot runtime)))
               (should (eq generation (etaf-runtime-current-generation runtime)))
               (should (= revision (plist-get snapshot :revision)))
               (should (= revision (etaf-render-port-revision buffer)))
               (should (equal before calls))
               (should (= 1 (aref calls 0)))
               (let* ((input (plist-get snapshot :input))
                      (root (car (ebox-canonical-input-roots input)))
                      (color (ebox-style-node-specified-value input :color)))
                 (should (equal expected-text
                                (etaf-dynamic-test--snapshot-text root)))
                 (should (equal expected-width
                                (ebox-style-node-specified-value input :width)))
                 (should (equal expected-color
                                (etaf-dynamic-test--paint-foreground buffer color))))
               snapshot)))
        (let* ((initial (check '("A" "R1") '(120) "#111111"))
               (initial-input (plist-get initial :input)))
          (setf (etaf-value label) "B")
          (check '("B" "R1") '(120) "#111111")
          (setf (etaf-value width) '(140))
          (check '("B" "R1") '(140) "#111111")
          (setf (etaf-value rows) '("R2" "R3"))
          (check '("B" "R2" "R3") '(140) "#111111")
          (setf (etaf-value palette) '(:fg "#eeeeee"))
          (let ((current (check '("B" "R2" "R3") '(140) "#eeeeee")))
            (should (= (plist-get initial :mount-id)
                       (plist-get current :mount-id)))
            (should (string-match-p "R3" (ebox-render (plist-get current :input)))))
          (cl-letf (((symbol-function 'etaf--runtime-swap-generation)
                     (lambda (&rest _) (error "Reject Host property candidate"))))
            (should-error (setf (etaf-value width) '(160))))
          (check '("B" "R2" "R3") '(140) "#eeeeee")
          (setf (etaf-value width) '(140))
          (should (equal '("A" "R1")
                         (etaf-dynamic-test--snapshot-text
                          (car (ebox-canonical-input-roots initial-input)))))
          (should (equal '(120)
                         (ebox-style-node-specified-value initial-input :width)))
          ;; The obsolete getter remains a current read, without a stored mirror.
          (should (equal '("B" "R2" "R3")
                         (etaf-dynamic-test--snapshot-text
                          (funcall 'etaf-runtime-root-node runtime)))))))))

(etaf-define-component etaf-dynamic-test-theme-projection
    (&key width palette transform calls)
  :setup (etaf-theme-provide palette)
  :render
  (progn
    (cl-incf (aref calls 0))
    (etaf-view
     (column :width (if width (etaf-value width) '(120))
             :color (etaf-theme-token :fg nil transform)
       (text "Content")))))

(defun etaf-dynamic-test--snapshot-color (runtime)
  "Read RUNTIME's canonical root color through the public snapshot API."
  (ebox-style-node-specified-value
   (plist-get (etaf-runtime-snapshot runtime) :input) :color))

(ert-deftest etaf-dynamic-components-host-projection-retains-paint-slot ()
  "Compiled width changes retain the original Theme paint contribution."
  (require 'bytecomp)
  (let* ((width (etaf-ref '(120)))
         (palette (etaf-ref '(:fg "#112233")))
         (calls (vector 0))
         (change-width (byte-compile (lambda (next) (setf (etaf-value width) next)))))
    (etaf-dynamic-test--with-runtime
        (etaf-view (etaf-dynamic-test-theme-projection
                     :width width :palette palette :calls calls))
      (let ((slot (etaf-dynamic-test--snapshot-color runtime)))
        (should (tp-paint-slot-p slot))
        (cl-letf (((symbol-function 'tp-paint-slot-create)
                   (lambda (&rest _) (ert-fail "Reprojection allocated a paint slot"))))
          (funcall change-width '(140)))
        ;; Ebox declarations compare opaque TP paint addresses by their face,
        ;; not the copied record's installation/spec publication metadata.
        (should (eq (tp-paint-slot-face slot)
                    (tp-paint-slot-face (etaf-dynamic-test--snapshot-color runtime))))
        (setf (etaf-value palette) '(:fg "#445566"))
        (should (eq (tp-paint-slot-face slot)
                    (tp-paint-slot-face (etaf-dynamic-test--snapshot-color runtime))))
        (should (equal "#445566" (etaf-dynamic-test--paint-foreground buffer slot)))
        (should (= 1 (aref calls 0)))))))

(ert-deftest etaf-dynamic-components-host-projection-collects-transform-reads ()
  "A transform's new reactive reads belong to the reprojected Host effect."
  (require 'bytecomp)
  (let* ((width (etaf-ref '(120)))
         (palette (etaf-ref '(:fg "#112233")))
         (extra (etaf-ref "#445566"))
         (flags (vector nil)) (calls (vector 0))
         (transform (byte-compile
                     (lambda (value)
                       (if (aref flags 0) (etaf-value extra) value)))))
    (etaf-dynamic-test--with-runtime
        (etaf-view (etaf-dynamic-test-theme-projection
                     :width width :palette palette :transform transform :calls calls))
      (aset flags 0 t)
      (setf (etaf-value width) '(140))
      (setf (etaf-value extra) "#778899")
      (let ((color (etaf-dynamic-test--snapshot-color runtime)))
        (should (equal "#778899"
                       (etaf-dynamic-test--paint-foreground buffer color))))
      (should (= 1 (aref calls 0))))))

(ert-deftest etaf-dynamic-components-host-projection-rejects-transform-writes ()
  "Both property and Theme-only turns reject writes before any publication."
  (require 'bytecomp)
  (dolist (property-turn '(nil t))
    (dolist (reject-publication '(nil t))
      (let* ((width (and property-turn (etaf-ref '(120))))
             (palette (etaf-ref '(:fg "#112233")))
             (target (etaf-ref 0)) (flags (vector nil)) (calls (vector 0))
             (transform (byte-compile
                         (lambda (value)
                           (when (aref flags 0) (setf (etaf-value target) 1))
                           value)))
             (change (byte-compile
                      (lambda ()
                        (if width (setf (etaf-value width) '(140))
                          (setf (etaf-value palette) '(:fg "#445566")))))))
        (etaf-dynamic-test--with-runtime
            (etaf-view (etaf-dynamic-test-theme-projection
                         :width width :palette palette
                         :transform transform :calls calls))
          (let ((generation (etaf-runtime-current-generation runtime))
                (revision (etaf-render-port-revision buffer))
                (published (with-current-buffer buffer (buffer-string)))
                (slot (etaf-dynamic-test--snapshot-color runtime)))
            (aset flags 0 t)
            (if reject-publication
                (cl-letf (((symbol-function 'etaf--runtime-swap-generation)
                           (lambda (&rest _) (error "Reject candidate"))))
                  (should-error (funcall change) :type 'etaf-render-write-error))
              (should-error (funcall change) :type 'etaf-render-write-error))
            (should (= 0 (etaf-value target)))
            (should (eq generation (etaf-runtime-current-generation runtime)))
            (should (= revision (etaf-render-port-revision buffer)))
            (should (equal-including-properties
                     published (with-current-buffer buffer (buffer-string))))
            (should (eq slot (etaf-dynamic-test--snapshot-color runtime)))
            (should (equal "#112233" (etaf-dynamic-test--paint-foreground buffer slot)))
            (aset flags 0 nil)
            (if width (setf (etaf-value width) '(120))
              (setf (etaf-value palette) '(:fg "#112233")))
            (should (= 1 (aref calls 0)))))))))

(ert-deftest etaf-dynamic-components-snapshot-rejects-uncommitted-lifecycle ()
  "Unmounted and transactional reads fail; detached exports survive remount."
  (with-temp-buffer
    (should-error (etaf-runtime-snapshot) :type 'etaf-runtime-error))
  (etaf-dynamic-test--with-runtime (etaf-view (text "Original"))
    (let* ((snapshot (with-current-buffer buffer (etaf-runtime-snapshot)))
           (revision (plist-get snapshot :revision))
           (generation (etaf-runtime-current-generation runtime)))
      (tp-with-transaction
        (should-error (etaf-runtime-snapshot runtime)))
      (should (= revision (etaf-render-port-revision buffer)))
      (should (eq generation (etaf-runtime-current-generation runtime)))
      (etaf-unmount runtime)
      (cl-letf (((symbol-function 'etaf-render-port-snapshot)
                 (lambda (&rest _) (ert-fail "Unmounted query reached Ebox"))))
        (should-error (etaf-runtime-snapshot runtime) :type 'etaf-runtime-error)
        (should-error (etaf-runtime-flush runtime) :type 'etaf-runtime-error))
      (etaf-mount buffer (etaf-view (text "Replacement")))
      (let ((replacement (etaf-runtime-snapshot (etaf-runtime-for-buffer buffer))))
        (should-not (= (plist-get snapshot :mount-id)
                       (plist-get replacement :mount-id))))
      (should (equal '("Original")
                     (etaf-dynamic-test--snapshot-text
                      (car (ebox-canonical-input-roots
                            (plist-get snapshot :input)))))))))

(ert-deftest etaf-dynamic-components-snapshot-does-not-drain-batched-inputs ()
  "A query observes the last publication while a reactive batch is pending."
  (let ((label (etaf-ref "Before")))
    (etaf-dynamic-test--with-runtime (etaf-view (text (expr (etaf-value label))))
      (let ((revision (etaf-render-port-revision buffer)))
        (etaf-reactive-call-with-batch
         (lambda ()
           (setf (etaf-value label) "After")
           (let ((snapshot (etaf-runtime-snapshot runtime)))
             (should (= revision (plist-get snapshot :revision)))
             (should (equal '("Before")
                            (etaf-dynamic-test--snapshot-text
                             (car (ebox-canonical-input-roots
                                   (plist-get snapshot :input)))))))))
        (should (equal "After" (etaf-dynamic-test--text buffer)))
        (should (> (etaf-render-port-revision buffer) revision))))))

(ert-deftest etaf-dynamic-components-flush-busy-returns-committed-revision ()
  "A busy flush returns the last publication and never implicitly exports."
  (let ((label (etaf-ref "Before")))
    (etaf-dynamic-test--with-runtime (etaf-view (text (expr (etaf-value label))))
      (let ((revision (etaf-render-port-revision buffer)))
        (cl-letf (((symbol-function 'etaf-runtime-snapshot)
                   (lambda (&rest _) (ert-fail "Flush exported Runtime")))
                  ((symbol-function 'etaf-render-port-snapshot)
                   (lambda (&rest _) (ert-fail "Flush exported Ebox")))
                  ((symbol-function 'etaf--runtime-render-root-turn)
                   (lambda (&rest _) (ert-fail "Flush rebuilt Root"))))
          (should (= revision (etaf-runtime-flush runtime)))
          (unwind-protect
              (progn
                (setf (etaf-runtime-event-depth runtime) 1)
                (setf (etaf-value label) "After")
                (should (= revision (etaf-runtime-flush runtime)))
                (should (etaf-runtime-pending-p runtime))
                (should (equal "Before" (etaf-dynamic-test--text buffer))))
            (setf (etaf-runtime-event-depth runtime) 0))
          (should (> (etaf-runtime-flush runtime) revision))
          (should (equal "After" (etaf-dynamic-test--text buffer)))
          (should (= (etaf-render-port-revision buffer)
                     (etaf-runtime-flush runtime))))))))

(ert-deftest etaf-dynamic-components-removed-slot-selects-fallback ()
  (let ((source (etaf-ref (etaf-node 'etaf-dynamic-test-slot-inner
                                     nil '("Supplied")))))
    (etaf-dynamic-test--with-runtime (lambda () (etaf-value source))
      (should (equal "Supplied" (etaf-dynamic-test--text buffer)))
      (setf (etaf-value source)
            (etaf-node 'etaf-dynamic-test-slot-inner nil nil))
      (should (equal "FALLBACK" (etaf-dynamic-test--text buffer))))))

(ert-deftest etaf-dynamic-components-empty-candidate-props-and-slots ()
  "Slot programs observe present empty inputs in their caller's environment."
  (let* ((children (list "Supplied"))
         (source (etaf-ref (etaf-node 'etaf-dynamic-test-slot-outer
                                      '(:label "A") children))))
    (etaf-dynamic-test--with-runtime (lambda () (etaf-value source))
      (should (string-match-p "A.*HAS-SLOT" (etaf-dynamic-test--text buffer)))
      (setf (etaf-value source)
            (etaf-node 'etaf-dynamic-test-slot-outer nil children))
      (should (string-match-p "EMPTY.*HAS-SLOT" (etaf-dynamic-test--text buffer)))
      (setf (etaf-value source)
            (etaf-node 'etaf-dynamic-test-slot-outer nil nil))
      (should (string-match-p "EMPTY.*NO-SLOT" (etaf-dynamic-test--text buffer)))
      (etaf-dispatch-event runtime 'etaf-dynamic-slot-snapshot 'press)
      (should (equal '((nil nil)) etaf-dynamic-test-actions)))))

(ert-deftest etaf-dynamic-components-empty-candidate-inputs-rollback ()
  "Rejected empty inputs leave the published caller snapshot intact."
  (let* ((original (etaf-node 'etaf-dynamic-test-slot-outer
                             '(:label "A") '("Supplied")))
         (source (etaf-ref original)))
    (etaf-dynamic-test--with-runtime (lambda () (etaf-value source))
      (let ((generation (etaf-runtime-current-generation runtime))
            (published (with-current-buffer buffer (buffer-string))))
        (cl-letf (((symbol-function 'etaf--runtime-swap-generation)
                   (lambda (&rest _) (error "Reject empty input candidate"))))
          (should-error
           (setf (etaf-value source)
                 (etaf-node 'etaf-dynamic-test-slot-outer nil nil))))
        (should (eq generation (etaf-runtime-current-generation runtime)))
        (should (equal-including-properties
                 published (with-current-buffer buffer (buffer-string))))
        (etaf-dispatch-event runtime 'etaf-dynamic-slot-snapshot 'press)
        (should (equal '(("A" t)) etaf-dynamic-test-actions))
        (setf (etaf-value source) original)
        (setf (etaf-value source)
              (etaf-node 'etaf-dynamic-test-slot-outer nil nil))
        (should (string-match-p "EMPTY.*NO-SLOT" (etaf-dynamic-test--text buffer)))))))

(ert-deftest etaf-dynamic-components-root-slot-context-matches-component-author ()
  "Root-owned slots use root Context while ordinary factories use consumers."
  (dolist (wrapped '(nil t))
    (let ((label (etaf-ref "A"))
          (cell (lambda ()
                  (etaf-view (etaf-dynamic-test-context-reader)))))
      (etaf-dynamic-test--with-runtime
          (if wrapped
              (etaf-view (etaf-dynamic-test-context-author :label label :cell cell))
            (etaf-view
             (etaf-dynamic-test-context-provider :cell cell
               (text (expr (concat (etaf-inject 'etaf-dynamic-slot-context "ROOT")
                                   ":" (etaf-value label))))
               (etaf-dynamic-test-context-reader))))
        (should (string-match-p "\\`ROOT:A[[:space:]]+ROOT[[:space:]]+INNER[[:space:]]*\\'"
                                (etaf-dynamic-test--text buffer)))
        (setf (etaf-value label) "B")
        (should (string-match-p "\\`ROOT:B[[:space:]]+ROOT[[:space:]]+INNER[[:space:]]*\\'"
                                (etaf-dynamic-test--text buffer)))
        (let ((generation (etaf-runtime-current-generation runtime))
              (published (with-current-buffer buffer (buffer-string))))
          (should-error (setf (etaf-value label) 42))
          (should (eq generation (etaf-runtime-current-generation runtime)))
          (should (equal-including-properties
                   published (with-current-buffer buffer (buffer-string)))))
        (setf (etaf-value label) "C")
        (should (string-match-p "\\`ROOT:C[[:space:]]+ROOT[[:space:]]+INNER[[:space:]]*\\'"
                                (etaf-dynamic-test--text buffer)))))))

(ert-deftest etaf-dynamic-components-retain-singleton-sequence-state ()
  (let* ((item (etaf-dynamic-test--counter "A"))
         (source (etaf-ref item)))
    (etaf-dynamic-test--with-runtime
        (etaf-view (etaf-dynamic-test-owner :source source))
      (let ((state (cdar etaf-dynamic-test-setups)))
        (setf (etaf-value state) 3)
        (setf (etaf-value source) (list item (etaf-dynamic-test--counter "B")))
        (should (= 2 (length etaf-dynamic-test-setups)))
        (should (string-match-p "A:3" (etaf-dynamic-test--text buffer)))
        (setf (etaf-value source) item)
        (should (= 2 (length etaf-dynamic-test-setups)))
        (should (equal '("B") etaf-dynamic-test-disposals))
        (should (string-match-p "A:3" (etaf-dynamic-test--text buffer)))
        (setf (etaf-value source) nil)
        (should (equal '("A" "B") etaf-dynamic-test-disposals))
        (should (equal 1 (cl-count '("A" . unmounted)
                                   etaf-dynamic-test-hooks :test #'equal)))))))

(ert-deftest etaf-dynamic-components-fragment-composes-material-components ()
  (let ((source (etaf-ref (etaf-node 'etaf-dynamic-test-pair nil nil))))
    (etaf-dynamic-test--with-runtime
        (etaf-view (etaf-dynamic-test-owner :source source))
      (should (= 2 (length etaf-dynamic-test-setups)))
      (setf (etaf-value (cdr (assoc "A" etaf-dynamic-test-setups))) 3)
      (should (string-match-p "A:3" (etaf-dynamic-test--text buffer)))
      (should (string-match-p "B:0" (etaf-dynamic-test--text buffer)))
      (setf (etaf-value source) nil)
      (should (= 2 (length etaf-dynamic-test-disposals))))))

(ert-deftest etaf-dynamic-components-material-child-props-update-retains-hosts ()
  (let* ((label (etaf-ref "A"))
         (source (etaf-ref (etaf-view (etaf-dynamic-test-wrapper
                                      :label (etaf-value label))))))
    (etaf-dynamic-test--with-runtime
        (etaf-view (etaf-dynamic-test-owner :source source))
      (setf (etaf-value (cdar etaf-dynamic-test-setups)) 4)
      (setf (etaf-value label) "B")
      (should (= 1 (length etaf-dynamic-test-setups)))
      (should-not etaf-dynamic-test-disposals)
      (should (string-match-p "B:4" (etaf-dynamic-test--text buffer))))))

(ert-deftest etaf-dynamic-components-keyed-first-update-retains-programmatic-hosts ()
  "Initial and incremental keyed items use the same descendant positions."
  (let ((items (etaf-ref '((one . "A")))))
    (etaf-dynamic-test--with-runtime
        (etaf-view
         (column
          (etaf-dynamic-test-programmatic-keyed-item
           :for (entry (etaf-value items)) :key (car entry) :entry entry)))
      (let* ((ref (caar (etaf-runtime-handler-entries runtime)))
             (ancestry (gethash ref (etaf-runtime-host-ancestries runtime (list ref)))))
        (etaf-dispatch-event runtime ref 'press)
        (should (string-match-p "A:1" (etaf-dynamic-test--text buffer)))
        (dolist (label '("B" "C"))
          (setf (etaf-value items) (list (cons 'one label)))
          (should (= 1 (length etaf-dynamic-test-setups)))
          (should-not etaf-dynamic-test-disposals)
          (should (equal ref (caar (etaf-runtime-handler-entries runtime))))
          (should (equal ancestry
                         (gethash ref (etaf-runtime-host-ancestries runtime (list ref)))))
          (should (string-match-p (concat label ":1")
                                  (etaf-dynamic-test--text buffer))))
        (etaf-dispatch-event runtime ref 'press)
        (should (equal '("C" "A") etaf-dynamic-test-actions))
        (should (string-match-p "C:2" (etaf-dynamic-test--text buffer)))))))

(defun etaf-dynamic-test--keyed-fragment-view (source &optional stateful)
  "Return keyed forests from SOURCE, optionally containing STATEFUL counters."
  (etaf-view
   (column
    (fragment :for (entry (etaf-value source)) :key (car entry)
      (expr
       (mapcar
        (lambda (label)
          (cond
           ((eq label 'fail) (etaf-node 'etaf-dynamic-test-failure nil nil))
           (stateful (etaf-dynamic-test--counter label))
           (t (etaf-node 'text nil (list label)))))
        (cdr entry)))))))

(ert-deftest etaf-dynamic-components-keyed-fragment-mount-matches-pure ()
  "Empty, single and multiple roots remain grouped by their logical key."
  (dolist (items '(((only)) ((only "A")) ((only "A" "B"))
                   ((empty) (pair "A" "B") (single "C"))))
    (let* ((source (etaf-ref items))
           (view (etaf-dynamic-test--keyed-fragment-view source))
           (pure (substring-no-properties (ebox-render (etaf-render view)))))
      (etaf-dynamic-test--with-runtime view
        (should (equal pure (etaf-dynamic-test--text buffer)))
        (dolist (next '(((only)) ((only "one")) ((only "left" "right"))
                        ((only))))
          (setf (etaf-value source) next)
          (should
           (equal
            (substring-no-properties
             (ebox-render (etaf-render
                           (etaf-dynamic-test--keyed-fragment-view source))))
            (etaf-dynamic-test--text buffer))))))))

(ert-deftest etaf-dynamic-components-keyed-fragment-spans-retain-state ()
  "Per-key forests retain state as items grow, shrink, reorder or fail."
  (let ((source (etaf-ref '((empty) (pair "A" "B") (single "C")))))
    (etaf-dynamic-test--with-runtime
        (etaf-dynamic-test--keyed-fragment-view source t)
      (let* ((generation (etaf-runtime-current-generation runtime))
             (effect-id (car (etaf--generation-source-effects generation source)))
             (range (etaf--generation-effect-semantic generation effect-id))
             (spans (etaf--semantic-range-keyed-item-node-span-index range)))
        ;; Total output cardinality happens to equal item count here.  Each
        ;; logical key must still own its own zero-, two-, or one-node span.
        (should (equal '(0 . 0) (gethash 'empty spans)))
        (should (equal '(0 . 2) (gethash 'pair spans)))
        (should (equal '(2 . 1) (gethash 'single spans))))
      (should (= 3 (length etaf-dynamic-test-setups)))
      (setf (etaf-value (cdr (assoc "A" etaf-dynamic-test-setups))) 7)
      (let* ((refs (mapcar #'car (etaf-runtime-handler-entries runtime)))
             (ancestries (etaf-runtime-host-ancestries runtime refs))
             (a-ref
              (cl-find-if
               (lambda (ref)
                 (let ((bounds (etaf-host-ref-bounds runtime ref)))
                   (with-current-buffer buffer
                     (string-match-p
                      "A:7" (buffer-substring-no-properties
                             (car bounds) (cdr bounds))))))
               refs)))
        (should a-ref)
        (setf (etaf-value source) '((single "C") (pair "A" "B") (empty)))
        (should (equal '("C:0" "A:7" "B:0")
                       (split-string (etaf-dynamic-test--text buffer))))
        (should (= 3 (length etaf-dynamic-test-setups)))
        (setf (etaf-value source) '((single "C") (pair "A2" "B2") (empty "D")))
        (should (= 4 (length etaf-dynamic-test-setups)))
        (dolist (ref refs)
          (should (equal (gethash ref ancestries)
                         (gethash ref (etaf-runtime-host-ancestries runtime refs)))))
        (setf (etaf-value source) '((single "C") (pair "A3") (empty "D")))
        (should (equal '("B") etaf-dynamic-test-disposals))
        (setf (etaf-value source) '((single "C") (pair "A4" "B3") (empty "D")))
        (should (= 5 (length etaf-dynamic-test-setups)))
        (should (equal '("C:0" "A4:7" "B3:0" "D:0")
                       (split-string (etaf-dynamic-test--text buffer))))
        (let ((generation (etaf-runtime-current-generation runtime))
              (published (with-current-buffer buffer (buffer-string))))
          (should-error
           (setf (etaf-value source)
                 '((new "N") (pair "A5" fail) (single "C") (empty "D"))))
          (should (eq generation (etaf-runtime-current-generation runtime)))
          (should (equal-including-properties
                   published (with-current-buffer buffer (buffer-string))))
          (should (member "N" etaf-dynamic-test-disposals))
          (should-not (member '("N" . mounted) etaf-dynamic-test-hooks)))
        (setf (etaf-value source) '((single "C") (pair "A4" "B3") (empty "D")))
        (should (equal (gethash a-ref ancestries)
                       (gethash a-ref
                                (etaf-runtime-host-ancestries runtime (list a-ref)))))
        (etaf-dispatch-event runtime a-ref 'press)
        (should (equal '("A4") etaf-dynamic-test-actions))
        (should (string-match-p "A4:8" (etaf-dynamic-test--text buffer)))
        (setf (etaf-value source) '((single "C") (empty "D")))
        (should-not (etaf-runtime-handler-for runtime a-ref))
        (setf (etaf-value source) nil)
        (should (equal "" (etaf-dynamic-test--text buffer)))
        (should (equal '("A" "B" "B3" "C" "D" "N")
                       (sort (copy-sequence etaf-dynamic-test-disposals)
                             #'string<)))))))

(ert-deftest etaf-dynamic-components-root-owned-expression-updates ()
  (let ((source (etaf-ref nil)))
    (etaf-dynamic-test--with-runtime
        (etaf-view (column (expr (etaf-value source))))
      (setf (etaf-value source) (etaf-dynamic-test--counter "root"))
      (setf (etaf-value (cdar etaf-dynamic-test-setups)) 2)
      (should (string-match-p "root:2" (etaf-dynamic-test--text buffer)))
      (setf (etaf-value source) nil)
      (should (equal '("root") etaf-dynamic-test-disposals)))))

(ert-deftest etaf-dynamic-components-remount-then-update-reuses-new-instance ()
  (let ((source (etaf-ref (etaf-dynamic-test--counter "A" 'a))))
    (etaf-dynamic-test--with-runtime
        (etaf-view (etaf-dynamic-test-owner :source source))
      (setf (etaf-value source) nil)
      (setf (etaf-value source) (etaf-dynamic-test--counter "A" 'a))
      (let ((state (cdar etaf-dynamic-test-setups)))
        (should (= 2 (length etaf-dynamic-test-setups)))
        (setf (etaf-value state) 5)
        (setf (etaf-value source) (etaf-dynamic-test--counter "A2" 'a))
        (should (= 2 (length etaf-dynamic-test-setups)))
        (should (string-match-p "A2:5" (etaf-dynamic-test--text buffer)))))))

(ert-deftest etaf-dynamic-components-keyed-reorder-remove-and-duplicate ()
  (let ((source (etaf-ref (list (etaf-dynamic-test--counter "A" 'a)
                                (etaf-dynamic-test--counter "B" 'b)))))
    (etaf-dynamic-test--with-runtime
        (etaf-view (etaf-dynamic-test-owner :source source))
      (let ((state-a (cdr (assoc "A" etaf-dynamic-test-setups))))
        (setf (etaf-value state-a) 7)
        (setf (etaf-value source)
              (list (etaf-dynamic-test--counter "B2" 'b)
                    (etaf-dynamic-test--counter "A2" 'a)))
        (should (= 2 (length etaf-dynamic-test-setups)))
        (should (string-match-p "A2:7" (etaf-dynamic-test--text buffer)))
        (let ((generation (etaf-runtime-current-generation runtime))
              (text (etaf-dynamic-test--text buffer)))
          (should-error
           (setf (etaf-value source)
                 (list (etaf-dynamic-test--counter "bad" 'a)
                       (etaf-dynamic-test--counter "duplicate" 'a)))
           :type 'etaf-runtime-error)
          (should (eq generation (etaf-runtime-current-generation runtime)))
          (should (equal text (etaf-dynamic-test--text buffer))))))))

(ert-deftest etaf-dynamic-components-reused-description-isolates-instances ()
  (let* ((item (etaf-dynamic-test--counter "shared-description"))
         (source (etaf-ref (list item item))))
    (etaf-dynamic-test--with-runtime
        (etaf-view (etaf-dynamic-test-owner :source source))
      (should (= 2 (length etaf-dynamic-test-setups)))
      (let ((states (mapcar #'cdr etaf-dynamic-test-setups)))
        (should-not (eq (car states) (cadr states)))
        (setf (etaf-value (car states)) 8)
        (should (string-match-p "shared-description:8" (etaf-dynamic-test--text buffer)))
        (should (string-match-p "shared-description:0" (etaf-dynamic-test--text buffer)))))))

(defun etaf-dynamic-test--helper (source)
  "Return a reused compiled Host and Expr site reading SOURCE."
  (etaf-view (column (expr (etaf-value source)))))

(defun etaf-dynamic-test--expr-helper (source)
  "Return a reused expression site with no intervening Host."
  (etaf-view (expr (etaf-value source))))

(defun etaf-dynamic-test--deferred-helper (left right calls)
  "Return independent LEFT/RIGHT text programs counted in CALLS."
  (etaf-view
   (column
     (text (expr (progn (cl-incf (aref calls 0)) (etaf-value left))))
     (text (expr (progn (cl-incf (aref calls 1)) (etaf-value right)))))))

(defun etaf-dynamic-test--lexical-helper (value)
  "Return inline and structural programs capturing the current VALUE."
  (etaf-view
   (column
    (text :ref 'lexical-inline (expr value))
    (column
     (expr (etaf-node 'text (list :ref 'lexical-structural) (list value)))))))

(ert-deftest etaf-dynamic-components-parent-range-retargets-lexical-programs ()
  "Fresh lexical inputs update stable child Range owners and roll back errors."
  (let ((source (etaf-ref "Before")))
    (etaf-dynamic-test--with-runtime
        (etaf-view (column (expr (etaf-dynamic-test--lexical-helper
                                  (etaf-value source)))))
      (let* ((generation (etaf-runtime-current-generation runtime))
             (inline-ancestry
              (gethash 'lexical-inline
                       (etaf-runtime-host-ancestries runtime '(lexical-inline))))
             (structural-ancestry
              (gethash 'lexical-structural
                       (etaf-runtime-host-ancestries runtime '(lexical-structural))))
             (published (with-current-buffer buffer (buffer-string))))
        (should (string-match-p "Before[[:space:]]+Before"
                                (etaf-dynamic-test--text buffer)))
        (should-error (setf (etaf-value source) 42))
        (should (eq generation (etaf-runtime-current-generation runtime)))
        (should (equal-including-properties
                 published (with-current-buffer buffer (buffer-string))))
        (setf (etaf-value source) "After")
        (should (string-match-p "After[[:space:]]+After"
                                (etaf-dynamic-test--text buffer)))
        (dolist (entry (list (cons 'lexical-inline inline-ancestry)
                            (cons 'lexical-structural structural-ancestry)))
          (should (equal (cdr entry)
                         (gethash (car entry)
                                  (etaf-runtime-host-ancestries
                                  runtime (list (car entry)))))))))))

(defun etaf-dynamic-test--batch-lexical-helper (value source calls kind)
  "Return KIND programs combining lexical VALUE and reactive SOURCE."
  (etaf-node
   'column nil
   (append
    (when (memq kind '(inline both))
      (list
       (etaf-view
        (text :ref 'batch-inline
          (expr (progn
                  (cl-incf (aref calls 1))
                  (concat value "/" (etaf-value source))))))))
    (when (memq kind '(structural both))
      (list
       (etaf-view
        (column
         (expr
          (progn
            (cl-incf (aref calls 2))
            (etaf-node 'text (list :ref 'batch-structural)
                       (list (concat value "/" (etaf-value source)))))))))))))

(defun etaf-dynamic-test--check-parent-child-batch (kind)
  "Check KIND nested programs for both parent/child notification orders."
  (dolist (child-first '(nil t))
    (let ((outer (etaf-ref "A"))
          (inner (etaf-ref "1"))
          (calls (vector 0 0 0)))
      (etaf-dynamic-test--with-runtime
          (etaf-view
           (column
            (expr
             (progn
               (cl-incf (aref calls 0))
               (when (etaf-value outer)
                 (etaf-dynamic-test--batch-lexical-helper
                  (etaf-value outer) inner calls kind))))))
        (let* ((refs (pcase kind
                       ('inline '(batch-inline))
                       ('structural '(batch-structural))
                       (_ '(batch-inline batch-structural))))
               (ancestries (etaf-runtime-host-ancestries runtime refs))
               (version (etaf-runtime-generation runtime)))
          (cl-labels
              ((check-output
                (value)
                (should
                 (equal (split-string (etaf-dynamic-test--text buffer))
                        (make-list (length refs) value))))
               (update
                (parent child)
                (etaf-reactive-call-with-batch
                 (lambda ()
                   (if child-first
                       (setf (etaf-value inner) child
                             (etaf-value outer) parent)
                     (setf (etaf-value outer) parent
                           (etaf-value inner) child))))))
            (check-output "A/1")
            (update "B" "2")
            (check-output "B/2")
            (should (= (1+ version) (etaf-runtime-generation runtime)))
            (should (equal calls
                           (pcase kind
                             ('inline [2 2 0])
                             ('structural [2 0 2])
                             (_ [2 2 2]))))
            (dolist (ref refs)
              (should (equal (gethash ref ancestries)
                             (gethash ref
                                      (etaf-runtime-host-ancestries runtime refs)))))
            (let ((generation (etaf-runtime-current-generation runtime))
                  (published (with-current-buffer buffer (buffer-string))))
              (should-error (update 42 "3"))
              (should (eq generation (etaf-runtime-current-generation runtime)))
              (should (equal-including-properties
                       published (with-current-buffer buffer (buffer-string)))))
            (update "C" "4")
            (check-output "C/4")
            (let ((parent-calls (aref calls 0)))
              (setf (etaf-value inner) "5")
              (check-output "C/5")
              (should (= parent-calls (aref calls 0))))
            (let ((child-calls (list (aref calls 1) (aref calls 2))))
              (update nil "6")
              (should (equal "" (etaf-dynamic-test--text buffer)))
              (should (equal child-calls
                             (list (aref calls 1) (aref calls 2)))))))))))

(ert-deftest etaf-dynamic-components-parent-child-batch-inline ()
  "Inline descendants use the fresh parent closure once in a shared batch."
  (etaf-dynamic-test--check-parent-child-batch 'inline))

(ert-deftest etaf-dynamic-components-parent-child-batch-structural ()
  "Structural descendants use one coherent candidate in a shared batch."
  (etaf-dynamic-test--check-parent-child-batch 'structural))

(ert-deftest etaf-dynamic-components-parent-child-batch-mixed ()
  "Mixed descendants retain ownership through batches, rollback and removal."
  (etaf-dynamic-test--check-parent-child-batch 'both))

(ert-deftest etaf-dynamic-components-helper-expr-keeps-dependencies-local ()
  "Direct and structural-expression use retain the same child dependencies."
  (dolist (wrapped '(nil t))
    (let ((left (etaf-ref "Left"))
          (right (etaf-ref "Right"))
          (calls (vector 0 0)))
      (etaf-dynamic-test--with-runtime
          (if wrapped
              (etaf-view
               (column (expr (etaf-dynamic-test--deferred-helper
                               left right calls))))
            (etaf-dynamic-test--deferred-helper left right calls))
        (should (equal calls [1 1]))
        (setf (etaf-value left) "LEFT")
        (should (equal calls [2 1]))
        (should (string-match-p "LEFT[[:space:]]+Right"
                                (etaf-dynamic-test--text buffer)))
        (setf (etaf-value right) "RIGHT")
        (should (equal calls [2 2]))
        (let ((generation (etaf-runtime-current-generation runtime))
              (published (with-current-buffer buffer (buffer-string))))
          (should-error (setf (etaf-value left) 42))
          (should (eq generation (etaf-runtime-current-generation runtime)))
          (should (equal-including-properties
                   published (with-current-buffer buffer (buffer-string))))
          (should (= 2 (aref calls 1))))))))

(defun etaf-dynamic-test--keyed-helper (left right)
  "Return two independent keyed Component ranges over LEFT and RIGHT."
  (etaf-view
   (column
     (etaf-dynamic-test-counter :for (item (etaf-value left)) :key item :label "A")
     (etaf-dynamic-test-counter :for (item (etaf-value right)) :key item :label "B"))))

(ert-deftest etaf-dynamic-components-helper-expr-keeps-keyed-scopes ()
  "Equal keys at distinct helper sites own separate state and disposal."
  (dolist (wrapped '(nil t))
    (let ((left (etaf-ref '(1)))
          (right (etaf-ref '(1))))
      (etaf-dynamic-test--with-runtime
          (if wrapped
              (etaf-view
               (column (expr (etaf-dynamic-test--keyed-helper left right))))
            (etaf-dynamic-test--keyed-helper left right))
        (should (= 2 (length etaf-dynamic-test-setups)))
        (let ((state-a (cdr (assoc "A" etaf-dynamic-test-setups)))
              (state-b (cdr (assoc "B" etaf-dynamic-test-setups))))
          (should-not (eq state-a state-b))
          (setf (etaf-value state-a) 7)
          (should (string-match-p "A:7[[:space:]]+B:0"
                                  (etaf-dynamic-test--text buffer)))
          (setf (etaf-value left) nil)
          (should (equal '("A") etaf-dynamic-test-disposals))
          (setf (etaf-value state-b) 8)
          (should (string-match-p "B:8" (etaf-dynamic-test--text buffer)))
          (should (= 2 (length etaf-dynamic-test-setups))))))))

(ert-deftest etaf-dynamic-components-reused-expression-sites-remain-independent ()
  (let ((left (etaf-ref (etaf-dynamic-test--counter "left")))
        (right (etaf-ref (etaf-dynamic-test--counter "right"))))
    (etaf-dynamic-test--with-runtime
        (etaf-node 'column nil
                   (list (etaf-dynamic-test--expr-helper left)
                         (etaf-dynamic-test--expr-helper right)))
      (should (= 2 (length etaf-dynamic-test-setups)))
      (setf (etaf-value left) nil)
      (should (equal '("left") etaf-dynamic-test-disposals))
      (should (string-match-p "right:0" (etaf-dynamic-test--text buffer))))))

(ert-deftest etaf-dynamic-components-helper-sites-isolate-hosts-and-ranges ()
  (let ((left (etaf-ref (etaf-dynamic-test--counter "left")))
        (right (etaf-ref (etaf-dynamic-test--counter "right"))))
    (etaf-dynamic-test--with-runtime
        (etaf-node 'column nil
                   (list (etaf-dynamic-test--helper left)
                         (etaf-dynamic-test--helper right)))
      (should (= 2 (length etaf-dynamic-test-setups)))
      (setf (etaf-value left) nil)
      (should (equal '("left") etaf-dynamic-test-disposals))
      (should (string-match-p "right:0" (etaf-dynamic-test--text buffer))))))

(ert-deftest etaf-dynamic-components-invalid-output-has-public-context ()
  (let ((source (etaf-ref nil)))
    (etaf-dynamic-test--with-runtime
        (etaf-view (etaf-dynamic-test-owner :source source))
      (let ((condition (should-error (setf (etaf-value source) '(text "raw"))
                                     :type 'etaf-runtime-error)))
        (should (string-match-p "etaf-dynamic-test-owner" (error-message-string condition)))
        (should (string-match-p "View" (error-message-string condition)))
        (should-not (string-match-p "Step4" (error-message-string condition)))))))

(ert-deftest etaf-dynamic-components-nested-shapes-and-type-replacement ()
  (let ((source (etaf-ref nil)))
    (etaf-dynamic-test--with-runtime
        (etaf-view (etaf-dynamic-test-owner :source source))
      (dolist (shape
               (list "bare"
                     (etaf-view (text "host"))
                     (etaf-view
                      (fragment (text "fragment")
                                (expr (etaf-dynamic-test--counter "nested"))))))
        (setf (etaf-value source) shape))
      (should (string-match-p "fragment" (etaf-dynamic-test--text buffer)))
      (should (string-match-p "nested:0" (etaf-dynamic-test--text buffer)))
      (setf (etaf-value source) (etaf-dynamic-test--counter "direct" 'same))
      (should (equal '("nested") etaf-dynamic-test-disposals))
      (setf (etaf-value source)
            (etaf-node 'etaf-dynamic-test-pure
                       '(:label "replacement" :key same) nil))
      (should (equal '("direct" "nested") etaf-dynamic-test-disposals))
      (should (string-match-p "replacement" (etaf-dynamic-test--text buffer))))))

(ert-deftest etaf-dynamic-components-fragment-keeps-nested-range-boundaries ()
  (let* ((left (etaf-ref "left"))
         (right (etaf-ref "right"))
         (source (etaf-ref (etaf-node 'etaf-dynamic-test-range-pair
                                      (list :left left :right right) nil))))
    (etaf-dynamic-test--with-runtime
        (etaf-view (etaf-dynamic-test-owner :source source))
      (let* ((generation (etaf-runtime-current-generation runtime))
             (pair (cl-loop for identity being the hash-keys of
                            (etaf-generation-identity-index generation)
                            when (eq (car-safe identity) 'etaf-dynamic-test-range-pair)
                            return (etaf--generation-semantic generation identity))))
        (should (eq 'transparent (etaf--semantic-component-publication-kind pair))))
      (setf (etaf-value left) "LEFT")
      (should (string-match-p "LEFT" (etaf-dynamic-test--text buffer)))
      (setf (etaf-value right) "RIGHT")
      (should (string-match-p "RIGHT" (etaf-dynamic-test--text buffer))))))

(ert-deftest etaf-dynamic-components-two-apps-own-their-scopes ()
  (let* ((item (etaf-dynamic-test--counter "A"))
         (source (etaf-ref item))
         (view (etaf-view (etaf-dynamic-test-owner :source source))))
    (etaf-dynamic-test--with-runtime view
      (let ((other (generate-new-buffer " *etaf-dynamic-other*"))
            (first-state (cdar etaf-dynamic-test-setups)))
        (unwind-protect
            (progn
              (etaf-mount other view)
              (should (= 2 (length etaf-dynamic-test-setups)))
              (setf (etaf-value first-state) 4)
              (should (string-match-p "A:4" (etaf-dynamic-test--text buffer)))
              (should (string-match-p "A:0" (etaf-dynamic-test--text other)))
              (etaf-unmount (etaf-runtime-for-buffer other))
              (should (= 1 (length etaf-dynamic-test-disposals)))
              (setf (etaf-value first-state) 5)
              (should (string-match-p "A:5" (etaf-dynamic-test--text buffer))))
          (etaf-dynamic-test--close other))))))

(etaf-define-component etaf-dynamic-test-failure ()
  :render (error "dynamic sibling render failure"))

(defun etaf-dynamic-test--first-handler (runtime)
  "Return a committed press target from RUNTIME."
  (caar (etaf--generation-index-entries
          (etaf-runtime-current-generation runtime) 'handlers)))

(ert-deftest etaf-dynamic-components-failure-restores-state-handlers-and-scopes ()
  (let ((source (etaf-ref (list (etaf-dynamic-test--counter "A" 'a)))))
    (etaf-dynamic-test--with-runtime
        (etaf-view (etaf-dynamic-test-owner :source source))
      (let ((generation (etaf-runtime-current-generation runtime))
            (target (etaf-dynamic-test--first-handler runtime))
            (registry-count (hash-table-count (etaf-runtime-resource-registry runtime))))
        (should-error
         (setf (etaf-value source)
               (list (etaf-dynamic-test--counter "B" 'a)
                     (etaf-dynamic-test--counter "new" 'new)
                     (etaf-node 'etaf-dynamic-test-failure nil nil)))
         :type 'error)
        (should (eq generation (etaf-runtime-current-generation runtime)))
        (should (= registry-count (hash-table-count (etaf-runtime-resource-registry runtime))))
        (should (equal '("new") etaf-dynamic-test-disposals))
        (should-not (member '("new" . mounted) etaf-dynamic-test-hooks))
        ;; Restore the external source before dispatch, whose ordinary batch
        ;; end legitimately retries any still-dirty business value.
        (setf (etaf-value source) (list (etaf-dynamic-test--counter "A" 'a)))
        (etaf-dispatch-event runtime target :on-press)
        (should (equal '("A") etaf-dynamic-test-actions))
        (should (string-match-p "A:1" (etaf-dynamic-test--text buffer)))))))

(defun etaf-dynamic-test--keyed-host (key label)
  "Return one compiled keyed Host with a nested stateful LABEL Component."
  (etaf-view (column :key key (etaf-dynamic-test-counter :label label))))

(ert-deftest etaf-dynamic-components-keyed-host-reorder-retains-descendants ()
  (let ((source (etaf-ref (list (etaf-dynamic-test--keyed-host 'a "A")
                                (etaf-dynamic-test--keyed-host 'b "B")))))
    (etaf-dynamic-test--with-runtime
        (etaf-view (etaf-dynamic-test-owner :source source))
      (let* ((generation (etaf-runtime-current-generation runtime))
             (host-id
              (cl-loop for identity being the hash-keys of
                       (etaf--semantic-range-item-identity-index
                        (cl-loop for identity being the hash-keys of
                                 (etaf-generation-identity-index generation)
                                 when (eq (car-safe identity) 'range)
                                 return (etaf--generation-semantic generation identity)))
                       using (hash-values semantic-id)
                       when (equal (plist-get (cddr identity) :key) 'a)
                       return semantic-id))
             (host-ref (etaf--semantic-host-host-ref
                        (etaf--pvec-get (etaf-generation-semantic-nodes generation) host-id))))
        (setf (etaf-value (cdr (assoc "A" etaf-dynamic-test-setups))) 6)
        (setf (etaf-value source)
            (list (etaf-dynamic-test--keyed-host 'b "B")
                  (etaf-dynamic-test--keyed-host 'a "A")))
        (should (= 2 (length etaf-dynamic-test-setups)))
        (should (string-match-p "A:6" (etaf-dynamic-test--text buffer)))
        (should-not etaf-dynamic-test-disposals)
        (should (equal host-ref
                       (etaf--semantic-host-host-ref
                        (etaf--pvec-get
                         (etaf-generation-semantic-nodes
                          (etaf-runtime-current-generation runtime)) host-id))))))))

(ert-deftest etaf-dynamic-components-pure-stateless-output-matches-mounted ()
  (let* ((view (etaf-view
               (column (expr (list (etaf-view (etaf-dynamic-test-pure :label "A"))
                                   (etaf-view (text "B")))))))
         (pure (substring-no-properties (ebox-render (etaf-render view)))))
    (etaf-dynamic-test--with-runtime view
      (should (equal pure (etaf-dynamic-test--text buffer))))))

(etaf-define-component etaf-dynamic-test-theme-alias (&key defaults property color)
  :setup (etaf-theme-provide defaults)
  :render (etaf-node 'box (list property color) (list "theme")))

(ert-deftest etaf-dynamic-components-theme-default-respects-property-alias ()
  (dolist (case '((:bgcolor :background-color "#abcdef")
                  (:background-color :bgcolor "#abcdef")
                  (:bgcolor :background-color nil)))
    (let* ((defaults (etaf-ref (list (car case) "#123456")))
           (property (cadr case))
           (color (caddr case)))
      (etaf-dynamic-test--with-runtime
          (etaf-view (etaf-dynamic-test-theme-alias
                      :defaults defaults :property property :color color))
        (should (string-match-p "theme" (etaf-dynamic-test--text buffer)))
        (setf (etaf-value defaults) (list (car case) "#654321"))
        (should (string-match-p "theme" (etaf-dynamic-test--text buffer)))))))

(etaf-define-component etaf-dynamic-test-theme-layout
    (&key palette behavior on-press)
  :setup (etaf-theme-provide palette)
  :styles (styles ("&" :padding (1 2))
                  (".content" :item-gap 3))
  :view
  (column :width '(100) :height 8 :overflow 'scroll
          :color (etaf-theme-token :fg)
          :bgcolor (etaf-theme-token :bg)
    (row :class "content"
      (text :ref 'theme-layout-first :role 'button :disabled nil
            :use behavior :on-press on-press
            :color (etaf-theme-token :fg) "First")
      (text :ref 'theme-layout-second "Second"))))

(ert-deftest etaf-dynamic-components-theme-preserves-anonymous-host-layout ()
  "Theme-only effects retain full Host geometry without semantic attributes."
  (let ((palette (etaf-ref '(:fg "#111111" :bg "#ffffff"))))
    (etaf-dynamic-test--with-runtime
        (etaf-view (etaf-dynamic-test-theme-layout :palette palette))
      (let* ((state (ebox--buffer-render-state buffer))
             (source-index (plist-get state :source-index))
             (root (plist-get state :root-node))
             (geometry
              (cl-loop for (property value) on
                       (ebox-tree-node-source-declarations source-index root)
                       by #'cddr
                       unless (memq property '(ebox/color ebox/background-color))
                       append (list property value)))
             (text (etaf-dynamic-test--text buffer))
             (bounds (etaf-host-ref-bounds runtime 'theme-layout-first)))
        (should (equal (plist-get geometry 'ebox/width) '(100)))
        (should (equal (plist-get geometry 'ebox/padding-inline-start) 2))
        (dolist (next '((:fg "#eeeeee" :bg "#111111")
                        (:fg "#111111" :bg "#ffffff")))
          (setf (etaf-value palette) next)
          (let* ((next-state (ebox--buffer-render-state buffer))
                 (next-root (plist-get next-state :root-node))
                 (next-declarations
                  (ebox-tree-node-source-declarations
                   (plist-get next-state :source-index) next-root)))
            (should
             (equal geometry
                    (cl-loop for (property value) on next-declarations by #'cddr
                             unless (memq property
                                          '(ebox/color ebox/background-color))
                             append (list property value))))
            (should (equal text (etaf-dynamic-test--text buffer)))
            (should (equal bounds
                           (etaf-host-ref-bounds runtime 'theme-layout-first)))
            (should
             (equal
              (with-current-buffer buffer
                (cl-some
                 (lambda (spec) (and (listp spec) (plist-get spec :foreground)))
                 (cdr (assq (tp-paint-slot-face (plist-get next-root :color))
                            face-remapping-alist))))
              (plist-get next :fg)))))))))

(ert-deftest etaf-dynamic-components-theme-retains-composed-callbacks ()
  "Theme deltas and rollback keep callbacks once and retain Behavior resources."
  (let* ((palette (etaf-ref '(:fg "#111111" :bg "#ffffff")))
         (installs 0) (cleanups 0) (calls nil)
         (behavior
          (etaf-behavior-create
           'theme-layout
           :on-press (lambda () (push 'behavior calls))
           :install (lambda ()
                      (cl-incf installs)
                      (lambda () (cl-incf cleanups)))))
         (captured 'original)
         (on-press (let ((value captured))
                     (lambda () (push value calls)))))
    (etaf-dynamic-test--with-runtime
        (etaf-view (etaf-dynamic-test-theme-layout
                    :palette palette :behavior behavior :on-press on-press))
      (setq captured 'changed)
      (dolist (next '((:fg "#eeeeee" :bg "#111111")
                      (:fg "#111111" :bg "#ffffff")))
        (setf (etaf-value palette) next)
        (setq calls nil)
        (etaf-dispatch-event runtime 'theme-layout-first 'press)
        (should (equal calls '(behavior original)))
        (should (= installs 1))
        (should (= cleanups 0))
        (let ((props (etaf-runtime-host-props-for runtime 'theme-layout-first)))
          (should (eq (plist-get props :role) 'button))
          (should-not (plist-get props :disabled))))
      (cl-letf (((symbol-function 'etaf--runtime-swap-generation)
                 (lambda (&rest _) (error "Reject Theme candidate"))))
        (should-error
         (setf (etaf-value palette) '(:fg "#eeeeee" :bg "#111111"))))
      (setq calls nil)
      (etaf-dispatch-event runtime 'theme-layout-first 'press)
      (should (equal calls '(behavior original)))
      (should (= installs 1))
      (should (= cleanups 0)))
    (should (= cleanups 1))))

(provide 'etaf-dynamic-components-tests)
;;; etaf-dynamic-components-tests.el ends here
