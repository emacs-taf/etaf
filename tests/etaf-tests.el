;;; etaf-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'etaf)
(require 'subr-x)

(defvar etaf-test-setup-count 0)

(defvar etaf-test-theme-cell nil)

(defvar etaf-test-prop-cell nil)

(defvar etaf-test-lifecycle-failure-p nil)

(defvar etaf-test-branch-page-cell nil)

(defvar etaf-test-branch-late-cell nil)

(defvar etaf-test-branch-mode-cell nil)

(defvar etaf-test-event-batch-source nil)

(defvar etaf-test-event-resource-fail nil)

(defvar etaf-test-input-render-count 0)

(defvar etaf-test-inline-shared nil)

(defvar etaf-test-inline-shared-evals 0)

(defvar etaf-test-context-provider-source nil)

(defvar etaf-test-context-provider-renders 0)

(defvar etaf-test-context-consumer-renders 0)

(etaf-define-component etaf-test-input-equal (&key label)
  "Count renders of a caller-owned semantic input."
  :view
  (text (expr (progn (cl-incf etaf-test-input-render-count) label))))

(etaf-define-component etaf-test-inline-shared-hosts ()
  "Render one shared source in two distinct text Hosts."
  :view
  (column
   (text :key 'left
         (expr (progn (cl-incf etaf-test-inline-shared-evals)
                      (etaf-value etaf-test-inline-shared))))
   (text :key 'right
         (expr (progn (cl-incf etaf-test-inline-shared-evals)
                      (etaf-value etaf-test-inline-shared))))))

(etaf-define-component etaf-test-generation-context-consumer ()
  "Render one generation-owned Context dependency."
  :setup
  (progn (cl-incf etaf-test-context-consumer-renders) nil)
  :view
  (text :color (etaf-value (etaf-inject 'generation-label)) "context"))

(etaf-define-component etaf-test-generation-context-provider ()
  "Provide a candidate Context value to one retained consumer."
  :setup
  (progn
    ;; Context values are provided during setup as stable reactive sources;
    ;; consumers track the source value without requiring a render-time
    ;; Context mutation.
    (etaf-provide 'generation-label etaf-test-context-provider-source)
    nil)
  :render
  (progn
    (cl-incf etaf-test-context-provider-renders)
    (etaf-value etaf-test-context-provider-source)
    (etaf-node 'etaf-test-generation-context-consumer nil nil)))

(etaf-define-component etaf-test-prop-env-child (&key value)
  "Render VALUE received from a parent Component."
  :view (text (expr value)))

(etaf-define-component etaf-test-prop-env-parent (&key label)
  "Forward dynamic parent LABEL into a nested Component prop."
  :view (etaf-test-prop-env-child :value label))

(defun etaf-test--render-text (view)
  "Return plain rendered text for VIEW."
  (replace-regexp-in-string
   "[[:space:]]+$" ""
   (substring-no-properties (ebox-render (etaf-render view)))
   nil t))

(defun etaf-test--buffer-text (buffer-name)
  "Return normalized plain text from mounted BUFFER-NAME."
  (with-current-buffer buffer-name
    (string-trim
     (replace-regexp-in-string
      "[[:space:]]+" " " (substring-no-properties (buffer-string))))))

(etaf-define-component etaf-test-badge (&key label)
  "Render LABEL as a small semantic test Component."
  :view
  (text :font-weight 'bold (expr label)))

(etaf-define-component etaf-list (&key label)
  "Render LABEL using the collision-safe `list-view' alias."
  :view
  (text (expr label)))

(etaf-define-component etaf-test-slot-card (&key title)
  "Render a title with default and named slot projections."
  :view
  (column
   (text (expr title))
   (slot :name 'header (text :color "#777777" "Default header"))
   (slot (text :color "#777777" "Default body"))))

(etaf-define-component etaf-test-named-slot-consumer ()
  "Render the named header slot for forwarding tests."
  :view
  (slot :name 'header))

(etaf-define-component etaf-test-named-slot-forwarder ()
  "Forward a named slot through a nested Component call."
  :view
  (etaf-test-named-slot-consumer
   (slot :name 'header (text "Forwarded"))))

(etaf-define-component etaf-test-provider ()
  "Provide a reactive theme to descendants."
  :setup
  (let ((theme (etaf-ref 'dark)))
    (setq etaf-test-theme-cell theme)
    (etaf-provide 'theme theme)
    theme)
  :view (column (etaf-test-consumer)))

(etaf-define-component etaf-test-consumer ()
  "Render the nearest Context theme."
  :setup
  (etaf-inject 'theme nil t)
  :view (text (expr (symbol-name (etaf-value (etaf-state))))))

(etaf-define-component etaf-test-prop-stateful (&key label)
  "Render a retained label whose prop can change without rerunning setup."
  :setup
  (progn
    (cl-incf etaf-test-setup-count)
    nil)
  :view (text (expr label)))

(etaf-define-component etaf-test-lifecycle-failure (&key label)
  "Render LABEL and deliberately fail from an update lifecycle hook."
  :setup
  (progn
    (etaf-on-updated
     (lambda ()
       (when etaf-test-lifecycle-failure-p
         (error "test lifecycle failed"))))
    nil)
  :view (text (expr label)))

(etaf-define-component etaf-test-rollback (&key fail)
  "Render a candidate that can deliberately fail during reconciliation."
  :setup
  (let ((cell (etaf-ref 0)))
    (setq etaf-test-prop-cell cell)
    cell)
  :render
  (progn
    (when fail
      (signal 'etaf-runtime-error (list "test candidate failed")))
    (etaf-node 'text nil
               (list (format "stable:%d" (etaf-value (etaf-state)))))))

(etaf-define-component etaf-test-late-branch ()
  "Read a late reactive ref only after switching render branches."
  :setup
  (let ((page (etaf-ref "page"))
        (late (etaf-ref "late"))
        (late-branch (etaf-ref nil)))
    (setq etaf-test-branch-page-cell page
          etaf-test-branch-late-cell late
          etaf-test-branch-mode-cell late-branch)
    (list page late late-branch))
  :view
  (text
   (expr
    (if (etaf-value (nth 2 (etaf-state)))
        (etaf-value (nth 1 (etaf-state)))
      (etaf-value (nth 0 (etaf-state)))))))

(etaf-define-component etaf-test-event-batch-stateful ()
  "Render a callback with computed, watch, and effect dependents."
  :setup
  (let* ((source (etaf-ref 0))
         (computed (etaf-computed
                    (lambda () (* 2 (etaf-value source)))))
         (watch-value (etaf-ref "watch:0"))
         (effect-value (etaf-ref "effect:0"))
         (last-effect "effect:0"))
    (setq etaf-test-event-batch-source source)
    (etaf-watch
     source
     (lambda (new _old)
       (setf (etaf-value watch-value) (format "watch:%d" new)))
     :immediate nil)
    (etaf-watch-effect
     (lambda ()
       (let ((next (format "effect:%d" (etaf-value computed))))
         (unless (equal next last-effect)
           (setq last-effect next)
           (setf (etaf-value effect-value) next)))))
    (list :source source :computed computed
          :watch watch-value :effect effect-value))
  :view
  (column
   (text :ref 'event-batch-trigger
         :on-press
         (let ((source (plist-get (etaf-state) :source)))
           (lambda () (setf (etaf-value source) 2)))
         "Update")
   (text
    (expr
     (format "source=%d computed=%d %s %s"
             (etaf-value (plist-get (etaf-state) :source))
             (etaf-value (plist-get (etaf-state) :computed))
             (etaf-value (plist-get (etaf-state) :watch))
             (etaf-value (plist-get (etaf-state) :effect)))))))

(etaf-define-component etaf-test-event-batch-noop ()
  "Render an event callback that performs no state write."
  :view
  (text :ref 'event-batch-noop
        :on-press (lambda () nil)
        "No-op"))

(etaf-define-component etaf-test-event-batch-behavior ()
  "Render a toggleable Behavior whose callback writes two refs."
  :setup
  (let ((left (etaf-ref nil))
        (right (etaf-ref nil)))
    (list left right))
  :view
  (column
   (text :ref 'event-batch-behavior
         :use
         (let ((left (car (etaf-state))) (right (cadr (etaf-state))))
           (list
            (etaf-toggleable
             :value left
             :on-change
             (lambda (value)
               (setf (etaf-value left) value
                     (etaf-value right) value)))))
         "Toggle")
   (text
    (expr
     (format "left=%s right=%s"
             (if (etaf-value (car (etaf-state))) "on" "off")
             (if (etaf-value (cadr (etaf-state))) "on" "off"))))))

(defvar etaf-test-theme-property-render-count 0)

(defvar etaf-test-theme-property-cell nil)

(defun etaf-test--face-value (face property)
  "Return PROPERTY from anonymous FACE contributions."
  (cond
   ((symbolp face)
    (let* ((remap (assq face face-remapping-alist))
           (mapped
            (cl-some (lambda (spec)
                       (and (listp spec) (keywordp (car-safe spec))
                            (plist-get spec property)))
                     (cdr remap)))
           (attribute
            (pcase property
              (:foreground :foreground)
              (:background :background)
              (_ property)))
           (value (face-attribute face attribute nil nil)))
      (or mapped
          (unless (memq value '(unspecified unspecified-fg unspecified-bg))
            value))))
   ((and (listp face) (keywordp (car-safe face)))
    (plist-get face property))
   ((listp face)
    (cl-some (lambda (entry)
               (etaf-test--face-value entry property))
             face))))

(etaf-define-component etaf-test-theme-property-effect ()
  "Update a Theme-bound Host property without rerunning this Component."
  :setup
  (let* ((dark (etaf-ref nil))
         (theme
          (etaf-computed
           (lambda ()
             (if (etaf-value dark)
                 '(:color "#EEEEEE" :bgcolor "#111111")
               '(:color "#111111" :bgcolor "#FFFFFF"))))))
    (setq etaf-test-theme-property-cell dark)
    (etaf-theme-provide theme)
    dark)
  :render
  (progn
    (cl-incf etaf-test-theme-property-render-count)
    (let ((dark (etaf-state)))
      (etaf-node
       'text
       (list :ref 'theme-property-toggle
             :color (etaf-theme-token :color)
             :bgcolor (etaf-theme-token :bgcolor)
             :on-press
             (lambda ()
               (setf (etaf-value dark) (not (etaf-value dark)))))
       (list "Theme property")))))

(etaf-define-component etaf-test-event-batch-resource (&key resource fail)
  "Render synchronous Resource success and error state transitions."
  :setup
  (let ((instance-resource resource)
        (instance-fail fail))
    (list instance-resource instance-fail))
  :view
  (column
   (text :ref 'event-batch-resource-success
         :on-press
         (let ((resource (car (etaf-state)))
               (fail (cadr (etaf-state))))
           (lambda ()
             (setf (etaf-value fail) nil)
             (etaf-resource-load resource)))
         "Load success")
   (text :ref 'event-batch-resource-error
         :on-press
         (let ((resource (car (etaf-state)))
               (fail (cadr (etaf-state))))
           (lambda ()
             (setf (etaf-value fail) t)
             (etaf-resource-load resource)))
         "Load error")
   (text
    (expr
     (let ((resource (car (etaf-state))))
       (format "status=%s value=%s error=%s"
               (etaf-resource-status resource)
               (or (etaf-resource-value resource) "none")
               (if (etaf-resource-error resource) "yes" "no")))))))

(ert-deftest etaf-view-property-region-precedes-children ()
  "Reject a property that appears after a structural child."
  (should-error
   (macroexpand '(etaf-view (text "Hello" :font-weight 'bold)))
   :type 'etaf-view-syntax-error))

(ert-deftest etaf-view-ordinary-control-flow-belongs-in-expr ()
  "Reject ordinary Elisp control flow in the child region."
  (should-error
   (macroexpand '(etaf-view (text (if checked "yes" "no"))))
   :type 'etaf-view-syntax-error))

(ert-deftest etaf-view-attribute-values-are-ordinary-elisp ()
  "Evaluate an attribute expression without an extra evaluation wrapper."
  (let ((face 'bold)
        (label "Ready"))
    (let ((view (etaf-view (text :font-weight face (expr label)))))
      (should (equal "Ready" (etaf-test--render-text view))))))

(ert-deftest etaf-host-metadata-uses-the-frozen-runtime-grammar ()
  "Semantic metadata should validate before it reaches Runtime or Ebox."
  (should
   (equal "Valid"
          (etaf-test--render-text
           (etaf-view
            (text :ref 'status :role 'status :aria-live 'polite
                  :on-press #'ignore "Valid")))))
  (dolist (view
           (list (etaf-view (text :ref 1.5 "bad"))
                 (etaf-view (text :role '(button) "bad"))
                 (etaf-view (text :aria-live [polite] "bad"))
                 (etaf-view (text :on-press "bad" "bad"))
                 (etaf-view (text :use 1 "bad"))
                 (etaf-view (text :disabled 1 "bad"))
                 (etaf-view (text :tab-index 1.5 "bad"))
                 (etaf-view (text :face 'bold "bad"))
                 (etaf-view (text :surface-properties '(help-echo "bad")
                                  "bad"))
                 (etaf-view (box (text :face 'bold "bad")))
                 (etaf-view
                  (box (text :surface-properties '(help-echo "bad")
                             "bad")))))
    (should-error (etaf-test--render-text view)
                  :type 'etaf-renderer-error))
  (should-error (etaf-view (text :content "bad"))
                :type 'etaf-view-syntax-error))

(ert-deftest etaf-view-expr-evaluates-control-flow ()
  "Use the sole child computation bridge for ordinary control flow."
  (let ((checked t))
    (should
     (equal "yes"
            (etaf-test--render-text
             (etaf-view
              (text (expr (if checked "yes" "no")))))))))

(ert-deftest etaf-view-expr-can-return-a-view ()
  "Allow an expression to return a dynamically constructed View."
  (let ((open t))
    (should
     (equal "Details"
            (etaf-test--render-text
             (etaf-view
              (column
               (expr (when open
                  (etaf-view (text "Details")))))))))))

(ert-deftest etaf-text-expr-requires-one-string ()
  "Reject structural and sequence values at the Text interpolation boundary."
  (dolist (view
           (list
            (etaf-view (text (expr (list "A" "B"))))
            (etaf-view
             (text
              (expr (etaf-view (text :face 'bold "B")))))))
    (should-error (etaf-test--render-text view)
                  :type 'etaf-renderer-error)))

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

(ert-deftest etaf-view-box-rejects-invalid-layout ()
  "Reject an invalid canonical Box layout before publication."
  (should-error
   (etaf-render (etaf-view (box :layout 'masonry "A")))
   :type 'error))

(ert-deftest etaf-runtime-box-retains-child-text-update ()
  "Mounted canonical Box should retain its layout while Text updates."
  (let ((buffer-name " *etaf-box-runtime-test*")
        (source (etaf-ref "A")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (row
                 (text (expr (etaf-value source)))
                 (text "B"))))
          (should (string-match-p "AB" (etaf-test--buffer-text buffer-name)))
          (setf (etaf-value source) "C")
          (should (string-match-p "CB" (etaf-test--buffer-text buffer-name))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-view-prefixed-host-is-not-an-implicit-alias ()
  "Keep the core Host registry exact instead of deriving prefix aliases."
  (should-error (etaf-view (etaf-text "Hello"))
                :type 'etaf-component-call-error))

(ert-deftest etaf-component-prefixed-name-is-not-an-implicit-alias ()
  "Keep an `etaf-' Component name exact in the public registry."
  (should-error (etaf-view (test-badge :label "Ready"))
                :type 'etaf-component-call-error))

(ert-deftest etaf-component-registry-does-not-generate-elisp-aliases ()
  "Use the exact Component name even when an Elisp function collides."
  (should
   (equal "Items"
          (etaf-test--render-text
           (etaf-view (etaf-list :label "Items")))))
  (should-error (etaf-view (list-view :label "Items"))
                :type 'etaf-component-call-error))

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
       :setup value
       :render (etaf-node 'text nil (list value)))))
  (should
   (macroexpand
    '(etaf-define-component styled-component ()
       :styles (("&" :color "red"))
       :view (text "x"))))
  (should-error
   (macroexpand
    '(etaf-define-component ambiguous-component (&key value)
       :view (text "x")
       :render (etaf-node 'text nil (list value))))
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

(ert-deftest etaf-theme-token-updates-host-property-without-component-render ()
  "A reactive Theme token should publish one Host paint update directly."
  (let ((buffer-name " *etaf-theme-property-effect-test*")
        (etaf-test-theme-property-render-count 0)
        (etaf-test-theme-property-cell nil))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf-view (etaf-test-theme-property-effect)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-generation runtime)))
            (should (= etaf-test-theme-property-render-count 1))
            (etaf-dispatch-event runtime 'theme-property-toggle 'press)
            (should (= etaf-test-theme-property-render-count 1))
            (should (= (etaf-runtime-generation runtime) (1+ generation)))
            (should (etaf-value etaf-test-theme-property-cell))
            (with-current-buffer buffer-name
              (let ((face (get-text-property (point-min) 'face)))
                (should (equal (etaf-test--face-value face :foreground)
                               "#EEEEEE"))
                (should (equal (etaf-test--face-value face :background)
                               "#111111"))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-theme-resolves-explicit-light-dark-palette ()
  "Resolve semantic palette pairs without coupling Theme to a renderer."
  (should
   (equal '(:ink "#172033" :paper "#F7F3EA")
          (etaf-theme-resolve-palette
           '(:ink ("#172033" . "#F4F7FF")
             :paper (:light "#F7F3EA" :dark "#111827"))
           'light)))
  (should
   (equal '(:ink "#F4F7FF" :paper "#111827")
          (etaf-theme-resolve-palette
           '(:ink ("#172033" . "#F4F7FF")
             :paper (:light "#F7F3EA" :dark "#111827"))
           'dark)))
  (let ((palette '(:ink ("#172033" . "#F4F7FF")
                   :accent "#3657D6" :border nil)))
    (dolist (mode '(light dark))
      (let ((resolved (etaf-theme-resolve-palette palette mode)))
        (should (equal (plist-get resolved :accent) "#3657D6"))
        (should (plist-member resolved :border))
        (should-not (plist-get resolved :border))
        (setf (plist-get resolved :accent) "changed")))
    (should (equal (plist-get palette :accent) "#3657D6")))
  (should-error
   (etaf-theme-resolve-palette '(:ink "red") 'sepia)
   :type 'etaf-context-error)
  (should-error
   (etaf-theme-resolve-palette '(ink "red") 'light)
   :type 'etaf-context-error)
  (should-error
   (etaf-theme-resolve-palette '(:ink) 'dark)
   :type 'etaf-context-error))

(ert-deftest etaf-box-composes-adjacent-styled-text-runs ()
  "Represent styled runs as sibling Text nodes, never a nested Text tree."
  (let* ((node (etaf-render
                (etaf-view
                 (box "Hello " (text :font-weight 'bold "world") "!"))))
         (content (ebox-render node)))
    (should (equal "Hello world!" (substring-no-properties content)))
    (should (equal '(:weight bold)
                   (get-text-property 6 'face content)))
    (should-not (get-text-property 0 'face content))))

(ert-deftest etaf-runtime-recollects-late-branch-dependencies ()
  "Recollect refs introduced by a branch after the initial mount."
  (let ((buffer-name " *etaf-runtime-late-branch-test*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-test-late-branch)))
          (with-current-buffer buffer-name
            (should (equal "page" (buffer-string))))
          (setf (etaf-value etaf-test-branch-mode-cell) t)
          (with-current-buffer buffer-name
            (should (equal "late" (buffer-string))))
          (setf (etaf-value etaf-test-branch-late-cell) "late-updated")
          (with-current-buffer buffer-name
            (should (equal "late-updated" (buffer-string)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-context-provide-inject-follows-component-tree ()
  "Test Component inheritance; separate slot tests cover author environments."
  (let ((buffer-name " *etaf-context-test*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf-view
                       (etaf-test-provider)))
          (with-current-buffer buffer-name
            (should (equal "dark" (buffer-string))))
          (setf (etaf-value etaf-test-theme-cell) 'light)
          (with-current-buffer buffer-name
            (should (equal "light" (buffer-string)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

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
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
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
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
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
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
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
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-event-dispatch-batches-reactive-publication ()
  "Publish one final tree for a callback's reactive dependency chain."
  (let ((buffer-name " *etaf-event-batch-test*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf-view (etaf-test-event-batch-stateful)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (before (etaf-runtime-generation runtime)))
            (etaf-dispatch-event runtime 'event-batch-trigger 'press)
            (with-current-buffer buffer-name
              (should (string-match-p
                       "source=2 computed=4 watch:2 effect:4"
                       (buffer-string))))
            (should (= 1 (- (etaf-runtime-generation runtime) before)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-runtime-equal-component-input-skips-render ()
  "Promote an input target dependency change without running its render target."
  (let ((buffer-name " *etaf-input-equal-test*") (trigger (etaf-ref 0)))
    (setq etaf-test-input-render-count 0)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (etaf-test-input-equal
             :label (progn (etaf-value trigger) "same"))))
          (setq etaf-test-input-render-count 0)
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (before (etaf-runtime-generation runtime)))
            (setf (etaf-value trigger) 1)
            (should (= (1+ before) (etaf-runtime-generation runtime)))
            (should (zerop etaf-test-input-render-count))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-shared-inline-source-updates-distinct-text-hosts ()
  "Publish two distinct Text hosts that read one shared source in one commit."
  (let ((buffer-name " *etaf-inline-two-host-test*")
        (etaf-test-inline-shared (etaf-ref "0"))
        (etaf-test-inline-shared-evals 0)
        (host-replaces 0) (commits 0))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-test-inline-shared-hosts)))
          (setq etaf-test-inline-shared-evals 0)
          (let ((old-host (symbol-function 'ebox-candidate-replace-host-ref))
                (old-commit (symbol-function 'ebox-commit)))
            (cl-letf (((symbol-function 'ebox-candidate-replace-host-ref)
                       (lambda (&rest args)
                         (cl-incf host-replaces) (apply old-host args)))
                      ((symbol-function 'ebox-commit)
                       (lambda (&rest args)
                         (cl-incf commits) (apply old-commit args))))
              (setf (etaf-value etaf-test-inline-shared) "1")))
          (should (= 2 etaf-test-inline-shared-evals))
          (should (= 2 host-replaces))
          (should (= 1 commits)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-nested-component-input-reads-caller-candidate-props ()
  "Resolve child input thunks from final candidate parent props."
  (let ((buffer-name " *etaf-nested-prop-env-test*") (label (etaf-ref "A")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view (etaf-test-prop-env-parent :label (etaf-value label))))
          (should (equal "A" (etaf-test--buffer-text buffer-name)))
          (setf (etaf-value label) "B")
          (should (equal "B" (etaf-test--buffer-text buffer-name))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-context-provider-promotes-consumer-atomically ()
  "Promote provider and dependent Host property only with their generation."
  (let ((buffer-name " *etaf-generation-context-test*")
        (etaf-test-context-provider-source (etaf-ref "red")))
    (setq etaf-test-context-provider-renders 0
          etaf-test-context-consumer-renders 0)
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf-view (etaf-test-generation-context-provider)))
          (setq etaf-test-context-provider-renders 0
                etaf-test-context-consumer-renders 0)
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (old-generation (etaf-runtime-current-generation runtime)))
            (setf (etaf-value etaf-test-context-provider-source) "blue")
            (should (= 1 etaf-test-context-provider-renders))
            (should (zerop etaf-test-context-consumer-renders))
            (with-current-buffer buffer-name
              (should (equal '(:foreground "blue")
                             (get-text-property 0 'face (buffer-string)))))
            (let ((committed (etaf-runtime-current-generation runtime))
                  (before (etaf-test--buffer-text buffer-name)))
              (cl-letf (((symbol-function 'ebox-commit)
                         (lambda (&rest _)
                           (error "injected Context publication failure"))))
                (should-error
                 (setf (etaf-value etaf-test-context-provider-source) "green")
                 :type 'error))
              (should (eq committed (etaf-runtime-current-generation runtime)))
              (should (equal before (etaf-test--buffer-text buffer-name))))
            (etaf-runtime-flush runtime)
            (with-current-buffer buffer-name
              (should (equal '(:foreground "green")
                             (get-text-property 0 'face (buffer-string)))))
            (should-not (eq old-generation
                            (etaf-runtime-current-generation runtime)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-event-dispatch-noop-does-not-publish ()
  "Do not publish when an event callback changes no reactive state."
  (let ((buffer-name " *etaf-event-noop-test*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-test-event-batch-noop)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (before (etaf-runtime-generation runtime)))
            (etaf-dispatch-event runtime 'event-batch-noop 'press)
            (should (= before (etaf-runtime-generation runtime)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-event-dispatch-batches-behavior-two-ref-write ()
  "Batch a Behavior callback that writes two reactive refs."
  (let ((buffer-name " *etaf-event-behavior-batch-test*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf-view (etaf-test-event-batch-behavior)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (before (etaf-runtime-generation runtime)))
            (etaf-dispatch-event runtime 'event-batch-behavior 'press)
            (should (equal "Toggle left=on right=on"
                           (etaf-test--buffer-text buffer-name)))
            (should (= 1 (- (etaf-runtime-generation runtime) before)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-event-dispatch-batches-resource-success-and-error ()
  "Batch synchronous Resource success and error publications per event."
  (let* ((buffer-name " *etaf-event-resource-batch-test*")
         (fail (etaf-ref nil :name 'etaf-test-event-resource-fail))
         (resource
          (etaf-resource
           (lambda ()
             (if (etaf-value fail)
                 (error "expected resource failure")
               (etaf-resource-result "ok")))
           :immediate nil :name 'etaf-test-event-resource)))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf-view
                       (etaf-test-event-batch-resource
                        :resource resource :fail fail)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (before (etaf-runtime-generation runtime)))
            (etaf-dispatch-event runtime 'event-batch-resource-success 'press)
            (should (equal "Load success Load error status=success value=ok error=no"
                           (etaf-test--buffer-text buffer-name)))
            (should (= 1 (- (etaf-runtime-generation runtime) before)))
            (setq before (etaf-runtime-generation runtime))
            (etaf-dispatch-event runtime 'event-batch-resource-error 'press)
            (with-current-buffer buffer-name
              (should (string-match-p
                       "status=error value=none error=yes"
                       (buffer-string))))
            (should (= 1 (- (etaf-runtime-generation runtime) before)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer))
      (etaf-resource-dispose resource))))

(ert-deftest etaf-mount-publishes-through-ebox ()
  "Mount a View into a buffer using Ebox's buffer publication API."
  (let ((buffer-name " *etaf-test-mount*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf-view (text :color "#F4F6FB" "Mounted")))
          (with-current-buffer buffer-name
            (should (equal "Mounted" (buffer-string)))))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-mount-accepts-final-initial-viewport ()
  "Publish the first generation at its final viewport without a rerender."
  (let ((buffer-name " *etaf-test-initial-viewport*"))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (column :width '(vw 100) :height '(vh 100)
             (text "Viewport")))
           '(:viewport-width 640 :viewport-height 24))
          (let ((report
                 (ebox-surface-update-buffer-viewport
                  (get-buffer buffer-name) 640 24)))
            (should (eq (plist-get report :strategy) 'no-op)))
          (should-error
           (etaf-mount buffer-name (etaf-view (text "Invalid"))
                       '(:unknown-option t)))
          (should-error
           (etaf-mount buffer-name (etaf-view (text "Invalid"))
                       '(:viewport-width 0))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-runtime-refit-reapplies-the-viewport ()
  "Refit a mounted Runtime to an explicit viewport size."
  (let ((buffer-name " *etaf-test-runtime-refit*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (text "Runtime refit"))
                      '(:viewport-width 640 :viewport-height 24))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (window (display-buffer (get-buffer buffer-name))))
            (should (etaf-runtime-refit runtime 320 12))
            (should (eq (plist-get (ebox-surface-update-buffer-viewport
                                    (get-buffer buffer-name) 320 12)
                                   :strategy)
                        'no-op))
            ;; The convenience entry uses the display window's safe width and
            ;; stops being a refit once the Runtime is unmounted.
            (let ((viewport (etaf-refit runtime window)))
              (should (consp viewport))
              (should (> (car viewport) 0))
              (should (eq (plist-get (ebox-surface-update-buffer-viewport
                                      (get-buffer buffer-name)
                                      (car viewport) (cdr viewport))
                                     :strategy)
                          'no-op)))
            (etaf-unmount runtime)
            (should-error (etaf-runtime-refit runtime 320 12)
                          :type 'etaf-runtime-error)
            (should-not (etaf-refit runtime window))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-refit-without-a-mounted-runtime-is-a-no-op ()
  "Refitting a buffer without a mounted Runtime returns nil."
  (let ((buffer (generate-new-buffer " *etaf-test-no-runtime-refit*")))
    (unwind-protect
        (with-current-buffer buffer
          (should-not (etaf-refit)))
      (kill-buffer buffer))))

(ert-deftest etaf-runtime-viewport-reports-and-follows-refits ()
  "The viewport reader reports mount and refit sizes, and unmount signals."
  (let ((buffer-name " *etaf-test-viewport*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (text "Viewport"))
                      '(:viewport-width 640 :viewport-height 24))
          (let ((runtime (etaf-runtime-for-buffer buffer-name)))
            (should (equal (etaf-runtime-viewport runtime) '(640 . 24)))
            (should (etaf-runtime-refit runtime 320 12))
            (should (equal (etaf-runtime-viewport runtime) '(320 . 12)))
            (etaf-unmount runtime)
            (should-error (etaf-runtime-viewport runtime)
                          :type 'etaf-runtime-error)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-runtime-refits-after-a-window-size-change ()
  "A settled window size change refits the mounted Runtime automatically."
  (let ((buffer-name " *etaf-test-auto-refit*")
        (original (get-buffer "*scratch*")))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) (get-buffer-create buffer-name))
          (etaf-mount buffer-name (etaf-view (text "Auto refit")))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (window (get-buffer-window buffer-name t))
                 (before (etaf-runtime-viewport runtime)))
            (should (consp before))
            (set-frame-size (selected-frame) 100 30)
            ;; Batch Emacs has no window manager; notify the framework the way
            ;; a resized frame would.
            (run-hook-with-args 'window-size-change-functions (selected-frame))
            (sleep-for 0.4)
            (let ((after (etaf-runtime-viewport runtime)))
              (should (equal (cdr after) (window-body-height window)))
              (should-not (equal after before)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer))
      (when-let* ((window (selected-window)))
        (when (buffer-live-p original)
          (set-window-buffer window original)))
      (set-frame-size (selected-frame) 80 25))))

(ert-deftest etaf-runtime-keeps-its-canvas-when-transient-ui-borrows-height ()
  "A borrowed height is not a resize, while a frame resize still refits."
  (let ((buffer-name " *etaf-test-transient-refit*")
        (original (get-buffer "*scratch*")))
    (unwind-protect
        (progn
          (set-frame-size (selected-frame) 80 25)
          (delete-other-windows)
          (set-window-buffer (selected-window) (get-buffer-create buffer-name))
          ;; Let a fresh split normalize the frame before the canvas exists,
          ;; so the borrowed height below changes only the window layout.
          (let ((popup (split-window (selected-window) -1 'below)))
            (set-window-buffer popup (get-buffer-create " *etaf-test-popup*"))
            (sleep-for 0.4)
            (etaf-mount buffer-name (etaf-view (text "Transient refit")))
            (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                   (window (get-buffer-window buffer-name t)))
              (unwind-protect
                  (let ((before (etaf-runtime-viewport runtime)))
                    ;; A completion popup borrows lines while the minibuffer is
                    ;; active.  Batch Emacs has no active minibuffer; present
                    ;; it the way the window hook sees completion.
                    (window-resize popup 2)
                    (cl-letf (((symbol-function 'active-minibuffer-window)
                               (lambda ()
                                 (minibuffer-window (selected-frame)))))
                      (run-hook-with-args 'window-size-change-functions
                                          (selected-frame))
                      (sleep-for 0.4)
                      ;; Borrowed space must not refit the committed canvas.
                      (should (equal (etaf-runtime-viewport runtime) before))
                      ;; A frame resize is user geometry even while that UI is
                      ;; present, so the canvas follows the new window.
                      (set-frame-size (selected-frame) 80 21)
                      (run-hook-with-args 'window-size-change-functions
                                          (selected-frame))
                      (sleep-for 0.4)
                      (should (equal (etaf-runtime-viewport runtime)
                                     (cons (car before)
                                           (window-body-height window)))))
                    ;; Releasing the space settles onto the restored height.
                    (delete-window popup)
                    (run-hooks 'minibuffer-exit-hook)
                    (sleep-for 0.4)
                    (should (equal (etaf-runtime-viewport runtime)
                                   (cons (car before)
                                         (window-body-height window))))
                    (should-not (equal (etaf-runtime-viewport runtime) before)))
                (when (window-live-p popup) (delete-window popup))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer))
      (when-let* ((window (selected-window)))
        (when (buffer-live-p original)
          (set-window-buffer window original)))
      (set-frame-size (selected-frame) 80 25))))

(provide 'etaf-tests)
;;; etaf-tests.el ends here
