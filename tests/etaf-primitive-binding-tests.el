;;; etaf-primitive-binding-tests.el --- Registered primitive publication -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Public Host state, dormant programs and reentrant observer writes remain
;; coherent when a mounted primitive set serves several sparse interactions.

;;; Code:

(require 'ert)
(require 'etaf)
(require 'ebox)

(etaf-define-component etaf-primitive-binding-test--choice (&key id active)
		       :view
		       (box :ref id :role 'button :width 'max-content
			    :class (if (eq id (etaf-value active)) "choice active" "choice")
			    :color (if (eq id (etaf-value active)) "#334155" "#64748B")
			    :background-color (if (eq id (etaf-value active)) "#C5D4E2" "#DCE6F0")
			    :border (if (eq id (etaf-value active))
					'((px 1) solid "#68809A") '((px 1) solid "#DCE6F0"))
			    :font-weight (if (eq id (etaf-value active)) 'bold 'normal)
			    (text (expr (symbol-name id)))))

(defun etaf-primitive-binding-test--view (active title z)
  "Return a public primitive View driven by ACTIVE, TITLE and Z."
  (etaf-view
   (column :width '(ch 40) :height '(lh 7)
	   (row :width 'stretch :height '(lh 1)
		(etaf-primitive-binding-test--choice :id 'one :active active)
		(etaf-primitive-binding-test--choice :id 'two :active active)
		(etaf-primitive-binding-test--choice :id 'three :active active))
	   (flex :width 'stretch :height '(lh 1)
		 (box :flex-grow 1 :flex-basis '(px 0) :min-width '(px 0)
		      :height '(lh 1) :wrap-mode 'none :overflow 'hidden
		      (text (expr (etaf-value title))))
		 (text "Tail"))
	   (box :position 'relative :width 'stretch :height '(lh 4)
		(box :ref 'raised :position 'absolute :left '(ch 1) :top '(lh 0)
		     :width '(ch 12) :height '(lh 3) :z-index (etaf-value z)
		     :background-color "#E2E8F0"
		     (text "Window"))
		(box :position 'absolute :left '(ch 4) :top '(lh 1)
		     :width '(ch 12) :height '(lh 2) :z-index 2
		     :background-color "#DCE6F0"
		     (text "Peer"))))))

(defun etaf-primitive-binding-test--appearance (text)
  "Return TEXT's public character, face and display presentation."
  (list (substring-no-properties text)
        (cl-loop for position below (length text)
                 collect (list (get-text-property position 'face text)
                               (get-text-property position 'display text)))))

(ert-deftest etaf-primitive-bindings-publish-selection-and-variable-status ()
  "One batch preserves classes, border paint, font, raise and varying titles."
  (let ((buffer (generate-new-buffer " *etaf-primitive-bindings*"))
        (fresh (generate-new-buffer " *etaf-primitive-bindings-fresh*"))
        (active (etaf-ref 'one)) (title (etaf-ref "Initial")) (z (etaf-ref 1)))
    (unwind-protect
        (let* ((runtime (etaf-runtime-for-buffer
                         (etaf-mount buffer (etaf-primitive-binding-test--view active title z))))
               (snapshot (etaf-runtime-snapshot runtime))
               (old (etaf-primitive-binding-test--appearance
                     (ebox-render (plist-get snapshot :input)))))
          (dolist (state '((two "A title longer than the original and the available status slot" 3)
                           (three "Short" 4) (one "" 5) (two "Restored" 6)))
            (let ((before (etaf-runtime-flush runtime)))
              (etaf-batch
               (etaf-set-value active (car state))
               (etaf-set-value title (cadr state))
               (etaf-set-value z (nth 2 state)))
              (should (= (1+ before) (etaf-runtime-flush runtime)))
              (let ((other (etaf-runtime-for-buffer
                            (etaf-mount fresh (etaf-primitive-binding-test--view active title z)))))
                (unwind-protect
                    (progn
                      (dolist (ref '(one two three raised))
                        (should (equal-including-properties
                                 (etaf-runtime-host-props-for runtime ref)
                                 (etaf-runtime-host-props-for other ref))))
                      (should (equal
                               (etaf-primitive-binding-test--appearance
                                (ebox-render (plist-get (etaf-runtime-snapshot runtime) :input)))
                               (etaf-primitive-binding-test--appearance
                                (ebox-render (plist-get (etaf-runtime-snapshot other) :input))))))
                  (etaf-unmount other)))))
          (should (equal old (etaf-primitive-binding-test--appearance
                              (ebox-render (plist-get snapshot :input))))))
      (dolist (target (list buffer fresh))
        (when-let* ((runtime (etaf-runtime-for-buffer target))) (etaf-unmount runtime))
        (kill-buffer target)))))

(etaf-define-component etaf-primitive-binding-test--dormant (&key source allowed)
		       :view
		       (box :position 'absolute :left '(ch 18) :top '(lh 0)
			    :width '(ch 10) :height '(lh 1)
			    (text (expr (progn
					  (unless (funcall allowed) (error "Dormant input was evaluated"))
					  (etaf-value source))))))

(ert-deftest etaf-primitive-bindings-leave-undirtied-programs-lazy ()
  "Updates to one mounted primitive do not evaluate an unrelated registered input."
  (let ((buffer (generate-new-buffer " *etaf-primitive-dormant*"))
        (x (etaf-ref '(ch 0))) (source (etaf-ref "Dormant")) (allowed t))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (box :position 'relative :width '(ch 32) :height '(lh 3)
		 (box :ref 'moving :position 'absolute :left (etaf-value x)
                      :top '(lh 0) :width '(ch 8) :height '(lh 1)
                      (text "Moving"))
		 (etaf-primitive-binding-test--dormant
		  :source source :allowed (lambda () allowed)))))
          (setq allowed nil)
          (etaf-set-value x '(ch 2))
          (should (equal '(ch 2)
                         (plist-get (etaf-runtime-host-props-for
                                     (etaf-runtime-for-buffer buffer) 'moving) :left)))
          (should (string-match-p "Dormant" (with-current-buffer buffer (buffer-string)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-primitive-bindings-observer-write-keeps-newer-input-pending ()
  "Observer writes through direct and derived dependencies retain newer input."
  (dolist (derived-p '(nil t))
    (let* ((buffer (generate-new-buffer " *etaf-primitive-observer*"))
           (value (etaf-ref "0"))
           (display (if derived-p (etaf-computed (lambda () (etaf-value value))) value))
           reported accepted)
      (unwind-protect
          (let ((runtime
                 (etaf-runtime-for-buffer
                  (etaf-mount
                   buffer
                   (etaf-view
                    (box :position 'relative :width '(ch 20) :height '(lh 3)
			 (box :position 'absolute :left '(ch 0) :top '(lh 0)
                              :width '(ch 8) :height '(lh 1)
                              (text (expr (etaf-value display))))))))))
            (ebox-buffer-set-observer
             buffer
             (lambda (_buffer report)
               (when (and (not reported)
                          (eq (plist-get report :provider) 'ebox-publication))
                 (setq reported t
                       accepted (with-current-buffer buffer (buffer-string)))
                 (etaf-set-value value "2"))))
            (etaf-set-value value "1")
            (should reported)
            (should (string-match-p "1" accepted))
            (should-not (string-match-p "2" accepted))
            (should (equal "2" (etaf-value value)))
            (should (string-match-p "2" (with-current-buffer buffer (buffer-string))))
            (should-not (string-match-p "1" (with-current-buffer buffer (buffer-string)))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
        (kill-buffer buffer)))))

(etaf-define-component etaf-primitive-binding-test--ordinary-chrome (&key active x)
		       :render
		       (let* ((selected (etaf-value active))
			      (color (if selected "#BB4422" "#8899AA"))
			      (controls
			       (cl-loop for ref in '(ordinary-close ordinary-minimize ordinary-maximize)
					for glyph in '("×" "−" "+")
					collect
					(etaf-node
					 'box (list :ref ref :role 'button :tab-index 0 :on-press #'ignore
						    :width '(ch 4) :height '(lh 1) :color color
						    :hover-content (concat glyph (if selected " on" " off")))
					 (list (etaf-node 'text nil (list "●")))))))
			 (etaf-view
			  (box :ref 'ordinary-window :position 'absolute :left (etaf-value x)
			       :top '(lh 0) :width '(ch 18) :height '(lh 2)
			       (row :width 'stretch :height '(lh 1) (expr controls))))))

(ert-deftest etaf-primitive-bindings-follow-explicit-component-render ()
  "Ordinary Component replacement keeps canonical sources paired before reuse."
  (let ((buffer (generate-new-buffer " *etaf-ordinary-chrome*"))
        (fresh (generate-new-buffer " *etaf-ordinary-chrome-fresh*"))
        (active (etaf-ref nil)) (x (etaf-ref '(ch 0))))
    (unwind-protect
        (progn
          (etaf-mount buffer
                      (etaf-view
                       (box :position 'relative :width '(ch 30) :height '(lh 4)
                            (etaf-primitive-binding-test--ordinary-chrome :active active :x x))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            ;; ACTIVE is deliberately read by :render above.  This remains an
            ;; ordinary Component update even when native fields have bindings.
            (etaf-set-value active t)
            (dolist (left '((ch 0) (ch 2)))
              (etaf-set-value x left)
              (let ((other
                     (etaf-runtime-for-buffer
                      (etaf-mount fresh
                                  (etaf-view
                                   (box :position 'relative :width '(ch 30) :height '(lh 4)
					(etaf-primitive-binding-test--ordinary-chrome
					 :active active :x x)))))))
                (unwind-protect
                    (progn
                      (should
                       (equal
                        (etaf-primitive-binding-test--appearance
                         (ebox-render (plist-get (etaf-runtime-snapshot runtime) :input)))
                        (etaf-primitive-binding-test--appearance
                         (ebox-render (plist-get (etaf-runtime-snapshot other) :input)))))
                      (dolist (ref '(ordinary-window ordinary-close ordinary-minimize ordinary-maximize))
                        (should (equal-including-properties
                                 (etaf-runtime-host-props-for runtime ref)
                                 (etaf-runtime-host-props-for other ref)))))
                  (etaf-unmount other))))))
      (dolist (target (list buffer fresh))
        (when-let* ((runtime (etaf-runtime-for-buffer target))) (etaf-unmount runtime))
        (kill-buffer target)))))

(etaf-define-component etaf-primitive-binding-test--hover
		       (&key content pulse reject report activate)
		       :setup (progn (etaf-on-updated report) nil)
		       :view
		       (box :position 'absolute :left '(ch 0) :top '(lh 0)
			    :width '(ch 8) :height '(lh 1)
			    (box :ref 'hover-control :role 'button :tab-index 0 :on-press activate
				 :width '(ch 4) :height '(lh 1)
				 :hover-content (let ((text (etaf-value content)))
						  (etaf-value pulse)
						  (when (funcall reject) (error "Rejected native content"))
						  text)
				 (text "●"))))

(ert-deftest etaf-primitive-bindings-hover-source-keeps-native-and-owner-lifecycle ()
  "Native hover sources keep activation, update hooks, rollback and retry."
  (let ((buffer (generate-new-buffer " *etaf-native-source*"))
        (content (etaf-ref "×")) (pulse (etaf-ref 0)) reject
        (updates 0) activated)
    (unwind-protect
        (save-window-excursion
          (etaf-mount
           buffer
           (etaf-view
            (box :position 'relative :width '(ch 16) :height '(lh 2)
		 (etaf-primitive-binding-test--hover
		  :content content :pulse pulse :reject (lambda () reject)
		  :report (lambda () (cl-incf updates))
		  :activate (lambda () (setq activated t))))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (before (etaf-runtime-generation runtime)))
            (etaf-set-value pulse 1)
            (should (= 1 updates))
            (should (= (1+ before) (etaf-runtime-generation runtime)))
            (etaf-set-value content "⊗")
            (should (= 2 updates))
            (should (equal "⊗" (plist-get (etaf-runtime-host-props-for runtime 'hover-control)
                                          :hover-content)))
            (set-window-buffer (selected-window) buffer)
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "●")
              (let ((hover (lookup-key ebox-buffer-mode-map [mouse-movement])))
                (funcall hover (list 'mouse-movement
                                     (list (selected-window) (1- (point)) '(1 . 1) 0)))
                (should (string-match-p "⊗" (buffer-string)))
                (funcall hover (list 'mouse-movement
                                     (list (selected-window) (point-max) '(80 . 80) 0)))
                (should (string-match-p "●" (buffer-string)))))
            (etaf-dispatch-event runtime 'hover-control 'press)
            (should activated)
            (setq reject t)
            (should-error (etaf-set-value content "+"))
            (should (= 2 updates))
            (should (equal "⊗" (plist-get (etaf-runtime-host-props-for runtime 'hover-control)
                                          :hover-content)))
            (setq reject nil)
            (etaf-runtime-flush runtime)
            (should (= 3 updates))
            (should (equal "+" (plist-get (etaf-runtime-host-props-for runtime 'hover-control)
                                          :hover-content)))
            (should (ebox-render (plist-get (etaf-runtime-snapshot runtime) :input)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-primitive-bindings-normalize-class-grammar-at-lowering ()
  "Box and Text selectors share whitespace/list/symbol classes with pure render."
  (let* ((buffer (generate-new-buffer " *etaf-class-tokens*"))
         (box-classes "  alpha\tbeta\n gamma  ")
         (text-classes '(alpha (" beta " gamma) "delta"))
         (view (etaf-view
                (box :ref 'class-box :class box-classes
                  (text :ref 'class-text :class text-classes "Class")))))
    (unwind-protect
        (progn
          (let ((input (etaf-render view)))
            (should (= 2 (length (ebox-selector-query-all input ".alpha.beta.gamma"))))
            (should (= 1 (length (ebox-selector-query-all input ".delta")))))
          (etaf-mount buffer view)
          (should (= 2 (length (ebox-select-all buffer ".alpha.beta.gamma"))))
          (should (= 1 (length (ebox-select-all buffer ".delta"))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (should (equal box-classes
                           (plist-get (etaf-runtime-host-props-for runtime 'class-box) :class)))
            (should (equal text-classes
                           (plist-get (etaf-runtime-host-props-for runtime 'class-text) :class)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-primitive-binding-tests)
;;; etaf-primitive-binding-tests.el ends here
