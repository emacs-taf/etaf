;;; etaf-tests.el --- ETAF P0 contract tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'etaf)

(defun etaf-test--render-text (view)
  "Return plain rendered text for VIEW."
  (substring-no-properties (ebox-render (etaf-render view))))

(etaf-define-component etaf-test-badge (&key label)
  "Render LABEL as a small semantic test Component."
  :view
  (text :face 'bold (expr :value label)))

(etaf-define-component etaf-list (&key label)
  "Render LABEL using the collision-safe `list-view' alias."
  :view
  (text (expr :value label)))

(ert-deftest etaf-view-property-region-precedes-children ()
  "Reject a property that appears after a structural child."
  (should-error
   (macroexpand '(etaf-view (text "Hello" :face 'bold)))
   :type 'etaf-view-syntax-error))

(ert-deftest etaf-view-ordinary-control-flow-belongs-in-expr ()
  "Reject ordinary Elisp control flow in the child region."
  (should-error
   (macroexpand '(etaf-view (text (if checked "yes" "no"))))
   :type 'etaf-view-syntax-error))

(ert-deftest etaf-view-quote-is-not-needed-for-structure ()
  "Construct an unquoted structural View and preserve quoted data values."
  (let ((view (etaf-view (text :face 'bold "Hello"))))
    (should (etaf--view-node-p view))
    (should (equal 'bold (plist-get (etaf--view-node-props view) :face)))
    (should (equal "Hello" (etaf-test--render-text view)))))

(ert-deftest etaf-view-attribute-values-are-ordinary-elisp ()
  "Evaluate an attribute expression without an extra evaluation wrapper."
  (let ((face 'bold)
        (label "Ready"))
    (let ((view (etaf-view (text :face face (expr :value label)))))
      (should (equal "Ready" (etaf-test--render-text view))))))

(ert-deftest etaf-view-expr-evaluates-control-flow ()
  "Use the sole child computation bridge for ordinary control flow."
  (let ((checked t))
    (should
     (equal "yes"
            (etaf-test--render-text
             (etaf-view
              (text (expr :value (if checked "yes" "no")))))))))

(ert-deftest etaf-view-expr-can-return-a-view ()
  "Allow an expression to return a dynamically constructed View."
  (let ((open t))
    (should
     (equal "Details"
            (etaf-test--render-text
             (etaf-view
              (column
               (expr
                :value
                (when open
                  (etaf-view (text "Details")))))))))))

(ert-deftest etaf-view-expr-can-return-a-sequence ()
  "Flatten a sequence returned by `expr' into the surrounding Host."
  (should
   (equal "AB"
          (etaf-test--render-text
           (etaf-view
            (text (expr :value (list "A" "B"))))))))

(ert-deftest etaf-view-expr-rejects-extra-properties ()
  "Reject an expr property other than `:value'."
  (should-error
   (macroexpand '(etaf-view (text (expr :test checked :value "yes"))))
   :type 'etaf-view-syntax-error))

(ert-deftest etaf-view-quoted-view-data-is-not-executed ()
  "Reject quoted View data when it reaches the executable child boundary."
  (should-error
   (macroexpand '(etaf-view (text (quote (text "not-a-view")))))
   :type 'etaf-view-syntax-error))

(ert-deftest etaf-view-layouts-lower-to-ebox ()
  "Lower row and column Hosts through Ebox's public constructors."
  (should
   (equal "AB"
          (etaf-test--render-text
           (etaf-view (row (text "A") (text "B"))))))
  (should
   (equal "A\nB"
          (etaf-test--render-text
           (etaf-view (column (text "A") (text "B")))))))

(ert-deftest etaf-view-prefixed-host-alias-lowers-to-canonical-host ()
  "Resolve an explicit `etaf-' Host spelling to its core Host name."
  (should
   (equal "Hello"
          (etaf-test--render-text
           (etaf-view (etaf-text "Hello"))))))

(ert-deftest etaf-component-view-renders-props ()
  "Render a stateless Component from its declared props."
  (let ((view (etaf-view (etaf-test-badge :label "Ready"))))
    (should (etaf--component-call-p view))
    (should (equal "Ready" (etaf-test--render-text view)))))

(ert-deftest etaf-component-prefixed-name-has-short-alias ()
  "Resolve an `etaf-' Component through its public View alias."
  (should
   (equal "Ready"
          (etaf-test--render-text
           (etaf-view (test-badge :label "Ready"))))))

(ert-deftest etaf-component-alias-avoids-elisp-collision ()
  "Use a semantic alias when the unprefixed name is an Elisp function."
  (should
   (equal "Items"
          (etaf-test--render-text
           (etaf-view (list-view :label "Items"))))))

(ert-deftest etaf-component-rejects-unknown-props ()
  "Reject undeclared Component props at the Component boundary."
  (should-error
   (etaf-view (etaf-test-badge :unknown t))
   :type 'etaf-component-call-error))

(ert-deftest etaf-component-rejects-unimplemented-definition-forms ()
  "Reject future clauses instead of assigning them accidental semantics."
  (should-error
   (macroexpand
    '(etaf-define-component future-component (&key value)
       :setup value))
   :type 'etaf-component-definition-error)
  (should-error
   (macroexpand
    '(etaf-define-component styled-component ()
       :styles (styles ("&" :color "red"))
       :view (text "x")))
   :type 'etaf-component-definition-error))

(ert-deftest etaf-mount-publishes-through-ebox ()
  "Mount a View into a buffer using Ebox's buffer publication API."
  (let ((buffer-name " *etaf-test-mount*"))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (etaf-view (text :color "#F4F6FB" "Mounted")))
          (with-current-buffer buffer-name
            (should (equal "Mounted" (buffer-string)))))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

;;; etaf-tests.el ends here
