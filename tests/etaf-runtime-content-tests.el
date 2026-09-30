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
            (etaf-runtime-update-host-content runtime 'clock "0:01")
            (with-current-buffer buffer-name
              (should (string-match-p "0:01" (buffer-string)))
              (should-not (string-match-p "0:00" (buffer-string)))
              (should (string-match-p "0/10" (buffer-string))))
            (etaf-runtime-update-host-contents
             runtime '((clock . "0:02") (meter . "2/10")))
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

(provide 'etaf-runtime-content-tests)
;;; etaf-runtime-content-tests.el ends here
