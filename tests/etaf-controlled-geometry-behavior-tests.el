;;; etaf-controlled-geometry-behavior-tests.el --- Aggregate geometry Behaviors -*- lexical-binding: t; -*-

(require 'ert)
(require 'etaf)

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

(provide 'etaf-controlled-geometry-behavior-tests)
;;; etaf-controlled-geometry-behavior-tests.el ends here
