;; Legal Contract Management System
;; Description: Smart contract system for managing legal agreements on Stacks blockchain

;; Error Codes
(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_INVALID_INPUT (err u101))
(define-constant ERR_CONTRACT_NOT_FOUND (err u102))
(define-constant ERR_MAX_SIGNATURES_REACHED (err u103))
(define-constant ERR_INVALID_STATE (err u104))
(define-constant ERR_VERSION_NOT_FOUND (err u105))
(define-constant ERR_EVENT_FAILED (err u106))

;; Constants
(define-constant CONTRACT_ACTIVE u0)
(define-constant CONTRACT_ARCHIVED u1)
(define-constant MAX_SIGNATURES u8)
(define-constant ACCESS_LEVEL_READ u0)
(define-constant ACCESS_LEVEL_WRITE u1)
(define-constant ACCESS_LEVEL_ADMIN u2)
(define-constant INITIAL_VERSION "Initial version")

;; Data Maps
(define-map legal-contracts
    { contract-id: uint }
    {
        title: (string-ascii 256),
        description: (string-ascii 1024),
        status: uint,
        created-by: principal,
        created-at: uint,
        updated-at: uint,
        required-signatures: uint
    }
)

(define-map contract-versions
    { contract-id: uint, version: uint }
    {
        content-hash: (buff 32),
        created-by: principal,
        created-at: uint,
        metadata: (string-ascii 256)
    }
)

(define-map contract-signatures
    { contract-id: uint, signer: principal }
    {
        signed-at: uint,
        signature-hash: (buff 64),
        version: uint
    }
)

(define-map contract-access
    { contract-id: uint, user: principal }
    { access-level: uint }
)

(define-map contract-events
    { contract-id: uint, event-id: uint }
    {
        event-type: (string-ascii 64),
        created-at: uint,
        created-by: principal,
        metadata: (string-ascii 256),
        related-principal: (optional principal),
        related-uint: (optional uint)
    }
)

;; Data Variables
(define-data-var contract-nonce uint u0)
(define-data-var event-nonce uint u0)

;; Check if the caller is an admin for the specified contract
(define-private (is-contract-admin (contract-id uint) (caller principal))
    (match (map-get? contract-access { contract-id: contract-id, user: caller })
        access-data (is-eq (get access-level access-data) ACCESS_LEVEL_ADMIN)
        false
    )
)

;; Increment a nonce value by 1
(define-private (increment-nonce (nonce uint))
    (+ nonce u1)
)

;; Validate that a contract exists for the given contract ID
(define-private (validate-contract-exists (contract-id uint))
    (match (map-get? legal-contracts { contract-id: contract-id })
        contract-data true
        false
    )
)

;; Validate description length (must be greater than 0)
(define-private (validate-description (description (string-ascii 1024)))
    (> (len description) u0)
)

;; Validate that the content hash is exactly 32 bytes
(define-private (validate-content-hash (hash (buff 32)))
    (is-eq (len hash) u32)
)

;; Validate that the signature hash is exactly 64 bytes
(define-private (validate-signature-hash (hash (buff 64)))
    (is-eq (len hash) u64)
)

;; Validate metadata length (must be greater than 0)
(define-private (validate-metadata (metadata (string-ascii 256)))
    (> (len metadata) u0)
)

;; Ensure the provided user principal is neither the transaction sender nor the contract principal
(define-private (validate-user-principal (user principal))
    (and 
        (not (is-eq user tx-sender))  
        (not (is-eq user (as-contract tx-sender)))
    )
)

;; Log contract-related events with metadata and optional associated principals or integers
(define-private (log-contract-event 
    (contract-id uint) 
    (event-type (string-ascii 64)) 
    (metadata (string-ascii 256))
    (related-principal-opt (optional principal))
    (related-uint-opt (optional uint)))
    (begin
        (let ((event-id (var-get event-nonce)))
            (map-set contract-events
                { contract-id: contract-id, event-id: event-id }
                {
                    event-type: event-type,
                    created-at: block-height,
                    created-by: tx-sender,
                    metadata: metadata,
                    related-principal: related-principal-opt,
                    related-uint: related-uint-opt
                }
            )
            (var-set event-nonce (increment-nonce event-id))
            (ok event-id)
        )
    )
)

