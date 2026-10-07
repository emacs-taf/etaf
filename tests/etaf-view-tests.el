;;; etaf-view-tests.el --- Retained View updates through public APIs -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'etaf-test-support)

(etaf-define-component etaf-view-test-label (&key label)
  "Render LABEL in one text Host."
  :view (text (expr (etaf-value label))))

(etaf-define-component etaf-view-test-counter-row (&key name)
  "Render NAME with a retained local counter."
  :bindings ((clicks (etaf-ref 0)))
  :view
  (row :ref (intern (format "row-%s" name))
       :on-press (lambda () (etaf-update-value clicks #'1+))
    (text (expr (format "%s=%d" name (etaf-value clicks))))))

(etaf-define-component etaf-view-test-frame (&key title)
  "Render TITLE above default content and a named footer slot."
  :view
  (column
    (text (expr title))
    (slot)
    (slot :name 'footer (text "no footer"))))

(etaf-define-component etaf-view-test-styled ()
  "Render one styled label."
  :view (column (box :class "title" "styled"))
  :styles ((".title" :font-weight bold)))

(ert-deftest etaf-view-mounts-static-and-expression-text ()
  "A mounted View paints static text and updates an expression in place."
  (let ((label (etaf-ref "first")))
    (etaf-test-with-mount (runtime (etaf-view (column (text "header")
                                                      (etaf-view-test-label :label label))))
      (should (equal (etaf-test-lines) '("header" "first")))
      (let ((revision (etaf-runtime-revision runtime)))
        (etaf-set-value label "second")
        (should (equal (etaf-test-lines) '("header" "second")))
        (should (> (etaf-runtime-revision runtime) revision))))))

(ert-deftest etaf-view-batches-writes-into-one-commit ()
  "Writes inside one batch become visible together in one revision."
  (let ((a (etaf-ref "a")) (b (etaf-ref "b")))
    (etaf-test-with-mount (runtime (etaf-view (column (text (expr (etaf-value a)))
                                                      (text (expr (etaf-value b))))))
      (let ((revision (etaf-runtime-revision runtime)))
        (etaf-batch
          (etaf-set-value a "A")
          (etaf-set-value b "B")
          (should (equal (etaf-test-lines) '("a" "b"))))
        (should (equal (etaf-test-lines) '("A" "B")))
        (should (= (etaf-runtime-revision runtime) (1+ revision)))))))

(ert-deftest etaf-view-updates-reactive-paint-properties ()
  "A reactive Host property changes the painted face without changing text."
  (let ((bold (etaf-ref nil)))
    (etaf-test-with-mount (_runtime
                           (etaf-view (box :font-weight (if (etaf-value bold) 'bold 'normal)
                                           "label")))
      (should-not (eq (etaf-test-face-attribute (etaf-test-face-at "label") :weight) 'bold))
      (etaf-set-value bold t)
      (should (equal (etaf-test-lines) '("label")))
      (should (eq (etaf-test-face-attribute (etaf-test-face-at "label") :weight) 'bold)))))

(ert-deftest etaf-view-switches-branches ()
  "Branch directives mount only the selected arm and switch when inputs change."
  (let ((mode (etaf-ref 'a)))
    (etaf-test-with-mount (_runtime
                           (etaf-view (column
                                        (text :if (eq (etaf-value mode) 'a) "arm a")
                                        (text :else-if (eq (etaf-value mode) 'b) "arm b")
                                        (text :else t "arm c")
                                        (text "tail"))))
      (should (equal (etaf-test-lines) '("arm a" "tail")))
      (etaf-set-value mode 'b)
      (should (equal (etaf-test-lines) '("arm b" "tail")))
      (etaf-set-value mode 'z)
      (should (equal (etaf-test-lines) '("arm c" "tail")))
      (etaf-set-value mode 'a)
      (should (equal (etaf-test-lines) '("arm a" "tail"))))))

(ert-deftest etaf-view-keyed-list-retains-instances ()
  "Keyed rows keep Component state across insertion, reordering and removal."
  (let ((names (etaf-ref '("a" "b" "c"))))
    (etaf-test-with-mount (runtime
                           (etaf-view (column
                                        (etaf-view-test-counter-row
                                         :for (name (etaf-value names)) :key name
                                         :name name))))
      (should (equal (etaf-test-lines) '("a=0" "b=0" "c=0")))
      (etaf-dispatch-event runtime 'row-b 'press)
      (etaf-dispatch-event runtime 'row-b 'press)
      (should (equal (etaf-test-lines) '("a=0" "b=2" "c=0")))
      (etaf-set-value names '("c" "x" "b" "a"))
      (should (equal (etaf-test-lines) '("c=0" "x=0" "b=2" "a=0")))
      (etaf-set-value names '("b"))
      (should (equal (etaf-test-lines) '("b=2")))
      (should-not (etaf-runtime-host-props-for runtime 'row-a))
      (etaf-set-value names '("a" "b"))
      (should (equal (etaf-test-lines) '("a=0" "b=2"))))))

(ert-deftest etaf-view-keyed-list-appends-and-clears ()
  "Appending to and clearing a keyed list matches a fresh render."
  (let ((items (etaf-ref (number-sequence 1 3))))
    (etaf-test-with-mount (_runtime
                           (etaf-view (column
                                        (text "head")
                                        (text :for (n (etaf-value items)) :key n
                                              (expr (format "item %d" n)))
                                        (text "foot"))))
      (etaf-set-value items (number-sequence 1 5))
      (should (equal (etaf-test-lines)
                     '("head" "item 1" "item 2" "item 3" "item 4" "item 5" "foot")))
      (etaf-set-value items nil)
      (should (equal (etaf-test-lines) '("head" "foot")))
      (etaf-set-value items '(9))
      (should (equal (etaf-test-lines) '("head" "item 9" "foot"))))))

(ert-deftest etaf-view-rejects-duplicate-list-keys ()
  "Duplicate keys signal and keep the previous committed rows."
  (let ((items (etaf-ref '(1 2))))
    (etaf-test-with-mount (_runtime
                           (etaf-view (column (text :for (n (etaf-value items)) :key n
                                                    (expr (format "n%d" n))))))
      (should-error (etaf-set-value items '(1 1)))
      (should (equal (etaf-test-lines) '("n1" "n2"))))))

(ert-deftest etaf-view-projects-default-and-named-slots ()
  "Default and named slots project caller content; absent slots use fallback."
  (let ((footer (etaf-ref t)))
    (etaf-test-with-mount (_runtime
                           (etaf-view (column
                                        (etaf-view-test-frame
                                         :title "Frame"
                                         (text "body")
                                         (slot :name 'footer
                                               (column
                                                 (text :if (etaf-value footer)
                                                       "custom footer")))))))
      (should (equal (etaf-test-lines) '("Frame" "body" "custom footer")))
      (etaf-set-value footer nil)
      (should (equal (etaf-test-lines) '("Frame" "body"))))
    (etaf-test-with-mount (_runtime (etaf-view (etaf-view-test-frame :title "Bare")))
      (should (equal (etaf-test-lines) '("Bare" "no footer"))))))

(ert-deftest etaf-view-component-props-update-retained-instance ()
  "A changed business prop updates the instance without resetting bindings."
  (let ((name (etaf-ref "left")))
    (etaf-test-with-mount (runtime
                           (etaf-view (column (etaf-view-test-counter-row
                                               :name (etaf-value name)))))
      (etaf-dispatch-event runtime 'row-left 'press)
      (should (equal (etaf-test-lines) '("left=1")))
      (etaf-set-value name "right")
      (should (equal (etaf-test-lines) '("right=1")))
      (etaf-dispatch-event runtime 'row-right 'press)
      (should (equal (etaf-test-lines) '("right=2"))))))

(ert-deftest etaf-view-render-returns-detached-node ()
  "Pure rendering evaluates the View once without a Runtime."
  (let* ((count (etaf-ref 3))
         (node (etaf-render (etaf-view (column (text (expr (format "n=%d" (etaf-value count)))))))))
    (should node)
    (with-temp-buffer
      (ebox-mount (current-buffer) node :width 400 :height 10)
      (should (equal (etaf-test-lines) '("n=3"))))))

(ert-deftest etaf-view-node-builds-views-programmatically ()
  "`etaf-node' constructs the same Views as the DSL."
  (let ((label (etaf-ref "dynamic")))
    (etaf-test-with-mount (_runtime
                           (etaf-node 'column nil
                                      (list (etaf-node 'text nil (list "static"))
                                            (etaf-node 'etaf-view-test-label
                                                       (list :label label) nil))))
      (should (equal (etaf-test-lines) '("static" "dynamic")))
      (etaf-set-value label "changed")
      (should (equal (etaf-test-lines) '("static" "changed"))))))

(ert-deftest etaf-view-applies-component-styles ()
  "Component rules style owned Hosts and later rule changes repaint them."
  (etaf-test-with-mount (_runtime (etaf-view (etaf-view-test-styled)))
    (should (eq (etaf-test-face-attribute (etaf-test-face-at "styled") :weight) 'bold))))

(ert-deftest etaf-view-unmount-and-kill-release-runtime ()
  "Unmounting releases the Runtime; killing a buffer unmounts it."
  (let ((buffer (generate-new-buffer " *etaf-unmount*")))
    (etaf-mount buffer (etaf-view (text "x")))
    (let ((runtime (etaf-runtime-for-buffer buffer)))
      (should (etaf-runtime-mounted-p runtime))
      (etaf-unmount runtime)
      (should-not (etaf-runtime-mounted-p runtime))
      (should-not (etaf-runtime-for-buffer buffer)))
    (etaf-mount buffer (etaf-view (text "y")))
    (let ((runtime (etaf-runtime-for-buffer buffer)))
      (kill-buffer buffer)
      (should-not (etaf-runtime-mounted-p runtime)))))

(provide 'etaf-view-tests)

;;; etaf-view-tests.el ends here
