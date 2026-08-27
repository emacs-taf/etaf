;;; etaf-observer-tests.el --- Scoped observer port tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for the dynamically scoped ETAF observer port.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf-observer)

(defun etaf-test-observer-context (sink &optional diagnostic)
  "Return a test observer context using SINK and DIAGNOSTIC."
  (etaf--observer-context-create
   :sink sink
   :operation-id 41
   :runtime-id 9
   :buffer-name "*etaf-test*"
   :diagnostic (or diagnostic #'ignore)))

(ert-deftest etaf-observer-stage-preserves-success-and-metadata ()
  "Observed stages preserve results and emit required flat metadata."
  (let (reports)
    (should
     (eq 'result
         (etaf--observer-call-with-context
          (etaf-test-observer-context
           (lambda (report) (push report reports)))
          (lambda ()
            (etaf-observer-with-stage ('etaf 'render :detail "root")
              'result)))))
    (let ((report (car reports)))
      (should (= 1 (length reports)))
      (should (= etaf-observer-report-format-version
                 (plist-get report :format-version)))
      (should (eq 'etaf (plist-get report :provider)))
      (should (eq 'render (plist-get report :stage)))
      (should (= 41 (plist-get report :operation-id)))
      (should (= 1 (plist-get report :sequence)))
      (should (= 9 (plist-get report :runtime-id)))
      (should (equal "*etaf-test*" (plist-get report :buffer-name)))
      (should (eq 'success (plist-get report :status)))
      (should (equal "root" (plist-get report :detail)))
      (should (>= (plist-get report :duration-ms) 0.0)))))

(ert-deftest etaf-observer-stage-preserves-error-and-quit ()
  "Observed failures are reported and re-signaled without translation."
  (let (reports error-condition quit-condition)
    (let ((context
           (etaf-test-observer-context
            (lambda (report) (push report reports)))))
      (setq error-condition
            (condition-case condition
                (etaf--observer-call-with-context
                 context
                 (lambda ()
                   (etaf-observer-with-stage ('etaf 'render)
                     (signal 'wrong-type-argument '(integerp bad)))))
              (error condition)))
      (setq quit-condition
            (condition-case condition
                (etaf--observer-call-with-context
                 context
                 (lambda ()
                   (etaf-observer-with-stage ('ebox 'commit)
                     (signal 'quit '(requested)))))
              (quit condition))))
    (should (equal '(wrong-type-argument integerp bad) error-condition))
    (should (equal '(quit requested) quit-condition))
    (setq reports (nreverse reports))
    (should (equal '(error quit)
                   (mapcar (lambda (report) (plist-get report :status))
                           reports)))
    (should (equal '(1 2)
                   (mapcar (lambda (report) (plist-get report :sequence))
                           reports)))))

(ert-deftest etaf-observer-emits-defensive-flat-copy ()
  "Observer mutation cannot alter the producer's report snapshot."
  (let* ((detail (copy-sequence "producer"))
         (report (list :provider 'ebox :stage 'commit
                       :status 'success :duration-ms 1.0
                       :detail (list detail)))
         (original (copy-tree report)))
    (etaf--observer-call-with-context
     (etaf-test-observer-context
      (lambda (delivered)
        (setcar delivered :mutated)
        (setcar (cdr delivered) 99)
        (aset (car (plist-get delivered :detail)) 0 ?!)))
     (lambda () (etaf-observer-emit report)))
    (should (equal original report))
    (should (equal "producer" detail))))

(ert-deftest etaf-observer-contains-observer-failures-and-invalid-reports ()
  "Observer and validation failures are diagnostics, not product failures."
  (let (diagnostics failure)
    (let ((context
           (etaf-test-observer-context
            (lambda (_report)
              (if (eq failure 'error)
                  (error "Observer error")
                (signal 'quit '(observer-quit))))
            (lambda (diagnostic) (push diagnostic diagnostics)))))
      (setq failure 'error)
      (should
       (eq 'product-result
           (etaf--observer-call-with-context
            context
            (lambda ()
              (prog1 'product-result
                (etaf-observer-emit
                 '(:provider etaf :stage render
                   :status success :duration-ms 0.0)))))))
      (setq failure 'quit)
      (etaf--observer-call-with-context
       context
       (lambda ()
         (etaf-observer-emit
          '(:provider etaf :stage commit
            :status success :duration-ms 0.0))))
      (etaf--observer-call-with-context
       context
       (lambda ()
         (etaf-observer-emit '(:provider etaf :nested (not flat))))))
    (should (equal '(observer-failure observer-failure invalid-report)
                   (mapcar (lambda (diagnostic)
                             (plist-get diagnostic :kind))
                           (nreverse diagnostics))))))

(ert-deftest etaf-observer-clears-context-during-reentrant-delivery ()
  "Observer reentry sees no active observation context."
  (let (context-seen reports)
    (etaf--observer-call-with-context
     (etaf-test-observer-context
      (lambda (report)
        (push report reports)
        (setq context-seen etaf--observer-context)
        (etaf-observer-with-stage ('etaf 'reentrant) 'ignored)))
     (lambda ()
       (etaf-observer-with-stage ('etaf 'outer) 'done)))
    (should-not context-seen)
    (should (= 1 (length reports)))
    (should (eq 'outer (plist-get (car reports) :stage)))))

(ert-deftest etaf-observer-nil-path-does-zero-instrumentation ()
  "The unobserved path does not time, allocate delivery, or inspect GC state."
  (let ((body-count 0)
        (etaf--observer-context nil))
    (cl-letf (((symbol-function 'float-time)
               (lambda (&optional _time) (error "Unexpected clock read")))
              ((symbol-function 'etaf--observer-call-stage)
               (lambda (&rest _arguments) (error "Unexpected stage wrapper")))
              ((symbol-function 'etaf-observer-emit)
               (lambda (&rest _arguments) (error "Unexpected report"))))
      (should
       (eq 'plain-result
           (etaf-observer-with-stage ('etaf 'render)
             (setq body-count (1+ body-count))
             'plain-result))))
    (should (= 1 body-count))))

(provide 'etaf-observer-tests)

;;; etaf-observer-tests.el ends here
