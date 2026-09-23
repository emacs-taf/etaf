;;; benchmark-scheduler-context.el --- ETAF dispatcher microbenchmark -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Runs the M3a T6 fixed scheduler scenario: 40 changed sources fan out to one
;; Effect in each of four isolated contexts.  Five warmups precede thirty timed
;; samples.  Exact work counters and a 50 ms p95/max gate make the result useful
;; as a small dispatcher regression baseline; product GUI performance is a
;; separate end-to-end gate.

;;; Code:

(require 'cl-lib)
(require 'etaf)

(defconst etaf-scheduler-benchmark-warmups 5)
(defconst etaf-scheduler-benchmark-samples 30)
(defconst etaf-scheduler-benchmark-source-count 40)
(defconst etaf-scheduler-benchmark-context-count 4)
(defconst etaf-scheduler-benchmark-limit-ms 50.0)

(defun etaf-scheduler-benchmark--percentile (values percentile)
  "Return nearest-rank PERCENTILE from numeric VALUES."
  (let* ((ordered (sort (copy-sequence values) #'<))
         (rank (max 1 (ceiling (* percentile (length ordered))))))
    (nth (1- rank) ordered)))

(defun etaf-scheduler-benchmark--metric-total (contexts key)
  "Return the sum of metric KEY across scheduler CONTEXTS."
  (cl-loop for context in contexts
           sum (or (plist-get (etaf-scheduler-context-metrics context) key)
                   0)))

(defun etaf-scheduler-benchmark--iteration (sources iteration)
  "Publish ITERATION through all reactive SOURCES once."
  (etaf-call-with-batch
   (lambda ()
     (cl-loop for source in sources
              for index from 0
              do (setf (etaf-value source)
                       (+ (* iteration 1000) index))))))

;;;###autoload
(defun etaf-scheduler-benchmark-run ()
  "Run the fixed scheduler benchmark, print its result, and return it."
  (let* ((contexts
          (cl-loop for index below etaf-scheduler-benchmark-context-count
                   collect
                   (etaf-scheduler-context-create
                    :name (list 'benchmark index))))
         (sources
          (cl-loop repeat etaf-scheduler-benchmark-source-count
                   collect (etaf-ref 0)))
         effects durations result)
    (unwind-protect
        (progn
          (dolist (context contexts)
            (let ((effect
                   (etaf-scheduler-call-with-context
                    context
                    (lambda ()
                      (etaf-reactive-effect-create
                       (lambda () (mapcar #'etaf-value sources)))))))
              (push effect effects)
              (etaf-reactive-effect-run effect)))
          (dotimes (index etaf-scheduler-benchmark-warmups)
            (etaf-scheduler-benchmark--iteration sources (1+ index)))
          (let ((source-before
                 (etaf-scheduler-benchmark--metric-total
                  contexts :source-enqueues))
                (visit-before
                 (etaf-scheduler-benchmark--metric-total
                  contexts :subscriber-visits))
                (effect-before
                 (etaf-scheduler-benchmark--metric-total
                  contexts :effect-evaluations))
                (turn-before
                 (etaf-scheduler-benchmark--metric-total
                  contexts :turn-count)))
            (dotimes (index etaf-scheduler-benchmark-samples)
              (let ((started (float-time)))
                (etaf-scheduler-benchmark--iteration
                 sources (+ etaf-scheduler-benchmark-warmups index 1))
                (push (* 1000.0 (- (float-time) started)) durations)))
            (setq durations (nreverse durations))
            (let* ((expected-source-work
                    (* etaf-scheduler-benchmark-samples
                       etaf-scheduler-benchmark-source-count
                       etaf-scheduler-benchmark-context-count))
                   (expected-context-work
                    (* etaf-scheduler-benchmark-samples
                       etaf-scheduler-benchmark-context-count))
                   (source-work
                    (- (etaf-scheduler-benchmark--metric-total
                        contexts :source-enqueues)
                       source-before))
                   (subscriber-visits
                    (- (etaf-scheduler-benchmark--metric-total
                        contexts :subscriber-visits)
                       visit-before))
                   (effect-work
                    (- (etaf-scheduler-benchmark--metric-total
                        contexts :effect-evaluations)
                       effect-before))
                   (turn-work
                    (- (etaf-scheduler-benchmark--metric-total
                        contexts :turn-count)
                       turn-before))
                   (p95
                    (etaf-scheduler-benchmark--percentile durations 0.95))
                   (maximum (apply #'max durations)))
              (unless (and (= source-work expected-source-work)
                           (= subscriber-visits expected-source-work)
                           (= effect-work expected-context-work)
                           (= turn-work expected-context-work))
                (error "Scheduler work counters diverged: %S"
                       (list source-work subscriber-visits
                             effect-work turn-work)))
              (setq result
                    (list
                     :scenario 'scheduler-40-sources-4-contexts
                     :warmups etaf-scheduler-benchmark-warmups
                     :samples etaf-scheduler-benchmark-samples
                     :p95-ms p95 :max-ms maximum
                     :source-enqueues source-work
                     :subscriber-visits subscriber-visits
                     :effect-evaluations effect-work
                     :turns turn-work))
              (when (or (> p95 etaf-scheduler-benchmark-limit-ms)
                        (> maximum etaf-scheduler-benchmark-limit-ms))
                (error "Scheduler benchmark exceeds %.1f ms: %S"
                       etaf-scheduler-benchmark-limit-ms result)))))
      (dolist (effect effects) (etaf--stop-effect effect)))
    (prin1 result)
    (terpri)
    result))

(provide 'benchmark-scheduler-context)

;;; benchmark-scheduler-context.el ends here
