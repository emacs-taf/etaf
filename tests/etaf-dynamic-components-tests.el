;;; etaf-dynamic-components-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'etaf)

(defvar etaf-dynamic-test-setups nil)

(defvar etaf-dynamic-test-disposals nil)

(defvar etaf-dynamic-test-hooks nil)

(defvar etaf-dynamic-test-actions nil)

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

(defun etaf-dynamic-test--paint-foreground (buffer color)
  "Read COLOR's currently published foreground in BUFFER."
  (if (tp-paint-slot-p color)
      (with-current-buffer buffer
        (plist-get (cadr (assq (tp-paint-slot-face color) face-remapping-alist))
                   :foreground))
    color))

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

(ert-deftest etaf-dynamic-components-invalid-output-has-public-context ()
  (let ((source (etaf-ref nil)))
    (etaf-dynamic-test--with-runtime
        (etaf-view (etaf-dynamic-test-owner :source source))
      (let ((condition (should-error (setf (etaf-value source) '(text "raw"))
                                     :type 'etaf-runtime-error)))
        (should (string-match-p "etaf-dynamic-test-owner" (error-message-string condition)))
        (should (string-match-p "View" (error-message-string condition)))
        (should-not (string-match-p "Step4" (error-message-string condition)))))))

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
  :styles (("&" :padding ((lh 1) (ch 2)))
                  (".content" :item-gap (px 3)))
  :view
  (column :width '(px 100) :height '(lh 8) :overflow 'scroll
          :color (etaf-theme-token :fg)
          :bgcolor (etaf-theme-token :bg)
    (row :class "content"
      (text :ref 'theme-layout-first :role 'button :disabled nil
            :use behavior :on-press on-press
            :color (etaf-theme-token :fg) "First")
      (text :ref 'theme-layout-second "Second"))))

(ert-deftest etaf-dynamic-components-theme-preserves-anonymous-host-layout ()
  "Theme changes preserve visible geometry and interactive Host bounds."
  (let ((palette (etaf-ref '(:fg "#111111" :bg "#ffffff"))))
    (etaf-dynamic-test--with-runtime
        (etaf-view (etaf-dynamic-test-theme-layout :palette palette))
      (let* ((text (etaf-dynamic-test--text buffer))
             (widths (with-current-buffer buffer
                       (mapcar #'ebox-string-pixel-width
                               (ebox-string-lines (buffer-string)))))
             (bounds (etaf-host-ref-bounds runtime 'theme-layout-first)))
        (should bounds)
        (should (string-match-p "First" text))
        (dolist (next '((:fg "#eeeeee" :bg "#111111")
                       (:fg "#111111" :bg "#ffffff")))
          (setf (etaf-value palette) next)
          (should (equal text (etaf-dynamic-test--text buffer)))
          (should (equal widths
                         (with-current-buffer buffer
                           (mapcar #'ebox-string-pixel-width
                                   (ebox-string-lines (buffer-string))))))
          (should (equal bounds
                         (etaf-host-ref-bounds runtime 'theme-layout-first)))
          (should (equal (plist-get next :fg)
                         (etaf-dynamic-test--paint-foreground
                          buffer
                          (plist-get (etaf-runtime-host-props-for
                                      runtime 'theme-layout-first) :color)))))))))

(provide 'etaf-dynamic-components-tests)
;;; etaf-dynamic-components-tests.el ends here
