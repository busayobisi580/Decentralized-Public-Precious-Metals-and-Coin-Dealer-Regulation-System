;; Authentication and Grading Oversight Contract
;; Regulates coin grading services and authenticity verification

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-ALREADY-REGISTERED (err u301))
(define-constant ERR-NOT-REGISTERED (err u302))
(define-constant ERR-INVALID-INPUT (err u303))
(define-constant ERR-INSUFFICIENT-FUNDS (err u304))
(define-constant ERR-INVALID-GRADE (err u305))
(define-constant ERR-DISPUTE-EXISTS (err u306))

;; Data Variables
(define-data-var grading-service-fee uint u2000000) ;; 2 STX
(define-data-var authentication-fee uint u100000)   ;; 0.1 STX per item
(define-data-var max-grade uint u70) ;; Maximum grade (MS-70)
(define-data-var dispute-resolution-fee uint u500000) ;; 0.5 STX

;; Data Maps
(define-map grading-services
  { service: principal }
  {
    company-name: (string-ascii 100),
    certification-number: (string-ascii 50),
    specializations: (list 10 (string-ascii 30)),
    registration-date: uint,
    status: (string-ascii 20),
    total-gradings: uint,
    accuracy-score: uint,
    last-audit: uint
  }
)

(define-map administrators { admin: principal } { authorized: bool })
(define-map quality-auditors { auditor: principal } { authorized: bool })

(define-map graded-items
  { service: principal, item-id: uint }
  {
    description: (string-ascii 200),
    grade: uint,
    grade-type: (string-ascii 20), ;; "MS", "PR", "AU", etc.
    authentication-status: (string-ascii 20),
    grading-date: uint,
    grader-notes: (string-ascii 500),
    owner: principal,
    verification-hash: (buff 32)
  }
)

(define-map authentication-requests
  { requester: principal, request-id: uint }
  {
    item-description: (string-ascii 200),
    service-requested: principal,
    status: (string-ascii 20),
    request-date: uint,
    completion-date: uint,
    fee-paid: bool,
    result: (string-ascii 20)
  }
)

(define-map disputes
  { disputer: principal, item-service: principal, item-id: uint }
  {
    dispute-reason: (string-ascii 300),
    dispute-date: uint,
    status: (string-ascii 20),
    resolution: (string-ascii 300),
    resolution-date: uint,
    fee-paid: bool
  }
)

;; Initialize contract
(map-set administrators { admin: CONTRACT-OWNER } { authorized: true })

;; Admin Functions
(define-public (add-administrator (new-admin principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-set administrators { admin: new-admin } { authorized: true }))
  )
)

(define-public (add-quality-auditor (new-auditor principal))
  (begin
    (asserts! (default-to false (get authorized (map-get? administrators { admin: tx-sender }))) ERR-NOT-AUTHORIZED)
    (ok (map-set quality-auditors { auditor: new-auditor } { authorized: true }))
  )
)

(define-public (set-grading-service-fee (new-fee uint))
  (begin
    (asserts! (default-to false (get authorized (map-get? administrators { admin: tx-sender }))) ERR-NOT-AUTHORIZED)
    (asserts! (> new-fee u0) ERR-INVALID-INPUT)
    (ok (var-set grading-service-fee new-fee))
  )
)

;; Grading Service Registration
(define-public (register-grading-service
  (company-name (string-ascii 100))
  (certification-number (string-ascii 50))
  (specializations (list 10 (string-ascii 30)))
)
  (let
    (
      (existing-service (map-get? grading-services { service: tx-sender }))
    )
    (asserts! (is-none existing-service) ERR-ALREADY-REGISTERED)
    (asserts! (> (len company-name) u0) ERR-INVALID-INPUT)
    (asserts! (> (len certification-number) u0) ERR-INVALID-INPUT)
    (asserts! (> (len specializations) u0) ERR-INVALID-INPUT)

    (try! (stx-transfer? (var-get grading-service-fee) tx-sender CONTRACT-OWNER))

    (map-set grading-services
      { service: tx-sender }
      {
        company-name: company-name,
        certification-number: certification-number,
        specializations: specializations,
        registration-date: block-height,
        status: "active",
        total-gradings: u0,
        accuracy-score: u100, ;; Start with 100% accuracy
        last-audit: u0
      }
    )
    (ok true)
  )
)

;; Grading Functions
(define-public (submit-grading
  (item-id uint)
  (description (string-ascii 200))
  (grade uint)
  (grade-type (string-ascii 20))
  (grader-notes (string-ascii 500))
  (owner principal)
  (verification-hash (buff 32))
)
  (let
    (
      (service (unwrap! (map-get? grading-services { service: tx-sender }) ERR-NOT-REGISTERED))
      (current-gradings (get total-gradings service))
    )
    (asserts! (is-eq (get status service) "active") ERR-NOT-REGISTERED)
    (asserts! (<= grade (var-get max-grade)) ERR-INVALID-GRADE)
    (asserts! (> grade u0) ERR-INVALID-GRADE)
    (asserts! (> (len description) u0) ERR-INVALID-INPUT)

    (map-set graded-items
      { service: tx-sender, item-id: item-id }
      {
        description: description,
        grade: grade,
        grade-type: grade-type,
        authentication-status: "authenticated",
        grading-date: block-height,
        grader-notes: grader-notes,
        owner: owner,
        verification-hash: verification-hash
      }
    )

    (map-set grading-services
      { service: tx-sender }
      (merge service { total-gradings: (+ current-gradings u1) })
    )
    (ok true)
  )
)

