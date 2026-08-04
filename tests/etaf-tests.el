;;; etaf-tests.el --- ETAF contract tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'etaf)

(defvar etaf-test-state-cell nil)
(defvar etaf-test-setup-count 0)
(defvar etaf-test-mounted-count 0)
(defvar etaf-test-unmounted-count 0)
(defvar etaf-test-theme-cell nil)
(defvar etaf-test-event-count 0)
(defvar etaf-test-behavior-cleanups 0)
(defvar etaf-test-behavior-runtime nil)
(defvar etaf-test-prop-cell nil)
(defvar etaf-test-updated-count 0)
(defvar etaf-test-lifecycle-failure-p nil)

(defun etaf-test--render-text (view)
  "Return plain rendered text for VIEW."
  (replace-regexp-in-string
   "[[:space:]]+$" ""
   (substring-no-properties (ebox-render (etaf-render view)))
   nil t))

(etaf-define-component etaf-test-badge (&key label)
  "Render LABEL as a small semantic test Component."
  :view
  (text :face 'bold (expr :value label)))

(etaf-define-component etaf-list (&key label)
  "Render LABEL using the collision-safe `list-view' alias."
  :view
  (text (expr :value label)))

(etaf-define-component etaf-test-slot-card (&key title)
  "Render a title with default and named slot projections."
  :view
  (column
   (text (expr :value title))
   (slot :name 'header (text :face 'shadow "Default header"))
   (slot (text :face 'shadow "Default body"))))

(etaf-define-component etaf-test-named-slot-consumer ()
  "Render the named header slot for forwarding tests."
  :view
  (slot :name 'header))

(etaf-define-component etaf-test-named-slot-forwarder ()
  "Forward a named slot through a nested Component call."
  :view
  (etaf-test-named-slot-consumer
   (slot :name 'header (text "Forwarded"))))

(etaf-define-component etaf-test-styled-card ()
  "Render style and Theme precedence fixtures."
  :styles
  (styles
   ("&" :color "style-root")
   (".title" :color "style-title" :bgcolor "title-bg"))
  :view
  (column
   (text :class "title" :color "inline-title" "Title")
   (text "Body")))

(etaf-define-component etaf-test-styled-child ()
  "Render a child Host for nested style scope tests."
  :view
  (text :class "nested-child" "Nested"))

(etaf-define-component etaf-test-styled-parent ()
  "Apply a style rule through a nested Component boundary."
  :styles
  (styles
   (".nested-child" :color "parent-color"))
  :view
  (etaf-test-styled-child))

(etaf-define-component etaf-test-themed-text ()
  "Provide Theme defaults to one text Host."
  :setup
  (progn
    (etaf-theme-provide '(:color "theme-color" :bgcolor "theme-bg"))
    (lambda () (etaf-view (text "Themed")))))

(etaf-define-component etaf-test-stateful (&key label)
  "Render a retained counter for Runtime tests."
  :setup
  (let ((cell (etaf-ref 0)))
    (setq etaf-test-state-cell cell)
    (cl-incf etaf-test-setup-count)
    (etaf-on-mounted (lambda () (cl-incf etaf-test-mounted-count)))
    (etaf-on-updated (lambda () (cl-incf etaf-test-updated-count)))
    (etaf-on-unmounted (lambda () (cl-incf etaf-test-unmounted-count)))
    (lambda ()
      (etaf-view
       (text
        (expr :value (format "%s:%d" label (etaf-value cell))))))))

(etaf-define-component etaf-test-provider ()
  "Provide a reactive theme to descendants."
  :setup
  (let ((theme (etaf-ref 'dark)))
    (setq etaf-test-theme-cell theme)
    (etaf-provide 'theme theme)
    (lambda ()
      (etaf-view (column (slot))))))

(etaf-define-component etaf-test-consumer ()
  "Render the nearest Context theme."
  :setup
  (let ((theme (etaf-inject 'theme nil t)))
    (lambda ()
      (etaf-view (text (expr :value (symbol-name (etaf-value theme))))))))

(etaf-define-component etaf-test-prop-stateful (&key label)
  "Render a retained label whose prop can change without rerunning setup."
  :setup
  (progn
    (cl-incf etaf-test-setup-count)
    (lambda ()
      (etaf-view (text (expr :value label))))))

(etaf-define-component etaf-test-lifecycle-failure (&key label)
  "Render LABEL and deliberately fail from an update lifecycle hook."
  :setup
  (progn
    (etaf-on-updated
     (lambda ()
       (when etaf-test-lifecycle-failure-p
         (error "test lifecycle failed"))))
    (lambda ()
      (etaf-view (text (expr :value label))))))

(etaf-define-component etaf-test-rollback (&key fail)
  "Render a candidate that can deliberately fail during reconciliation."
  :setup
  (let ((cell (etaf-ref 0)))
    (setq etaf-test-prop-cell cell)
    (lambda ()
      (when fail
        (signal 'etaf-runtime-error (list "test candidate failed")))
      (etaf-view
       (text
        (expr :value (format "stable:%d" (etaf-value cell))))))))

(etaf-define-behavior etaf-test-cleanup-behavior (&rest attributes)
  "Construct a Behavior whose disposal is visible to tests."
  (apply #'etaf-behavior-create
         'etaf-test-cleanup-behavior
         (append attributes
                 (list :install
                       (lambda ()
                         (setq etaf-test-behavior-runtime
                               (etaf-behavior-context-runtime
                                (etaf-current-behavior-context)))
                         (lambda () (cl-incf etaf-test-behavior-cleanups)))))))

(etaf-action-define etaf-test-action (runtime)
  "Increment the event counter through a named Action."
  (ignore runtime)
  (cl-incf etaf-test-event-count))

(ert-deftest etaf-view-property-region-precedes-children ()
  "Reject a property that appears after a structural child."
  (should-error
   (macroexpand '(etaf-view (text "Hello" :face 'bold)))
   :type 'etaf-view-syntax-error))

(ert-deftest etaf-view-ordinary-control-flow-belongs-in-expr ()
  "Reject ordinary Elisp control flow in the child region."
  (should-error
   (macroexpand '(etaf-view (text (if checked "yes" "no"))))
   :type 'etaf-view-syntax-error))

(ert-deftest etaf-view-quote-is-not-needed-for-structure ()
  "Construct an unquoted structural View and preserve quoted data values."
  (let ((view (etaf-view (text :face 'bold "Hello"))))
    (should (etaf--view-node-p view))
    (should (equal 'bold (plist-get (etaf--view-node-props view) :face)))
    (should (equal "Hello" (etaf-test--render-text view)))))

(ert-deftest etaf-view-attribute-values-are-ordinary-elisp ()
  "Evaluate an attribute expression without an extra evaluation wrapper."
  (let ((face 'bold)
        (label "Ready"))
    (let ((view (etaf-view (text :face face (expr :value label)))))
      (should (equal "Ready" (etaf-test--render-text view))))))

(ert-deftest etaf-view-expr-evaluates-control-flow ()
  "Use the sole child computation bridge for ordinary control flow."
  (let ((checked t))
    (should
     (equal "yes"
            (etaf-test--render-text
             (etaf-view
              (text (expr :value (if checked "yes" "no")))))))))

(ert-deftest etaf-view-expr-can-return-a-view ()
  "Allow an expression to return a dynamically constructed View."
  (let ((open t))
    (should
     (equal "Details"
            (etaf-test--render-text
             (etaf-view
              (column
               (expr
                :value
                (when open
                  (etaf-view (text "Details")))))))))))

(ert-deftest etaf-view-expr-can-return-a-sequence ()
  "Flatten a sequence returned by `expr' into the surrounding Host."
  (should
   (equal "AB"
          (etaf-test--render-text
           (etaf-view
            (text (expr :value (list "A" "B"))))))))

(ert-deftest etaf-view-expr-rejects-extra-properties ()
  "Reject an expr property other than `:value'."
  (should-error
   (macroexpand '(etaf-view (text (expr :test checked :value "yes"))))
   :type 'etaf-view-syntax-error))

(ert-deftest etaf-view-quoted-view-data-is-not-executed ()
  "Reject quoted View data when it reaches the executable child boundary."
  (should-error
   (macroexpand '(etaf-view (text (quote (text "not-a-view")))))
   :type 'etaf-view-syntax-error))

(ert-deftest etaf-view-layouts-lower-to-ebox ()
  "Lower row and column Hosts through Ebox's public constructors."
  (should
   (equal "AB"
          (etaf-test--render-text
           (etaf-view (row (text "A") (text "B"))))))
  (should
   (equal "A\nB"
          (etaf-test--render-text
           (etaf-view (column (text "A") (text "B")))))))

(ert-deftest etaf-view-grid-lowers-to-ebox-grid ()
  "Lower the Grid Host through Ebox's two-dimensional layout node."
  (let ((node (etaf-render
               (etaf-view
                (grid
                 :grid-template-columns '((20) (20))
                 (text "A")
                 (text "B"))))))
    (should (eq (plist-get node :ebox-type) 'grid))
    (should (string-match-p "A" (substring-no-properties (ebox-render node))))
    (should (string-match-p "B" (substring-no-properties (ebox-render node))))))

(ert-deftest etaf-view-prefixed-host-alias-lowers-to-canonical-host ()
  "Resolve an explicit `etaf-' Host spelling to its core Host name."
  (should
   (equal "Hello"
          (etaf-test--render-text
           (etaf-view (etaf-text "Hello"))))))

(ert-deftest etaf-component-view-renders-props ()
  "Render a stateless Component from its declared props."
  (let ((view (etaf-view (etaf-test-badge :label "Ready"))))
    (should (etaf--component-call-p view))
    (should (equal "Ready" (etaf-test--render-text view)))))

(ert-deftest etaf-component-prefixed-name-has-short-alias ()
  "Resolve an `etaf-' Component through its public View alias."
  (should
   (equal "Ready"
          (etaf-test--render-text
           (etaf-view (test-badge :label "Ready"))))))

(ert-deftest etaf-component-alias-avoids-elisp-collision ()
  "Use a semantic alias when the unprefixed name is an Elisp function."
  (should
   (equal "Items"
          (etaf-test--render-text
           (etaf-view (list-view :label "Items"))))))

(ert-deftest etaf-component-rejects-unknown-props ()
  "Reject undeclared Component props at the Component boundary."
  (should-error
   (etaf-view (etaf-test-badge :unknown t))
   :type 'etaf-component-call-error))

(ert-deftest etaf-component-definition-keywords-have-one-owner ()
  "Accept the two definition modes and reject ambiguous combinations."
  (should
   (macroexpand
    '(etaf-define-component setup-component (&key value)
       :setup (lambda () (etaf-view (text (expr :value value)))))))
  (should
   (macroexpand
    '(etaf-define-component styled-component ()
       :styles (styles ("&" :color "red"))
       :view (text "x"))))
  (should-error
   (macroexpand
    '(etaf-define-component ambiguous-component (&key value)
       :setup value
       :view (text "x")))
   :type 'etaf-component-definition-error)
  (should-error
   (macroexpand
    '(etaf-define-component invalid-component ()
       :behavior value))
   :type 'etaf-component-definition-error))

(ert-deftest etaf-component-slots-share-one-default-and-named-model ()
  "Render default children and explicit named slot contributions."
  (should
   (equal "Card\nHeader\nBody"
          (etaf-test--render-text
           (etaf-view
            (etaf-test-slot-card :title "Card"
             (slot :name 'header (text "Header"))
             (text "Body"))))))
  (should
   (equal "Card\nDefault header\nDefault body"
          (etaf-test--render-text
           (etaf-view (etaf-test-slot-card :title "Card")))))
  (should
   (equal "Card\nDefault body"
          (etaf-test--render-text
           (etaf-view
            (etaf-test-slot-card
             :title "Card"
             (slot :name 'header))))))
  (should-error
   (macroexpand '(etaf-view (etaf-test-slot-card (slot "bad"))))
   :type 'etaf-view-syntax-error)
  (should-error
   (macroexpand
    '(etaf-view
      (etaf-test-slot-card (slot :name header (text "bad")))))
   :type 'etaf-view-syntax-error)
  (should-error
   (macroexpand
    '(etaf-view
      (etaf-test-slot-card (slot :name nil (text "bad")))))
   :type 'etaf-view-syntax-error))

(ert-deftest etaf-component-nested-slot-inputs-stay-named ()
  "Treat a nested Component's slot child as input, not as projection."
  (should
   (equal "Forwarded"
          (etaf-test--render-text
           (etaf-view (etaf-test-named-slot-forwarder))))))

(ert-deftest etaf-styles-have-root-class-and-inline-precedence ()
  "Apply component styles only at matching scope and preserve inline props."
  (let* ((node (etaf-render (etaf-view (etaf-test-styled-card))))
         (content-node (plist-get node :ebox-content-node))
         (children (plist-get content-node :children))
         (title (car children))
         (body (cadr children)))
    (should (equal "inline-title" (ebox-get title :color)))
    (should (equal "title-bg" (ebox-get title :bgcolor)))
    (should (equal "style-root" (ebox-get node :color)))
    (should-not (ebox-get body :color))))

(ert-deftest etaf-styles-continue-through-nested-components ()
  "Apply a parent Component selector to a nested Component Host."
  (let ((node (etaf-render (etaf-view (etaf-test-styled-parent)))))
    (should (equal "parent-color" (ebox-get node :color)))))

(ert-deftest etaf-mounted-styles-continue-through-nested-components ()
  "Apply a parent Component selector through the mounted Runtime."
  (let ((buffer-name " *etaf-mounted-style-test*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-test-styled-parent)))
          (should
           (equal "parent-color"
                  (ebox-get
                   (etaf-runtime-root-node
                    (etaf-runtime-for-buffer buffer-name))
                   :color))))
      (when-let ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-theme-defaults-are-inherited-and-overridable ()
  "Apply Theme defaults while allowing explicit Host properties to win."
  (let ((buffer-name " *etaf-theme-test*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-test-themed-text)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (node (etaf-runtime-root-node runtime)))
            (should (equal "theme-color" (ebox-get node :color)))
            (should (equal "theme-bg" (ebox-get node :bgcolor)))))
      (when-let ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-text-supports-inline-propertized-runs ()
  "Lower nested text Hosts to one Ebox content surface with text properties."
  (let* ((node (etaf-render
                (etaf-view
                 (text "Hello " (text :face 'bold "world") "!"))))
         (content (ebox-get node :content)))
    (should (equal "Hello world!" (substring-no-properties content)))
    (should (eq 'bold (get-text-property 6 'face content)))
    (should-not (get-text-property 0 'face content))))

(ert-deftest etaf-runtime-retains-setup-and-reactively-commits ()
  "Run setup once, update through a ref, and dispose on unmount."
  (let ((buffer-name " *etaf-runtime-test*"))
    (setq etaf-test-state-cell nil
          etaf-test-setup-count 0
          etaf-test-mounted-count 0
          etaf-test-unmounted-count 0
          etaf-test-updated-count 0)
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf-view (etaf-test-stateful :label "Count")))
          (should (equal "Count:0" (etaf-test--render-text
                                     (etaf-view (text "Count:0")))))
          (with-current-buffer buffer-name
            (should (equal "Count:0" (buffer-string))))
          (should (= etaf-test-setup-count 1))
          (should (= etaf-test-mounted-count 1))
          (setf (etaf-value etaf-test-state-cell) 1)
          (with-current-buffer buffer-name
            (should (equal "Count:1" (buffer-string))))
          (should (= etaf-test-setup-count 1))
          (should (= etaf-test-updated-count 1))
          (etaf-unmount (etaf-runtime-for-buffer buffer-name))
          (should (= etaf-test-unmounted-count 1)))
      (when-let ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-context-provide-inject-follows-component-tree ()
  "Resolve the nearest Context and react to its provided ref."
  (let ((buffer-name " *etaf-context-test*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf-view
                       (etaf-test-provider
                        (etaf-test-consumer))))
          (with-current-buffer buffer-name
            (should (equal "dark" (buffer-string))))
          (setf (etaf-value etaf-test-theme-cell) 'light)
          (with-current-buffer buffer-name
            (should (equal "light" (buffer-string)))))
      (when-let ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-behavior-event-and-action-share-runtime-boundary ()
  "Install a Behavior, dispatch its Host callback, and dispose it."
  (let ((buffer-name " *etaf-event-test*"))
    (setq etaf-test-event-count 0
          etaf-test-behavior-cleanups 0)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (text
             :ref 'interactive
             :use (list (etaf-test-cleanup-behavior))
             :on-press (lambda () (etaf-dispatch 'etaf-test-action))
             "Press")))
          (let ((runtime (etaf-runtime-for-buffer buffer-name)))
            (etaf-dispatch-event runtime 'interactive 'press)
            (should (= etaf-test-event-count 1))
            (should (equal '(press)
                           (mapcar #'car
                                   (gethash 'interactive
                                            (etaf-runtime-handlers runtime)))))
            (etaf-unmount runtime))
          (should (= etaf-test-behavior-cleanups 1)))
      (when-let ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-behavior-replacement-disposes-previous-installer ()
  "Dispose a replaced Behavior while retaining the public installer path."
  (let ((buffer-name " *etaf-behavior-replace-test*")
        (marker (etaf-ref 0)))
    (setq etaf-test-behavior-cleanups 0
          etaf-test-behavior-runtime nil)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (text
             :ref 'behavior-host
             :use (list (etaf-test-cleanup-behavior
                         :class (format "mode-%d" (etaf-value marker))))
             "Behavior")))
          (should (etaf-runtime-p etaf-test-behavior-runtime))
          (setf (etaf-value marker) 1)
          (should (= 1 etaf-test-behavior-cleanups)))
      (when-let ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-toggleable-reads-reactive-value-at-event-time ()
  "Use the current reactive value when a toggleable Behavior is pressed."
  (let ((value (etaf-ref nil)) received)
    (let ((behavior
           (etaf-toggleable
            :value value
            :on-change (lambda (next) (setq received next))
            :class "toggle")))
      (should (equal "toggle"
                     (plist-get (etaf-behavior-spec-attributes behavior)
                                :class)))
      (funcall (plist-get (etaf-behavior-spec-attributes behavior) :on-press))
      (should (eq t received))
      (setf (etaf-value value) t)
      (funcall (plist-get (etaf-behavior-spec-attributes behavior) :on-press))
      (should (eq nil received)))))

(ert-deftest etaf-focusable-supplies-default-tab-stop ()
  "Give a focusable Behavior the standard tab index unless overridden."
  (should (= 0 (plist-get (etaf-behavior-spec-attributes (etaf-focusable))
                          :tab-index)))
  (should-not (plist-get
               (etaf-behavior-spec-attributes
                (etaf-focusable :tab-index nil))
               :tab-index)))

(ert-deftest etaf-reactive-computed-watch-and-cleanup-share-one-model ()
  "Compute values, watch changes, and dispose watch cleanup deterministically."
  (let* ((source (etaf-ref 1))
         (computed (etaf-computed (lambda () (* 2 (etaf-value source)))))
         (watch-values nil)
         (cleanup-count 0)
         (stop-watch
          (etaf-watch source
                      (lambda (new old)
                        (push (list new old) watch-values))
                      :immediate t))
         (stop-effect
          (etaf-watch-effect
           (lambda ()
             (etaf-value source)
             (lambda () (cl-incf cleanup-count))))))
    (unwind-protect
        (progn
          (should (= 2 (etaf-value computed)))
          (setf (etaf-value source) 2)
          (should (= 4 (etaf-value computed)))
          (should (equal '((2 1) (1 nil)) watch-values))
          (should (= 1 cleanup-count))
          (funcall stop-watch)
          (funcall stop-effect)
          (should (= 2 cleanup-count))
          (setf (etaf-value source) 3)
          (should (equal '((2 1) (1 nil)) watch-values)))
      (funcall stop-watch)
      (funcall stop-effect))))

(ert-deftest etaf-reactive-effect-restores-dependencies-after-failure ()
  "Keep the previous dependency set when an effect run fails."
  (let* ((source (etaf-ref 0))
         (runs 0)
         (fail-p nil)
         (effect (etaf-reactive-effect-create
                  (lambda ()
                    (etaf-value source)
                    (cl-incf runs)
                    (when fail-p
                      (error "expected effect failure"))))))
    (etaf-reactive-effect-run effect)
    (setq fail-p t)
    (should-error (setf (etaf-value source) 1))
    (should (= 2 runs))
    (setq fail-p nil)
    (setf (etaf-value source) 2)
    (should (= 3 runs))
    (etaf--stop-effect effect)))

(ert-deftest etaf-view-raw-ebox-is-an-explicit-backend-escape ()
  "Lower a public Ebox node only through the explicit raw escape."
  (let ((node
         (etaf-render
          (etaf-view
           (raw-ebox
            :key 7
            :value (ebox-create :content "Backend"))))))
    (should (equal "Backend" (ebox-get node :content)))
    (should (= 7 (ebox-get node :key)))))

(ert-deftest etaf-stateful-props-update-without-rerunning-setup ()
  "Track a reactive root prop while retaining one Component setup Scope."
  (let ((buffer-name " *etaf-prop-update-test*")
        (label (etaf-ref "A")))
    (setq etaf-test-setup-count 0)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (etaf-test-prop-stateful :label (etaf-value label))))
          (with-current-buffer buffer-name
            (should (equal "A" (buffer-string))))
          (setf (etaf-value label) "B")
          (with-current-buffer buffer-name
            (should (equal "B" (buffer-string))))
          (should (= 1 etaf-test-setup-count)))
      (when-let ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-runtime-keeps-last-committed-view-after-render-error ()
  "Rollback a failed candidate without losing the last committed buffer."
  (let ((buffer-name " *etaf-rollback-test*")
        (fail-p (etaf-ref nil)))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view (etaf-test-rollback :fail (etaf-value fail-p))))
          (with-current-buffer buffer-name
            (should (equal "stable:0" (buffer-string))))
          (should-error (setf (etaf-value fail-p) t)
                        :type 'etaf-runtime-error)
          (with-current-buffer buffer-name
            (should (equal "stable:0" (buffer-string))))
          (setf (etaf-value fail-p) nil)
          (with-current-buffer buffer-name
            (should (equal "stable:0" (buffer-string)))))
      (when-let ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-runtime-keeps-published-state-when-lifecycle-fails ()
  "Keep retained state aligned with the published tree after hook failure."
  (let ((buffer-name " *etaf-lifecycle-error-test*")
        (label (etaf-ref "A")))
    (setq etaf-test-lifecycle-failure-p nil)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (etaf-test-lifecycle-failure :label (etaf-value label))))
          (setq etaf-test-lifecycle-failure-p t)
          (should-error (setf (etaf-value label) "B") :type 'error)
          (should (etaf-runtime-mounted-p
                   (etaf-runtime-for-buffer buffer-name)))
          (with-current-buffer buffer-name
            (should (equal "B" (buffer-string))))
          (setq etaf-test-lifecycle-failure-p nil)
          (setf (etaf-value label) "C")
          (with-current-buffer buffer-name
            (should (equal "C" (buffer-string)))))
      (when-let ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-events-support-payload-and-cyclic-focus ()
  "Dispatch a payload and cycle focus through visible tab-index Hosts."
  (let ((buffer-name " *etaf-focus-test*")
        payload)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (column
             (text :ref 'first :tab-index 0 "First")
             (text :ref 'second :tab-index 1
                   :on-input (lambda (value) (setq payload value))
                   "Second"))))
          (let ((runtime (etaf-runtime-for-buffer buffer-name)))
            (should (eq 'first (etaf-focus-next runtime)))
            (should (eq 'second (etaf-focus-next runtime)))
            (should (eq 'first (etaf-focus-next runtime)))
            (etaf-dispatch-event runtime 'second 'input "value" t)
            (should (equal "value" payload))))
      (when-let ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-mount-publishes-through-ebox ()
  "Mount a View into a buffer using Ebox's buffer publication API."
  (let ((buffer-name " *etaf-test-mount*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf-view (text :color "#F4F6FB" "Mounted")))
          (with-current-buffer buffer-name
            (should (equal "Mounted" (buffer-string)))))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

;;; etaf-tests.el ends here
