;;; etaf-controlled-geometry-behavior-tests.el --- Aggregate geometry Behaviors -*- lexical-binding: t; -*-

(require 'ert)
(require 'etaf)

;; The child owns its gesture Behaviors in `:bindings'.  The parent reads the
;; same aggregate ref while rendering, which deliberately causes a parent
;; projection update after each accepted motion.  This fixture exercises the
;; public retention contract without inspecting Runtime internals.
(etaf-define-component etaf-test-controlled-geometry-child (&key state)
  :bindings
  ((move
    (etaf-draggable-controlled
     (lambda () (etaf-value state))
     (lambda (next) (setf (etaf-value state) next))))
   (resize
    (etaf-resizable-controlled
     (lambda () (etaf-value state))
     (lambda (next) (setf (etaf-value state) next))
     :edges '(right bottom)
     :min-width 8
     :min-height 4)))
  :render
  (etaf-view
   (column
    (box :ref 'controlled-drag-handle :position 'absolute
         :left (list 'px (plist-get (etaf-value state) :x))
         :top (list 'lh (plist-get (etaf-value state) :y))
         :width (list 'px (plist-get (etaf-value state) :width))
         :height (list 'lh (plist-get (etaf-value state) :height))
         :use (list move) "Drag")
    (box :ref 'controlled-resize-handle :position 'absolute
         :left (list 'px (plist-get (etaf-value state) :x))
         :top (list 'lh (plist-get (etaf-value state) :y))
         :width (list 'px (plist-get (etaf-value state) :width))
         :height (list 'lh (plist-get (etaf-value state) :height))
         :use (list resize) "Resize"))))

(etaf-define-component etaf-test-controlled-geometry-parent (&key state)
  :render
  (let ((snapshot (etaf-value state)))
    (etaf-view
     (column
      (etaf-test-controlled-geometry-child :key 'surface :state state)
      (text (expr (format "%s" (plist-get snapshot :x))))))))

(ert-deftest etaf-controlled-draggable-keeps-aggregate-state-authoritative ()
  "Controlled drag emits a detached next plist without owning geometry refs."
  (let ((buffer (generate-new-buffer " *etaf-controlled-drag*"))
        (state '(:x 3 :y 4 :width 20 :height 8)) changes)
    (unwind-protect
        (let ((behavior
               (etaf-draggable-controlled
                (lambda () state)
                (lambda (next) (setq state next) (push next changes)))))
          (etaf-mount buffer (etaf-view
                               (box :ref 'handle :position 'absolute
                                    :left '(px 3) :top '(lh 4)
                                    :width '(px 20) :height '(lh 8)
                                    :use (list behavior) "Drag"))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-dispatch-event runtime 'handle 'drag '(:phase start :delta (0 . 0)) t)
            (etaf-dispatch-event runtime 'handle 'drag '(:phase end :delta (7 . 2)) t))
          (should (equal '(10 6) (list (plist-get state :x) (plist-get state :y))))
          (should (= 1 (length changes))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer)))

(ert-deftest etaf-controlled-resizable-applies-edge-and-bounds ()
  "Controlled resize preserves the opposite edge and clamps dimensions."
  (let ((buffer (generate-new-buffer " *etaf-controlled-resize*"))
        (state '(:x 10 :y 2 :width 20 :height 8)) changes)
    (unwind-protect
        (let ((behavior
               (etaf-resizable-controlled
                (lambda () state)
                (lambda (next) (setq state next) (push next changes))
                :edges 'left :min-width 8)))
          (etaf-mount buffer (etaf-view
                               (box :ref 'handle :position 'absolute
                                    :left '(px 10) :top '(lh 2)
                                    :width '(px 20) :height '(lh 8)
                                    :use (list behavior) "Resize"))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-dispatch-event runtime 'handle 'drag '(:phase start :delta (0 . 0)) t)
            (etaf-dispatch-event runtime 'handle 'drag '(:phase move :delta (18 . 0)) t))
          (should (= 8 (plist-get state :width)))
          (should (= 22 (plist-get state :x)))
          (should (= 1 (length changes))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer)))

(ert-deftest etaf-controlled-draggable-retains-origin-through-rerenders ()
  "A bound controlled drag keeps one origin across parent projections."
  (let ((buffer (generate-new-buffer " *etaf-controlled-drag-retained*"))
        (state (etaf-ref '(:x 3 :y 4 :width 20 :height 8))))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-test-controlled-geometry-parent :state state)))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-dispatch-event runtime 'controlled-drag-handle 'drag
                                 '(:phase start :delta (0 . 0)) t)
            (etaf-dispatch-event runtime 'controlled-drag-handle 'drag
                                 '(:phase move :delta (7 . 2)) t)
            (should (equal '(10 6)
                           (list (plist-get (etaf-value state) :x)
                                 (plist-get (etaf-value state) :y))))
            (etaf-dispatch-event runtime 'controlled-drag-handle 'drag
                                 '(:phase move :delta (9 . 3)) t)
            (etaf-dispatch-event runtime 'controlled-drag-handle 'drag
                                 '(:phase end :delta (11 . 4)) t))
          (should (equal '(14 8)
                         (list (plist-get (etaf-value state) :x)
                               (plist-get (etaf-value state) :y)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-controlled-draggable-cancel-and-repeated-gestures-use-current-state ()
  "Cancel clears only transient origin; the next gesture starts at current state."
  (let ((buffer (generate-new-buffer " *etaf-controlled-drag-repeat*"))
        (state (etaf-ref '(:x 3 :y 4 :width 20 :height 8))))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-test-controlled-geometry-parent :state state)))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-dispatch-event runtime 'controlled-drag-handle 'drag
                                 '(:phase start :delta (0 . 0)) t)
            (etaf-dispatch-event runtime 'controlled-drag-handle 'drag
                                 '(:phase move :delta (5 . 1)) t)
            (etaf-dispatch-event runtime 'controlled-drag-handle 'drag
                                 '(:phase cancel :delta (8 . 2)) t)
            (should (equal '(8 5)
                           (list (plist-get (etaf-value state) :x)
                                 (plist-get (etaf-value state) :y))))
            (etaf-dispatch-event runtime 'controlled-drag-handle 'drag
                                 '(:phase start :delta (0 . 0)) t)
            (etaf-dispatch-event runtime 'controlled-drag-handle 'drag
                                 '(:phase end :delta (2 . 3)) t)
            (should (equal '(10 8)
                           (list (plist-get (etaf-value state) :x)
                                 (plist-get (etaf-value state) :y))))
            (etaf-dispatch-event runtime 'controlled-drag-handle 'drag
                                 '(:phase start :delta (0 . 0)) t)
            (etaf-dispatch-event runtime 'controlled-drag-handle 'drag
                                 '(:phase end :delta (4 . 0)) t)))
          (should (= 14 (plist-get (etaf-value state) :x)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-controlled-resizable-retains-origin-through-rerenders ()
  "A bound controlled resize keeps its start geometry across projections."
  (let ((buffer (generate-new-buffer " *etaf-controlled-resize-retained*"))
        (state (etaf-ref '(:x 3 :y 4 :width 20 :height 8))))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-test-controlled-geometry-parent :state state)))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-dispatch-event runtime 'controlled-resize-handle 'drag
                                 '(:phase start :delta (0 . 0)) t)
            (etaf-dispatch-event runtime 'controlled-resize-handle 'drag
                                 '(:phase move :delta (7 . 2)) t)
            (should (equal '(27 10)
                           (list (plist-get (etaf-value state) :width)
                                 (plist-get (etaf-value state) :height))))
            (etaf-dispatch-event runtime 'controlled-resize-handle 'drag
                                 '(:phase end :delta (11 . 3)) t))
          (should (equal '(31 11)
                         (list (plist-get (etaf-value state) :width)
                               (plist-get (etaf-value state) :height)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-controlled-geometry-behavior-tests)
;;; etaf-controlled-geometry-behavior-tests.el ends here
