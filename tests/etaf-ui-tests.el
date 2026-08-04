;;; etaf-ui-tests.el --- Official ETAF Component tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'etaf-ui)

(defun etaf-ui-test--buffer-text (buffer-name)
  "Return plain text currently published in BUFFER-NAME."
  (with-current-buffer buffer-name
    (string-trim-right (substring-no-properties (buffer-string)))))

(ert-deftest etaf-ui-button-dispatches-controlled-press ()
  "Render a button and dispatch its public Host callback."
  (let ((buffer-name " *etaf-ui-button-test*")
        (presses 0))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (etaf-button
             :label "Save"
             :ref 'save
             :on-press (lambda () (cl-incf presses)))))
          (should (string-match-p "Save" (etaf-ui-test--buffer-text buffer-name)))
          (etaf-dispatch-event
           (etaf-runtime-for-buffer buffer-name) 'save 'press)
          (should (= 1 presses)))
      (when-let ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-ui-checkbox-emits-next-value ()
  "Render a controlled checkbox and emit its next checked value."
  (let ((buffer-name " *etaf-ui-checkbox-test*")
        next)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (etaf-checkbox
             :checked nil
             :label "Done"
             :ref 'done
             :on-change (lambda (value) (setq next value)))))
          (should (string-match-p "☐ Done"
                                  (etaf-ui-test--buffer-text buffer-name)))
          (etaf-dispatch-event
           (etaf-runtime-for-buffer buffer-name)
           'done
           'press)
          (should (eq t next)))
      (when-let ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-ui-panel-projects-named-and-default-slots ()
  "Project panel header and body slots through the common slot model."
  (let ((rendered
         (string-trim-right
          (substring-no-properties
           (ebox-render
            (etaf-render
             (etaf-view
              (etaf-panel :title "Account"
               (slot :name 'header (text "Settings"))
               (text "Body")))))))))
    (dolist (label '("Account" "Settings" "Body"))
      (should (string-match-p (regexp-quote label) rendered)))))

(ert-deftest etaf-ui-data-grid-projects-reactive-controller ()
  "Render DataGrid rows and update them through the Data Controller."
  (let* ((source (etaf-data-memory-source
                  '((:id 1 :name "Ada") (:id 2 :name "Grace"))
                  :id-key :id))
         (controller (etaf-data-controller source :page-size 10 :auto-load t))
         (buffer-name " *etaf-ui-grid-test*"))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (etaf-data-grid
             :controller controller
             :columns '((:key :id :label "ID")
                        (:key :name :label "Name"))
             :row-key (lambda (row) (plist-get row :id)))))
          (should (string-match-p "Ada" (etaf-ui-test--buffer-text buffer-name)))
          (etaf-data-mutate controller 'insert '(:id 3 :name "Alan"))
          (should (string-match-p "Alan" (etaf-ui-test--buffer-text buffer-name))))
      (when-let ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (etaf-data-stop controller)
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-ui-data-grid-requires-stable-row-key ()
  "Reject a DataGrid that cannot identify retained rows."
  (let* ((source (etaf-data-memory-source
                  '((:id 1 :name "Ada"))
                  :id-key :id))
         (controller (etaf-data-controller source :page-size 10 :auto-load t))
         (buffer-name " *etaf-ui-grid-row-key-test*"))
    (unwind-protect
        (should-error
         (etaf-mount
          buffer-name
          (etaf-view
           (etaf-data-grid
            :controller controller
            :columns '((:key :id :label "ID"))))))
      (when-let ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (etaf-data-stop controller)
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-ui-data-grid-rejects-nil-row-key ()
  "Reject a DataGrid row-key function that returns no identity."
  (let* ((source (etaf-data-memory-source
                  '((:id 1 :name "Ada"))
                  :id-key :id))
         (controller (etaf-data-controller source :auto-load t))
         (buffer-name " *etaf-ui-grid-nil-row-key-test*"))
    (unwind-protect
        (should-error
         (etaf-mount
          buffer-name
          (etaf-view
           (etaf-data-grid
            :controller controller
            :columns '((:key :id :label "ID"))
            :row-key (lambda (_row) nil)))))
      (when-let ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (etaf-data-stop controller)
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

;;; etaf-ui-tests.el ends here
