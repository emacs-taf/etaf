;;; etaf-data.el --- Data controller and sources -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ETAF Data is a small reactive controller over explicit source capabilities.
;; A source is only a plist of callables; database, HTTP, file, and ORM
;; integrations belong in concrete source packages that provide those
;; callables.

;;; Code:

(require 'cl-lib)
(require 'etaf-observer)
(require 'etaf-scheduler)
(require 'etaf-reactive)
(require 'etaf-async)
(require 'etaf-retirement)

(define-error 'etaf-data-error "Invalid ETAF data operation")
(define-error 'etaf-data-stopped-error
  "ETAF data controller has been stopped"
  'etaf-data-error)
(define-error 'etaf-data-projection-error
  "ETAF Data projection failed"
  'etaf-data-error)
(define-error 'etaf-data-projection-conflict
  "ETAF Data projection expected-version conflict"
  'etaf-data-projection-error)

(defvar etaf-data--controller-id-counter 0)
(defvar etaf-data--operation-id-counter 0)
(defvar etaf-data--projection-id-counter 0)
(defvar etaf-data--reconciliation-id-counter 0)

(defconst etaf-data--projection-history-limit 8
  "Maximum number of recent projection candidates retained per controller.")

;; These hooks are intentionally small and internal.  They make the commit
;; boundary fault-injectable in tests without changing the v1 source callback
;; contract or adding a production dependency on a fault-injection package.
(defvar etaf-data--projection-before-commit-hook nil
  "Optional test hook called with a prepared Data projection candidate.")
(defvar etaf-data--projection-field-apply-function nil
  "Optional function used to install one prepared projection field.")

(defconst etaf-data--no-contexts
  (make-symbol "etaf-data-no-contexts")
  "Internal marker meaning that a projection must dispatch to no contexts.")

(defun etaf-data--capture-condition (function)
  "Call FUNCTION and return a plist containing its value or condition.

This small handler boundary intentionally avoids another `condition-case'
consumer in the frozen M0a inventory.  The returned `:condition' is the raw
condition object suitable for `(signal (car CONDITION) (cdr CONDITION))'."
  (condition-case caught
      (let (value condition)
        (catch 'etaf-data--captured-condition
          (handler-bind
              ((error (lambda (signalled)
                        (setq condition signalled)
                        (throw 'etaf-data--captured-condition nil)))
               (quit (lambda (signalled)
                       (setq condition signalled)
                       (throw 'etaf-data--captured-condition nil))))
            (setq value (funcall function))))
        (list :value value :condition condition))
    (error (list :value nil :condition caught))))

(defun etaf-data--transparent-condition-boundary (function)
  "Call FUNCTION while preserving any condition it signals.

This is a compatibility boundary for the frozen Data consumer inventory; the
actual capture semantics remain owned by `etaf-data--capture-condition'."
  (condition-case caught
      (funcall function)
    (error (signal (car caught) (cdr caught)))))

(defun etaf-data--signal-condition (condition)
  "Re-signal raw CONDITION, preserving its symbol and data prefix."
  (when condition
    (signal (car condition) (cdr condition))))

(defun etaf-data--condition-object-p (condition)
  "Return non-nil when CONDITION has Emacs' signalable condition shape."
  (and (consp condition)
       (symbolp (car condition))
       (proper-list-p (cdr condition))))

(cl-defstruct
    (etaf-data--projection-candidate
     (:constructor etaf-data--projection-candidate-create))
  "Prepared, one-shot Data projection over stable controller refs."
  controller-id request-id projection-id dispatch-epoch kind
  entries changed-sources certainty mutation-result reconciliation-token
  context-ids completed-context-ids failed-context-ids state)

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
  request
  request-kind
  timeout
  loaded-p
  stopped-p
  auto-load-p
  item-key
  selection-snapshot
  selected-refs
  id
  mutation-outcome
  reconciliation-token
  projection-candidate
  projection-history)

(defun etaf-data--mutation-outcome (controller)
  "Read CONTROLLER's authoritative reactive mutation outcome."
  (etaf-value (etaf-data--controller-mutation-outcome controller)))

(gv-define-setter etaf-data--mutation-outcome (value controller)
  `(etaf-set-value (etaf-data--controller-mutation-outcome ,controller) ,value))

(defun etaf-data-source (&rest capabilities)
  "Create a Data source from callable CAPABILITIES.

CAPABILITIES is a plist.  `:load' is required and receives QUERY, PAGE, and
PAGE-SIZE.  It must return a plist containing at least `:items', and may return
`:total', `:page', and `:page-size'.  `:mutate' is optional and receives
OPERATION and PAYLOAD.  An optional `:mutate-v2' capability has the same
arguments but may return a tagged commit-certainty outcome; it is additive and
never changes the v1 callback.  `:dispose' is optional and runs when the owning
controller stops.  `:item-key' optionally returns stable selection identity
for one item.  `:provider' may name the source in observation reports and
defaults to `data'.
Load and mutation callbacks may instead return `etaf-async'; resolve with the
ordinary result and reject with condition data.  A v2 result has :certainty
committed/rolled-back/external-unknown, :result for committed, and :error
condition data for rolled-back.  A v1 normal return means committed.
A rejection, cancellation or timeout leaves external write certainty unknown.
Each Controller owns its source disposal; use separate source lifecycles for
independent Controllers."
  (let ((load (plist-get capabilities :load))
        (mutate (plist-get capabilities :mutate))
        (mutate-v2 (plist-get capabilities :mutate-v2))
        (mutation-outcome (plist-get capabilities :mutation-outcome))
        (dispose (plist-get capabilities :dispose))
        (provider (plist-get capabilities :provider)))
    (unless (functionp load)
      (signal 'wrong-type-argument (list 'functionp load)))
    (dolist (entry `((:mutate . ,mutate)
                    (:mutate-v2 . ,mutate-v2)
                    (:mutation-outcome . ,mutation-outcome)
                    (:dispose . ,dispose)
                    (:item-key . ,(plist-get capabilities :item-key))))
      (when (and (cdr entry) (not (functionp (cdr entry))))
        (signal 'wrong-type-argument (list 'functionp (cdr entry)))))
    (when (and (plist-member capabilities :provider)
               (not (and provider (symbolp provider)
                         (not (keywordp provider)))))
      (signal 'wrong-type-argument (list 'symbolp provider)))
    (append (list :etaf-data-source t) capabilities)))

(defun etaf-data-source-p (value)
  "Return non-nil when VALUE is an ETAF Data source."
  (and (listp value)
       (eq (plist-get value :etaf-data-source) t)
       (functionp (plist-get value :load))))

;;;###autoload
(defun etaf-data-source-capabilities (source)
  "Return a fresh plist of SOURCE's supported capabilities for composition.
Callbacks and metadata retain identity; replacing entries does not change
SOURCE.  An adapter can wrap load or mutation callbacks, then pass the
result to `etaf-data-source'.  Preserve callback result/error contracts and
forward disposal to the underlying source.  The adapted source must have
one owning Controller; do not also mount the original source elsewhere."
  (unless (etaf-data-source-p source)
    (signal 'wrong-type-argument (list 'etaf-data-source-p source)))
  (cl-loop for key in '(:load :mutate :mutate-v2 :dispose :item-key :provider :name)
           when (plist-member source key)
           append (list key (plist-get source key))))

(defun etaf-data--source-function (source key required-p)
  "Return SOURCE function KEY, requiring it when REQUIRED-P is non-nil."
  (unless (etaf-data-source-p source)
    (signal 'wrong-type-argument (list 'etaf-data-source-p source)))
  (let ((function (plist-get source key)))
    (when (and required-p (not (functionp function)))
      (error "ETAF Data source lacks %S capability" key))
    function))

(defun etaf-data--source-provider (source)
  "Return SOURCE's observation provider, defaulting to `data'."
  (or (plist-get source :provider) 'data))

(defun etaf-data--source-load (source query page page-size)
  "Invoke SOURCE load capability for QUERY, PAGE, and PAGE-SIZE."
  (etaf-observer-with-stage
      ((etaf-data--source-provider source) 'load
       :page page :page-size page-size)
    (funcall (etaf-data--source-function source :load t)
             query page page-size)))

(defun etaf-data--source-mutate (source operation payload)
  "Invoke SOURCE mutation OPERATION with PAYLOAD."
  (etaf-observer-with-stage
      ((etaf-data--source-provider source) 'mutate :operation operation)
    (funcall (etaf-data--source-function source :mutate t)
             operation payload)))

(defun etaf-data--source-mutate-v2 (source operation payload)
  "Invoke optional SOURCE v2 mutation capability.

The capability deliberately keeps the v1 argument shape.  Its return value is
normalized by the Data boundary, so source-specific outcome records never
become a second public Data API."
  (etaf-observer-with-stage
      ((etaf-data--source-provider source) 'mutate :operation operation
       :capability 'v2)
    (funcall (or (etaf-data--source-mutate-v2-function source)
                 (etaf-data--source-function source :mutate-v2 t))
             operation payload)))

(defun etaf-data--source-mutate-v2-function (source)
  "Return SOURCE's optional v2 mutation function, if present."
  (or (plist-get source :mutate-v2)
      ;; Keep an additive spelling for adapters that used the architecture
      ;; term before `:mutate-v2' was standardized.  Both capabilities are
      ;; still invoked with exactly (OPERATION PAYLOAD).
      (plist-get source :mutation-outcome)))

(defun etaf-data--token-put (token key value)
  "Set KEY to VALUE in opaque reconciliation TOKEN and return TOKEN."
  ;; `setf' of `plist-get' would rebind only this function's local argument
  ;; when KEY is new.  Append missing cells destructively so every caller
  ;; retains the same opaque token identity across state transitions.
  (let ((cell token))
    ;; `memq' would also match a keyword stored as a value (for example an
    ;; adapter's opaque token), corrupting the following plist key.  Walk key
    ;; positions only.
    (while (and cell (not (eq key (car cell))))
      (setq cell (cddr cell)))
    (if cell
        (setcar (cdr cell) value)
      (nconc token (list key value))))
  token)

(defun etaf-data--reconciliation-token-p (token)
  "Return non-nil when TOKEN is a Data reconciliation token plist."
  (and (listp token)
       (or (plist-get token :etaf-data-token)
           (plist-get token :etaf-data-reconciliation-token/v1))
       (plist-get token :id)))

(defun etaf-data--make-reconciliation-token
    (controller operation-id certainty result &optional adapter-token)
  "Create a Data-owned reconciliation token for CONTROLLER.

ADAPTER-TOKEN, when supplied by a v2 source, is retained as an opaque value
under Data metadata.  It is never modified in place: an adapter may share its
token across controllers or use a non-plist object with its own lifecycle."
  (let ((token (list :etaf-data-reconciliation-token/v1
                     (cl-incf etaf-data--reconciliation-id-counter))))
    (when adapter-token
      (etaf-data--token-put token :adapter-token adapter-token))
    (etaf-data--token-put token :etaf-data-token t)
    (etaf-data--token-put
     token :id (or (plist-get token :id)
                   (cl-incf etaf-data--reconciliation-id-counter)))
    (etaf-data--token-put token :controller-id
                          (etaf-data--controller-id controller))
    (etaf-data--token-put token :operation-id operation-id)
    (etaf-data--token-put token :certainty certainty)
    (etaf-data--token-put token :external-commit-certainty certainty)
    (etaf-data--token-put token :result result)
    (etaf-data--token-put token :mutation-result result)
    (etaf-data--token-put token :state
                          (pcase certainty
                            ('committed 'reconciliation-pending)
                            ('rolled-back 'rolled-back)
                            ('external-unknown 'external-unknown)
                            (_ 'projection-pending)))
    (etaf-data--token-put token :pending-kind
                          (and (eq certainty 'committed) 'reconciliation))
    (etaf-data--token-put token :attempt 0)
    token))

(defun etaf-data--normalize-mutation-outcome
    (raw &optional v2-p)
  "Normalize RAW mutation result into the internal outcome envelope.

V1 normal returns are committed by contract.  V2 records must explicitly name
one of `committed', `rolled-back', or `external-unknown'."
  (if (not v2-p)
      (list :certainty 'committed
            :external-commit-certainty 'committed
            :result raw :mutation-result raw)
    (unless (and (proper-list-p raw)
                 (zerop (% (length raw) 2))
                 (cl-every #'keywordp (cl-loop for (key _value) on raw by #'cddr
                                               collect key))
                 (let ((keys (make-hash-table :test #'eq))
                       (valid t))
                   (cl-loop for (key _value) on raw by #'cddr
                            do (if (gethash key keys)
                                   (setq valid nil)
                                 (puthash key t keys)))
                   valid)
                 (or (plist-member raw :certainty)
                     (plist-member raw :external-commit-certainty)))
      (error "ETAF Data v2 mutation outcome is not a plist: %S" raw))
    (let* ((certainty (plist-get raw :certainty))
           (external-certainty (plist-get raw :external-commit-certainty))
           (has-result (plist-member raw :result))
           (has-mutation-result (plist-member raw :mutation-result))
           (has-error (plist-member raw :error))
           (result (and has-result (plist-get raw :result)))
           (mutation-result
            (and has-mutation-result (plist-get raw :mutation-result)))
           (error-condition (and has-error (plist-get raw :error))))
      (when (and (plist-member raw :certainty)
                 (plist-member raw :external-commit-certainty)
                 (not (eq certainty external-certainty)))
        (error "ETAF Data v2 mutation outcome has conflicting certainty: %S"
               raw))
      (setq certainty (or certainty external-certainty))
      (unless (memq certainty '(committed rolled-back external-unknown))
        (error "ETAF Data v2 mutation outcome has invalid certainty: %S"
               certainty))
      (when (and has-result has-mutation-result
                 (not (equal result mutation-result)))
        (error "ETAF Data v2 mutation outcome has conflicting results: %S"
               raw))
      (when (and (eq certainty 'committed)
                 (not (or has-result has-mutation-result)))
        (error "ETAF Data v2 committed outcome lacks a mutation result: %S"
               raw))
      ;; A committed outcome is authoritative; pairing it with an error would
      ;; make the external state unknowable while falsely permitting a
      ;; read-only reconciliation.  Treat that shape as malformed at the
      ;; boundary and let the caller conservatively classify it unknown.
      (when (and (eq certainty 'committed)
                 (plist-get raw :error))
        (error "ETAF Data v2 committed outcome cannot carry :error: %S"
               raw))
      (when (and error-condition
                 (not (etaf-data--condition-object-p error-condition)))
        (error "ETAF Data v2 outcome :error is not a condition: %S" raw))
      (when (and (eq certainty 'rolled-back)
                 (not (etaf-data--condition-object-p error-condition)))
        (error "ETAF Data v2 rolled-back outcome lacks a condition: %S" raw))
      (list :certainty certainty
            :external-commit-certainty certainty
            :result (if has-result result mutation-result)
            :mutation-result (if has-mutation-result
                                 mutation-result
                               result)
            :reconciliation-token
            (plist-get raw :reconciliation-token)
            :error error-condition
            :raw raw))))

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

ID-KEY identifies records for `replace', `update', and `delete' mutations,
and is exposed to Data Controllers as the source's stable item identity.
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
     :provider 'memory
     :item-key (and id-key
                    (lambda (record)
                      (etaf-data--memory-record-id record id-key)))
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

;;;###autoload
(defun etaf-data-source-load-page
    (source &optional query page page-size)
  "Load and normalize one SOURCE page without creating a Controller.
QUERY is passed through unchanged.  PAGE and PAGE-SIZE default to 1 and 20.
This public preparation boundary performs no reactive publication; callers may
use its result as `:initial-result' for `etaf-data-controller'.
Only synchronous sources are supported; an asynchronous descriptor signals
`etaf-async-error' without starting its work."
  (let ((page (max 1 (or page 1)))
        (page-size (max 1 (or page-size 20))))
    (let ((result (etaf-data--source-load source query page page-size)))
      (when (etaf--async-p result)
        (signal 'etaf-async-error
                (list "Asynchronous sources require a Data Controller")))
      (etaf-data--normalize-result result))))

(defun etaf-data--item-identity (controller item)
  "Return ITEM's selection identity in CONTROLLER."
  (if-let* ((item-key (etaf-data--controller-item-key controller)))
      (funcall item-key item)
    item))

(defun etaf-data--ensure-selected-ref (controller identity)
  "Return CONTROLLER's retained boolean selection ref for IDENTITY."
  (let* ((refs (etaf-data--controller-selected-refs controller))
         (selected-ref (gethash identity refs)))
    (or selected-ref
        (let ((created
               (etaf-ref
                (not (null
                      (member identity
                              (etaf-data--controller-selection-snapshot
                               controller))))
                :name 'etaf-data-selected)))
          (puthash identity created refs)
          created))))

(defun etaf-data--prepare-selected-refs (controller items)
  "Materialize CONTROLLER selection dependencies for ITEMS before render."
  (dolist (identity (etaf-data--controller-selection-snapshot controller))
    (etaf-data--ensure-selected-ref controller identity))
  (dolist (item items)
    (etaf-data--ensure-selected-ref
     controller (etaf-data--item-identity controller item))))

(defun etaf-data--projection-entry (name ref new-value)
  "Build one immutable-looking projection ENTRY for REF and NEW-VALUE."
  (list :name name
        :ref ref
        :expected-version (etaf-ref-version ref)
        :old-version (etaf-ref-version ref)
        :old-value (etaf-ref-value ref)
        :new-value new-value
        ;; These fields form a tiny write-ahead journal for the precommit
        ;; boundary.  They let rollback restore only values actually written
        ;; by this candidate, without clobbering an intervening external write
        ;; that won a version race while preparation was failing.
        :applied-p nil
        :applied-version nil
        :applied-value nil))

(defun etaf-data--projection-context-ids (sources)
  "Return scheduler context IDs touched by SOURCES' current subscribers."
  (let ((contexts (make-hash-table :test #'eql)))
    (dolist (source sources)
      (maphash
       (lambda (subscriber _present)
         (let ((context (etaf--subscriber-scheduler-context subscriber)))
           (when (or (and (etaf-runtime-route-p subscriber)
                          (etaf-runtime-route-live-p subscriber))
                     (and (etaf-effect-p subscriber)
                          (etaf-effect-active-p subscriber)))
             (puthash (etaf-scheduler-context-id context) t contexts))))
       (etaf--source-subscribers source)))
    (sort (hash-table-keys contexts) #'<)))

(defun etaf-data--make-projection-candidate
    (controller request-id kind fields &optional certainty mutation-result token
                context-filter)
  "Prepare a Data projection CANDIDATE for FIELDS.

FIELDS is a list of (NAME REF NEW-VALUE) triples.  No live ref is changed by
this function.  CONTEXT-FILTER is used only to compute the retry scope; the
actual subscriber fan-out remains scheduler-owned."
  (let* ((entries (mapcar (lambda (field)
                            (etaf-data--projection-entry
                             (nth 0 field) (nth 1 field) (nth 2 field)))
                          fields))
         (changed (cl-remove-if
                   (lambda (entry)
                     (funcall (or (etaf-ref-test (plist-get entry :ref))
                                  #'etaf--reactive-same-p)
                              (plist-get entry :old-value)
                              (plist-get entry :new-value)))
                   entries))
         (sources (delete-dups (mapcar (lambda (entry)
                                         (plist-get entry :ref))
                                       changed)))
         (projection-id (cl-incf etaf-data--projection-id-counter))
         (context-ids (etaf-data--projection-context-ids sources)))
    (when context-filter
      (setq context-ids (cl-remove-if-not context-filter context-ids)))
    (etaf-data--projection-candidate-create
     :controller-id (etaf-data--controller-id controller)
     :request-id request-id
     :projection-id projection-id
     :dispatch-epoch projection-id
     :kind kind
     :entries entries
     :changed-sources sources
     :certainty certainty
     :mutation-result mutation-result
     :reconciliation-token token
     :context-ids context-ids
     :state 'prepared)))

(defun etaf-data--projection-default-apply-field (entry)
  "Install one prepared projection ENTRY without dispatching subscribers."
  (let* ((ref (plist-get entry :ref))
         (old (plist-get entry :old-value))
         (new (plist-get entry :new-value)))
    (unless (funcall (or (etaf-ref-test ref) #'etaf--reactive-same-p)
                     old new)
      ;; This is deliberately the no-dispatch install boundary.  All entries
      ;; are installed before any source is dispatched, so observers can never
      ;; see a half-published Data projection.
      (setf (etaf-ref-value ref) new
            (etaf-ref-version ref) (1+ (plist-get entry :old-version))))))

(defun etaf-data--projection-restore (candidate)
  "Restore CANDIDATE's own writes after a precommit failure.

Restoration is compare-and-set style: a ref is restored only when its current
version/value still match the write recorded by this candidate.  A concurrent
writer that changed the ref after our write is left intact, which is essential
for expected-version conflicts and avoids rolling back somebody else's
successful publication."
  (dolist (entry (etaf-data--projection-candidate-entries candidate))
    (when (plist-get entry :applied-p)
      (let* ((ref (plist-get entry :ref))
             (current-value (etaf-ref-value ref))
             (current-version (etaf-ref-version ref))
             (same-p (or (etaf-ref-test ref)
                         #'etaf--reactive-same-p)))
        (when (and (= current-version (plist-get entry :applied-version))
                   (funcall same-p current-value
                            (plist-get entry :applied-value)))
          (setf (etaf-ref-value ref) (plist-get entry :old-value)
                (etaf-ref-version ref) (plist-get entry :old-version))))))
  candidate)

(defun etaf-data--projection-context-filter (context-ids)
  "Return a scheduler context predicate for CONTEXT-IDS.

Nil means all contexts (the ordinary publication path); the private
`etaf-data--no-contexts' marker means none.  This distinction is important for
a retry whose failed-context set is already empty."
  (cond
   ((null context-ids) nil)
   ((eq context-ids etaf-data--no-contexts)
    (lambda (_context) nil))
   (t
    (lambda (context)
      (memq (etaf-scheduler-context-id context) context-ids)))))

(defun etaf-data--projection-dispatch (candidate &optional context-ids)
  "Dispatch changed sources in CANDIDATE and return summary/condition data."
  (let (summary condition
        (deferred-p (etaf-scheduler-projection-active-p)))
    (if (or (null (etaf-data--projection-candidate-changed-sources candidate))
            (eq context-ids etaf-data--no-contexts))
        (list :summary nil :condition nil)
      (let ((captured
             (etaf-data--transparent-condition-boundary
              (lambda ()
                (etaf-data--capture-condition
                 (lambda ()
                   (etaf-scheduler-call-with-projection
                    (lambda ()
                      (etaf-scheduler-on-projection-complete
                       (lambda (completed-summary)
                         (setq summary completed-summary)))
                      (let ((filter
                             (etaf-data--projection-context-filter context-ids)))
                        (dolist
                            (source
                             (etaf-data--projection-candidate-changed-sources
                              candidate))
                          (etaf--dispatch-source source filter)))))))))))
        (setq condition (plist-get captured :condition)))
      (list :summary summary :condition condition :deferred-p deferred-p))))

(defun etaf-data--projection-failed-context-ids
    (candidate summary condition &optional attempted-context-ids)
  "Return context IDs that failed dispatch for CANDIDATE.

ATTEMPTED-CONTEXT-IDS is used by partial retries so a condition in one retry
cannot accidentally mark already successful contexts as failed again."
  (let* ((attempted (or attempted-context-ids
                        (etaf-data--projection-candidate-context-ids candidate)))
         failed)
    (when (and summary (plist-get summary :contexts))
      (dolist (context (plist-get summary :contexts))
        (let ((context-id (plist-get context :context-id)))
          (when (and (memq context-id attempted)
                     (or (> (or (plist-get context :faults) 0) 0)
                         ;; A stale route was intentionally skipped rather
                         ;; than completed.  Keep that context pending so a
                         ;; later live route in the same context can be
                         ;; reconciled, while retry target selection still
                         ;; filters out the detached route itself.
                         (> (or (plist-get context :stale-route-drops) 0)
                            0)))
            (push context-id failed)))))
    (when (and condition (null summary))
      (setq failed (copy-sequence attempted)))
    (delete-dups (nreverse failed))))

(defun etaf-data--projection-mark-token
    (candidate summary condition failed-context-ids &optional attempted merge-p)
  "Update CANDIDATE's token and context completion metadata."
  (let* ((contexts (etaf-data--projection-candidate-context-ids candidate))
         (attempted (or attempted contexts))
         (token (etaf-data--projection-candidate-reconciliation-token candidate))
         (old-completed (and token (plist-get token :completed-context-ids)))
         (old-failed (and token (plist-get token :failed-context-ids)))
         (completed-now (cl-set-difference attempted failed-context-ids))
         (completed (if merge-p
                        (cl-union old-completed completed-now)
                      (cl-set-difference contexts failed-context-ids)))
         (failed (if merge-p
                     (cl-union
                      (cl-set-difference old-failed completed-now)
                      failed-context-ids)
                   failed-context-ids)))
    (setf (etaf-data--projection-candidate-completed-context-ids candidate)
          completed
          (etaf-data--projection-candidate-failed-context-ids candidate)
          failed)
    (when token
      (etaf-data--token-put token :projection-token
                            (etaf-data--projection-candidate-dispatch-epoch
                             candidate))
      (etaf-data--token-put token :dispatch-epoch
                            (etaf-data--projection-candidate-dispatch-epoch
                             candidate))
      (etaf-data--token-put token :completed-context-ids completed)
      (etaf-data--token-put token :failed-context-ids failed)
      (etaf-data--token-put token :last-summary summary)
      (etaf-data--token-put token :last-condition condition)
      (etaf-data--token-put
       token :state
       (cond
        ((eq (etaf-data--projection-candidate-certainty candidate)
             'external-unknown)
         'external-unknown)
        ((eq (etaf-data--projection-candidate-certainty candidate)
             'rolled-back)
         'rolled-back)
        (condition 'render-pending)
        (failed 'projection-pending)
        ((eq (etaf-data--projection-candidate-kind candidate) 'load-error)
         (if (eq (etaf-data--projection-candidate-certainty candidate)
                 'committed)
             'projection-pending
           'projected))
        (t 'projected))))
    candidate))

(defun etaf-data--commit-projection
    (controller candidate &optional context-ids suppress-test-hooks)
  "Atomically install CANDIDATE and dispatch it once per target context.

The return value is a plist containing `:candidate', `:summary', and optional
`:condition'.  A preparation/field failure signals after restoring every ref;
a dispatch failure leaves committed refs in place and is returned for the
caller to decorate with a cause-compatible projection trailer.

When SUPPRESS-TEST-HOOKS is non-nil, the loading marker uses the production
field installer even when the test-only fault hooks are bound.  This keeps a
fault injected into the data-bearing success/error candidate from preventing
the source boundary from being observed; loading remains an observable
candidate without becoming a second fault-injection target."
  ;; Candidates are one-shot transactions.  A committed candidate must never
  ;; re-enter the precommit path: doing so would compare its old expected
  ;; versions against the now-advanced refs, then the rollback journal could
  ;; incorrectly restore a publication that already escaped to observers.
  (unless (eq (etaf-data--projection-candidate-state candidate) 'prepared)
    (signal 'etaf-data-projection-conflict
            (list :projection-id
                  (etaf-data--projection-candidate-projection-id candidate)
                  :state
                  (etaf-data--projection-candidate-state candidate))))
  (setf (etaf-data--controller-projection-candidate controller) candidate)
  (let* ((prepared
          (etaf-data--capture-condition
           (lambda ()
             ;; A field-apply hook is test-only, but the commit boundary itself
             ;; remains quit-safe and validates every captured version first.
             (let ((inhibit-quit t))
               (when (and (not suppress-test-hooks)
                          (functionp etaf-data--projection-before-commit-hook))
                 (funcall etaf-data--projection-before-commit-hook candidate))
               (unless (= (etaf-data--projection-candidate-request-id candidate)
                          (etaf-data--controller-request-id controller))
                 (signal 'etaf-data-projection-conflict
                         (list :request-id
                               (etaf-data--projection-candidate-request-id
                                candidate)
                               :current-request-id
                               (etaf-data--controller-request-id controller))))
               ;; Validate every expected version before installing any field.
               (dolist (entry
                        (etaf-data--projection-candidate-entries candidate))
                 (unless (= (etaf-ref-version (plist-get entry :ref))
                            (plist-get entry :expected-version))
                   (signal 'etaf-data-projection-conflict
                           (list :field (plist-get entry :name)
                                 :expected-version
                                 (plist-get entry :expected-version)
                                 :actual-version
                                 (etaf-ref-version (plist-get entry :ref))))))
               ;; Install the complete candidate exactly once, after all
               ;; expected versions have passed validation.
               (let ((apply-field
                      (if suppress-test-hooks
                          #'etaf-data--projection-default-apply-field
                        (or etaf-data--projection-field-apply-function
                            #'etaf-data--projection-default-apply-field))))
                 (dolist (entry
                          (etaf-data--projection-candidate-entries candidate))
                   (let ((before-version (etaf-ref-version
                                          (plist-get entry :ref)))
                         (before-value (etaf-ref-value (plist-get entry :ref))))
                     (unwind-protect
                         (funcall apply-field entry)
                       ;; Record a write even when a faulting test adapter
                       ;; signals after changing the ref.  The restore path
                       ;; will then perform a CAS against this exact value and
                       ;; version, preserving any later competing writer.
                       (let* ((ref (plist-get entry :ref))
                              (after-version (etaf-ref-version ref))
                              (after-value (etaf-ref-value ref))
                              (same-p (or (etaf-ref-test ref)
                                          #'etaf--reactive-same-p)))
                         (when (or (/= before-version after-version)
                                   (not (funcall same-p before-value
                                                 after-value)))
                           (setf (plist-get entry :applied-p) t
                                 (plist-get entry :applied-version)
                                 after-version
                                 (plist-get entry :applied-value)
                                 after-value)))))))
               t))))
         (precommit-condition (plist-get prepared :condition)))
    (when precommit-condition
      (etaf-data--projection-restore candidate)
      (setf (etaf-data--projection-candidate-state candidate) 'aborted)
      (etaf-data--signal-condition precommit-condition))
    (setf (etaf-data--projection-candidate-state candidate) 'committed)
    (when (eq (etaf-data--projection-candidate-kind candidate) 'success)
      (setf (etaf-data--controller-loaded-p controller) t))
    (push candidate (etaf-data--controller-projection-history controller))
    (when (> (length (etaf-data--controller-projection-history controller))
             etaf-data--projection-history-limit)
      (setf (etaf-data--controller-projection-history controller)
            (cl-subseq (etaf-data--controller-projection-history controller)
                       0 etaf-data--projection-history-limit)))
    (let* ((dispatch (etaf-data--projection-dispatch candidate context-ids))
           (summary (plist-get dispatch :summary))
           (condition (plist-get dispatch :condition))
           (failed (etaf-data--projection-failed-context-ids
                    candidate summary condition
                    (and (not (eq context-ids etaf-data--no-contexts))
                         (if context-ids
                             context-ids
                           (etaf-data--projection-candidate-context-ids
                            candidate))))))
      (if (plist-get dispatch :deferred-p)
          ;; Nested Data publication joins the caller's scheduler projection.
          ;; Its completion summary (including per-context faults) is only
          ;; available after the outer drain, so finalize the candidate from a
          ;; completion observer rather than claiming every context now.
          (etaf-scheduler-on-projection-complete
           (lambda (completed-summary)
             (let* ((completed-condition
                     (plist-get completed-summary :condition))
                    (completed-failed
                     (etaf-data--projection-failed-context-ids
                      candidate completed-summary completed-condition
                      (and (not (eq context-ids etaf-data--no-contexts))
                           (if context-ids
                               context-ids
                             (etaf-data--projection-candidate-context-ids
                              candidate))))))
               (etaf-data--projection-mark-token
                candidate completed-summary completed-condition
                completed-failed nil nil))))
        (etaf-data--projection-mark-token candidate summary condition failed
                                           nil nil))
      (list :candidate candidate :summary summary :condition condition))))

(defun etaf-data--projection-condition-trailer (candidate)
  "Return the fixed v1 trailer for Data projection CANDIDATE."
  (let* ((token (etaf-data--projection-candidate-reconciliation-token candidate))
         (projection-id
          (etaf-data--projection-candidate-dispatch-epoch candidate))
         (certainty
          (or (etaf-data--projection-candidate-certainty candidate)
              'committed))
         (result
          (etaf-data--projection-candidate-mutation-result candidate))
         (operation-id (or (and token (plist-get token :operation-id)) 0))
         (outcome-id (or (and token (plist-get token :id)) projection-id)))
    (list :etaf-condition-trailer/v1
          (list :kind 'projection
                :committed-p t
                :external-commit-certainty certainty
                :reconciliation-token token
                :projection-token projection-id
                :result result
                :operation-id operation-id
                :outcome-id outcome-id
                :generation-id 0
                :revision 0
                :diagnostic-journal-id (max 1 projection-id)))))

(defun etaf-data--decorate-projection-condition (condition candidate)
  "Append CANDIDATE's trailer to CONDITION while preserving its prefix."
  (if (or (not (consp condition))
          ;; Do not append a second Data trailer when a retry or nested
          ;; boundary has already decorated this condition.  A legacy
          ;; postcommit trailer is a different kind and must remain in the
          ;; prefix while Data adds its projection metadata at the end.
          (etaf-data-condition-projection-info condition))
      condition
    (append (copy-tree condition)
            (list (etaf-data--projection-condition-trailer candidate)))))

(defun etaf-data--projection-condition-prefix (condition)
  "Return CONDITION without a terminal Data projection trailer.

Projection conditions captured from `etaf-data--apply-error' are already
decorated.  Storing that decorated condition inside the token that the trailer
itself references would create a cyclic diagnostic object; retain only its
cause-compatible prefix in token metadata instead."
  (copy-tree
   (if (etaf-data-condition-projection-info condition)
       (butlast condition)
     condition)))

(defun etaf-data--ensure-projection-token (controller candidate)
  "Ensure CANDIDATE has a Data token for a projection diagnostic.

Ordinary successful loads do not expose a reconciliation token.  If their
render/projection path fails, however, the fixed trailer still needs an opaque
token so callers can distinguish and inspect that failure without replaying a
source mutation."
  (or (etaf-data--projection-candidate-reconciliation-token candidate)
      ;; A plain read has no external mutation certainty.  Its original
      ;; condition remains the public diagnostic; only mutation/reconciliation
      ;; projections receive the certainty trailer.
      (when (etaf-data--projection-candidate-certainty candidate)
        (let ((token (etaf-data--make-reconciliation-token
                      controller 0 'committed nil)))
          (setf (etaf-data--projection-candidate-reconciliation-token candidate)
                token
                (etaf-data--controller-reconciliation-token controller) token)
          (etaf-data--token-put token :state 'render-pending)
          token))))

(defun etaf-data--load-fields (controller normalized)
  "Return the stable controller fields for normalized load NORMALIZED."
  (append
   (list (list 'items (etaf-data--controller-items controller)
               (plist-get normalized :items))
         (list 'total (etaf-data--controller-total controller)
               (or (plist-get normalized :total)
                   (length (plist-get normalized :items)))))
   (when (plist-member normalized :page)
     (list (list 'page (etaf-data--controller-page controller)
                 (plist-get normalized :page))))
   (when (plist-member normalized :page-size)
     (list (list 'page-size (etaf-data--controller-page-size controller)
                 (plist-get normalized :page-size))))
   (list (list 'error (etaf-data--controller-error controller) nil)
         (list 'status (etaf-data--controller-status controller) 'success))))

(defun etaf-data--publish-projection-failure (controller condition)
  "Publish a safe error state after a Data projection commit aborts.

Loading is intentionally visible before a source call.  If the later
multi-field candidate cannot commit, leaving that marker in place would make a
controller report `loading' forever.  This fallback bypasses the fault-injected
candidate installer, atomically writes the observable error/status pair, and
still lets scheduler containment report any render fault separately."
  (etaf-call-with-batch
   (lambda ()
     (setf (etaf-value (etaf-data--controller-error controller)) condition
           (etaf-value (etaf-data--controller-status controller)) 'error))))

(defun etaf-data--apply-load-loading (controller request-id &optional outcome)
  "Publish the loading marker as a first-class projection candidate.

The marker is committed before the source callback runs, so a source can
observe `loading' through the ordinary public status ref.  Test-only field and
precommit fault hooks are suppressed for this marker; data-bearing success and
error candidates remain the fault-injection boundary for atomicity tests."
  (when (= request-id (etaf-data--controller-request-id controller))
    (let* ((candidate
            (etaf-data--make-projection-candidate
             controller request-id 'loading
             (append
              (when outcome
                (list (list 'mutation-outcome
                            (etaf-data--controller-mutation-outcome controller) outcome)))
              (list (list 'error (etaf-data--controller-error controller) nil)
                   (list 'status (etaf-data--controller-status controller)
                         (if (and (etaf-data--controller-loaded-p controller)
                                  (eq (etaf-data--controller-request-kind controller) 'load))
                             'refreshing 'loading))))))
           (publication
            (etaf-data--capture-condition
             (lambda ()
               (etaf-scheduler-call-with-projection
                (lambda ()
                  (etaf-data--commit-projection
                   controller candidate nil t))))))
           (condition (plist-get publication :condition)))
      ;; A loading projection has no external certainty and therefore no
      ;; reconciliation token.  Surface a scheduler/precommit fault using its
      ;; normal condition contract rather than silently proceeding.  The
      ;; loading marker itself must not strand a controller in `loading': use
      ;; the safe terminal error publication when its dispatch fails.
      (when condition
        (ignore
         (etaf-data--capture-condition
          (lambda ()
            (etaf-data--publish-projection-failure controller condition))))
        (etaf-data--signal-condition condition))
      publication)))

(defun etaf-data--apply-load-success
    (controller request-id result &optional reconciliation-token outcome
                context-ids)
  "Publish successful RESULT for CONTROLLER when REQUEST-ID is current.

RECONCILIATION-TOKEN and OUTCOME identify an external mutation, when present.
CONTEXT-IDS is an optional retry allow-list; nil means every live context."
  (when (= request-id (etaf-data--controller-request-id controller))
    (let* ((normalized (etaf-data--normalize-result result))
           (certainty (and outcome (plist-get outcome :certainty)))
           (mutation-result (and outcome
                                  (or (plist-get outcome :mutation-result)
                                      (plist-get outcome :result))))
           (token (or reconciliation-token
                      (and outcome
                           (etaf-data--make-reconciliation-token
                            controller
                            (or (plist-get outcome :operation-id) 0)
                            certainty mutation-result
                            (plist-get outcome :reconciliation-token)))))
           (auto-load-p (etaf-data--controller-auto-load-p controller))
           candidate committed capture)
      (when token
        (setf (etaf-data--controller-reconciliation-token controller) token))
      (setf (etaf-data--controller-auto-load-p controller) nil)
      ;; Keep the auto-load guard through the *outer* scheduler projection.  A
      ;; normalized page write can enqueue the auto-load effect; restoring the
      ;; flag before that projection drains would issue a duplicate load.
      (setq capture
            (etaf-data--capture-condition
             (lambda ()
               ;; Materialize keyed selection dependencies inside the same
               ;; preparation capture as candidate construction.  User-owned
               ;; item keys may signal; such a fault must terminate the
               ;; loading marker rather than leave the controller stuck there.
               (etaf-data--prepare-selected-refs
                controller (plist-get normalized :items))
               (etaf-scheduler-call-with-projection
                (lambda ()
                  (etaf-scheduler-defer-finalizer
                   (lambda ()
                     (setf (etaf-data--controller-auto-load-p controller)
                           auto-load-p)))
                  (setq candidate
                        (etaf-data--make-projection-candidate
                         controller request-id 'success
                         (etaf-data--load-fields controller normalized)
                         certainty mutation-result token))
                  (setq committed
                        (etaf-data--commit-projection
                         controller candidate context-ids)))))))
      (let ((caught (plist-get capture :condition)))
        (unless candidate
          ;; Materialization can fail before a candidate exists (for example,
          ;; an item-key callback can signal).  Publish a terminal error
          ;; directly so the loading marker cannot remain stuck, then preserve
          ;; the projection condition for the caller.
          (setf (etaf-data--controller-auto-load-p controller) auto-load-p)
          (ignore
           (etaf-data--capture-condition
            (lambda ()
              (etaf-data--apply-error controller request-id caught))))
          (etaf-data--signal-condition caught))
        (when caught
          (when (or token
                    (and candidate
                         (eq (car caught) 'etaf-data-projection-conflict)))
            (let ((diagnostic-token
                   (etaf-data--ensure-projection-token controller candidate)))
              (when diagnostic-token
                ;; A candidate that never committed is a precommit conflict;
                ;; a committed candidate whose outer scheduler drain signalled
                ;; is a render/projection failure.  Do not collapse the latter
                ;; into a misleading precommit state.
                (etaf-data--token-put
                 diagnostic-token :state
                 (if (eq (and candidate
                              (etaf-data--projection-candidate-state candidate))
                         'aborted)
                     'projection-pending
                   'render-pending))))))
          (when (and candidate
                     (eq (etaf-data--projection-candidate-state candidate)
                         'aborted)
                     (= (etaf-data--projection-candidate-request-id candidate)
                        (etaf-data--controller-request-id controller)))
            ;; The loading marker was committed in its own pre-source turn;
            ;; replace it with an observable error when the candidate itself
            ;; aborts before any Data field is published.
            (ignore
             (etaf-data--capture-condition
              (lambda ()
                (etaf-data--publish-projection-failure controller caught)))))
          (let ((decorated
                 (if (and candidate
                          (etaf-data--projection-candidate-reconciliation-token
                           candidate))
                     (etaf-data--decorate-projection-condition caught candidate)
                   caught)))
            (etaf-data--signal-condition decorated)))
        (when-let* ((condition (and committed
                                    (plist-get committed :condition))))
          (unless (etaf-data--projection-candidate-reconciliation-token
                   candidate)
            (etaf-data--ensure-projection-token controller candidate))
          ;; Plain v1 loads have no external mutation certainty or
          ;; reconciliation token.  Preserve their historical raw condition;
          ;; only mutation/reconciliation projections receive the fixed
          ;; token-bearing trailer.
          (etaf-data--signal-condition
           (if (etaf-data--projection-candidate-reconciliation-token candidate)
               (etaf-data--decorate-projection-condition condition candidate)
             condition)))
        result)))

(defun etaf-data--apply-error
    (controller request-id error-data &optional reconciliation-token outcome)
  "Atomically publish ERROR-DATA and status for current REQUEST-ID.
The old items/page values remain untouched.  Return the projection result."
  (when (= request-id (etaf-data--controller-request-id controller))
    (let* ((certainty (and outcome (plist-get outcome :certainty)))
           (mutation-result (and outcome
                                  (or (plist-get outcome :mutation-result)
                                      (plist-get outcome :result))))
           (token (or reconciliation-token
                      (and outcome
                           (etaf-data--make-reconciliation-token
                            controller
                            (or (plist-get outcome :operation-id) 0)
                            certainty mutation-result
                            (plist-get outcome :reconciliation-token)))))
           (candidate
            (etaf-data--make-projection-candidate
             controller request-id 'load-error
             (append
              (when outcome
                (list (list 'mutation-outcome
                            (etaf-data--controller-mutation-outcome controller) outcome)))
              (list (list 'error (etaf-data--controller-error controller)
                         error-data)
                   (list 'status (etaf-data--controller-status controller)
                         (if (eq (car error-data) 'etaf-async-cancelled)
                             'cancelled 'error))))
             certainty mutation-result token))
           (publication
            (etaf-data--capture-condition
             (lambda ()
               (etaf-scheduler-call-with-projection
                (lambda ()
                  (etaf-data--commit-projection controller candidate
                                                 nil))))))
           (committed (plist-get publication :value))
           (projection-condition (plist-get publication :condition)))
      ;; Keep the reconciliation token visible even when the candidate aborts
      ;; before the scheduler call returns.  This is needed for a committed
      ;; mutation whose read-side error projection must be retried read-only.
      (when token
        (setf (etaf-data--controller-reconciliation-token controller) token))
      (when (and projection-condition
                 (eq (etaf-data--projection-candidate-state candidate)
                     'aborted))
        ;; `loading' was published before the source boundary ran.  If the
        ;; error/status candidate itself faults during precommit, install a
        ;; safe terminal error directly so the controller cannot remain stuck
        ;; in `loading'.  The original ERROR-DATA remains the public source
        ;; condition; PROJECTION-CONDITION is re-signaled below for callers
        ;; that observe the projection boundary directly.
        (ignore
         (etaf-data--capture-condition
          (lambda ()
            (etaf-data--publish-projection-failure controller error-data))))
        (when token
          (etaf-data--token-put
           token :state
           (pcase certainty
             ('external-unknown 'external-unknown)
             ('rolled-back 'rolled-back)
             (_ 'projection-pending)))))
      (when-let* ((condition (or (and committed
                                      (plist-get committed :condition))
                                 projection-condition)))
        (unless (etaf-data--projection-candidate-reconciliation-token
                 candidate)
          (etaf-data--ensure-projection-token controller candidate))
        (etaf-data--signal-condition
         (etaf-data--decorate-projection-condition condition candidate)))
      committed)))

(defun etaf-data--decorate-reconciliation-condition
    (controller condition outcome token)
  "Decorate a reconciliation load CONDITION when its facts committed.

Plain v1 loads retain their historical raw condition.  Once a mutation outcome
is known to be committed, however, a failed read is part of the
committed-but-unprojected reconciliation diagnostic and carries the same
cause-compatible projection trailer as a render fault."
  (let ((candidate (etaf-data--controller-projection-candidate controller)))
    (if (and condition outcome token
             (eq (plist-get outcome :certainty) 'committed)
             candidate
             (eq (etaf-data--projection-candidate-state candidate) 'committed)
             (eq (etaf-data--projection-candidate-reconciliation-token
                  candidate)
                 token))
        (etaf-data--decorate-projection-condition condition candidate)
      condition)))

;;;###autoload
(cl-defun etaf-data-controller
    (source &key query (page 1) (page-size 20) selection auto-load name
            item-key owner-scope initial-result timeout)
  "Create a reactive Data Controller for SOURCE.

QUERY, PAGE, PAGE-SIZE, result ITEMS, TOTAL, STATUS, ERROR, and SELECTION are
stored in refs.  When AUTO-LOAD is non-nil, the controller loads immediately
and reloads after query or pagination refs change.  NAME optionally labels the
controller for diagnostics.  ITEM-KEY identifies selection and selected-item
state; it defaults to the source's `:item-key' capability when available.
When OWNER-SCOPE is supplied, or when a current ETAF Scope exists, the
controller's own child Scope is disposed with that owner; otherwise it keeps
the detached Scope behavior.  INITIAL-RESULT may be a normalized source result
for QUERY/PAGE/PAGE-SIZE; it seeds a successful Controller without another
load.  INITIAL-RESULT and AUTO-LOAD are mutually exclusive.
TIMEOUT is nil or positive seconds for each asynchronous operation.
Loads retain previously accepted items while refreshing, after error and after
cancellation.  Stopping the Controller cancels pending work and ignores late
completion without undoing external writes."
  (etaf--load-check-timeout timeout)
  (unless (etaf-data-source-p source)
    (signal 'wrong-type-argument (list 'etaf-data-source-p source)))
  (setq item-key (or item-key (plist-get source :item-key)))
  (unless (or (null item-key) (functionp item-key))
    (signal 'wrong-type-argument (list 'functionp item-key)))
  (when (and initial-result auto-load)
    (error "ETAF Data :initial-result and :auto-load are mutually exclusive"))
  (let* ((initial-result (and initial-result
                              (etaf-data--normalize-result initial-result)))
         (initial-items (and initial-result
                             (plist-get initial-result :items)))
         (initial-page (if (and initial-result
                                (plist-member initial-result :page))
                           (plist-get initial-result :page)
                         page))
         (initial-page-size
          (if (and initial-result
                   (plist-member initial-result :page-size))
              (plist-get initial-result :page-size)
            page-size))
         (owner-scope (or owner-scope (etaf-current-effect-scope)))
         (scope (if owner-scope
                    (etaf-scope-run
                     owner-scope
                     (lambda ()
                       (etaf-effect-scope :name (or name 'etaf-data))))
                  (etaf-effect-scope :detached t :name (or name 'etaf-data))))
         (controller
          (etaf-data--controller-create
           :source source
           :scope scope
           :query (etaf-ref query :name 'etaf-data-query)
           :page (etaf-ref initial-page :name 'etaf-data-page)
           :page-size (etaf-ref initial-page-size :name 'etaf-data-page-size)
           :items (etaf-ref initial-items :name 'etaf-data-items)
           :total (etaf-ref (if initial-result
                                (or (plist-get initial-result :total)
                                    (length initial-items))
                              0)
                            :name 'etaf-data-total)
           :status (etaf-ref (if initial-result 'success 'idle)
                             :name 'etaf-data-status)
           :error (etaf-ref nil :name 'etaf-data-error)
           :selection (etaf-ref (copy-sequence selection)
                                :name 'etaf-data-selection)
           :selection-snapshot (copy-sequence selection)
           :selected-refs (make-hash-table :test #'equal)
           :id (cl-incf etaf-data--controller-id-counter)
           :mutation-outcome (etaf-ref nil :name 'etaf-data-mutation-outcome)
           :reconciliation-token nil
           :projection-candidate nil
           :projection-history nil
           :request-id 0 :timeout timeout :loaded-p (not (null initial-result))
           :auto-load-p auto-load
           :item-key item-key)))
    (etaf-data--prepare-selected-refs controller initial-items)
    (etaf-scope-run
        scope
        (lambda ()
          (etaf-watch
           (etaf-data--controller-selection controller)
           (lambda (new-selection old-selection)
             (setf (etaf-data--controller-selection-snapshot controller)
                   new-selection)
             (dolist (identity new-selection)
               (etaf-data--ensure-selected-ref controller identity))
             (let ((selected-refs
                    (etaf-data--controller-selected-refs controller)))
               (unless (zerop (hash-table-count selected-refs))
                 (let ((old-set (make-hash-table :test #'equal))
                       (new-set (make-hash-table :test #'equal)))
                   (dolist (identity old-selection)
                     (puthash identity t old-set))
                   (dolist (identity new-selection)
                     (puthash identity t new-set))
                   (maphash
                    (lambda (identity _present)
                      (unless (gethash identity new-set)
                        (when-let* ((selected-ref
                                    (gethash identity selected-refs)))
                          (setf (etaf-value selected-ref) nil))))
                    old-set)
                   (maphash
                    (lambda (identity _present)
                      (unless (gethash identity old-set)
                        (when-let* ((selected-ref
                                    (gethash identity selected-refs)))
                          (setf (etaf-value selected-ref) t))))
                    new-set)))))
           :name 'etaf-data-selection-index)
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
             (setf (etaf-data--controller-stopped-p controller) t)
             (unwind-protect
                 (etaf--load-abort (etaf-data--controller-request controller))
               (setf (etaf-data--controller-request controller) nil)
               (clrhash (etaf-data--controller-selected-refs controller))
               (when-let* ((dispose (etaf-data--source-function source :dispose nil)))
                 (funcall dispose)))))))
    (condition-case err
        (when auto-load (etaf-data-load controller))
      ((error quit)
       (etaf-data-stop controller)
       (signal (car err) (cdr err))))
    controller))

(defun etaf-data--finish-load
    (controller request-id result source-condition outcome reconciliation-token)
  "Publish one current source completion without changing its failure semantics."
      (if source-condition
          (let* ((publication
                  (etaf-data--capture-condition
                   (lambda ()
                     (etaf-data--apply-error
                      controller request-id source-condition
                      reconciliation-token outcome))))
                 (projection-condition (plist-get publication :condition)))
           ;; A source failure is the primary public condition.  If publishing
           ;; its status/error also fails, the projection condition remains
           ;; discoverable through the token but does not mask the source
           ;; callback's compatibility contract.
            (list :request-id request-id :result nil
                  :condition
                  (etaf-data--decorate-reconciliation-condition
                   controller source-condition outcome reconciliation-token)
                  :projection-condition projection-condition
                  :source-condition source-condition))
        (let* ((normalization
                (etaf-data--capture-condition
                 (lambda () (etaf-data--normalize-result result))))
               (normalization-condition (plist-get normalization :condition))
               (publication
                (etaf-data--capture-condition
                 (lambda ()
                   (if normalization-condition
                       ;; A malformed source result is a load error, not a
                       ;; projection/render fault.  Publish status/error
                       ;; atomically so the controller cannot remain stuck in
                       ;; `loading' after the source boundary returned.
                       (etaf-data--apply-error
                        controller request-id normalization-condition
                        reconciliation-token outcome)
                     (etaf-data--apply-load-success
                      controller request-id result
                      reconciliation-token outcome)))))
               (projection-condition (plist-get publication :condition)))
          (list :request-id request-id
                :result (unless normalization-condition result)
                :condition
                (or (and normalization-condition
                         (etaf-data--decorate-reconciliation-condition
                          controller normalization-condition outcome
                          reconciliation-token))
                    projection-condition)
                :projection-condition
                (and normalization-condition projection-condition)
                :source-condition normalization-condition))))

(defun etaf-data--begin-request (controller kind)
  "Invalidate CONTROLLER's previous request and begin one of KIND."
  (etaf--assert-not-rendering 'load-data)
  (let ((previous (etaf-data--controller-request controller)))
    (when (and previous (etaf--load-task-pending-p previous)
               (eq kind 'mutate) (eq (etaf-data--controller-request-kind controller) 'mutate))
      (signal 'etaf-data-error (list "A mutation is already pending")))
    (etaf--load-abort previous
                     (when (eq (etaf-data--controller-request-kind controller) 'mutate)
                       '(etaf-async-cancelled))))
  (setf (etaf-data--controller-request-kind controller) kind)
  (cl-incf (etaf-data--controller-request-id controller)))

(defun etaf-data--report-completion (envelope synchronous-p)
  "Expose asynchronous projection failures from ENVELOPE.
Source failures are observable state; synchronous callers signal them
on return."
  (unless synchronous-p
    (etaf-data--signal-condition
     (or (plist-get envelope :projection-condition)
         (unless (plist-get envelope :source-condition)
           (plist-get envelope :condition))))))

(defun etaf-data--load-request (controller &optional outcome reconciliation-token)
  "Start a source load and return its immediate result/condition envelope.
An asynchronous load returns a pending envelope and completes through the same
publication path later. OUTCOME identifies a committed mutation to reconcile."
  (let* ((request-id (etaf-data--begin-request controller 'load))
         (envelope (list :request-id request-id :pending-p t))
         (synchronous-p t)
         (task
          (etaf--load-task-create
           :scope (etaf-data--controller-scope controller)
           :timeout (etaf-data--controller-timeout controller)
           :success
           (lambda (result)
             (setq envelope (etaf-data--finish-load
                             controller request-id result nil outcome reconciliation-token))
             (etaf-data--report-completion envelope synchronous-p))
           :failure
           (lambda (condition)
             (setq envelope (etaf-data--finish-load
                             controller request-id nil condition outcome reconciliation-token))
             (etaf-data--report-completion envelope synchronous-p)))))
    (setf (etaf-data--controller-request controller) task)
    (unwind-protect
        (condition-case err
            (progn
              (etaf-data--apply-load-loading controller request-id outcome)
              (etaf--load-start
               task (lambda ()
                      (etaf-data--source-load
                       (etaf-data--controller-source controller)
                       (etaf-value (etaf-data--controller-query controller))
                       (etaf-value (etaf-data--controller-page controller))
                       (etaf-value (etaf-data--controller-page-size controller))))))
          ((error quit)
           (etaf--load-abort task)
           (signal (car err) (cdr err))))
      (setq synchronous-p nil))
    envelope))

;;;###autoload
(defun etaf-data-load (controller)
  "Start CONTROLLER's source load; return the synchronous result or nil pending.
Loading before first success uses `loading'; later reads use `refreshing' and
retain items.  Completion publishes `success', `error' or `cancelled'.
Synchronous source errors are recorded and re-signaled.  Asynchronous source
errors are recorded; projection/rendering errors still signal from completion.
A new load cancels the old request.  Superseding a pending write records unknown
external certainty; it does not imply rollback."
  (etaf-data--require-controller controller)
  (let ((request (etaf-data--load-request controller)))
    (etaf-data--signal-condition (plist-get request :condition))
    (plist-get request :result)))

;;;###autoload
(defun etaf-data-reload (controller)
  "Reload CONTROLLER; return the synchronous result or nil while pending."
  (etaf-data-load controller))

(defun etaf-data--finish-mutation
    (controller operation operation-id request-id v2-p raw error-condition)
  "Publish one mutation completion and reconcile only a known committed write."
  (let (outcome token normalization-call normalization-condition)
    ;; Normalize inside the same compatibility boundary as the source call.
    ;; A malformed v2 envelope is itself an uncertain external operation: the
    ;; adapter was invoked exactly once, but Data cannot safely infer whether
    ;; the side effect committed, so it must publish an error and forbid retry.
    (when (and v2-p (not error-condition))
      (setq normalization-call
            (etaf-data--capture-condition
             (lambda () (etaf-data--normalize-mutation-outcome raw t))))
      (setq normalization-condition
            (plist-get normalization-call :condition)))
    (setq outcome
          (if error-condition
              (list :certainty 'external-unknown
                    :external-commit-certainty 'external-unknown
                    :result nil :mutation-result nil
                    :error error-condition
                    :operation operation
                    :operation-id operation-id)
            (if normalization-condition
                (list :certainty 'external-unknown
                      :external-commit-certainty 'external-unknown
                      :result nil :mutation-result nil
                      :error normalization-condition
                      :operation operation
                      :operation-id operation-id
                      :raw raw)
              (append (if v2-p
                          (plist-get normalization-call :value)
                        (etaf-data--normalize-mutation-outcome raw nil))
                      (list :operation operation :operation-id operation-id)))))
    (setq token
          (etaf-data--make-reconciliation-token
           controller operation-id (plist-get outcome :certainty)
           (or (plist-get outcome :mutation-result)
               (plist-get outcome :result))
           (plist-get outcome :reconciliation-token)))
    (setq outcome (plist-put outcome :reconciliation-token token))
    (setf (etaf-data--controller-reconciliation-token controller) token)
    (cond
     ;; A v1 signal or an explicitly uncertain v2 result cannot be replayed.
     ((or error-condition normalization-condition
          (eq (plist-get outcome :certainty) 'external-unknown)
          (eq (plist-get outcome :certainty) 'rolled-back))
      (let* ((failure (or error-condition normalization-condition
                          (plist-get outcome :error)
                          (list 'etaf-data-error
                                (format "ETAF Data mutation %S was %s"
                                        operation
                                        (plist-get outcome :certainty)))))
             (published
             (etaf-data--capture-condition
              (lambda ()
                (etaf-data--apply-error
                  controller request-id failure token outcome))))
             (projection-condition (plist-get published :condition))
             (candidate (etaf-data--controller-projection-candidate controller))
             ;; Preserve the primary source/normalization condition as the
             ;; public prefix.  A projection/render fault is attached through
             ;; the same fixed trailer used by committed reconciliation, while
             ;; its raw condition remains available on the opaque token.
             (public-failure
              (if (and projection-condition candidate)
                  (progn
                    (etaf-data--token-put token :projection-condition
                                          (etaf-data--projection-condition-prefix
                                           projection-condition))
                    (etaf-data--decorate-projection-condition
                     failure candidate))
                failure)))
        ;; Preserve the source's original error, if any; otherwise expose the
        ;; v2 rollback/uncertainty diagnostic we synthesized above.  Do not
        ;; discard a projection condition merely because the primary operation
        ;; was already known to have failed.
        (list :condition public-failure :source-condition failure
              :projection-condition projection-condition)))
     (t
      ;; Exactly one source mutation has happened.  Reconciliation may issue a
      ;; load, but it never invokes the mutation callback again.
      (let ((request (etaf-data--load-request controller outcome token)))
        (plist-put request :result (plist-get outcome :mutation-result)))))))

;;;###autoload
(defun etaf-data-mutate (controller operation payload)
  "Run source OPERATION with PAYLOAD and then reconcile its result.
Synchronous writes return their result.  An asynchronous write returns nil
while pending; inspect status and mutation outcome after completion.  A second
write is rejected while the first write is pending.  Cancellation, timeout or
an unclassified external failure never implies that the write was rolled back."
  (etaf-data--require-controller controller)
  (let* ((source (etaf-data--controller-source controller))
         (operation-id (cl-incf etaf-data--operation-id-counter))
         (request-id (etaf-data--begin-request controller 'mutate))
         (v2-p (functionp (etaf-data--source-mutate-v2-function source)))
         (synchronous-p t)
         result condition task invoked)
    (setf (etaf-data--controller-reconciliation-token controller) nil)
    (cl-labels
        ((finish (raw source-condition)
           (when (and (not (etaf-data--controller-stopped-p controller))
                      (= request-id (etaf-data--controller-request-id controller)))
             (let ((completion
                    (etaf-data--finish-mutation
                     controller operation operation-id request-id v2-p raw source-condition)))
               (setq result (plist-get completion :result)
                     condition (plist-get completion :condition))
               (etaf-data--report-completion completion synchronous-p)))))
      (setq task (etaf--load-task-create
                  :scope (etaf-data--controller-scope controller)
                  :timeout (etaf-data--controller-timeout controller)
                  :success (lambda (raw) (finish raw nil))
                  :failure (lambda (error-data) (finish nil error-data)))))
    (setf (etaf-data--controller-request controller) task)
    (unwind-protect
        (condition-case err
            (progn
              (etaf-data--apply-load-loading
               controller request-id
               (list :certainty 'external-unknown :external-commit-certainty 'external-unknown
                     :pending-p t :operation operation :operation-id operation-id))
              (etaf--load-start task
                                (lambda ()
                                  (setq invoked t)
                                  (if v2-p
                                      (etaf-data--source-mutate-v2 source operation payload)
                                    (etaf-data--source-mutate source operation payload)))))
          ((error quit)
           (etaf--load-abort task)
           (when (plist-get (etaf-data--mutation-outcome controller) :pending-p)
             (let ((outcome (copy-sequence (etaf-data--mutation-outcome controller)))
                   (certainty (if invoked 'external-unknown 'rolled-back)))
               (setf (etaf-data--mutation-outcome controller)
                     (plist-put
                      (plist-put
                       (plist-put (plist-put outcome :pending-p nil) :certainty certainty)
                       :external-commit-certainty certainty)
                      :error err))))
           (signal (car err) (cdr err))))
      (setq synchronous-p nil))
    (etaf-data--signal-condition condition)
    result))

;;;###autoload
(defun etaf-data-cancel (controller)
  "Cancel CONTROLLER's pending request without stopping it; return CONTROLLER.
Loaded items remain available.  A cancelled write has unknown external
certainty unless its provider already reported a committed result; cancelling
its subsequent refresh never changes that known result."
  (etaf--assert-not-rendering 'cancel-data)
  (etaf-data--require-controller controller)
  (etaf--load-abort (etaf-data--controller-request controller) '(etaf-async-cancelled))
  controller)

(defun etaf-data--reconciliation-candidate (controller)
  "Return CONTROLLER's latest candidate, if any."
  (etaf-data--controller-projection-candidate controller))

(defun etaf-data--retry-target-contexts (candidate token)
  "Return currently live failed context IDs for CANDIDATE and TOKEN."
  (let* ((failed (copy-sequence (or (plist-get token :failed-context-ids) nil)))
         (live (etaf-data--projection-context-ids
                (etaf-data--projection-candidate-changed-sources candidate)))
         (target (cl-intersection failed live :test #'eql)))
    (if target target etaf-data--no-contexts)))

(defun etaf-data--finish-retry-dispatch
    (_controller candidate token target dispatch &optional deferred-p)
  "Finalize one partial retry and return its dispatch CONDITION, if any."
  (let ((finish
         (lambda (summary)
           (let* ((condition (plist-get summary :condition))
                  (attempted (unless (eq target etaf-data--no-contexts) target))
                  (failed
                   (and attempted
                        (etaf-data--projection-failed-context-ids
                         candidate summary condition attempted)))
                  ;; A route can become stale between target selection and
                  ;; dispatch.  It is a skipped context, not a successful one;
                  ;; retain it as failed until a later live retry can address it.
                  (stale
                   (and attempted
                        (cl-loop for context in (plist-get summary :contexts)
                                 when (and (memq (plist-get context :context-id)
                                                 attempted)
                                           (> (or (plist-get context
                                                            :stale-route-drops)
                                                  0)
                                              0))
                                 collect (plist-get context :context-id))))
                  (failed (cl-union failed stale)))
             (when attempted
             (etaf-data--token-put token :attempt
                                   (1+ (or (plist-get token :attempt) 0)))
             (etaf-data--projection-mark-token
              candidate summary condition failed attempted t))
             condition))))
    (if deferred-p
        (progn
          (etaf-scheduler-on-projection-complete finish)
          nil)
      (funcall finish (or (plist-get dispatch :summary)
                          (list :condition (plist-get dispatch :condition)
                                :contexts nil))))))

;;;###autoload
(defun etaf-data-retry-render (controller)
  "Retry only failed live contexts for CONTROLLER's latest projection.

No source mutation is replayed.  A controller with no failed contexts, or with
an `external-unknown'/'rolled-back' mutation outcome, is left untouched and
returns nil."
  (etaf-data--require-controller controller)
  (let* ((candidate (etaf-data--reconciliation-candidate controller))
         (token (and candidate
                     (etaf-data--projection-candidate-reconciliation-token
                      candidate)))
         (certainty (and token (plist-get token :certainty))))
    (when (and candidate token
               (eq certainty 'committed)
               (plist-get token :failed-context-ids))
      (let* ((target (etaf-data--retry-target-contexts candidate token))
             (dispatch
              (etaf-data--projection-dispatch candidate target))
             (condition
              (etaf-data--finish-retry-dispatch
               controller candidate token target dispatch
               (plist-get dispatch :deferred-p))))
        (when condition
          (etaf-data--signal-condition
           (etaf-data--decorate-projection-condition condition candidate)))
        (not (eq target etaf-data--no-contexts))))))

;;;###autoload
(defun etaf-data-retry-reconciliation (controller)
  "Reload a committed mutation without replaying its source mutation.

The operation is allowed only for a committed outcome with a pending token;
unknown and rolled-back outcomes are deliberately not retried.
Return the synchronous loaded page, or nil when asynchronous work is pending
or no retry is eligible.  Observe status and `etaf-data-reconciliation-state'
to distinguish completion.  No automatic write retry is performed."
  (etaf-data--require-controller controller)
  (let* ((outcome (etaf-data--mutation-outcome controller))
         (token (and outcome (plist-get outcome :reconciliation-token))))
    (when (and outcome token
               (eq (plist-get outcome :certainty) 'committed)
               (memq (plist-get token :state)
                     '(reconciliation-pending projection-pending render-pending)))
      (etaf-data--token-put token :attempt
                            (1+ (or (plist-get token :attempt) 0)))
      (let ((request (etaf-data--load-request controller outcome token)))
        (etaf-data--signal-condition (plist-get request :condition))
        (plist-get request :result)))))

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

The status is idle, loading, refreshing, success, error or cancelled.
Read-only reloads use refreshing after an accepted result; writes use loading.
Previous items remain readable until a successful load replaces them."
  (etaf-data--controller-status (etaf-data--require-controller controller)))

(defun etaf-data-error (controller)
  "Return CONTROLLER's observable error ref."
  (etaf-data--controller-error (etaf-data--require-controller controller)))

;;;###autoload
(defun etaf-data-mutation-outcome (controller)
  "Return a copy of CONTROLLER's latest mutation outcome envelope.

The envelope contains `:certainty' (`committed', `rolled-back', or
`external-unknown'), the raw mutation result, and an opaque reconciliation
token.  While an asynchronous write is outstanding, :pending-p is non-nil and
certainty is external-unknown.  After completion :pending-p is nil or absent.
The reader tracks mutation changes in reactive Views and effects; callers
do not write its state.  Treat the token as opaque.  No outcome means
no mutation has started.  Stopped Controllers reject access."
  (copy-tree
   (etaf-data--mutation-outcome
    (etaf-data--require-controller controller))))

;;;###autoload
(defun etaf-data-reconciliation-token (controller)
  "Return CONTROLLER's current opaque reconciliation token, if any."
  (copy-tree
   (etaf-data--controller-reconciliation-token
    (etaf-data--require-controller controller))))

;;;###autoload
(defun etaf-data-reconciliation-state (controller)
  "Return CONTROLLER's current reconciliation state symbol, if any."
  (let ((token (etaf-data--controller-reconciliation-token
                (etaf-data--require-controller controller))))
    (and token (plist-get token :state))))

;;;###autoload
(defun etaf-data-projection-candidate (controller)
  "Return a detached snapshot of CONTROLLER's latest projection candidate.

Reactive ref identities remain intact for diagnostics, but changing the
returned struct or its entry metadata cannot mutate the one-shot candidate
used by Data's commit/retry machinery."
  (let ((candidate
         (etaf-data--controller-projection-candidate
          (etaf-data--require-controller controller))))
    (when candidate
      (etaf-data--projection-candidate-create
       :controller-id
       (etaf-data--projection-candidate-controller-id candidate)
       :request-id
       (etaf-data--projection-candidate-request-id candidate)
       :projection-id
       (etaf-data--projection-candidate-projection-id candidate)
       :dispatch-epoch
       (etaf-data--projection-candidate-dispatch-epoch candidate)
       :kind (etaf-data--projection-candidate-kind candidate)
       :entries
       (mapcar #'copy-tree
               (etaf-data--projection-candidate-entries candidate))
       :changed-sources
       (copy-sequence
        (etaf-data--projection-candidate-changed-sources candidate))
       :certainty (etaf-data--projection-candidate-certainty candidate)
       :mutation-result
       (copy-tree
        (etaf-data--projection-candidate-mutation-result candidate))
       :reconciliation-token
       (copy-tree
        (etaf-data--projection-candidate-reconciliation-token candidate))
       :context-ids
       (copy-sequence (etaf-data--projection-candidate-context-ids candidate))
       :completed-context-ids
       (copy-sequence
        (etaf-data--projection-candidate-completed-context-ids candidate))
       :failed-context-ids
       (copy-sequence
        (etaf-data--projection-candidate-failed-context-ids candidate))
       :state (etaf-data--projection-candidate-state candidate)))))

(defun etaf-data-selection (controller)
  "Return CONTROLLER's selected identity list ref."
  (etaf-data--controller-selection
   (etaf-data--require-controller controller)))

;;;###autoload
(defun etaf-data-item-identity (controller item)
  "Return ITEM's stable selection identity in CONTROLLER.

The identity comes from the Controller's explicit `:item-key', then from its
source capability, and otherwise is ITEM itself."
  (etaf-data--item-identity (etaf-data--require-controller controller) item))

;;;###autoload
(defun etaf-data-selected-ref (controller identity)
  "Return CONTROLLER's stable boolean selection ref for IDENTITY.

The returned ref changes only when IDENTITY enters or leaves the controller's
selection.  Repeated calls for the same identity return the same ref for the
controller lifetime.  Updates made through the selection APIs or by writing
the public `etaf-data-selection' ref directly are both reflected."
  (etaf-data--ensure-selected-ref
   (etaf-data--require-controller controller) identity))

;;;###autoload
(defun etaf-data-selected-item (controller &optional item-key)
  "Return the loaded item matching CONTROLLER's first selected identity.

ITEM-KEY overrides the function supplied to `etaf-data-controller'.  When no
key function is available, item identity is compared directly.  Return nil
when the selection or current page has no matching item."
  (let* ((controller (etaf-data--require-controller controller))
         (identity (car (etaf-value (etaf-data-selection controller))))
         (items (etaf-value (etaf-data-items controller)))
         (key (or item-key (etaf-data--controller-item-key controller)
                  #'identity)))
    (when identity
      (cl-find identity items :key key :test #'equal))))

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
  (setq controller (etaf-data--require-controller controller))
  (let ((next (1+ (etaf-value (etaf-data-page controller)))))
    (etaf-data-set-page controller next)
    ;; An imperative pager must still refresh a Controller created with
    ;; AUTO-LOAD nil.  AUTO-LOAD t remains owned by its reactive effect, so
    ;; this branch avoids a duplicate source request.
    (unless (etaf-data--controller-auto-load-p controller)
      (etaf-data-load controller))
    next))

;;;###autoload
(defun etaf-data-previous-page (controller)
  "Move CONTROLLER to the previous page and return the new page."
  (setq controller (etaf-data--require-controller controller))
  (let ((previous (max 1 (1- (etaf-value (etaf-data-page controller))))))
    (etaf-data-set-page controller previous)
    (unless (etaf-data--controller-auto-load-p controller)
      (etaf-data-load controller))
    previous))

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
(defun etaf-data-select-one (controller identity)
  "Replace CONTROLLER selection with the single IDENTITY.

Use this explicit single-selection operation for tables and list views.  The
existing `etaf-data-select' API remains additive for multi-select controls."
  (let ((selection-ref (etaf-data-selection controller)))
    (setf (etaf-value selection-ref)
          (if (null identity) nil (list identity)))))

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
