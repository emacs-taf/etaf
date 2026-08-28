;;; emacs-gui-verifier.el --- Generic temporal GUI scenario engine -*- lexical-binding: t; -*-

;;; Commentary:

;; This developer tool executes declarative GUI scenarios against any Emacs
;; buffer.  It owns action ordering, checkpoint phases, target-buffer guards,
;; completion, and evidence lifecycle.  It does not know ETAF Runtime, Ebox,
;; Playground, or any concrete example; adapters supply those facts through
;; callbacks and opaque context data.

;;; Code:

(require 'cl-lib)

(declare-function emacs-dynamic-ui-verification-start
                  "capture-checkpoint" (directory run-id claim required-phases))
(declare-function emacs-dynamic-ui-verification-checkpoint
                  "capture-checkpoint"
                  (action-id phase adapter assertions screenshot))
(declare-function emacs-dynamic-ui-verification-finish
                  "capture-checkpoint" (completed adapter))

(cl-defstruct (etaf-gui-verifier-action
               (:constructor etaf-gui-verifier-action-create))
  "One ordered GUI action and its postcondition callback."
  id execute assertions screenshot settled-p
  (settle-timeout 5.0) (settle-interval 0.05))

(cl-defstruct (etaf-gui-verifier-scenario
               (:constructor etaf-gui-verifier-scenario-create))
  "One reusable GUI scenario assembled by an adapter."
  name claim initialize actions invariants adapter completion)

(cl-defstruct (etaf-gui-verifier-context
               (:constructor etaf-gui-verifier--context-create))
  "Mutable execution state owned only by one verifier run."
  scenario target-buffer data (action-count 0) (last-duration-ms 0.0))

(defun etaf-gui-verifier-context-put (context key value)
  "Store adapter VALUE for KEY in CONTEXT and return VALUE."
  (setf (alist-get key (etaf-gui-verifier-context-data context)) value)
  value)

(defun etaf-gui-verifier-context-get (context key &optional default)
  "Return CONTEXT adapter value KEY, or DEFAULT when absent."
  (alist-get key (etaf-gui-verifier-context-data context) default))

(defun etaf-gui-verifier-context-select-buffer (context buffer)
  "Select live BUFFER as CONTEXT's single-window target."
  (unless (buffer-live-p buffer)
    (error "GUI verifier target buffer is not live"))
  (setf (etaf-gui-verifier-context-target-buffer context) buffer)
  (switch-to-buffer buffer)
  (delete-other-windows)
  buffer)

(defun etaf-gui-verifier-assert (name passed &optional detail)
  "Return one normalized assertion NAME for PASSED and optional DETAIL."
  (append (list (cons 'name name) (cons 'passed (and passed t)))
          (when detail (list (cons 'detail detail)))))

(defun etaf-gui-verifier--target-assertions (context)
  "Return generic selected-target assertions for CONTEXT."
  (let ((buffer (etaf-gui-verifier-context-target-buffer context)))
    (list
     (etaf-gui-verifier-assert
      "target-buffer-selected"
      (and (buffer-live-p buffer)
           (eq (window-buffer (selected-window)) buffer))))))

(defun etaf-gui-verifier--scenario-assertions (context)
  "Return generic and adapter assertions for CONTEXT."
  (let* ((scenario (etaf-gui-verifier-context-scenario context))
         (function (etaf-gui-verifier-scenario-invariants scenario)))
    (append
     (etaf-gui-verifier--target-assertions context)
     (and function (funcall function context)))))

(defun etaf-gui-verifier--adapter-data (context)
  "Return generic and adapter JSON data for CONTEXT."
  (let* ((scenario (etaf-gui-verifier-context-scenario context))
         (function (etaf-gui-verifier-scenario-adapter scenario)))
    (append
     (list
      (cons 'scenario (etaf-gui-verifier-scenario-name scenario))
      (cons 'action_count
            (etaf-gui-verifier-context-action-count context))
      (cons 'duration_ms
            (etaf-gui-verifier-context-last-duration-ms context)))
     (and function (funcall function context)))))

(defun etaf-gui-verifier--checkpoint
    (context action-id phase screenshot &optional extra)
  "Capture CONTEXT ACTION-ID PHASE with SCREENSHOT and EXTRA assertions."
  (emacs-dynamic-ui-verification-checkpoint
   action-id phase
   (etaf-gui-verifier--adapter-data context)
   (append (etaf-gui-verifier--scenario-assertions context) extra)
   screenshot))

(defun etaf-gui-verifier--settle-action (context action)
  "Wait until ACTION's visible result is settled in CONTEXT."
  (let ((settled-p (etaf-gui-verifier-action-settled-p action))
        (timeout (etaf-gui-verifier-action-settle-timeout action))
        (interval (etaf-gui-verifier-action-settle-interval action)))
    (unless settled-p
      (error "GUI action has no settle predicate: %s"
             (etaf-gui-verifier-action-id action)))
    (unless (and (numberp timeout) (> timeout 0))
      (error "GUI action settle timeout must be positive: %s"
             (etaf-gui-verifier-action-id action)))
    (unless (and (numberp interval) (> interval 0))
      (error "GUI action settle interval must be positive: %s"
             (etaf-gui-verifier-action-id action)))
    ;; Always complete at least one redisplay before accepting a predicate.
    ;; A predicate proves adapter state, not that Emacs painted that state.
    (redisplay t)
    (sit-for 0)
    (let ((deadline
           (+ (float-time) timeout))
          settled)
      (while (not settled)
        (when (>= (float-time) deadline)
          (error "GUI action did not settle before timeout: %s"
                 (etaf-gui-verifier-action-id action)))
        (if (funcall settled-p context)
            ;; Require the same postcondition across one event/paint turn.
            ;; Runtime state can be synchronous while the GUI compositor still
            ;; presents the preceding frame.
            (progn
              (sit-for interval)
              (redisplay t)
              (setq settled (funcall settled-p context)))
          (sit-for interval)
          (redisplay t))))))

(defun etaf-gui-verifier--run-action (context action)
  "Execute ACTION once inside CONTEXT's ordered checkpoint protocol."
  (let ((action-id (etaf-gui-verifier-action-id action))
        (assertions (etaf-gui-verifier-action-assertions action)))
    (etaf-gui-verifier--checkpoint
     context action-id "before-action" nil)
    (let ((started (float-time)))
      (funcall (etaf-gui-verifier-action-execute action) context)
      (setf (etaf-gui-verifier-context-last-duration-ms context)
            (* 1000.0 (- (float-time) started))))
    (cl-incf (etaf-gui-verifier-context-action-count context))
    (etaf-gui-verifier--checkpoint
     context action-id "after-action" nil)
    (raise-frame)
    (etaf-gui-verifier--settle-action context action)
    (etaf-gui-verifier--checkpoint
     context action-id "after-redisplay"
     (etaf-gui-verifier-action-screenshot action)
     (and assertions (funcall assertions context)))))

;;;###autoload
(defun etaf-gui-verifier-run (scenario run-directory)
  "Execute generic SCENARIO and write temporal evidence to RUN-DIRECTORY."
  (unless (etaf-gui-verifier-scenario-p scenario)
    (signal 'wrong-type-argument
            (list 'etaf-gui-verifier-scenario-p scenario)))
  (let* ((context
          (etaf-gui-verifier--context-create :scenario scenario))
         (initialize (etaf-gui-verifier-scenario-initialize scenario))
         (completion (etaf-gui-verifier-scenario-completion scenario))
         finished-p)
    (emacs-dynamic-ui-verification-start
     run-directory
     (etaf-gui-verifier-scenario-name scenario)
     (etaf-gui-verifier-scenario-claim scenario)
     '("before-action" "after-action" "after-redisplay"))
    (condition-case error-data
        (progn
          (when initialize (funcall initialize context))
          (dolist (action (etaf-gui-verifier-scenario-actions scenario))
            (etaf-gui-verifier--run-action context action))
          (let ((completed (if completion
                               (funcall completion context)
                             t)))
            (emacs-dynamic-ui-verification-finish
             completed (etaf-gui-verifier--adapter-data context))
            (setq finished-p t)
            (unless completed
              (error "GUI scenario completion predicate failed")))
          context)
      ((error quit)
       (unless finished-p
         (condition-case finish-error
             (emacs-dynamic-ui-verification-finish
              nil (etaf-gui-verifier--adapter-data context))
           (error
            (message "GUI verifier could not record failed completion: %s"
                     (error-message-string finish-error)))))
       (signal (car error-data) (cdr error-data))))))

(provide 'emacs-gui-verifier)
;;; emacs-gui-verifier.el ends here
