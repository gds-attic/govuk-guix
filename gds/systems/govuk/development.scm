(define-module (gds systems govuk development)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 match)
  #:use-module (gnu)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages databases)
  #:use-module (gnu services networking)
  #:use-module (gnu services ssh)
  #:use-module (gnu services web)
  #:use-module (gnu services databases)
  #:use-module (gnu packages linux)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (gds packages utils custom-sources)
  #:use-module (gds packages mongodb)
  #:use-module (guix store)
  #:use-module (gds services base)
  #:use-module (gds services mongodb)
  #:use-module (gds packages govuk)
  #:use-module (gds services)
  #:use-module (gds services rails)
  #:use-module (gds services utils)
  #:use-module (gds services utils databases)
  #:use-module (gds services utils databases mysql)
  #:use-module (gds services utils databases postgresql)
  #:use-module (gds services utils databases mongodb)
  #:use-module (gds services govuk)
  #:use-module (gds services govuk plek)
  #:use-module (gds services govuk nginx))

(define govuk-ports
  `((publishing-api . 53039)
    (content-store . 53000)
    (draft-content-store . 53001)
    (content-tagger . 53116)
    (specialist-publisher . 53064)
    (need-api . 53052)
    (maslow . 53053)
    (specialist-frontend . 53065)
    (draft-specialist-frontend . 53066)
    (signon . 53016)
    (static . 53013)
    (draft-static . 53014)
    (router-api . 53056)
    (draft-router-api . 53557)))

(define system-ports
  `((postgresql . 55432)
    (mongodb . 57017)
    (redis . 56379)
    (mysql . 53306)))

(define base-services
  (list
   (syslog-service)
   (urandom-seed-service)
   (nscd-service)
   (guix-service)
   pretend-loopback-service))

