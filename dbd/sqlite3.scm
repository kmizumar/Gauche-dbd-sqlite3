(define-module dbd.sqlite3
  (use dbi)
  (use gauche.uvector)
  (use util.list)
  (use util.match)
  (use gauche.collection)
  (use util.stream)
  (export
   <sqlite3-driver>
   <sqlite3-connection>
   <sqlite3-result-set>
   sqlite3-error-message
   sqlite3-table-columns
   sqlite3-last-id
   ))
(select-module dbd.sqlite3)

(dynamic-load "dbd_sqlite3")

;;;
;;; Sqlite3 specific interfaces
;;;

(define (sqlite3-table-columns conn table)
  (map
   (lambda (row) 
     (dbi-get-value row 1))
   (dbi-do conn "PRAGMA table_info(?)" '() table)))

(define (sqlite3-error-message conn)
  (sqlite3-errmsg (slot-ref conn '%handle)))

(define (sqlite3-last-id conn)
  (sqlite3-last-insert-rowid (slot-ref conn '%handle)))

;;;
;;; DBI interfaces
;;;

(define-class <sqlite3-driver> (<dbi-driver>)
  ())

(define-class <sqlite3-connection> (<dbi-connection>)
  ((%handle :init-value #f)
   (%filename :init-value #f :init-keyword :filename)))

(define-class <sqlite3-result-set> (<relation> <sequence>)
  ((%db :init-keyword :db)
   (%handle :init-keyword :handle)
   (%stream :init-value #f)
   (%cache :init-form '())
   (field-names :init-keyword :field-names)))

(define-condition-type <sqlite3-error> <dbi-error> #f
  (error-code))

(define-method dbi-make-connection ((d <sqlite3-driver>)
                                    (options <string>)
                                    (option-alist <list>)
                                    . args)
  (let* ((db-name
          (match option-alist
                 (((maybe-db . #t) . rest) maybe-db)
                 (else (assoc-ref option-alist "db" #f))))
         (conn (make <sqlite3-connection>
                 :filename db-name)))
    (guard (e (else (error <sqlite3-error> :message "SQLite3 open failed")))
      (slot-set! conn '%handle (sqlite3-open db-name)))
    conn))

(define-method dbi-execute-using-connection
  ((c <sqlite3-connection>) (q <dbi-query>) params)

  (define (prepare db query)
    (let ((stmt (make-sqlite-statement)))
      (unless (guard (e (else 
                         (error <sqlite3-error> 
                                :message (slot-ref e 'message))))
                (sqlite3-prepare db stmt query))
        (errorf
         <sqlite3-error> :error-message (sqlite3-errmsg db)
         "SQLite3 query failed: ~a" (sqlite3-errmsg db)))
      (make <sqlite3-result-set>
        :db db
        :handle stmt
        :field-names (sqlite3-statement-column-names stmt))))

  (let* ((query-string (apply (slot-ref q 'prepared) params))
         (result (prepare (slot-ref c '%handle) query-string)))
    (slot-set! result '%stream (statement-next result))
    result))

(define-method dbi-escape-sql ((c <sqlite3-connection>) str)
  (sqlite3-escape-string str))

(define-method dbi-open? ((c <sqlite3-connection>))
  (not (sqlite3-closed-p (slot-ref c '%handle))))

(define-method dbi-open? ((c <sqlite3-result-set>))
  (not (sqlite3-statement-closed-p (slot-ref c '%handle))))

(define-method dbi-close ((c <sqlite3-connection>))
  (guard (e (else (error <sqlite3-error> :message (slot-ref e 'message))))
    (sqlite3-close (slot-ref c '%handle))))

(define-method dbi-close ((result-set <sqlite3-result-set>))
  (sqlite3-statement-finish (slot-ref result-set '%handle)))

;;;
;;; Relation interfaces
;;;

(define-method relation-column-names ((r <sqlite3-result-set>))
  (ref r 'field-names))

(define-method relation-accessor ((r <sqlite3-result-set>))
  (let1 columns (ref r 'field-names)
    (lambda (row column . maybe-default)
      (cond
       ((find-index (cut string=? <> column) columns)
        => (cut vector-ref row <>))
       ((pair? maybe-default) (car maybe-default))
       (else (error "invalud column name:" column))))))

;;TODO
(define-method relation-modifier ((r <sqlite3-result-set>))
  )

(define-method relation-rows ((r <sqlite3-result-set>))
  (map identity r))

;;;
;;; Sequence interfaces
;;;

(define-method call-with-iterator ((r <sqlite3-result-set>) proc . option)
  (let* ((s (slot-ref r '%stream))
         (next (^ () (begin0
                       (stream-car s)
                       (set! s (stream-cdr s)))))
         (end? (^ () (stream-null? s))))
    (proc end? next)))

(define (statement-next rset)

  (define (next)
    (guard (e (else (error <sqlite3-error> 
                           :message (sqlite3-errmsg (slot-ref rset '%db)))))
      (sqlite3-statement-step (slot-ref rset '%handle))))

  (cond
   ((sqlite3-statement-end? (slot-ref rset '%handle))
    stream-null)
   ((next) =>
    (^n (stream-delay (cons n (statement-next rset)))))
   (else
    stream-null)))

;;;
;;;TODO dbi extensions
;;;

;;TODO isolation level
(define-class <dbi-transaction> ()
  ((connection :init-keyword :connection)))

;; Begin transaction and return <dbi-transaction> instance.
(define-method dbi-begin-transaction ((conn <dbi-connection>) . args)
  (make <dbi-transaction> :connection conn))

(define-method dbi-commit ((tran <dbi-transaction>) . args))

(define-method dbi-rollback ((tran <dbi-transaction>) . args))

;; proc accept a <dbi-transaction>.
(define (call-with-transaction conn proc . flags)
  (let1 tran (apply dbi-begin-transaction conn flags)
    (guard (e (else 
               (guard (e2 (else 
                           (raise (make-compound-condition e e2))))
                      (dbi-rollback tran)
                      (raise e))))
      (begin0
        (proc tran)
        (dbi-commit tran)))))

(define-method dbi-tables ((conn <dbi-connection>))
  '())

(export-if-defined call-with-transaction dbi-tables)


;;;
;;; Transaction interfaces
;;;

(define-class <sqlite3-transaction> (<dbi-transaction>)
  ())

(define-method dbi-begin-transaction ((conn <sqlite3-connection>) . args)
  (rlet1 tran (make <sqlite3-transaction> :connection conn)
    (dbi-do conn "BEGIN TRANSACTION")))

(define-method dbi-commit ((tran <sqlite3-transaction>) . args)
  (dbi-do (slot-ref tran 'connection)
          "COMMIT TRANSACTION"))

(define-method dbi-rollback ((tran <sqlite3-transaction>) . args)
  (dbi-do (slot-ref tran 'connection)
          "ROLLBACK TRANSACTION"))

(define-method dbi-tables ((conn <sqlite3-connection>))
  (map
   (lambda (row) (dbi-get-value row 0))
   (dbi-do conn "SELECT name FROM sqlite_master WHERE type='table'")))

