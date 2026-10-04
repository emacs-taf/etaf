;;; etaf-runtime-content-tests.el --- Incremental Host content boundary -*- lexical-binding: t; -*-

(require 'ert)
(require 'etaf)
(require 'ebox)

(ert-deftest etaf-runtime-update-host-content-replaces-retained-text ()
  "The ETAF incremental Host content boundary replaces one retained text.
A scoped replacement changes only the addressed Host, and the following
ordinary publication keeps the caller's state authoritative."
  (let ((buffer-name " *etaf-runtime-content-boundary*")
        (label (etaf-ref "0:00"))
        (meter (etaf-ref "0/10")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (flex :flex-direction 'column
                  (box :id "clock" :ref 'clock
                       (text (expr (etaf-value label))))
                  (box :id "meter" :ref 'meter
                       (text (expr (etaf-value meter))))
                  (box :id "title" :ref 'title (text "song")))))
          (let ((runtime (etaf-runtime-for-buffer buffer-name)))
            (should (eq t
                        (etaf-runtime-update-host-content runtime 'clock "0:01")))
            (with-current-buffer buffer-name
              (should (string-match-p "0:01" (buffer-string)))
              (should-not (string-match-p "0:00" (buffer-string)))
              (should (string-match-p "0/10" (buffer-string))))
            (should (eq t
                        (etaf-runtime-update-host-contents
                         runtime '((clock . "0:02") (meter . "2/10")))))
            (with-current-buffer buffer-name
              (should (string-match-p "0:02" (buffer-string)))
              (should (string-match-p "2/10" (buffer-string))))
            (setf (etaf-value label) "0:09")
            (etaf-runtime-flush runtime)
            (with-current-buffer buffer-name
              (should (string-match-p "0:09" (buffer-string)))
              (should-not (string-match-p "0:02" (buffer-string))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-runtime-update-host-content-rejects-invalid-targets ()
  "Invalid Host content targets signal `etaf-runtime-error' before any change.
A rejected batch leaves the committed text untouched."
  (let ((buffer-name " *etaf-runtime-content-errors*"))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (flex :flex-direction 'column
                  (box :id "clock" :ref 'clock (text "0:00")))))
          (let ((runtime (etaf-runtime-for-buffer buffer-name)))
            (should-error (etaf-runtime-update-host-content runtime 'missing "0:01")
                          :type 'etaf-runtime-error)
            (should-error (etaf-runtime-update-host-content runtime 'clock 5)
                          :type 'etaf-runtime-error)
            (should-error (etaf-runtime-update-host-contents
                           runtime '((clock . "0:01") (missing . "x")))
                          :type 'etaf-runtime-error)
            (with-current-buffer buffer-name
              (should (string-match-p "0:00" (buffer-string)))
              (should-not (string-match-p "0:01" (buffer-string))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-runtime-content-fixed-canvas-keeps-batches-and-rebinds ()
  "Fixed content cohorts preserve rich text, atomic rejection and resize rebinding."
  (let ((buffer (generate-new-buffer " *etaf-content-canvas*")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (box :position 'relative :width '(ch 60) :height '(lh 12) :background-color "black"
              (box :position 'absolute :left '(ch 2) :top '(lh 1) :z-index 0
                   :width '(ch 30) :height '(lh 5) :wrap-mode 'none :overflow 'hidden
                   :background-color "black"
                (text :id 'body :ref 'body "initial"))
              (box :position 'absolute :left '(ch 2) :top '(lh 8) :z-index 0
                   :width '(ch 30) :height '(lh 1) :background-color "black"
                (text :id 'status :ref 'status "ready"))))
           '(:viewport-width 600 :viewport-height 12))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (dotimes (index 4)
              (let ((value (propertize (format "第 %d 行\ncode" index) 'face 'bold)))
                (should (etaf-runtime-update-host-content runtime 'body value))
                (with-current-buffer buffer
                  (should (string-match-p (format "第 %d 行" index) (buffer-string)))
                  (should (string-match-p "ready" (buffer-string))))))
            (etaf-runtime-update-host-contents runtime '((body . "batched") (status . "done")))
            (should-error (etaf-runtime-update-host-contents runtime '((body . "lost") (missing . "bad")))
                          :type 'etaf-runtime-error)
            (with-current-buffer buffer
              (should (string-match-p "batched" (buffer-string)))
              (should-not (string-match-p "lost" (buffer-string))))
            (etaf-runtime-refit runtime 650 14)
            (should (etaf-runtime-update-host-content runtime 'body "after resize"))
            (with-current-buffer buffer
              (should (string-match-p "after resize" (buffer-string)))
              (should (string-match-p "done" (buffer-string))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-runtime-update-host-content-publishes-image-cells ()
  "An image object is published as a Host content cell.
The retained update keeps the caller's display specification in the buffer,
so a fixed-size Host can show a new frame per update, and a value that is
neither a string nor an image still signals `etaf-runtime-error'."
  (let ((buffer-name " *etaf-runtime-content-image*"))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (flex :flex-direction 'column
                  (box :id "canvas" :ref 'canvas :width '(ch 16) :height '(lh 4)
                       :overflow 'hidden
                       (text " ")))))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (image (create-image "fake-frame-data" 'png t)))
            (should (eq t (etaf-runtime-update-host-content runtime 'canvas image)))
            (with-current-buffer buffer-name
              (should (equal image (get-text-property 0 'display (buffer-string)))))
            (should-error (etaf-runtime-update-host-content runtime 'canvas 5)
                          :type 'etaf-runtime-error)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-runtime-content-keeps-image-slices-across-mixed-updates ()
  "Changing sliced images preserves every row and neighbouring controls."
  (let ((buffer (generate-new-buffer " *etaf-sliced-content*")))
    (unwind-protect
        (progn
          (etaf-mount buffer
            (etaf-view
             (box :position 'relative :width '(ch 40) :height '(lh 8)
               (box :position 'absolute :left '(ch 0) :top '(lh 0) :z-index 0
                    :width '(ch 16) :height '(lh 3) :overflow 'hidden :wrap-mode 'none
                 (text :ref 'picture :id 'picture " "))
               (box :position 'absolute :left '(ch 0) :top '(lh 5) :z-index 0
                    :width '(ch 16) :height '(lh 1)
                 (text :ref 'caption :id 'caption "ready"))))
            '(:viewport-width 400 :viewport-height 8))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (dotimes (index 5)
              (let* ((image (create-image (format "frame-%d" index) 'png t))
                     (value (mapconcat
                             (lambda (row)
                               (propertize " " 'display
                                           (list (list 'slice 0 row 8 1) image)))
                             '(0 1 2) "\n")))
                (etaf-runtime-update-host-content runtime 'picture value)
                (etaf-runtime-update-host-content runtime 'caption (format "frame %d" index))
                (with-current-buffer buffer
                  (let ((position (point-min)) (count 0))
                    (while (< position (point-max))
                      (let ((display (get-text-property position 'display)))
                        (when (and (consp display) (consp (car display))
                                   (eq (caar display) 'slice))
                          (should (equal (cadr display) image))
                          (setq count (1+ count))))
                      (setq position (next-single-property-change position 'display nil (point-max))))
                    (should (= count 3)))
                  (should (string-match-p (format "frame %d" index)
                                          (buffer-substring-no-properties (point-min) (point-max))))))
              (when (= index 2) (etaf-runtime-refit runtime 450 9)))
            (should-error (etaf-runtime-update-host-contents
                           runtime '((caption . "lost") (missing . "bad")))
                          :type 'etaf-runtime-error)
            (with-current-buffer buffer
              (should (string-match-p "frame 4" (buffer-substring-no-properties (point-min) (point-max)))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'etaf-runtime-content-tests)
;;; etaf-runtime-content-tests.el ends here
