;;; etaf-resource.el --- Resource state and error boundary -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Resources are small Scope-owned data loaders.  A synchronous loader updates
;; one reactive state cell to loading, success, or error.  Loader failures are
;; represented in that state; unrelated errors still propagate through their
;; ordinary boundary unless explicitly wrapped with `etaf-error-boundary-run'.

;;; Code:

(require 'cl-lib)
(require 'etaf-observer)
(require 'etaf-reactive)

(define-error 'etaf-resource-error "Invalid ETAF Resource operation"
  'etaf-reactive-error)

(cl-defstruct (etaf-resource
               (:constructor etaf--resource-create))
  "A Scope-owned synchronous resource."
  loader
  state
  scope
  cleanup
  name
  (active-p t))

(cl-defstruct (etaf-resource-result
               (:constructor etaf--resource-result-create))
  "A Resource loader result with VALUE and optional CLEANUP."
  value
  cleanup)

(defun etaf--resource-state (status value error)
  "Return a Resource state plist for STATUS, VALUE, and ERROR."
  (list :status status :value value :error error))

(defun etaf--resource-parent-scope (scope)
  "Return explicit SCOPE or the current active Scope."
  (or scope (etaf-current-effect-scope)))

(defun etaf--resource-child-scope (scope name)
  "Create a Resource Scope named NAME under SCOPE when present, otherwise detached."
  (if scope
      (etaf-scope-run scope
       (lambda () (etaf-effect-scope :name name)))
    (etaf-effect-scope :detached t :name name)))

(defun etaf--resource-require-active (resource)
  "Return active RESOURCE or signal a Resource error."
  (unless (and (etaf-resource-p resource)
               (etaf-resource-active-p resource))
    (signal 'etaf-resource-error
            (list "ETAF Resource is not active")))
  resource)

(defun etaf--resource-set-state (resource status value error)
  "Set RESOURCE state to STATUS, VALUE, and ERROR."
  (setf (etaf-value (etaf-resource-state resource))
        (etaf--resource-state status value error)))

(defun etaf--resource-run-cleanup (resource)
  "Run RESOURCE's current cleanup once."
  (when-let* ((cleanup (etaf-resource-cleanup resource)))
    (setf (etaf-resource-cleanup resource) nil)
    (funcall cleanup)))

(defun etaf--resource-normalize-result (result)
  "Return (VALUE CLEANUP) from loader RESULT."
  (if (etaf-resource-result-p result)
      (list (etaf-resource-result-value result)
            (etaf-resource-result-cleanup result))
    (list result nil)))

;;;###autoload
(cl-defun etaf-resource-result (value &key cleanup)
  "Return a Resource loader result containing VALUE and optional CLEANUP.

CLEANUP must be nil or a zero-argument function.  It runs before the next
successful load replaces the resource value, and when the Resource is
disposed."
  (when (and cleanup (not (functionp cleanup)))
    (signal 'wrong-type-argument (list 'functionp cleanup)))
  (etaf--resource-result-create :value value :cleanup cleanup))

;;;###autoload
(cl-defun etaf-resource (loader &key (immediate t) scope name)
  "Create a Resource backed by synchronous LOADER.

The Resource owns a child Scope under SCOPE, or under the current active Scope
when SCOPE is nil.  Without any parent Scope it creates a detached Scope.
When IMMEDIATE is non-nil, load the Resource before returning it."
  (etaf--assert-not-rendering 'create-resource)
  (unless (functionp loader)
    (signal 'wrong-type-argument (list 'functionp loader)))
  (let* ((parent (etaf--resource-parent-scope scope))
         (owned-scope (etaf--resource-child-scope parent name))
         resource)
    (setq resource
          (etaf--resource-create
           :loader loader
           :state (etaf-ref (etaf--resource-state 'loading nil nil)
                            :name name)
           :scope owned-scope
           :name name))
    (etaf-scope-run
     owned-scope
     (lambda ()
       (etaf-on-scope-dispose
        (lambda ()
          (setf (etaf-resource-active-p resource) nil)
          (etaf--resource-run-cleanup resource)))))
    (when immediate
      (etaf-resource-load resource))
    resource))

;;;###autoload
(defun etaf-resource-status (resource)
  "Return RESOURCE status: `loading', `success', or `error'."
  (plist-get (etaf-value (etaf-resource-state resource)) :status))

;;;###autoload
(defun etaf-resource-value (resource)
  "Return RESOURCE's successful value, or nil before success."
  (plist-get (etaf-value (etaf-resource-state resource)) :value))

;;;###autoload
(defun etaf-resource-error (resource)
  "Return RESOURCE's captured loader error, or nil when not in error."
  (plist-get (etaf-value (etaf-resource-state resource)) :error))

;;;###autoload
(defun etaf-resource-load (resource)
  "Reload RESOURCE and return it.

Only LOADER errors are captured into Resource state.  Cleanup failures and
wrong Resource usage continue to signal normally."
  (etaf--assert-not-rendering 'load-resource)
  (etaf--resource-require-active resource)
  (etaf--resource-run-cleanup resource)
  (etaf--resource-set-state resource 'loading nil nil)
  (let (result error-data)
    (condition-case err
        (setq result
              (etaf-observer-with-stage ('resource 'load)
                (etaf-scope-run
                 (etaf-resource-scope resource)
                 (etaf-resource-loader resource))))
      (error (setq error-data err)))
    (if error-data
        (etaf--resource-set-state resource 'error nil error-data)
      (pcase-let ((`(,value ,cleanup)
                   (etaf--resource-normalize-result result)))
        (when (and cleanup (not (functionp cleanup)))
          (signal 'wrong-type-argument (list 'functionp cleanup)))
        (setf (etaf-resource-cleanup resource) cleanup)
        (etaf--resource-set-state resource 'success value nil))))
  resource)

;;;###autoload
(defun etaf-resource-dispose (resource)
  "Dispose RESOURCE and return cleanup errors collected by its Scope."
  (etaf--assert-not-rendering 'dispose-resource)
  (unless (etaf-resource-p resource)
    (signal 'wrong-type-argument (list 'etaf-resource-p resource)))
  (when (etaf-resource-active-p resource)
    (setf (etaf-resource-active-p resource) nil)
    (etaf-scope-stop (etaf-resource-scope resource))))

;;;###autoload
(defalias 'etaf-resource-cancel #'etaf-resource-dispose
  "Cancel RESOURCE and return cleanup errors collected by its Scope.")

;;;###autoload
(cl-defun etaf-error-boundary-run (function handler &key name)
  "Run FUNCTION and handle its signaled error with HANDLER.

HANDLER receives the raw condition object and its return value becomes the
boundary result.  NAME is accepted for caller diagnostics and does not change
control flow.  Errors signaled outside FUNCTION, or by HANDLER itself, are not
swallowed by this boundary."
  (ignore name)
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (unless (functionp handler)
    (signal 'wrong-type-argument (list 'functionp handler)))
  (condition-case err
      (funcall function)
    (error
     (funcall handler err))))

(provide 'etaf-resource)

;;; etaf-resource.el ends here
