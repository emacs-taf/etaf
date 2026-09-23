;;; etaf-drag-tests.el --- Shared native drag integration -*- lexical-binding: t; -*-

;;; Commentary:
;; Native Ebox keymaps drive mounted ETAF callbacks and visible reactive updates.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'etaf)
(require 'ebox)

(defun etaf-drag-test--run (runtime after-burst)
  "Drag RUNTIME's handle through two motion bursts and a later release.
AFTER-BURST receives the expected horizontal delta after each burst publishes.
An empty native queue separates bursts; nonblocking polls never reveal a
future event.  Events returned to `unread-command-events' retain precedence."
  (save-window-excursion
    (set-window-buffer (selected-window) (etaf-runtime-buffer runtime))
    (with-current-buffer (etaf-runtime-buffer runtime)
      (let* ((window (selected-window))
             (position (etaf-host-ref-position runtime 'handle))
             (press (list 'down-mouse-1 (list window position '(1 . 1) 0)))
             (bursts
              (list
               (list 3
                     (list 'mouse-movement (list window position '(2 . 2) 1))
                     (list 'mouse-movement (list window position '(4 . 2) 2)))
               (list 5
                     (list 'mouse-movement (list window position '(5 . 2) 3))
                     (list 'mouse-movement (list window position '(6 . 2) 4)))
               (list nil
                     (list 'drag-mouse-1 (event-start press)
                           (list window position '(7 . 2) 5)))))
             events checkpoint
             (unread-command-events nil)
             (command (key-binding (vector press) nil nil position)))
        (cl-letf (((symbol-function 'read-event)
                   (lambda (&optional _prompt _inherit seconds)
                     (cond
                      (unread-command-events (pop unread-command-events))
                      (events (pop events))
                      ((equal seconds 0) nil)
                      (bursts
                       (when checkpoint (funcall after-burst checkpoint))
                       (let ((burst (pop bursts)))
                         (setq checkpoint (car burst) events (cdr burst)))
                       (pop events))
                      (t ?q)))))
          (funcall command press))))))

(ert-deftest etaf-drag-publishes-motion-bursts-through-ebox ()
  "Each delivered burst updates the active View before the exact release endpoint."
  (let ((buffer (generate-new-buffer " *etaf-drag*"))
        (offset (etaf-ref 0)) phases targets)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (column :width '(px 80)
             (box :ref 'handle :position 'relative :left (list 'px (etaf-value offset))
                  :on-drag (lambda (gesture)
                             (push (plist-get gesture :phase) phases)
                             (push (plist-get gesture :host-ref) targets)
                             (when (memq (plist-get gesture :phase) '(move end))
                               (setf (etaf-value offset) (car (plist-get gesture :delta)))))
                  "Drag")
             (text (expr (format "X %d" (etaf-value offset)))))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-drag-test--run
             runtime (lambda (delta)
                       (should (= delta (etaf-value offset)))
                       (should (string-match-p (format "X %d" delta) (buffer-string)))
                       (should (= 1 (length (ebox-selector-query-buffer buffer ":active"))))))
            (should (equal (reverse phases) '(start move move end)))
            (should (equal targets '(handle handle handle handle)))
            (should (= (etaf-value offset) 6))
            (should-not (ebox-selector-query-buffer buffer ":active"))
            (with-current-buffer buffer (should (string-match-p "X 6" (buffer-string))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-drag-cancellation-clears-transient-state-on-disable ()
  "A retained disabled target receives cancellation, then rejects new input."
  (let ((buffer (generate-new-buffer " *etaf-drag-disable*"))
        (disabled (etaf-ref nil)) (moving (etaf-ref nil)) phases)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (column
             (box :ref 'handle :disabled (etaf-value disabled)
                  :on-drag (lambda (gesture)
                             (let ((phase (plist-get gesture :phase)))
                               (push phase phases)
                               (pcase phase
                                 ('start (setf (etaf-value moving) t))
                                 ('move (setf (etaf-value disabled) t))
                                 ('cancel (setf (etaf-value moving) nil)))))
                  "Drag")
             (text (expr (if (etaf-value moving) "Moving" "Stopped"))))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-drag-test--run runtime #'ignore)
            (should (equal (reverse phases) '(start move cancel)))
            (should-not (etaf-value moving))
            (should-not (ebox-selector-query-buffer buffer ":active"))
            (with-current-buffer buffer (should (string-match-p "Stopped" (buffer-string))))
            (should-error (etaf-dispatch-event runtime 'handle 'drag '(:phase start) t)
                          :type 'etaf-event-error)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-drag-tests)
;;; etaf-drag-tests.el ends here
