(define-module (gds data transformations mysql)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 match)
  #:use-module (guix gexp)
  #:use-module (gnu packages base)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages pv)
  #:use-module (gnu services)
  #:use-module (gnu services databases)
  #:use-module (gds data data-extract)
  #:use-module (gds services utils databases mysql)
  #:export (with-mysql

            mysql-load-extracts))

(define* (with-mysql
          mysql-service
          gexp-to-run
          #:key (base-directory #~(string-append
                                   (getcwd)
                                   "/mysql")))

  (let ((mysql ((@@ (gnu services databases) mysql-configuration-mysql)
                (service-value mysql-service))))
    (with-imported-modules '((guix build utils))
      #~(begin
          (add-to-load-path #$(file-append shepherd
                                           "/share/guile/site/"
                                           (effective-version)))

          (use-modules (shepherd service)
                       (guix build utils))

          (define base-directory #$base-directory)

          (setenv "PATH"
                  (list->search-path-as-string
                   (cons* #$(file-append mysql "/bin")
                          #$(file-append pv "/bin")
                          #$(file-append gzip "/bin")
                          (string-append #$xz "/bin")
                          ;; TODO: mysql_install_db uses mkdir and sed
                          #$(file-append coreutils "/bin")
                          #$(file-append sed "/bin")
                          (search-path-as-string->list (getenv "PATH")))
                   ":"))

          (define configuration-file
            (string-append (getcwd) "/my.cnf"))

          (define socket-file
            (string-append (getcwd) "/mysqld.sock"))

          (setenv "MYSQL_UNIX_PORT" socket-file)

          (call-with-output-file configuration-file
            (lambda (port)
              (display "[mysqld]\n" port)
              (display (string-append "datadir=" base-directory "\n")
                       port)
              (display (string-append "socket=" socket-file "\n")
                       port)
              (display "max_allowed_packet=1G\n" port)
              (display "\n" port)))

          (mkdir-p base-directory)
          (invoke #$(file-append mysql "/bin/mysql_install_db")
                  (string-append "--datadir=" base-directory))

          (simple-format #t "\nSuccessfully boostrapped MySQL\n\n")
          (force-output)

          ;; TODO: This might work in the future, but currently fails
          ;; as the mysql.server script and mysqld_safe use sed,
          ;; hostname, ... and can't access them
          (define (mysql.server . args)
            (let ((command
                   `(#$(file-append mysql
                                    "/share/mysql/support-files/mysql.server")
                     ,@args)))
              (simple-format #t "running: ~A\n" (string-join command " "))
              (force-output)
              (apply invoke command)))

          (define (start-mysql)
            ((make-forkexec-constructor
              (list #$(file-append mysql "/bin/mysqld")
                    (string-append "--defaults-file=" configuration-file)
                    "--innodb_buffer_pool_size=1GB"
                    "--skip-innodb_doublewrite"
                    "--innodb_flush_log_at_trx_commit=0"
                    "--innodb_flush_method=nosync"
                    "--innodb_io_capacity=2000"
                    "--innodb_io_capacity_max=3000"
                    "--pid-file=/tmp/mysql.pid")
              #:pid-file "/tmp/mysql.pid")))

          (let ((mysql-pid (start-mysql))
                (result
                 (#$gexp-to-run)))

            (simple-format #t "Stopping MySQL\n")
            (force-output)
            ((make-kill-destructor) mysql-pid)
            ;; TODO: Fix this
            (sleep 10)
            (simple-format #t "Finished sleeping after stopping MySQL\n")
            (force-output)

            result)))))

(define (mysql-load-extracts extracts-and-database-connection-configs)
  (define operation
    (with-imported-modules '((gds data transformations build mysql))
      #~(lambda _
          (use-modules (gds data transformations build mysql))
          #$@(append-map
              (match-lambda
                ((data-extract . database-connection-configs)
                 (map
                  (lambda (database-connection-config)
                    #~(let ((database #$(mysql-connection-config-database
                                         database-connection-config)))
                        (invoke
                         "mysql" "--user=root" "-e"
                         (string-append
                          "CREATE DATABASE " database ";"
                          "GRANT ALL ON " database ".* TO ''@'localhost';"))

                        (decompress-file-and-pipe-to-mysql
                         #$(data-extract-file data-extract)
                         database)))
                  database-connection-configs)))
              extracts-and-database-connection-configs))))

  #~(begin
      #$(with-mysql
         (service mysql-service-type)
         operation)))
