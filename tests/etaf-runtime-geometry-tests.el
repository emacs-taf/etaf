;;; etaf-runtime-geometry-tests.el --- Incremental Host geometry boundary -*- lexical-binding: t; -*-

(require 'ert)
(require 'etaf)
(require 'ebox)

(ert-deftest etaf-runtime-update-host-geometry-uses-retained-provider-region ()
  "A controlled Host geometry update changes the retained Ebox region atomically."
  (let ((buffer-name " *etaf-runtime-geometry-boundary*"))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (box :id "panel" :ref 'panel :position 'absolute
                 :left '(px 2) :top '(lh 1) :width '(px 40) :height '(lh 3)
                 "Panel")))
          (let ((runtime (etaf-runtime-for-buffer buffer-name)))
            (should
             (listp
              (etaf-runtime-update-host-geometry
               runtime 'panel
               :left '(px 12) :top '(lh 4)
               :width '(px 64) :height '(lh 5) :z-index 3)))
            (with-current-buffer buffer-name
              (let ((geometry (ebox-region-geometry "panel")))
                (should (equal '(px 12) (plist-get geometry :left)))
                (should (equal '(lh 4) (plist-get geometry :top)))
                (should (equal '(px 64) (plist-get geometry :width)))
                (should (equal '(lh 5) (plist-get geometry :height)))
                (should (= 3 (plist-get geometry :z-index)))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(provide 'etaf-runtime-geometry-tests)
;;; etaf-runtime-geometry-tests.el ends here