(define live-router-config
  (router-config (public-port 51001)
                 (api-port 51002)
                 (debug? #t)))

(define draft-router-config
  (router-config (public-port 51003)
                 (api-port 51004)
                 (debug? #t)))

(define services
  (append
   api-services
   publishing-application-services
   supporting-application-services
   frontend-services
   draft-frontend-services
   (list
    (nginx
     govuk-ports
     live-router-config
     draft-router-config)
    (service
     redis-service-type
     (redis-configuration
      (port (assq-ref system-ports 'redis))))
    (postgresql-service #:port (assq-ref system-ports 'postgresql))
    (mongodb-service #:port (assq-ref system-ports 'mongodb))
    (mysql-service #:config (mysql-configuration
                             (port (assq-ref system-ports 'mysql))))
    govuk-content-schemas-service
    ;; Position is significant for /usr/bin/env-service and
    ;; /usr/share/zoneinfo-service, as these need to be activated
    ;; before services which require them in their activation
    (/usr/bin/env-service)
    (/usr/share/zoneinfo-service))
   base-services))

(define (update-routing-services-configuration
         services)
  (let
      ((router-config->router-nodes-value
        (lambda (router-config)
          (simple-format
           #f
           "localhost:~A"
           (router-config-api-port router-config)))))

    (update-services-parameters
     services
     (list
      (cons router-service-type
            (list
             (cons router-config?
                   (const live-router-config))))
      (cons draft-router-service-type
            (list
             (cons router-config?
                   (const draft-router-config))))
      (cons router-api-service-type
            (list
             (cons service-startup-config?
                   (lambda (ssc)
                     (service-startup-config-with-additional-environment-variables
                      ssc
                      `(("ROUTER_NODES"
                         .
                         ,(router-config->router-nodes-value
                           live-router-config))))))))
      (cons draft-router-api-service-type
            (list
             (cons service-startup-config?
                   (lambda (ssc)
                     (service-startup-config-with-additional-environment-variables
                      ssc
                      `(("ROUTER_NODES"
                         .
                         ,(router-config->router-nodes-value
                           draft-router-config))))))))))))

(define (get-package-source-config-list-from-environment regex)
  (map
   (lambda (name-value-match)
     (cons
      (string-map
       (lambda (c)
         (if (eq? c #\_) #\- c))
       (string-downcase
        (match:substring name-value-match 1)))
      (match:substring name-value-match 2)))
   (filter
    regexp-match?
    (map
     (lambda (name-value)
       (regexp-exec regex name-value))
     (environ)))))

(define (update-database-connection-config-ports ports config)
  (define (port-for service)
    (or (assq-ref ports service)
        (begin
          (display "ports: ")
          (display ports)
          (display "\n")
          (error "Missing port for " service))))

  (cond
   ((postgresql-connection-config? config)
    (postgresql-connection-config
     (inherit config)
     (port (port-for 'postgresql))))
   ((mysql-connection-config? config)
    (mysql-connection-config
     (inherit config)
     (port (port-for 'mysql))))
   ((mongodb-connection-config? config)
    (mongodb-connection-config
     (inherit config)
     (port (port-for 'mongodb))))
   ((redis-connection-config? config)
    (redis-connection-config
     (inherit config)
     (port (port-for 'redis))))
   (else (error "unknown database connection config " config))))

(define (ensure-service-parameters s test-and-value-pairs)
  (service
   (service-kind s)
   (fold
    (lambda (test+value parameters)
      (match test+value
        ((test? . value)
         (if (list? parameters)
             (if (any test? parameters)
                 (map (lambda (x) (if (test? x) value x))
                      parameters)
                 (append parameters (list value)))
             (if (test? parameters)
                 value
                 (list parameters value))))))
    (service-parameters s)
    test-and-value-pairs)))

(define (update-service-parameters s test-and-function-pairs)
  (define (update-parameter parameter)
    (fold
     (lambda (test+function parameter)
       (match test+function
         ((test . function)
          (if (test parameter)
              (function parameter)
               parameter))))
     parameter
     test-and-function-pairs))

  (service
   (service-kind s)
   (let
       ((parameters (service-parameters s)))
     (if
      (list? parameters)
      (map update-parameter parameters)
      (update-parameter parameters)))))

(define (correct-source-of package-path-list package-commit-ish-list pkg)
  (let
      ((custom-path (assoc-ref package-path-list
                               (package-name pkg)))
       (custom-commit-ish (assoc-ref package-commit-ish-list
                                     (package-name pkg))))
    (cond
     ((and custom-commit-ish custom-path)
      (error "cannot specify custom-commit-ish and custom-path"))
     (custom-commit-ish
      (package
        (inherit pkg)
        (source
         (custom-github-archive-source-for-package
          pkg
          custom-commit-ish))))
     (custom-path
      (package
        (inherit pkg)
        (source custom-path)))
     (else
      pkg))))

(define (log-package-path-list package-path-list)
  (for-each
   (match-lambda
     ((package . path)
      (simple-format
       #t
       "Using path \"~A\" for the ~A package\n"
       path
       package)))
   package-path-list))

(define (log-package-commit-ish-list package-commit-ish-list)
  (for-each
   (match-lambda
     ((package . commit-ish)
      (simple-format
       #t
       "Using commit-ish \"~A\" for the ~A package\n"
       commit-ish
       package)))
   package-commit-ish-list))

(define (port-for service)
  (or (assq-ref govuk-ports service)
      (assq-ref system-ports service)))

(define (set-random-rails-secret-token service)
  (update-service-parameters
   service
   (list
    (cons rails-app-config?
          update-rails-app-config-with-random-secret-token))))

(define (set-plek-config services)
  (map
   (lambda (service)
     (update-service-parameters
      service
      (list
       (cons
        plek-config?
        (const (make-custom-plek-config
                govuk-ports
                #:govuk-app-domain "guix-dev.gov.uk"
                #:use-https? #f
                #:port 50080))))))
   services))

(define plek-config
  (make-custom-plek-config
   govuk-ports
   #:govuk-app-domain "guix-dev.gov.uk"
   #:use-https? #f
   #:port 50080))

(define-public (setup-services services)
  (map
   (lambda (service)
     (update-service-parameters
      service
      (list
       (cons
        database-connection-config?
        (lambda (config)
          (update-database-connection-config-ports system-ports config)))
       (cons
        rails-app-config?
        (lambda (config)
          (update-rails-app-config-environment
           "development"
           (update-rails-app-config-with-random-secret-key-base config)))))))
   (update-routing-services-configuration
    (correct-services-package-source-from-environment
     (update-services-parameters
      services
      (list
       (cons
        (const #t)
        (list
         (cons
          plek-config?
          (const plek-config))))))))))

(define development-os-services
  (setup-services services))

(define-public development-os
  (operating-system
    (host-name "govuk-test")
    (timezone "Europe/London")
    (locale "en_GB.UTF-8")
    (bootloader (grub-configuration (device "/dev/sdX")))
    (hosts-file
     (plain-file "hosts"
                 (string-join
                  (list
                   (local-host-aliases host-name)
                   (plek-config->/etc/hosts-string plek-config))
                  "\n")))
    (packages
     (cons*
      govuk-setenv
      strace
      (specification->package+output "bind" "utils")
      glibc
      postgresql
      mariadb
      mongodb
      mongo-tools
      htop
      %base-packages))
    (file-systems
     (cons (file-system
             (device "my-root")
             (title 'label)
             (mount-point "/")
             (type "ext4"))
           %base-file-systems))
    (services
     development-os-services)))

development-os
