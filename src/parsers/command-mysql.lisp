;;;
;;; Parse the pgloader commands grammar
;;;

(in-package :pgloader.parser)

(defun mysql-connection-bindings (my-db-uri)
  "Generate the code needed to set MySQL connection bindings."
  (destructuring-bind (&key ((:host myhost))
                            ((:port myport))
                            ((:user myuser))
                            ((:password mypass))
                            ((:dbname mydb))
                            &allow-other-keys)
      my-db-uri
    `((*myconn-host* ',myhost)
      (*myconn-port* ,myport)
      (*myconn-user* ,myuser)
      (*myconn-pass* ,mypass)
      (*my-dbname*   ,mydb))))

;;;
;;; Materialize views by copying their data over, allows for doing advanced
;;; ETL processing by having parts of the processing happen on the MySQL
;;; query side.
;;;
(defrule view-name (and (alpha-char-p character)
			(* (or (alpha-char-p character)
			       (digit-char-p character)
			       #\_)))
  (:text t))

(defrule view-sql (and kw-as dollar-quoted)
  (:destructure (as sql) (declare (ignore as)) sql))

(defrule view-definition (and view-name (? view-sql))
  (:destructure (name sql) (cons name sql)))

(defrule another-view-definition (and comma view-definition)
  (:lambda (source)
    (bind (((_ view) source)) view)))

(defrule views-list (and view-definition (* another-view-definition))
  (:lambda (vlist)
    (destructuring-bind (view1 views) vlist
      (list* view1 views))))

(defrule materialize-all-views (and kw-materialize kw-all kw-views)
  (:constant :all))

(defrule materialize-view-list (and kw-materialize kw-views views-list)
  (:destructure (mat views list) (declare (ignore mat views)) list))

(defrule materialize-views (or materialize-view-list materialize-all-views)
  (:lambda (views)
    (cons :views views)))


;;;
;;; Including only some tables or excluding some others
;;;
(defrule namestring-or-regex (or quoted-namestring quoted-regex))

(defrule another-namestring-or-regex (and comma namestring-or-regex)
  (:lambda (source)
    (bind (((_ re) source)) re)))

(defrule filter-list (and namestring-or-regex (* another-namestring-or-regex))
  (:lambda (source)
    (destructuring-bind (filter1 filters) source
      (list* filter1 filters))))

(defrule including (and kw-including kw-only kw-table kw-names kw-matching
			filter-list)
  (:lambda (source)
    (bind (((_ _ _ _ _ filter-list) source))
      (cons :including filter-list))))

(defrule excluding (and kw-excluding kw-table kw-names kw-matching filter-list)
  (:lambda (source)
    (bind (((_ _ _ _ filter-list) source))
      (cons :excluding filter-list))))


;;;
;;; Per table encoding options, because MySQL is so bad at encoding...
;;;
(defrule decoding-table-as (and kw-decoding kw-table kw-names kw-matching
                                filter-list
                                kw-as encoding)
  (:lambda (source)
    (bind (((_ _ _ _ filter-list _ encoding) source))
      (cons encoding filter-list))))

(defrule decoding-tables-as (+ decoding-table-as)
  (:lambda (tables)
    (cons :decoding tables)))


;;;
;;; Allow clauses to appear in any order
;;;
(defrule load-mysql-optional-clauses (* (or mysql-options
                                            gucs
                                            casts
                                            materialize-views
                                            including
                                            excluding
                                            decoding-tables-as
                                            before-load
                                            after-load))
  (:lambda (clauses-list)
    (alexandria:alist-plist clauses-list)))

(defrule load-mysql-command (and database-source target
                                 load-mysql-optional-clauses)
  (:lambda (command)
    (destructuring-bind (source target clauses) command
      `(,source ,target ,@clauses))))


;;; LOAD DATABASE FROM mysql://
(defrule load-mysql-database load-mysql-command
  (:lambda (source)
    (bind (((my-db-uri pg-db-uri
                       &key
                       gucs casts views before after
                       ((:mysql-options options))
                       ((:including incl))
                       ((:excluding excl))
                       ((:decoding decoding-as)))           source)

           ((&key ((:dbname mydb)) table-name
                  &allow-other-keys)                        my-db-uri)

           ((&key ((:dbname pgdb)) &allow-other-keys)       pg-db-uri))
      `(lambda ()
         (let* ((state-before  (pgloader.utils:make-pgstate))
                (*state*       (or *state* (pgloader.utils:make-pgstate)))
                (state-idx     (pgloader.utils:make-pgstate))
                (state-after   (pgloader.utils:make-pgstate))
                (*default-cast-rules* ',*mysql-default-cast-rules*)
                (*cast-rules*         ',casts)
                ,@(mysql-connection-bindings my-db-uri)
                ,@(pgsql-connection-bindings pg-db-uri gucs)
                ,@(batch-control-bindings options)
                (source
                 (make-instance 'pgloader.mysql::copy-mysql
                                :target-db ,pgdb
                                :source-db ,mydb)))

           ,(sql-code-block pgdb 'state-before before "before load")

           (pgloader.mysql:copy-database source
                                         ,@(when table-name
                                                 `(:only-tables ',(list table-name)))
                                         :including ',incl
                                         :excluding ',excl
                                         :decoding-as ',decoding-as
                                         :materialize-views ',views
                                         :state-before state-before
                                         :state-after state-after
                                         :state-indexes state-idx
                                         ,@(remove-batch-control-option options))

           ,(sql-code-block pgdb 'state-after after "after load")

           (report-full-summary "Total import time" *state*
                                :before   state-before
                                :finally  state-after
                                :parallel state-idx))))))
