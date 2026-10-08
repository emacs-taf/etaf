;;; etaf-events-tests.el --- Events, focus, input and Host queries -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'etaf-test-support)

(etaf-action-define etaf-events-test-add (runtime count amount)
  "Add AMOUNT to COUNT inside RUNTIME."
  (ignore runtime)
  (etaf-update-value count #'+ amount))

(etaf-define-component etaf-events-test-toggle (&key on)
  "Render a toggle bound to ref ON."
  :bindings ((behavior (etaf-toggleable :value on
                                        :on-change (lambda (next) (etaf-set-value on next)))))
  :view (box :ref 'toggle :use (list behavior)
             (text (expr (if (etaf-value on) "[x]" "[ ]")))))

(etaf-define-component etaf-events-test-drag (&key x)
  "Render a draggable box moving ref X."
  :bindings ((behavior (etaf-draggable :x x :axis 'x)))
  :view (box :ref 'handle :use (list behavior) (text (expr (format "x=%s" (etaf-value x))))))

(ert-deftest etaf-events-press-runs-callback-in-one-batch ()
  "A press callback runs in a batch and publishes its writes once."
  (let ((count (etaf-ref 0)) seen)
    (etaf-test-with-mount (runtime (etaf-view (column
                                                (text (expr (format "count %d" (etaf-value count))))
                                                (box :ref 'add
                                                     :on-press (lambda (&optional payload)
                                                                 (setq seen payload)
                                                                 (etaf-update-value count #'1+)
                                                                 (etaf-update-value count #'1+))
                                                     "add"))))
      (let ((revision (etaf-runtime-revision runtime)))
        (etaf-dispatch-event runtime 'add 'press)
        (should (equal (etaf-test-lines) '("count 2" "add")))
        (should (= (etaf-runtime-revision runtime) (1+ revision)))
        (etaf-dispatch-event runtime 'add :on-press 'data t)
        (should (eq seen 'data))
        (should (equal (etaf-test-lines) '("count 4" "add")))))))

(defvar etaf-events-test-pressed nil
  "Item reported by `etaf-events-test-row'.")

(etaf-define-component etaf-events-test-row (&key item)
  "Render a row reporting ITEM when pressed."
  :render (etaf-node 'box (list :ref 'row
                                :on-press (lambda () (setq etaf-events-test-pressed item)))
                     (list "row")))

(ert-deftest etaf-events-press-uses-callback-over-equal-new-item ()
  "A new prop object replaces the committed callback even when `equal'."
  (let* ((item (etaf-ref (list :id 1 :name "Row")))
         (replacement (copy-sequence (etaf-value item)))
         (etaf-events-test-pressed nil))
    (etaf-test-with-mount (runtime (etaf-view (etaf-events-test-row :item (etaf-value item))))
      (etaf-set-value item replacement)
      (etaf-dispatch-event runtime 'row 'press)
      (should (eq etaf-events-test-pressed replacement)))))

(ert-deftest etaf-events-rejects-disabled-and-missing-handlers ()
  "Disabled Hosts and Hosts without a handler signal `etaf-event-error'."
  (let ((disabled (etaf-ref t)) (presses 0))
    (etaf-test-with-mount (runtime (etaf-view (column
                                                (box :ref 'button :disabled (etaf-value disabled)
                                                     :on-press (lambda () (cl-incf presses))
                                                     "button")
                                                (box :ref 'plain "plain"))))
      (should-error (etaf-dispatch-event runtime 'button 'press) :type 'etaf-event-error)
      (should-error (etaf-dispatch-event runtime 'plain 'press) :type 'etaf-event-error)
      (etaf-set-value disabled nil)
      (etaf-dispatch-event runtime 'button 'press)
      (should (= presses 1)))))

(ert-deftest etaf-events-press-capture-sees-target ()
  "Ancestor press-capture callbacks run after the target and see it."
  (let (log)
    (etaf-test-with-mount (runtime
                           (etaf-view (column :ref 'shell
                                              :on-press-capture
                                              (lambda ()
                                                (push (list 'capture
                                                            (etaf-event-target-within-p 'panel)
                                                            (etaf-event-target-within-p 'leaf))
                                                      log))
                                        (box :ref 'panel
                                             (box :ref 'leaf
                                                  :on-press (lambda () (push 'leaf log))
                                                  "leaf")))))
      (etaf-dispatch-event runtime 'leaf 'press)
      (should (equal (reverse log) '(leaf (capture t t))))
      (should (equal (gethash 'leaf (etaf-runtime-host-ancestries runtime '(leaf)))
                     '(leaf panel shell))))))

(ert-deftest etaf-events-actions-dispatch-through-runtime ()
  "Named Actions receive the Runtime and run in an event batch."
  (let ((count (etaf-ref 1)))
    (etaf-test-with-mount (runtime (etaf-view (column
                                                (text (expr (format "n=%d" (etaf-value count))))
                                                (box :ref 'go
                                                     :on-press (lambda ()
                                                                 (etaf-dispatch 'etaf-events-test-add
                                                                                count 2))
                                                     "go"))))
      (etaf-dispatch-event runtime 'go 'press)
      (should (equal (car (etaf-test-lines)) "n=3"))
      (etaf-dispatch runtime 'etaf-events-test-add count 10)
      (should (equal (car (etaf-test-lines)) "n=13"))
      (should-error (etaf-dispatch runtime 'etaf-events-test-unknown) :type 'etaf-action-error))))

(ert-deftest etaf-events-focus-navigation ()
  "Focus moves among tab stops and reports committed Host references."
  (etaf-test-with-mount (runtime (etaf-view (column
                                              (box :ref 'one :tab-index 0 "one")
                                              (box :ref 'two :use (list (etaf-focusable)) "two")
                                              (box :ref 'group
                                                   (box :ref 'three :tab-index 0 "three")))))
    (etaf-focus runtime)
    (should (eq (etaf-focused-host-ref runtime) 'one))
    (etaf-focus-next runtime)
    (should (eq (etaf-focused-host-ref runtime) 'two))
    (etaf-focus-previous runtime)
    (should (eq (etaf-focused-host-ref runtime) 'one))
    (etaf-focus runtime 'three)
    (should (eq (etaf-focused-host-ref runtime) 'three))
    (should (= (point) (etaf-host-ref-position runtime 'three)))
    (etaf-focus runtime 'one)
    (etaf-focus-within runtime 'group)
    (should (eq (etaf-focused-host-ref runtime) 'three))
    (should-error (etaf-focus runtime 'missing) :type 'etaf-event-error)))

(ert-deftest etaf-events-activate-dispatches-press-at-point ()
  "Activation at point dispatches the enclosing Host's press callback."
  (let ((pressed nil))
    (etaf-test-with-mount (runtime (etaf-view (column
                                                (text "header")
                                                (box :ref 'button :on-press (lambda () (setq pressed t))
                                                     "button"))))
      (goto-char (etaf-host-ref-position runtime 'button))
      (etaf-activate runtime)
      (should pressed))))

(ert-deftest etaf-events-behaviors-toggle-and-drag ()
  "Toggleable and draggable Behaviors update caller-owned refs."
  (let ((on (etaf-ref nil)) (x (etaf-ref 10)))
    (etaf-test-with-mount (runtime (etaf-view (column (etaf-events-test-toggle :on on)
                                                      (etaf-events-test-drag :x x))))
      (should (equal (etaf-test-lines) '("[ ]" "x=10")))
      (etaf-dispatch-event runtime 'toggle 'press)
      (should (equal (etaf-test-lines) '("[x]" "x=10")))
      (etaf-dispatch-event runtime 'handle 'drag '(:phase start :delta (0 . 0)) t)
      (etaf-dispatch-event runtime 'handle 'drag '(:phase move :delta (5 . 0)) t)
      (etaf-dispatch-event runtime 'handle 'drag '(:phase end :delta (7 . 0)) t)
      (should (= (etaf-value x) 17))
      (should (equal (etaf-test-lines) '("[x]" "x=17"))))))

(ert-deftest etaf-events-native-input-session ()
  "An input session edits a Host's text and restores it on end."
  (etaf-test-with-mount (runtime (etaf-view (column (text :ref 'field :tab-index 0 "value")
                                                    (text "after"))))
    (let ((session (etaf-input-begin runtime 'field)))
      (should (eq (etaf-input-active-p runtime) session))
      (should (equal (etaf-input-text session) "value"))
      (should (equal (etaf-input-end session) "value"))
      (should-not (etaf-input-active-p runtime))
      (should (equal (etaf-test-lines) '("value" "after"))))))

(ert-deftest etaf-events-host-queries ()
  "Host queries report committed props, handlers, bounds and size."
  (let ((label (etaf-ref "abc")))
    (etaf-test-with-mount (runtime (etaf-view (column
                                                (box :ref 'target :class "c" :tab-index 0
                                                     :on-press #'ignore
                                                     (text (expr (etaf-value label)))))))
      (should (equal (plist-get (etaf-runtime-host-props-for runtime 'target) :class) "c"))
      (should (assq 'target (etaf-runtime-host-props-entries runtime)))
      (should (assq 'target (etaf-runtime-handler-entries runtime)))
      (let ((bounds (etaf-host-ref-bounds runtime 'target))
            (size (etaf-host-ref-size runtime 'target)))
        (should (consp bounds))
        (should (< (car bounds) (cdr bounds)))
        (should (= (cdr size) 1))
        (should (> (car size) 0)))
      (should-not (etaf-host-ref-bounds runtime 'missing)))))

(ert-deftest etaf-events-retained-host-updates ()
  "Retained content and geometry updates change one Host and bump the revision."
  (etaf-test-with-mount (runtime (etaf-view (column (text :ref 'frame "frame 0")
                                                    (box :ref 'panel :width '(px 100) "panel"))))
    (let ((revision (etaf-runtime-revision runtime)))
      (should (eq t (etaf-runtime-update-host-content runtime 'frame "frame 1")))
      (should (equal (etaf-test-lines) '("frame 1" "panel")))
      (should (> (etaf-runtime-revision runtime) revision))
      (should (eq t (etaf-runtime-update-host-contents runtime '((frame . "frame 2")))))
      (should (equal (etaf-test-lines) '("frame 2" "panel")))
      (should (eq t (etaf-runtime-update-host-geometry runtime 'panel :width '(px 200))))
      (should (= (car (etaf-host-ref-size runtime 'panel)) 200))
      (should-error (etaf-runtime-update-host-content runtime 'missing "x")
                    :type 'etaf-runtime-error))))

(ert-deftest etaf-events-performance-records-operations ()
  "The performance recorder captures observed event operations."
  (etaf-test-with-mount (runtime (etaf-view (box :ref 'b :on-press #'ignore "b")))
    (etaf-performance-clear)
    (etaf-performance-start runtime)
    (unwind-protect
        (etaf-dispatch-event runtime 'b 'press)
      (etaf-performance-stop runtime))
    (let ((records (etaf-performance-records)))
      (should records)
      (should (eq (etaf-performance-operation-kind (car records)) 'event))
      (should (eq (etaf-performance-operation-status (car records)) 'success)))))

(provide 'etaf-events-tests)

;;; etaf-events-tests.el ends here
