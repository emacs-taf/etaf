;;; etaf-tests.el --- ETAF contract tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'subr-x)
(require 'etaf)

;; This suite locks ETAF range and slot semantics against the named Elisp
;; projection plans.  Keep an optional locally built Ebox module from
;; replacing those plans with `native-frame'; native execution is covered by
;; the Playground integration and performance gates.
(setq ebox-native-reflow-module-path nil)

(defvar etaf-test-state-cell nil)
(defvar etaf-test-setup-count 0)
(defvar etaf-test-mounted-count 0)
(defvar etaf-test-unmounted-count 0)
(defvar etaf-test-theme-cell nil)
(defvar etaf-test-event-count 0)
(defvar etaf-test-behavior-cleanups 0)
(defvar etaf-test-behavior-installs 0)
(defvar etaf-test-behavior-runtime nil)
(defvar etaf-test-prop-cell nil)
(defvar etaf-test-updated-count 0)
(defvar etaf-test-lifecycle-failure-p nil)
(defvar etaf-test-branch-page-cell nil)
(defvar etaf-test-branch-late-cell nil)
(defvar etaf-test-branch-mode-cell nil)
(defvar etaf-test-event-batch-source nil)
(defvar etaf-test-event-resource-fail nil)
(defvar etaf-test-retained-render-counts nil)
(defvar etaf-test-next-turn-target nil)
(defvar etaf-test-next-turn-source nil)
(defvar etaf-test-next-turn-sink nil)
(defvar etaf-test-input-render-count 0)
(defvar etaf-test-priority-render-source nil)
(defvar etaf-test-priority-render-count 0)
(defvar etaf-test-local-style-source nil)
(defvar etaf-test-lazy-computed-base nil)
(defvar etaf-test-lazy-computed-value nil)
(defvar etaf-test-wide-parent-source nil)
(defvar etaf-test-wide-parent-cells nil)
(defvar etaf-test-range-source nil)
(defvar etaf-test-range-static-count 10)
(defvar etaf-test-range-evals 0)
(defvar etaf-test-range-component-renders 0)
(defvar etaf-test-range-left-evals 0)
(defvar etaf-test-range-right-evals 0)
(defvar etaf-test-range-host-prop-calls 0)
(defvar etaf-test-unsupported-range-source nil)
(defvar etaf-test-string-range-source nil)
(defvar etaf-test-nested-range-present nil)
(defvar etaf-test-nested-range-source nil)
(defvar etaf-test-nested-range-evals 0)
(defvar etaf-test-inline-shared nil)
(defvar etaf-test-inline-shared-evals 0)
(defvar etaf-test-inline-branch-mode nil)
(defvar etaf-test-inline-branch-left nil)
(defvar etaf-test-inline-branch-right nil)
(defvar etaf-test-inline-branch-evals 0)
(defvar etaf-test-inline-branch-updated 0)
(defvar etaf-test-inline-priority-source nil)
(defvar etaf-test-inline-priority-evals 0)
(defvar etaf-test-inline-priority-renders 0)
(defvar etaf-test-inline-priority-updated 0)
(defvar etaf-test-inline-styled-source nil)
(defvar etaf-test-inline-styled-evals 0)
(defvar etaf-test-inline-host-prop-calls 0)
(defvar etaf-test-slot-parent-renders 0)
(defvar etaf-test-slot-forwarder-renders 0)
(defvar etaf-test-slot-consumer-renders 0)
(defvar etaf-test-slot-source nil)
(defvar etaf-test-slot-range-evals 0)
(defvar etaf-test-fragment-range-evals 0)
(defvar etaf-test-fragment-owner-renders 0)
(defvar etaf-test-fragment-source nil)
(defvar etaf-test-transparent-source nil)
(defvar etaf-test-transparent-renders 0)
(defvar etaf-test-transparent-parent-renders 0)
(defvar etaf-test-transparent-inner-renders 0)
(defvar etaf-test-transparent-outer-renders 0)
(defvar etaf-test-ancestor-parent-source nil)
(defvar etaf-test-ancestor-child-source nil)
(defvar etaf-test-context-provider-source nil)
(defvar etaf-test-context-provider-renders 0)
(defvar etaf-test-context-consumer-renders 0)
(defvar etaf-test-context-range-evals 0)
(defvar etaf-test-slot-author-updated 0)
(defvar etaf-test-slot-consumer-updated 0)
(defvar etaf-test-slot-branch-left nil)
(defvar etaf-test-slot-branch-right nil)
(defvar etaf-test-detached-list-source nil)
(defvar etaf-test-detached-theme-source nil)
(defvar etaf-test-detached-row-renders 0)

(defun etaf-test--input-root (input)
  "Return INPUT's single canonical root for structural assertions."
  (ebox-canonical-input--single-root input "ETAF test input"))

(defun etaf-test--mounted-specified-value (buffer-name node name)
  "Return mounted NODE's specified NAME from BUFFER-NAME's source generation."
  (ebox-style-node-specified-value
   node name nil
   (plist-get (ebox--buffer-render-state (get-buffer buffer-name))
              :source-index)))

(defun etaf-test--range-items ()
  "Return keyed text Views from `etaf-test-range-source'."
  (cl-incf etaf-test-range-evals)
  (mapcar (lambda (entry)
            (etaf--view-call 'text
                             (list :key (car entry) :class "slot-item")
                             (list (cdr entry))))
          (etaf-value etaf-test-range-source)))

(defun etaf-test--prefixed-range-items (prefix)
  "Return current Range items with key and content PREFIX."
  (mapcar (lambda (entry)
            (let ((key (intern (format "%s-%s" prefix (car entry)))))
              (etaf--view-call 'text (list :key key :ref key)
                               (list (format "%s%s" prefix (cdr entry))))))
          (etaf-value etaf-test-range-source)))

(defun etaf-test--unsupported-range-value ()
  "Return a Host, Component, or raw value for direct Range rejection tests."
  (pcase (etaf-value etaf-test-unsupported-range-source)
    ('component
     (etaf--view-call 'etaf-test-badge (list :label "component") nil))
    ('deep-component
     (etaf--view-call
      'column (list :key 'outer)
      (list (etaf--component-call-create
             :spec etaf-test-badge--etaf-component-definition
             :props (list :label "deep") :slots nil))))
    ('deep-expr-component
     (etaf--view-call
      'column (list :key 'outer)
      (list (etaf--expr-create
             :token 'etaf-test-deep-unsupported-site
             :thunk
             (lambda ()
               (etaf--component-call-create
                :spec etaf-test-badge--etaf-component-definition
                :props (list :label "deep-expr") :slots nil))))))
    (_ (etaf--view-call 'text (list :key 'safe) (list "safe")))))

(defun etaf-test--nested-range-children ()
  "Return keyed nested Hosts from the nested Range source."
  (let ((state (etaf-value etaf-test-nested-range-source)))
    (append
     (and (cdr state)
          (list (etaf--view-call 'text (list :key 'sibling)
                                 (list "sibling"))))
     (list (etaf--view-call 'text (list :key 'nested)
                            (list (car state)))))))

