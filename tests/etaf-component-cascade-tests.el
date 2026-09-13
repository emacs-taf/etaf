;;; etaf-component-cascade-tests.el --- Shared component cascade -*- lexical-binding: t; -*-

;;; Commentary:
;; Component ownership supplies facts; provider selectors and cascade own values.

;;; Code:
(require 'ert)
(require 'etaf)
(require 'ebox)
(require 'ecss)

(defun etaf-component-cascade-test-color (text word)
  "Return WORD's visible foreground in TEXT using current buffer face remaps."
  (cl-labels ((foreground (face)
                (cond ((and (symbolp face) (facep face))
                       (or (cl-some #'foreground (cdr (assq face face-remapping-alist)))
                           (let ((value (face-attribute face :foreground nil t)))
                             (unless (memq value '(unspecified unspecified-fg)) value))))
                      ((and (listp face) (keywordp (car-safe face)))
                       (plist-get face :foreground))
                      ((listp face) (cl-some #'foreground face)))))
    (foreground (get-text-property (string-match word text) 'face text))))

(etaf-define-component etaf-component-cascade-test-selectors (&key class)
  :styles (("&" :color "#111111")
           ("text.target" :color "#222222")
           (".target" :color "#333333")
           ("text.target" :color "#444444")
           ("& > text.target + text[role=button]" :color "#555555"))
  :view (column (text :class (etaf-value class) "First")
                (text :role 'button "Second")))

(ert-deftest etaf-component-rules-share-specificity-structure-and-reactivity ()
  "Provider specificity, later rule order and sibling selectors survive class updates."
  (let* ((class (etaf-ref "target"))
         (view (etaf-view (etaf-component-cascade-test-selectors :class class)))
         (buffer (generate-new-buffer " *etaf-component-cascade*")))
    (unwind-protect
        (progn
          (etaf-mount buffer view)
          (dolist (value '("target" "other" "target"))
            (setf (etaf-value class) value)
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (let ((pure (ebox-render (etaf-render view))))
              (with-current-buffer buffer
                (dolist (word '("First" "Second"))
                  (should (equal (etaf-component-cascade-test-color pure word)
                                 (etaf-component-cascade-test-color (buffer-string) word)))))))
          (with-current-buffer buffer
            (should (equal "#444444" (etaf-component-cascade-test-color (buffer-string) "First")))
            (should (equal "#555555" (etaf-component-cascade-test-color (buffer-string) "Second")))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(etaf-define-component etaf-component-cascade-test-forest ()
  :styles (("&" :color "#ff0000") ("text" :color "#0000ff"))
  :view (fragment (text "One") (text "Two")))

(ert-deftest etaf-component-rules-mark-every-transparent-root ()
  "Every forest Host is a scope root; ordinary descendant rules exclude roots."
  (let* ((view (etaf-view (etaf-component-cascade-test-forest)))
         (buffer (generate-new-buffer " *etaf-forest-cascade*")))
    (unwind-protect
        (progn
          (etaf-mount buffer view)
          (dolist (text (list (ebox-render (etaf-render view))
                              (with-current-buffer buffer (buffer-string))))
            (dolist (word '("One" "Two"))
              (should (equal "#ff0000" (etaf-component-cascade-test-color text word))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(etaf-define-component etaf-component-cascade-test-child ()
  :styles (("text" :color "#0000ff"))
  :view (column (slot) (slot :name 'footer (text "Fallback"))))

(etaf-define-component etaf-component-cascade-test-parent (&key palette label)
  :setup (etaf-theme-provide palette)
  :styles (("text" :color (etaf-theme-token :accent "#ff0000")))
  :view (fragment
         (column (text "Alpha")
                 (etaf-component-cascade-test-child
                  (expr (etaf-view (text (expr (etaf-value label)))))))
         (column (text "Beta"))))

(ert-deftest etaf-component-rules-retain-slot-ownership-across-theme-updates ()
  "Rule revisions reach retained caller content without styling child fallback."
  (let ((palette (etaf-ref '(:accent "#ff0000")))
        (label (etaf-ref "Slot"))
        (buffer (generate-new-buffer " *etaf-slot-cascade*")))
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-view (etaf-component-cascade-test-parent
                                        :palette palette :label label)))
          (dolist (color '("#ff0000" "#00ff00"))
            (setf (etaf-value palette) (list :accent color))
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (with-current-buffer buffer
              (dolist (word '("Alpha" "Beta" "Slot"))
                (should (equal color (etaf-component-cascade-test-color (buffer-string) word))))
              (should (equal "#0000ff" (etaf-component-cascade-test-color (buffer-string) "Fallback")))))
          (setf (etaf-value label) "Changed")
          (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
          (with-current-buffer buffer
            (should (equal "#00ff00" (etaf-component-cascade-test-color (buffer-string) "Changed"))))
          (let ((before (with-current-buffer buffer (buffer-string))))
            (should-error (setf (etaf-value palette) '(:accent 42)))
            (should (equal-including-properties before (with-current-buffer buffer (buffer-string))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(etaf-define-component etaf-component-cascade-test-raw-child ()
  :styles (("text" :color "#0000ff"))
  :render (etaf-node 'column nil
                     (append (etaf-current-slot 'default)
                             (list (etaf-node 'text nil '("Fallback"))))))

(etaf-define-component etaf-component-cascade-test-raw-parent ()
  :styles (("text" :color "#ff0000"))
  :view (column (etaf-component-cascade-test-raw-child (text "Caller"))))

(ert-deftest etaf-component-rules-preserve-code-slot-author ()
  "Public code slot accessors retain caller ownership when children are recomposed."
  (let* ((view (etaf-view (etaf-component-cascade-test-raw-parent)))
         (buffer (generate-new-buffer " *etaf-code-slot-cascade*")))
    (unwind-protect
        (progn
          (etaf-mount buffer view)
          (dolist (text (list (ebox-render (etaf-render view))
                              (with-current-buffer buffer (buffer-string))))
            (should (equal "#ff0000" (etaf-component-cascade-test-color text "Caller")))
            (should (equal "#0000ff" (etaf-component-cascade-test-color text "Fallback")))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(etaf-define-component etaf-component-cascade-test-values ()
  :view (column (text :class "important" :color "#0000ff" "Important")
                (text "Variable")))

(ert-deftest etaf-component-rules-preserve-importance-and-custom-properties ()
  "Author importance beats normal inline values and custom properties inherit."
  (let ((buffer (generate-new-buffer " *etaf-rule-values*")))
    (unwind-protect
        (progn
          (etaf-component-set-styles
           'etaf-component-cascade-test-values
           (list (list "&" '--accent (etaf-theme-token :accent "#00aa00"))
                 (list "text" :color (ecss-var '--accent "#000000"))
                 (list ".important" :color (ecss-important "#ff0000"))))
          (let ((view (etaf-view (etaf-component-cascade-test-values))))
            (etaf-mount buffer view)
            (dolist (text (list (ebox-render (etaf-render view))
                                (with-current-buffer buffer (buffer-string))))
              (should (equal "#ff0000" (etaf-component-cascade-test-color text "Important")))
              (should (equal "#00aa00" (etaf-component-cascade-test-color text "Variable"))))))
      (etaf-component-set-styles 'etaf-component-cascade-test-values nil)
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-component-cascade-tests)
;;; etaf-component-cascade-tests.el ends here
