;;; etaf-component-frontends-tests.el --- Component frontend contract -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'etaf)

(defvar etaf-test-g6b-dsl-setup-count 0)
(defvar etaf-test-g6b-code-setup-count 0)
(defvar etaf-test-g6b-lifecycle nil)

(etaf-define-component etaf-test-g6b-dsl-counter (&key initial)
  :setup
  (progn
    (cl-incf etaf-test-g6b-dsl-setup-count)
    (etaf-ref (or initial 0)))
  :view
  (column :background-color "#102030" :padding-inline 1
    (text :font-weight 'bold
          (expr (format "Count %d" (etaf-value (etaf-state)))))
    (box :ref 'g6b-dsl-increment
         :on-press
         (let ((count (etaf-state)))
           (lambda ()
             (setf (etaf-value count) (1+ (etaf-value count)))))
      "Increment")))

(etaf-define-component etaf-test-g6b-code-counter (&key initial)
  :setup
  (progn
    (cl-incf etaf-test-g6b-code-setup-count)
    (etaf-ref (or initial 0)))
  :render
  (let ((count (etaf-state)))
    (etaf-node
     'column (list :background-color "#102030" :padding-inline 1)
     (list
      (etaf-node 'text (list :font-weight 'bold)
                 (list (format "Count %d" (etaf-value count))))
      (etaf-node
       'box
       (list :ref 'g6b-code-increment
             :on-press
             (lambda ()
               (setf (etaf-value count) (1+ (etaf-value count)))))
       (list "Increment"))))))

(etaf-define-component etaf-test-g6b-nil-state ()
  :setup nil
  :view (text (expr (if (null (etaf-state)) "nil-state" "bad-state"))))

