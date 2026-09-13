;;; etaf-native-activation-tests.el --- Shared Ebox activation -*- lexical-binding: t; -*-

;;; Commentary:
;; Native provider activation reaches committed ETAF handlers and hit boundaries.

;;; Code:
(require 'ert)
(require 'etaf)
(require 'ebox)

(ert-deftest etaf-native-activation-matches-direct-ebox-counter ()
  "The same provider activation increments directly rendered and ETAF counters."
  (let ((direct (generate-new-buffer " *ebox-counter*"))
        (framework (generate-new-buffer " *etaf-counter*"))
        (count (etaf-ref 0)) (direct-count 0))
    (unwind-protect
        (cl-labels ((direct-input ()
                      (ebox-build
                       (list 'text :keymap (ebox-keymap-create
                                           :activate (lambda () (cl-incf direct-count)
                                                       (ebox-commit direct (direct-input))))
                             (number-to-string direct-count)))))
          (ebox-render-to-buffer direct (direct-input))
          (etaf-mount framework
                      (etaf-view (text :on-press (lambda () (cl-incf (etaf-value count)))
                                  (expr (number-to-string (etaf-value count))))))
          (dotimes (index 2)
            (with-current-buffer direct (ebox-activate (point-min)))
            (with-current-buffer framework (ebox-activate (point-min)))
            (should (= (1+ index) (etaf-value count)))
            (should (equal (with-current-buffer direct (buffer-substring-no-properties (point-min) (point-max)))
                           (with-current-buffer framework (buffer-substring-no-properties (point-min) (point-max)))))))
      (when-let* ((runtime (etaf-runtime-for-buffer framework))) (etaf-unmount runtime))
      (kill-buffer framework)
      (kill-buffer direct))))

(ert-deftest etaf-native-navigation-and-activation-preserve-hit-barriers ()
  "Native navigation discovers ETAF handlers while disabled and callbackless children block parents."
  (let ((buffer (generate-new-buffer " *etaf-native-boundaries*"))
        (disabled (etaf-ref nil)) events)
    (unwind-protect
        (progn
          (etaf-mount buffer
                      (etaf-view
                       (column (text "Intro")
                         (box :on-press (lambda () (push 'parent events))
                           (text "Parent")
                           (text :ref 'child :role 'button :disabled (etaf-value disabled)
                                 :on-press (lambda () (push 'child events)) "Child")
                           (text :role 'button "Blocked")))))
          (with-current-buffer buffer
            (goto-char (point-min))
            (ebox-next-interaction)
            (should (looking-at "Parent"))
            (ebox-activate)
            (ebox-next-interaction)
            (should (looking-at "Child"))
            (ebox-activate)
            (should (equal events '(child parent)))
            (let ((blocked (+ (point-min) (string-match "Blocked" (buffer-string)))))
              (should-error (ebox-activate blocked) :type 'user-error))
            (setf (etaf-value disabled) t)
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (should-error (ebox-activate (etaf-host-ref-position (etaf-runtime-for-buffer buffer) 'child))
                          :type 'user-error)
            (goto-char (point-min))
            (ebox-next-interaction)
            (should-error (ebox-next-interaction) :type 'user-error)
            (should (equal events '(child parent)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-native-activation-reads-only-committed-handlers ()
  "Native commands dispatch current handlers and retain them after rejected updates."
  (let ((buffer (generate-new-buffer " *etaf-native-callbacks*"))
        (label (etaf-ref "First")) events)
    (unwind-protect
        (progn
          (etaf-mount buffer
                      (etaf-view
                       (column
                         (text :ref 'action
                               :on-press (let ((snapshot (etaf-value label)))
                                           (lambda () (push snapshot events))) "Action")
                         (text (expr (if (equal (etaf-value label) "Reject")
                                         (error "Reject callback update") ""))))))
          (with-current-buffer buffer
            (let* ((position (etaf-host-ref-position (etaf-runtime-for-buffer buffer) 'action))
                   (command (lookup-key (get-text-property position 'keymap) (kbd "RET"))))
              (ebox-activate position)
              (setf (etaf-value label) "Second")
              (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
              (call-interactively command)
              (should-error (setf (etaf-value label) "Reject"))
              (ebox-activate position)
              (should (equal '("Second" "Second" "First") events)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-native-keyboard-preserves-explicit-focused-parent ()
  "Native RET preserves explicit focus when a child shares its parent's position."
  (let ((buffer (generate-new-buffer " *etaf-native-focus*")) events)
    (unwind-protect
        (progn
          (etaf-mount buffer
                      (etaf-view (box :ref 'parent :tab-index 0
                                      :on-press (lambda () (push 'parent events))
                                  (text :ref 'child :tab-index 1
                                        :on-press (lambda () (push 'child events)) "Child"))))
          (with-current-buffer buffer
            (let ((runtime (etaf-runtime-for-buffer buffer)) (last-input-event ?\r))
              (etaf-focus runtime 'parent)
              (call-interactively (key-binding (kbd "RET")))
              (etaf-focus runtime 'child)
              (call-interactively (key-binding (kbd "RET")))
              (should (equal events '(child parent)))
              (etaf-focus runtime 'parent)
              (save-window-excursion
                (set-window-buffer (selected-window) buffer)
                (let* ((position (etaf-host-ref-position runtime 'child))
                       (last-input-event (list 'mouse-1 (list (selected-window) position '(1 . 1) 0)))
                       (command (lookup-key (get-text-property position 'keymap) [mouse-1])))
                  (call-interactively command)))
              (should (equal events '(child child parent))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-native-keyboard-uses-shared-buffer-bindings-and-activation ()
  "ETAF mounts use Ebox TAB and activation, sharing focus and releasing mode bindings on unmount."
  (let ((buffer (generate-new-buffer " *etaf-shared-keyboard*")) events)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (column
              (box :ref 'parent :tab-index 0 :on-press (lambda () (push 'parent events))
                (text :ref 'child :tab-index 1 :on-press (lambda () (push 'child events)) "Child"))
              (text :ref 'blocked :tab-index 2 :disabled t "Blocked"))))
          (with-current-buffer buffer
            (let ((runtime (etaf-runtime-for-buffer buffer))
                  (forward (key-binding (kbd "TAB"))))
              (should (eq forward (lookup-key ebox-buffer-mode-map (kbd "TAB"))))
              (call-interactively forward)
              (should (eq (etaf-focused-host-ref runtime) 'parent))
              (let ((last-input-event ?\r)) (call-interactively (key-binding (kbd "RET"))))
              (ebox-activate)
              (etaf-activate runtime)
              (should (equal events '(parent parent parent)))
              (call-interactively forward)
              (should (eq (ebox-focused-host-ref) 'child))
              (let ((last-input-event ?\r)) (call-interactively (key-binding (kbd "RET"))))
              (should (equal events '(child parent parent parent)))
              (call-interactively forward)
              (should (eq (ebox-focused-host-ref) 'parent))
              (call-interactively (key-binding (kbd "<backtab>")))
              (should (eq (ebox-focused-host-ref) 'child))
              (etaf-unmount runtime)
              (should-not (eq (key-binding (kbd "TAB")) forward))
              (should-not (ebox-focused-host-ref)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-native-activation-retains-automatic-target-after-style-update ()
  "A property-only style update keeps automatic Host activation and focus usable."
  (let ((buffer (generate-new-buffer " *etaf-retained-activation*"))
        (color (etaf-ref "red")) (disabled (etaf-ref nil)) (presses 0))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (box :role 'button :tab-index 0 :aria-label "Action"
                 :color (etaf-value color) :disabled (etaf-value disabled)
                 :on-press (lambda () (cl-incf presses)) "Action")))
          (with-current-buffer buffer
            (let* ((runtime (etaf-runtime-for-buffer buffer))
                   (target (caar (etaf-runtime-host-props-entries runtime)))
                   (last-input-event ?\r))
              (etaf-focus runtime target)
              (call-interactively (key-binding (kbd "RET")))
              (setf (etaf-value color) "blue")
              (etaf-runtime-flush runtime)
              (should (equal target (etaf-focused-host-ref runtime)))
              (call-interactively (key-binding (kbd "RET")))
              (should (= presses 2))
              (setf (etaf-value disabled) t)
              (should-error (etaf-activate runtime) :type 'user-error)
              (setf (etaf-value disabled) nil)
              (etaf-focus runtime target)
              (ebox-activate)
              (should (= presses 3)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-native-activation-tests)
;;; etaf-native-activation-tests.el ends here
