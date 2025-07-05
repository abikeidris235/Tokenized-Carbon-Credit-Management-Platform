;; Credit Generation Contract
;; Issues verified carbon credits based on validated emission reductions

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u200))
(define-constant ERR_INVALID_PROJECT (err u201))
(define-constant ERR_INVALID_AMOUNT (err u202))
(define-constant ERR_CREDIT_EXISTS (err u203))
(define-constant ERR_INSUFFICIENT_CREDITS (err u204))

;; Data Variables
(define-data-var next-project-id uint u1)
(define-data-var next-credit-id uint u1)
(define-data-var total-credits-issued uint u0)

;; Data Maps
(define-map carbon-projects
  { project-id: uint }
  {
    name: (string-ascii 100),
    developer: principal,
    project-type: (string-ascii 50),
    location: (string-ascii 100),
    standard: (string-ascii 20),
    registered-at: uint,
    verified: bool,
    verifier: (optional principal)
  }
)

(define-map carbon-credits
  { credit-id: uint }
  {
    project-id: uint,
    owner: principal,
    amount: uint,
    vintage: uint,
    issued-at: uint,
    retired: bool,
    retired-at: (optional uint),
    metadata: (string-ascii 200)
  }
)

(define-map project-credits
  { project-id: uint }
  {
    total-issued: uint,
    total-retired: uint,
    available: uint
  }
)

(define-map owner-balances
  { owner: principal }
  {
    total-owned: uint,
    total-retired: uint
  }
)

;; Authorization Functions
(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT_OWNER)
)

(define-private (is-project-developer (project-id uint))
  (match (map-get? carbon-projects { project-id: project-id })
    project-data (is-eq tx-sender (get developer project-data))
    false
  )
)

(define-private (is-credit-owner (credit-id uint))
  (match (map-get? carbon-credits { credit-id: credit-id })
    credit-data (is-eq tx-sender (get owner credit-data))
    false
  )
)

;; Public Functions

;; Register a new carbon project
(define-public (register-project (name (string-ascii 100)) (project-type (string-ascii 50)) (location (string-ascii 100)) (standard (string-ascii 20)))
  (let ((project-id (var-get next-project-id)))
    (asserts! (> (len name) u0) ERR_INVALID_PROJECT)
    (map-set carbon-projects
      { project-id: project-id }
      {
        name: name,
        developer: tx-sender,
        project-type: project-type,
        location: location,
        standard: standard,
        registered-at: block-height,
        verified: false,
        verifier: none
      }
    )
    (map-set project-credits
      { project-id: project-id }
      {
        total-issued: u0,
        total-retired: u0,
        available: u0
      }
    )
    (var-set next-project-id (+ project-id u1))
    (ok project-id)
  )
)

;; Verify a carbon project (only contract owner)
(define-public (verify-project (project-id uint))
  (match (map-get? carbon-projects { project-id: project-id })
    project-data
    (begin
      (asserts! (is-contract-owner) ERR_UNAUTHORIZED)
      (map-set carbon-projects
        { project-id: project-id }
        (merge project-data { verified: true, verifier: (some tx-sender) })
      )
      (ok true)
    )
    ERR_INVALID_PROJECT
  )
)

;; Issue carbon credits for a verified project
(define-public (issue-credits (project-id uint) (amount uint) (vintage uint) (metadata (string-ascii 200)))
  (let (
    (credit-id (var-get next-credit-id))
    (project-data (unwrap! (map-get? carbon-projects { project-id: project-id }) ERR_INVALID_PROJECT))
    (current-project-credits (default-to { total-issued: u0, total-retired: u0, available: u0 }
                                        (map-get? project-credits { project-id: project-id })))
    (current-balance (default-to { total-owned: u0, total-retired: u0 }
                                (map-get? owner-balances { owner: tx-sender })))
  )
    (asserts! (get verified project-data) ERR_UNAUTHORIZED)
    (asserts! (is-project-developer project-id) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)

    ;; Create the credit
    (map-set carbon-credits
      { credit-id: credit-id }
      {
        project-id: project-id,
        owner: tx-sender,
        amount: amount,
        vintage: vintage,
        issued-at: block-height,
        retired: false,
        retired-at: none,
        metadata: metadata
      }
    )

    ;; Update project credits
    (map-set project-credits
      { project-id: project-id }
      {
        total-issued: (+ (get total-issued current-project-credits) amount),
        total-retired: (get total-retired current-project-credits),
        available: (+ (get available current-project-credits) amount)
      }
    )

    ;; Update owner balance
    (map-set owner-balances
      { owner: tx-sender }
      {
        total-owned: (+ (get total-owned current-balance) amount),
        total-retired: (get total-retired current-balance)
      }
    )

    (var-set next-credit-id (+ credit-id u1))
    (var-set total-credits-issued (+ (var-get total-credits-issued) amount))
    (ok credit-id)
  )
)