(etaf-define-component etaf-test-g6b-directives (&key selected items)
  :view
  (column
    (text :if selected :key 'selected (expr selected))
    (text :else t :key 'empty "No selection")
    (row :for (item items) :key (car item)
      (text (expr (cdr item))))))

(etaf-define-component etaf-test-g6b-pair (&key item)
  :view
  (fragment
    (text (expr (format "%s-1" (cdr item))))
    (text (expr (format "%s-2" (cdr item))))))

(etaf-define-component etaf-test-g6b-component-loop (&key items)
  :view
  (column
    (etaf-test-g6b-pair :for (item items) :key (car item) :item item)))

(etaf-define-component etaf-test-g6b-key-boundary (&key value)
  :setup
  (list :framework-key (etaf-current-prop 'key) :initial value)
  :view
  (text
   (expr
    (format "%s/%s"
            (plist-get (etaf-state) :initial)
            (or (plist-get (etaf-state) :framework-key) "no-key")))))

(etaf-define-component etaf-test-g6b-invalid-list-result ()
  :render
  (list (etaf-node 'text nil (list "ambiguous"))))

(etaf-define-component etaf-test-g6b-rollback (&key fail)
  :setup (etaf-ref 7)
  :render
  (let ((state (etaf-state)))
    (when fail
      (setf (etaf-value state) 99))
    (etaf-node 'text nil (list (format "Stable %d" (etaf-value state))))))

(etaf-define-component etaf-test-g6b-lifecycle (&key label)
  :setup
  (progn
    (etaf-on-mounted
     (lambda ()
       (setq etaf-test-g6b-lifecycle
             (append etaf-test-g6b-lifecycle '(mounted)))))
    (etaf-on-updated
     (lambda ()
       (setq etaf-test-g6b-lifecycle
             (append etaf-test-g6b-lifecycle '(updated)))))
    (etaf-on-unmounted
     (lambda ()
       (setq etaf-test-g6b-lifecycle
             (append etaf-test-g6b-lifecycle '(unmounted)))))
    (etaf-on-scope-dispose
     (lambda ()
       (setq etaf-test-g6b-lifecycle
             (append etaf-test-g6b-lifecycle '(cleanup)))))
    nil)
  :view (text (expr label)))

(etaf-define-component etaf-test-g6b-provider (&key count on-press)
  :setup
  (progn
    (etaf-provide 'g6b-message "Context")
    (etaf-theme-provide '(:color "#34D399"))
    nil)
  :view (column (etaf-test-g6b-context-action :count count :on-press on-press)))

(etaf-define-component etaf-test-g6b-context-action (&key count on-press)
  :render
  (etaf-node
   'box
   (list :class '(g6b-context-action)
         :ref 'g6b-context-action
         :use (etaf-focusable)
         :on-press on-press)
   (list (format "%s %d" (etaf-inject 'g6b-message "missing") count)))
  :styles
  (styles
   (".g6b-context-action" :background-color "#1F2937")))

(etaf-define-component etaf-test-g6b-attr-leaf (&key label)
  :view
  (box :class '(leaf base) :color "#111111"
    (text (expr label))))

(etaf-define-component etaf-test-g6b-attr-wrapper (&key label)
  :view
  (etaf-test-g6b-attr-leaf :label label))

(etaf-define-component etaf-test-g6b-attr-fragment ()
  :view
  (fragment (text "One") (text "Two")))

(etaf-define-component etaf-test-g6b-attr-text ()
  :view (text "Text"))

(etaf-define-component etaf-test-g6b-attr-role ()
  :view (box :role 'button "Role"))

(etaf-define-component etaf-test-g6b-attr-shape (&key split)
  :render
  (if split
      (etaf-node 'fragment nil
                 (list (etaf-node 'text nil (list "One"))
                       (etaf-node 'text nil (list "Two"))))
    (etaf-node 'box nil (list "Stable"))))

(etaf-define-component etaf-test-g6b-dsl-panel ()
  :view
  (column :background-color "#203040" :padding-inline 1
    (row :class 'header (slot :name 'header))
    (box (slot))
    (row :class 'actions (slot :name 'actions))))

(etaf-define-component etaf-test-g6b-code-panel ()
  :render
  (etaf-node
   'column (list :background-color "#203040" :padding-inline 1)
   (list
    (etaf-node 'row (list :class 'header)
               (etaf-current-slot 'header))
    (etaf-node 'box nil (etaf-current-slot 'default))
    (etaf-node 'row (list :class 'actions)
               (etaf-current-slot 'actions)))))

(defun etaf-test-g6b-dsl-counter (&rest _arguments)
  "Ordinary Elisp function colliding with a Component registry name."
  'ordinary-function)

(defun etaf-test-g6b--text (buffer)
  "Return BUFFER text without properties."
  (with-current-buffer buffer
    (substring-no-properties (buffer-string))))

(defun etaf-test-g6b--face-at (buffer regexp)
  "Return BUFFER face at the first REGEXP match."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (re-search-forward regexp)
      (get-text-property (match-beginning 0) 'face))))

(defun etaf-test-g6b--face-value (face property)
  "Return PROPERTY from anonymous FACE values."
  (cond
   ((and (listp face) (keywordp (car-safe face)))
    (plist-get face property))
   ((listp face)
    (cl-loop for entry in face
             when (and (listp entry) (keywordp (car-safe entry))
                       (plist-member entry property))
             return (plist-get entry property)))))

(ert-deftest etaf-component-frontends-definition-boundary-is-strict ()
  "Definitions choose one frontend and keep exact registry names."
  (should (etaf--component-spec-p
           (gethash 'etaf-test-g6b-dsl-counter etaf--view-registry)))
  (should-not (gethash 'test-g6b-dsl-counter etaf--view-registry))
  (should (eq 'ordinary-function (etaf-test-g6b-dsl-counter)))
  (dolist
      (definition
       '((etaf-define-component invalid-both ()
           :view (box) :render (etaf-node 'box nil nil))
         (etaf-define-component invalid-neither () :setup nil)
         (etaf-define-component invalid-reserved (&key key) :view (box))
         (etaf-define-component invalid-setup-view ()
           :setup (etaf-node 'box nil nil) :view (box))))
    (should-error (macroexpand definition)
                  :type 'etaf-component-definition-error)))

(ert-deftest etaf-node-validates-code-mode-structure ()
  "Code nodes accept typed values and reject DSL or raw-list ambiguity."
  (should (etaf--view-node-p
           (etaf-node 'box (list :padding 1) (list "A"))))
  (should (etaf--component-call-p
           (etaf-node 'etaf-test-g6b-dsl-counter
                      (list :initial 1) nil)))
  (should-error (etaf-node 'box (list :if t) nil)
                :type 'etaf-component-call-error)
  (should-error (etaf-node 'box nil '((text "raw")))
                :type 'etaf-component-call-error)
  (should-error (etaf-node 'box nil nil '((header . ("H"))))
                :type 'etaf-component-call-error)
  (should-error (etaf-node 'box (list :key nil) nil)
                :type 'etaf-component-call-error))

(ert-deftest etaf-component-directives-validate-branch-and-loop-grammar ()
  "DSL directives reject ambiguous structure during macro expansion."
  (dolist
      (form
       '((etaf-view (column (text :else t "orphan")))
         (etaf-view
          (column (text :if t :for (item '(1)) :key item "bad")))
         (etaf-view (column (text :for (item '(1)) "missing key")))
         (etaf-view
          (column (text :if nil "a") (text :else maybe "b")))))
    (should-error (macroexpand form) :type 'etaf-view-syntax-error)))

(ert-deftest etaf-component-directives-render-and-retain-keyed-identity ()
  "Branch changes and keyed reorder publish locally with stable item ids."
  (let ((buffer " *etaf-g6b-directives*")
        (selected (etaf-ref nil))
        (items (etaf-ref '((a . "A") (b . "B")))))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (lambda ()
             (etaf-view
              (etaf-test-g6b-directives
               :selected (etaf-value selected)
               :items (etaf-value items)))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (generation (etaf-runtime-current-generation runtime))
                 (range
                  (cl-loop for _identity being the hash-keys of
                           (etaf-generation-identity-index generation)
                           using (hash-values semantic-id)
                           for semantic = (etaf--pvec-get
                                           (etaf-generation-semantic-nodes
                                            generation)
                                           semantic-id)
                           when (and (etaf--semantic-range-p semantic)
                                     (etaf--semantic-range-keyed-key-order
                                      semantic))
                           return semantic))
                 (a-roots
                  (gethash
                   'a
                   (etaf--semantic-range-keyed-item-root-id-index range)))
                 (b-roots
                  (gethash
                   'b
                   (etaf--semantic-range-keyed-item-root-id-index range))))
            (should (string-match-p "No selection"
                                    (etaf-test-g6b--text buffer)))
            (should (string-match-p "A[[:space:]]+B"
                                    (etaf-test-g6b--text buffer)))
            (setf (etaf-value selected) "Selected")
            (setf (etaf-value items) '((b . "B2") (a . "A")))
            (should (string-match-p "Selected"
                                    (etaf-test-g6b--text buffer)))
            (should (string-match-p "B2[[:space:]]+A"
                                    (etaf-test-g6b--text buffer)))
            (let* ((generation (etaf-runtime-current-generation runtime))
                   (next (etaf--pvec-get
                          (etaf-generation-semantic-nodes generation)
                          (etaf--semantic-range-semantic-id range))))
              (should
               (equal
                a-roots
                (gethash
                 'a
                 (etaf--semantic-range-keyed-item-root-id-index next))))
              (should
               (equal
                b-roots
                (gethash
                 'b
                 (etaf--semantic-range-keyed-item-root-id-index next)))))
            (let ((generation (etaf-runtime-current-generation runtime))
                  (text (with-current-buffer buffer (buffer-string))))
              (should-error
               (setf (etaf-value items) '((a . "A") (a . "duplicate")))
               :type 'etaf-component-call-error)
              (should (eq generation
                          (etaf-runtime-current-generation runtime)))
              (should (equal-including-properties
                       text (with-current-buffer buffer (buffer-string)))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (when-let* ((live (get-buffer buffer))) (kill-buffer live)))))

(ert-deftest etaf-component-keyed-loop-owns-transparent-component-spans ()
  "A keyed item may be a transparent multi-root Component without a fake Box."
  (let ((buffer " *etaf-g6b-component-spans*")
        (items (etaf-ref '((a . "A") (b . "B")))))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (lambda ()
             (etaf-view
              (etaf-test-g6b-component-loop :items (etaf-value items)))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (generation (etaf-runtime-current-generation runtime))
                 (range
                  (cl-loop for _identity being the hash-keys of
                           (etaf-generation-identity-index generation)
                           using (hash-values semantic-id)
                           for semantic =
                           (etaf--pvec-get
                            (etaf-generation-semantic-nodes generation)
                            semantic-id)
                           when (and (etaf--semantic-range-p semantic)
                                     (equal
                                      '(a b)
                                      (etaf--semantic-range-keyed-key-order
                                       semantic)))
                           return semantic))
                 (root-index
                  (etaf--semantic-range-keyed-item-root-id-index range))
                 (a-roots (copy-sequence (gethash 'a root-index)))
                 (b-roots (copy-sequence (gethash 'b root-index))))
            (should (string-match-p
                     "A-1[[:space:]]+A-2[[:space:]]+B-1[[:space:]]+B-2"
                     (etaf-test-g6b--text buffer)))
            (should (= 1 (length a-roots)))
            (should (= 1 (length b-roots)))
            (should
             (etaf--semantic-component-p
              (etaf--pvec-get
               (etaf-generation-semantic-nodes generation) (car a-roots))))
            (setf (etaf-value items) '((b . "B2") (a . "A")))
            (setq generation (etaf-runtime-current-generation runtime)
                  range
                  (etaf--pvec-get
                   (etaf-generation-semantic-nodes generation)
                   (etaf--semantic-range-semantic-id range))
                  root-index
                  (etaf--semantic-range-keyed-item-root-id-index range))
            (should (string-match-p
                     "B2-1[[:space:]]+B2-2[[:space:]]+A-1[[:space:]]+A-2"
                     (etaf-test-g6b--text buffer)))
            (should (equal a-roots (gethash 'a root-index)))
            (should (equal b-roots (gethash 'b root-index)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (when-let* ((live (get-buffer buffer))) (kill-buffer live)))))

(ert-deftest etaf-component-frontends-project-default-and-named-slots ()
  "DSL and code Components preserve caller-owned slot order and styling."
  (let ((dsl-buffer " *etaf-g6b-dsl-slots*")
        (code-buffer " *etaf-g6b-code-slots*"))
    (unwind-protect
        (progn
          (etaf-mount
           dsl-buffer
           (etaf-view
            (etaf-test-g6b-dsl-panel
             (slot :name 'header (text :font-weight 'bold "Header"))
             (slot :name 'actions "Actions")
             "Body")))
          (etaf-mount
           code-buffer
           (etaf-node
            'etaf-test-g6b-code-panel nil (list "Body")
            (list
             (cons 'header
                   (list (etaf-node 'text (list :font-weight 'bold)
                                    (list "Header"))))
             (cons 'actions (list "Actions")))))
          (dolist (buffer (list dsl-buffer code-buffer))
            (let ((text (etaf-test-g6b--text buffer)))
              (should (string-match-p
                       "Header[[:space:]]+Body[[:space:]]+Actions" text)))
            (should (eq 'bold
                        (etaf-test-g6b--face-value
                         (etaf-test-g6b--face-at buffer "Header")
                         :weight)))))
      (dolist (buffer-name (list dsl-buffer code-buffer))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
          (etaf-unmount runtime))
        (when-let* ((buffer (get-buffer buffer-name)))
          (kill-buffer buffer))))))

(ert-deftest etaf-component-frontends-render-state-layout-style-and-events ()
  "DSL and code Components mount equivalent stateful interactive surfaces."
  (setq etaf-test-g6b-dsl-setup-count 0
        etaf-test-g6b-code-setup-count 0)
  (let ((dsl-buffer " *etaf-g6b-dsl*")
        (code-buffer " *etaf-g6b-code*"))
    (unwind-protect
        (progn
          (etaf-mount dsl-buffer
                      (etaf-view
                       (etaf-test-g6b-dsl-counter :initial 1)))
          (etaf-mount code-buffer
                      (etaf-node 'etaf-test-g6b-code-counter
                                 (list :initial 1) nil))
          (should (= 1 etaf-test-g6b-dsl-setup-count))
          (should (= 1 etaf-test-g6b-code-setup-count))
          (dolist (buffer (list dsl-buffer code-buffer))
            (let ((text (etaf-test-g6b--text buffer)))
              (should (string-match-p "Count 1" text))
              (should (string-match-p "Increment" text))
              (should (= 2 (length (split-string text "\n" t)))))
            (should (eq 'bold
                        (etaf-test-g6b--face-value
                         (etaf-test-g6b--face-at buffer "Count 1")
                         :weight))))
          (let* ((dsl-runtime (etaf-runtime-for-buffer dsl-buffer))
                 (code-runtime (etaf-runtime-for-buffer code-buffer))
                 (dsl-instance
                  (car (hash-table-values (etaf-runtime-instances dsl-runtime))))
                 (code-instance
                  (car (hash-table-values (etaf-runtime-instances code-runtime)))))
            (etaf-dispatch-event dsl-runtime 'g6b-dsl-increment 'press)
            (etaf-dispatch-event code-runtime 'g6b-code-increment 'press)
            (should (string-match-p "Count 2"
                                    (etaf-test-g6b--text dsl-buffer)))
            (should (string-match-p "Count 2"
                                    (etaf-test-g6b--text code-buffer)))
            (should (= 1 etaf-test-g6b-dsl-setup-count))
            (should (= 1 etaf-test-g6b-code-setup-count))
            (should (eq dsl-instance
                        (car (hash-table-values
                              (etaf-runtime-instances dsl-runtime)))))
            (should (eq code-instance
                        (car (hash-table-values
                              (etaf-runtime-instances code-runtime)))))))
      (dolist (buffer-name (list dsl-buffer code-buffer))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
          (etaf-unmount runtime))
        (when-let* ((buffer (get-buffer buffer-name)))
          (kill-buffer buffer))))))

(ert-deftest etaf-component-state-distinguishes-nil-from-no-setup ()
  "A completed setup may return nil without becoming setup absence."
  (let ((buffer " *etaf-g6b-nil-state*"))
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-view (etaf-test-g6b-nil-state)))
          (should (equal "nil-state" (etaf-test-g6b--text buffer))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (when-let* ((live (get-buffer buffer))) (kill-buffer live))))
  (should-error (etaf-state) :type 'etaf-component-definition-error))

(ert-deftest etaf-component-key-is-framework-owned-and-render-result-is-typed ()
  "Identity metadata stays outside business props and node lists stay invalid."
  (let ((buffer " *etaf-g6b-key-boundary*")
        (invalid-buffer " *etaf-g6b-invalid-result*"))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-test-g6b-key-boundary :key 'stable :value "Business")))
          (should (string-match-p "Business/no-key"
                                  (etaf-test-g6b--text buffer)))
          (should-error
           (etaf-mount
            invalid-buffer
            (etaf-view (etaf-test-g6b-invalid-list-result)))
           :type 'etaf-component-call-error))
      (dolist (buffer-name (list buffer invalid-buffer))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
          (etaf-unmount runtime))
        (when-let* ((live (get-buffer buffer-name))) (kill-buffer live))))))

(ert-deftest etaf-component-render-side-effect-rolls-back-completely ()
  "A detectable render mutation preserves the published generation and state."
  (let ((buffer " *etaf-g6b-render-rollback*")
        (fail (etaf-ref nil)))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (lambda ()
             (etaf-view
              (etaf-test-g6b-rollback :fail (etaf-value fail)))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (generation (etaf-runtime-current-generation runtime))
                 (published (with-current-buffer buffer (buffer-string)))
                 (instance
                  (car (hash-table-values (etaf-runtime-instances runtime))))
                 (state (etaf--component-instance-state instance)))
            (should-error (setf (etaf-value fail) t)
                          :type 'etaf-render-write-error)
            (should (eq generation
                        (etaf-runtime-current-generation runtime)))
            (should (equal-including-properties
                     published (with-current-buffer buffer (buffer-string))))
            (should (= 7 (etaf-value state)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (when-let* ((live (get-buffer buffer))) (kill-buffer live)))))

(ert-deftest etaf-component-lifecycle-and-scope-cleanup-are-ordered ()
  "Mount, update, removal, and Scope cleanup each run once in order."
  (let ((buffer " *etaf-g6b-lifecycle*")
        (label (etaf-ref "A")))
    (setq etaf-test-g6b-lifecycle nil)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (lambda ()
             (etaf-view
              (etaf-test-g6b-lifecycle :label (etaf-value label)))))
          (should (equal '(mounted) etaf-test-g6b-lifecycle))
          (setf (etaf-value label) "B")
          (should (equal '(mounted updated) etaf-test-g6b-lifecycle))
          (should (string-match-p "B" (etaf-test-g6b--text buffer)))
          (etaf-unmount (etaf-runtime-for-buffer buffer))
          (should (equal '(mounted updated unmounted cleanup)
                         etaf-test-g6b-lifecycle)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (when-let* ((live (get-buffer buffer))) (kill-buffer live)))))

(ert-deftest etaf-component-frontends-compose-context-theme-style-and-behavior ()
  "Test child inheritance and composition; separate tests cover slot authors."
  (let ((buffer " *etaf-g6b-composition*")
        (count (etaf-ref 0)))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (lambda ()
             (etaf-view
              (etaf-test-g6b-provider
                :count (etaf-value count)
                :on-press
                (let ((source count))
                  (lambda ()
                    (setf (etaf-value source)
                          (1+ (etaf-value source)))))))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (face (etaf-test-g6b--face-at buffer "Context 0"))
                 (props
                  (etaf-runtime-host-props-for
                   runtime 'g6b-context-action)))
            (should (equal "#34D399"
                           (etaf-test-g6b--face-value face :foreground)))
            (should (equal "#1F2937"
                           (etaf-test-g6b--face-value face :background)))
            (should (= 0 (plist-get props :tab-index)))
            (etaf-dispatch-event runtime 'g6b-context-action 'press)
            (should (string-match-p "Context 1"
                                    (etaf-test-g6b--text buffer)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (when-let* ((live (get-buffer buffer))) (kill-buffer live)))))

(ert-deftest etaf-component-host-attrs-fall-through-one-root-chain ()
  "Undeclared Host attrs cross a root Component chain without entering props."
  (let ((buffer " *etaf-g6b-attrs*")
        (color (etaf-ref "#224466")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (lambda ()
             (etaf-view
              (etaf-test-g6b-attr-wrapper
               :label "Leaf" :class '(caller base)
               :color (etaf-value color) :padding-inline 2
               :ref 'g6b-attr-root))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (instances (hash-table-values
                             (etaf-runtime-instances runtime)))
                 (props (etaf-runtime-host-props-for
                         runtime 'g6b-attr-root)))
            (should (equal '("leaf" "base" "caller")
                           (plist-get props :class)))
            (should (equal "#224466" (plist-get props :color)))
            (should (equal "#224466"
                           (etaf-test-g6b--face-value
                            (etaf-test-g6b--face-at buffer "Leaf")
                            :foreground)))
            (should (= 2 (plist-get props :padding-inline)))
            (setf (etaf-value color) "#335577")
            (setq props (etaf-runtime-host-props-for
                         runtime 'g6b-attr-root))
            (should (equal "#335577" (plist-get props :color)))
            (should (equal "#335577"
                           (etaf-test-g6b--face-value
                            (etaf-test-g6b--face-at buffer "Leaf")
                            :foreground)))
            (should
             (cl-every
              (lambda (instance)
                (memq instance (hash-table-values
                                (etaf-runtime-instances runtime))))
              instances))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (when-let* ((live (get-buffer buffer))) (kill-buffer live)))))

(ert-deftest etaf-component-host-attrs-reject-ambiguous-or-invalid-targets ()
  "Fallthrough fails closed for unknown, duplicate, conflicting, and multi-root input."
  (should-error
   (etaf-node 'etaf-test-g6b-attr-leaf (list :unknown-attr 1) nil)
   :type 'etaf-component-call-error)
  (should-error
   (etaf-node 'etaf-test-g6b-attr-leaf
              (list :bgcolor "red" :background-color "blue") nil)
   :type 'etaf-component-call-error)
  (dolist
      (entry
       `((" *etaf-g6b-attrs-fragment*"
          ,(etaf-view (etaf-test-g6b-attr-fragment :color "red")))
         (" *etaf-g6b-attrs-text*"
          ,(etaf-view (etaf-test-g6b-attr-text :padding 1)))))
    (let ((buffer (car entry)))
      (unwind-protect
          (should-error (etaf-mount buffer (cadr entry))
                        :type 'etaf-component-call-error)
        (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
          (etaf-unmount runtime))
        (when-let* ((live (get-buffer buffer))) (kill-buffer live)))))
  (let ((buffer " *etaf-g6b-attrs-role*"))
    (unwind-protect
        (should-error
         (etaf-mount
           buffer
           (etaf-view
            (etaf-test-g6b-attr-role
             :role 'navigation :ref 'g6b-attrs-role)))
         :type 'etaf-component-call-error)
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (when-let* ((live (get-buffer buffer))) (kill-buffer live)))))

(ert-deftest etaf-component-host-attrs-rollback-root-shape-failure ()
  "A later multi-root result cannot publish or retire the previous root."
  (let ((buffer " *etaf-g6b-attrs-rollback*")
        (split (etaf-ref nil)))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (lambda ()
             (etaf-view
              (etaf-test-g6b-attr-shape
               :split (etaf-value split) :color "#224466"))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (generation (etaf-runtime-current-generation runtime))
                 (published (with-current-buffer buffer (buffer-string))))
            (should-error (setf (etaf-value split) t)
                          :type 'etaf-component-call-error)
            (should (eq generation
                        (etaf-runtime-current-generation runtime)))
            (should (equal-including-properties
                     published (with-current-buffer buffer (buffer-string))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (when-let* ((live (get-buffer buffer))) (kill-buffer live)))))

(ert-deftest etaf-component-compiled-host-sites-are-instance-scoped ()
  "Two instances of one compiled Component never share generated Host refs."
  (let ((buffer " *etaf-g6b-instance-sites*"))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (column
             (etaf-test-g6b-attr-leaf :key 'one :label "One")
             (etaf-test-g6b-attr-leaf :key 'two :label "Two"))))
          (should (string-match-p
                   "One[[:space:]]+Two" (etaf-test-g6b--text buffer))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (when-let* ((live (get-buffer buffer))) (kill-buffer live)))))

(provide 'etaf-component-frontends-tests)
;;; etaf-component-frontends-tests.el ends here
