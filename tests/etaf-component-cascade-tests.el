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

(etaf-define-component etaf-component-cascade-test-disabled (&key disabled)
  :styles (("&" :color "#111111")
           ("&:disabled" :color "#999999"))
  :view (text :ref 'control :disabled (etaf-value disabled) "Control"))

(ert-deftest etaf-disabled-state-shares-provider-cascade ()
  "Reactive disabled input gives pure and mounted component rules the same state."
  (let* ((disabled (etaf-ref nil))
         (view (etaf-view (etaf-component-cascade-test-disabled :disabled disabled)))
         (buffer (generate-new-buffer " *etaf-disabled-cascade*")))
    (unwind-protect
        (progn
          (etaf-mount buffer view)
          (dolist (value '(nil t nil t))
            (setf (etaf-value disabled) value)
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (with-current-buffer buffer
              (dolist (text (list (buffer-string) (ebox-render (etaf-render view))))
                (should (equal (if value "#999999" "#111111")
                               (etaf-component-cascade-test-color text "Control")))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(etaf-define-component etaf-component-cascade-test-focus (&key label hidden)
  :styles (("&" :color "#111111")
           ("&:focus" :color "#ff0000")
           ("&.concealed" :visibility hidden))
  :view (text :ref 'control :tab-index 0
              :class (and (etaf-value hidden) 'concealed)
              (expr (etaf-value label))))

(ert-deftest etaf-component-focus-rules-follow-shared-publication ()
  "Component focus rules share Ebox focus, reactive publication and pure isolation."
  (let* ((label (etaf-ref "Control")) (hidden (etaf-ref nil))
         (view (etaf-view (etaf-component-cascade-test-focus :label label :hidden hidden)))
         (buffer (generate-new-buffer " *etaf-focus-cascade*")))
    (unwind-protect
        (progn
          (etaf-mount buffer view)
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-focus runtime 'control)
            (with-current-buffer buffer
              (should (= 1 (length (ebox-selector-query-buffer buffer ":focus"))))
              (should (equal "#ff0000" (etaf-component-cascade-test-color (buffer-string) "Control")))
              (should (equal "#111111" (etaf-component-cascade-test-color
                                        (ebox-render (etaf-render view)) "Control"))))
            (setf (etaf-value label) "Updated")
            (etaf-runtime-flush runtime)
            (should (eq (etaf-focused-host-ref runtime) 'control))
            (with-current-buffer buffer
              (should (equal "#ff0000" (etaf-component-cascade-test-color (buffer-string) "Updated"))))
            (setf (etaf-value hidden) t)
            (etaf-runtime-flush runtime)
            (should-not (etaf-focused-host-ref runtime))
            (should-not (ebox-selector-query-buffer buffer ":focus"))
            (setf (etaf-value hidden) nil)
            (etaf-runtime-flush runtime)
            (ebox-focus-first buffer)
            (should (eq (etaf-focused-host-ref runtime) 'control))
            (etaf-unmount runtime)
            (should-not (ebox-focused-host-ref buffer))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(etaf-define-component etaf-component-cascade-test-active (&key count)
  :styles (("&" :color "#111111")
           ("&:active" :color "#ff0000"))
  :view (text :ref 'control
              :on-press (lambda ()
                          (should-not (ebox-selector-query-buffer (current-buffer) ":active"))
                          (cl-incf (etaf-value count)))
              (expr (format "Press %d" (etaf-value count)))))

(ert-deftest etaf-component-active-rules-share-native-press-lifecycle ()
  "Ebox publishes scoped pressed paint and releases before one reactive callback."
  (let* ((count (etaf-ref 0))
         (view (etaf-view (etaf-component-cascade-test-active :count count)))
         (buffer (generate-new-buffer " *etaf-active-cascade*"))
         (other (generate-new-buffer " *etaf-active-isolation*")))
    (unwind-protect
        (save-window-excursion
          (set-window-buffer (selected-window) buffer)
          (etaf-mount buffer view)
          (etaf-mount other view)
          (with-current-buffer buffer
            (let* ((position (etaf-host-ref-position (etaf-runtime-for-buffer buffer) 'control))
                   (press (list 'down-mouse-1 (list (selected-window) position '(1 . 0) 0)))
                   (release (list 'mouse-1 (list (selected-window) position '(1 . 0) 1)))
                   (command (key-binding (vector press) nil nil position)))
              (cl-letf (((symbol-function 'read-event)
                         (lambda (&rest _)
                           (should (= 1 (length (ebox-selector-query-buffer buffer ":active"))))
                           (should (equal "#ff0000" (etaf-component-cascade-test-color (buffer-string) "Press")))
                           (should-not (ebox-selector-query-buffer other ":active"))
                           (should (equal "#111111" (etaf-component-cascade-test-color
                                                     (ebox-render (etaf-render view)) "Press")))
                           (should (= 0 (etaf-value count)))
                           release)))
                (funcall command press)))
            (should (= 1 (etaf-value count)))
            (should (string-match-p "Press 1" (buffer-string)))
            (should-not (ebox-selector-query-buffer buffer ":active"))
            (should (equal "#111111" (etaf-component-cascade-test-color (buffer-string) "Press")))))
      (dolist (target (list buffer other))
        (when-let* ((runtime (etaf-runtime-for-buffer target))) (etaf-unmount runtime))
        (kill-buffer target)))))

(provide 'etaf-component-cascade-tests)
;;; etaf-component-cascade-tests.el ends here
