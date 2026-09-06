;;; etaf-event-forwarding-tests.el --- Composable Host interaction tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Exercise fallthrough, committed disabled state, and interaction boundaries.

;;; Code:

(require 'ert)
(require 'etaf)

(defvar etaf-forward-test--trace nil)
(defvar etaf-forward-test--inner-use nil)
(defvar etaf-forward-test--middle-use nil)
(defvar etaf-forward-test--inner-disabled nil)

(defun etaf-forward-test--record (item)
  "Append ITEM to the current interaction trace."
  (setq etaf-forward-test--trace (append etaf-forward-test--trace (list item))))

(defun etaf-forward-test--dispose (buffer)
  "Unmount and kill test BUFFER."
  (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
    (etaf-unmount runtime))
  (when-let* ((live (get-buffer buffer))) (kill-buffer live)))

(etaf-define-component etaf-forward-test-leaf (&key on-press use disabled ref)
  :view (text :ref ref :role 'button :tab-index 0 :disabled disabled
              :on-press on-press :use use "Press"))

(etaf-define-component etaf-forward-test-middle ()
  :view (etaf-forward-test-leaf
         :ref 'internal
         :disabled (if (etaf-ref-p etaf-forward-test--inner-disabled)
                       (etaf-value etaf-forward-test--inner-disabled)
                     etaf-forward-test--inner-disabled)
         :use etaf-forward-test--inner-use
         :on-press (lambda () (etaf-forward-test--record 'inner))))

(etaf-define-component etaf-forward-test-outer ()
  :view (etaf-forward-test-middle
         :use etaf-forward-test--middle-use
         :on-press (lambda () (etaf-forward-test--record 'middle))))

(etaf-define-component etaf-forward-test-business (&key on-change)
  :view (text :role 'checkbox :aria-checked nil
              :on-press (let ((change on-change))
                          (lambda ()
                            (etaf-forward-test--record 'business)
                            (funcall change t)))
              "Toggle"))

(etaf-define-component etaf-forward-test-layout (&key width classes use renders)
  :render
  (progn
    (cl-incf (aref renders 0))
    (if (eq use 'absent)
        (etaf-view (box :ref 'layout :width (etaf-value width)
                        :class (etaf-value classes) (text "Text")))
      (etaf-view (box :ref 'layout :width (etaf-value width)
                      :class (etaf-value classes) :use use (text "Text"))))))

(ert-deftest etaf-forward-behavior-keeps-host-property-dependencies-local ()
  "Omitted, empty, and active `:use' preserve the same Host update boundary."
  (let ((installs 0) (cleanups 0) installed-props)
    (dolist (use (list 'absent nil (etaf-focusable)
                       (etaf-behavior-create
                        'layout-probe
                        :install
                        (lambda ()
                          (cl-incf installs)
                          (setq installed-props
                                (etaf-behavior-context-host-props
                                 (etaf-current-behavior-context)))
                          (lambda () (cl-incf cleanups))))))
      (let ((buffer (generate-new-buffer " *etaf-behavior-layout*"))
            (width (etaf-ref 10))
            (classes (etaf-ref '(first)))
            (renders (vector 0)))
        (unwind-protect
            (progn
              (etaf-mount
               buffer (etaf-node 'etaf-forward-test-layout
                                  (list :width width :classes classes
                                        :use use :renders renders) nil))
              (let ((runtime (etaf-runtime-for-buffer buffer)))
                (should (equal renders [1]))
                (setf (etaf-value width) 12)
                (should (= 12 (plist-get (etaf-runtime-host-props-for runtime 'layout)
                                        :width)))
                (should (equal renders [1]))
                (setf (etaf-value classes) '(second))
                (should (equal '(second)
                               (plist-get (etaf-runtime-host-props-for runtime 'layout)
                                          :class)))
                (should (equal renders [1]))
                (let ((generation (etaf-runtime-current-generation runtime)))
                  (cl-letf (((symbol-function 'etaf--runtime-swap-generation)
                             (lambda (&rest _) (error "Reject layout candidate"))))
                    (should-error (setf (etaf-value width) 14)))
                  (should (eq generation (etaf-runtime-current-generation runtime)))
                  (should (= 12 (plist-get (etaf-runtime-host-props-for runtime 'layout)
                                          :width)))
                  (should (equal renders [1])))))
          (etaf-forward-test--dispose buffer))))
    (should (= installs 1))
    (should (= cleanups 1))
    (should (= 10 (plist-get installed-props :width)))
    (should (equal '(first) (plist-get installed-props :class)))
    (should (eq 'layout (plist-get installed-props :ref)))))

(ert-deftest etaf-forward-declared-events-and-use-compose-once ()
  "Consume declared callback/use props once through two root wrappers."
  (let ((buffer " *etaf-forward-events*")
        (etaf-forward-test--trace nil)
        (etaf-forward-test--inner-use
         (etaf-behavior-create
          'inner :on-press (lambda () (etaf-forward-test--record 'behavior-inner))))
        (etaf-forward-test--middle-use
         (etaf-behavior-create
          'middle :on-press (lambda () (etaf-forward-test--record 'behavior-middle)))))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-forward-test-outer
             :ref 'target
             :on-press (lambda () (etaf-forward-test--record 'outer))
             :use (etaf-behavior-create
                   'outer :on-press
                   (lambda () (etaf-forward-test--record 'behavior-outer))))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-dispatch-event runtime 'target 'press)
            (should (equal etaf-forward-test--trace
                           '(inner middle outer behavior-inner
                                   behavior-middle behavior-outer)))
            (should-not (etaf-runtime-handler-for runtime 'internal))))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-disabled-or-recomputes-and-guards-public-input ()
  "Outer nil never enables an internally disabled Host; later inputs recover."
  (let* ((buffer " *etaf-forward-disabled*")
        (outer-disabled (etaf-ref nil))
        (inner-disabled (etaf-ref t))
        (etaf-forward-test--inner-disabled inner-disabled)
        (etaf-forward-test--trace nil))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (lambda ()
             (etaf-view (etaf-forward-test-middle
                         :ref 'target :disabled (etaf-value outer-disabled)))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (should (plist-get (etaf-runtime-host-props-for runtime 'target)
                               :disabled))
            (should-error (etaf-dispatch-event runtime 'target 'press)
                          :type 'etaf-event-error)
            (should-error (etaf-focus runtime 'target) :type 'etaf-event-error)
            (setf (etaf-value inner-disabled) nil)
            (etaf-dispatch-event runtime 'target 'press)
            (should (equal etaf-forward-test--trace '(inner)))
            (setf (etaf-value outer-disabled) t)
            (should-error (etaf-dispatch-event runtime 'target 'press)
                          :type 'etaf-event-error)
            (setf (etaf-value outer-disabled) nil)
            (etaf-dispatch-event runtime 'target 'press)
            (should (equal etaf-forward-test--trace '(inner inner)))))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-host-attribute-ownership ()
  "Presentation defaults and caller labels coexist with owned role/state."
  (let* ((root '(:color "red" :class "base" :role button :aria-checked nil
                :tab-index 0 :aria-label "Default" :ref fallback))
         (merged (etaf--merge-host-attrs
                  root '(:color nil :class (caller base) :tab-index 2
                         :aria-label "Caller" :ref target) 'text 'example)))
    (should (equal "red" (plist-get merged :color)))
    (should (equal '("base" "caller") (plist-get merged :class)))
    (should (= 2 (plist-get merged :tab-index)))
    (should (equal "Caller" (plist-get merged :aria-label)))
    (should (eq 'target (plist-get merged :ref)))
    (should-error (etaf--merge-host-attrs root '(:role navigation) 'text 'example)
                  :type 'etaf-component-call-error)
    (should-error (etaf--merge-host-attrs root '(:aria-checked t) 'text 'example)
                  :type 'etaf-component-call-error)))

(ert-deftest etaf-forward-business-conversion-precedes-subscriptions ()
  "A consumed change prop remains the business conversion for one press."
  (let ((buffer " *etaf-forward-conversion*")
        (etaf-forward-test--trace nil) (value nil))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-forward-test-business
             :ref 'target
             :on-change (lambda (next)
                          (setq value next)
                          (etaf-forward-test--record 'change))
             :on-press (lambda () (etaf-forward-test--record 'outer))
             :use (etaf-behavior-create
                   'observer :on-press
                   (lambda () (etaf-forward-test--record 'behavior))))))
          (etaf-dispatch-event (etaf-runtime-for-buffer buffer) 'target 'press)
          (should value)
          (should (equal etaf-forward-test--trace
                         '(business change outer behavior))))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-wrapper-duplicate-behaviors-fail-before-install ()
  "Do not lose duplicate names when declared use props consume fallthrough."
  (let* ((buffer " *etaf-forward-duplicate-use*")
         (installs 0)
         (behavior (etaf-behavior-create
                    'duplicate :install (lambda () (cl-incf installs) nil)))
         (etaf-forward-test--inner-use behavior))
    (unwind-protect
        (progn
          (should-error
           (etaf-mount buffer (etaf-view (etaf-forward-test-middle :use behavior)))
           :type 'etaf-behavior-error)
          (should (zerop installs)))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-failed-callback-stops-outer-subscriptions ()
  "An inner callback error stops outer subscriptions and Behaviors."
  (let ((buffer " *etaf-forward-callback-failure*")
        (etaf-forward-test--trace nil))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-forward-test-business
             :ref 'target :on-change (lambda (_) (error "change failed"))
             :on-press (lambda () (etaf-forward-test--record 'outer))
             :use (etaf-behavior-create
                   'observer :on-press
                   (lambda () (etaf-forward-test--record 'behavior))))))
          (should-error
           (etaf-dispatch-event (etaf-runtime-for-buffer buffer) 'target 'press))
          (should (equal etaf-forward-test--trace '(business))))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-behavior-final-props-precede-any-installer ()
  "Installers receive final merged semantic props, after validation."
  (let ((buffer " *etaf-forward-behavior-props*") (installs 0) (observed nil))
    (unwind-protect
        (let ((first
               (etaf-behavior-create
                'first :install
                (lambda ()
                  (cl-incf installs)
                  (setq observed
                        (etaf-behavior-context-host-props
                         (etaf-current-behavior-context)))
                  nil))))
          (etaf-mount
           buffer
           (etaf-view
            (text :ref 'target
                  :use (list first
                             (etaf-behavior-create 'label :aria-label "Final"))
                  "Target")))
          (should (= installs 1))
          (should (equal "Final" (plist-get observed :aria-label)))
          (etaf-unmount (etaf-runtime-for-buffer buffer))
          (setq installs 0)
          (should-error
           (etaf-mount
            buffer
            (etaf-view
             (text :ref 'target
                   :use (list first
                              (etaf-behavior-create 'invalid :disabled 'wrong))
                   "Target")))
           :type 'etaf-renderer-error)
          (should (zerop installs)))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-disabled-behavior-never-installs ()
  "Final disabled state, including Behavior defaults, precedes installation."
  (let ((buffer " *etaf-forward-behavior-disabled*") (installs 0))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (text :ref 'target :disabled nil
                  :use (list
                        (etaf-behavior-create
                         'first :install (lambda () (cl-incf installs) nil))
                        (etaf-behavior-create 'disabled :disabled t))
                  "Disabled")))
          (should (zerop installs))
          (should (plist-get (etaf-runtime-host-props-for
                              (etaf-runtime-for-buffer buffer) 'target)
                             :disabled)))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-behavior-disabled-transitions-and-rollback ()
  "Commit disables clean up once; failed disables preserve the old resource."
  (let ((buffer " *etaf-forward-behavior-transition*")
        (mode (etaf-ref 'enabled))
        (installs 0) (cleanups 0))
    (unwind-protect
        (let ((behavior (etaf-behavior-create
                         'resource :install
                         (lambda () (cl-incf installs)
                           (lambda () (cl-incf cleanups))))))
          (etaf-mount
           buffer
           (lambda ()
             (etaf-view
              (column
               (text :ref 'target :use behavior
                     :disabled (not (eq (etaf-value mode) 'enabled)) "Target")
               (text (expr (if (eq (etaf-value mode) 'failed)
                               (error "later sibling failed") "OK")))))))
          (should (= installs 1))
          (should-error (setf (etaf-value mode) 'failed))
          (should (= cleanups 0))
          (should-not (plist-get (etaf-runtime-host-props-for
                                  (etaf-runtime-for-buffer buffer) 'target)
                                 :disabled))
          (setf (etaf-value mode) 'disabled)
          (should (= cleanups 1))
          (setf (etaf-value mode) 'enabled)
          (should (= installs 2))
          (etaf-unmount (etaf-runtime-for-buffer buffer))
          (should (= cleanups 2)))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-failed-enable-disposes-only-candidate-behavior ()
  "A failed enable cleans its new resource while committed Host stays disabled."
  (let ((buffer " *etaf-forward-enable-rollback*")
        (mode (etaf-ref 'disabled)) (installs 0) (cleanups 0))
    (unwind-protect
        (let ((behavior
               (etaf-behavior-create
                'resource :install
                (lambda () (cl-incf installs)
                  (lambda () (cl-incf cleanups))))))
          (etaf-mount
           buffer
           (etaf-view
            (column
             (text :ref 'target :use behavior
                   :disabled (eq (etaf-value mode) 'disabled) "Target")
             (text (expr (if (eq (etaf-value mode) 'failed)
                             (error "later sibling failed") "OK"))))))
          (should (zerop installs))
          (should-error (setf (etaf-value mode) 'failed))
          (should (= installs 1))
          (should (= cleanups 1))
          (should (plist-get (etaf-runtime-host-props-for
                              (etaf-runtime-for-buffer buffer) 'target)
                             :disabled))
          (setf (etaf-value mode) 'enabled)
          (should (= installs 2))
          (etaf-unmount (etaf-runtime-for-buffer buffer))
          (should (= cleanups 2)))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-component-overlay-promotes-behavior-lifetime ()
  "A locally enabled Component owns its installed Behavior through teardown."
  (let ((buffer " *etaf-forward-overlay-behavior*")
        (disabled (etaf-ref t)) (installs 0) (cleanups 0))
    (unwind-protect
        (let ((behavior
               (etaf-behavior-create
                'resource :install
                (lambda () (cl-incf installs)
                  (lambda () (cl-incf cleanups))))))
          ;; Passing a View value keeps dependency ownership on the Component
          ;; input effect, exercising local overlay instead of Root rebuild.
          (etaf-mount buffer
                      (etaf-view (etaf-forward-test-leaf
                                  :ref 'target :use behavior
                                  :disabled (etaf-value disabled))))
          (should (zerop installs))
          (setf (etaf-value disabled) nil)
          (should (= installs 1))
          (should (zerop cleanups))
          (setf (etaf-value disabled) t)
          (should (= cleanups 1))
          (setf (etaf-value disabled) nil)
          (should (= installs 2))
          (etaf-unmount (etaf-runtime-for-buffer buffer))
          (should (= cleanups 2)))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-root-fallback-releases-abandoned-behavior ()
  "A local anchor proof miss releases candidate resources before Root retry."
  (let ((buffer " *etaf-forward-fallback-behavior*")
        (disabled (etaf-ref t)) (installs 0) (cleanups 0)
        (miss-next t))
    (unwind-protect
        (let ((behavior
               (etaf-behavior-create
                'resource :install
                (lambda () (cl-incf installs)
                  (lambda () (cl-incf cleanups))))))
          (etaf-mount
           buffer
           (etaf-view
            (column
             (etaf-forward-test-leaf :ref 'target :use behavior
                                     :disabled (etaf-value disabled))
             ;; Read here to change this structural Range.  A text child's
             ;; deferred Expr correctly owns its own independent update.
             (expr (etaf-node
                    'text nil
                    (list (if (etaf-value disabled) "Disabled" "Enabled")))))))
          (let ((original
                 (symbol-function 'etaf--runtime-range-change-has-backend-anchor-p)))
            (cl-letf (((symbol-function 'etaf--runtime-range-change-has-backend-anchor-p)
                       (lambda (runtime change)
                         (if miss-next
                             (progn (setq miss-next nil) nil)
                           (funcall original runtime change)))))
              (setf (etaf-value disabled) nil)))
          (should-not miss-next)
          (should (= installs 2))
          (should (= cleanups 1))
          (etaf-unmount (etaf-runtime-for-buffer buffer))
          (should (= cleanups 2)))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-removed-component-retires-behavior-immediately ()
  "A removed dynamic child releases its Behavior without waiting for unmount."
  (let ((buffer " *etaf-forward-removed-behavior*")
        (visible (etaf-ref t)) (installs 0) (cleanups 0))
    (unwind-protect
        (let ((behavior
               (etaf-behavior-create
                'resource :install
                (lambda () (cl-incf installs)
                  (lambda () (cl-incf cleanups))))))
          (etaf-mount
           buffer
           (etaf-view (column
                       (etaf-forward-test-leaf :if (etaf-value visible)
                                               :ref 'target :use behavior))))
          (should (= installs 1))
          (setf (etaf-value visible) nil)
          (should (= cleanups 1))
          (should-not
           (etaf--generation-index-entries
            (etaf-runtime-current-generation (etaf-runtime-for-buffer buffer))
            'behaviors))
          (setf (etaf-value visible) t)
          (should (= installs 2))
          (etaf-unmount (etaf-runtime-for-buffer buffer))
          (should (= cleanups 2)))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-component-overlay-removes-use-resources ()
  "Changing or removing use retires obsolete names on a retained Host."
  (let ((buffer " *etaf-forward-overlay-use*")
        (use (etaf-ref nil)) (installs 0) (cleanups 0))
    (unwind-protect
        (let* ((install (lambda () (cl-incf installs)
                          (lambda () (cl-incf cleanups))))
               (first (etaf-behavior-create 'first :install install))
               (second (etaf-behavior-create 'second :install install)))
          (setf (etaf-value use) first)
          (etaf-mount
           buffer (etaf-view (etaf-forward-test-leaf
                             :ref 'target :use (etaf-value use))))
          (should (= installs 1))
          (setf (etaf-value use) second)
          (should (= installs 2))
          (should (= cleanups 1))
          (setf (etaf-value use) nil)
          (should (= cleanups 2))
          (etaf-unmount (etaf-runtime-for-buffer buffer))
          (should (= cleanups 2)))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-keyed-host-behaviors-follow-owner-through-reorder ()
  "Keyed Host resources follow semantic owners through reorder and removal."
  (let ((buffer " *etaf-forward-keyed-behavior*") active events)
    (unwind-protect
        (let* ((behavior
                (etaf-behavior-create
                 'resource :install
                 (lambda ()
                   (let ((ref (plist-get
                               (etaf-behavior-context-host-props
                                (etaf-current-behavior-context)) :ref)))
                     (push ref active)
                     (push (list 'install ref) events)
                     (lambda ()
                       (setq active (delq ref active))
                       (push (list 'cleanup ref) events))))))
               (a (etaf-node 'box (list :key 'a :ref 'a :use behavior) '("A")))
               (b (etaf-node 'box (list :key 'b :ref 'b :use behavior) '("B")))
               (items (etaf-ref (list a b))))
          (etaf-mount buffer (etaf-view (column (expr (etaf-value items)))))
          (setf (etaf-value items) (list b a))
          (should (equal events '((install b) (install a))))
          (setf (etaf-value items) (list b))
          (should (equal active '(b)))
          (should (equal events '((cleanup a) (install b) (install a))))
          (etaf-unmount (etaf-runtime-for-buffer buffer))
          (should-not active)
          (should (= 1 (cl-count '(cleanup a) events :test #'equal)))
          (should (= 1 (cl-count '(cleanup b) events :test #'equal))))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-keyed-behavior-failure-retains-committed-owners ()
  "Failed reorder/removal keeps committed resources and cleans only new ones."
  (let ((buffer " *etaf-forward-keyed-behavior-rollback*") active events)
    (unwind-protect
        (let* ((behavior
                (etaf-behavior-create
                 'resource :install
                 (lambda ()
                   (let ((ref (plist-get
                               (etaf-behavior-context-host-props
                                (etaf-current-behavior-context)) :ref)))
                     (push ref active)
                     (push (list 'install ref) events)
                     (lambda ()
                       (setq active (delq ref active))
                       (push (list 'cleanup ref) events))))))
               (a (etaf-node 'box (list :key 'a :ref 'a :use behavior) '("A")))
               (b (etaf-node 'box (list :key 'b :ref 'b :use behavior) '("B")))
               (c (etaf-node 'box (list :key 'c :ref 'c :use behavior) '("C")))
               (mode (etaf-ref 'initial)))
          (etaf-mount
           buffer
           (etaf-view
            (column
             (expr (pcase (etaf-value mode)
                     ('initial (list a b))
                     ('failed (list b c))
                     (_ (list b))))
             (text (expr (if (eq (etaf-value mode) 'failed)
                             (error "later sibling failed") "OK"))))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (generation (etaf-runtime-current-generation runtime)))
            (should-error (setf (etaf-value mode) 'failed))
            (should (eq generation (etaf-runtime-current-generation runtime)))
            (should (equal active '(b a)))
            (should (equal events
                           '((cleanup c) (install c) (install b) (install a))))
            (setf (etaf-value mode) 'removed)
            (should (equal active '(b)))
            (should (equal (car events) '(cleanup a)))
            (etaf-unmount runtime)
            (should-not active)
            (dolist (ref '(a b c))
              (should (= 1 (cl-count (list 'install ref) events :test #'equal)))
              (should (= 1 (cl-count (list 'cleanup ref) events :test #'equal))))))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-behavior-installer-receives-effective-host-ref ()
  "An installer receives the effective address of an automatically referenced Host."
  (let ((buffer " *etaf-forward-behavior-generated-ref*") installed-ref)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (text :role 'button :on-press #'ignore
                  :use (etaf-behavior-create
                        'resource :install
                        (lambda ()
                          (setq installed-ref
                                (plist-get
                                 (etaf-behavior-context-host-props
                                  (etaf-current-behavior-context)) :ref))
                          nil))
                  "Control")))
          (should installed-ref)
          (should (etaf-runtime-handler-for
                   (etaf-runtime-for-buffer buffer) installed-ref)))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-behavior-address-change-reinstalls-after-commit ()
  "A retained Host changing its ref replaces the resource bound to that address."
  (let ((buffer " *etaf-forward-behavior-ref-change*")
        (ref (etaf-ref 'a)) active events)
    (unwind-protect
        (let ((behavior
               (etaf-behavior-create
                'resource :install
                (lambda ()
                  (let ((address (plist-get
                                  (etaf-behavior-context-host-props
                                   (etaf-current-behavior-context)) :ref)))
                    (push address active)
                    (push (list 'install address) events)
                    (lambda ()
                      (setq active (delq address active))
                      (push (list 'cleanup address) events)))))))
          (etaf-mount
           buffer
           (etaf-view (box :key 'stable :ref (etaf-value ref) :use behavior "Host")))
          (setf (etaf-value ref) 'b)
          (should (equal active '(b)))
          (should (equal events '((cleanup a) (install b) (install a))))
          (etaf-unmount (etaf-runtime-for-buffer buffer))
          (should-not active)
          (should (equal (car events) '(cleanup b))))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-carried-component-keeps-behavior-resource ()
  "A Root update carrying an unchanged Component retains its Host resource."
  (let ((buffer " *etaf-forward-carried-behavior*")
        (version (etaf-ref 0)) (installs 0) (cleanups 0))
    (unwind-protect
        (let ((behavior
               (etaf-behavior-create
                'resource :install
                (lambda () (cl-incf installs)
                  (lambda () (cl-incf cleanups))))))
          (etaf-mount
           buffer
           (lambda ()
             (etaf-value version)
             (etaf-view
              (column
               (etaf-forward-test-leaf :ref 'target :use behavior)))))
          (should (= installs 1))
          (setf (etaf-value version) 1)
          (should (= installs 1))
          (should (zerop cleanups))
          (etaf-unmount (etaf-runtime-for-buffer buffer))
          (should (= cleanups 1)))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-callback-snapshot-changes-only-after-commit ()
  "Composed subscriptions preserve committed scalar props after render fails."
  (let ((buffer " *etaf-forward-callback-commit*")
        (version (etaf-ref 'a)) (seen nil)
        (etaf-forward-test--trace nil))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (column
             (etaf-forward-test-middle
              :ref 'target
              :on-press (let ((snapshot (etaf-value version)))
                          (lambda () (push snapshot seen))))
             (text (expr (if (eq (etaf-value version) 'failed)
                             (error "later sibling failed") "OK"))))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-dispatch-event runtime 'target 'press)
            (should-error (setf (etaf-value version) 'failed))
            (etaf-dispatch-event runtime 'target 'press)
            (setf (etaf-value version) 'b)
            (etaf-dispatch-event runtime 'target 'press)
            (should (equal seen '(b a a)))
            (should (equal etaf-forward-test--trace '(inner inner inner)))))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-child-boundary-blocks-parent-activation ()
  "A disabled or callbackless child owns its hit area, including equal bounds."
  (let ((buffer " *etaf-forward-hit-boundary*") (trace nil))
    (unwind-protect
        (dolist (child-props '((:disabled t :on-press ignore) nil))
          (etaf-mount
           buffer
           (lambda ()
             (etaf-node
              'box (list :ref 'aaa-parent :role 'row :tab-index 0
                         :on-press (lambda () (push 'parent trace)))
              (list (etaf-node
                     'text (append '(:ref zzz-child :role button) child-props)
                     '("Child"))))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (position (etaf-host-ref-position runtime 'zzz-child)))
            (should (equal (etaf-host-ref-bounds runtime 'aaa-parent)
                           (etaf-host-ref-bounds runtime 'zzz-child)))
            (should-error (etaf--activation-at-position runtime position)
                          :type 'user-error)
            (should-not trace)
            (etaf-focus runtime 'aaa-parent)
            (etaf-activate runtime)
            (should (equal trace '(parent)))
            (setq trace nil)
            (etaf-unmount runtime)))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-child-wins-and-ordinary-text-belongs-to-parent ()
  "Semantic descendants beat equal bounds; passive text keeps row activation."
  (let ((buffer " *etaf-forward-hit-order*") (trace nil))
    (unwind-protect
        (dolist (interactive '(t nil))
          (etaf-mount
           buffer
           (lambda ()
             (etaf-node
              'box (list :ref 'aaa-parent
                         :on-press (lambda () (push 'parent trace)))
              (list (etaf-node
                     'text (append '(:ref zzz-child)
                                   (when interactive
                                     (list :role 'button :on-press
                                           (lambda () (push 'child trace)))))
                     '("Child"))))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf--activation-at-position
             runtime (etaf-host-ref-position runtime 'zzz-child))
            (should (equal trace (if interactive '(child) '(parent))))
            (setq trace nil)
            (etaf-unmount runtime)))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-focused-control-follows-changing-layout ()
  "Repeated keyboard activation follows a retained control after width changes."
  (let ((buffer " *etaf-forward-focus-layout*") (page (etaf-ref 9)))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (row
             (text (expr (format "Page %s" (etaf-value page))))
             (text :ref 'next :role 'button :tab-index 0
                   :on-press (lambda () (cl-incf (etaf-value page))) "Next"))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-focus runtime 'next)
            (etaf-activate runtime)
            (should (= (etaf-value page) 10))
            (should (eq (etaf-focused-host-ref runtime) 'next))
            (with-current-buffer buffer
              (should (= (point) (etaf-host-ref-position runtime 'next))))
            (etaf-activate runtime)
            (should (= (etaf-value page) 11))))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-layout-update-respects-manually-moved-point ()
  "A layout commit must not pull point back after the user leaves a control."
  (let ((buffer " *etaf-forward-focus-manual*") (page (etaf-ref 9)))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (row
             (text (expr (format "Page %s" (etaf-value page))))
             (text :ref 'next :role 'button :tab-index 0 "Next"))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-focus runtime 'next)
            (with-current-buffer buffer (goto-char (point-min)))
            (setf (etaf-value page) 10)
            (with-current-buffer buffer
              (should (= (point) (point-min)))
              (should-not (= (point) (etaf-host-ref-position runtime 'next))))))
      (etaf-forward-test--dispose buffer))))

(ert-deftest etaf-forward-focused-point-survives-failed-publication ()
  "A failed candidate retains the old focus and point; the next commit follows."
  (let ((buffer " *etaf-forward-focus-rollback*") (page (etaf-ref 9)))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (row
             (text (expr (format "Page %s" (etaf-value page))))
             (text :ref 'next :role 'button :tab-index 0 "Next")
             (text (expr (if (= (etaf-value page) 10)
                             (error "later rendering failed") "OK"))))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (generation (etaf-runtime-current-generation runtime))
                 (position (etaf-host-ref-position runtime 'next)))
            (etaf-focus runtime 'next)
            (should-error (setf (etaf-value page) 10))
            (should (eq generation (etaf-runtime-current-generation runtime)))
            (should (eq (etaf-focused-host-ref runtime) 'next))
            (with-current-buffer buffer (should (= (point) position)))
            (setf (etaf-value page) 11)
            (with-current-buffer buffer
              (should (= (point) (etaf-host-ref-position runtime 'next))))))
      (etaf-forward-test--dispose buffer))))

(provide 'etaf-event-forwarding-tests)
;;; etaf-event-forwarding-tests.el ends here