;; Transfer credit ownership
(define-public (transfer-credit (credit-id uint) (new-owner principal))
  (let (
    (credit-data (unwrap! (map-get? carbon-credits { credit-id: credit-id }) ERR_INVALID_PROJECT))
    (current-owner-balance (default-to { total-owned: u0, total-retired: u0 }
                                      (map-get? owner-balances { owner: tx-sender })))
    (new-owner-balance (default-to { total-owned: u0, total-retired: u0 }
                                  (map-get? owner-balances { owner: new-owner })))
  )
    (asserts! (is-credit-owner credit-id) ERR_UNAUTHORIZED)
    (asserts! (not (get retired credit-data)) ERR_INSUFFICIENT_CREDITS)

    ;; Update credit ownership
    (map-set carbon-credits
      { credit-id: credit-id }
      (merge credit-data { owner: new-owner })
    )

    ;; Update current owner balance
    (map-set owner-balances
      { owner: tx-sender }
      {
        total-owned: (- (get total-owned current-owner-balance) (get amount credit-data)),
        total-retired: (get total-retired current-owner-balance)
      }
    )

    ;; Update new owner balance
    (map-set owner-balances
      { owner: new-owner }
      {
        total-owned: (+ (get total-owned new-owner-balance) (get amount credit-data)),
        total-retired: (get total-retired new-owner-balance)
      }
    )

    (ok true)
  )
)

;; Retire carbon credits
(define-public (retire-credit (credit-id uint))
  (let (
    (credit-data (unwrap! (map-get? carbon-credits { credit-id: credit-id }) ERR_INVALID_PROJECT))
    (current-project-credits (unwrap! (map-get? project-credits { project-id: (get project-id credit-data) }) ERR_INVALID_PROJECT))
    (current-balance (default-to { total-owned: u0, total-retired: u0 }
                                (map-get? owner-balances { owner: tx-sender })))
  )
    (asserts! (is-credit-owner credit-id) ERR_UNAUTHORIZED)
    (asserts! (not (get retired credit-data)) ERR_INSUFFICIENT_CREDITS)

    ;; Retire the credit
    (map-set carbon-credits
      { credit-id: credit-id }
      (merge credit-data { retired: true, retired-at: (some block-height) })
    )

    ;; Update project credits
    (map-set project-credits
      { project-id: (get project-id credit-data) }
      {
        total-issued: (get total-issued current-project-credits),
        total-retired: (+ (get total-retired current-project-credits) (get amount credit-data)),
        available: (- (get available current-project-credits) (get amount credit-data))
      }
    )

    ;; Update owner balance
    (map-set owner-balances
      { owner: tx-sender }
      {
        total-owned: (- (get total-owned current-balance) (get amount credit-data)),
        total-retired: (+ (get total-retired current-balance) (get amount credit-data))
      }
    )

    (ok true)
  )
)

;; Read-only Functions

;; Get project information
(define-read-only (get-project (project-id uint))
  (map-get? carbon-projects { project-id: project-id })
)

;; Get credit information
(define-read-only (get-credit (credit-id uint))
  (map-get? carbon-credits { credit-id: credit-id })
)

;; Get project credit statistics
(define-read-only (get-project-credits (project-id uint))
  (map-get? project-credits { project-id: project-id })
)

;; Get owner balance
(define-read-only (get-owner-balance (owner principal))
  (map-get? owner-balances { owner: owner })
)

;; Get total credits issued
(define-read-only (get-total-credits-issued)
  (var-get total-credits-issued)
)

;; Get next project ID
(define-read-only (get-next-project-id)
  (var-get next-project-id)
)

;; Get next credit ID
(define-read-only (get-next-credit-id)
  (var-get next-credit-id)
)