(defun etaf-test--nested-range-value ()
  "Return one nested Host item or nil for recursive identity tests."
  (cl-incf etaf-test-nested-range-evals)
  (when (etaf-value etaf-test-nested-range-present)
    (etaf--view-call
     'column (list :key 'item)
     (list (etaf--expr-create
            :token 'etaf-test-nested-inner-site
            :thunk #'etaf-test--nested-range-children)))))

(defun etaf-test--slot-range-items ()
  "Return keyed Host items from the current slot source."
  (cl-incf etaf-test-slot-range-evals)
  (mapcar (lambda (entry)
            (etaf--view-call 'text
                             (list :key (car entry) :class "slot-item")
                             (list (cdr entry))))
          (etaf-value etaf-test-slot-source)))

(defun etaf-test--fragment-range-items ()
  "Return keyed Host items from the current fragment source."
  (cl-incf etaf-test-fragment-range-evals)
  (mapcar (lambda (entry)
            (etaf--view-call 'text (list :key (car entry))
                             (list (cdr entry))))
          (etaf-value etaf-test-fragment-source)))

(defun etaf-test--retained-leaf-value (label cell)
  "Record LABEL render and return CELL's current text."
  (puthash label (1+ (gethash label etaf-test-retained-render-counts 0))
           etaf-test-retained-render-counts)
  (format "%s=%s" label (etaf-value cell)))

(etaf-define-component etaf-test-retained-leaf (&key label cell)
  "Render one independently reactive retained leaf."
  :view
  (text (expr :value (etaf-test--retained-leaf-value label cell))))

(etaf-define-component etaf-test-setup-read-owner
    (&key setup-source render-source)
  "Read SETUP-SOURCE only during setup and render RENDER-SOURCE."
  :setup
  (progn
    (etaf-value setup-source)
    (lambda ()
      (etaf-view (text (expr :value (etaf-value render-source)))))))

(etaf-define-component etaf-test-dependency-only (&key source)
  "Track SOURCE while returning semantically equal output."
  :view
  (text (expr :value (progn (etaf-value source) "same"))))

(etaf-define-component etaf-test-input-equal (&key label)
  "Count renders of a caller-owned semantic input."
  :view
  (text (expr :value
              (progn (cl-incf etaf-test-input-render-count) label))))

(etaf-define-component etaf-test-target-priority (&key label)
  "Render LABEL with an independently dirty render dependency."
  :view
  (text (expr :value
              (progn
                (cl-incf etaf-test-priority-render-count)
                (format "%s/%s" label
                        (etaf-value etaf-test-priority-render-source))))))

(etaf-define-component etaf-test-local-style-parent ()
  "Project a locally reactive caller-owned slot through a styled child."
  :styles
  (styles (".live" :color "retained-color"))
  :view
  (etaf-test-styled-slot-child
   (text :class "live"
         (expr :value (etaf-value etaf-test-local-style-source)))))

(etaf-define-component etaf-test-lazy-computed-owner ()
  "Create a lazy computed first evaluated by the render target."
  :setup
  (let* ((base (etaf-ref 1))
         (computed (etaf-computed (lambda () (* 2 (etaf-value base))))))
    (setq etaf-test-lazy-computed-base base
          etaf-test-lazy-computed-value computed)
    (lambda ()
      (etaf-view (text (expr :value (number-to-string
                                     (etaf-value computed))))))))

(etaf-define-component etaf-test-wide-parent ()
  "Render a wide stable child list around one parent-owned value."
  :setup
  (lambda ()
    (etaf--view-call
     'column nil
     (cons
      (etaf--view-call
       'text nil (list (format "parent=%s"
                               (etaf-value etaf-test-wide-parent-source))))
      (cl-loop for cell in etaf-test-wide-parent-cells for index from 0
               collect
               (etaf--view-call 'etaf-test-retained-leaf
                                (list :key index :label index :cell cell)
                                nil))))))

(etaf-define-component etaf-test-direct-range ()
  "Render static siblings and one direct retained material-child Range."
  :setup
  (let ((range (etaf--expr-create
                :token 'etaf-test-direct-range-site
                :thunk #'etaf-test--range-items))
        (color (etaf--expr-create
                :token 'etaf-test-range-color-site
                :thunk (lambda ()
                         (cl-incf etaf-test-range-host-prop-calls)
                         "red"))))
    (lambda ()
      (cl-incf etaf-test-range-component-renders)
      (etaf--view-node-create
       :name 'column :props nil
       :children
       (append
        (cl-loop for index below etaf-test-range-static-count
                 collect (etaf--view-call
                          'text (append
                                 (list :key (intern (format "static-%s" index)))
                                 (and (zerop index) (list :color color)))
                          (list (format "S%s" index))))
        (list range))))))

(etaf-define-component etaf-test-two-direct-ranges ()
  "Render two disjoint direct material Ranges from one source."
  :setup
  (let ((left (etaf--expr-create
               :token 'etaf-test-left-range-site
               :thunk (lambda ()
                        (cl-incf etaf-test-range-left-evals)
                        (etaf-test--prefixed-range-items "L"))))
        (right (etaf--expr-create
                :token 'etaf-test-right-range-site
                :thunk (lambda ()
                         (cl-incf etaf-test-range-right-evals)
                         (etaf-test--prefixed-range-items "R")))))
    (lambda ()
      (etaf--view-node-create :name 'column :props nil
                              :children
                              (list (etaf--view-call 'text
                                                     (list :key 'static)
                                                     (list "S"))
                                    left right)))))

(etaf-define-component etaf-test-macro-range-token ()
  "Expose one macro-compiled direct expr callsite."
  :view
  (column (expr :value nil)))

(etaf-define-component etaf-test-public-direct-range ()
  "Exercise a public macro-compiled direct material-child expr."
  :view
  (column
   (text :key 'public-static "S")
   (expr :value (etaf-test--range-items))))

(etaf-define-component etaf-test-counted-direct-range (&key count)
  "Render COUNT static siblings before one stable direct Range callsite."
  :setup
  (let ((range (etaf--expr-create
                :token 'etaf-test-counted-range-site
                :thunk #'etaf-test--range-items)))
    (lambda ()
      (cl-incf etaf-test-range-component-renders)
      (etaf--view-node-create
       :name 'column :props nil
       :children
       (append
        (cl-loop for index below count
                 collect (etaf--view-call
                          'text (list :key (intern (format "counted-%s" index)))
                          (list (format "C%s" index))))
        (list range))))))

(etaf-define-component etaf-test-string-sibling-range ()
  "Render bare string siblings around one direct Range."
  :setup
  (let ((range (etaf--expr-create
                :token 'etaf-test-string-sibling-range-site
                :thunk #'etaf-test--range-items)))
    (lambda ()
      (etaf--view-node-create :name 'column :props nil
                              :children (list "prefix" range "suffix")))))

(etaf-define-component etaf-test-unsupported-direct-range ()
  "Start with a Host Range whose later unsupported output must fail."
  :setup
  (let ((range (etaf--expr-create
                :token 'etaf-test-unsupported-range-site
                :thunk #'etaf-test--unsupported-range-value)))
    (lambda ()
      (etaf--view-node-create
       :name 'column :props nil
       :children (list (etaf--view-call 'text (list :key 'static) (list "S"))
                       range)))))

(etaf-define-component etaf-test-public-string-range ()
  "Render one public direct expr whose Range item is a bare string."
  :view
  (column
   (text :key 'static "S")
   (expr :value (etaf-value etaf-test-string-range-source))))

(etaf-define-component etaf-test-nested-host-range ()
  "Render one Range whose keyed item owns keyed nested Hosts."
  :setup
  (let ((range (etaf--expr-create
                :token 'etaf-test-nested-range-site
                :thunk #'etaf-test--nested-range-value)))
    (lambda ()
      (etaf--view-node-create
       :name 'column :props nil
       :children (list (etaf--view-call 'text (list :key 'static) (list "S"))
                       range)))))

(etaf-define-component etaf-test-inline-shared-hosts ()
  "Render one shared source in two distinct text Hosts."
  :view
  (column
   (text :key 'left
         (expr :value
               (progn (cl-incf etaf-test-inline-shared-evals)
                      (etaf-value etaf-test-inline-shared))))
   (text :key 'right
         (expr :value
               (progn (cl-incf etaf-test-inline-shared-evals)
                      (etaf-value etaf-test-inline-shared))))))

(etaf-define-component etaf-test-inline-dependency-branch ()
  "Return equal inline output while switching its source dependency."
  :setup
  (progn
    (etaf-on-updated (lambda () (cl-incf etaf-test-inline-branch-updated)))
    (lambda ()
      (etaf-view
       (text
        (expr :value
              (progn
                (cl-incf etaf-test-inline-branch-evals)
                (if (etaf-value etaf-test-inline-branch-mode)
                    (etaf-value etaf-test-inline-branch-right)
                  (etaf-value etaf-test-inline-branch-left))
                "same")))))))

(etaf-define-component etaf-test-slot-env-child ()
  "Project the caller-owned default slot."
  :setup
  (lambda ()
    (cl-incf etaf-test-slot-consumer-renders)
    (etaf-view (column (slot)))))

(etaf-define-component etaf-test-slot-env-parent (&key label)
  "Author an inline slot expression from parent LABEL."
  :setup
  (lambda ()
    (cl-incf etaf-test-slot-parent-renders)
    (etaf-view
     (etaf-test-slot-env-child
      (text (expr :value label))))))

(etaf-define-component etaf-test-slot-env-consumer ()
  "Project a forwarded named header slot."
  :setup
  (lambda ()
    (cl-incf etaf-test-slot-consumer-renders)
    (etaf-view (column (slot :name 'header)))))

(etaf-define-component etaf-test-slot-env-forwarder ()
  "Forward the caller-owned named header slot."
  :setup
  (lambda ()
    (cl-incf etaf-test-slot-forwarder-renders)
    (etaf--component-call-create
     :spec etaf-test-slot-env-consumer--etaf-component-definition
     :props nil
     :slots (list (assq 'header etaf--current-component-slots)))))

(etaf-define-component etaf-test-slot-env-named-parent (&key label)
  "Author a named slot expression from parent LABEL."
  :setup
  (lambda ()
    (cl-incf etaf-test-slot-parent-renders)
    (etaf-view
     (etaf-test-slot-env-forwarder
      (slot :name 'header
            (text (expr :value label)))))))

(etaf-define-component etaf-test-slot-range-parent ()
  "Author one reactive default slot Range."
  :setup
  (progn
    (etaf-on-updated (lambda () (cl-incf etaf-test-slot-author-updated)))
    (lambda ()
      (cl-incf etaf-test-slot-parent-renders)
      (etaf-view
       (etaf-test-slot-env-child
        (expr :value (etaf-test--slot-range-items)))))))

(etaf-define-component etaf-test-slot-range-named-parent ()
  "Author one reactive named slot through the Forwarder."
  :setup
  (progn
    (etaf-on-updated (lambda () (cl-incf etaf-test-slot-author-updated)))
    (lambda ()
      (cl-incf etaf-test-slot-parent-renders)
      (etaf-view
       (etaf-test-slot-env-forwarder
        (slot :name 'header
              (expr :value (etaf-test--slot-range-items))))))))

(etaf-define-component etaf-test-slot-range-fallback ()
  "Own one reactive fallback slot Range."
  :styles (styles (".slot-item" :color "fallback-color"))
  :setup
  (progn
    (etaf-on-updated (lambda () (cl-incf etaf-test-slot-consumer-updated)))
    (lambda ()
      (cl-incf etaf-test-slot-consumer-renders)
      (etaf-view
       (column
        (slot (expr :value (etaf-test--slot-range-items))))))))

(etaf-define-component etaf-test-slot-range-two-sites ()
  "Project the same default slot at two material sites."
  :view
  (column
   (column :key 'left-site (slot))
   (column :key 'right-site (slot))))

(etaf-define-component etaf-test-slot-range-two-site-parent ()
  "Author one reactive slot consumed at two projection sites."
  :view
  (etaf-test-slot-range-two-sites
   (expr :value (etaf-test--slot-range-items))))

(etaf-define-component etaf-test-slot-range-branch-parent (&key mode)
  "Retarget slot dependencies from MODE while preserving equal output."
  :setup
  (lambda ()
    (cl-incf etaf-test-slot-parent-renders)
    (etaf-view
     (etaf-test-slot-env-child
      (expr :value
            (progn
              (if mode
                  (etaf-value etaf-test-slot-branch-right)
                (etaf-value etaf-test-slot-branch-left))
              (list (etaf-view (text :key 'same "same")))))))))

(etaf-define-component etaf-test-fragment-range-owner ()
  "Own one material fragment Range."
  :setup
  (lambda ()
    (cl-incf etaf-test-fragment-owner-renders)
    (etaf-view
     (column
      (fragment
       (expr :value (etaf-test--fragment-range-items)))))))


(etaf-define-component etaf-test-transparent-owner ()
  "Render a transparent fragment sequence."
  :setup
  (lambda ()
    (cl-incf etaf-test-transparent-renders)
    (etaf-view
     (fragment
      (expr :value
            (mapcar (lambda (entry)
                      (etaf--view-call 'text (list :key (car entry))
                                       (list (cdr entry))))
                    (etaf-value etaf-test-transparent-source)))))))

(etaf-define-component etaf-test-transparent-parent ()
  "Own one transparent child beside static material Hosts."
  :setup
  (lambda ()
    (cl-incf etaf-test-transparent-parent-renders)
    (etaf-view
     (column
      (text :key 'before "before")
      (etaf-test-transparent-owner)
      (text :key 'after "after")))))

(etaf-define-component etaf-test-transparent-inner ()
  "Render the inner transparent chain payload."
  :setup
  (lambda ()
    (cl-incf etaf-test-transparent-inner-renders)
    (etaf-view
     (fragment
      (expr :value
            (mapcar (lambda (entry)
                      (etaf--view-call 'text (list :key (car entry))
                                       (list (cdr entry))))
                    (etaf-value etaf-test-transparent-source)))))))

(etaf-define-component etaf-test-transparent-outer ()
  "Forward one transparent Component without a visual adapter."
  :setup
  (lambda ()
    (cl-incf etaf-test-transparent-outer-renders)
    (etaf-view (fragment (etaf-test-transparent-inner)))))

(etaf-define-component etaf-test-transparent-chain-parent ()
  "Place a transparent Component chain in one material parent."
  :view (column (etaf-test-transparent-outer)))

(etaf-define-component etaf-test-ancestor-artifact-child ()
  "Render a child whose local update invalidates ancestor artifacts."
  :view
  (text (expr :value
              (if (etaf-value etaf-test-ancestor-child-source)
                  "detail" "child"))))

(etaf-define-component etaf-test-ancestor-artifact-parent ()
  "Render a parent that can update after one descendant-only publication."
  :view
  (column :bgcolor (etaf-value etaf-test-ancestor-parent-source)
   (etaf-test-ancestor-artifact-child)))

(etaf-define-component etaf-test-generation-context-consumer ()
  "Render one generation-owned Context dependency."
  :setup
  (lambda ()
    (cl-incf etaf-test-context-consumer-renders)
    (etaf-view (text :color (etaf-inject 'generation-label) "context"))))

(etaf-define-component etaf-test-generation-context-provider ()
  "Provide a candidate Context value to one retained consumer."
  :setup
  (lambda ()
    (cl-incf etaf-test-context-provider-renders)
    (etaf-provide 'generation-label
                  (etaf-value etaf-test-context-provider-source))
    (etaf-view (etaf-test-generation-context-consumer))))

(etaf-define-component etaf-test-generation-context-range-provider ()
  "Provide Context directly to a retained child Range effect."
  :setup
  (lambda ()
    (etaf-provide 'generation-label
                  (etaf-value etaf-test-context-provider-source))
    (etaf-view
     (column
      (expr :value
            (progn
              (cl-incf etaf-test-context-range-evals)
              (list (etaf--view-call
                     'text (list :key 'context-range)
                     (list (etaf-inject 'generation-label))))))))))

(etaf-define-component etaf-test-generation-context-slot-consumer ()
  "Project one material slot Range for Context ownership tests."
  :setup
  (lambda ()
    (cl-incf etaf-test-slot-consumer-renders)
    (etaf-view (column (slot)))))

(etaf-define-component etaf-test-generation-context-slot-provider ()
  "Provide Context to an authored slot Range expression."
  :setup
  (lambda ()
    (cl-incf etaf-test-context-provider-renders)
    (etaf-provide 'generation-label
                  (etaf-value etaf-test-context-provider-source))
    (etaf-view
     (etaf-test-generation-context-slot-consumer
      (expr :value
            (progn
              (cl-incf etaf-test-slot-range-evals)
              (list (etaf--view-call
                     'text (list :key 'context-slot)
                     (list (etaf-inject 'generation-label))))))))))

(etaf-define-component etaf-test-prop-env-child (&key value)
  "Render VALUE received from a parent Component."
  :view (text (expr :value value)))

(etaf-define-component etaf-test-prop-env-parent (&key label)
  "Forward dynamic parent LABEL into a nested Component prop."
  :view (etaf-test-prop-env-child :value label))

(etaf-define-component etaf-test-inline-input-priority (&key label)
  "Render candidate LABEL with one independently dirty inline source."
  :setup
  (progn
    (etaf-on-updated (lambda () (cl-incf etaf-test-inline-priority-updated)))
    (lambda ()
      (cl-incf etaf-test-inline-priority-renders)
      (etaf-view
       (text
        (expr :value
              (progn
                (cl-incf etaf-test-inline-priority-evals)
                (format "%s/%s" label
                        (etaf-value etaf-test-inline-priority-source)))))))))

(etaf-define-component etaf-test-inline-styled-owner ()
  "Render a styled inline expression beside a side-effecting Host prop."
  :view
  (box :color (progn (cl-incf etaf-test-inline-host-prop-calls) "red")
   "P"
   (text :font-weight 'bold
         (expr :value
               (progn
                 (cl-incf etaf-test-inline-styled-evals)
                 (etaf-value etaf-test-inline-styled-source))))))

(etaf-define-component etaf-test-range-input-priority (&key marker)
  "Render fixed Range structure whose item reads MARKER and a reactive source."
  :setup
  (let ((range
         (etaf--expr-create
          :token 'etaf-test-range-input-priority-site
          :thunk
          (lambda ()
            (cl-incf etaf-test-range-evals)
            (list
             (etaf--view-call
              'text (list :key 'item :ref 'item)
              (list (format "%s/%s" marker
                            (etaf-value etaf-test-range-source)))))))))
    (lambda ()
      (cl-incf etaf-test-range-component-renders)
      (etaf--view-node-create
       :name 'column :props nil
       :children (list (etaf--view-call 'text (list :key 'static) (list "S"))
                       range)))))

(etaf-define-component etaf-test-next-turn ()
  "Write TARGET after publishing a SOURCE update."
  :setup
  (let ((source-cell etaf-test-next-turn-source)
        (target-cell etaf-test-next-turn-sink))
    (etaf-on-updated
     (lambda ()
       (when (and etaf-test-next-turn-target
                  (zerop (etaf-value target-cell)))
         (setf (etaf-value target-cell) 1))))
    (lambda ()
      (etaf-view
       (text (expr :value
                   (format "%s/%s" (etaf-value source-cell)
                           (etaf-value target-cell))))))))

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
  (text :font-weight 'bold (expr :value label)))

(etaf-define-component etaf-list (&key label)
  "Render LABEL using the collision-safe `list-view' alias."
  :view
  (text (expr :value label)))

(etaf-define-component etaf-test-slot-card (&key title)
  "Render a title with default and named slot projections."
  :view
  (column
   (text (expr :value title))
   (slot :name 'header (text :font-weight 'shadow "Default header"))
   (slot (text :font-weight 'shadow "Default body"))))

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

(etaf-define-component etaf-test-nil-style-host ()
  "Allow a Component style to fill an explicit nil Host property."
  :styles
  (styles
   (".fill" :color "style-color"))
  :view
  (text :class "fill" :color nil "Nil"))

(etaf-define-component etaf-test-style-rule-order (&key color)
  "Allow a later matching Component rule to refine an earlier rule."
  :styles
  (styles
   ("&" :color "base-color")
   ("&.accent" :color "accent-color"))
  :view
  (text :class "accent" :color color "Accent"))

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

(etaf-define-component etaf-test-styled-slot-child ()
  "Project caller-owned slot content without adding a style scope."
  :view
  (slot))

(etaf-define-component etaf-test-styled-slot-parent ()
  "Style caller-owned slot content while containing child internals."
  :styles
  (styles
   (".slot-content" :color "parent-color"))
  :view
  (etaf-test-styled-slot-child
   (text :class "slot-content" "Slot")))

(etaf-define-component etaf-test-styled-fallback-child ()
  "Style fallback content authored by the child Component."
  :styles
  (styles
   (".fallback-content" :color "child-color"))
  :view
  (slot
   (text :class "fallback-content" "Fallback")))

(etaf-define-component etaf-test-themed-text ()
  "Provide Theme defaults to one text Host."
  :setup
  (progn
    (etaf-theme-provide '(:color "theme-color" :bgcolor "theme-bg"))
    (lambda () (etaf-view (text :color nil "Themed")))))

(etaf-define-component etaf-test-themed-style-token ()
  "Resolve a deferred Theme token from a static Component style."
  :styles
  (styles ("&" :color (etaf-theme-token :color)))
  :setup
  (progn
    (etaf-theme-provide '(:color "token-color"))
    (lambda () (etaf-view (text "Token")))))

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

(etaf-define-component etaf-test-late-branch ()
  "Read a late reactive ref only after switching render branches."
  :setup
  (let ((page (etaf-ref "page"))
        (late (etaf-ref "late"))
        (late-branch (etaf-ref nil)))
    (setq etaf-test-branch-page-cell page
          etaf-test-branch-late-cell late
          etaf-test-branch-mode-cell late-branch)
    (lambda ()
      (etaf-view
       (text
        (expr :value
              (if (etaf-value late-branch)
                  (etaf-value late)
                (etaf-value page))))))))

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
    (lambda ()
      (etaf-view
       (column
        (text :ref 'event-batch-trigger
              :on-press (lambda () (setf (etaf-value source) 2))
              "Update")
        (text
         (expr :value
               (format "source=%d computed=%d %s %s"
                       (etaf-value source)
                       (etaf-value computed)
                       (etaf-value watch-value)
                       (etaf-value effect-value)))))))))

(etaf-define-component etaf-test-event-batch-noop ()
  "Render an event callback that performs no state write."
  :view
  (text :ref 'event-batch-noop
        :on-press (lambda () nil)
        "No-op"))

(etaf-define-component etaf-test-event-batch-nested ()
  "Render an outer callback that dispatches one nested public event."
  :setup
  (let ((state (etaf-ref "idle")))
    (lambda ()
      (etaf-view
       (column
        (text :ref 'event-batch-nested-outer
              :on-press
              (lambda ()
                (etaf-dispatch-event
                 (etaf-current-runtime)
                 'event-batch-nested-inner 'press))
              "Outer")
        (text :ref 'event-batch-nested-inner
              :on-press (lambda () (setf (etaf-value state) "nested"))
              "Inner")
        (text (expr :value (etaf-value state))))))))

(etaf-define-component etaf-test-event-batch-behavior ()
  "Render a toggleable Behavior whose callback writes two refs."
  :setup
  (let ((left (etaf-ref nil))
        (right (etaf-ref nil)))
    (lambda ()
      (etaf-view
       (column
        (text :ref 'event-batch-behavior
              :use
              (list
               (etaf-toggleable
                :value left
                :on-change
                (lambda (value)
                  (setf (etaf-value left) value
                        (etaf-value right) value))))
              "Toggle")
        (text
         (expr :value
               (format "left=%s right=%s"
                       (if (etaf-value left) "on" "off")
                       (if (etaf-value right) "on" "off")))))))))

(etaf-define-component etaf-test-event-batch-theme ()
  "Render a computed Theme changed by a public event callback."
  :setup
  (let* ((dark (etaf-ref nil))
         (theme (etaf-computed
                 (lambda ()
                   (if (etaf-value dark)
                       '(:color "dark")
                     '(:color "light"))))))
    (etaf-theme-provide theme)
    (lambda ()
      (etaf-view
       (column
        (text :ref 'event-batch-theme-toggle
              :on-press
              (lambda ()
                (setf (etaf-value dark) (not (etaf-value dark))))
              "Theme")
        (text (expr :value
                    (format "theme=%s" (etaf-theme-value :color)))))))))

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
    (lambda ()
      (cl-incf etaf-test-theme-property-render-count)
      (etaf-view
       (text :ref 'theme-property-toggle
             :color (etaf-theme-token :color)
             :bgcolor (etaf-theme-token :bgcolor)
             :on-press
             (lambda ()
               (setf (etaf-value dark) (not (etaf-value dark))))
             "Theme property")))))

(etaf-define-component etaf-test-theme-atomic-child (&key label on-press)
  "Render Theme paint below a Component whose input also changes."
  :view
  (column :ref 'theme-atomic-panel
          :color (etaf-theme-token :color)
          :bgcolor (etaf-theme-token :bgcolor)
   (text :ref 'theme-atomic-toggle :on-press on-press
         (expr :value label))))

(etaf-define-component etaf-test-theme-atomic-owner ()
  "Change Component content and descendant Theme properties in one turn."
  :setup
  (let* ((dark (etaf-ref nil))
         (theme
          (etaf-computed
           (lambda ()
             (if (etaf-value dark)
                 '(:color "#EEEEEE" :bgcolor "#111111")
               '(:color "#111111" :bgcolor "#FFFFFF")))))
         (toggle (lambda ()
                   (setf (etaf-value dark) (not (etaf-value dark))))))
    (etaf-theme-provide theme)
    (lambda ()
      (etaf--view-call
       'column (list :ref 'theme-atomic-root
                     :bgcolor (etaf-theme-token :bgcolor))
       (list
        (etaf--view-call
         'etaf-test-theme-atomic-child
         (list :label (if (etaf-value dark) "Dark" "Light")
               :on-press toggle)
         nil))))))

(etaf-define-component etaf-test-detached-theme-row (&key row-ref label)
  "Render one keyed Theme-bound row used by detached-subtree tests."
  :setup
  (lambda ()
    (cl-incf etaf-test-detached-row-renders)
    (etaf--view-call
     'row
     (list :ref (etaf-current-prop :row-ref)
           :color (etaf-theme-token :color))
     (list (etaf--view-call
            'text nil (list (etaf-current-prop :label)))))))

(etaf-define-component etaf-test-detached-theme-list ()
  "Render keyed Components below stable nested Host containers."
  :setup
  (progn
    (etaf-theme-provide etaf-test-detached-theme-source)
    (lambda ()
      (etaf--view-call
       'column (list :key 'shell)
       (list
        (etaf--view-call
         'column (list :key 'body)
         (mapcar
          (lambda (entry)
            (etaf--view-call
             'etaf-test-detached-theme-row
             (list :key (car entry) :row-ref (car entry) :label (cdr entry))
             nil))
          (etaf-value etaf-test-detached-list-source))))))))

(etaf-define-component etaf-test-event-batch-resource (&key resource fail)
  "Render synchronous Resource success and error state transitions."
  :setup
  (let ((instance-resource resource)
        (instance-fail fail))
    (lambda ()
      (etaf-view
       (column
        (text :ref 'event-batch-resource-success
              :on-press
              (lambda ()
                (setf (etaf-value instance-fail) nil)
                (etaf-resource-load instance-resource))
              "Load success")
        (text :ref 'event-batch-resource-error
              :on-press
              (lambda ()
                (setf (etaf-value instance-fail) t)
                (etaf-resource-load instance-resource))
              "Load error")
        (text
         (expr :value
               (format "status=%s value=%s error=%s"
                       (etaf-resource-status instance-resource)
                       (or (etaf-resource-value instance-resource) "none")
                       (if (etaf-resource-error instance-resource)
                           "yes"
                         "no")))))))))

(etaf-define-behavior etaf-test-cleanup-behavior (&rest attributes)
  "Construct a Behavior whose disposal is visible to tests."
  (apply #'etaf-behavior-create
         'etaf-test-cleanup-behavior
         (append attributes
                 (list :install
                       (lambda ()
                         (cl-incf etaf-test-behavior-installs)
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
   (macroexpand '(etaf-view (text "Hello" :font-weight 'bold)))
   :type 'etaf-view-syntax-error))

(ert-deftest etaf-view-ordinary-control-flow-belongs-in-expr ()
  "Reject ordinary Elisp control flow in the child region."
  (should-error
   (macroexpand '(etaf-view (text (if checked "yes" "no"))))
   :type 'etaf-view-syntax-error))

(ert-deftest etaf-view-quote-is-not-needed-for-structure ()
  "Construct an unquoted structural View and preserve quoted data values."
  (let ((view (etaf-view (text :font-weight 'bold "Hello"))))
    (should (etaf--view-node-p view))
    (should (equal 'bold (plist-get (etaf--view-node-props view) :font-weight)))
    (should (equal "Hello" (etaf-test--render-text view)))))

(ert-deftest etaf-view-attribute-values-are-ordinary-elisp ()
  "Evaluate an attribute expression without an extra evaluation wrapper."
  (let ((face 'bold)
        (label "Ready"))
    (let ((view (etaf-view (text :font-weight face (expr :value label)))))
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

(ert-deftest etaf-view-normalizes-box-string-child-to-text ()
  "Normalize a static Box string child to one Text View."
  (let* ((view (etaf-view (box "A")))
         (child (car (etaf--view-node-children view))))
    (should (etaf--view-node-p child))
    (should (eq (etaf--view-node-name child) 'text))
    (should (equal (etaf--view-node-children child) '("A")))))

(ert-deftest etaf-view-normalizes-root-string-to-text ()
  "Normalize a static root string to one Text View."
  (let ((view (etaf-view "A")))
    (should (etaf--view-node-p view))
    (should (eq (etaf--view-node-name view) 'text))
    (should (equal (etaf--view-node-children view) '("A")))))

(ert-deftest etaf-view-normalizes-component-string-slot-to-text ()
  "Normalize a static Component string child before slot ownership."
  (let* ((call (etaf-view (etaf-test-slot-card :title "Card" "Body")))
         (child (car (cdr (assq 'default
                                (etaf--component-call-slots call))))))
    (should (etaf--view-node-p child))
    (should (eq (etaf--view-node-name child) 'text))
    (should (equal (etaf--view-node-children child) '("Body")))))

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

(ert-deftest etaf-view-box-forms-lower-outer-and-layout-to-ebox ()
  "Lower each Box form to one typed Box with its selected Layout."
  (let ((row
         (etaf-render
          (etaf-view
           (row :outer 'inline
                (text "A")
                (text "B")))))
        (column
         (etaf-render
          (etaf-view
           (column :outer 'block
                (text "A")
                (text "B"))))))
    (should (equal (ebox--computed-display (etaf-test--input-root row))
                   '(inline row)))
    (should (equal (ebox--computed-display (etaf-test--input-root column))
                   '(block column)))
    (should (equal (substring-no-properties (ebox-render row)) "AB"))
    (should (equal (substring-no-properties (ebox-render column)) "A\nB"))))

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
                 (text (expr :value (etaf-value source)))
                 (text "B"))))
          (should (string-match-p "AB" (etaf-test--buffer-text buffer-name)))
          (setf (etaf-value source) "C")
          (should (string-match-p "CB" (etaf-test--buffer-text buffer-name))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-view-grid-lowers-to-ebox-grid ()
  "Lower the Grid Host through Ebox's two-dimensional layout node."
  (let ((node (etaf-render
               (etaf-view
                (grid
                 :grid-template-columns '((20) (20))
                 (text "A")
                 (text "B"))))))
    (should (ebox-box-node-p (etaf-test--input-root node)))
    (should (eq (ebox-layout-config-kind
                 (ebox-box-node-layout (etaf-test--input-root node)))
                'grid))
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
  (let* ((input (etaf-render (etaf-view (etaf-test-styled-card))))
         (source-index (ebox-canonical-input--source-index input))
         (node (etaf-test--input-root input))
         (children (ebox-box-node-children node))
         (title (car children))
         (body (cadr children)))
    (should (equal "inline-title"
                   (ebox-style-node-specified-value
                    title :color nil source-index)))
    (should (equal "title-bg"
                   (ebox-style-node-specified-value
                    title :bgcolor nil source-index)))
    (should (equal "style-root"
                   (ebox-style-node-specified-value
                    node :color nil source-index)))
    (should-not (ebox-style-node-specified-value
                 body :color nil source-index))))

(ert-deftest etaf-nil-host-props-allow-component-styles ()
  "Treat an explicit nil Host style property as unspecified."
  (let ((node (etaf-render (etaf-view (etaf-test-nil-style-host)))))
    (should (equal "style-color"
                   (ebox-style-node-specified-value node :color)))))

(ert-deftest etaf-style-rules-preserve-first-default-with-inline-protection ()
  "Keep the first matching Component default without overriding inline props."
  (let ((node (etaf-render (etaf-view (etaf-test-style-rule-order)))))
    (should (equal "base-color"
                   (ebox-style-node-specified-value node :color))))
  (let ((node (etaf-render
               (etaf-view
                (etaf-test-style-rule-order :color "inline-color")))))
    (should (equal "inline-color"
                   (ebox-style-node-specified-value node :color)))))

(ert-deftest etaf-styles-stop-at-nested-component-boundaries ()
  "Keep a parent Component selector outside nested Component internals."
  (let ((node (etaf-render (etaf-view (etaf-test-styled-parent)))))
    (should-not (ebox-style-node-specified-value node :color))))

(ert-deftest etaf-styles-follow-caller-owned-slot-content ()
  "Keep caller styles on slot content projected by a child Component."
  (let ((node (etaf-render (etaf-view (etaf-test-styled-slot-parent)))))
    (should (equal "parent-color"
                   (ebox-style-node-specified-value node :color)))))

(ert-deftest etaf-styles-keep-child-owned-slot-fallback-pure ()
  "Keep child styles on fallback content authored by that Component."
  (let ((node (etaf-render (etaf-view (etaf-test-styled-fallback-child)))))
    (should (equal "child-color"
                   (ebox-style-node-specified-value node :color)))))

(ert-deftest etaf-mounted-styles-keep-child-owned-slot-fallback ()
  "Keep child styles on fallback content through the Runtime path."
  (let ((buffer-name " *etaf-mounted-style-fallback-test*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-test-styled-fallback-child)))
          (should
           (equal "child-color"
                  (ebox-style-node-specified-value
                   (etaf-runtime-root-node
                    (etaf-runtime-for-buffer buffer-name))
                   :color nil
                   (plist-get
                    (ebox--buffer-render-state (get-buffer buffer-name))
                    :source-index)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-mounted-styles-stop-at-nested-component-boundaries ()
  "Keep a parent Component selector outside mounted child internals."
  (let ((buffer-name " *etaf-mounted-style-test*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-test-styled-parent)))
          (should
           (null
            (etaf-test--mounted-specified-value
             buffer-name
             (etaf-runtime-root-node
              (etaf-runtime-for-buffer buffer-name))
             :color))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-theme-defaults-are-inherited-and-overridable ()
  "Apply Theme defaults while allowing explicit Host properties to win."
  (let ((buffer-name " *etaf-theme-test*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-test-themed-text)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (node (etaf-runtime-root-node runtime)))
            (should (equal "theme-color"
                           (etaf-test--mounted-specified-value
                            buffer-name node :color)))
            (should (equal "theme-bg"
                           (etaf-test--mounted-specified-value
                            buffer-name node :bgcolor)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-theme-token-resolves-static-component-style ()
  "Resolve a Theme token without turning the Host property inline."
  (let ((buffer-name " *etaf-theme-token-test*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf-view (etaf-test-themed-style-token)))
          (should (equal "token-color"
                         (etaf-test--mounted-specified-value
                          buffer-name
                          (etaf-runtime-root-node
                           (etaf-runtime-for-buffer buffer-name))
                          :color))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-theme-token-resolves-nested-fallback-before-transform ()
  "Resolve semantic aliases once, then transform the final Theme value."
  (let ((token
         (etaf-theme-token
          :ui-border
          (etaf-theme-token :line "#AAAAAA")
          (lambda (color) (list (list 1) 'solid color)))))
    (should
     (equal '((1) solid "#202020")
            (etaf--theme-token-resolve-from-theme
             token '(:ui-border "#202020" :line "#101010"))))
    (should
     (equal '((1) solid "#101010")
            (etaf--theme-token-resolve-from-theme
             token '(:line "#101010"))))
    (should
     (equal '((1) solid "#AAAAAA")
            (etaf--theme-token-resolve-from-theme token nil)))))

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

(ert-deftest etaf-theme-paint-slot-rolls-back-with-generation-failure ()
  "A failed generation promotion must restore the committed paint plane."
  (let ((buffer-name " *etaf-theme-paint-rollback-test*")
        (etaf-test-theme-property-cell nil))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf-view (etaf-test-theme-property-effect)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-generation runtime))
                 (slot
                  (plist-get
                   (etaf-runtime-host-props-for
                    runtime 'theme-property-toggle)
                   :color)))
            (should (tp-paint-slot-p slot))
            (should (equal "#111111"
                           (plist-get (tp-paint-slot-spec slot) :foreground)))
            (cl-letf (((symbol-function 'etaf--runtime-swap-generation)
                       (lambda (&rest _)
                         (error "injected generation promotion failure"))))
              (should-error
               (etaf-dispatch-event runtime 'theme-property-toggle 'press)))
            (should (= generation (etaf-runtime-generation runtime)))
            (should (equal "#111111"
                           (plist-get (tp-paint-slot-spec slot) :foreground)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-theme-and-component-change-publish-one-final-artifact ()
  "Publish same-turn content and Theme changes from the final Generation."
  (let ((buffer-name " *etaf-theme-atomic-artifact-test*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf-view (etaf-test-theme-atomic-owner)))
          (let ((runtime (etaf-runtime-for-buffer buffer-name)))
            (cl-labels
                ((ebox-host-node
                  (host-ref)
                  (ebox--host-ref-node (get-buffer buffer-name) host-ref))
                 (background
                  (value)
                  (if (tp-paint-slot-p value)
                      (plist-get (tp-paint-slot-spec value) :background)
                    value)))
              (let ((slot
                     (let* ((buffer (get-buffer buffer-name))
                            (state (ebox--buffer-render-state buffer)))
                       (ebox-style-node-specified-value
                        (ebox-host-node 'theme-atomic-panel) :bgcolor nil
                        (plist-get state :source-index)))))
                (should (equal "#FFFFFF" (background slot)))
                (etaf-dispatch-event runtime 'theme-atomic-toggle 'press)
                (let ((semantic
                       (plist-get
                        (etaf-runtime-host-props-for
                         runtime 'theme-atomic-panel)
                        :bgcolor)))
                  (should (equal "#111111" (background semantic))))
                (with-current-buffer buffer-name
                  (should
                   (cl-some
                    (lambda (entry)
                      (equal "#111111"
                             (plist-get (cadr entry) :background)))
                    face-remapping-alist)))
                (should (string-match-p
                         "Dark" (etaf-test--buffer-text buffer-name)))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-runtime-detached-component-subtree-retires-host-effects ()
  "Retire unreachable Host contributions before a later Theme update."
  (let ((buffer-name " *etaf-detached-theme-list-test*")
        (etaf-test-detached-list-source
         (etaf-ref '((old-a . "A") (old-b . "B"))))
        (etaf-test-detached-theme-source
         (etaf-ref '(:color "#111111")))
        (etaf-test-detached-row-renders 0))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf-view (etaf-test-detached-theme-list)))
          (let ((runtime (etaf-runtime-for-buffer buffer-name)))
            (should (etaf-runtime-host-props-for runtime 'old-b))
            (setf (etaf-value etaf-test-detached-list-source)
                  '((old-a . "A2") (new-c . "C")))
            (should-not (etaf-runtime-host-props-for runtime 'old-b))
            (should-not
             (gethash 'old-b
                      (ebox--buffer-host-ref-table (get-buffer buffer-name))))
            (setq etaf-test-detached-row-renders 0)
            (setf (etaf-value etaf-test-detached-theme-source)
                  '(:color "#222222"))
            (should (zerop etaf-test-detached-row-renders))
            (let ((color
                   (plist-get
                    (etaf-runtime-host-props-for runtime 'new-c)
                    :color)))
              (should (tp-paint-slot-p color))
              (should
               (equal "#222222"
                      (plist-get (tp-paint-slot-spec color) :foreground))))))
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
  (should-error
   (etaf-theme-resolve-palette '(:ink "red") 'sepia)
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
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-current-generation runtime))
                 (effect-id (car (etaf--generation-source-effects
                                  generation etaf-test-state-cell))))
            (should (eq 'inline
                        (etaf--generation-effect-kind
                         (etaf--generation-effect generation effect-id)))))
          (setf (etaf-value etaf-test-state-cell) 1)
          (with-current-buffer buffer-name
            (should (equal "Count:1" (buffer-string))))
          (should (= etaf-test-setup-count 1))
          (should (= etaf-test-updated-count 1))
          (etaf-unmount (etaf-runtime-for-buffer buffer-name))
          (should (= etaf-test-unmounted-count 1)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

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

(ert-deftest etaf-runtime-branch-switch-keeps-equal-sources-distinct ()
  "Index equal-valued reactive sources by identity across a branch switch."
  (let ((buffer-name " *etaf-runtime-equal-source-branch-test*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-test-late-branch)))
          (setf (etaf-value etaf-test-branch-page-cell) "same")
          (setf (etaf-value etaf-test-branch-late-cell) "same")
          (setf (etaf-value etaf-test-branch-mode-cell) t)
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-current-generation runtime))
                 (before (etaf-runtime-generation runtime)))
            (should-not (etaf--generation-source-effects
                         generation etaf-test-branch-page-cell))
            (should (etaf--generation-source-effects
                     generation etaf-test-branch-late-cell))
            (setf (etaf-value etaf-test-branch-page-cell) "old-only")
            (should (= before (etaf-runtime-generation runtime)))
            (setf (etaf-value etaf-test-branch-late-cell) "new-only")
            (should (= (1+ before) (etaf-runtime-generation runtime)))
            (should (equal "new-only" (etaf-test--buffer-text buffer-name)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-theme-validation-snapshot-is-shared-across-contexts ()
  "Validate one immutable Theme value once for all inheriting Context frames."
  (let* ((theme (list :color "ink" :bgcolor "paper" :border "line"))
         (provider (etaf--context-create))
         (left (etaf--context-create :parent provider))
         (right (etaf--context-create :parent provider))
         (etaf--theme-value-cache
          (make-hash-table :test #'eq :weakness 'key))
         left-value right-value)
    (puthash 'theme theme (etaf-context-values provider))
    (let ((etaf--current-context left))
      (setq left-value (etaf-theme-defaults)))
    (let ((etaf--current-context right))
      (setq right-value (etaf-theme-defaults)))
    (should (eq left-value right-value))
    (should-not (eq left-value theme))
    (should (equal theme left-value))))

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
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
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
            (let* ((generation (etaf-runtime-current-generation runtime))
                   (entry (car (etaf--generation-index-entries
                                generation 'behaviors)))
                   (resource-key (cdr entry)))
              (should entry)
              (should (consp resource-key))
              (should (gethash resource-key
                                (etaf-runtime-resource-registry runtime))))
            (etaf-dispatch-event runtime 'interactive 'press)
            (should (= etaf-test-event-count 1))
            (should (equal '(press)
                           (mapcar #'car
                                   (gethash 'interactive
                                            (etaf-runtime-handlers runtime)))))
            (etaf-unmount runtime))
          (should (= etaf-test-behavior-cleanups 1)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-runtime-composes-host-and-behavior-events-in-order ()
  "Run an explicit Host callback before its Behavior callback.

Event composition is a Runtime contract, not a UI-library helper contract."
  (let ((buffer-name " *etaf-event-composition-test*")
        (order nil))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (text
             :ref 'composed
             :use (list
                   (etaf-test-cleanup-behavior
                    :on-press (lambda () (setq order (append order '(behavior))))))
             :on-press (lambda () (setq order (append order '(host))))
             "Press")))
          (etaf-dispatch-event (etaf-runtime-for-buffer buffer-name)
                               'composed 'press)
          (should (equal order '(host behavior))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-behavior-replacement-disposes-previous-installer ()
  "Dispose a replaced Behavior while retaining the public installer path."
  (let ((buffer-name " *etaf-behavior-replace-test*")
        (marker (etaf-ref 0))
        (trigger (etaf-ref 0)))
    (setq etaf-test-behavior-cleanups 0
          etaf-test-behavior-installs 0
          etaf-test-behavior-runtime nil)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (text
             :ref 'behavior-host
             :aria-label (progn (etaf-value trigger) "behavior")
             :use (list (etaf-test-cleanup-behavior
                         :class (format "mode-%d" (etaf-value marker))))
             "Behavior")))
          (should (etaf-runtime-p etaf-test-behavior-runtime))
          (should (= 1 etaf-test-behavior-installs))
          (setf (etaf-value trigger) 1)
          ;; The render creates a fresh installer closure.  Function identity
          ;; is part of Behavior equality, so the old installer is disposed
          ;; before the new one is staged.
          (should (= 2 etaf-test-behavior-installs))
          (should (= 1 etaf-test-behavior-cleanups))
          (should (etaf--generation-index-entries
                   (etaf-runtime-current-generation
                    (etaf-runtime-for-buffer buffer-name))
                   'behaviors))
          (setf (etaf-value marker) 1)
          (should (= 3 etaf-test-behavior-installs))
          (should (= 2 etaf-test-behavior-cleanups)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-behavior-rollback-cleanups-continue-and-diagnose ()
  "Run candidate Behavior cleanup in reverse order despite error and quit."
  (let* ((runtime (etaf--runtime-create
                   :behaviors (make-hash-table :test #'equal)
                   :candidate-behaviors (make-hash-table :test #'equal)))
         (trace nil)
         (first (etaf-behavior-create 'first))
         (second (etaf-behavior-create 'second)))
    (puthash '(a first)
             (cons first (lambda () (push 'first trace) (error "first")))
             (etaf-runtime-candidate-behaviors runtime))
    (puthash '(b second)
             (cons second (lambda () (push 'second trace) (signal 'quit nil)))
             (etaf-runtime-candidate-behaviors runtime))
    (etaf--runtime-rollback-behaviors runtime)
    (should (equal '(first second) trace))
    (should (= 2 (length (etaf-runtime-diagnostics runtime))))
    (should (equal '(behavior-rollback behavior-rollback)
                   (mapcar (lambda (entry) (plist-get entry :phase))
                           (reverse (etaf-runtime-diagnostics runtime)))))))

(ert-deftest etaf-runtime-target-equality-keeps-function-and-reactive-identity ()
  "Use EQ for function/reactive leaves while comparing scalar structure."
  (let* ((source (etaf-ref 1))
         (callback (lambda () 1))
         (left (list :value source :callback callback :count 1))
         (same (list :value source :callback callback :count 1))
         (new (list :value source :callback (lambda () 1) :count 1)))
    (should (etaf--runtime-target-value-equal-p left same))
    (should-not (etaf--runtime-target-value-equal-p left new))
    (should (etaf--runtime-behavior-spec-equal-p
             (etaf-behavior-create 'stable :value source :install callback)
             (etaf-behavior-create 'stable :value source :install callback)))
    (should-not (etaf--runtime-behavior-spec-equal-p
                 (etaf-behavior-create 'stable :value source
                                       :install (lambda () nil))
                 (etaf-behavior-create 'stable :value source
                                       :install (lambda () nil))))))

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

(ert-deftest etaf-runtime-root-owner-is-only-full-rebuild-entry ()
  "Keep complete-root publication isolated to Root-owner control flow."
  (let ((file (expand-file-name
               "etaf-runtime.el"
               (file-name-directory (or (locate-library "etaf")
                                        default-directory))))
        source)
    (with-temp-buffer
      (insert-file-contents file)
      (setq source (buffer-string)))
    ;; Mounted non-root invalidations set only their effect queue.  Root-owned
    ;; rebuilds are centralized behind one marker and are requested only by a
    ;; Root effect route or by an explicit local-proof miss.
    (should (= 1 (let ((start 0) count)
                   (while (string-match
                           "(setf (etaf-runtime-root-dirty-p runtime) t)"
                           source start)
                     (setq count (1+ (or count 0))
                           start (match-end 0)))
                   count)))
    (should (= 2 (let ((start 0) count)
                   (while (string-match
                           "(etaf--runtime-mark-root-dirty runtime)"
                           source start)
                     (setq count (1+ (or count 0))
                           start (match-end 0)))
                   count)))
    (let* ((start (string-match
                   "(defun etaf--runtime-component-overlay"
                   source))
           (end (string-match
                 "(defun etaf--runtime-render-effect"
                 source start))
           (overlay (substring source start end)))
      (should-not (string-match-p "etaf--runtime-render-effect" overlay))
      (should-not (string-match-p "etaf--runtime-evaluate-root-candidate"
                                  overlay)))
    ;; Flush has one mutually exclusive Root branch and one local overlay
    ;; branch; this guards against accidentally routing all mounted effects
    ;; through the Root adapter again.
    (should (string-match-p
             "(if (etaf-runtime-root-dirty-p runtime)"
             source))))

(ert-deftest etaf-runtime-fixed-point-tuple-detects-repeated-input ()
  "Reject a repeated Runtime effect tuple only within one flush."
  (let* ((runtime (etaf--runtime-create :mount-epoch 77))
         (source (etaf-ref nil))
         (effect (etaf--generation-effect-create
                  :effect-id 3 :kind 'range :deps (list source)))
         (generation (etaf--generation-create
                      :generation-id 1
                      :effect-map (etaf--pvec-put nil 3 effect)))
         (etaf--runtime-fixed-point-stamps
          (make-hash-table :test #'equal)))
    (should (etaf--runtime-record-effect-input-version
             runtime generation 3))
    (should-error
     (etaf--runtime-record-effect-input-version runtime generation 3)
     :type 'etaf-runtime-error)
    (setf (etaf-ref-version source) 1)
    (should (etaf--runtime-record-effect-input-version
             runtime generation 3))))

(ert-deftest etaf-reactive-dispatch-fifos-append-in-constant-time-order ()
  "Keep source and Runtime dispatch order with explicit FIFO tails."
  (let ((etaf--dispatch-depth 1)
        (etaf--dispatch-source-queue nil)
        (etaf--dispatch-source-queue-tail nil)
        (etaf--dispatch-source-set (make-hash-table :test #'eq))
        (etaf--dispatch-runtime-queue nil)
        (etaf--dispatch-runtime-queue-tail nil)
        (etaf--dispatch-runtime-set (make-hash-table :test #'eq))
        (sources (cl-loop repeat 100 collect (etaf-ref nil))))
    (dolist (source sources)
      (etaf--dispatch-source source))
    (etaf--dispatch-source (car sources))
    (etaf-reactive-enqueue-runtime-flush 'first #'ignore)
    (etaf-reactive-enqueue-runtime-flush 'second #'ignore)
    (etaf-reactive-enqueue-runtime-flush 'first #'ignore)
    (should (equal sources etaf--dispatch-source-queue))
    (should (eq (car etaf--dispatch-source-queue-tail) (car (last sources))))
    (should (equal '(first second) etaf--dispatch-runtime-queue))
    (should (eq 'second (car etaf--dispatch-runtime-queue-tail)))))

(ert-deftest etaf-runtime-dirty-effect-fifo-and-priority-stay-stable ()
  "Append dirty effects in O(1) and sort each immutable effect only once."
  (let* ((runtime
          (etaf--runtime-create
           :dirty-effect-ids (make-hash-table :test #'eql)))
         (generation
          (etaf--generation-create
           :effect-map
           (etaf--pvec-put-many
            nil
            (list
             (cons 5 (etaf--generation-effect-create
                      :effect-id 5 :kind 'component-render))
             (cons 2 (etaf--generation-effect-create
                      :effect-id 2 :kind 'inline))
             (cons 3 (etaf--generation-effect-create
                      :effect-id 3 :kind 'component-input))
             (cons 1 (etaf--generation-effect-create
                      :effect-id 1 :kind 'root)))))))
    (dolist (effect-id '(5 2 3 1 2))
      (etaf--runtime-enqueue-effect runtime effect-id))
    (should (equal '(5 2 3 1)
                   (etaf-runtime-dirty-effect-queue runtime)))
    (should (= 1 (car (etaf-runtime-dirty-effect-queue-tail runtime))))
    (should (equal '(1 3 2 5)
                   (etaf--runtime-sort-dirty-effects
                    generation (etaf-runtime-dirty-effect-queue runtime))))
    (let (popped)
      (while (etaf-runtime-dirty-effect-queue runtime)
        (push (etaf--runtime-pop-effect runtime) popped))
      (should (equal '(5 2 3 1) (nreverse popped)))
      (should-not (etaf-runtime-dirty-effect-queue-tail runtime)))))

(ert-deftest etaf-runtime-fixed-point-step-bound-stops-monotonic-cycle ()
  "Stop a cycle whose source version changes on every evaluation."
  (let* ((runtime (etaf--runtime-create :mount-epoch 78))
         (source (etaf-ref nil))
         (effect (etaf--generation-effect-create
                  :effect-id 4 :kind 'range :deps (list source)))
         (generation (etaf--generation-create
                      :generation-id 1
                      :effect-map (etaf--pvec-put nil 4 effect)))
         (etaf--runtime-fixed-point-stamps (make-hash-table :test #'equal))
         (etaf--runtime-fixed-point-steps 0)
         (etaf--runtime-fixed-point-step-bound 2))
    (etaf--runtime-record-effect-input-version runtime generation 4)
    (setf (etaf-ref-version source) 1)
    (etaf--runtime-record-effect-input-version runtime generation 4)
    (setf (etaf-ref-version source) 2)
    (should-error
     (etaf--runtime-record-effect-input-version runtime generation 4)
     :type 'etaf-runtime-error)))

(ert-deftest etaf-runtime-fixed-point-long-acyclic-chain-fits-bound ()
  "Allow a long chain of distinct effect tuples within the graph bound."
  (let ((runtime (etaf--runtime-create :mount-epoch 79))
        (etaf--runtime-fixed-point-stamps (make-hash-table :test #'equal))
        (etaf--runtime-fixed-point-steps 0)
        (etaf--runtime-fixed-point-step-bound 164)
        (generation (etaf--generation-create :generation-id 1
                                              :effect-map nil)))
    (dotimes (index 40)
      (let* ((source (etaf-ref nil))
             (effect-id (1+ index))
             (effect (etaf--generation-effect-create
                      :effect-id effect-id :kind 'range :deps (list source))))
        (setf (etaf-generation-effect-map generation)
              (etaf--pvec-put (etaf-generation-effect-map generation)
                              effect-id effect))
        (etaf--runtime-record-effect-input-version runtime generation effect-id)))
    (should (= 40 etaf--runtime-fixed-point-steps))))

(ert-deftest etaf-runtime-fixed-point-tuple-includes-candidate-facts-and-path ()
  "Detect candidate semantic cycles and retain an effect/edge path."
  (let* ((source (etaf-ref nil))
         (runtime
          (etaf--runtime-create
           :mount-epoch 80 :next-effect-id 2
           :candidate-effects (make-hash-table :test #'eql)
           :candidate-graph-nodes (make-hash-table :test #'eql)
           :route-sources (make-hash-table :test #'eq)))
         (effect
          (etaf--generation-effect-create
           :effect-id 1 :kind 'range :semantic-id 11 :deps (list source)))
         (generation
          (etaf--generation-create
           :generation-id 1
           :effect-map (etaf--pvec-put nil 1 effect)))
         (semantic
          (etaf--semantic-range-create
           :semantic-id 11 :identity '(candidate-range)
           :effect-id 1 :kind 'range :composition-version 1
           :output-signature '("A") :context-deps nil)))
    (puthash 1 effect (etaf-runtime-candidate-effects runtime))
    (puthash 11 semantic (etaf-runtime-candidate-graph-nodes runtime))
    (let ((etaf--runtime-fixed-point-stamps (make-hash-table :test #'equal))
          (etaf--runtime-fixed-point-history nil)
          (etaf--runtime-fixed-point-steps 0)
          (etaf--runtime-fixed-point-step-bound 8))
      (etaf--runtime-record-effect-input-version runtime generation 1)
      (setf (etaf--semantic-range-composition-version semantic) 2)
      (etaf--runtime-record-effect-input-version runtime generation 1)
      (let (condition)
        (condition-case err
            (etaf--runtime-record-effect-input-version runtime generation 1)
          (etaf-runtime-error (setq condition (cdr err))))
        (should condition)
        (should (plist-get condition :path))
        (should (= 3 (length (plist-get condition :path))))))))

(ert-deftest etaf-runtime-skips-descendant-range-under-rendered-component ()
  "A freshly rendered Component absorbs its old descendant Range effect."
  (let* ((component
          (etaf--semantic-component-create
           :semantic-id 7 :identity '(parent-component)))
         (range
          (etaf--semantic-range-create
           :semantic-id 8 :effect-id 8 :component-id 7 :parent-id 7))
         (generation
          (etaf--generation-create
           :generation-id 1
           :semantic-nodes (etaf--pvec-put
                            (etaf--pvec-put nil 7 component) 8 range)))
         (runtime
          (etaf--runtime-create
           :candidate-rendered-identities '((parent-component))
           :candidate-effects (make-hash-table :test #'eql)
           :candidate-graph-nodes (make-hash-table :test #'eql))))
    (puthash 8
             (etaf--generation-effect-create
              :effect-id 8 :kind 'range :semantic-id 8)
             (etaf-runtime-candidate-effects runtime))
    (puthash 8 range (etaf-runtime-candidate-graph-nodes runtime))
    (should (etaf--runtime-range-owned-by-rendered-component-p
             runtime generation range))
    (setf (etaf-runtime-candidate-rendered-identities runtime) nil)
    (should-not (etaf--runtime-range-owned-by-rendered-component-p
                 runtime generation range))))


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

(ert-deftest etaf-runtime-observer-covers-initial-publication ()
  "Observed mount emits TP, Ebox, then one final ETAF operation report."
  (let ((buffer-name " *etaf-observed-mount-test*") reports)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name (etaf-view (box "Observed"))
           (list :observer
                 (lambda (report) (push report reports))))
          (setq reports (nreverse reports))
          (should (equal (mapcar (lambda (report)
                                   (plist-get report :provider))
                                 reports)
                         '(tp ebox etaf)))
          (should (equal (mapcar (lambda (report)
                                   (plist-get report :sequence))
                                 reports)
                         '(1 2 3)))
          (should (equal (delete-dups
                          (mapcar (lambda (report)
                                    (plist-get report :operation-id))
                                  reports))
                         '(1)))
          (let ((final (car (last reports))))
            (should (eq (plist-get final :stage) 'runtime-operation))
            (should (eq (plist-get final :kind) 'mount))
            (should (eq (plist-get final :status) 'success))
            (should (= (plist-get final :generation-before) 0))
            (should (= (plist-get final :generation-after) 1))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-runtime-set-observer runtime nil)
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-runtime-observer-flattens-nested-event-and-detaches ()
  "Nested event/flush work shares one operation and detach stops reports."
  (let ((buffer-name " *etaf-observed-event-test*") reports)
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf-view (etaf-test-event-batch-nested)))
          (let ((runtime (etaf-runtime-for-buffer buffer-name)))
            (etaf-runtime-set-observer
             runtime (lambda (report) (push report reports)))
            (etaf-dispatch-event
             runtime 'event-batch-nested-outer 'press)
            (setq reports (nreverse reports))
            (should (equal (mapcar (lambda (report)
                                     (plist-get report :provider))
                                   reports)
                           '(tp ebox etaf)))
            (should (= 1 (cl-count 'etaf reports
                                   :key (lambda (report)
                                          (plist-get report :provider)))))
            (should (= 1 (length
                          (delete-dups
                           (mapcar (lambda (report)
                                     (plist-get report :operation-id))
                                   reports)))))
            (should (equal "Outer Inner nested"
                           (etaf-test--buffer-text buffer-name)))
            (should-not (etaf-runtime-set-observer runtime nil))
            (setq reports nil)
            (etaf-dispatch-event
             runtime 'event-batch-nested-outer 'press)
            (should-not reports)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-runtime-observer-noop-and-failure-cannot-change-state ()
  "No-op observation and observer errors preserve exact committed state."
  (let ((buffer-name " *etaf-observed-noop-test*") reports)
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-test-event-batch-noop)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-generation runtime))
                 (before (with-current-buffer buffer-name (buffer-string))))
            (etaf-runtime-set-observer
             runtime
             (lambda (report)
               (push report reports)
               (error "observer failure")))
            (etaf-dispatch-event runtime 'event-batch-noop 'press)
            (should (= generation (etaf-runtime-generation runtime)))
            (should (equal-including-properties
                     before (with-current-buffer buffer-name (buffer-string))))
            (should (= 1 (length reports)))
            (should (eq (plist-get (car reports) :provider) 'etaf))
            (should (cl-find 'observer
                             (etaf-runtime-diagnostics runtime)
                             :key (lambda (entry)
                                    (plist-get entry :phase))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-runtime-set-observer runtime nil)
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-runtime-observer-compare-and-set-preserves-foreign-owner ()
  "Observer consumers replace only the exact sink they own."
  (let ((buffer-name " *etaf-observer-owner-test*")
        (first #'ignore)
        (second (lambda (_report) nil)))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (box "Observer owner")))
          (let ((runtime (etaf-runtime-for-buffer buffer-name)))
            (should (etaf-runtime-compare-and-set-observer runtime nil first))
            (should-not
             (etaf-runtime-compare-and-set-observer runtime nil second))
            (should (etaf-runtime-compare-and-set-observer runtime first second))
            (should-not
             (etaf-runtime-compare-and-set-observer runtime first nil))
            (should (etaf-runtime-compare-and-set-observer runtime second nil))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-runtime-set-observer runtime nil)
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-runtime-killed-buffer-unmounts-owned-scope ()
  "Killing a mounted buffer follows the ordinary Runtime unmount path."
  (let* ((buffer-name (generate-new-buffer-name " *etaf-kill-runtime-test*"))
         runtime scope buffer)
    (etaf-mount buffer-name (etaf-view (box "Kill Runtime")))
    (setq buffer (get-buffer buffer-name)
          runtime (etaf-runtime-for-buffer buffer)
          scope (etaf-runtime-scope runtime))
    (should (etaf-effect-scope-active-p scope))
    (kill-buffer buffer)
    (should-not (buffer-live-p buffer))
    (should-not (etaf-runtime-mounted-p runtime))
    (should-not (etaf-effect-scope-active-p scope))
    (should-not (gethash buffer etaf--runtime-table))))

(ert-deftest etaf-pvec-put-many-preserves-values-and-shares-untouched-branches ()
  "Batch persistent-vector updates match sequential puts and share untouched paths."
  (let* ((untouched-id (* 31 (expt 2 30)))
         (base (etaf--pvec-put
                (etaf--pvec-put nil untouched-id 'untouched)
                1 'old))
         (sequential-metrics (etaf--generation-metrics-create))
         (batch-metrics (etaf--generation-metrics-create))
         (sequential
          (etaf--pvec-put
           (etaf--pvec-put
            (etaf--pvec-put
             (etaf--pvec-put base 1 'new) 2 'two sequential-metrics)
            3 'three sequential-metrics)
           1 'final sequential-metrics))
         (batch
          (etaf--pvec-put-many
           base '((1 . new) (2 . two) (3 . three) (1 . final))
           batch-metrics))
         (base-children (etaf--pvec-node-children base))
         (batch-children (etaf--pvec-node-children batch))
         (untouched-slot (logand 31 (ash untouched-id (* -5 6)))))
    (should (equal (etaf--pvec-get batch 1) 'final))
    (should (equal (etaf--pvec-get batch 2) 'two))
    (should (equal (etaf--pvec-get batch 3) 'three))
    (should (equal (etaf--pvec-get batch untouched-id) 'untouched))
    (should (equal (etaf--pvec-get batch 1)
                   (etaf--pvec-get sequential 1)))
    (should (eq (aref base-children untouched-slot)
                (aref batch-children untouched-slot)))
    (should (< (etaf--generation-metrics-node-copies batch-metrics)
               (etaf--generation-metrics-node-copies sequential-metrics)))))

(ert-deftest etaf-runtime-component-overlay-does-zero-unrelated-work ()
  "Point-update one of 500 retained Components without Root or sibling work."
  (let* ((buffer-name " *etaf-persistent-generation-test*")
         (cells (cl-loop repeat 500 collect (etaf-ref 0)))
         (etaf-test-retained-render-counts (make-hash-table :test #'eql))
         (root-calls 0)
         (view
          (lambda ()
            (cl-incf root-calls)
            (etaf--view-call
             'column nil
             (cl-loop for cell in cells for index from 0
                      collect
                      (etaf--view-call
                       'etaf-test-retained-leaf
                       (list :key index :label index :cell cell) nil))))))
    (unwind-protect
        (progn
          (etaf-mount buffer-name view)
          (clrhash etaf-test-retained-render-counts)
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (old (etaf-runtime-current-generation runtime))
                 (old-index (etaf-generation-identity-index old)))
            (setf (etaf-value (nth 247 cells)) 1)
            (let ((metrics (etaf-runtime-candidate-generation-metrics runtime))
                  (new (etaf-runtime-current-generation runtime)))
              (should (= 1 root-calls))
              (should (= 1 (gethash 247 etaf-test-retained-render-counts 0)))
              (should (= 1 (hash-table-count etaf-test-retained-render-counts)))
              (should (eq old-index (etaf-generation-identity-index new)))
              (should (<= (etaf--generation-metrics-node-copies metrics) 128)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-shared-source-renders-siblings-in-one-commit ()
  "Render exactly two subscribing siblings and publish one candidate."
  (let* ((buffer-name " *etaf-shared-source-siblings-test*")
         (shared (etaf-ref 0)) (unrelated (etaf-ref 0))
         (root-calls 0) (commits 0) (replacements 0)
         (etaf-test-retained-render-counts (make-hash-table :test #'equal))
         (view
          (lambda ()
            (cl-incf root-calls)
            (etaf--view-call
             'column nil
             (list
              (etaf--view-call 'etaf-test-retained-leaf
                               (list :key 'a :label "A" :cell shared) nil)
              (etaf--view-call 'etaf-test-retained-leaf
                               (list :key 'b :label "B" :cell shared) nil)
              (etaf--view-call 'etaf-test-retained-leaf
                               (list :key 'u :label "U" :cell unrelated) nil))))))
    (unwind-protect
        (progn
          (etaf-mount buffer-name view)
          (clrhash etaf-test-retained-render-counts)
          (let ((old-commit (symbol-function 'ebox-commit))
                (old-replace (symbol-function 'ebox-candidate-replace-host-ref))
                (runtime (etaf-runtime-for-buffer buffer-name)))
            (cl-letf (((symbol-function 'ebox-commit)
                       (lambda (&rest args)
                         (cl-incf commits) (apply old-commit args)))
                      ((symbol-function 'ebox-candidate-replace-host-ref)
                       (lambda (&rest args)
                         (cl-incf replacements) (apply old-replace args))))
              (let ((before (etaf-runtime-generation runtime)))
                (setf (etaf-value shared) 1)
                (should (= 1 (- (etaf-runtime-generation runtime) before)))))
            (should (= 1 commits))
            (should (= 2 replacements))
            (should (= 1 (gethash "A" etaf-test-retained-render-counts 0)))
            (should (= 1 (gethash "B" etaf-test-retained-render-counts 0)))
            (should (zerop (gethash "U" etaf-test-retained-render-counts 0)))
            (should (= 1 root-calls))
            (should (= 1 (hash-table-count (etaf-ref-subscribers shared))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-root-rebuild-retains-unchanged-sibling-routes ()
  "Retain an unchanged sibling semantic subtree across a Root-owned rebuild."
  (let* ((buffer-name " *etaf-root-retain-sibling-test*")
         (root-source (etaf-ref "A"))
         (left-cell (etaf-ref 0)) (right-cell (etaf-ref 0))
         (root-calls 0)
         (etaf-test-retained-render-counts (make-hash-table :test #'equal))
         (view
          (lambda ()
            (cl-incf root-calls)
            (etaf--view-call
             'column nil
             (list
              (etaf--view-call 'etaf-test-retained-leaf
                               (list :key 'left
                                     :label (etaf-value root-source)
                                     :cell left-cell) nil)
              (etaf--view-call 'etaf-test-retained-leaf
                               (list :key 'right :label "R"
                                     :cell right-cell) nil))))))
    (unwind-protect
        (progn
          (etaf-mount buffer-name view)
          (clrhash etaf-test-retained-render-counts)
          (setf (etaf-value root-source) "B")
          (should (= 1 (gethash "B" etaf-test-retained-render-counts 0)))
          (should (zerop (gethash "R" etaf-test-retained-render-counts 0)))
          (clrhash etaf-test-retained-render-counts)
          (let ((root-before root-calls))
            (setf (etaf-value right-cell) 1)
            (should (= root-before root-calls))
            (should (= 1 (gethash "R" etaf-test-retained-render-counts 0)))
            (should (zerop (gethash "B" etaf-test-retained-render-counts 0)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-setup-read-is-not-a-render-dependency ()
  "Do not subscribe a Component render owner to setup-only reads."
  (let ((buffer-name " *etaf-setup-dependency-test*")
        (setup-source (etaf-ref 0)) (render-source (etaf-ref "A")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf--view-call 'etaf-test-setup-read-owner
                            (list :setup-source setup-source
                                  :render-source render-source) nil))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (before (etaf-runtime-generation runtime)))
            (setf (etaf-value setup-source) 1)
            (should (= before (etaf-runtime-generation runtime)))
            (setf (etaf-value render-source) "B")
            (should (= (1+ before) (etaf-runtime-generation runtime)))
            (should (equal "B" (etaf-test--buffer-text buffer-name)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-dependency-only-promotion-skips-ebox-publication ()
  "Promote changed dependencies/output inputs without an Ebox commit."
  (let ((buffer-name " *etaf-dependency-only-test*")
        (source (etaf-ref 0)) (commits 0))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf--view-call 'etaf-test-dependency-only
                                       (list :source source) nil))
          (let ((runtime (etaf-runtime-for-buffer buffer-name))
                (before-commit (symbol-function 'ebox-commit)))
            (cl-letf (((symbol-function 'ebox-commit)
                       (lambda (&rest args)
                         (cl-incf commits)
                         (apply before-commit args))))
              (let ((before (etaf-runtime-generation runtime)))
                (setf (etaf-value source) 1)
                (should (= (1+ before) (etaf-runtime-generation runtime)))
                (should (zerop commits))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

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

(ert-deftest etaf-runtime-input-target-precedes-render-target ()
  "Render once with final inputs regardless of batched source write order."
  (dolist (order '((input render) (render input)))
    (let ((buffer-name (format " *etaf-target-order-%S*" order))
          (input (etaf-ref "A")) (render (etaf-ref 0)))
      (setq etaf-test-priority-render-source render
            etaf-test-priority-render-count 0)
      (unwind-protect
          (progn
            (etaf-mount
             buffer-name
             (etaf-view
              (etaf-test-target-priority :label (etaf-value input))))
            (setq etaf-test-priority-render-count 0)
            (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                   (before (etaf-runtime-generation runtime)))
              (etaf-runtime-event-begin runtime)
              (dolist (which order)
                (if (eq which 'input)
                    (setf (etaf-value input) "B")
                  (setf (etaf-value render) 1)))
              (etaf-runtime-event-end runtime)
              (should (= 1 etaf-test-priority-render-count))
              (should (= 1 (- (etaf-runtime-generation runtime) before)))
              (should (equal "B/1" (etaf-test--buffer-text buffer-name)))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
          (etaf-unmount runtime))
        (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer))))))

(ert-deftest etaf-runtime-local-component-retains-caller-style-environment ()
  "Preserve caller style/slot environment across a Component-only update."
  (let ((buffer-name " *etaf-local-style-environment-test*")
        (source (etaf-ref "A")))
    (setq etaf-test-local-style-source source)
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-test-local-style-parent)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-current-generation runtime))
                 (effects (etaf--generation-source-effects generation source))
                 (parent (etaf--generation-semantic
                          generation '(etaf-test-local-style-parent (root)))))
            (should-not (memq (etaf--semantic-component-effect-id parent)
                              effects))
            (setf (etaf-value source) "B")
            (with-current-buffer buffer-name
              (let ((text (buffer-string)))
                (should (equal "B" (substring-no-properties text)))
                (should (equal '(:foreground "retained-color")
                               (get-text-property 0 'face text)))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-lazy-computed-owns-its-underlying-dependency ()
  "Route Component to computed while its ordinary effect owns the base ref."
  (let ((buffer-name " *etaf-lazy-computed-owner-test*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-test-lazy-computed-owner)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-current-generation runtime)))
            (should (etaf--generation-source-effects
                     generation etaf-test-lazy-computed-value))
            (should-not (etaf--generation-source-effects
                         generation etaf-test-lazy-computed-base))
            (should (= 1 (hash-table-count
                          (etaf-ref-subscribers
                           etaf-test-lazy-computed-base))))
            (let ((before (etaf-runtime-generation runtime)))
              (setf (etaf-value etaf-test-lazy-computed-base) 3)
              (should (= (1+ before) (etaf-runtime-generation runtime)))
              (should (equal "6" (etaf-test--buffer-text buffer-name))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-reactive-post-publication-write-runs-next-runtime-turn ()
  "Drain a lifecycle source write as a distinct following Runtime turn."
  (let ((buffer-name " *etaf-next-turn-test*")
        (source (etaf-ref 0)) (target (etaf-ref 0))
        (etaf-test-next-turn-target t)
        (etaf-test-next-turn-source nil)
        (etaf-test-next-turn-sink nil))
    (unwind-protect
        (progn
          (setq etaf-test-next-turn-source source
                etaf-test-next-turn-sink target)
          (etaf-mount buffer-name
                      (etaf--view-call 'etaf-test-next-turn nil nil))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (before (etaf-runtime-generation runtime)))
            (setf (etaf-value source) 1)
            (should (= 2 (- (etaf-runtime-generation runtime) before)))
            (should (equal "1/1" (etaf-test--buffer-text buffer-name)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-route-is-opaque-and-unmount-disarms-sources ()
  "Keep sources free of Runtime closures and remove route tokens on unmount."
  (let ((buffer-name " *etaf-route-lifetime-test*") (source (etaf-ref 0)))
    (let ((baseline (hash-table-count (etaf-ref-subscribers source))))
      (etaf-mount buffer-name
                  (etaf--view-call 'etaf-test-dependency-only
                                   (list :source source) nil))
      (let* ((runtime (etaf-runtime-for-buffer buffer-name))
             (route (etaf-runtime-route-token runtime)))
        (should (symbolp (etaf-runtime-route-scheduler route)))
        (should-not (functionp (etaf-runtime-route-runtime-id route)))
        (should (gethash route (etaf-ref-subscribers source)))
        (etaf-unmount runtime)
        (should (= baseline (hash-table-count (etaf-ref-subscribers source)))))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-participant-publish-failure-restores-generation ()
  "Restore generation and Ebox state when participant publish fails after swap."
  (let ((buffer-name " *etaf-generation-rollback-test*")
        (source (etaf-ref 0))
        (etaf-test-retained-render-counts (make-hash-table :test #'eql)))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf--view-call 'etaf-test-retained-leaf
                                       (list :label 1 :cell source) nil))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (old-generation (etaf-runtime-current-generation runtime))
                 (old-swap (symbol-function 'etaf--runtime-swap-generation))
                 (old-rollback
                  (symbol-function 'etaf--runtime-participant-rollback))
                 (resource-count
                  (hash-table-count (etaf-runtime-resource-registry runtime)))
                 (artifact-count
                  (hash-table-count (etaf-runtime-artifact-registry runtime)))
                 rollback-saw-old)
            (cl-letf (((symbol-function 'etaf--runtime-swap-generation)
                       (lambda (&rest args)
                         (apply old-swap args)
                         (error "injected participant publish failure")))
                      ((symbol-function 'etaf--runtime-participant-rollback)
                       (lambda (participant)
                         (setq rollback-saw-old
                               (eq old-generation
                                   (etaf-runtime-current-generation runtime)))
                         (funcall old-rollback participant))))
              (should-error (setf (etaf-value source) 1) :type 'error))
            (should rollback-saw-old)
            (should (eq old-generation
                        (etaf-runtime-current-generation runtime)))
            (should (equal "1=0" (etaf-test--buffer-text buffer-name)))
            (should (= resource-count
                       (hash-table-count
                        (etaf-runtime-resource-registry runtime))))
            (should (<= (hash-table-count
                         (etaf-runtime-artifact-registry runtime))
                        artifact-count))
            (etaf-runtime-flush runtime)
            (should (equal "1=1" (etaf-test--buffer-text buffer-name)))
            (should (= (1+ (etaf-generation-generation-id old-generation))
                       (etaf-runtime-generation runtime)))
            (let ((committed (etaf-runtime-current-generation runtime)))
              (cl-letf (((symbol-function 'accept-change-group)
                         (lambda (&rest _)
                           (error "injected TP final accept failure"))))
                (should-error (setf (etaf-value source) 2) :type 'error))
              (should (eq committed (etaf-runtime-current-generation runtime)))
              (should (equal "1=1" (etaf-test--buffer-text buffer-name)))
              (should (= resource-count
                         (hash-table-count
                          (etaf-runtime-resource-registry runtime))))
              (should (<= (hash-table-count
                           (etaf-runtime-artifact-registry runtime))
                          artifact-count))
              (etaf-runtime-flush runtime)
              (should (equal "1=2" (etaf-test--buffer-text buffer-name))))
            (let ((committed (etaf-runtime-current-generation runtime)))
              (cl-letf (((symbol-function 'ebox-commit)
                         (lambda (&rest _)
                           (error "injected Ebox pre-publish failure"))))
                (should-error (setf (etaf-value source) 3) :type 'error))
              (should (eq committed (etaf-runtime-current-generation runtime)))
              (should (equal "1=2" (etaf-test--buffer-text buffer-name)))
              (etaf-runtime-flush runtime)
              (should (equal "1=3" (etaf-test--buffer-text buffer-name))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-artifact-registry-stays-bounded ()
  "Discard superseded artifacts after repeated Component publications."
  (let ((buffer-name " *etaf-artifact-bound-test*") (source (etaf-ref 0))
        (etaf-test-retained-render-counts (make-hash-table :test #'eql)))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf--view-call 'etaf-test-retained-leaf
                                       (list :label 1 :cell source) nil))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (baseline (hash-table-count
                            (etaf-runtime-artifact-registry runtime))))
            (dotimes (index 100)
              (setf (etaf-value source) (1+ index)))
            (should (<= (hash-table-count
                         (etaf-runtime-artifact-registry runtime))
                        baseline))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-prepublication-journals-are-exception-atomic ()
  "Rollback partial resource, artifact, and route installation immediately."
  (dolist (phase '(resource artifact route))
    (let* ((buffer-name (format " *etaf-journal-%S-test*" phase))
           (source (etaf-ref 0))
           (baseline (hash-table-count (etaf-ref-subscribers source)))
           (old-puthash (symbol-function 'puthash))
           (etaf-test-retained-render-counts (make-hash-table :test #'eql)))
      (cl-letf
          (((symbol-function 'puthash)
            (lambda (key value table)
              (let ((result (funcall old-puthash key value table)))
                (when
                    (pcase phase
                      ('resource
                       (and (consp key) (integerp (car key))
                            (integerp (cdr key))
                            (etaf--component-instance-p value)))
                      ('artifact
                       (and (consp key) (integerp (car key))
                            (integerp (cdr key))
                            (ebox-canonical-input-p value)))
                      ('route (etaf-runtime-route-p key)))
                  (error "injected %S journal write" phase))
                result))))
        (should-error
         (etaf-mount buffer-name
                     (etaf--view-call 'etaf-test-retained-leaf
                                      (list :label 1 :cell source) nil))
         :type 'error))
      (should-not (etaf-runtime-for-buffer buffer-name))
      (should (= baseline (hash-table-count (etaf-ref-subscribers source))))
      (etaf-mount buffer-name
                  (etaf--view-call 'etaf-test-retained-leaf
                                   (list :label 1 :cell source) nil))
      (etaf-unmount (etaf-runtime-for-buffer buffer-name))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-artifact-removal-failure-restores-retained-input ()
  "Rollback an obsolete-artifact removal inside the prepublication journal."
  (let ((buffer-name " *etaf-artifact-removal-rollback*")
        (source (etaf-ref 0))
        (etaf-test-retained-render-counts (make-hash-table :test #'eql)))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf--view-call 'etaf-test-retained-leaf
                                       (list :label 1 :cell source) nil))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-current-generation runtime))
                 (registry (etaf-runtime-artifact-registry runtime))
                 old-key old-input
                 (before (etaf-test--buffer-text buffer-name))
                 (original-remhash (symbol-function 'remhash))
                 injected-p)
            (maphash (lambda (key value)
                       (unless old-key
                         (setq old-key key old-input value)))
                     registry)
            (should old-key)
            (should (ebox-canonical-input-p old-input))
            (cl-letf (((symbol-function 'remhash)
                       (lambda (key table)
                         (if (and (not injected-p)
                                  (eq table registry)
                                  (equal key old-key))
                             (progn
                               (setq injected-p t)
                               (funcall original-remhash key table)
                               (error "injected artifact removal failure"))
                           (funcall original-remhash key table)))))
              (should-error (setf (etaf-value source) 1) :type 'error))
            (should injected-p)
            (should (eq generation (etaf-runtime-current-generation runtime)))
            (should (eq old-input (gethash old-key registry)))
            (should (equal before (etaf-test--buffer-text buffer-name)))
            (etaf-runtime-flush runtime)
            (should-not (equal before (etaf-test--buffer-text buffer-name)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-runtime-route-arm-kth-failure-is-bounded-and-retryable ()
  "Rollback each partial route arm and keep repeated failures bounded."
  (dolist (failure-index '(1 2))
    (let* ((buffer-name (format " *etaf-route-kth-%s-test*" failure-index))
           (show (etaf-ref nil)) (left (etaf-ref 0)) (right (etaf-ref 0))
           (etaf-test-retained-render-counts (make-hash-table :test #'eql))
           (view (lambda ()
                   (if (etaf-value show)
                       (etaf--view-call
                        'column nil
                        (list
                         (etaf--view-call 'etaf-test-retained-leaf
                                          (list :key 'left :label 1 :cell left)
                                          nil)
                         (etaf--view-call 'etaf-test-retained-leaf
                                          (list :key 'right :label 2 :cell right)
                                          nil)))
                     (etaf--view-call 'text nil (list "empty"))))))
      (unwind-protect
          (progn
            (etaf-mount buffer-name view)
            (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                   (old-generation (etaf-runtime-current-generation runtime))
                   (baseline-routes
                    (hash-table-count (etaf-runtime-route-sources runtime)))
                   (old-puthash (symbol-function 'puthash))
                   (writes 0))
              (cl-letf
                  (((symbol-function 'puthash)
                    (lambda (key value table)
                      (let ((result (funcall old-puthash key value table)))
                        (when (and (etaf-runtime-route-p key)
                                   (memq table (list (etaf-ref-subscribers left)
                                                     (etaf-ref-subscribers right))))
                          (cl-incf writes)
                          (when (= writes failure-index)
                            (error "injected kth route arm")))
                        result))))
                (should-error (setf (etaf-value show) t) :type 'error))
              (should (eq old-generation
                          (etaf-runtime-current-generation runtime)))
              (should (zerop (hash-table-count (etaf-ref-subscribers left))))
              (should (zerop (hash-table-count (etaf-ref-subscribers right))))
              (should (= baseline-routes
                         (hash-table-count
                          (etaf-runtime-route-sources runtime))))
              (etaf-runtime-flush runtime)
              (should (string-match-p "1=0"
                                      (etaf-test--buffer-text buffer-name)))
              (etaf-unmount runtime)
              (should (zerop (hash-table-count (etaf-ref-subscribers left))))
              (should (zerop (hash-table-count
                              (etaf-ref-subscribers right))))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
          (etaf-unmount runtime))
        (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer))))))

(ert-deftest etaf-runtime-published-generation-resolves-new-resource ()
  "Make every newly published resource membership immediately resolvable."
  (let* ((buffer-name " *etaf-publish-resource-visibility-test*")
         (show (etaf-ref nil)) (cell (etaf-ref 0)) (checked 0)
         (etaf-test-retained-render-counts (make-hash-table :test #'eql))
         (view
          (lambda ()
            (if (etaf-value show)
                (etaf--view-call 'etaf-test-retained-leaf
                                 (list :key 'new :label 1 :cell cell) nil)
              (etaf--view-call 'text nil (list "empty"))))))
    (unwind-protect
        (progn
          (etaf-mount buffer-name view)
          (let ((old-publish
                 (symbol-function 'etaf--runtime-participant-publish)))
            (cl-letf
                (((symbol-function 'etaf--runtime-participant-publish)
                  (lambda (participant)
                    (prog1 (funcall old-publish participant)
                      (let* ((runtime
                              (etaf--generation-participant-runtime participant))
                             (generation
                              (etaf-runtime-current-generation runtime)))
                        (maphash
                         (lambda (_identity semantic-id)
                           (let ((semantic
                                  (etaf--pvec-get
                                   (etaf-generation-semantic-nodes generation)
                                   semantic-id)))
                             (when (etaf--semantic-component-p semantic)
                               (should
                                (gethash
                                 (etaf--semantic-component-resource-key semantic)
                                 (etaf-runtime-resource-registry runtime)))
                               (cl-incf checked))))
                         (etaf-generation-identity-index generation)))))))
              (setf (etaf-value show) t)))
          (should (= 1 checked)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-local-parent-does-not-carry-unchanged-descendants ()
  "Avoid generation subtree carry for 500 unchanged children of a dirty parent."
  (let ((buffer-name " *etaf-wide-parent-local-test*")
        (etaf-test-retained-render-counts (make-hash-table :test #'eql)))
    (setq etaf-test-wide-parent-source (etaf-ref 0)
          etaf-test-wide-parent-cells
          (cl-loop repeat 500 collect (etaf-ref 0)))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-test-wide-parent)))
          (clrhash etaf-test-retained-render-counts)
          (let ((runtime (etaf-runtime-for-buffer buffer-name)))
            (cl-letf (((symbol-function 'etaf--runtime-carry-committed-subtree)
                       (lambda (&rest _)
                         (error "local path attempted committed subtree carry"))))
              (setf (etaf-value etaf-test-wide-parent-source) 1))
            (should (zerop (hash-table-count
                            etaf-test-retained-render-counts)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-direct-expr-publishes-child-range-only ()
  "Publish a direct material-child expr without running its Component owner."
  (let ((buffer-name " *etaf-direct-range-test*")
        (etaf-test-range-source (etaf-ref nil))
        (etaf-test-range-static-count 10)
        (etaf-test-range-evals 0)
        (etaf-test-range-component-renders 0)
        (range-replaces 0) (host-replaces 0) (commits 0))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-test-public-direct-range)))
          (setq etaf-test-range-evals 0
                etaf-test-range-component-renders 0)
          (let ((old-range (symbol-function 'ebox-candidate-replace-range-ref))
                (old-host (symbol-function 'ebox-candidate-replace-host-ref))
                (old-commit (symbol-function 'ebox-commit))
                (runtime (etaf-runtime-for-buffer buffer-name)))
            (cl-letf (((symbol-function 'ebox-candidate-replace-range-ref)
                       (lambda (&rest args)
                         (cl-incf range-replaces) (apply old-range args)))
                      ((symbol-function 'ebox-candidate-replace-host-ref)
                       (lambda (&rest args)
                         (cl-incf host-replaces) (apply old-host args)))
                      ((symbol-function 'ebox-commit)
                       (lambda (&rest args)
                         (cl-incf commits) (apply old-commit args)))
                      ((symbol-function 'etaf--runtime-render-dirty-component)
                       (lambda (&rest _)
                         (error "Public Range entered Component owner")))
                      ((symbol-function 'etaf--runtime-evaluate-root-candidate)
                       (lambda (&rest _)
                         (error "Public Range entered Root owner"))))
              (let ((before (etaf-runtime-generation runtime)))
                (setf (etaf-value etaf-test-range-source) '((item . "I")))
                (should (= 1 (- (etaf-runtime-generation runtime) before)))))
            (should (= 1 etaf-test-range-evals))
            (should (zerop etaf-test-range-component-renders))
            (should (= 1 range-replaces))
            (should (zerop host-replaces))
            (should (= 1 commits))
            (should (string-match-p "I" (etaf-test--buffer-text buffer-name)))
            (let* ((generation (etaf-runtime-current-generation runtime))
                   (range-id
                    (cl-loop for identity being the hash-keys of
                             (etaf-generation-identity-index generation)
                             using (hash-values semantic-id)
                             when (eq (car-safe identity) 'range)
                             return semantic-id))
                   (range (etaf--pvec-get
                           (etaf-generation-semantic-nodes generation) range-id)))
              (should (integerp range-id))
              (should (etaf--semantic-range-p range))
              (should (integerp (etaf--semantic-range-parent-id range)))
              (should (= 1 (length (etaf--semantic-range-item-host-ids range))))
              (should
               (equal '(range)
                      (mapcar
                       (lambda (effect-id)
                         (etaf--generation-effect-kind
                          (etaf--generation-effect generation effect-id)))
                       (etaf--generation-source-effects
                        generation etaf-test-range-source))))
              (cl-labels
                  ((walk (parent-id)
                     (dolist (child-id
                              (etaf--generation-child-ids
                               generation parent-id))
                       (should (integerp child-id))
                       (should (= parent-id
                                  (etaf--generation-parent-id
                                   generation child-id)))
                       (walk child-id))))
                (walk 0)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-view-expr-callsite-token-is-stable ()
  "Give repeated values from one compiled expr site the same opaque token."
  (let* ((spec etaf-test-macro-range-token--etaf-component-definition)
         (render (etaf--component-spec-render spec))
         (left (funcall render nil nil))
         (right (funcall render nil nil))
         (left-expr (car (etaf--view-node-children left)))
         (right-expr (car (etaf--view-node-children right))))
    (should (etaf--expr-token left-expr))
    (should (eq (etaf--expr-token left-expr)
                (etaf--expr-token right-expr)))))

(ert-deftest etaf-runtime-public-expr-token-addresses-one-range-across-mounts ()
  "Carry one macro-generated expr token into exactly one mounted Range site."
  (let ((etaf-test-range-source (etaf-ref nil)) tokens)
    (dolist (buffer-name '(" *etaf-public-range-token-a*"
                           " *etaf-public-range-token-b*"))
      (unwind-protect
          (progn
            (etaf-mount buffer-name (etaf-view (etaf-test-public-direct-range)))
            (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                   (generation (etaf-runtime-current-generation runtime))
                   ranges)
              (maphash
               (lambda (identity semantic-id)
                 (when (eq (car-safe identity) 'range)
                   (push (etaf--pvec-get
                          (etaf-generation-semantic-nodes generation)
                          semantic-id)
                         ranges)))
               (etaf-generation-identity-index generation))
              (should (= 1 (length ranges)))
              (push (etaf--semantic-range-token (car ranges)) tokens)))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
          (etaf-unmount runtime))
        (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer))))
    (should (eq (car tokens) (cadr tokens)))))

(ert-deftest etaf-runtime-does-not-encode-ebox-layout-shapes ()
  "Keep resolved backend layout construction in the Renderer port."
  (let ((source (with-temp-buffer
                  (insert-file-contents "etaf-runtime.el")
                  (buffer-string))))
    (should-not (string-match-p ":ebox-type" source))))

(ert-deftest etaf-runtime-direct-range-gate-a-transitions ()
  "Meet direct Range bounds for 10/100/500 static siblings and keyed survival."
  (dolist (fixture '((10 . 2) (100 . 3) (500 . 3)))
    (let* ((static-count (car fixture)) (bound (cdr fixture))
           (buffer-name (format " *etaf-range-gate-%s*" static-count))
           (etaf-test-range-source (etaf-ref nil))
           (etaf-test-range-static-count static-count)
           (etaf-test-range-evals 0)
           (etaf-test-range-component-renders 0)
           range-id range-ref a-id b-id static-records)
      (unwind-protect
          (progn
            (etaf-mount buffer-name (etaf-view (etaf-test-direct-range)))
            (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                   (generation (etaf-runtime-current-generation runtime)))
              (setq range-id
                    (cl-loop for identity being the hash-keys of
                             (etaf-generation-identity-index generation)
                             using (hash-values semantic-id)
                             when (eq (car-safe identity) 'range)
                             return semantic-id))
              (setq range-ref
                    (etaf--semantic-range-range-ref
                     (etaf--pvec-get
                      (etaf-generation-semantic-nodes generation) range-id)))
              (let* ((range (etaf--pvec-get
                             (etaf-generation-semantic-nodes generation)
                             range-id))
                     (parent-id (etaf--semantic-range-parent-id range)))
                (setq static-records
                      (cl-loop for child-id in
                               (etaf--generation-child-ids
                                generation parent-id)
                               unless (= child-id range-id)
                               collect
                               (cons child-id
                                     (etaf--pvec-get
                                      (etaf-generation-semantic-nodes generation)
                                      child-id)))))
              (dolist (items (list '((a . "A"))
                                   '((a . "A") (b . "B"))
                                   '((a . "A2") (b . "B"))
                                   '((b . "B2")) nil))
                (setq etaf-test-range-evals 0
                      etaf-test-range-component-renders 0)
                (let ((before (etaf-runtime-generation runtime))
                      (old-identity-index
                       (etaf-generation-identity-index
                        (etaf-runtime-current-generation runtime))))
                  (cl-letf
                      (((symbol-function 'etaf--runtime-render-dirty-component)
                        (lambda (&rest _)
                          (error "Range update entered Component owner")))
                       ((symbol-function 'etaf--runtime-evaluate-root-candidate)
                        (lambda (&rest _)
                          (error "Range update entered Root owner"))))
                    (setf (etaf-value etaf-test-range-source) items))
                  (should (= 1 (- (etaf-runtime-generation runtime) before)))
                  (should (eq old-identity-index
                              (etaf-generation-identity-index
                               (etaf-runtime-current-generation runtime)))))
                (should (= 1 etaf-test-range-evals))
                (should (zerop etaf-test-range-component-renders))
                (let* ((generation (etaf-runtime-current-generation runtime))
                       (range (etaf--pvec-get
                               (etaf-generation-semantic-nodes generation)
                               range-id))
                       (metrics (car (plist-get
                                      (plist-get (ebox-buffer-update-report
                                                  buffer-name)
                                                 :range-metrics)
                                      :parents))))
                  (should (eq range-ref (etaf--semantic-range-range-ref range)))
                  (should (<= (plist-get metrics :segment-visits) bound))
                  (should (<= (plist-get metrics :segment-copies) bound))
                  (should (= (plist-get metrics :new-payload-visits)
                             (length items)))
                  (should (zerop (plist-get metrics
                                            :unaffected-payload-visits)))
                  (should (= 1 (plist-get
                                (plist-get (ebox-buffer-update-report buffer-name)
                                           :range-metrics)
                                :replacement-count)))
                  (when (equal items '((b . "B2")))
                    (should (zerop (plist-get (ebox-buffer-update-report
                                               buffer-name)
                                              :created-objects))))
                  (dolist (entry static-records)
                    (should (eq (cdr entry)
                                (etaf--pvec-get
                                 (etaf-generation-semantic-nodes generation)
                                 (car entry)))))
                  (when (assoc 'a items)
                    (let ((id (gethash
                               (list 'host range-id :key 'a)
                               (etaf--semantic-range-item-identity-index range))))
                      (if a-id (should (= a-id id)) (setq a-id id))))
                  (when (assoc 'b items)
                    (let ((id (gethash
                               (list 'host range-id :key 'b)
                               (etaf--semantic-range-item-identity-index range))))
                      (if b-id (should (= b-id id)) (setq b-id id))))))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
          (etaf-unmount runtime))
        (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer))))))

(ert-deftest etaf-runtime-detached-range-removals-are-not-rescanned ()
  "A Range's complete removal set should skip duplicate subtree traversal."
  (let* ((candidate-children (make-hash-table :test #'eql))
         (runtime
          (etaf--runtime-create
           :candidate-graph-children candidate-children
           :candidate-graph-nodes (make-hash-table :test #'eql)
           :candidate-removed-semantic-ids '(20 30)))
         queries)
    (puthash 10 nil candidate-children)
    (cl-letf (((symbol-function 'etaf--generation-child-ids)
               (lambda (_generation semantic-id)
                 (push semantic-id queries)
                 (if (= semantic-id 10)
                     '(20)
                   (error "Pre-recorded subtree was traversed: %S"
                          semantic-id)))))
      (etaf--runtime-record-detached-candidate-subtrees runtime 'base))
    (should (equal '(10) (nreverse queries)))
    (should (equal '(20 30)
                   (etaf-runtime-candidate-removed-semantic-ids runtime)))))

(ert-deftest etaf-runtime-two-direct-ranges-batch-one-publication ()
  "Evaluate and splice two disjoint Ranges once in one logical commit."
  (let ((buffer-name " *etaf-two-range-test*")
        (etaf-test-range-source (etaf-ref nil))
        (etaf-test-range-left-evals 0) (etaf-test-range-right-evals 0)
        (range-replaces 0) (commits 0))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-test-two-direct-ranges)))
          (setq etaf-test-range-left-evals 0 etaf-test-range-right-evals 0)
          (let ((old-range (symbol-function 'ebox-candidate-replace-range-ref))
                (old-commit (symbol-function 'ebox-commit))
                (runtime (etaf-runtime-for-buffer buffer-name)))
            (cl-letf (((symbol-function 'ebox-candidate-replace-range-ref)
                       (lambda (&rest args)
                         (cl-incf range-replaces) (apply old-range args)))
                      ((symbol-function 'ebox-commit)
                       (lambda (&rest args)
                         (cl-incf commits) (apply old-commit args))))
              (let ((before (etaf-runtime-generation runtime)))
                (setf (etaf-value etaf-test-range-source) '((x . "X")))
                (should (= 1 (- (etaf-runtime-generation runtime) before)))))
            (should (= 1 etaf-test-range-left-evals))
            (should (= 1 etaf-test-range-right-evals))
            (should (= 2 range-replaces))
            (should (= 1 commits))
            (should (= 1 (hash-table-count
                          (etaf-ref-subscribers etaf-test-range-source))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-range-artifact-survives-root-rebuild ()
  "Relower current Range graph after Root change without application thunks."
  (let* ((buffer-name " *etaf-range-root-coherence-test*")
         (etaf-test-range-source (etaf-ref nil))
         (etaf-test-range-static-count 10)
         (etaf-test-range-evals 0)
         (etaf-test-range-component-renders 0)
         (etaf-test-range-host-prop-calls 0)
         (root-source (etaf-ref nil))
         (root-calls 0)
         (view
          (lambda ()
            (cl-incf root-calls)
            (etaf--view-call
             'column nil
             (append
              (list (etaf--view-call 'text (list :key 'head) (list "H")))
              (and (etaf-value root-source)
                   (list (etaf--view-call 'text (list :key 'inserted)
                                          (list "X"))))
              (list (etaf--view-call 'etaf-test-direct-range
                                     (list :key 'range-owner) nil)))))))
    (unwind-protect
        (progn
          (etaf-mount buffer-name view)
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-current-generation runtime))
                 (range-id
                  (cl-loop for identity being the hash-keys of
                           (etaf-generation-identity-index generation)
                           using (hash-values semantic-id)
                           when (eq (car-safe identity) 'range)
                           return semantic-id))
                 (range-ref
                  (etaf--semantic-range-range-ref
                   (etaf--pvec-get (etaf-generation-semantic-nodes generation)
                                   range-id))))
            (setf (etaf-value etaf-test-range-source) '((a . "A")))
            (setq etaf-test-range-evals 0
                  etaf-test-range-component-renders 0)
            (let ((prop-calls etaf-test-range-host-prop-calls))
              (setf (etaf-value root-source) t)
              (should (zerop etaf-test-range-evals))
              (should (zerop etaf-test-range-component-renders))
              (should (= prop-calls etaf-test-range-host-prop-calls)))
            (let* ((generation (etaf-runtime-current-generation runtime))
                   (range (etaf--pvec-get
                           (etaf-generation-semantic-nodes generation) range-id)))
              (should (eq range-ref (etaf--semantic-range-range-ref range)))
              (should (string-match-p "A" (etaf-test--buffer-text buffer-name))))
            (setq etaf-test-range-evals 0)
            (setf (etaf-value etaf-test-range-source) '((b . "B")))
            (should (= 1 etaf-test-range-evals))
            (should (string-match-p "B" (etaf-test--buffer-text buffer-name)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-range-address-survives-preceding-static-insert ()
  "Keep Range id/ref when its material parent's preceding siblings change."
  (let ((buffer-name " *etaf-range-static-insert-test*")
        (count (etaf-ref 2))
        (etaf-test-range-source (etaf-ref nil))
        (etaf-test-range-evals 0))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (etaf-test-counted-direct-range :count (etaf-value count))))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-current-generation runtime))
                 (range-id
                  (cl-loop for identity being the hash-keys of
                           (etaf-generation-identity-index generation)
                           using (hash-values semantic-id)
                           when (eq (car-safe identity) 'range)
                           return semantic-id))
                 (range-ref
                  (etaf--semantic-range-range-ref
                   (etaf--pvec-get (etaf-generation-semantic-nodes generation)
                                   range-id))))
            (setq etaf-test-range-evals 0)
            (setf (etaf-value count) 5)
            (should (zerop etaf-test-range-evals))
            (let* ((generation (etaf-runtime-current-generation runtime))
                   (range (etaf--pvec-get
                           (etaf-generation-semantic-nodes generation) range-id)))
              (should (eq range-ref (etaf--semantic-range-range-ref range))))
            (setf (etaf-value etaf-test-range-source) '((a . "A")))
            (should (= 1 etaf-test-range-evals))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-range-rebuild-keeps-bare-string-siblings ()
  "Keep mounted synthetic string Hosts through Range invalidation and rebuild."
  (let* ((buffer-name " *etaf-range-string-siblings-test*")
         (etaf-test-range-source (etaf-ref nil))
         (root-source (etaf-ref 0))
         (view (lambda ()
                 (etaf-value root-source)
                 (etaf--view-call 'etaf-test-string-sibling-range
                                  (list :key 'owner) nil))))
    (unwind-protect
        (progn
          (etaf-mount buffer-name view)
          (setf (etaf-value etaf-test-range-source) '((a . "A")))
          (setf (etaf-value root-source) 1)
          (let ((text (etaf-test--buffer-text buffer-name)))
            (should (string-match-p "prefix" text))
            (should (string-match-p "A" text))
            (should (string-match-p "suffix" text))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-range-failure-rolls-back-and-manual-retries ()
  "Restore Range graph/artifacts/buffer for prepublish and final-accept failure."
  (let ((buffer-name " *etaf-range-rollback-test*")
        (etaf-test-range-source (etaf-ref nil))
        (etaf-test-range-static-count 10))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-test-direct-range)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (old-generation (etaf-runtime-current-generation runtime))
                 (range-id
                  (cl-loop for identity being the hash-keys of
                           (etaf-generation-identity-index old-generation)
                           using (hash-values semantic-id)
                           when (eq (car-safe identity) 'range)
                           return semantic-id))
                 (old-range
                  (etaf--pvec-get (etaf-generation-semantic-nodes old-generation)
                                  range-id))
                 (artifact-count
                  (hash-table-count (etaf-runtime-range-artifact-registry runtime))))
            (cl-letf (((symbol-function 'ebox-candidate-replace-range-ref)
                       (lambda (&rest _)
                         (error "injected Range prepublish failure"))))
              (should-error
               (setf (etaf-value etaf-test-range-source) '((a . "A")))
               :type 'error))
            (should (eq old-generation (etaf-runtime-current-generation runtime)))
            (should (eq old-range
                        (etaf--pvec-get
                         (etaf-generation-semantic-nodes
                          (etaf-runtime-current-generation runtime))
                         range-id)))
            (should (= artifact-count
                       (hash-table-count
                        (etaf-runtime-range-artifact-registry runtime))))
            (etaf-runtime-flush runtime)
            (should (string-match-p "A" (etaf-test--buffer-text buffer-name)))
            (let ((committed (etaf-runtime-current-generation runtime)))
              (cl-letf (((symbol-function 'accept-change-group)
                         (lambda (&rest _)
                           (error "injected Range final accept failure"))))
                (should-error
                 (setf (etaf-value etaf-test-range-source)
                       '((a . "A") (b . "B")))
                 :type 'error))
              (should (eq committed (etaf-runtime-current-generation runtime)))
              (should-not (string-match-p "B"
                                          (etaf-test--buffer-text buffer-name)))
              (etaf-runtime-flush runtime)
              (should (string-match-p "B"
                                      (etaf-test--buffer-text buffer-name))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-direct-range-rejects-step4b-output-without-reownership ()
  "Reject direct Component output while retaining Range-only dependency."
  (dolist (unsupported '(component deep-component
                         deep-expr-component))
    (let ((buffer-name (format " *etaf-range-unsupported-%S*" unsupported))
          (etaf-test-unsupported-range-source (etaf-ref 'host)))
      (unwind-protect
          (progn
            (etaf-mount buffer-name
                        (etaf-view (etaf-test-unsupported-direct-range)))
            (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                   (generation (etaf-runtime-current-generation runtime)))
              (should-error
               (setf (etaf-value etaf-test-unsupported-range-source)
                     unsupported)
               :type 'etaf-runtime-error)
              (should (eq generation (etaf-runtime-current-generation runtime)))
              (should
               (equal '(range)
                      (mapcar
                       (lambda (effect-id)
                         (etaf--generation-effect-kind
                          (etaf--generation-effect generation effect-id)))
                       (etaf--generation-source-effects
                        generation etaf-test-unsupported-range-source))))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
          (etaf-unmount runtime))
        (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer))))))

(ert-deftest etaf-runtime-direct-range-normalizes-bare-string-item ()
  "Represent a bare direct expr string as one synthetic semantic text Host."
  (let ((buffer-name " *etaf-string-range-test*")
        (etaf-test-string-range-source (etaf-ref nil)))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-test-public-string-range)))
          (setf (etaf-value etaf-test-string-range-source) "hello")
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-current-generation runtime))
                 (range-id
                  (car (etaf--generation-source-effects
                        generation etaf-test-string-range-source)))
                 (effect (etaf--generation-effect generation range-id))
                 (range (etaf--pvec-get
                         (etaf-generation-semantic-nodes generation)
                         (etaf--generation-effect-semantic-id effect))))
            (should (eq 'range (etaf--generation-effect-kind effect)))
            (should (= 1 (length (etaf--semantic-range-item-host-ids range))))
            (should (string-match-p "hello"
                                    (etaf-test--buffer-text buffer-name)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-range-recursively-retains-and-removes-host-subtree ()
  "Retain keyed nested Hosts and tombstone their full removed subtree."
  (let ((buffer-name " *etaf-nested-range-hosts-test*")
        (etaf-test-nested-range-present (etaf-ref t))
        (etaf-test-nested-range-source (etaf-ref (cons "A" nil)))
        (etaf-test-nested-range-evals 0))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-test-nested-host-range)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-current-generation runtime))
                 (effect-id (car (etaf--generation-source-effects
                                  generation etaf-test-nested-range-source)))
                 (effect (etaf--generation-effect generation effect-id))
                 (range-id (etaf--generation-effect-semantic-id effect))
                 (range (etaf--pvec-get
                         (etaf-generation-semantic-nodes generation) range-id))
                 (nested-id
                  (cl-loop for identity being the hash-keys of
                           (etaf--semantic-range-item-identity-index range)
                           using (hash-values semantic-id)
                           when (equal (plist-get (cddr identity) :key) 'nested)
                           return semantic-id)))
            (setq etaf-test-nested-range-evals 0)
            (cl-letf (((symbol-function 'etaf--runtime-render-dirty-component)
                       (lambda (&rest _)
                         (error "Nested Range entered Component owner"))))
              (setf (etaf-value etaf-test-nested-range-source)
                    (cons "B" t)))
            (should (= 1 etaf-test-nested-range-evals))
            (should (= 1 (plist-get
                          (plist-get (ebox-buffer-update-report buffer-name)
                                     :range-metrics)
                          :replacement-count)))
            (let* ((generation (etaf-runtime-current-generation runtime))
                   (range (etaf--pvec-get
                           (etaf-generation-semantic-nodes generation) range-id)))
              (should (= nested-id
                         (cl-loop for identity being the hash-keys of
                                  (etaf--semantic-range-item-identity-index range)
                                  using (hash-values semantic-id)
                                  when (equal (plist-get (cddr identity) :key)
                                              'nested)
                                  return semantic-id)))
              (should
               (equal '(range)
                      (mapcar
                       (lambda (id)
                         (etaf--generation-effect-kind
                          (etaf--generation-effect generation id)))
                       (etaf--generation-source-effects
                        generation etaf-test-nested-range-source))))
              (let* ((old-generation generation)
                     (old-range range)
                     (removed-ids
                      (etaf--runtime-generation-descendant-ids
                       old-generation
                       (etaf--semantic-range-item-host-ids old-range))))
                (setf (etaf-value etaf-test-nested-range-present) nil)
                (let ((new-generation
                       (etaf-runtime-current-generation runtime)))
                  (dolist (semantic-id removed-ids)
                    (should (etaf--pvec-get
                             (etaf-generation-semantic-nodes old-generation)
                             semantic-id))
                    (should-not (etaf--pvec-get
                                 (etaf-generation-semantic-nodes new-generation)
                                 semantic-id))
                    (should-not
                     (etaf--generation-parent-id new-generation semantic-id))
                    (should-not
                     (etaf--generation-child-ids
                      new-generation semantic-id))))))))
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

(ert-deftest etaf-runtime-inline-output-equal-promotes-dependencies-only ()
  "Promote an inline branch dependency change without Ebox publication."
  (let ((buffer-name " *etaf-inline-dependency-only-test*")
        (etaf-test-inline-branch-mode (etaf-ref nil))
        (etaf-test-inline-branch-left (etaf-ref 0))
        (etaf-test-inline-branch-right (etaf-ref 0))
        (etaf-test-inline-branch-evals 0)
        (etaf-test-inline-branch-updated 0)
        (commits 0))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-test-inline-dependency-branch)))
          (setq etaf-test-inline-branch-evals 0)
          (let ((runtime (etaf-runtime-for-buffer buffer-name))
                (old-commit (symbol-function 'ebox-commit)))
            (cl-letf (((symbol-function 'ebox-commit)
                       (lambda (&rest args)
                         (cl-incf commits) (apply old-commit args))))
              (let ((before (etaf-runtime-generation runtime)))
                (setf (etaf-value etaf-test-inline-branch-mode) t)
                (should (= 1 (- (etaf-runtime-generation runtime) before))))
              (should (zerop commits))
              (should (zerop etaf-test-inline-branch-updated))
              (let* ((generation (etaf-runtime-current-generation runtime))
                     (before (etaf-runtime-generation runtime)))
                (should-not (etaf--generation-source-effects
                             generation etaf-test-inline-branch-left))
                (should (etaf--generation-source-effects
                         generation etaf-test-inline-branch-right))
                (setf (etaf-value etaf-test-inline-branch-left) 1)
                (should (= before (etaf-runtime-generation runtime)))
                (setf (etaf-value etaf-test-inline-branch-right) 1)
                (should (= (1+ before) (etaf-runtime-generation runtime)))
                (should (zerop commits))
                (should (zerop etaf-test-inline-branch-updated))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-slot-inline-keeps-authoring-component-environment ()
  "Read authoring parent props through default and forwarded named slots."
  (dolist (component '(etaf-test-slot-env-parent
                       etaf-test-slot-env-named-parent))
    (let ((buffer-name (format " *etaf-slot-env-%S*" component))
          (label (etaf-ref "A")))
      (setq etaf-test-slot-parent-renders 0
            etaf-test-slot-forwarder-renders 0
            etaf-test-slot-consumer-renders 0)
      (unwind-protect
          (progn
            (etaf-mount
             buffer-name
            (etaf--view-call component
                              (list :label
                                    (etaf--expr-create
                                     :thunk (lambda () (etaf-value label))))
                              nil))
            (should (equal "A" (etaf-test--buffer-text buffer-name)))
            (setq etaf-test-slot-parent-renders 0
                  etaf-test-slot-forwarder-renders 0
                  etaf-test-slot-consumer-renders 0)
            (setf (etaf-value label) "B")
            (should (equal "B" (etaf-test--buffer-text buffer-name)))
            (should (= 1 etaf-test-slot-parent-renders))
            (should (zerop etaf-test-slot-forwarder-renders))
            (should (zerop etaf-test-slot-consumer-renders)))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
          (etaf-unmount runtime))
        (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer))))))

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

(ert-deftest etaf-runtime-inline-and-input-fixed-point-uses-final-props-once ()
  "Run input, inline, and Component render once for either source write order."
  (dolist (order '((input inline) (inline input)))
    (let ((buffer-name (format " *etaf-inline-input-%S*" order))
          (label (etaf-ref "A"))
          (etaf-test-inline-priority-source (etaf-ref 0))
          (etaf-test-inline-priority-evals 0)
          (etaf-test-inline-priority-renders 0)
          (etaf-test-inline-priority-updated 0))
      (unwind-protect
          (progn
            (etaf-mount
             buffer-name
             (etaf-view
              (etaf-test-inline-input-priority :label (etaf-value label))))
            (setq etaf-test-inline-priority-evals 0
                  etaf-test-inline-priority-renders 0
                  etaf-test-inline-priority-updated 0)
            (let ((runtime (etaf-runtime-for-buffer buffer-name)))
              (etaf-runtime-event-begin runtime)
              (dolist (which order)
                (if (eq which 'input)
                    (setf (etaf-value label) "B")
                  (setf (etaf-value etaf-test-inline-priority-source) 1)))
              (etaf-runtime-event-end runtime)
              (should (= 1 etaf-test-inline-priority-evals))
              (should (= 1 etaf-test-inline-priority-renders))
              (should (= 1 etaf-test-inline-priority-updated))
              (should (equal "B/1" (etaf-test--buffer-text buffer-name)))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
          (etaf-unmount runtime))
        (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer))))))

(ert-deftest etaf-runtime-range-and-input-fixed-point-reuses-range-candidate ()
  "Evaluate direct Range once when Component input changes in the same turn."
  (dolist (order '((input range) (range input)))
    (let ((buffer-name (format " *etaf-range-input-%S*" order))
          (marker (etaf-ref "A"))
          (etaf-test-range-source (etaf-ref 0))
          (etaf-test-range-evals 0)
          (etaf-test-range-component-renders 0))
      (unwind-protect
          (progn
            (etaf-mount
             buffer-name
             (etaf-view
              (etaf-test-range-input-priority :marker (etaf-value marker))))
            (setq etaf-test-range-evals 0 etaf-test-range-component-renders 0)
            (let ((runtime (etaf-runtime-for-buffer buffer-name)))
              (etaf-runtime-event-begin runtime)
              (dolist (which order)
                (if (eq which 'input)
                    (setf (etaf-value marker) "B")
                  (setf (etaf-value etaf-test-range-source) 1)))
              (etaf-runtime-event-end runtime)
              (should (= 1 etaf-test-range-evals))
              (should (= 1 etaf-test-range-component-renders))
              (should (string-match-p "B/1"
                                      (etaf-test--buffer-text buffer-name)))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
          (etaf-unmount runtime))
        (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer))))))

(ert-deftest etaf-runtime-slot-range-direct-source-skips-component-renders ()
  "Update default, forwarded named, and fallback slot Ranges directly."
  (dolist (component '(etaf-test-slot-range-parent
                       etaf-test-slot-range-named-parent
                       etaf-test-slot-range-fallback))
    (let ((buffer-name (format " *etaf-slot-range-%S*" component))
          (etaf-test-slot-source (etaf-ref nil))
          (range-replaces 0) (host-replaces 0) (commits 0))
      (setq etaf-test-slot-range-evals 0
            etaf-test-slot-parent-renders 0
            etaf-test-slot-forwarder-renders 0
            etaf-test-slot-consumer-renders 0
            etaf-test-slot-author-updated 0
            etaf-test-slot-consumer-updated 0)
      (unwind-protect
          (progn
            (etaf-mount buffer-name (etaf--view-call component nil nil))
            (setq etaf-test-slot-range-evals 0
                  etaf-test-slot-parent-renders 0
                  etaf-test-slot-forwarder-renders 0
                  etaf-test-slot-consumer-renders 0)
            (let ((old-range (symbol-function 'ebox-candidate-replace-range-ref))
                  (old-host (symbol-function 'ebox-candidate-replace-host-ref))
                  (old-commit (symbol-function 'ebox-commit)))
              (cl-letf (((symbol-function 'ebox-candidate-replace-range-ref)
                         (lambda (&rest args)
                           (cl-incf range-replaces) (apply old-range args)))
                        ((symbol-function 'ebox-candidate-replace-host-ref)
                         (lambda (&rest args)
                           (cl-incf host-replaces) (apply old-host args)))
                        ((symbol-function 'ebox-commit)
                         (lambda (&rest args)
                           (cl-incf commits) (apply old-commit args))))
                (setf (etaf-value etaf-test-slot-source) '((a . "A")))))
            (should (= 1 etaf-test-slot-range-evals))
            (should (= 1 range-replaces))
            (should (zerop host-replaces))
            (should (= 1 commits))
            (should (zerop etaf-test-slot-parent-renders))
            (should (zerop etaf-test-slot-forwarder-renders))
            (should (zerop etaf-test-slot-consumer-renders))
            (if (eq component 'etaf-test-slot-range-fallback)
                (progn
                  (should (zerop etaf-test-slot-author-updated))
                  (should (= 1 etaf-test-slot-consumer-updated))
                  (with-current-buffer buffer-name
                    (should (equal '(:foreground "fallback-color")
                                   (get-text-property
                                    0 'face (buffer-string))))))
              (should (= 1 etaf-test-slot-author-updated))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
          (etaf-unmount runtime))
        (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer))))))

(ert-deftest etaf-runtime-slot-range-two-sites-batch-one-commit ()
  "Evaluate two projection sites and publish two Range replacements once."
  (let ((buffer-name " *etaf-slot-range-two-sites-test*")
        (etaf-test-slot-source (etaf-ref nil))
        (etaf-test-slot-range-evals 0)
        (range-replaces 0) (commits 0))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf-view (etaf-test-slot-range-two-site-parent)))
          (setq etaf-test-slot-range-evals 0)
          (let ((old-range (symbol-function 'ebox-candidate-replace-range-ref))
                (old-commit (symbol-function 'ebox-commit)))
            (cl-letf (((symbol-function 'ebox-candidate-replace-range-ref)
                       (lambda (&rest args)
                         (cl-incf range-replaces) (apply old-range args)))
                      ((symbol-function 'ebox-commit)
                       (lambda (&rest args)
                         (cl-incf commits) (apply old-commit args))))
              (setf (etaf-value etaf-test-slot-source) '((a . "A")))))
          (should (= 2 etaf-test-slot-range-evals))
          (should (= 2 range-replaces))
          (should (= 1 commits)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-slot-retarget-equal-output-promotes-dependencies ()
  "Retarget caller slot deps without rendering Consumer or publishing Ebox."
  (let ((buffer-name " *etaf-slot-retarget-equal-test*")
        (mode (etaf-ref nil))
        (etaf-test-slot-branch-left (etaf-ref 0))
        (etaf-test-slot-branch-right (etaf-ref 0))
        (commits 0))
    (setq etaf-test-slot-parent-renders 0
          etaf-test-slot-consumer-renders 0)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (etaf-test-slot-range-branch-parent :mode (etaf-value mode))))
          (setq etaf-test-slot-parent-renders 0
                etaf-test-slot-consumer-renders 0)
          (let ((runtime (etaf-runtime-for-buffer buffer-name))
                (old-commit (symbol-function 'ebox-commit)))
            (cl-letf (((symbol-function 'ebox-commit)
                       (lambda (&rest args)
                         (cl-incf commits) (apply old-commit args))))
              (let ((before (etaf-runtime-generation runtime)))
                (setf (etaf-value mode) t)
                (should (= 1 (- (etaf-runtime-generation runtime) before)))))
            (should (= 1 etaf-test-slot-parent-renders))
            (should (zerop etaf-test-slot-consumer-renders))
            (should (zerop commits))
            (let ((generation (etaf-runtime-current-generation runtime)))
              (should-not (etaf--generation-source-effects
                           generation etaf-test-slot-branch-left))
              (should (etaf--generation-source-effects
                       generation etaf-test-slot-branch-right)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-slot-range-rolls-back-rebuilds-and-removes-items ()
  "Keep slot Range state atomic across rollback, rebuild, and item removal."
  (let* ((buffer-name " *etaf-slot-range-rollback-test*")
         (etaf-test-slot-source (etaf-ref '((a . "A"))))
         (root-source (etaf-ref 0))
         (view (lambda ()
                 (etaf-value root-source)
                 (etaf--view-call 'etaf-test-slot-range-parent
                                  (list :key 'owner) nil))))
    (unwind-protect
        (progn
          (etaf-mount buffer-name view)
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-current-generation runtime))
                 (effect-id (car (etaf--generation-source-effects
                                  generation etaf-test-slot-source)))
                 (effect (etaf--generation-effect generation effect-id))
                 (slot-id (etaf--generation-effect-semantic-id effect)))
            (should (eq 'slot (etaf--generation-effect-kind effect)))
            (setq etaf-test-slot-range-evals 0)
            (setf (etaf-value etaf-test-slot-source) '((b . "B")))
            (should (= 1 etaf-test-slot-range-evals))
            (setq etaf-test-slot-range-evals 0)
            (setf (etaf-value root-source) 1)
            (should (zerop etaf-test-slot-range-evals))
            (should (string-match-p "B" (etaf-test--buffer-text buffer-name)))
            (let ((committed (etaf-runtime-current-generation runtime))
                  (before (etaf-test--buffer-text buffer-name)))
              (cl-letf (((symbol-function 'accept-change-group)
                         (lambda (&rest _)
                           (error "injected slot Range final accept failure"))))
                (should-error
                 (setf (etaf-value etaf-test-slot-source) '((c . "C")))
                 :type 'error))
              (should (eq committed (etaf-runtime-current-generation runtime)))
              (should (equal before (etaf-test--buffer-text buffer-name))))
            (etaf-runtime-flush runtime)
            (let* ((generation (etaf-runtime-current-generation runtime))
                   (slot (etaf--pvec-get
                          (etaf-generation-semantic-nodes generation) slot-id))
                   (item-id (gethash (list 'host slot-id :key 'c)
                                     (etaf--semantic-slot-range-item-identity-index
                                      slot))))
              (should item-id)
              (should (string-match-p "C" (etaf-test--buffer-text buffer-name)))
              (setf (etaf-value etaf-test-slot-source) nil)
              (let ((generation (etaf-runtime-current-generation runtime)))
                (should-not (etaf--pvec-get
                             (etaf-generation-semantic-nodes generation) item-id))
                (should-not
                 (etaf--generation-parent-id generation item-id))
                (should-not
                 (etaf--generation-child-ids generation item-id))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-material-fragment-is-one-retained-range-owner ()
  "Update a material fragment without rendering its Component or Root."
  (let ((buffer-name " *etaf-fragment-range-test*")
        (etaf-test-fragment-source (etaf-ref nil))
        (range-replaces 0) (root-replaces 0) (commits 0))
    (setq etaf-test-fragment-range-evals 0
          etaf-test-fragment-owner-renders 0)
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf-view (etaf-test-fragment-range-owner)))
          (setq etaf-test-fragment-range-evals 0
                etaf-test-fragment-owner-renders 0)
          (let ((old-range (symbol-function 'ebox-candidate-replace-range-ref))
                (old-root (symbol-function 'ebox-candidate-replace-root))
                (old-commit (symbol-function 'ebox-commit)))
            (cl-letf (((symbol-function 'ebox-candidate-replace-range-ref)
                       (lambda (&rest args)
                         (cl-incf range-replaces) (apply old-range args)))
                      ((symbol-function 'ebox-candidate-replace-root)
                       (lambda (&rest args)
                         (cl-incf root-replaces) (apply old-root args)))
                      ((symbol-function 'ebox-commit)
                       (lambda (&rest args)
                         (cl-incf commits) (apply old-commit args))))
              (setf (etaf-value etaf-test-fragment-source)
                    '((a . "A") (b . "B")))))
          (should (= 1 etaf-test-fragment-range-evals))
          (should (zerop etaf-test-fragment-owner-renders))
          (should (= 1 range-replaces))
          (should (zerop root-replaces))
          (should (= 1 commits))
          (should (string-match-p "A" (etaf-test--buffer-text buffer-name)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-current-generation runtime))
                 (effect-id (car (etaf--generation-source-effects
                                  generation etaf-test-fragment-source))))
            (should (eq 'fragment
                        (etaf--generation-effect-kind
                         (etaf--generation-effect generation effect-id))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))


(ert-deftest etaf-runtime-root-effect-owns-one-semantic-root-range ()
  "Publish Root changes through one semantic Root Range and root replacement."
  (let* ((buffer-name " *etaf-semantic-root-range-test*")
         (source (etaf-ref nil))
         (root-evals 0) (root-replaces 0) (commits 0)
         (view (lambda ()
                 (cl-incf root-evals)
                 (mapcar (lambda (entry)
                           (etaf--view-call 'text (list :key (car entry))
                                            (list (cdr entry))))
                         (etaf-value source)))))
    (unwind-protect
        (progn
          (etaf-mount buffer-name view)
          (setq root-evals 0)
          (let ((old-root (symbol-function 'ebox-candidate-replace-root))
                (old-commit (symbol-function 'ebox-commit)))
            (cl-letf (((symbol-function 'ebox-candidate-replace-root)
                       (lambda (&rest args)
                         (cl-incf root-replaces) (apply old-root args)))
                      ((symbol-function 'ebox-commit)
                       (lambda (&rest args)
                         (cl-incf commits) (apply old-commit args))))
              (setf (etaf-value source) '((a . "A") (b . "B")))))
          (should (= 1 root-evals))
          (should (= 1 root-replaces))
          (should (= 1 commits))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-current-generation runtime))
                 (root (etaf--pvec-get
                        (etaf-generation-semantic-nodes generation) 0))
                 (range-id (car (etaf--generation-child-ids generation 0)))
                 (range (etaf--pvec-get
                         (etaf-generation-semantic-nodes generation) range-id)))
            (should (etaf--semantic-root-p root))
            (should (eq 'root (etaf--semantic-range-kind range)))
            (should (= 0 (etaf--semantic-range-parent-id range)))
            (should (= range-id
                       (etaf--generation-effect-semantic-id
                        (etaf--generation-effect generation 0))))
            (let ((committed generation)
                  (before (etaf-test--buffer-text buffer-name)))
              (cl-letf (((symbol-function 'accept-change-group)
                         (lambda (&rest _)
                           (error "injected Root final accept failure"))))
                (should-error
                 (setf (etaf-value source) '((c . "C"))) :type 'error))
              (should (eq committed (etaf-runtime-current-generation runtime)))
              (should (equal before (etaf-test--buffer-text buffer-name))))
            (etaf-runtime-flush runtime)
            (should (string-match-p "C" (etaf-test--buffer-text buffer-name)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-transparent-component-publishes-output-range ()
  "Publish transparent Component nil/one/many output through one Range."
  (let ((buffer-name " *etaf-transparent-output-range-test*")
        (etaf-test-transparent-source (etaf-ref nil))
        (range-replaces 0) (host-replaces 0) (commits 0))
    (setq etaf-test-transparent-renders 0
          etaf-test-transparent-parent-renders 0)
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-test-transparent-parent)))
          (setq etaf-test-transparent-renders 0
                etaf-test-transparent-parent-renders 0)
          (let ((old-range (symbol-function 'ebox-candidate-replace-range-ref))
                (old-host (symbol-function 'ebox-candidate-replace-host-ref))
                (old-commit (symbol-function 'ebox-commit)))
            (cl-letf (((symbol-function 'ebox-candidate-replace-range-ref)
                       (lambda (&rest args)
                         (cl-incf range-replaces) (apply old-range args)))
                      ((symbol-function 'ebox-candidate-replace-host-ref)
                       (lambda (&rest args)
                         (cl-incf host-replaces) (apply old-host args)))
                      ((symbol-function 'ebox-commit)
                       (lambda (&rest args)
                         (cl-incf commits) (apply old-commit args))))
              (setf (etaf-value etaf-test-transparent-source)
                    '((a . "A") (b . "B")))))
          (should (= 1 etaf-test-transparent-renders))
          (should (zerop etaf-test-transparent-parent-renders))
          (should (= 1 range-replaces))
          (should (zerop host-replaces))
          (should (= 1 commits))
          (should (string-match-p "A" (etaf-test--buffer-text buffer-name)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-current-generation runtime))
                 (component
                  (cl-loop for id from 1 to (etaf-runtime-next-semantic-id runtime)
                           for node = (etaf--pvec-get
                                       (etaf-generation-semantic-nodes generation)
                                       id)
                           when (and (etaf--semantic-component-p node)
                                     (equal (car (etaf--semantic-component-identity node))
                                            'etaf-test-transparent-owner))
                           return node))
                 (range (etaf--pvec-get
                         (etaf-generation-semantic-nodes generation)
                         (etaf--semantic-component-output-range-id component))))
            (should (eq 'transparent
                        (etaf--semantic-component-publication-kind component)))
            (should (eq 'component-output (etaf--semantic-range-kind range)))
            (should-not (etaf--semantic-component-artifact-key component))
            (should (etaf--semantic-range-range-ref range))
            (should
             (ebox-canonical-input-p
              (gethash (etaf--semantic-range-artifact-key range)
                       (etaf-runtime-range-artifact-registry runtime))))
            (let ((committed generation)
                  (before (etaf-test--buffer-text buffer-name)))
              (cl-letf (((symbol-function 'accept-change-group)
                         (lambda (&rest _)
                           (error "injected transparent final accept failure"))))
                (should-error
                 (setf (etaf-value etaf-test-transparent-source)
                       '((c . "C")))
                 :type 'error))
              (should (eq committed (etaf-runtime-current-generation runtime)))
              (should (equal before (etaf-test--buffer-text buffer-name))))
            (etaf-runtime-flush runtime)
            (should (string-match-p "C"
                                    (etaf-test--buffer-text buffer-name)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-transparent-chain-shares-nearest-backend-anchor ()
  "Update an inner transparent Component without rendering its ancestors."
  (let ((buffer-name " *etaf-transparent-chain-test*")
        (etaf-test-transparent-source (etaf-ref '((a . "A"))))
        (range-replaces 0) (commits 0))
    (setq etaf-test-transparent-inner-renders 0
          etaf-test-transparent-outer-renders 0)
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf-view (etaf-test-transparent-chain-parent)))
          (setq etaf-test-transparent-inner-renders 0
                etaf-test-transparent-outer-renders 0)
          (let ((old-range (symbol-function 'ebox-candidate-replace-range-ref))
                (old-commit (symbol-function 'ebox-commit)))
            (cl-letf (((symbol-function 'ebox-candidate-replace-range-ref)
                       (lambda (&rest args)
                         (cl-incf range-replaces) (apply old-range args)))
                      ((symbol-function 'ebox-commit)
                       (lambda (&rest args)
                         (cl-incf commits) (apply old-commit args))))
              (setf (etaf-value etaf-test-transparent-source)
                    '((a . "B")))))
          (should (= 1 etaf-test-transparent-inner-renders))
          (should (zerop etaf-test-transparent-outer-renders))
          (should (= 1 range-replaces))
          (should (= 1 commits))
          (should (string-match-p "B" (etaf-test--buffer-text buffer-name))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-parent-rerender-rebuilds-invalidated-artifact ()
  "Rebuild a committed parent anchor after a descendant-only publication."
  (let ((buffer-name " *etaf-ancestor-artifact-test*")
        (etaf-test-ancestor-parent-source (etaf-ref "light"))
        (etaf-test-ancestor-child-source (etaf-ref nil)))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf-view (etaf-test-ancestor-artifact-parent)))
          (setf (etaf-value etaf-test-ancestor-child-source) t)
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-current-generation runtime))
                 (parent
                  (etaf--generation-semantic
                   generation '(etaf-test-ancestor-artifact-parent (root)))))
            (should (etaf--semantic-component-p parent))
            (should-not (etaf--semantic-component-artifact-key parent))
            (setf (etaf-value etaf-test-ancestor-parent-source) "dark")
            (should (equal
                     (plist-get
                      (etaf-runtime-host-props-for
                       runtime '(etaf-host (root :view)))
                      :bgcolor)
                     "dark"))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

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

(ert-deftest etaf-generation-owns-handler-ref-and-focus-contributions ()
  "Dispatch only committed handlers and remove stale focus membership."
  (let* ((buffer-name " *etaf-generation-handler-test*")
         (mode (etaf-ref 'old))
         (old-calls 0) (new-calls 0) (stable-calls 0)
         (view
          (lambda ()
            (etaf--view-call
             'column nil
             (list
              (pcase (etaf-value mode)
                ('old (etaf--view-call
                       'text
                       (list :ref 'target :tab-index 0
                             :on-press (lambda () (cl-incf old-calls)))
                       (list "old")))
                ('new (etaf--view-call
                       'text
                       (list :ref 'target :tab-index 0
                             :on-press (lambda () (cl-incf new-calls)))
                       (list "new")))
                (_ (etaf--view-call 'text (list :ref 'target)
                                    (list "removed"))))
              (etaf--view-call
               'text (list :ref 'stable :tab-index 1
                           :on-press (lambda () (cl-incf stable-calls)))
               (list "stable")))))))
    (unwind-protect
        (progn
          (etaf-mount buffer-name view)
          (let ((runtime (etaf-runtime-for-buffer buffer-name))
                (old-commit (symbol-function 'ebox-commit)))
            (cl-letf (((symbol-function 'ebox-commit)
                       (lambda (&rest args)
                         (etaf-dispatch-event runtime 'target 'press)
                         (apply old-commit args))))
              (setf (etaf-value mode) 'new))
            (should (= 1 old-calls))
            (should (zerop new-calls))
            (etaf-dispatch-event runtime 'target 'press)
            (should (= 1 new-calls))
            (etaf-dispatch-event runtime 'stable 'press)
            (should (= 1 stable-calls))
            (etaf-focus runtime 'target)
            (should (eq 'target (etaf-focused-host-ref runtime)))
            (setf (etaf-value mode) 'removed)
            (should-error (etaf-dispatch-event runtime 'target 'press)
                          :type 'etaf-event-error)
            (should-not (etaf-focused-host-ref runtime))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-candidate-reintroduced-host-cancels-contribution-removal ()
  "Cancel a Host tombstone when the same stable ref is re-registered."
  (let ((runtime
         (etaf--runtime-create
          :candidate-removed-host-refs '(stable other)
          :candidate-host-props (make-hash-table :test #'equal)
          :candidate-handlers (make-hash-table :test #'equal)
          :candidate-semantic-nodes (make-hash-table :test #'equal)
          :candidate-graph-nodes (make-hash-table :test #'eql)
          :candidate-behaviors (make-hash-table :test #'equal))))
    (etaf--runtime-register-host
     runtime '(:ref stable :on-press ignore) '(test))
    (should (equal '(other)
                   (etaf-runtime-candidate-removed-host-refs runtime)))
    (should (etaf-runtime-handler-for
             (let ((generation
                    (etaf--generation-create
                     :indexes
                     (etaf--runtime-build-contribution-indexes
                      runtime nil t))))
               (setf (etaf-runtime-current-generation runtime) generation)
               runtime)
             'stable))))

(ert-deftest etaf-contribution-index-compaction-preserves-effective-values ()
  "Flatten contribution deltas without changing values or tombstones."
  (let* ((base
          (etaf--contribution-index-create
           :handlers '((a . ((press . old))) (b . ((press . removed))))
           :host-props '((a :role button) (b :role button))
           :contexts '((10 . old-context) (20 . stable-context))
           :themes '((10 . old-theme) (20 . stable-theme))
           :behaviors '((10 . old-behavior) (20 . stable-behavior))
           :context-consumers '(((10 . theme) 1) ((20 . theme) 2))
           :lifecycle '((old . updated))))
         (delta
          (etaf--contribution-index-create
           :base base :depth 2
           :handlers '((a . ((press . new))))
           :host-props '((a :role checkbox))
           :contexts '((10 . new-context))
           :themes '((10 . new-theme))
           :behaviors '((10 . new-behavior))
           :context-consumers '(((10 . theme) 3))
           :lifecycle '((new . updated))
           :host-removals '(b)
           :semantic-removals '(30)))
         (compacted (etaf--contribution-index-compact delta)))
    (should-not (etaf--contribution-index-base compacted))
    (should (= 1 (etaf--contribution-index-depth compacted)))
    (dolist (slot '(handlers host-props contexts themes behaviors
                            context-consumers lifecycle))
      (should (equal (etaf--contribution-index-entries delta slot)
                     (etaf--contribution-index-entries compacted slot))))
    (let ((generation (etaf--generation-create :indexes compacted)))
      (should (equal '((press . new))
                     (etaf--generation-index-lookup generation 'handlers 'a)))
      (should-not
       (etaf--generation-index-lookup generation 'handlers 'b)))))

(ert-deftest etaf-contribution-index-depth-stays-bounded ()
  "Periodically compact a long sequence of local contribution generations."
  (let ((etaf-generation-index-max-depth 4)
        (runtime
         (etaf--runtime-create
          :candidate-handlers (make-hash-table :test #'equal)
          :candidate-host-props (make-hash-table :test #'equal)
          :candidate-semantic-nodes (make-hash-table :test #'equal)
          :candidate-graph-nodes (make-hash-table :test #'eql)
          :candidate-behaviors (make-hash-table :test #'equal)
          :candidate-behavior-resource-keys (make-hash-table :test #'equal)))
        generation)
    (dotimes (index 20)
      (setq generation
            (etaf--generation-create
             :generation-id (1+ index)
             :indexes
             (etaf--runtime-build-contribution-indexes
              runtime generation nil)))
      (should (<= (etaf--contribution-index-depth
                   (etaf-generation-indexes generation))
                  etaf-generation-index-max-depth)))))

(ert-deftest etaf-context-edge-belongs-to-direct-range-effect ()
  "Invalidate the injecting Range effect, not its lexical Component effect."
  (let ((buffer-name " *etaf-context-range-owner-test*")
        (etaf-test-context-provider-source (etaf-ref "A")))
    (setq etaf-test-context-range-evals 0)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view (etaf-test-generation-context-range-provider)))
          (setq etaf-test-context-range-evals 0)
          (setf (etaf-value etaf-test-context-provider-source) "B")
          (should (= 1 etaf-test-context-range-evals))
          (should (string-match-p "B" (etaf-test--buffer-text buffer-name)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-current-generation runtime))
                 (edges (etaf--generation-index-entries
                         generation 'context-consumers)))
            (should (= 1 (length (cdar edges))))
            (should (eq 'range
                        (etaf--generation-effect-kind
                         (etaf--generation-effect generation
                                                  (cadar edges)))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-context-edge-belongs-to-slot-range-effect ()
  "Invalidate the authored slot Range without rendering its consumer."
  (let ((buffer-name " *etaf-context-slot-owner-test*")
        (etaf-test-context-provider-source (etaf-ref "A")))
    (setq etaf-test-slot-range-evals 0
          etaf-test-slot-consumer-renders 0
          etaf-test-context-provider-renders 0)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view (etaf-test-generation-context-slot-provider)))
          (setq etaf-test-slot-range-evals 0
                etaf-test-slot-consumer-renders 0
                etaf-test-context-provider-renders 0)
          (setf (etaf-value etaf-test-context-provider-source) "B")
          (should (= 1 etaf-test-context-provider-renders))
          (should (= 1 etaf-test-slot-range-evals))
          (should (zerop etaf-test-slot-consumer-renders))
          (should (string-match-p "B" (etaf-test--buffer-text buffer-name)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (generation (etaf-runtime-current-generation runtime))
                 (effect-id (cadar (etaf--generation-index-entries
                                    generation 'context-consumers))))
            (should (eq 'slot
                        (etaf--generation-effect-kind
                         (etaf--generation-effect generation effect-id))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest etaf-context-cycle-validator-allows-long-chain-and-rejects-cycle ()
  "Settle a long Context graph and reject one deterministic cross-edge cycle."
  (let ((effect-map nil) chain)
    (dotimes (index 40)
      (let ((effect-id (1+ index))
            (consumer-id (+ 2 index)))
        (setq effect-map
              (etaf--pvec-put
               effect-map effect-id
               (etaf--generation-effect-create
                :effect-id effect-id :kind 'component-render
                :semantic-id consumer-id :deps nil)))
        (push (cons (cons (1+ index) 'chain-key) (list effect-id)) chain)))
    (let ((generation
           (etaf--generation-create
            :effect-map effect-map
            :indexes (etaf--contribution-index-create
                      :context-consumers (nreverse chain)))))
      (should (eq generation
                  (etaf--generation-validate-context-acyclic generation))))
    (let* ((cycle-effects
            (etaf--pvec-put
             (etaf--pvec-put
              nil 1 (etaf--generation-effect-create
                     :effect-id 1 :kind 'component-render
                     :semantic-id 2 :deps nil))
             2 (etaf--generation-effect-create
                :effect-id 2 :kind 'component-render
                :semantic-id 1 :deps nil)))
           (cycle
            (etaf--generation-create
             :effect-map cycle-effects
             :indexes
             (etaf--contribution-index-create
              :context-consumers
              (list (cons (cons 1 'left) (list 1))
                    (cons (cons 2 'right) (list 2)))))))
      (should-error (etaf--generation-validate-context-acyclic cycle)
                    :type 'etaf-context-error))))

(ert-deftest etaf-runtime-inline-styled-output-survives-pure-root-rebuild ()
  "Keep current propertized inline output without replaying application thunks."
  (let* ((buffer-name " *etaf-inline-styled-rebuild-test*")
         (etaf-test-inline-styled-source (etaf-ref "A"))
         (etaf-test-inline-styled-evals 0)
         (etaf-test-inline-host-prop-calls 0)
         (root-source (etaf-ref 0))
         (view (lambda ()
                 (etaf-value root-source)
                 (etaf--view-call 'etaf-test-inline-styled-owner
                                  (list :key 'styled) nil))))
    (unwind-protect
        (progn
          (etaf-mount buffer-name view)
          (should (= 1 etaf-test-inline-host-prop-calls))
          (setq etaf-test-inline-styled-evals 0)
          (setf (etaf-value etaf-test-inline-styled-source) "B")
          (should (= 1 etaf-test-inline-styled-evals))
          (setq etaf-test-inline-styled-evals 0)
          (setf (etaf-value root-source) 1)
          (should (zerop etaf-test-inline-styled-evals))
          (should (= 1 etaf-test-inline-host-prop-calls))
          (with-current-buffer buffer-name
            (let ((text (buffer-string)))
              (should (equal "PB" (substring-no-properties text)))
              (should (get-text-property 1 'face text)))))
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

(ert-deftest etaf-event-dispatch-nested-batches-once ()
  "Batch nested public dispatches into one final publication."
  (let ((buffer-name " *etaf-event-nested-test*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-test-event-batch-nested)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (before (etaf-runtime-generation runtime)))
            (etaf-dispatch-event runtime 'event-batch-nested-outer 'press)
            (should (equal "Outer Inner nested"
                           (etaf-test--buffer-text buffer-name)))
            (should (= 1 (- (etaf-runtime-generation runtime) before)))))
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

(ert-deftest etaf-event-dispatch-batches-computed-theme ()
  "Batch a callback that invalidates a computed Theme value."
  (let ((buffer-name " *etaf-event-theme-batch-test*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-view (etaf-test-event-batch-theme)))
          (should (equal "Theme theme=light"
                         (etaf-test--buffer-text buffer-name)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (before (etaf-runtime-generation runtime)))
            (etaf-dispatch-event runtime 'event-batch-theme-toggle 'press)
            (should (equal "Theme theme=dark"
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

(ert-deftest etaf-mounted-input-focus-order-and-lifecycle ()
  "Order equal tab stops by live position and toggle input with mount life."
  (let ((buffer-name " *etaf-input-lifecycle-test*"))
    (setq etaf-test-event-count 0)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (column
             (text :ref 'first :tab-index 0
                   :on-press (lambda () (cl-incf etaf-test-event-count))
                   "First")
             (text :ref 'second :tab-index 0
                   :on-press (lambda () (cl-incf etaf-test-event-count))
                   "Second"))))
          (should (etaf-runtime-for-buffer buffer-name))
          (with-current-buffer buffer-name
            (should etaf-input-mode)
            (should (eq #'etaf-focus-next (key-binding (kbd "TAB"))))
            (should (eq #'etaf-activate (key-binding (kbd "RET"))))
            (should (eq #'etaf-focus-previous
                        (key-binding (kbd "<backtab>"))))
            (switch-to-buffer buffer-name)
            (execute-kbd-macro (kbd "TAB"))
            (execute-kbd-macro (kbd "RET")))
          (let ((runtime (etaf-runtime-for-buffer buffer-name)))
            (should (eq 'first (etaf-focused-host-ref runtime)))
            (should (= 1 etaf-test-event-count))
            (with-current-buffer buffer-name
              (should (= (point) (etaf-host-ref-position runtime 'first))))
            (should (eq 'second (etaf-focus-next runtime)))
            (with-current-buffer buffer-name
              (should (= (point) (etaf-host-ref-position runtime 'second))))
            (let ((window (get-buffer-window buffer-name t)))
              (should (windowp window))
              (etaf-activate-mouse
               (list 'mouse-1
                     (list window
                           (etaf-host-ref-position runtime 'second)))))
            (should (= 2 etaf-test-event-count))
            (etaf-unmount runtime))
          (with-current-buffer buffer-name
            (should-not etaf-input-mode)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-activation-skips-disabled-and-callbackless-hosts ()
  "Do not activate a disabled Host or a Host without a press callback."
  (let ((buffer-name " *etaf-activation-filter-test*"))
    (setq etaf-test-event-count 0)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (column
             (text :ref 'disabled :tab-index 0 :disabled t
                   :on-press (lambda () (cl-incf etaf-test-event-count))
                   "Disabled")
             (text :ref 'passive :tab-index 1 "Passive"))))
          (let ((runtime (etaf-runtime-for-buffer buffer-name)))
            (with-current-buffer buffer-name
              (goto-char (etaf-host-ref-position runtime 'disabled))
              (should-error (etaf-activate runtime) :type 'user-error)
              (goto-char (etaf-host-ref-position runtime 'passive))
              (should-error (etaf-activate runtime) :type 'user-error)
              (let ((window (get-buffer-window buffer-name t)))
                (etaf-activate-mouse
                 (list 'mouse-1
                       (list window
                             (etaf-host-ref-position runtime 'passive))))))
            (should (= 0 etaf-test-event-count))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
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
            (column :width '(viewport) :height '(viewport-height)
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

(ert-deftest etaf-runtime-publishes-handle-only-ebox-sources ()
  "Renderer should publish one source index and handle-only Ebox nodes."
  (let ((buffer-name " *etaf-source-index-boundary*"))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (column :id "app" :class "shell"
             (box :key 'row :id "row" :class "entry" "A"))))
          (let* ((buffer (get-buffer buffer-name))
                 (state (ebox--buffer-render-state buffer))
                 (source-index (plist-get state :source-index))
                 (match (car (ebox-selector-query-buffer buffer "#row")))
                 (node (plist-get match :node))
                 (record
                  (ebox-source-index-record
                   source-index (ebox-node-source-handle node))))
            (should (ebox-source-index-p source-index))
            (should (equal '("entry")
                           (ebox-source-record-classes record)))
            (should (eq 'row (ebox-source-record-key record)))
            (maphash
             (lambda (_node-id candidate-node)
               (when (ebox-node-kind candidate-node)
                 (should
                  (ebox-source-index-record
                   source-index
                   (ebox-node-source-handle candidate-node)))
                 (dolist (field
                          '(:key :id :class :host-ref
                            :ebox-style-declarations))
                   (should-not (plist-member candidate-node field)))))
             (plist-get state :node-table))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

;;; etaf-tests.el ends here
