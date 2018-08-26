(define-module (gds data govuk sources govuk-puppet-aws)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-19)
  #:use-module (srfi srfi-26)
  #:use-module (ice-9 match)
  #:use-module (ice-9 ftw)
  #:use-module (web uri)
  #:use-module (json)
  #:use-module (guix gexp)
  #:use-module (guix hash)
  #:use-module (guix base32)
  #:use-module (guix download)
  #:use-module (guix packages)
  #:use-module (gnu packages guile)
  #:use-module (gds services govuk)
  #:use-module (gds services govuk signon)
  #:use-module (gds services govuk rummager)
  #:use-module (gds data data-source)
  #:use-module (gds data data-extract)
  #:use-module (gds data tar-extract)
  #:use-module (gds data govuk sources govuk-puppet)
  #:export (govuk-puppet-aws-data-source))

;;;
;;; Source file handling
;;;

(define postgresql-extracts
  `(("content_audit_tool_production" . (,content-audit-tool-service-type))
    ("content_performance_manager_production" .
     (,content-performance-manager-service-type))
    ("content_tagger_production" . (,content-tagger-service-type))
    ("email-alert-api_production" . (,email-alert-api-service-type))
    ("link_checker_api_production" . (,link-checker-api-service-type))
    ("local-links-manager_production" . (,local-links-manager-service-type))
    ("policy-publisher_production" . (,policy-publisher-service-type))
    ("publishing_api_production"  .(,publishing-api-service-type))
    ("service-manual-publisher_production" .
     (,service-manual-publisher-service-type))
    ("support_contacts_production" . (,support-api-service-type))
    ;;("transition_production" . (,transition-service-type))
    ))

(define mysql-extracts
  `(("collections_publisher_production" . (,collections-publisher-service-type))
    ("contacts_production" . (,contacts-admin-service-type))
    ("release_production" . (,release-service-type))
    ("search_admin_production" . (,search-admin-service-type))
    ("signon_production" . (,signon-service-type))
    ("whitehall_production" . (,whitehall-service-type))))

(define mongodb-extracts
  `(("mongo" .
     (("content_store_production" . (,content-store-service-type))
      ("draft_content_store_production" . (,draft-content-store-service-type))
      ("govuk_assets_production" . (,asset-manager-service-type))
      ("govuk_content_production" . (,publisher-service-type
                                     ,manuals-publisher-service-type
                                     ,specialist-publisher-service-type))
      ("imminence_production" . (,imminence-service-type))
      ("licence_finder_production" . (,licence-finder-service-type))
      ("maslow_production" . (,maslow-service-type))
      ("short_url_manager_production" . (,short-url-manager-service-type))
      ("travel_advice_publisher_production" .
       (,travel-advice-publisher-service-type))))
     ("router_backend" .
      (("authenticating_proxy_production" . (,authenticating-proxy-service-type))
       ("draft_router" . (,draft-router-service-type
                          ,draft-router-api-service-type))
       ("router" . (,router-service-type ,router-api-service-type))))))

(define (find-data-extracts backup-directory)
  (define (log message value)
    ;;(simple-format #t "~A: ~A\n" message value)
    value)

  (define (process-date-dir date stat . children)
    (append-map
     (cut apply process-database-dir date <>)
     children))

  (define (process-database-dir date database stat . children)
    (cond
     ((string=? database "postgresql")
      (create-extracts-from-sql-dump-files postgresql-extracts
                                           date
                                           database
                                           children))

     ((string=? database "mysql")
      (append-map (match-lambda*
                    (((filename stat . children))
                     (if (string=? filename "mysql-master")
                         (create-extracts-from-sql-dump-files mysql-extracts
                                                              date
                                                              database
                                                              children)
                         '())))
                  children))

     ((string=? database "mongo")
      (append-map (match-lambda*
                    (((filename stat . children))
                     (or (and=> (assoc-ref mongodb-extracts
                                       filename)
                                (lambda (extracts)
                                  (create-extracts-from-mongodb-dump-files extracts
                                                                           date
                                                                           filename
                                                                           children)))
                         '())))
                  children))

     (else
      '())))

  (define (create-extracts-from-mongodb-dump-files extracts date subdirectory files)
    (define filenames (map car files))

    (define (filename-for-extract extract-prefix)
      (find (lambda (filename)
              (member filename filenames))
            (map (lambda (suffix)
                   (string-append extract-prefix suffix))
                 '(".tar.xz" "tar.gz"))))

    (define (create-data-extract filename services)
      (data-extract
       (file (local-file
              (string-join
               `(,backup-directory
                 ,date
                 "mongo"
                 ,subdirectory
                 ,filename)
               "/")))
       (datetime (string->date date "~Y-~m-~d"))
       (database "mongo")
       (services services)
       (data-source govuk-puppet-aws-data-source)))

    (filter-map (match-lambda
                  ((extract-prefix . services)
                   (and=> (filename-for-extract extract-prefix)
                          (lambda (filename)
                            (create-data-extract filename
                                                 services)))))
                extracts))

  (define (create-extracts-from-sql-dump-files extracts date database files)
    (define filenames
      (map car files))

    (define (filename-for-extract extract-prefix)
      (find (lambda (filename)
              (member filename filenames))
            (list (string-append extract-prefix ".dump.xz")
                  (string-append extract-prefix ".dump.gz"))))

    (define (create-data-extract filename services)
      (data-extract
       (file (local-file
              (string-join
               `(,backup-directory
                 ,date
                 ,database
                 ,@(if (string=? "mysql" database)
                       '("mysql-master")
                       '())
                 ,filename)
               "/")))
       (datetime (string->date date "~Y-~m-~d"))
       (database database)
       (services services)
       (data-source govuk-puppet-aws-data-source)))

    (filter-map (match-lambda
                  ((extract-prefix . services)
                   (and=> (filename-for-extract extract-prefix)
                          (lambda (filename)
                            (create-data-extract filename
                                                 services)))))
                extracts))

  (let ((tree (file-system-tree backup-directory (const #t) stat)))
    (append-map
     (cut apply process-date-dir <>)
     (cddr tree))))

;;;
;;; govuk-puppet-aws-data-source
;;;

(define list-extracts
  (lambda ()
    (find-data-extracts (backups-directory))))

(define govuk-puppet-aws-data-source
  (data-source
   (name "govuk-puppet-aws")
   (list-extracts list-extracts)
   (list-extracts-from-data-directory-index #f)
   (data-directory-with-index #f)
   (priority 1)))
