;;; etaf-data.el --- Data controller and sources -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ETAF Data is a small reactive controller over explicit source capabilities.
;; A source is only a plist of callables; database, HTTP, file, and ORM
;; integrations belong in concrete source packages that provide those
;; callables.

;;; Code:

(require 'cl-lib)
(require 'etaf-reactive)

(define-error 'etaf-data-error "Invalid ETAF data operation")
(define-error 'etaf-data-stopped-error
  "ETAF data controller has been stopped"
  'etaf-data-error)

(cl-defstruct (etaf-data--controller
               (:constructor etaf-data--controller-create)
               (:predicate etaf-data-controller-p)
               (:conc-name etaf-data--controller-))
  "A reactive Data Controller."
  source
  scope
  query
  page
  page-size
  items
  total
  status
  error
  selection
  request-id
  stopped-p
  auto-load-p)

(defun etaf-data-source (&rest capabilities)
  "Create a Data source from callable CAPABILITIES.

CAPABILITIES is a plist.  `:load' is required and receives QUERY, PAGE, and
PAGE-SIZE.  It must return a plist containing at least `:items', and may return
`:total', `:page', and `:page-size'.  `:mutate' is optional and receives
OPERATION and PAYLOAD.  `:dispose' is optional and runs when the owning
controller stops."
  (let ((load (plist-get capabilities :load))
        (mutate (plist-get capabilities :mutate))
        (dispose (plist-get capabilities :dispose)))
    (unless (functionp load)
      (signal 'wrong-type-argument (list 'functionp load)))
    (dolist (entry `((:mutate . ,mutate)
                    (:dispose . ,dispose)))
      (when (and (cdr entry) (not (functionp (cdr entry))))
        (signal 'wrong-type-argument (list 'functionp (cdr entry)))))
    (append (list :etaf-data-source t) capabilities)))

(defun etaf-data-source-p (value)
  "Return non-nil when VALUE is an ETAF Data source."
  (and (listp value)
       (eq (plist-get value :etaf-data-source) t)
       (functionp (plist-get value :load))))

(defun etaf-data--source-function (source key required-p)
  "Return SOURCE function KEY, requiring it when REQUIRED-P is non-nil."
  (unless (etaf-data-source-p source)
    (signal 'wrong-type-argument (list 'etaf-data-source-p source)))
  (let ((function (plist-get source key)))
    (when (and required-p (not (functionp function)))
      (error "ETAF Data source lacks %S capability" key))
    function))

(defun etaf-data--record-value (record key)
  "Return RECORD value at KEY for plist, alist, or hash table records."
  (cond
   ((hash-table-p record) (gethash key record))
   ((and (proper-list-p record)
         (zerop (% (length record) 2))
         (keywordp (car record)))
    (plist-get record key))
   ((listp record) (alist-get key record))
   (t nil)))

(defun etaf-data--record-matches-p (record query)
  "Return whether RECORD matches memory source QUERY."
  (cond
   ((null query) t)
   ((functionp query) (funcall query record))
   ((stringp query)
    (string-match-p
     (regexp-quote (downcase query))
     (downcase (prin1-to-string record))))
   ((and (listp query) (keywordp (car query)))
    (cl-loop for (key value) on query by #'cddr
             always (equal (etaf-data--record-value record key) value)))
   ((listp query)
    (cl-loop for (key . value) in query
             always (equal (etaf-data--record-value record key) value)))
   (t (equal record query))))

(defun etaf-data--slice (items page page-size)
  "Return the PAGE and PAGE-SIZE window from ITEMS."
  (let* ((safe-page (max 1 (or page 1)))
         (safe-page-size (max 1 (or page-size 20)))
         (start (* (1- safe-page) safe-page-size))
         (end (min (length items) (+ start safe-page-size))))
    (if (>= start (length items))
        nil
      (cl-subseq items start end))))

(defun etaf-data--memory-record-id (record id-key)
  "Return RECORD identity using ID-KEY."
  (if id-key
      (etaf-data--record-value record id-key)
    record))

(defun etaf-data--memory-replace (items id-key payload)
  "Return ITEMS with the record matching PAYLOAD and ID-KEY replaced."
  (let* ((target-id (etaf-data--memory-record-id payload id-key))
         (matched-p nil)
         (next
          (mapcar
           (lambda (record)
             (if (equal (etaf-data--memory-record-id record id-key) target-id)
                 (progn
                   (setq matched-p t)
                   payload)
               record))
           items)))
    (unless matched-p
      (error "No memory source record for id %S" target-id))
    next))

;;;###autoload
(cl-defun etaf-data-memory-source (items &key id-key name)
  "Create an in-memory Data source over ITEMS.

ID-KEY identifies records for `replace', `update', and `delete' mutations.
NAME optionally labels the source for diagnostics.
Queries may be nil, a predicate, a search string, a plist, an alist, or an
exact value.  Supported mutations are `insert', `replace', `update', `delete',
and `reset'."
  (let* ((records (etaf-ref (copy-sequence items)
                            :name (or name 'etaf-data-memory-source)))
         (query-function
          (lambda (query current)
            (cl-remove-if-not
             (lambda (record)
               (etaf-data--record-matches-p record query))
             current))))
    (etaf-data-source
     :name name
     :load (lambda (query page page-size)
             (let* ((all (etaf-value records))
                    (filtered (funcall query-function query all)))
               (list :items (etaf-data--slice filtered page page-size)
                     :total (length filtered)
                     :page (max 1 (or page 1))
                     :page-size (max 1 (or page-size 20)))))
     :mutate (lambda (operation payload)
               (pcase operation
                 ('insert
                  (setf (etaf-value records)
                        (append (etaf-value records) (list payload))))
                 ((or 'replace 'update)
                  (setf (etaf-value records)
                        (etaf-data--memory-replace
                         (etaf-value records) id-key payload)))
                 ('delete
                  (let ((target-id (if id-key
                                       payload
                                     (etaf-data--memory-record-id
                                      payload id-key))))
                    (setf (etaf-value records)
                          (cl-remove-if
                           (lambda (record)
                             (equal (etaf-data--memory-record-id record id-key)
                                    target-id))
                           (etaf-value records)))))
                 ('reset
                  (setf (etaf-value records) (copy-sequence payload)))
                 (_
                  (error "Unsupported memory source mutation: %S"
                         operation)))
               (etaf-value records)))))

(defun etaf-data--require-controller (controller)
  "Signal unless CONTROLLER is a Data Controller."
  (unless (etaf-data-controller-p controller)
    (signal 'wrong-type-argument (list 'etaf-data-controller-p controller)))
  (when (etaf-data--controller-stopped-p controller)
    (signal 'etaf-data-stopped-error (list controller)))
  controller)

(defun etaf-data--normalize-result (result)
  "Return a normalized source RESULT plist."
  (unless (and (listp result)
               (or (null result) (keywordp (car result))))
    (error "ETAF Data source load must return a plist: %S" result))
  (unless (plist-member result :items)
    (error "ETAF Data source load result lacks :items"))
  result)

(defun etaf-data--apply-load-success (controller request-id result)
  "Publish successful RESULT for CONTROLLER when REQUEST-ID is current."
  (when (= request-id (etaf-data--controller-request-id controller))
    (let ((normalized (etaf-data--normalize-result result))
          (auto-load-p (etaf-data--controller-auto-load-p controller)))
      (unwind-protect
          (progn
            (setf (etaf-data--controller-auto-load-p controller) nil)
            (setf (etaf-value (etaf-data--controller-items controller))
                  (plist-get normalized :items))
            (setf (etaf-value (etaf-data--controller-total controller))
                  (or (plist-get normalized :total)
                      (length (plist-get normalized :items))))
            (when (plist-member normalized :page)
              (setf (etaf-value (etaf-data--controller-page controller))
                    (plist-get normalized :page)))
            (when (plist-member normalized :page-size)
              (setf (etaf-value (etaf-data--controller-page-size controller))
                    (plist-get normalized :page-size)))
            (setf (etaf-value (etaf-data--controller-error controller)) nil)
            (setf (etaf-value (etaf-data--controller-status controller))
                  'success))
        (setf (etaf-data--controller-auto-load-p controller) auto-load-p))))
  result)

(defun etaf-data--apply-error (controller request-id error-data)
  "Publish ERROR-DATA for CONTROLLER when REQUEST-ID is current."
  (when (= request-id (etaf-data--controller-request-id controller))
    (setf (etaf-value (etaf-data--controller-error controller)) error-data)
    (setf (etaf-value (etaf-data--controller-status controller)) 'error)))

;;;###autoload
(cl-defun etaf-data-controller
    (source &key query (page 1) (page-size 20) selection auto-load name)
  "Create a reactive Data Controller for SOURCE.

QUERY, PAGE, PAGE-SIZE, result ITEMS, TOTAL, STATUS, ERROR, and SELECTION are
stored in refs.  When AUTO-LOAD is non-nil, the controller loads immediately
and reloads after query or pagination refs change.  NAME optionally labels the
controller for diagnostics."
  (unless (etaf-data-source-p source)
    (signal 'wrong-type-argument (list 'etaf-data-source-p source)))
  (let* ((scope (etaf-effect-scope :detached t :name (or name 'etaf-data)))
         (controller
          (etaf-data--controller-create
           :source source
           :scope scope
           :query (etaf-ref query :name 'etaf-data-query)
           :page (etaf-ref page :name 'etaf-data-page)
           :page-size (etaf-ref page-size :name 'etaf-data-page-size)
           :items (etaf-ref nil :name 'etaf-data-items)
           :total (etaf-ref 0 :name 'etaf-data-total)
           :status (etaf-ref 'idle :name 'etaf-data-status)
           :error (etaf-ref nil :name 'etaf-data-error)
           :selection (etaf-ref (copy-sequence selection)
                                :name 'etaf-data-selection)
           :request-id 0
           :auto-load-p auto-load)))
    (etaf-scope-run
        scope
        (lambda ()
          (let ((effect
                 (etaf-reactive-effect-create
                  (lambda ()
                    (etaf-value (etaf-data--controller-query controller))
                    (etaf-value (etaf-data--controller-page controller))
                    (etaf-value (etaf-data--controller-page-size controller)))
                  :name 'etaf-data-auto-load
                  :scheduler
                  (lambda (_effect)
                    (when (and (etaf-data--controller-auto-load-p controller)
                               (not (etaf-data--controller-stopped-p
                                     controller)))
                      (etaf-data-load controller))))))
            (etaf-reactive-effect-run effect))
          (etaf-on-scope-dispose
           (lambda ()
             (when-let ((dispose (etaf-data--source-function
                                  source :dispose nil)))
               (funcall dispose))))))
    (when auto-load
      (etaf-data-load controller))
    controller))

;;;###autoload
(defun etaf-data-load (controller)
  "Load CONTROLLER from its source and publish loading, success, or error."
  (etaf-data--require-controller controller)
  (let ((request-id (1+ (etaf-data--controller-request-id controller))))
    (setf (etaf-data--controller-request-id controller) request-id)
    (setf (etaf-value (etaf-data--controller-status controller)) 'loading)
    (setf (etaf-value (etaf-data--controller-error controller)) nil)
    (condition-case err
        (etaf-data--apply-load-success
         controller
         request-id
         (funcall (etaf-data--source-function
                   (etaf-data--controller-source controller) :load t)
                  (etaf-value (etaf-data--controller-query controller))
                  (etaf-value (etaf-data--controller-page controller))
                  (etaf-value (etaf-data--controller-page-size controller))))
      (error
       (etaf-data--apply-error controller request-id err)
       (signal (car err) (cdr err))))))

;;;###autoload
(defun etaf-data-reload (controller)
  "Reload CONTROLLER and return the source result."
  (etaf-data-load controller))

;;;###autoload
(defun etaf-data-mutate (controller operation payload)
  "Run source OPERATION with PAYLOAD, then reload CONTROLLER.

Errors are stored in the controller error ref and re-signaled."
  (etaf-data--require-controller controller)
  (let ((request-id (1+ (etaf-data--controller-request-id controller))))
    (setf (etaf-data--controller-request-id controller) request-id)
    (setf (etaf-value (etaf-data--controller-status controller)) 'loading)
    (setf (etaf-value (etaf-data--controller-error controller)) nil)
    (condition-case err
        (progn
          (funcall (etaf-data--source-function
                    (etaf-data--controller-source controller) :mutate t)
                   operation payload)
          (etaf-data-load controller))
      (error
       (etaf-data--apply-error controller request-id err)
       (signal (car err) (cdr err))))))

;;;###autoload
(defun etaf-data-stop (controller)
  "Stop CONTROLLER, dispose its Scope, and return cleanup errors."
  (unless (etaf-data-controller-p controller)
    (signal 'wrong-type-argument (list 'etaf-data-controller-p controller)))
  (unless (etaf-data--controller-stopped-p controller)
    (setf (etaf-data--controller-stopped-p controller) t)
    (etaf-scope-stop (etaf-data--controller-scope controller))))

(defun etaf-data-query (controller)
  "Return CONTROLLER's query ref."
  (etaf-data--controller-query (etaf-data--require-controller controller)))

(defun etaf-data-page (controller)
  "Return CONTROLLER's page ref."
  (etaf-data--controller-page (etaf-data--require-controller controller)))

(defun etaf-data-page-size (controller)
  "Return CONTROLLER's page-size ref."
  (etaf-data--controller-page-size
   (etaf-data--require-controller controller)))

(defun etaf-data-items (controller)
  "Return CONTROLLER's loaded items ref."
  (etaf-data--controller-items (etaf-data--require-controller controller)))

(defun etaf-data-total (controller)
  "Return CONTROLLER's total matching item count ref."
  (etaf-data--controller-total (etaf-data--require-controller controller)))

(defun etaf-data-status (controller)
  "Return CONTROLLER's status ref.

The status value is one of `idle', `loading', `success', or `error'."
  (etaf-data--controller-status (etaf-data--require-controller controller)))

(defun etaf-data-error (controller)
  "Return CONTROLLER's observable error ref."
  (etaf-data--controller-error (etaf-data--require-controller controller)))

(defun etaf-data-selection (controller)
  "Return CONTROLLER's selected identity list ref."
  (etaf-data--controller-selection
   (etaf-data--require-controller controller)))

;;;###autoload
(defun etaf-data-set-query (controller query)
  "Set CONTROLLER query to QUERY and return QUERY."
  (setf (etaf-value (etaf-data-query controller)) query))

;;;###autoload
(defun etaf-data-set-page (controller page)
  "Set CONTROLLER page to PAGE and return PAGE."
  (setf (etaf-value (etaf-data-page controller)) page))

;;;###autoload
(defun etaf-data-set-page-size (controller page-size)
  "Set CONTROLLER page size to PAGE-SIZE and return PAGE-SIZE."
  (setf (etaf-value (etaf-data-page-size controller)) page-size))

;;;###autoload
(defun etaf-data-next-page (controller)
  "Move CONTROLLER to the next page and return the new page."
  (let ((next (1+ (etaf-value (etaf-data-page controller)))))
    (etaf-data-set-page controller next)))

;;;###autoload
(defun etaf-data-previous-page (controller)
  "Move CONTROLLER to the previous page and return the new page."
  (let ((previous (max 1 (1- (etaf-value (etaf-data-page controller))))))
    (etaf-data-set-page controller previous)))

;;;###autoload
(cl-defun etaf-data-select (controller identity &optional (selected-p t))
  "Select or deselect IDENTITY in CONTROLLER.

When SELECTED-P is nil, remove IDENTITY from the selection."
  (let* ((selection-ref (etaf-data-selection controller))
         (selection (etaf-value selection-ref)))
    (setf (etaf-value selection-ref)
          (if selected-p
              (cl-adjoin identity selection :test #'equal)
            (cl-remove identity selection :test #'equal)))))

;;;###autoload
(defun etaf-data-selected-p (controller identity)
  "Return non-nil when IDENTITY is selected in CONTROLLER."
  (member identity (etaf-value (etaf-data-selection controller))))

;;;###autoload
(defun etaf-data-clear-selection (controller)
  "Clear CONTROLLER selection and return nil."
  (setf (etaf-value (etaf-data-selection controller)) nil))

(provide 'etaf-data)

;;; etaf-data.el ends here
