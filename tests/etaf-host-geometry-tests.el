;;; etaf-host-geometry-tests.el --- Reactive geometry publication -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Public geometry inputs retain semantic queries, snapshots and interaction.

;;; Code:

(require 'ert)
(require 'etaf)
(require 'ebox)

(defun etaf-host-geometry-test--crop-view (width height on-press)
  "Build a fixed-text panel with live WIDTH, HEIGHT and ON-PRESS."
  (etaf-view
   (box :position 'relative :width '(px 240) :height '(lh 12)
        :background-color "#EAF0F6"
     (box :id "crop" :ref 'crop :position 'absolute :left '(px 8) :top '(lh 2)
          :width (etaf-value width) :height (etaf-value height) :z-index 1
          :min-width '(px 0) :min-height '(lh 0) :overflow 'hidden :wrap-mode 'none
          :color "#F1F5F9" :background-color "#243447"
          :tab-index 0 :on-press on-press
       (text "Fixed text abcdefghijklmnopqrstuvwxyz\nSecond row\nThird row")))))

(ert-deftest etaf-host-geometry-resizes-fixed-text-through-prepared-publication ()
  "Mounted size bindings publish directly while snapshots and input remain current."
  (let ((buffer (generate-new-buffer " *etaf-retained-crop*"))
        (width (etaf-ref '(px 96) :test #'equal))
        (height (etaf-ref '(lh 4) :test #'equal)) (pressed 0))
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-host-geometry-test--crop-view
                              width height (lambda () (cl-incf pressed))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (snapshot (etaf-runtime-snapshot runtime))
                 (before (ebox-render (plist-get snapshot :input))))
            (dolist (size '((160 6) (64 2) (192 7) (96 4)))
              (let ((revision (ebox-surface-buffer-revision buffer)))
                (etaf-batch
                  (etaf-set-value width (list 'px (car size)))
                  (etaf-set-value height (list 'lh (cadr size))))
                (etaf-runtime-flush runtime)
                (should (= (1+ revision) (ebox-surface-buffer-revision buffer)))
                (should (eq 'prepared-update (plist-get (ebox-buffer-update-report buffer) :projection-kind)))
                (should (equal (etaf-value width)
                               (plist-get (etaf-runtime-host-props-for runtime 'crop) :width)))
                (should (equal (etaf-value height)
                               (plist-get (etaf-runtime-host-props-for runtime 'crop) :height)))
                (should (etaf-host-ref-position runtime 'crop))
                (should (equal (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max)))
                               (substring-no-properties (ebox-render (plist-get (etaf-runtime-snapshot runtime) :input)))))
                (etaf-dispatch-event runtime 'crop 'press)))
            (should (= pressed 4))
            (should (equal-including-properties before (ebox-render (plist-get snapshot :input))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-retained-resize-example-controls-size-and-cancellation ()
  "The interactive example preserves controlled sizes, peer input and cleanup."
  (let ((buffer (generate-new-buffer " *etaf-resize-example-test*")))
    (unwind-protect
        (progn
          (etaf-retained-resize-open buffer)
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-dispatch-event runtime 'resize-panel 'drag '(:phase start :delta (0 . 0)) t)
            (etaf-dispatch-event runtime 'resize-panel 'drag '(:phase move :delta (32 . 2)) t)
            (should (eq 'prepared-update (plist-get (ebox-buffer-update-report buffer) :projection-kind)))
            (should (equal '(px 352) (plist-get (etaf-runtime-host-props-for runtime 'resize-panel) :width)))
            (should (equal '(lh 10) (plist-get (etaf-runtime-host-props-for runtime 'resize-panel) :height)))
            (etaf-dispatch-event runtime 'resize-panel 'drag '(:phase cancel :reason quit :delta (32 . 2)) t)
            (should (equal '(px 320) (plist-get (etaf-runtime-host-props-for runtime 'resize-panel) :width)))
            (should (equal '(lh 8) (plist-get (etaf-runtime-host-props-for runtime 'resize-panel) :height)))
            (should (etaf-host-ref-position runtime 'resize-peer))
            (etaf-dispatch-event runtime 'resize-panel 'drag '(:phase start :delta (0 . 0)) t)
            (etaf-dispatch-event runtime 'resize-panel 'drag '(:phase end :delta (16 . 1)) t)
            (should (equal '(px 336) (plist-get (etaf-runtime-host-props-for runtime 'resize-panel) :width)))
            (etaf-unmount runtime)
            (should-not (etaf-runtime-for-buffer buffer))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(etaf-define-component etaf-host-geometry-test--component (&key left shown)
  :bindings ((count (etaf-ref 0)))
  :view
  (box :ref 'component-panel :position 'absolute
       :left (etaf-value left) :top '(lh 1)
       :width '(px 60) :height '(lh 3)
       :visibility (if (etaf-value shown) 'visible 'hidden)
       :on-press (lambda () (etaf-update-value count #'1+))
    (text (expr (format "Count %d" (etaf-value count))))))

(defun etaf-host-geometry-test--view (left top width visible clicks)
  "Return a positioned public View using LEFT, TOP, WIDTH, VISIBLE and CLICKS."
  (etaf-view
   (box :position 'relative :width '(px 180) :height '(lh 12)
     (expr
      (when (etaf-value visible)
        (etaf-view
         (box :id "panel" :ref 'panel :position 'absolute
              :left (etaf-value left) :top (etaf-value top)
              :width (etaf-value width) :height '(lh 3)
              :on-press (lambda () (etaf-update-value clicks #'1+))
           (text "Panel")))))
     (box :id "peer" :ref 'peer :position 'absolute
          :left '(px 100) :top '(lh 7) :width '(px 60) :height '(lh 2)
       (text "Peer")))))

(ert-deftest etaf-host-geometry-publishes-semantics-and-detached-snapshots ()
  "Repeated geometry writes update queries while retained exports stay fixed."
  (let ((left (etaf-ref '(px 0))) (top (etaf-ref '(lh 0)))
        (width (etaf-ref '(px 60))) (visible (etaf-ref t))
        (clicks (etaf-ref 0))
        (buffer (generate-new-buffer " *etaf-host-geometry*")))
    (unwind-protect
        (let* ((runtime
                (etaf-runtime-for-buffer
                 (etaf-mount buffer
                             (etaf-host-geometry-test--view
                              left top width visible clicks))))
               (snapshot (etaf-runtime-snapshot runtime))
               (before (ebox-render (plist-get snapshot :input)))
               (props (etaf-runtime-host-props-for runtime 'panel))
               (revision (plist-get snapshot :revision))
               (generation (etaf-runtime-generation runtime)))
          (dolist (x '(12 28 4))
            (etaf-batch
              (etaf-set-value left (list 'px x))
              (etaf-set-value top '(lh 2)))
            (should (equal (list 'px x)
                           (plist-get (etaf-runtime-host-props-for runtime 'panel)
                                      :left)))
            (with-current-buffer buffer
              (should (equal (list 'px x)
                             (plist-get (ebox-region-geometry "panel") :left)))
              (should (equal '(lh 2)
                             (plist-get (ebox-region-geometry "panel") :top))))
            (should (> (etaf-runtime-generation runtime) generation))
            (should (> (etaf-runtime-flush runtime) revision))
            (setq generation (etaf-runtime-generation runtime)
                  revision (etaf-runtime-flush runtime))
            (etaf-dispatch-event runtime 'panel 'press))
          (should (= 3 (etaf-value clicks)))
          (should (equal '(px 0) (plist-get props :left)))
          (should (equal-including-properties
                   before (ebox-render (plist-get snapshot :input)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-host-geometry-recovers-after-invalid-input-and-replacement ()
  "Rejected geometry retains the picture; resize and replacement remain current."
  (let ((left (etaf-ref '(px 0))) (top (etaf-ref '(lh 0)))
        (width (etaf-ref '(px 60))) (visible (etaf-ref t))
        (clicks (etaf-ref 0))
        (buffer (generate-new-buffer " *etaf-host-geometry-recovery*")))
    (unwind-protect
        (let ((runtime
               (etaf-runtime-for-buffer
                (etaf-mount buffer
                            (etaf-host-geometry-test--view
                             left top width visible clicks)))))
          (etaf-set-value left '(px 10))
          (let ((revision (etaf-runtime-flush runtime))
                (generation (etaf-runtime-generation runtime))
                (before (with-current-buffer buffer (buffer-string))))
            (should-error (etaf-set-value left '(unknown-unit 20)))
            (should (= generation (etaf-runtime-generation runtime)))
            (should (= revision
                       (plist-get (etaf-runtime-snapshot runtime) :revision)))
            (should (equal '(px 10)
                           (plist-get (etaf-runtime-host-props-for runtime 'panel)
                                      :left)))
            (should (equal-including-properties
                     before (with-current-buffer buffer (buffer-string)))))
          (etaf-set-value left '(px 20))
          (etaf-set-value width '(px 80))
          (etaf-set-value left '(px 30))
          (etaf-set-value visible nil)
          (should-not (etaf-host-ref-position runtime 'panel))
          (etaf-set-value visible t)
          (etaf-set-value left '(px 5))
          (with-current-buffer buffer
            (should (equal '(px 5)
                           (plist-get (ebox-region-geometry "panel") :left)))
            (should (equal '(px 80)
                           (plist-get (ebox-region-geometry "panel") :width)))
            (should (string-match-p "Peer" (buffer-string))))
          (etaf-dispatch-event runtime 'panel 'press)
          (should (= 1 (etaf-value clicks))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-host-geometry-keeps-component-state-and-property-guards ()
  "Geometry and visibility preserve a Component's state and current handlers."
  (let ((left (etaf-ref '(px 0))) (shown (etaf-ref t))
        (buffer (generate-new-buffer " *etaf-component-geometry*")))
    (unwind-protect
        (let ((runtime
               (etaf-runtime-for-buffer
                (etaf-mount
                 buffer
                 (etaf-view
                  (box :position 'relative :width '(px 180) :height '(lh 10)
                    (etaf-host-geometry-test--component
                     :left left :shown shown)))))))
          (etaf-set-value left '(px 12))
          (etaf-dispatch-event runtime 'component-panel 'press)
          (etaf-set-value left '(px 20))
          (etaf-set-value shown nil)
          (should-not (etaf-host-ref-position runtime 'component-panel))
          (etaf-set-value left '(px 8))
          (etaf-set-value shown t)
          (should (etaf-host-ref-position runtime 'component-panel))
          (should (equal '(px 8)
                         (plist-get
                          (etaf-runtime-host-props-for runtime 'component-panel)
                          :left)))
          (etaf-dispatch-event runtime 'component-panel 'press)
          (should (string-match-p "Count 2"
                                  (with-current-buffer buffer (buffer-string)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-host-geometry-rebinds-changed-reactive-dependencies ()
  "A geometry expression switches dependencies without losing later updates."
  (let ((first (etaf-ref '(px 0))) (second (etaf-ref '(px 10)))
        (choose-second (etaf-ref nil))
        (buffer (generate-new-buffer " *etaf-geometry-dependencies*")))
    (unwind-protect
        (let ((runtime
               (etaf-runtime-for-buffer
                (etaf-mount
                 buffer
                 (etaf-view
                  (box :position 'relative :width '(px 180) :height '(lh 10)
                    (box :ref 'panel :position 'absolute
                         :left (if (etaf-value choose-second)
                                   (etaf-value second) (etaf-value first))
                         :top '(lh 1) :width '(px 60) :height '(lh 3)
                      (text "Panel"))))))))
          (etaf-set-value first '(px 4))
          (etaf-set-value choose-second t)
          (etaf-set-value second '(px 22))
          (should (equal '(px 22)
                         (plist-get (etaf-runtime-host-props-for runtime 'panel)
                                    :left)))
          (etaf-set-value choose-second nil)
          (etaf-set-value first '(px 7))
          (should (equal '(px 7)
                         (plist-get (etaf-runtime-host-props-for runtime 'panel)
                                    :left))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-host-geometry-resolves-theme-tokens-across-declaration-changes ()
  "Geometry tokens resolve both initially and when introduced after plain moves."
  (let ((left (etaf-ref '(px 0)))
        (token-p (etaf-ref t))
        (buffer (generate-new-buffer " *etaf-host-geometry-token*")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (box :position 'relative :width '(px 180) :height '(lh 12)
              (box :id "panel" :ref 'panel :position 'absolute
                   :left (if (etaf-value token-p)
                             (etaf-theme-token :panel-left (etaf-value left))
                           (etaf-value left))
                   :top '(lh 0) :width '(px 60) :height '(lh 3)
                "Panel"))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (dolist (case '((t (px 10)) (nil (px 20))
                            (t (px 30)) (nil (px 40))))
              (etaf-batch
                (etaf-set-value token-p (car case))
                (etaf-set-value left (cadr case)))
              (should (equal (cadr case)
                             (plist-get
                              (etaf-runtime-host-props-for runtime 'panel)
                              :left)))
              (with-current-buffer buffer
                (should (equal (cadr case)
                               (plist-get (ebox-region-geometry "panel") :left)))
                (should (string-match-p "Panel" (buffer-string)))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-host-geometry-accepts-unit-and-unspecified-transitions ()
  "Unit and unspecified changes match fresh output; invalid units stay rejected."
  (let ((left (etaf-ref '(px 0)))
        (buffer (generate-new-buffer " *etaf-host-geometry-units*"))
        (fresh (generate-new-buffer " *etaf-host-geometry-units-fresh*")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (box :position 'relative :width '(px 180) :height '(lh 12)
              (box :id "panel" :ref 'panel :position 'absolute
                   :left (etaf-value left) :top '(lh 0)
                   :width '(px 60) :height '(lh 3)
                "Panel"))))
          (dolist (value '((ch 2) (px 20) auto (px 30) nil (px 40)))
            (if (eq value 'auto)
                (let ((before (with-current-buffer buffer (buffer-string))))
                  (should-error (etaf-set-value left value) :type 'ebox-size-error)
                  (should (equal-including-properties
                           before (with-current-buffer buffer (buffer-string)))))
              (etaf-set-value left value)
              (etaf-mount
               fresh
               (etaf-view
                (box :position 'relative :width '(px 180) :height '(lh 12)
                  (box :id "panel" :ref 'panel :position 'absolute
                       :left value :top '(lh 0) :width '(px 60) :height '(lh 3)
                    "Panel"))))
              (should
               (equal (with-current-buffer fresh
                        (plist-get (ebox-region-geometry "panel") :left))
                      (with-current-buffer buffer
                        (plist-get (ebox-region-geometry "panel") :left))))
              (should
               (equal value
                      (plist-get
                       (etaf-runtime-host-props-for
                        (etaf-runtime-for-buffer buffer) 'panel) :left)))
              (should
               (equal (etaf-host-ref-bounds (etaf-runtime-for-buffer fresh) 'panel)
                      (etaf-host-ref-bounds (etaf-runtime-for-buffer buffer) 'panel)))
              (let ((expected (with-current-buffer fresh (buffer-string)))
                    (actual (with-current-buffer buffer (buffer-string))))
                (should (string= expected actual))
                (dotimes (position (length expected))
                  (should (equal (get-text-property position 'display expected)
                                 (get-text-property position 'display actual)))))
              (etaf-unmount (etaf-runtime-for-buffer fresh)))))
      (dolist (target (list buffer fresh))
        (when-let* ((runtime (etaf-runtime-for-buffer target)))
          (etaf-unmount runtime))
        (kill-buffer target)))))

(ert-deftest etaf-host-geometry-unsupported-root-recovers-from-invalid-value ()
  "A standalone Host retains ordinary validation and recovery without a plane."
  (let ((left (etaf-ref '(px 0)))
        (buffer (generate-new-buffer " *etaf-standalone-geometry*")))
    (unwind-protect
        (let ((runtime
               (etaf-runtime-for-buffer
                (etaf-mount
                 buffer
                 (etaf-view
                  (box :ref 'panel :position 'absolute
                       :left (etaf-value left) :width '(px 80)
                    (text "Panel")))))))
          (let ((generation (etaf-runtime-generation runtime)))
            (should-error (etaf-set-value left '(unknown-unit 2)))
            (should (= generation (etaf-runtime-generation runtime))))
          (etaf-set-value left '(px 12))
          (should (equal '(px 12)
                         (plist-get (etaf-runtime-host-props-for runtime 'panel)
                                    :left)))
          (should (string-match-p "Panel"
                                  (with-current-buffer buffer (buffer-string)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'etaf-host-geometry-tests)
;;; etaf-host-geometry-tests.el ends here
