;;; etaf-examples-tests.el --- ETAF executable example tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'etaf-counter-example)
(require 'etaf-data-example)
(require 'etaf-resource-example)

(defun etaf-examples-test--text (buffer)
  "Return plain rendered text from BUFFER."
  (with-current-buffer buffer
    (substring-no-properties (buffer-string))))

(ert-deftest etaf-examples-load-without-opening-buffers ()
  "Loading example libraries must not mount an application."
  (dolist (name (list etaf-counter-example-buffer-name
                      etaf-data-example-buffer-name
                      etaf-resource-example-buffer-name))
    (should-not (get-buffer name))))

(ert-deftest etaf-counter-example-drives-event-action-and-state ()
  "Drive the counter through its installed public event path."
  (unwind-protect
      (let* ((buffer (etaf-counter-example-open))
             (runtime (etaf-runtime-for-buffer buffer)))
        (should (string-match-p "COUNT  2"
                                (etaf-examples-test--text buffer)))
        (etaf-dispatch-event runtime 'counter-increment 'press)
        (should (string-match-p "COUNT  3"
                                (etaf-examples-test--text buffer)))
        (should (string-match-p "DOUBLE  6"
                                (etaf-examples-test--text buffer)))
        (etaf-dispatch-event runtime 'counter-reset 'press)
        (should (string-match-p "STATE  READY"
                                (etaf-examples-test--text buffer))))
    (etaf-counter-example-close)))

(ert-deftest etaf-data-example-owns-query-selection-and-mutation ()
  "Exercise Data query, selection, and mutation through mounted Hosts."
  (unwind-protect
      (let* ((buffer (etaf-data-example-open))
             (runtime (etaf-runtime-for-buffer buffer)))
        (should (string-match-p "5 records · 0 selected"
                                (etaf-examples-test--text buffer)))
        (etaf-dispatch-event runtime 'data-task-1 'press)
        (should (string-match-p "5 records · 1 selected"
                                (etaf-examples-test--text buffer)))
        (etaf-dispatch-event runtime 'data-add 'press)
        (should (string-match-p "Review example #6"
                                (etaf-examples-test--text buffer)))
        (etaf-dispatch-event runtime 'data-filter-done 'press)
        (should (string-match-p "Verify retained updates"
                                (etaf-examples-test--text buffer)))
        (should-not (string-match-p "Define the public boundary"
                                    (etaf-examples-test--text buffer))))
    (etaf-data-example-close)))

(ert-deftest etaf-resource-example-shows-errors-recovery-and-cleanup ()
  "Reload the Resource and keep failure state visible until recovery."
  (unwind-protect
      (let* ((buffer (etaf-resource-example-open))
             (runtime (etaf-runtime-for-buffer buffer)))
        (should (string-match-p "Generation 1 is healthy"
                                (etaf-examples-test--text buffer)))
        (etaf-dispatch-event runtime 'resource-fail 'press)
        (should (string-match-p "Synthetic service failure 2"
                                (etaf-examples-test--text buffer)))
        (should (string-match-p "CLEANUPS  1"
                                (etaf-examples-test--text buffer)))
        (etaf-dispatch-event runtime 'resource-reload 'press)
        (should (string-match-p "Generation 3 is healthy"
                                (etaf-examples-test--text buffer)))
        (etaf-dispatch-event runtime 'resource-reload 'press)
        (should (string-match-p "CLEANUPS  2"
                                (etaf-examples-test--text buffer))))
    (etaf-resource-example-close)))

(provide 'etaf-examples-tests)

;;; etaf-examples-tests.el ends here
