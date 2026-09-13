;;; etaf-behavior.el --- Non-visual :use Behaviors -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A Behavior is a reusable bundle of semantic attributes and optional setup
;; cleanup.  It is data attached through `:use', never a View node.  Local
;; `:on-*' callbacks remain the simpler choice for one-off interaction.

;;; Code:

(require 'cl-lib)
(require 'etaf-reactive)

(define-error 'etaf-behavior-error "Invalid ETAF Behavior")

(cl-defstruct (etaf-behavior-spec
               (:constructor etaf--behavior-spec-create))
  "A name-plus-attributes non-visual Behavior specification."
  name
  attributes
  install)

(cl-defstruct (etaf-behavior-context
               (:constructor etaf--behavior-context-create))
  "Runtime context supplied to an optional Behavior installer."
  runtime
  path
  host-props)

(defvar etaf--current-behavior-context nil
  "Behavior context active while one Behavior installs.")

;;;###autoload
(defun etaf-current-behavior-context ()
  "Return the Behavior context active during an installer, or nil."
  etaf--current-behavior-context)

(defun etaf-behavior-create (name &rest attributes)
  "Create a Behavior spec named NAME from keyword ATTRIBUTES.

The reserved `:install' attribute is an optional zero-argument installer that
returns nil or a cleanup function; it is not merged into Host properties."
  (unless (and (symbolp name) (not (keywordp name)))
    (signal 'etaf-behavior-error
            (list (format "Behavior name must be a symbol: %S" name))))
  (unless (and (proper-list-p attributes)
               (zerop (% (length attributes) 2)))
    (signal 'etaf-behavior-error
            (list "Behavior attributes must be keyword/value pairs")))
  (let ((tail attributes)
        (semantic nil)
        install
        seen)
    (while tail
      (let ((key (pop tail)))
        (unless (keywordp key)
          (signal 'etaf-behavior-error
                  (list (format "Behavior attribute must be a keyword: %S"
                                key))))
        (when (memq key seen)
          (signal 'etaf-behavior-error
                  (list (format "Duplicate Behavior attribute: %S" key))))
        (push key seen)
        (let ((value (pop tail)))
          (if (eq key :install)
              (setq install value)
            (setq semantic (append semantic (list key value)))))))
    (when (and install (not (functionp install)))
      (signal 'etaf-behavior-error
              (list ":install must be a function or nil")))
    (etaf--behavior-spec-create :name name
                                :attributes semantic
                                :install install)))

(defmacro etaf-define-behavior (name arguments &rest body)
  "Define ordinary Behavior constructor NAME with ARGUMENTS and BODY.

The constructor must return `etaf-behavior-create' data.  This is a function
definition convenience, not a second runtime or visual node model."
  (declare (indent 2) (debug defun))
  (unless (symbolp name)
    (signal 'etaf-behavior-error (list "Behavior name must be a symbol")))
  `(defun ,name ,arguments
     ,(if (stringp (car body)) (pop body)
        (format "Construct the `%s' ETAF Behavior." name))
     ,@body))

;;;###autoload
(defun etaf-focusable (&rest attributes)
  "Return a focusable Behavior from ATTRIBUTES.

When ATTRIBUTES does not specify `:tab-index', the Behavior supplies the
standard first tab stop, zero.  An explicit nil keeps the Host unfocusable."
  (unless (plist-member attributes :tab-index)
    (setq attributes (append attributes (list :tab-index 0))))
  (apply #'etaf-behavior-create 'focusable attributes))

;;;###autoload
(defun etaf-toggleable (&rest attributes)
  "Return a Behavior converting ATTRIBUTES into a toggleable press action.

`:value' and `:on-change' configure the action; all other attributes remain
part of the returned Behavior."
  (let ((value (plist-get attributes :value))
        (on-change (plist-get attributes :on-change)))
    (unless (functionp on-change)
      (signal 'etaf-behavior-error
              (list "toggleable requires a function-valued :on-change")))
    (let (remaining)
      (while attributes
        (let ((key (pop attributes))
              (item (pop attributes)))
          (unless (memq key '(:value :on-change))
            (setq remaining (append remaining (list key item))))))
      (apply #'etaf-behavior-create
             'toggleable
             (append remaining
                     (list :on-press
                           (lambda ()
                             (funcall
                              on-change
                              (not
                               (if (or (etaf-ref-p value)
                                       (etaf-computed-p value))
                                   (etaf-value value)
                                 value))))))))))

(provide 'etaf-behavior)

;;; etaf-behavior.el ends here
