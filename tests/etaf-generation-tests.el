;;; etaf-generation-tests.el --- M3a generation authority gates -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'etaf)
(require 'etaf-generation)

(defun etaf-generation-test--view (visible)
  "Return a root View selected by reactive VISIBLE."
  (if (etaf-value visible)
      (etaf-view
       (text :ref 'generation-target :role 'button
             :on-press #'ignore "visible"))
    (etaf-view (text :ref 'generation-other "other"))))

(ert-deftest etaf-generation-authority-is-runtime-single-source ()
  "Runtime compatibility access reads and writes one authority object."
  (let* ((runtime (etaf--runtime-create))
         (first (etaf--generation-create :generation-id 1))
         (second (etaf--generation-create :generation-id 2)))
    (should-not (etaf-runtime-current-generation runtime))
    (setf (etaf-runtime-current-generation runtime) first)
    (let ((authority (etaf-runtime-generation-authority runtime)))
      (should (etaf-generation-authority-p authority))
      (should (eq first (etaf-generation-authority-current authority)))
      (should (eq first (etaf-runtime-current-generation runtime)))
      (setf (etaf-runtime-current-generation runtime) second)
      (should (eq authority (etaf-runtime-generation-authority runtime)))
      (should (eq second (etaf-runtime-current-generation runtime)))
      (should (zerop (etaf-generation-authority-token authority))))))

(ert-deftest etaf-generation-projection-is-detached-and-rejects-duplicates ()
  "Compatibility projections copy facts and reject ambiguous keys."
  (let* ((handlers '((host . ((press . callback)))))
         (projection
          (etaf-generation-project-mirrors handlers '((host :role button))))
         (handler-table (plist-get projection :handlers))
         (props-table (plist-get projection :host-props)))
    (setcdr (car handlers) 'mutated)
    (should (equal (gethash 'host handler-table) '((press . callback))))
    (should (equal (gethash 'host props-table) '(:role button)))
    (should-error
     (etaf-generation-project-mirror '((host . one) (host . two)))
     :type 'etaf-generation-error)))

(ert-deftest etaf-generation-mirrors-follow-committed-generation ()
  "Every commit projects exact mirrors and removes stale Host facts."
  (let ((buffer-name " *etaf-generation-mirror-test*")
        (visible (etaf-ref t)))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (lambda () (etaf-generation-test--view visible)))
          (let ((runtime (etaf-runtime-for-buffer buffer-name)))
            (should (etaf-runtime-generation-mirrors-consistent-p runtime))
            (should (etaf-runtime-handler-for runtime 'generation-target))
            (should (gethash 'generation-target
                             (etaf-runtime-handlers runtime)))
            (setf (etaf-value visible) nil)
            (should (etaf-runtime-generation-mirrors-consistent-p runtime))
            (should-not (etaf-runtime-handler-for runtime 'generation-target))
            (should-not (gethash 'generation-target
                                 (etaf-runtime-handlers runtime)))
            (should (gethash 'generation-other
                             (etaf-runtime-host-props runtime)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-generation-query-ignores-compatibility-mirror-drift ()
  "Corrupting a mirror never changes committed generation queries."
  (let ((buffer-name " *etaf-generation-query-test*")
        (visible (etaf-ref t)))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (lambda () (etaf-generation-test--view visible)))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (committed
                  (copy-tree
                   (etaf-runtime-handler-for runtime 'generation-target))))
            (puthash 'generation-target 'corrupt
                     (etaf-runtime-handlers runtime))
            (should-not (etaf-runtime-generation-mirrors-consistent-p runtime))
            (should (equal committed
                           (etaf-runtime-handler-for
                            runtime 'generation-target)))
            (setf (etaf-value visible) nil)
            (setf (etaf-value visible) t)
            (should (etaf-runtime-generation-mirrors-consistent-p runtime))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-generation-shadow-route-proves-legacy-equivalence ()
  "The shadow route accepts a legacy projection only when facts are equal."
  (let ((buffer-name " *etaf-generation-shadow-test*")
        (visible (etaf-ref t))
        (etaf-generation-mirror-route 'shadow))
    (unwind-protect
        (progn
          (etaf-mount buffer-name
                      (lambda () (etaf-generation-test--view visible)))
          (setf (etaf-value visible) nil)
          (let ((runtime (etaf-runtime-for-buffer buffer-name)))
            (should (etaf-runtime-generation-mirrors-consistent-p runtime))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-generation-rejects-unknown-mirror-route ()
  "An unknown compatibility route cannot silently publish mirrors."
  (let ((runtime (etaf--runtime-create
                  :generation-authority
                  (etaf-generation-authority-create)))
        (etaf-generation-mirror-route 'unknown))
    (should-error
     (etaf--runtime-install-generation-mirrors runtime nil t)
     :type 'etaf-generation-error)))

(provide 'etaf-generation-tests)

;;; etaf-generation-tests.el ends here
