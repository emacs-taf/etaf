;;; etaf-component-tests.el --- Component lifecycle and composition -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'etaf-test-support)

(defvar etaf-component-test-log nil
  "Lifecycle events recorded by the test Components.")

(etaf-define-component etaf-component-test-leaf (&key name)
  "Record NAME's lifecycle."
  :setup
  (progn
    (push (list 'setup name) etaf-component-test-log)
    (etaf-on-mounted (lambda () (push (list 'mounted name) etaf-component-test-log)))
    (etaf-on-updated (lambda () (push (list 'updated name) etaf-component-test-log)))
    (etaf-on-unmounted (lambda () (push (list 'unmounted name) etaf-component-test-log)))
    nil)
  :view (text (expr (format "leaf %s" name))))

(etaf-define-component etaf-component-test-parent (&key show)
  "Render a leaf while SHOW is non-nil."
  :setup (progn
           (etaf-on-mounted (lambda () (push '(mounted parent) etaf-component-test-log)))
           nil)
  :view
  (column
    (etaf-component-test-leaf :if (etaf-value show) :name 'child)
    (text "parent")))

(etaf-define-component etaf-component-test-tracked (&key value)
  "Derive a computed from tracked prop VALUE."
  :bindings ((doubled (let ((input (etaf-prop 'value)))
                        (etaf-computed (lambda () (* 2 (etaf-value input))))))
             (setups (etaf-ref 0)))
  :setup (etaf-update-value setups #'1+)
  :view (text (expr (format "%d doubled %d setup %d"
                            value (etaf-value doubled) (etaf-value setups)))))

(etaf-define-component etaf-component-test-validated (&key count)
  "Accept only integer COUNT."
  :validate (etaf-check-prop :count count (integerp count) "an integer")
  :view (text (expr (format "count %d" count))))

(etaf-define-component etaf-component-test-render (&key items)
  "Render ITEMS with the ordinary Elisp frontend."
  :render
  (etaf-view (column (text :for (item items) :key item (expr (format "* %s" item))))))

(etaf-define-component etaf-component-test-stateful ()
  "Expose setup state through `etaf-state'."
  :setup (list :greeting "hello")
  :view (text (expr (plist-get (etaf-state) :greeting))))

(etaf-define-component etaf-component-test-provider (&key value)
  "Provide VALUE to descendants."
  :setup (etaf-provide 'etaf-component-test-key value)
  :view (column (etaf-component-test-consumer) (slot)))

(etaf-define-component etaf-component-test-consumer ()
  "Show the injected value."
  :bindings ((value (etaf-inject 'etaf-component-test-key "missing")))
  :view (text (expr (format "injected %s"
                            (if (etaf-ref-p value) (etaf-value value) value)))))

(etaf-define-component etaf-component-test-watcher (&key source seen)
  "Record SOURCE, the injected Context and the Runtime into the cons SEEN."
  :setup
  (progn
    (etaf-watch-effect
     (lambda ()
       (setcar seen (list (etaf-value source)
                          (etaf-inject 'etaf-component-test-key "missing")
                          (and (etaf-current-runtime) t)))))
    nil)
  :view (text "watcher"))

(etaf-define-component etaf-component-test-watcher-provider (&key source seen)
  "Provide a context key around a child that watches SOURCE."
  :setup (etaf-provide 'etaf-component-test-key "provided")
  :view (etaf-component-test-watcher :source source :seen seen))

(etaf-define-component etaf-component-test-watch-source (&key source seen)
  "Record SOURCE through a two-argument `etaf-watch' callback into SEEN."
  :setup
  (progn
    (etaf-watch source
                (lambda (new _old)
                  (setcar seen (list new
                                     (etaf-inject 'etaf-component-test-key "missing")
                                     (and (etaf-current-runtime) t))))
                :immediate t)
    nil)
  :view (text "watcher"))

(etaf-define-component etaf-component-test-watch-provider (&key source seen)
  "Provide a context key around a child that watches SOURCE."
  :setup (etaf-provide 'etaf-component-test-key "provided")
  :view (etaf-component-test-watch-source :source source :seen seen))

(etaf-define-component etaf-component-test-computed-watcher (&key source seen)
  "Record SOURCE through a computed binding into SEEN."
  :bindings ((derived (etaf-computed
                       (lambda ()
                         (list (etaf-value source)
                               (etaf-inject 'etaf-component-test-key "missing")
                               (and (etaf-current-runtime) t)))
                       :test #'equal)))
  :setup
  (progn
    (etaf-watch derived (lambda (new _old) (setcar seen new)) :immediate t)
    nil)
  :view (text "computed watcher"))

(etaf-define-component etaf-component-test-computed-provider (&key source seen)
  "Provide a context key around a child that computes over SOURCE."
  :setup (etaf-provide 'etaf-component-test-key "provided")
  :view (etaf-component-test-computed-watcher :source source :seen seen))

(etaf-define-component etaf-component-test-themed ()
  "Paint with a theme token."
  :view (column (box :class "swatch" "swatch"))
  :styles ((".swatch" :color (etaf-theme-token :accent "#000000"))))

(etaf-define-component etaf-component-test-theme-root (&key theme)
  "Provide THEME to a themed child."
  :setup (etaf-theme-provide theme)
  :view (column (etaf-component-test-themed)))

(etaf-define-component etaf-component-test-appearance-root (&key appearance)
  "Provide APPEARANCE and render what a child reads."
  :setup (etaf-appearance-provide appearance)
  :view (column (expr (format "appearance:%s" (etaf-appearance)))))

(etaf-define-component etaf-component-test-hover-themed ()
  "Hover with a Theme token nested in a :hover-style plist."
  :view (column (box :ref 'hoverer :class "hoverer"
                     :hover-style (list :background-color
                                        (etaf-theme-token :tint "#DCE7FA"))
                     "hover")))

(etaf-define-component etaf-component-test-hover-root (&key theme)
  "Provide THEME to a hover token child."
  :setup (etaf-theme-provide theme)
  :view (column (etaf-component-test-hover-themed)))

(etaf-define-component etaf-component-test-local (&key on-ref)
  "Expose a local Host reference to ON-REF."
  :bindings ((target (etaf-local-ref 'target)))
  :setup (funcall on-ref target)
  :view (column (box :ref target :tab-index 0 "target")))

(etaf-define-component etaf-component-test-optional (&key mode)
  "Return nil, one View or a fragment depending on MODE."
  :bindings ((stamp (etaf-ref (random))))
  :render
  (pcase (etaf-value mode)
    ('none nil)
    ('one (etaf-view (text (expr (format "one %s" (numberp (etaf-value stamp)))))))
    (_ (etaf-view (fragment (text "first") (text "second"))))))

(ert-deftest etaf-component-lifecycle-hooks-run-in-order ()
  "Mounted hooks run children first; branch removal runs unmounted hooks."
  (setq etaf-component-test-log nil)
  (let ((show (etaf-ref t)))
    (etaf-test-with-mount (runtime (etaf-view (etaf-component-test-parent :show show)))
      (should (equal (reverse etaf-component-test-log)
                     '((setup child) (mounted child) (mounted parent))))
      (setq etaf-component-test-log nil)
      (etaf-set-value show nil)
      (should (equal (etaf-test-lines) '("parent")))
      (should (member '(unmounted child) etaf-component-test-log))
      (setq etaf-component-test-log nil)
      (etaf-set-value show t)
      (should (equal (etaf-test-lines) '("leaf child" "parent")))
      (should (equal (reverse etaf-component-test-log) '((setup child) (mounted child))))
      (setq etaf-component-test-log nil)
      (etaf-unmount runtime)
      (should (member '(unmounted child) etaf-component-test-log)))))

(ert-deftest etaf-component-tracked-props-update-without-setup ()
  "`etaf-prop' tracks inputs while setup and bindings run once."
  (let ((value (etaf-ref 2)))
    (etaf-test-with-mount (_runtime (etaf-view (column (etaf-component-test-tracked
                                                        :value (etaf-value value)))))
      (should (equal (etaf-test-lines) '("2 doubled 4 setup 1")))
      (etaf-set-value value 5)
      (should (equal (etaf-test-lines) '("5 doubled 10 setup 1"))))))

(ert-deftest etaf-component-validation-rejects-invalid-input ()
  "Invalid props signal and keep the last accepted render."
  (let ((count (etaf-ref 1)))
    (should-error (etaf-render (etaf-view (etaf-component-test-validated :count "x"))))
    (etaf-test-with-mount (_runtime (etaf-view (column (etaf-component-test-validated
                                                        :count (etaf-value count)))))
      (should (equal (etaf-test-lines) '("count 1")))
      (should-error (etaf-set-value count 'bad))
      (should (equal (etaf-test-lines) '("count 1")))
      (etaf-set-value count 3)
      (should (equal (etaf-test-lines) '("count 3"))))))

(ert-deftest etaf-component-render-frontend-and-state ()
  "`:render' returns ordinary Views and setup state is readable."
  (let ((items (etaf-ref '(a b))))
    (etaf-test-with-mount (_runtime (etaf-view (column (etaf-component-test-render
                                                        :items (etaf-value items))
                                                       (etaf-component-test-stateful))))
      (should (equal (etaf-test-lines) '("* a" "* b" "hello")))
      (etaf-set-value items '(b c))
      (should (equal (etaf-test-lines) '("* b" "* c" "hello"))))))

(ert-deftest etaf-component-context-reaches-descendants ()
  "Provided values reach rendered descendants; slot content keeps caller Context."
  (let ((value (etaf-ref "one")))
    (etaf-test-with-mount (_runtime (etaf-view (etaf-component-test-provider
                                                :value value
                                                (etaf-component-test-consumer))))
      (should (equal (etaf-test-lines) '("injected one" "injected missing")))
      (etaf-set-value value "two")
      (should (equal (etaf-test-lines) '("injected two" "injected missing")))))
  (etaf-test-with-mount (_runtime (etaf-view (column (etaf-component-test-consumer))))
    (should (equal (etaf-test-lines) '("injected missing")))))

(ert-deftest etaf-component-watcher-keeps-its-environment-on-rerun ()
  "A Component watcher keeps Context and Runtime on later reactive runs."
  (let* ((source (etaf-ref 1))
         (seen (cons nil nil)))
    (etaf-test-with-mount (_runtime (etaf-view (etaf-component-test-watcher-provider
                                                :source source :seen seen)))
      (should (equal (car seen) (list 1 "provided" t)))
      (etaf-set-value source 2)
      (should (equal (car seen) (list 2 "provided" t))))))

(ert-deftest etaf-component-watch-callback-keeps-its-environment ()
  "A two-argument `etaf-watch' callback keeps its environment when it reruns."
  (let* ((source (etaf-ref 1))
         (seen (cons nil nil)))
    (etaf-test-with-mount (_runtime (etaf-view (etaf-component-test-watch-provider
                                                :source source :seen seen)))
      (should (equal (car seen) (list 1 "provided" t)))
      (etaf-set-value source 2)
      (should (equal (car seen) (list 2 "provided" t))))))

(ert-deftest etaf-component-computed-keeps-its-environment-on-rerun ()
  "A computed keeps Context and Runtime when it refreshes outside rendering."
  (let* ((source (etaf-ref 1))
         (seen (cons nil nil)))
    (etaf-test-with-mount (_runtime (etaf-view (etaf-component-test-computed-provider
                                                :source source :seen seen)))
      (should (equal (car seen) (list 1 "provided" t)))
      ;; Refresh from a buffer without a Runtime, outside the Component
      ;; render that created the computed.
      (with-temp-buffer (etaf-set-value source 2))
      (should (equal (car seen) (list 2 "provided" t))))))

(ert-deftest etaf-component-theme-tokens-follow-provided-theme ()
  "Theme tokens in Component rules resolve from the provided Theme."
  (let ((theme (etaf-ref '(:accent "#FF0000"))))
    (etaf-test-with-mount (_runtime (etaf-view (etaf-component-test-theme-root :theme theme)))
      (should (equal (etaf-test-face-attribute (etaf-test-face-at "swatch") :foreground)
                     "#FF0000"))
      (etaf-set-value theme '(:accent "#00FF00"))
      (should (equal (etaf-test-face-attribute (etaf-test-face-at "swatch") :foreground)
                     "#00FF00")))))

(ert-deftest etaf-component-appearance-follows-a-provided-ref ()
  "A Component reads the host appearance and re-renders when it switches."
  (let ((appearance (etaf-ref 'dark)))
    (etaf-test-with-mount (_runtime (etaf-view (etaf-component-test-appearance-root
                                                :appearance appearance)))
      (should (string-match-p "appearance:dark"
                              (buffer-substring-no-properties (point-min) (point-max))))
      (etaf-set-value appearance 'light)
      (should (string-match-p "appearance:light"
                              (buffer-substring-no-properties (point-min) (point-max)))))))

(ert-deftest etaf-component-rejects-an-invalid-appearance ()
  "Only light, dark, a ref or a computed is an appearance."
  (let ((error (should-error (etaf-appearance-provide 'sepia)
                             :type 'etaf-context-error)))
    (should (string-match-p "Appearance" (error-message-string error)))))

(ert-deftest etaf-component-hover-style-token-resolves-from-provided-theme ()
  "A token inside :hover-style resolves to the provided Theme colour.
Ebox turns the plist into a native mouse face; an unresolved token is an
invalid face attribute and the hover paint is lost."
  (let ((theme (etaf-ref '(:tint "#FF0000"))))
    (etaf-test-with-mount (runtime (etaf-view (etaf-component-test-hover-root :theme theme)))
      (should (equal (plist-get (plist-get (etaf-runtime-host-props-for runtime 'hoverer)
                                           :hover-style)
                                :background-color)
                     "#FF0000"))
      (save-excursion
        (goto-char (point-min))
        (should (search-forward "hover" nil t))
        (should (equal (plist-get (get-text-property (match-beginning 0) 'mouse-face)
                                  :background)
                       "#FF0000")))
      (etaf-set-value theme '(:tint "#00FF00"))
      (should (equal (plist-get (plist-get (etaf-runtime-host-props-for runtime 'hoverer)
                                           :hover-style)
                                :background-color)
                     "#00FF00")))))

(ert-deftest etaf-component-local-ref-resolves-committed-host ()
  "A local Host reference supports focus and position queries."
  (let (target)
    (etaf-test-with-mount (runtime (etaf-view (etaf-component-test-local
                                               :on-ref (lambda (ref) (setq target ref)))))
      (should target)
      (should (integerp (etaf-host-ref-position runtime target)))
      (etaf-focus runtime target)
      (should (equal (etaf-focused-host-ref runtime) target)))))

(ert-deftest etaf-component-output-shape-changes-keep-bindings ()
  "Output may switch between nil, one View and a fragment."
  (let ((mode (etaf-ref 'one)))
    (etaf-test-with-mount (_runtime (etaf-view (column (text "a")
                                                       (etaf-component-test-optional :mode mode)
                                                       (text "z"))))
      (should (equal (etaf-test-lines) '("a" "one t" "z")))
      (etaf-set-value mode 'none)
      (should (equal (etaf-test-lines) '("a" "z")))
      (etaf-set-value mode 'many)
      (should (equal (etaf-test-lines) '("a" "first" "second" "z")))
      (etaf-set-value mode 'one)
      (should (equal (etaf-test-lines) '("a" "one t" "z"))))))

(ert-deftest etaf-component-error-boundary-handles-errors ()
  "The error boundary returns the handler's value for signaled errors."
  (should (equal (etaf-error-boundary-run (lambda () (error "boom"))
                                          (lambda (err) (cadr err)))
                 "boom"))
  (should (= (etaf-error-boundary-run (lambda () 4) #'ignore) 4)))

(ert-deftest etaf-component-unknown-component-signals ()
  "Unknown Component tags are rejected at View construction."
  (should-error (etaf-node 'etaf-component-test-does-not-exist nil nil)))

(provide 'etaf-component-tests)

;;; etaf-component-tests.el ends here
