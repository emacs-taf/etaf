;;; etaf-app-tests.el --- ETAF App workflow tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'etaf)

(defmacro etaf-app-test--with-files (bindings &rest body)
  "Create temporary App files named by BINDINGS and evaluate BODY."
  (declare (indent 1))
  `(let* ((directory (make-temp-file "etaf-app-test-" t))
          (source (expand-file-name "sample.el" directory))
          (static (expand-file-name "sample.etaf" directory))
          (style (expand-file-name "sample.ecss" directory))
          (artifact (expand-file-name "sample.etafc" directory))
          ,@bindings)
     (unwind-protect
         (progn
           (with-temp-file source
             (insert "(defun sample-view (color)\n"
                     "  (etaf-view\n"
                     "   (column :color color (text \"sample\"))))\n"))
           (with-temp-file static (insert "(sample :title \"Sample\")\n"))
           (with-temp-file style (insert "(styles (\"column\" :color red))\n"))
           ,@body)
       (when (file-directory-p directory)
         (delete-directory directory t)))))

(ert-deftest etaf-app-interactive-workflow-produces-current-artifact ()
  "The public App command writes and loads a current standalone artifact."
  (etaf-app-test--with-files ()
    (etaf-register-app "sample" :source source :static static :style style
                       :artifact artifact)
    (should (eq (plist-get (etaf-app-compile-status "sample") :status)
                'missing))
    (let ((status (etaf-compile-app "sample")))
      (should (file-readable-p artifact))
      (should (eq (plist-get status :status) 'current))
      (should (= (plist-get status :blueprints) 1)))
    (should (eq (plist-get (etaf-app-compile-status "sample") :status)
                'current))))

(ert-deftest etaf-app-artifact-becomes-stale-after-source-change ()
  "Changing any source hash rejects the previously compiled artifact."
  (etaf-app-test--with-files ()
    (etaf-register-app "sample-stale"
                       :source source :static static :style style
                       :artifact artifact)
    (etaf-compile-app "sample-stale")
    (with-temp-buffer
      (insert-file-contents source)
      (goto-char (point-max))
      (insert "\n;; changed\n")
      (write-region (point-min) (point-max) source nil 'silent))
    (should (eq (plist-get (etaf-app-compile-status "sample-stale") :status)
                'stale))))

(ert-deftest etaf-app-loaded-blueprint-is-consumed-at-runtime ()
  "Instantiation uses the manually compiled blueprint by artifact id."
  (etaf-app-test--with-files ()
    (etaf-register-app "sample-hit" :source source :static static :style style
                       :artifact artifact)
    (let* ((status (etaf-compile-app "sample-hit"))
           (entry (car (plist-get (plist-get status :artifact) :blueprints)))
           (blueprint (plist-get entry :blueprint))
           (before (plist-get (etaf-compiler-statistics) :artifact-hits))
           (view (etaf-compiler-instantiate
                  blueprint (vector (lambda () "purple")))))
      (should (etaf--view-node-p view))
      (should (> (plist-get (etaf-compiler-statistics) :artifact-hits) before)))))

(ert-deftest etaf-app-missing-artifact-warns-once-with-compile-command ()
  "Direct fallback tells an interactive user exactly how to compile the App."
  (etaf-app-test--with-files ()
    (etaf-register-app "sample-warning"
                       :source source :static static :style style
                       :artifact artifact)
    (let ((noninteractive nil)
          (etaf-app-warn-on-artifact-fallback t)
          warnings)
      (remhash "sample-warning" etaf-app--warning-state)
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type message &optional _level _buffer-name)
                   (push message warnings))))
        (should-not (etaf-app-load-artifact-or-warn "sample-warning"))
        (should-not (etaf-app-load-artifact-or-warn "sample-warning")))
      (should (= (length warnings) 1))
      (should (string-match-p "M-x etaf-compile-app" (car warnings))))))

(provide 'etaf-app-tests)
;;; etaf-app-tests.el ends here