;; Authentication Request Functions
(define-public (request-authentication
  (request-id uint)
  (item-description (string-ascii 200))
  (service-requested principal)
)
  (begin
    (asserts! (> (len item-description) u0) ERR-INVALID-INPUT)
    (asserts! (is-some (map-get? grading-services { service: service-requested })) ERR-NOT-REGISTERED)

    (try! (stx-transfer? (var-get authentication-fee) tx-sender CONTRACT-OWNER))

    (map-set authentication-requests
      { requester: tx-sender, request-id: request-id }
      {
        item-description: item-description,
        service-requested: service-requested,
        status: "pending",
        request-date: block-height,
        completion-date: u0,
        fee-paid: true,
        result: "pending"
      }
    )
    (ok true)
  )
)

(define-public (complete-authentication
  (requester principal)
  (request-id uint)
  (result (string-ascii 20))
)
  (let
    (
      (request (unwrap! (map-get? authentication-requests { requester: requester, request-id: request-id }) ERR-INVALID-INPUT))
    )
    (asserts! (is-eq (get service-requested request) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status request) "pending") ERR-INVALID-INPUT)
    (asserts! (or (is-eq result "authentic") (is-eq result "counterfeit") (is-eq result "inconclusive")) ERR-INVALID-INPUT)

    (map-set authentication-requests
      { requester: requester, request-id: request-id }
      (merge request {
        status: "completed",
        completion-date: block-height,
        result: result
      })
    )
    (ok true)
  )
)

;; Dispute Management
(define-public (file-dispute
  (item-service principal)
  (item-id uint)
  (dispute-reason (string-ascii 300))
)
  (let
    (
      (graded-item (unwrap! (map-get? graded-items { service: item-service, item-id: item-id }) ERR-INVALID-INPUT))
      (existing-dispute (map-get? disputes { disputer: tx-sender, item-service: item-service, item-id: item-id }))
    )
    (asserts! (is-none existing-dispute) ERR-DISPUTE-EXISTS)
    (asserts! (> (len dispute-reason) u0) ERR-INVALID-INPUT)

    (try! (stx-transfer? (var-get dispute-resolution-fee) tx-sender CONTRACT-OWNER))

    (map-set disputes
      { disputer: tx-sender, item-service: item-service, item-id: item-id }
      {
        dispute-reason: dispute-reason,
        dispute-date: block-height,
        status: "open",
        resolution: "",
        resolution-date: u0,
        fee-paid: true
      }
    )
    (ok true)
  )
)

(define-public (resolve-dispute
  (disputer principal)
  (item-service principal)
  (item-id uint)
  (resolution (string-ascii 300))
)
  (let
    (
      (dispute (unwrap! (map-get? disputes { disputer: disputer, item-service: item-service, item-id: item-id }) ERR-INVALID-INPUT))
    )
    (asserts! (default-to false (get authorized (map-get? quality-auditors { auditor: tx-sender }))) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status dispute) "open") ERR-INVALID-INPUT)
    (asserts! (> (len resolution) u0) ERR-INVALID-INPUT)

    (map-set disputes
      { disputer: disputer, item-service: item-service, item-id: item-id }
      (merge dispute {
        status: "resolved",
        resolution: resolution,
        resolution-date: block-height
      })
    )
    (ok true)
  )
)

;; Quality Audit Functions
(define-public (conduct-service-audit (service principal) (new-accuracy-score uint))
  (let
    (
      (service-data (unwrap! (map-get? grading-services { service: service }) ERR-NOT-REGISTERED))
    )
    (asserts! (default-to false (get authorized (map-get? quality-auditors { auditor: tx-sender }))) ERR-NOT-AUTHORIZED)
    (asserts! (<= new-accuracy-score u100) ERR-INVALID-INPUT)

    (map-set grading-services
      { service: service }
      (merge service-data {
        accuracy-score: new-accuracy-score,
        last-audit: block-height,
        status: (if (< new-accuracy-score u70) "suspended" "active")
      })
    )
    (ok true)
  )
)

;; Read-only Functions
(define-read-only (get-grading-service (service principal))
  (map-get? grading-services { service: service })
)

(define-read-only (get-graded-item (service principal) (item-id uint))
  (map-get? graded-items { service: service, item-id: item-id })
)

(define-read-only (get-authentication-request (requester principal) (request-id uint))
  (map-get? authentication-requests { requester: requester, request-id: request-id })
)

(define-read-only (get-dispute (disputer principal) (item-service principal) (item-id uint))
  (map-get? disputes { disputer: disputer, item-service: item-service, item-id: item-id })
)

(define-read-only (is-registered-service (service principal))
  (let
    (
      (service-data (map-get? grading-services { service: service }))
    )
    (match service-data
      data (is-eq (get status data) "active")
      false
    )
  )
)

(define-read-only (get-grading-service-fee)
  (var-get grading-service-fee)
)

(define-read-only (get-authentication-fee)
  (var-get authentication-fee)
)

(define-read-only (is-administrator (user principal))
  (default-to false (get authorized (map-get? administrators { admin: user })))
)

(define-read-only (is-quality-auditor (user principal))
  (default-to false (get authorized (map-get? quality-auditors { auditor: user })))
)
