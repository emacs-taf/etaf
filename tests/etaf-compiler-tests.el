;;; etaf-compiler-tests.el --- ETAF compiler slice tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'etaf)

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

(defun etaf-compiler-test--lowered (color text)
  "Return an automatically lowered fixture using COLOR and TEXT."
  (etaf-view
   (column :color color
    (column :padding '(1 2)
     (text "static"))
    (text (expr text)))))

(defun etaf-compiler-test--slot-view ()
  "Return a blueprint-backed View containing a slot projection."
  (etaf-view
   (column (slot (text "fallback")))))

(ert-deftest etaf-automatic-view-slot-uses-current-blueprint-abi ()
  "Slot projection is a `/2' block and never takes a compatibility path."
  (let* ((before (plist-get (etaf-compiler-statistics) :instantiations))
         (view (etaf-compiler-test--slot-view))
         (after (etaf-compiler-statistics))
         (root (plist-get etaf-compiler--last-blueprint :root)))
    (should (etaf--slot-projection-p
             (car (etaf--view-node-children view))))
    (should (eq 'slot
                (plist-get (car (plist-get root :children)) :kind)))
    (should (= (1+ before) (plist-get after :instantiations)))
    (should-not (plist-member after :fallbacks))))

(defun etaf-compiler-test--lowered-supported (color)
  "Return a supported automatically lowered fixture using COLOR."
  (etaf-view
   (column :color color
    (column :padding '(1 2)
     (text "static-a")
     (text "static-b"))
    (text :color "blue" "tail"))))

(ert-deftest etaf-automatic-view-supported-output-is-exact ()
  "A blueprint produces the exact normalized typed View data."
  (should
   (equal (etaf-compiler-test--canonical
           (etaf-compiler-test--lowered-supported "green"))
          '(:host column :props (:color "green")
            :children
            ((:host column :props (:padding (1 2))
              :children
              ((:host text :props nil :children ("static-a"))
               (:host text :props nil :children ("static-b"))))
             (:host text :props (:color "blue") :children ("tail")))))))

(ert-deftest etaf-automatic-view-reuses-static-subtrees ()
  "Repeated instantiation reuses a static child while rebuilding its root."
  (etaf-compiler-clear-cache)
  (let* ((first (etaf-compiler-test--lowered-supported "red"))
         (second (etaf-compiler-test--lowered-supported "blue"))
         (first-static (car (etaf--view-node-children first)))
         (second-static (car (etaf--view-node-children second))))
    (should-not (eq first second))
    (should (eq first-static second-static))))

(ert-deftest etaf-automatic-view-reduces-runtime-construction-work ()
  "A warmed blueprint constructs only its dynamic ancestor path."
  (etaf-compiler-clear-cache)
  (etaf-compiler-test--lowered-supported "warm")
  (let ((calls 0)
        (original (symbol-function 'etaf--view-call)))
    (cl-letf (((symbol-function 'etaf--view-call)
               (lambda (&rest arguments)
                 (cl-incf calls)
                 (apply original arguments))))
      (etaf-compiler-test--lowered-supported "next"))
    (should (= calls 1))))

(ert-deftest etaf-automatic-view-exposes-blueprint-coverage ()
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

(ert-deftest etaf-automatic-view-expr-is-a-dynamic-child-hole ()
  "Expr becomes one dynamic child program without forcing root fallback."
  (pcase-let* ((`(,blueprint . ,programs)
                (etaf-compiler--compile
                 '(column (text (expr value)))))
               (root (plist-get blueprint :root))
               (text-block (car (plist-get root :children)))
               (expr-block (car (plist-get text-block :children))))
    (should (eq (plist-get expr-block :kind) 'expr))
    (should-not (plist-get root :static-p))
    (should (= (length programs) 1))))

(ert-deftest etaf-automatic-view-directives-are-blueprint-blocks ()
  "Branch and keyed list topology are represented inside the `/2' blueprint."
  (pcase-let* ((`(,blueprint . ,programs)
                (etaf-compiler--compile
                 '(column
                    (text :if selected "selected")
                    (text :else t "empty")
                    (row :for (item items) :key (car item)
                      (text (expr (cdr item)))))))
               (children (plist-get (plist-get blueprint :root) :children)))
    (should (equal '(branch keyed-list)
                   (mapcar (lambda (block) (plist-get block :kind)) children)))
    (should (= 2 (length programs)))
    (should (= 2 (plist-get blueprint :hole-count)))))

(ert-deftest etaf-automatic-view-rejects-stale-blueprint-abi ()
  "A stale View IR requests a clean rebuild instead of compatibility."
  (let ((blueprint
         (list :kind 'etaf/view-blueprint
               :abi "etaf-view-blueprint/1"
               :id "stale" :root nil :hole-count 0)))
    (should-error (etaf-compiler-instantiate blueprint [])
                  :type 'error)))

(provide 'etaf-compiler-tests)
;;; etaf-compiler-tests.el ends here
