;;; etaf-prepared-batch-tests.el --- Atomic mixed Host updates -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Related geometry, paint, hover and inline changes publish one accepted state.

;;; Code:

(require 'ert)
(require 'etaf)
(require 'ebox)

(etaf-define-component etaf-prepared-batch-test--panel
    (&key left color hover caption reject report)
  :setup (progn (etaf-on-updated report) nil)
  :view
  (box :id "prepared-panel" :ref 'prepared-panel :position 'absolute
       :left (etaf-value left) :top '(lh 0)
       :width '(ch 14) :height '(lh 2)
    (text :ref 'prepared-caption
          :color (etaf-value color) :hover-content (etaf-value hover)
      (expr (let ((value (etaf-value caption)))
              (when (funcall reject) (error "Rejected batch caption"))
              value)))))

(defun etaf-prepared-batch-test--view
    (left color hover caption reject report)
  "Build a public View using LEFT, COLOR, HOVER, CAPTION, REJECT and REPORT."
  (etaf-view
   (box :position 'relative :width '(ch 20) :height '(lh 3)
     (etaf-prepared-batch-test--panel
      :left left :color color :hover hover :caption caption
      :reject reject :report report))))

(defun etaf-prepared-batch-test--caption (label display)
  "Return LABEL with a cached DISPLAY substitution on its final character."
  (concat label (propertize "@" 'display display)))

(defun etaf-prepared-batch-test--appearance (text)
  "Return TEXT and its observable display and face properties."
  (cons (substring-no-properties text)
        (cl-loop for position below (length text)
                 collect (list (get-text-property position 'display text)
                               (get-text-property position 'face text)))))

(defun etaf-prepared-batch-test--assert-fresh
    (runtime buffer fresh left color hover caption reject)
  "Compare RUNTIME in BUFFER with FRESH using the current public inputs.
LEFT, COLOR, HOVER, CAPTION and REJECT are the mounted View's input handles."
  (let ((fresh-runtime
         (etaf-runtime-for-buffer
          (etaf-mount
           fresh (etaf-prepared-batch-test--view
                  left color hover caption reject #'ignore)))))
    (unwind-protect
        (progn
          (dolist (ref '(prepared-panel prepared-caption))
            (should
             (equal-including-properties
              (etaf-runtime-host-props-for runtime ref)
              (etaf-runtime-host-props-for fresh-runtime ref))))
          (should
           (equal
            (etaf-prepared-batch-test--appearance
             (ebox-render (plist-get (etaf-runtime-snapshot runtime) :input)))
            (etaf-prepared-batch-test--appearance
             (ebox-render (plist-get (etaf-runtime-snapshot fresh-runtime) :input)))))
          (should
           (equal
            (etaf-prepared-batch-test--appearance
             (with-current-buffer buffer (buffer-string)))
            (etaf-prepared-batch-test--appearance
             (with-current-buffer fresh (buffer-string))))))
      (etaf-unmount fresh-runtime))))

(ert-deftest etaf-prepared-batch-publishes-mixed-host-inputs-once ()
  "Repeated mixed batches match fresh mounts in one revision and owner update."
  (let ((buffer (generate-new-buffer " *etaf-prepared-batch*"))
        (fresh (generate-new-buffer " *etaf-prepared-batch-fresh*"))
        (left (etaf-ref '(ch 0)))
        (color (etaf-ref "#112233"))
        (hover (etaf-ref "Initial hover"))
        (caption (etaf-ref (etaf-prepared-batch-test--caption "Value00 " "[0]")))
        (updates 0))
    (unwind-protect
        (let ((runtime
               (etaf-runtime-for-buffer
                (etaf-mount
                 buffer
                 (etaf-prepared-batch-test--view
                  left color hover caption (lambda () nil)
                  (lambda () (cl-incf updates)))))))
          (dolist (entry '((1 "#224466" "First hover" "Value01 " "[1]")
                           (2 "#446622" "Second hover" "Value02 " "[2]")
                           (3 "#662244" "Third hover" "Value03 " "[3]")))
            (let ((revision (etaf-runtime-flush runtime))
                  (before-updates updates)
                  (before (with-current-buffer buffer (buffer-string)))
                  (next-caption
                   (etaf-prepared-batch-test--caption (nth 3 entry) (nth 4 entry))))
              (etaf-batch
                (etaf-set-value left (list 'ch (nth 0 entry)))
                (etaf-set-value color (nth 1 entry))
                (etaf-set-value hover (nth 2 entry))
                (etaf-set-value caption next-caption)
                (should (= revision (plist-get (etaf-runtime-snapshot runtime)
                                              :revision)))
                (should (equal-including-properties
                         before (with-current-buffer buffer (buffer-string)))))
              (should (= (1+ revision) (etaf-runtime-flush runtime)))
              (should (= (1+ before-updates) updates))
              (should (equal (etaf-value left)
                             (plist-get (etaf-runtime-host-props-for
                                         runtime 'prepared-panel) :left)))
              (let ((props (etaf-runtime-host-props-for runtime 'prepared-caption)))
                (should (equal (etaf-value color) (plist-get props :color)))
                (should (equal (etaf-value hover) (plist-get props :hover-content))))
              (should
               (cl-some
                (lambda (properties) (equal (nth 4 entry) (car properties)))
                (cdr (etaf-prepared-batch-test--appearance
                      (with-current-buffer buffer (buffer-string))))))
              (etaf-prepared-batch-test--assert-fresh
               runtime buffer fresh left color hover caption (lambda () nil)))))
      (dolist (target (list buffer fresh))
        (when-let* ((runtime (etaf-runtime-for-buffer target)))
          (etaf-unmount runtime))
        (kill-buffer target)))))

(ert-deftest etaf-prepared-batch-rejection-retains-all-members-until-retry ()
  "A getter failure retains the whole publication and retries changed refs once."
  (let ((buffer (generate-new-buffer " *etaf-prepared-batch-retry*"))
        (fresh (generate-new-buffer " *etaf-prepared-batch-retry-fresh*"))
        (left (etaf-ref '(ch 0)))
        (color (etaf-ref "#112233"))
        (hover (etaf-ref "Initial hover"))
        (caption (etaf-ref (etaf-prepared-batch-test--caption "Value00 " "[0]")))
        (updates 0)
        rejected)
    (unwind-protect
        (let* ((reject (lambda () rejected))
               (runtime
                (etaf-runtime-for-buffer
                 (etaf-mount
                  buffer (etaf-prepared-batch-test--view
                          left color hover caption reject
                          (lambda () (cl-incf updates)))))))
          ;; Accept one complete batch before rejecting a later publication.
          (etaf-batch
            (etaf-set-value left '(ch 1))
            (etaf-set-value color "#224466")
            (etaf-set-value hover "Accepted hover")
            (etaf-set-value caption
                            (etaf-prepared-batch-test--caption "Accepted " "[1]")))
          (should (= updates 1))
          (let* ((snapshot (etaf-runtime-snapshot runtime))
                 (revision (plist-get snapshot :revision))
                 (before (with-current-buffer buffer (buffer-string)))
                 (before-render (ebox-render (plist-get snapshot :input)))
                 (panel-props (etaf-runtime-host-props-for runtime 'prepared-panel))
                 (caption-props (etaf-runtime-host-props-for runtime 'prepared-caption))
                 (next-caption (etaf-prepared-batch-test--caption "Retried " "[2]")))
            (setq rejected t)
            (should-error
             (etaf-batch
               (etaf-set-value left '(ch 2))
               (etaf-set-value color "#664422")
               (etaf-set-value hover "Retried hover")
               (etaf-set-value caption next-caption))
             :type 'error)
            (should (equal '(ch 2) (etaf-value left)))
            (should (equal "#664422" (etaf-value color)))
            (should (equal "Retried hover" (etaf-value hover)))
            (should (equal-including-properties next-caption (etaf-value caption)))
            (should (= revision (plist-get (etaf-runtime-snapshot runtime) :revision)))
            (should (= updates 1))
            (should (equal-including-properties
                     before (with-current-buffer buffer (buffer-string))))
            (should (equal-including-properties
                     panel-props (etaf-runtime-host-props-for runtime 'prepared-panel)))
            (should (equal-including-properties
                     caption-props (etaf-runtime-host-props-for runtime 'prepared-caption)))
            (should
             (equal
              (etaf-prepared-batch-test--appearance before-render)
              (etaf-prepared-batch-test--appearance
               (ebox-render (plist-get (etaf-runtime-snapshot runtime) :input)))))
            (setq rejected nil)
            (should (= (1+ revision) (etaf-runtime-flush runtime)))
            (should (= updates 2))
            (etaf-prepared-batch-test--assert-fresh
             runtime buffer fresh left color hover caption reject)))
      (dolist (target (list buffer fresh))
        (when-let* ((runtime (etaf-runtime-for-buffer target)))
          (etaf-unmount runtime))
        (kill-buffer target)))))

(ert-deftest etaf-prepared-batch-retry-drains-lifecycle-writes ()
  "Explicit retry settles reactive writes made by accepted inline update hooks."
  (let ((buffer (generate-new-buffer " *etaf-prepared-batch-followup*"))
        (left (etaf-ref '(ch 0)))
        (color (etaf-ref "#112233"))
        (hover (etaf-ref "Hover"))
        (caption (etaf-ref "Value 0"))
        reject
        (updates 0))
    (unwind-protect
        (let ((runtime
               (etaf-runtime-for-buffer
                (etaf-mount
                 buffer
                 (etaf-prepared-batch-test--view
                  left color hover caption (lambda () reject)
                  (lambda ()
                    (cl-incf updates)
                    (etaf-set-value color "#445566")))))))
          (setq reject t)
          (should-error
           (etaf-batch
             (etaf-set-value left '(ch 1))
             (etaf-set-value caption "Value 1")))
          (should (= updates 0))
          (setq reject nil)
          (etaf-runtime-flush runtime)
          (should (= updates 1))
          (should (equal "#445566"
                         (plist-get (etaf-runtime-host-props-for
                                     runtime 'prepared-caption) :color))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-prepared-batch-hook-error-keeps-accepted-members ()
  "An updated hook error exposes accepted members without repeating the hook."
  (let ((buffer (generate-new-buffer " *etaf-prepared-batch-hook*"))
        (left (etaf-ref '(ch 0))) (color (etaf-ref "#112233"))
        (hover (etaf-ref "Hover")) (caption (etaf-ref "Value 0"))
        (updates 0) (fail t))
    (unwind-protect
        (let* ((runtime
                (etaf-runtime-for-buffer
                 (etaf-mount
                  buffer
                  (etaf-prepared-batch-test--view
                   left color hover caption (lambda () nil)
                   (lambda ()
                     (cl-incf updates)
                     (when fail (error "Accepted update hook failed")))))))
               (before (etaf-runtime-flush runtime))
               (condition
                (should-error
                 (etaf-batch
                   (etaf-set-value left '(ch 1))
                   (etaf-set-value color "#445566")
                   (etaf-set-value caption "Value 1")))))
          (should (eq 'error (car condition)))
          (should (equal "Accepted update hook failed" (cadr condition)))
          (should (= 1 updates))
          (should (= (1+ before) (etaf-runtime-flush runtime)))
          (should (= 1 updates))
          (should (equal '(ch 1) (plist-get (etaf-runtime-host-props-for
                                           runtime 'prepared-panel) :left)))
          (should (equal "#445566" (plist-get (etaf-runtime-host-props-for
                                             runtime 'prepared-caption) :color)))
          (should (string-match-p "Value 1" (with-current-buffer buffer (buffer-string))))
          (setq fail nil)
          (etaf-set-value caption "Value 2")
          (should (= 2 updates)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-prepared-batch-expands-demand-and-rebinds-after-structure ()
  "New primitive sources join atomic updates and refresh after structural work."
  (let ((buffer (generate-new-buffer " *etaf-demanded-cohort*"))
        (left (etaf-ref '(ch 0))) (color (etaf-ref "#112233"))
        (hover (etaf-ref "Hover")) (caption (etaf-ref "Value00"))
        (extra (etaf-ref nil)) rejected)
    (unwind-protect
        (let ((runtime
               (etaf-runtime-for-buffer
                (etaf-mount
                 buffer
                 (etaf-view
                  (box :position 'relative :width '(ch 24) :height '(lh 4)
                    (etaf-prepared-batch-test--panel
                     :left left :color color :hover hover :caption caption :z-index 1
                     :reject (lambda () rejected) :report #'ignore)
                    (expr (when (etaf-value extra) (etaf-view (box :position 'absolute :left '(ch 0) :top '(lh 3)
                                                       :width '(vw 10) :height '(lh 1) :z-index 0
                                                   (text "Extra")))))))))))
          (cl-labels
              ((assert-current ()
                 (should (equal (etaf-value left)
                                (plist-get (etaf-runtime-host-props-for runtime 'prepared-panel)
                                           :left)))
                 (should (equal (etaf-value color)
                                (plist-get (etaf-runtime-host-props-for runtime 'prepared-caption)
                                           :color)))
                 (with-current-buffer buffer
                   (should (string-match-p (regexp-quote (etaf-value caption))
                                           (buffer-substring-no-properties (point-min) (point-max)))))
                 (should
                  (equal
                   (etaf-prepared-batch-test--appearance
                    (with-current-buffer buffer (buffer-string)))
                   (etaf-prepared-batch-test--appearance
                    (ebox-render (plist-get (etaf-runtime-snapshot runtime) :input))))))
               (accept (function)
                 (let ((revision (etaf-runtime-generation runtime)))
                   (funcall function)
                   (should (= (1+ revision) (etaf-runtime-generation runtime)))
                   (ert-info ((format "Inputs %S; preparation %S"
                                      (list (etaf-value left) (etaf-value caption) (etaf-value color))
                                      (ebox-update-prepare-report buffer)))
                     (should (eq 'prepared-update
                                 (plist-get (ebox-buffer-update-report buffer) :projection-kind))))
                   (assert-current))))
            ;; Request one owner first, then introduce a new inline owner whose
            ;; first evaluation fails.  The written ref survives for retry.
            (accept (lambda () (etaf-set-value left '(ch 1))))
            (let ((before (with-current-buffer buffer (buffer-string)))
                  (revision (etaf-runtime-generation runtime)))
              (setq rejected t)
              (should-error (etaf-set-value caption "Value01"))
              (should (= revision (etaf-runtime-generation runtime)))
              (should (equal-including-properties before
                                                 (with-current-buffer buffer (buffer-string))))
              (setq rejected nil)
              (accept (lambda () (etaf-runtime-flush runtime))))
            ;; A second program on the same Text Host joins later; previously
            ;; demanded geometry and inline sources remain authoritative.
            (accept (lambda () (etaf-set-value color "#445566")))
            (accept (lambda ()
                      (etaf-batch
                        (etaf-set-value left '(ch 2))
                        (etaf-set-value color "#667788")
                        (etaf-set-value caption "Value02"))))
            (accept (lambda () (etaf-set-value caption "Value03")))
            (let ((token (ebox-update-binding-token buffer)))
              (etaf-set-value extra t)
              (should-not (eq token (ebox-update-binding-token buffer)))
              (with-current-buffer buffer
                (should (string-match-p "Extra"
                                        (buffer-substring-no-properties (point-min) (point-max))))))
            ;; The first real source notification after ordinary publication
            ;; prepares its current generation and publishes immediately.
            (accept (lambda () (etaf-set-value caption "Value04")))
            (accept (lambda ()
                      (etaf-batch
                        (etaf-set-value left '(ch 3))
                        (etaf-set-value color "#8899AA")
                        (etaf-set-value caption "Value05"))))
            ;; Separate text and interactive cohorts may alternate after a
            ;; mixed batch.  Each must retain current public source cells.
            (dotimes (index 3)
              (accept (lambda () (etaf-set-value caption (format "Separate%d" index))))
              (accept (lambda () (etaf-set-value left (list 'ch (+ 4 index))))))
            (let ((token (ebox-update-binding-token buffer)))
              (ebox-surface-update-buffer-viewport buffer 320 12)
              (should-not (eq token (ebox-update-binding-token buffer))))
            (let ((ebox-viewport-width 320) (ebox-viewport-height 12))
              (accept (lambda () (etaf-set-value caption "After viewport")))
              (accept (lambda ()
                        (etaf-batch
                          (etaf-set-value color "#AABBCC")
                          (etaf-set-value caption "Mixed viewport")))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-prepared-batch-couples-computed-paint-and-status ()
  "Computed sibling inputs share atomic updates while an independent clock stays live."
  (let* ((buffer (generate-new-buffer " *etaf-coupled-status*"))
         (selection (etaf-ref 0)) (clock (etaf-ref "12:00:00"))
         (paint (etaf-computed (lambda () (if (cl-oddp (etaf-value selection))
                                            "#AA2233" "#334455"))))
         (status (etaf-computed (lambda () (format "Selected %d" (etaf-value selection)))))
         rejected)
    (unwind-protect
        (let ((runtime
               (etaf-runtime-for-buffer
                (etaf-mount
                 buffer
                 (etaf-view
                  (box :position 'relative :width '(ch 32) :height '(lh 3)
                    (box :ref 'panel :position 'absolute :left '(ch 0) :top '(lh 0)
                         :z-index 1 :width '(ch 24) :height '(lh 2) :color (etaf-value paint)
                      (text (expr (let ((value (etaf-value status)))
                                    (when rejected (error "Rejected status"))
                                    value)))
                      (text (expr (etaf-value clock))))))))))
          (cl-labels ((accept (function)
                        (let ((revision (etaf-runtime-generation runtime)))
                          (funcall function)
                          (should (= (1+ revision) (etaf-runtime-generation runtime)))
                          (should (eq 'prepared-update
                                      (plist-get (ebox-buffer-update-report buffer) :projection-kind)))
                          (should (equal (etaf-value paint)
                                         (plist-get (etaf-runtime-host-props-for runtime 'panel) :color)))
                          (with-current-buffer buffer
                            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                              (ert-info ((format "Live %s; snapshot %s"
                                                 text
                                                 (substring-no-properties
                                                  (ebox-render (plist-get (etaf-runtime-snapshot runtime) :input)))))
                                (should (string-match-p (regexp-quote (etaf-value status)) text)))
                              (should (string-match-p (regexp-quote (etaf-value clock)) text)))))))
            (accept (lambda () (etaf-set-value selection 1)))
            (accept (lambda () (etaf-set-value clock "12:00:01")))
            (accept (lambda () (etaf-set-value selection 2)))
            (let ((before (with-current-buffer buffer (buffer-string)))
                  (revision (etaf-runtime-generation runtime)))
              (setq rejected t)
              (should-error (etaf-set-value selection 3))
              (should (= revision (etaf-runtime-generation runtime)))
              (should (equal-including-properties before
                                                 (with-current-buffer buffer (buffer-string))))
              (setq rejected nil)
              (accept (lambda () (etaf-runtime-flush runtime))))
            (accept (lambda () (etaf-set-value clock "12:00:02")))
            (accept (lambda () (etaf-set-value selection 4)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'etaf-prepared-batch-tests)
;;; etaf-prepared-batch-tests.el ends here
