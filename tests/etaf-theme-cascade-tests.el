;;; etaf-theme-cascade-tests.el --- Theme origin behavior -*- lexical-binding: t; -*-

;;; Commentary:
;; Theme defaults participate in the provider cascade and retained publication.

;;; Code:
(require 'ert)
(require 'etaf)
(require 'ebox)
(require 'ecss)

(etaf-define-component etaf-theme-cascade-test-shell (&key palette color)
  :setup (etaf-theme-provide palette)
  :view (column (text :color (etaf-value color) "Theme")))

(defun etaf-theme-cascade-test-foreground (text)
  "Return the visible foreground at Theme in TEXT."
  (cl-labels ((foreground (face)
                (cond ((and (symbolp face) (facep face))
                       (or (cl-some #'foreground (cdr (assq face face-remapping-alist)))
                           (let ((value (face-attribute face :foreground nil t)))
                             (unless (memq value '(unspecified unspecified-fg)) value))))
                      ((and (listp face) (keywordp (car-safe face)))
                       (plist-get face :foreground))
                      ((listp face) (cl-some #'foreground face)))))
    (foreground (get-text-property (string-match "Theme" text) 'face text))))

(ert-deftest etaf-theme-defaults-use-ecss-origin-on-retained-updates ()
  "UA importance and fallback survive Theme and Host property updates."
  (let ((palette (etaf-ref nil))
        (color (etaf-ref "#112233"))
        (buffer (generate-new-buffer " *etaf-theme-cascade*")))
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-view (etaf-theme-cascade-test-shell
                                        :palette palette :color color)))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (dolist (case (list (list '(:color "#aabbcc") "#112233" "#112233")
                               (list (list :color (ecss-important "#ff0000"))
                                     (ecss-important "#0000ff") "#ff0000")
                               (list '(:color "#aabbcc") nil "#aabbcc")
                               (list nil "#112233" "#112233")))
              (setf (etaf-value palette) (car case)
                    (etaf-value color) (cadr case))
              (etaf-runtime-flush runtime)
              (should (equal (nth 2 case) (with-current-buffer buffer
                                          (etaf-theme-cascade-test-foreground (buffer-string))))))
            (let ((before (with-current-buffer buffer (buffer-string))))
              (should-error (setf (etaf-value palette) '(:width invalid)))
              (should (equal-including-properties before
                                                  (with-current-buffer buffer (buffer-string)))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(etaf-define-component etaf-theme-cascade-test-static ()
  :setup (etaf-theme-provide (list :color (ecss-important "#ff0000")))
  :view (text :color (ecss-important "#0000ff") "Theme"))

(ert-deftest etaf-theme-defaults-match-provider-ua-origin ()
  "Mounted Theme defaults match provider UA importance over inline importance."
  (let* ((view (etaf-view (etaf-theme-cascade-test-static)))
         (buffer (generate-new-buffer " *etaf-theme-origin*")))
    (unwind-protect
        (progn
          (let* ((scope (ebox-style-scope-create
                         (list (list "&" :color (ecss-important "#ff0000"))) :origin 'ua))
                 (builder (ebox-source-builder-create))
                 (declarations (ebox-style-compile-declarations
                                (list :color (ecss-important "#0000ff"))))
                 (node (ebox-text-create
                        :value "Theme"
                        :owned-facts (ebox-canonical-facts-from-declarations 'text declarations)
                        :source-handle (ebox-source-builder-bind
                                        builder :declarations declarations
                                        :ecss-scopes (list scope) :ecss-scope-roots (list scope))))
                 (input (ebox-canonical-input-create (list node) (ebox-source-builder-finish builder))))
            (should (equal "#ff0000" (etaf-theme-cascade-test-foreground (ebox-render input)))))
          (etaf-mount buffer view)
          (should (equal "#ff0000" (with-current-buffer buffer
                                    (etaf-theme-cascade-test-foreground (buffer-string))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(etaf-define-component etaf-theme-cascade-test-layout (&key palette)
  :setup (etaf-theme-provide palette)
  :view (column (box "Theme") (box "Other")))

(defun etaf-theme-cascade-test-layout-output (buffer)
  "Return BUFFER's visible text and display geometry."
  (with-current-buffer buffer
    (let ((text (buffer-string)))
      (cons (substring-no-properties text)
            (cl-loop for position below (length text)
                     collect (get-text-property position 'display text))))))

(ert-deftest etaf-theme-defaults-update-empty-layout-and-isolate-apps ()
  "Initially empty Theme defaults gain geometry, matching a fresh isolated mount."
  (let* ((palette (etaf-ref nil))
         (buffer (generate-new-buffer " *etaf-theme-layout*"))
         (isolated (generate-new-buffer " *etaf-theme-isolated*")))
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-view (etaf-theme-cascade-test-layout :palette palette)))
          (etaf-mount isolated (etaf-view (etaf-theme-cascade-test-layout :palette nil)))
          (let ((original (with-current-buffer isolated (buffer-string))))
            (dolist (defaults (list (list :item-gap (ecss-important '(lh 2)))
                                   '(:item-gap (lh 1)) nil))
              (setf (etaf-value palette) defaults)
              (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
              (let ((fresh (generate-new-buffer " *etaf-theme-fresh*")))
                (unwind-protect
                    (progn
                      (etaf-mount fresh (etaf-view (etaf-theme-cascade-test-layout :palette defaults)))
                      (should (equal (etaf-theme-cascade-test-layout-output buffer)
                                     (etaf-theme-cascade-test-layout-output fresh))))
                  (when-let* ((runtime (etaf-runtime-for-buffer fresh))) (etaf-unmount runtime))
                  (kill-buffer fresh)))
              (should (equal-including-properties original
                                                  (with-current-buffer isolated (buffer-string)))))))
      (dolist (target (list buffer isolated))
        (when-let* ((runtime (etaf-runtime-for-buffer target))) (etaf-unmount runtime))
        (kill-buffer target)))))

(etaf-define-component etaf-theme-cascade-test-token (&key palette)
  :setup (etaf-theme-provide palette)
  :view (column (text :color (etaf-theme-token :foreground "#112233") "Theme")))

(ert-deftest etaf-theme-unused-tokens-retain-publication ()
  "A palette edit outside consumed tokens preserves the committed publication."
  (let ((palette (etaf-ref '(:foreground "#112233" :unused "#000000")))
        (buffer (generate-new-buffer " *etaf-theme-projection*")))
    (unwind-protect
        (let* ((_mount (etaf-mount buffer (etaf-view
                                          (etaf-theme-cascade-test-token :palette palette))))
               (runtime (etaf-runtime-for-buffer buffer))
               (generation (etaf-runtime-generation runtime)))
          (setf (etaf-value palette) '(:foreground "#112233" :unused "#ffffff"))
          (should (= generation (etaf-runtime-generation runtime)))
          (setf (etaf-value palette) '(:foreground "#445566" :unused "#ffffff"))
          (should (> (etaf-runtime-generation runtime) generation))
          (should (equal "#445566" (with-current-buffer buffer
                                    (etaf-theme-cascade-test-foreground (buffer-string))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(etaf-define-component etaf-theme-cascade-test-dynamic-token (&key palette selected)
  :setup (etaf-theme-provide palette)
  :view
  (column
    (text :ref 'selected-theme-token
          :color (etaf-theme-token (etaf-value selected)) "Theme")
    (text :color (etaf-theme-token :second) "Other")))

(ert-deftest etaf-theme-dynamic-token-switch-observes-selected-value ()
  "Switching a prepared token retains updates of the newly selected key."
  (let ((palette (etaf-ref '(:first "#112233" :second "#445566")))
        (selected (etaf-ref :first))
        (buffer (generate-new-buffer " *etaf-theme-dynamic*")))
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-view (etaf-theme-cascade-test-dynamic-token
                                        :palette palette :selected selected)))
          (setf (etaf-value selected) :second)
          (should (equal "#445566" (with-current-buffer buffer
                                    (etaf-theme-cascade-test-foreground (buffer-string)))))
          (setf (etaf-value palette) '(:first "#112233" :second "#778899"))
          (should (equal "#778899" (with-current-buffer buffer
                                    (etaf-theme-cascade-test-foreground (buffer-string))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-theme-source-replacement-retires-old-provider ()
  "A replacement provider reads its own palette and retires the old source."
  (let ((first (etaf-ref '(:foreground "#112233")))
        (second (etaf-ref '(:foreground "#445566")))
        (replace (etaf-ref nil))
        (buffer (generate-new-buffer " *etaf-theme-replacement*")))
    (unwind-protect
        (progn
          (etaf-mount buffer
            (etaf-view
             (column
               (expr (if (etaf-value replace)
                         (etaf-view (etaf-theme-cascade-test-token :key 'second :palette second))
                       (etaf-view (etaf-theme-cascade-test-token :key 'first :palette first)))))))
          (setf (etaf-value replace) t)
          (should (equal "#445566" (with-current-buffer buffer
                                    (etaf-theme-cascade-test-foreground (buffer-string)))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (generation (etaf-runtime-generation runtime)))
            (setf (etaf-value first) '(:foreground "#aabbcc"))
            (should (= generation (etaf-runtime-generation runtime))))
          (setf (etaf-value second) '(:foreground "#778899"))
          (should (equal "#778899" (with-current-buffer buffer
                                    (etaf-theme-cascade-test-foreground (buffer-string))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(etaf-define-component etaf-theme-cascade-test-transformed (&key palette transform)
  :setup (etaf-theme-provide palette)
  :view (text :color (etaf-theme-token :foreground "#112233" transform) "Theme"))

(ert-deftest etaf-theme-projection-transform-failure-retries-written-state ()
  "A failing token transform retains publication and retries current Theme data."
  (let ((palette (etaf-ref '(:foreground "#112233")))
        (reject nil)
        (buffer (generate-new-buffer " *etaf-theme-retry*")))
    (unwind-protect
        (progn
          (etaf-mount buffer
            (etaf-view (etaf-theme-cascade-test-transformed
                        :palette palette
                        :transform (lambda (color)
                                     (when reject (error "Theme value unavailable"))
                                     color))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (generation (etaf-runtime-generation runtime)))
            (setq reject t)
            (should-error (setf (etaf-value palette) '(:foreground "#445566")))
            (should (= generation (etaf-runtime-generation runtime)))
            (should (equal "#112233" (with-current-buffer buffer
                                      (etaf-theme-cascade-test-foreground (buffer-string)))))
            (setq reject nil)
            (etaf-runtime-flush runtime)
            (should (equal "#445566" (with-current-buffer buffer
                                      (etaf-theme-cascade-test-foreground (buffer-string)))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(defun etaf-theme-cascade-test-context-transform (_width)
  "Return the current consumer's public Context width."
  (etaf-value (etaf-inject 'theme-projection-width)))

(etaf-define-component etaf-theme-cascade-test-contextual (&key palette width target)
  :setup (progn (etaf-theme-provide palette)
                (etaf-provide 'theme-projection-width width))
  :view (box :ref target
             :width (etaf-theme-token :extent nil
                                     #'etaf-theme-cascade-test-context-transform)
          "Theme"))

(ert-deftest etaf-theme-contextual-transforms-retain-consumer-context ()
  "The same Theme and transform preserve distinct consuming Context values."
  (let ((palette (etaf-ref '(:extent (ch 1))))
        (narrow (etaf-ref '(ch 6)))
        (wide (etaf-ref '(ch 10)))
        (buffer (generate-new-buffer " *etaf-theme-context*")))
    (unwind-protect
        (let ((view
               (etaf-view
             (column
               (etaf-theme-cascade-test-contextual
                 :palette palette :width narrow :target 'narrow)
               (etaf-theme-cascade-test-contextual
                 :palette palette :width wide :target 'wide)))))
          (etaf-mount buffer view)
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (dolist (value '(2 3))
              (setf (etaf-value palette) (list :extent (list 'ch value)))
              (should (equal '(ch 6) (plist-get (etaf-runtime-host-props-for runtime 'narrow) :width)))
              (should (equal '(ch 10) (plist-get (etaf-runtime-host-props-for runtime 'wide) :width))))
            (setf (etaf-value narrow) '(ch 8))
            (should (equal '(ch 8) (plist-get (etaf-runtime-host-props-for runtime 'narrow) :width)))
            (should (equal '(ch 10) (plist-get (etaf-runtime-host-props-for runtime 'wide) :width)))
            (etaf-unmount runtime))
          (setf (etaf-value narrow) '(ch 9)
                (etaf-value wide) '(ch 12)
                (etaf-value palette) '(:extent (ch 4)))
          (etaf-mount buffer view)
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (should (equal '(ch 9) (plist-get (etaf-runtime-host-props-for runtime 'narrow) :width)))
            (should (equal '(ch 12) (plist-get (etaf-runtime-host-props-for runtime 'wide) :width)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-theme-cascade-tests)
;;; etaf-theme-cascade-tests.el ends here
