;;; etaf-geometry-behavior-tests.el --- Draggable and resizable Behaviors -*- lexical-binding: t; -*-

;;; Commentary:
;; Public Behavior constructors translate Ebox gestures into caller-owned refs.

;;; Code:
(require 'ert)
(require 'etaf)

(ert-deftest etaf-draggable-behavior-publishes-coordinate-refs ()
  "A draggable Behavior applies Ebox deltas to caller-owned coordinates."
  (let ((buffer (generate-new-buffer " *etaf-draggable-behavior*"))
        (x (etaf-ref 3))
        (y (etaf-ref 4))
        phases)
    (unwind-protect
        (let ((behavior
               (etaf-draggable
                :x x :y y
                :on-start (lambda (_gesture) (push 'start phases))
                :on-move (lambda (_gesture) (push 'move phases))
                :on-end (lambda (_gesture) (push 'end phases)))))
          (etaf-mount
           buffer
           (etaf-view
            (box :ref 'handle :position 'absolute
                 :left (list 'px (etaf-value x))
                 :width (list 'px 20)
                 :use (list behavior)
                 "Drag")))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (dolist (gesture '((:phase start :delta (0 . 0))
                               (:phase move :delta (7 . 5))
                               (:phase end :delta (9 . 6))))
              (etaf-dispatch-event runtime 'handle 'drag gesture t)))
          (should (= (etaf-value x) 12))
          (should (= (etaf-value y) 10))
          (should (equal (reverse phases) '(start move end))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-resizable-behavior-clamps-and-keeps-left-edge ()
  "A left resize updates x and width while honoring minimum size."
  (let ((buffer (generate-new-buffer " *etaf-resizable-behavior*"))
        (x (etaf-ref 10))
        (width (etaf-ref 20)))
    (unwind-protect
        (let ((behavior
               (etaf-resizable :x x :width width :edges 'left
                               :min-width 8)))
          (etaf-mount
           buffer
           (etaf-view
            (box :ref 'handle :position 'absolute
                 :left (list 'px (etaf-value x))
                 :width (list 'px (etaf-value width))
                 :use (list behavior)
                 "Resize")))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-dispatch-event runtime 'handle 'drag
                                 '(:phase start :delta (0 . 0)) t)
            (etaf-dispatch-event runtime 'handle 'drag
                                 '(:phase move :delta (18 . 0)) t))
          ;; Width would become 2, so the minimum keeps it at 8 and moves x
          ;; by the accepted size change to preserve the right edge.
          (should (= (etaf-value width) 8))
          (should (= (etaf-value x) 22)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-geometry-behavior-converts-ebox-deltas ()
  "A delta converter adapts pixel gestures to caller coordinate units."
  (let ((buffer (generate-new-buffer " *etaf-geometry-delta*"))
        (x (etaf-ref 2)))
    (unwind-protect
        (let ((behavior
               (etaf-draggable
                :x x
                :delta (lambda (gesture)
                         (cons (/ (car (plist-get gesture :delta)) 2) 0)))))
          (etaf-mount
           buffer
           (etaf-view
            (box :ref 'handle :position 'absolute
                 :left (list 'px (etaf-value x))
                 :width (list 'px 20)
                 :use (list behavior)
                 "Convert")))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-dispatch-event runtime 'handle 'drag
                                 '(:phase start :delta (0 . 0)) t)
            (etaf-dispatch-event runtime 'handle 'drag
                                 '(:phase end :delta (10 . 0)) t))
          (should (= (etaf-value x) 7)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-geometry-behaviors-reject-invalid-contracts ()
  "Missing refs, invalid edges and nonnumeric bounds fail at construction."
  (should-error (etaf-draggable :axis 'x) :type 'etaf-behavior-error)
  (should-error (etaf-draggable :x (etaf-ref 0) :axis 'z)
                :type 'etaf-behavior-error)
  (should-error (etaf-resizable :edges 'left :width (etaf-ref 10))
                :type 'etaf-behavior-error)
  (should-error (etaf-resizable :edges '(right right)
                                :width (etaf-ref 10))
                :type 'etaf-behavior-error)
  (should-error (etaf-resizable :edges 'right :width (etaf-ref 10)
                                :min-width "large")
                :type 'etaf-behavior-error))

(provide 'etaf-geometry-behavior-tests)

;;; etaf-geometry-behavior-tests.el ends here
