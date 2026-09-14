;;; etaf-native-affordance-tests.el --- Ebox native affordance integration -*- lexical-binding: t; -*-

;;; Commentary:
;; Observe the public View API's native text properties and activation.

;;; Code:
(require 'ert)
(require 'etaf)
(require 'ebox)

(defun etaf-native-affordance-test--properties (text word)
  "Read native affordances on WORD in rendered TEXT."
  (let ((position (string-match (regexp-quote word) text)))
    (should position)
    (mapcar (lambda (property) (get-text-property position property text))
            '(pointer help-echo mouse-face))))

(ert-deftest etaf-native-affordances-match-ebox-inheritance ()
  "Nested Hosts preserve Ebox native hover, help and explicit nil boundaries."
  (let ((direct (ebox-render
                 (ebox-build
                  '(row :color "#123456" :pointer hand :help-echo "Parent"
                        :hover-style (:text-decoration-line underline)
                        (text "Inherited")
                        (text :pointer nil :help-echo nil :hover-style nil "Plain")))))
        (integrated (ebox-render (etaf-render
                                  (etaf-view
                                   (row :color "#123456" :pointer 'hand :help-echo "Parent"
                                        :hover-style '(:text-decoration-line underline)
                                        (text "Inherited")
                                        (text :pointer nil :help-echo nil :hover-style nil "Plain")))))))
    (dolist (word '("Inherited" "Plain"))
      (should (equal (etaf-native-affordance-test--properties direct word)
                     (etaf-native-affordance-test--properties integrated word))))
    (should (equal '(nil nil nil)
                   (etaf-native-affordance-test--properties integrated "Plain")))))

(etaf-define-component etaf-native-affordance-test-control ()
                       :view (box :role 'button :tab-index 0 (text "Control")))

(ert-deftest etaf-native-affordances-update-through-component-attributes ()
  "Forwarded affordances update with reactive inputs without replacing activation."
  (let ((buffer (generate-new-buffer " *etaf-native-affordances*"))
        (enabled (etaf-ref t))
        (help (lambda (_window _object _position) "Native help"))
        (activations 0))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-native-affordance-test-control
             :ref 'control
             :pointer (if (etaf-value enabled) 'hand nil)
             :help-echo (if (etaf-value enabled) help "Updated")
             :hover-style (when (etaf-value enabled)
                            '(:background-color "#345678"))
             :on-press (lambda () (cl-incf activations)))))
          (with-current-buffer buffer
            (let ((properties (etaf-native-affordance-test--properties
                               (buffer-string) "Control")))
              (should (eq (car properties) 'hand))
              (should (eq (cadr properties) help))
              (should (nth 2 properties)))
            (ebox-activate (etaf-host-ref-position (etaf-runtime-for-buffer buffer) 'control)))
          (setf (etaf-value enabled) nil)
          (with-current-buffer buffer
            (should (equal '(nil "Updated" nil)
                           (etaf-native-affordance-test--properties (buffer-string) "Control")))
            (ebox-activate (etaf-host-ref-position (etaf-runtime-for-buffer buffer) 'control)))
          (should (= activations 2)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-native-affordance-tests)
;;; etaf-native-affordance-tests.el ends here
