;;; etaf-m0b-component-manifest.el --- Observed Component contract manifest -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Emit a machine-readable M0b manifest that keeps Component business props,
;; forwarded Host attributes, and the single-root forwarding guarantee in
;; separate fields.  The manifest is emitted only after a real mounted probe.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'etaf)

(defconst etaf-m0b-component-manifest--dsl-name
  'etaf-m0b-manifest-dsl-card)

(defconst etaf-m0b-component-manifest--render-name
  'etaf-m0b-manifest-render-card)

(defun etaf-m0b-component-manifest--define-fixtures ()
  "Define the two manifest probe Components through the public authoring API."
  (etaf-component-redefine-run
   (lambda ()
     (eval
      '(etaf-define-component etaf-m0b-manifest-dsl-card (&key title)
         :view
         (box :class "definition" (text (expr title)))))
     (eval
      '(etaf-define-component etaf-m0b-manifest-render-card (&key label)
         :render
         (etaf-node 'box (list :class "definition")
                    (list (etaf-node 'text nil (list label)))))))))

(defun etaf-m0b-component-manifest--spec-props (name)
  "Return declared business props for Component NAME."
  (let ((spec (gethash name etaf--view-registry)))
    (unless (etaf--component-spec-p spec)
      (error "Manifest fixture is not a Component: %S" name))
    (mapcar #'symbol-name (etaf--component-spec-props spec))))

(defun etaf-m0b-component-manifest--mounted-probe (name prop value ref text)
  "Mount NAME with PROP VALUE and verify forwarded attrs at REF and TEXT."
  (let ((buffer (generate-new-buffer-name " *etaf-m0b-manifest*")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-node name
                      (list prop value :class "caller"
                            :aria-label "manifest-probe" :ref ref)
                      nil))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (props (etaf-runtime-host-props-for runtime ref)))
            (unless (and (string-match-p (regexp-quote text)
                                         (with-current-buffer buffer
                                           (buffer-string)))
                         (member "caller" (plist-get props :class))
                         (equal "manifest-probe"
                                (plist-get props :aria-label)))
              (error "Mounted Component forwarding probe failed: %S" name)))
          t)
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (when-let* ((live (get-buffer buffer)))
        (kill-buffer live)))))

(defun etaf-m0b-component-manifest-data ()
  "Return the observed M0b Component manifest as an alist."
  (etaf-m0b-component-manifest--define-fixtures)
  (let ((dsl-ok
         (etaf-m0b-component-manifest--mounted-probe
          etaf-m0b-component-manifest--dsl-name :title "DSL" 'manifest-dsl
          "DSL"))
        (render-ok
         (etaf-m0b-component-manifest--mounted-probe
          etaf-m0b-component-manifest--render-name :label "Render"
          'manifest-render "Render"))
        (attrs '("class" "style/presentation" "layout" "ref"
                 "role/tab-index" "aria-*" "on-*" "use")))
    `((schema-version . 1)
      (evidence-mode . "observed")
      (components
       . (((name . ,(symbol-name etaf-m0b-component-manifest--dsl-name))
           (frontend . "view")
           (declared-business-props
            . ,(etaf-m0b-component-manifest--spec-props
                etaf-m0b-component-manifest--dsl-name))
           (forwarded-host-attrs . ,attrs)
           (root-shape-forwarding-guarantee
            . "single attr-capable root only; fragment, text, and multi-root results reject forwarded attrs")
           (mounted-validation . ,dsl-ok))
          ((name . ,(symbol-name etaf-m0b-component-manifest--render-name))
           (frontend . "render")
           (declared-business-props
            . ,(etaf-m0b-component-manifest--spec-props
                etaf-m0b-component-manifest--render-name))
           (forwarded-host-attrs . ,attrs)
           (root-shape-forwarding-guarantee
            . "single attr-capable root only; fragment, text, and multi-root results reject forwarded attrs")
           (mounted-validation . ,render-ok)))))))

(defun etaf-m0b-component-manifest-write-json ()
  "Write the observed M0b Component manifest as JSON."
  (princ (json-encode (etaf-m0b-component-manifest-data))))

(provide 'etaf-m0b-component-manifest)

;;; etaf-m0b-component-manifest.el ends here