;; Batch 3: Core Public Functions

;; Create a new legal contract
(define-public (create-contract
    (title (string-ascii 256))
    (description (string-ascii 1024))
    (required-signatures uint)
    (initial-content-hash (buff 32)))
    (let
        ((contract-id (var-get contract-nonce)))
        (begin
            ;; Input validation
            (asserts! (> (len title) u0) ERR_INVALID_INPUT)
            (asserts! (validate-description description) ERR_INVALID_INPUT)
            (asserts! (>= required-signatures u1) ERR_INVALID_INPUT)
            (asserts! (<= required-signatures MAX_SIGNATURES) ERR_INVALID_INPUT)
            (asserts! (validate-content-hash initial-content-hash) ERR_INVALID_INPUT)
            
            ;; Create contract
            (map-set legal-contracts
                { contract-id: contract-id }
                {
                    title: title,
                    description: description,
                    status: CONTRACT_ACTIVE,
                    created-by: tx-sender,
                    created-at: block-height,
                    updated-at: block-height,
                    required-signatures: required-signatures
                }
            )
            
            ;; Set initial version
            (map-set contract-versions
                { contract-id: contract-id, version: u0 }
                {
                    content-hash: initial-content-hash,
                    created-by: tx-sender,
                    created-at: block-height,
                    metadata: INITIAL_VERSION
                }
            )
            
            ;; Grant admin access to creator
            (map-set contract-access
                { contract-id: contract-id, user: tx-sender }
                { access-level: ACCESS_LEVEL_ADMIN }
            )
            
            ;; Log creation event and return contract ID
            (unwrap! (log-contract-event 
                contract-id 
                "contract_created" 
                "Contract created"
                (some tx-sender)
                none)
                ERR_EVENT_FAILED)
            
            (var-set contract-nonce (increment-nonce contract-id))
            (ok contract-id)
        )
    )
)

;; Add a signature to the contract
(define-public (add-signature
    (contract-id uint)
    (signature-hash (buff 64)))
    (let
        ((contract-opt (map-get? legal-contracts { contract-id: contract-id })))
        (begin
            ;; Validate contract exists
            (asserts! (is-some contract-opt) ERR_CONTRACT_NOT_FOUND)
            
            (let ((contract-data (unwrap! contract-opt ERR_CONTRACT_NOT_FOUND))
                  (current-version-opt (get-latest-version contract-id)))
                
                ;; Validate version exists
                (asserts! (is-some current-version-opt) ERR_VERSION_NOT_FOUND)
                (let ((current-version (unwrap! current-version-opt ERR_VERSION_NOT_FOUND)))
                    
                    ;; Validate input
                    (asserts! (validate-signature-hash signature-hash) ERR_INVALID_INPUT)
                    
                    ;; Validate contract is active
                    (asserts! (is-eq (get status contract-data) CONTRACT_ACTIVE) ERR_INVALID_STATE)
                    
                    ;; Check if already signed
                    (asserts! (is-none (map-get? contract-signatures 
                        { contract-id: contract-id, signer: tx-sender })) ERR_INVALID_STATE)
                    
                    ;; Add signature
                    (map-set contract-signatures
                        { contract-id: contract-id, signer: tx-sender }
                        {
                            signed-at: block-height,
                            signature-hash: signature-hash,
                            version: current-version
                        }
                    )
                    
                    ;; Log event
                    (unwrap! (log-contract-event 
                        contract-id 
                        "signature_added" 
                        "Signature added"
                        (some tx-sender)
                        (some current-version))
                        ERR_EVENT_FAILED)
                    
                    (ok true)
                )
            )
        )
    )
)

;; Get details of a specific contract
(define-public (get-contract-details (contract-id uint))
    (match (map-get? legal-contracts { contract-id: contract-id })
        contract-data (ok contract-data)
        ERR_CONTRACT_NOT_FOUND
    )
)
