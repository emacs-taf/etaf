;;; etaf-playground-tests.el --- ETAF playground tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'etaf-playground)

(ert-deftest etaf-playground-mounts-and-dispatches-core-example ()
  "Mount the public playground and update its retained counter."
  (let ((buffer-name " *etaf-playground-test*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-playground-view))
          (with-current-buffer buffer-name
            (should (string-match-p "ETAF Playground" (buffer-string)))
            (should (string-match-p "Count: 0" (buffer-string))))
          (let ((runtime (etaf-runtime-for-buffer buffer-name)))
            (etaf-dispatch-event runtime 'increment 'press)
            (with-current-buffer buffer-name
              (should (string-match-p "Count: 1" (buffer-string))))))
      (when-let ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-playground-ui-keeps-the-catalog-optional ()
  "Mount the optional UI catalog through the playground public entry point."
  (require 'etaf-ui)
  (let ((buffer-name " *etaf-playground-ui-test*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-playground-ui-view))
          (with-current-buffer buffer-name
            (let ((contents (buffer-string)))
              (should (string-match-p "Official Components" contents))
              (should (string-match-p "A public Component" contents))
              (should (string-match-p "Controlled checkbox" contents)))))
      (when-let ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

;;; etaf-playground-tests.el ends here
