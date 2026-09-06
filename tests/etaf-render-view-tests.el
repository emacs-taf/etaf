;;; etaf-render-view-tests.el --- Ordinary Elisp View frontend -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The render frontend shares View compilation and retained runtime semantics.

;;; Code:

(require 'ert)
(require 'bytecomp)
(require 'etaf)

(defvar etaf-rv--renders 0)
(defvar etaf-rv--left-reads 0)
(defvar etaf-rv--right-reads 0)
(defvar etaf-rv--events nil)

(defun etaf-rv--define (name arguments &rest clauses)
  "Define test Component NAME with ARGUMENTS and CLAUSES lexically."
  (etaf-component-redefine-run
   (lambda ()
     (eval `(etaf-define-component ,name ,arguments ,@clauses) t))))

(defmacro etaf-rv--with-buffer (&rest body)
  "Run BODY in a temporary buffer and always dispose its Runtime."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (unwind-protect
         (progn ,@body)
       (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
         (etaf-unmount runtime)))))

(ert-deftest etaf-render-view-equivalent-to-view-and-node ()
  "All frontends produce the same visible structure and Host properties."
  (etaf-rv--define 'etaf-rv-view '(&key label)
                   :view '(column :padding-inline 1
                            (text :font-weight 'bold (expr label))
                            (text "Body")))
  (etaf-rv--define 'etaf-rv-render '(&key label)
                   :render '(let ((caption label))
                              (etaf-view
                               (column :padding-inline 1
                                 (text :font-weight 'bold (expr caption))
                                 (text "Body")))))
  (etaf-rv--define 'etaf-rv-node '(&key label)
                   :render '(etaf-node
                             'column '(:padding-inline 1)
                             (list (etaf-node 'text '(:font-weight bold)
                                              (list label))
                                   (etaf-node 'text nil '("Body")))))
  (let ((outputs
         (mapcar
          (lambda (name)
            (etaf-rv--with-buffer
              (etaf-mount (current-buffer)
                          (etaf-node name '(:label "Title") nil))
              (list (buffer-substring-no-properties (point-min) (point-max))
                    (progn
                      (goto-char (point-min))
                      (search-forward "Title")
                      (get-text-property (match-beginning 0) 'face)))))
          '(etaf-rv-view etaf-rv-render etaf-rv-node))))
    (should (equal (car outputs) (cadr outputs)))
    (should (equal (car outputs) (caddr outputs)))))

(ert-deftest etaf-render-view-prop-loop-conflicts-match-view ()
  "Nested Views use Component prop validation during definition expansion."
  (dolist (body '((etaf-view
                  (column (text :for (item '("A")) :key item (expr item))))
                 (let ((prefix "item"))
                   (etaf-view
                    (column (text :for (item '("A")) :key item
                              (expr (concat prefix item))))))
                 (funcall
                  (lambda ()
                    (etaf-view
                     (column (text :for (item '("A")) :key item
                               (expr item))))))))
    (let ((failure
           (should-error
            (macroexpand
             `(etaf-define-component etaf-rv-conflict (&key item)
                :render ,body))
            :type 'etaf-view-syntax-error)))
      (should (string-match-p "conflicts with a Component prop"
                              (error-message-string failure)))))
  (should-error
   (macroexpand
    '(etaf-define-component etaf-rv-conflict (&key item)
       :view (column (text :for (item '("A")) :key item (expr item)))))
   :type 'etaf-view-syntax-error))

(ert-deftest etaf-render-view-preserves-ordinary-lexical-shadowing ()
  "Let and lambda bindings shadow prop shorthand using normal Elisp scope."
  (etaf-rv--define
   'etaf-rv-shadow '(&key label)
   :render
   '(let* ((original label)
           (label "local")
           (caption (funcall (lambda (label) (concat original "/" label))
                             label)))
      (etaf-view
       (box :ref 'etaf-rv-shadow-button
            :on-press (lambda () (push caption etaf-rv--events))
         (text (expr caption))))))
  (let ((etaf-rv--events nil))
    (etaf-rv--with-buffer
      (etaf-mount (current-buffer)
                  (etaf-node 'etaf-rv-shadow '(:label "prop") nil))
      (should (equal "prop/local" (buffer-string)))
      (etaf-dispatch-event (etaf-runtime-for-buffer (current-buffer))
                           'etaf-rv-shadow-button 'press)
      (should (equal '("prop/local") etaf-rv--events)))))

(ert-deftest etaf-render-view-retains-surrounding-macro-environment ()
  "A lexically scoped macro cannot hide a View from prop grammar checks."
  (should-error
   (macroexpand-all
    '(cl-macrolet
         ((local-view ()
            '(etaf-view
              (column (text :for (item '("A")) :key item (expr item))))))
       (etaf-define-component etaf-rv-macro-conflict (&key item)
         :render (local-view))))
   :type 'etaf-view-syntax-error))

(ert-deftest etaf-render-view-props-shadow-surrounding-symbol-macros ()
  "A Component's prop scope overrides same-named outer symbol macros."
  (etaf-component-redefine-run
   (lambda ()
     (eval
      '(cl-symbol-macrolet ((label "Outer"))
         (etaf-define-component etaf-rv-outer-shadow (&key label)
           :render (etaf-view (text (expr label)))))
      t)))
  (etaf-rv--with-buffer
    (etaf-mount (current-buffer)
                (etaf-node 'etaf-rv-outer-shadow '(:label "Prop") nil))
    (should (equal "Prop" (buffer-string)))))

(ert-deftest etaf-render-view-byte-compiled-callback-retains-lexical-props ()
  "Compiled Component definitions preserve the same delayed callback scope."
  (let ((byte-compile-error-on-warn t)
        (etaf-rv--events nil))
    (etaf-component-redefine-run
     (lambda ()
       (funcall
        (byte-compile
         '(lambda ()
            (etaf-define-component etaf-rv-compiled (&key label)
              :render
              (let ((caption label))
                (etaf-view
                 (box :ref 'etaf-rv-compiled-button
                      :on-press (lambda () (push caption etaf-rv--events))
                   (text (expr caption)))))))))))
    (etaf-rv--with-buffer
      (etaf-mount (current-buffer)
                  (etaf-node 'etaf-rv-compiled '(:label "Compiled") nil))
      (should (equal "Compiled" (buffer-string)))
      (etaf-dispatch-event (etaf-runtime-for-buffer (current-buffer))
                           'etaf-rv-compiled-button 'press)
      (should (equal '("Compiled") etaf-rv--events)))))

(ert-deftest etaf-render-view-keeps-deferred-dependencies-local ()
  "Capturing stable handles does not pull reactive reads into Component render."
  (etaf-rv--define
   'etaf-rv-deferred '(&key left right)
   :setup '(list left right)
   :render
   '(progn
      (cl-incf etaf-rv--renders)
      (let* ((state (etaf-state))
             (left-ref (car state))
             (right-ref (cadr state)))
        (etaf-view
         (column
           (text (expr (progn (cl-incf etaf-rv--left-reads)
                              (etaf-value left-ref))))
           (text (expr (progn (cl-incf etaf-rv--right-reads)
                              (etaf-value right-ref)))))))))
  (let ((left (etaf-ref "Left A"))
        (right (etaf-ref "Right A"))
        (etaf-rv--renders 0)
        (etaf-rv--left-reads 0)
        (etaf-rv--right-reads 0))
    (etaf-rv--with-buffer
      (etaf-mount (current-buffer)
                  (etaf-node 'etaf-rv-deferred (list :left left :right right)
                             nil))
      (let ((renders etaf-rv--renders)
            (left-reads etaf-rv--left-reads)
            (right-reads etaf-rv--right-reads))
        (setf (etaf-value left) "Left B")
        (should (string-match-p "Left B" (buffer-string)))
        (should (= renders etaf-rv--renders))
        (should (> etaf-rv--left-reads left-reads))
        (should (= right-reads etaf-rv--right-reads))))))

(ert-deftest etaf-render-view-projects-caller-owned-slots ()
  "Embedded Views distinguish projections from named inputs and caller props."
  (etaf-rv--define
   'etaf-rv-panel '(&key label)
   :render '(let ((heading label))
              (etaf-view
               (column
                 (text (expr heading))
                 (slot)
                 (slot :name 'footer (text "Fallback"))))))
  (etaf-rv--define
   'etaf-rv-slot-owner '(&key label)
   :render '(let ((caption label))
              (etaf-view
               (etaf-rv-panel :label "Panel"
                 (text (expr label))
                 (slot :name 'footer (text (expr (concat caption " footer"))))))))
  (etaf-rv--with-buffer
    (etaf-mount (current-buffer)
                (etaf-node 'etaf-rv-slot-owner '(:label "Caller") nil))
    (should (string-match-p "Panel[[:space:]]+Caller[[:space:]]+Caller footer"
                            (buffer-string)))
    (should-not (string-match-p "Fallback" (buffer-string))))
  (etaf-rv--with-buffer
    (etaf-mount (current-buffer)
                (etaf-node 'etaf-rv-panel '(:label "Panel") nil))
    (should (string-match-p "Fallback" (buffer-string)))))

(ert-deftest etaf-render-view-callback-captures-committed-prop-snapshot ()
  "A normal lexical callback uses new committed props and survives rollback."
  (etaf-rv--define
   'etaf-rv-snapshot '(&key label)
   :render '(let ((caption label))
              (etaf-view
               (box :ref 'etaf-rv-snapshot-button
                    :on-press (lambda () (push caption etaf-rv--events))
                 (text (expr caption))))))
  (let ((label (etaf-ref "A"))
        (etaf-rv--events nil))
    (etaf-rv--with-buffer
      (etaf-mount
       (current-buffer)
       (lambda ()
         (etaf-node
          'column nil
          (list (etaf-node 'etaf-rv-snapshot
                           (list :label (etaf-value label)) nil)
                (etaf-view
                 (text (expr (if (equal (etaf-value label) "Failed")
                                 (error "Rejected sibling")
                               "Sibling"))))))))
      (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
        (etaf-dispatch-event runtime 'etaf-rv-snapshot-button 'press)
        (setf (etaf-value label) "B")
        (etaf-dispatch-event runtime 'etaf-rv-snapshot-button 'press)
        (let ((published (buffer-string)))
          (should-error (setf (etaf-value label) "Failed"))
          (should (equal-including-properties published (buffer-string))))
        (etaf-dispatch-event runtime 'etaf-rv-snapshot-button 'press)
        (should (equal '("B" "B" "A") etaf-rv--events))))))

(ert-deftest etaf-render-view-callback-live-ref-is-not-a-ui-snapshot ()
  "An explicit shared ref remains live even when a sibling rejects its UI."
  (etaf-rv--define
   'etaf-rv-live '(&key model)
   :render '(let ((shared model))
              (etaf-view
               (box :ref 'etaf-rv-live-button
                    :on-press (lambda ()
                                (push (etaf-value shared) etaf-rv--events))
                 (text "Read live")))))
  (let ((model (etaf-ref "A"))
        (etaf-rv--events nil))
    (etaf-rv--with-buffer
      (etaf-mount
       (current-buffer)
       (etaf-node
        'column nil
        (list (etaf-node 'etaf-rv-live (list :model model) nil)
              (etaf-view
               (text (expr (if (equal (etaf-value model) "B")
                               (error "Rejected live value")
                             "Sibling")))))))
      (let ((runtime (etaf-runtime-for-buffer (current-buffer)))
            (published (buffer-string)))
        (should-error (setf (etaf-value model) "B"))
        (should (equal-including-properties published (buffer-string)))
        (etaf-dispatch-event runtime 'etaf-rv-live-button 'press)
        (should (equal '("B") etaf-rv--events))))))

(provide 'etaf-render-view-tests)
;;; etaf-render-view-tests.el ends here
