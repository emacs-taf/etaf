;;; etaf-viewport-tests.el --- Nested viewport regions through public APIs -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'etaf-test-support)

(etaf-define-component etaf-viewport-test-reader (&key seen)
  "Record the subtree's viewport into the cons cell SEEN."
  :setup
  (progn
    (etaf-watch-effect
     (lambda () (setcar seen (etaf-viewport))))
    nil)
  :view (text "reader"))

(etaf-define-component etaf-viewport-test-region (&key seen)
  "Wrap SEEN's reader in a viewport region that fills its parent."
  :view (etaf-viewport-region (etaf-viewport-test-reader :seen seen)))

(etaf-define-component etaf-viewport-test-fixed-region (&key seen height)
  "Wrap SEEN's reader in a viewport region of HEIGHT lines."
  :view (etaf-viewport-region :height (list 'lh (etaf-value height))
          (etaf-viewport-test-reader :seen seen)))

(etaf-define-component etaf-viewport-test-wrapper ()
  "Pass its default slot through a viewport region."
  :render
  (etaf-node 'etaf-viewport-region nil (etaf-current-slot 'default)))

(etaf-define-component etaf-viewport-test-toggle (&key show seen)
  "Show a four-line region around SEEN's reader only while SHOW is non-nil."
  :render
  (if (etaf-value show)
      (etaf-node 'etaf-viewport-region (list :height '(lh 4))
                 (list (etaf-node 'etaf-viewport-test-reader (list :seen seen) nil)))
    (etaf-node 'etaf-viewport-test-reader (list :seen seen) nil)))

(ert-deftest etaf-viewport-region-publishes-its-committed-size ()
  "Content below a region reads the region's committed box, not the mount."
  (let ((seen (cons nil nil)))
    (etaf-test-with-mount
        (runtime (etaf-view (etaf-viewport-test-region :seen seen))
                 (list :viewport-width 200 :viewport-height 10))
      (should (equal (car seen) (cons 200 10))))))

(ert-deftest etaf-viewport-falls-back-to-the-runtime-viewport ()
  "Without a region the subtree reads the mounted Runtime's viewport."
  (let ((seen (cons nil nil)))
    (etaf-test-with-mount
        (runtime (etaf-view (etaf-viewport-test-reader :seen seen))
                 (list :viewport-width 400 :viewport-height 12))
      (should (equal (car seen) (cons 400 12))))))

(ert-deftest etaf-viewport-region-reaches-slot-content ()
  "Content passed through a slot resolves the wrapping region."
  (let ((seen (cons nil nil)))
    (etaf-test-with-mount
        (runtime (etaf-view (etaf-viewport-test-wrapper
                             (etaf-viewport-test-reader :seen seen)))
                 (list :viewport-width 200 :viewport-height 10))
      (should (equal (car seen) (cons 200 10))))))

(ert-deftest etaf-viewport-region-republishes-after-a-region-resize ()
  "Changing a region's own size republishes it after the next flush."
  (let ((seen (cons nil nil))
        (height (etaf-ref 6)))
    (etaf-test-with-mount
        (runtime (etaf-view
                  (etaf-viewport-test-fixed-region :seen seen :height height))
                 (list :viewport-width 200 :viewport-height 10))
      (should (equal (car seen) (cons 200 6)))
      (etaf-set-value height 3)
      (should (equal (car seen) (cons 200 3))))))

(ert-deftest etaf-viewport-region-follows-the-mount-refit ()
  "A stretched region republishes after the Runtime viewport changes."
  (let ((seen (cons nil nil)))
    (etaf-test-with-mount
        (runtime (etaf-view (etaf-viewport-test-region :seen seen))
                 (list :viewport-width 200 :viewport-height 10))
      (should (equal (car seen) (cons 200 10)))
      (etaf-runtime-refit runtime 200 6)
      (etaf-runtime-flush runtime)
      (should (equal (car seen) (cons 200 6))))))

(ert-deftest etaf-viewport-nearest-region-wins ()
  "A nested region shadows the region around it."
  (let ((seen (cons nil nil)))
    (etaf-test-with-mount
        (runtime (etaf-view
                  (etaf-viewport-region :height '(lh 8)
                    (etaf-viewport-region :height '(lh 3)
                      (etaf-viewport-test-reader :seen seen))))
                 (list :viewport-width 200 :viewport-height 10))
      (should (equal (car seen) (cons 200 3))))))

(ert-deftest etaf-viewport-region-stops-publishing-when-removed ()
  "Removing a region returns its subtree to the Runtime viewport."
  (let ((seen (cons nil nil))
        (show (etaf-ref t)))
    (etaf-test-with-mount
        (runtime (etaf-view (etaf-viewport-test-toggle :show show :seen seen))
                 (list :viewport-width 200 :viewport-height 10))
      (should (equal (car seen) (cons 200 4)))
      (etaf-set-value show nil)
      (should (equal (car seen) (cons 200 10))))))

(ert-deftest etaf-viewport-window-metrics-need-a-graphic-window ()
  "The window viewport is nil without a graphical window and needs a Runtime."
  (etaf-test-with-mount (runtime (etaf-view (box "w")))
    (should-not (etaf-runtime-window-viewport runtime)))
  (should-error (etaf-runtime-window-viewport) :type 'etaf-runtime-error))

(provide 'etaf-viewport-tests)
;;; etaf-viewport-tests.el ends here
