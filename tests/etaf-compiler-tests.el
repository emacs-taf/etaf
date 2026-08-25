;;; etaf-compiler-tests.el --- ETAF compiler slice tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'etaf)

(defmacro etaf-compiler-test--legacy-view (form)
  "Construct FORM through the pre-compiler View expansion for comparison."
  (etaf--compile-view-form form :projection))

(defun etaf-compiler-test--canonical (value)
  "Return VALUE as comparable View data, resolving lazy holes once."
  (cond
   ((etaf--expr-p value)
    (etaf-compiler-test--canonical (funcall (etaf--expr-thunk value))))
   ((etaf--view-node-p value)
    (list :host (etaf--view-node-name value)
          :props (etaf--resolve-property-plist (etaf--view-node-props value))
          :children (mapcar #'etaf-compiler-test--canonical
                            (etaf--view-node-children value))))
   ((etaf--slot-projection-p value)
    (list :slot (etaf--slot-projection-name value)
          :fallback (mapcar #'etaf-compiler-test--canonical
                            (etaf--slot-projection-fallback value))))
   ((stringp value) value)
   ((null value) nil)
   (t value)))

(defun etaf-compiler-test--interpreted (color text)
  "Return an interpreted fixture using COLOR and TEXT."
  (etaf-compiler-test--legacy-view
   (column :color color
    (column :padding '(1 2)
     (text "static"))
    (text (expr :value text)))))

(defun etaf-compiler-test--compiled (color text)
  "Return a compiled fixture using COLOR and TEXT."
  (etaf-compiled-view
   (column :color color
    (column :padding '(1 2)
     (text "static"))
    (text (expr :value text)))))

(defun etaf-compiler-test--fallback-view ()
  "Return a View containing the not-yet-compiled slot grammar."
  (etaf-compiled-view
   (column (slot (text "fallback")))))

(defun etaf-compiler-test--fallback-reference ()
  "Return the interpreted reference for `etaf-compiler-test--fallback-view'."
  (etaf-compiler-test--legacy-view
   (column (slot (text "fallback")))))

(ert-deftest etaf-compiled-view-fallback-is-exact ()
  "An unsupported slot keeps the existing View semantics."
  (let ((before (plist-get (etaf-compiler-statistics) :fallbacks)))
    (should
     (equal (etaf-compiler-test--canonical
             (etaf-compiler-test--fallback-view))
            (etaf-compiler-test--canonical
             (etaf-compiler-test--fallback-reference))))
    (should (= (1+ before)
               (plist-get (etaf-compiler-statistics) :fallbacks)))))

(defun etaf-compiler-test--compiled-supported (color)
  "Return a supported compiled fixture using COLOR."
  (etaf-compiled-view
   (column :color color
    (column :padding '(1 2)
     (text "static-a")
     (text "static-b"))
    (text :color "blue" "tail"))))

(defun etaf-compiler-test--interpreted-supported (color)
  "Return the matching interpreted fixture using COLOR."
  (etaf-compiler-test--legacy-view
   (column :color color
    (column :padding '(1 2)
     (text "static-a")
     (text "static-b"))
    (text :color "blue" "tail"))))

(ert-deftest etaf-compiled-view-supported-output-is-exact ()
  "A supported blueprint produces the same normalized View data."
  (should
   (equal (etaf-compiler-test--canonical
           (etaf-compiler-test--compiled-supported "green"))
          (etaf-compiler-test--canonical
           (etaf-compiler-test--interpreted-supported "green")))))

(ert-deftest etaf-compiled-view-reuses-static-subtrees ()
  "Repeated instantiation reuses a static child while rebuilding its root."
  (etaf-compiler-clear-cache)
  (let* ((first (etaf-compiler-test--compiled-supported "red"))
         (second (etaf-compiler-test--compiled-supported "blue"))
         (first-static (car (etaf--view-node-children first)))
         (second-static (car (etaf--view-node-children second))))
    (should-not (eq first second))
    (should (eq first-static second-static))))

(ert-deftest etaf-compiled-view-reduces-runtime-construction-work ()
  "A warmed blueprint constructs only its dynamic ancestor path."
  (etaf-compiler-clear-cache)
  (etaf-compiler-test--compiled-supported "warm")
  (let ((calls 0)
        (original (symbol-function 'etaf--view-call)))
    (cl-letf (((symbol-function 'etaf--view-call)
               (lambda (&rest arguments)
                 (cl-incf calls)
                 (apply original arguments))))
      (etaf-compiler-test--compiled-supported "next"))
    (should (= calls 1))
    (setq calls 0)
    (cl-letf (((symbol-function 'etaf--view-call)
               (lambda (&rest arguments)
                 (cl-incf calls)
                 (apply original arguments))))
      (etaf-compiler-test--interpreted-supported "next"))
    (should (> calls 1))))

(ert-deftest etaf-compiled-view-exposes-blueprint-coverage ()
  "The compiler reports static nodes, dynamic paths, and holes."
  (pcase-let* ((`(,blueprint . ,programs)
                (etaf-compiler--compile
                 '(column :color color
                   (column (text "static")))))
               (static (plist-get blueprint :static-nodes))
               (dynamic (plist-get blueprint :dynamic-nodes)))
    (should (equal (plist-get blueprint :abi)
                   etaf-compiler-blueprint-abi))
    (should (> static 0))
    (should (= dynamic 1))
    (should (= (length programs) 1))
    (should (= (plist-get blueprint :hole-count) 1))))

(ert-deftest etaf-compiled-view-expr-is-a-dynamic-child-hole ()
  "Expr becomes one dynamic child program without forcing root fallback."
  (pcase-let* ((`(,blueprint . ,programs)
                (etaf-compiler--compile
                 '(column (text (expr :value value)))))
               (root (plist-get blueprint :root))
               (text-block (car (plist-get root :children)))
               (expr-block (car (plist-get text-block :children))))
    (should (eq (plist-get expr-block :kind) 'expr))
    (should-not (plist-get root :static-p))
    (should (= (length programs) 1))))

(provide 'etaf-compiler-tests)
;;; etaf-compiler-tests.el ends here
