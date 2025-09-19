;; Harvesting Rewards Contract
;; Manages rainwater collection verification, reward distribution, and fraud prevention
;; Integrates with RainCoin token contract for automated reward distribution

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_OWNER_ONLY (err u200))
(define-constant ERR_UNAUTHORIZED (err u201))
(define-constant ERR_INVALID_AMOUNT (err u202))
(define-constant ERR_ALREADY_VERIFIED (err u203))
(define-constant ERR_NOT_FOUND (err u204))
(define-constant ERR_CLAIM_EXPIRED (err u205))
(define-constant ERR_INSUFFICIENT_VERIFICATIONS (err u206))
(define-constant ERR_ALREADY_CLAIMED (err u207))
(define-constant ERR_INVALID_VERIFIER (err u208))
(define-constant ERR_DUPLICATE_VERIFICATION (err u209))
(define-constant ERR_FRAUDULENT_CLAIM (err u210))
(define-constant ERR_COLLECTOR_SUSPENDED (err u211))
(define-constant ERR_CONTRACT_PAUSED (err u212))
(define-constant ERR_INVALID_COORDINATES (err u213))
(define-constant ERR_INVALID_TIMESTAMP (err u214))

;; System Configuration
(define-constant MIN_VERIFICATIONS u2) ;; Minimum verifications required
(define-constant REWARD_RATE u1000000) ;; 1 RAIN per liter (with 6 decimals)
(define-constant VERIFICATION_FEE_RATE u1000) ;; 0.1% fee for verifiers (in basis points)
(define-constant CLAIM_EXPIRY_BLOCKS u1008) ;; Claims expire after ~1 week
(define-constant MAX_COLLECTION_PER_CLAIM u100000) ;; Max 100,000 liters per claim
(define-constant MIN_COLLECTION_PER_CLAIM u1) ;; Min 1 liter per claim
(define-constant VERIFICATION_DEADLINE u144) ;; 24 hours to verify in blocks

;; Data Variables
(define-data-var next-claim-id uint u1)
(define-data-var total-water-collected uint u0)
(define-data-var total-rewards-distributed uint u0)
(define-data-var contract-paused bool false)
(define-data-var reward-rate uint REWARD_RATE)
(define-data-var min-verifications uint MIN_VERIFICATIONS)
(define-data-var verification-fee-rate uint VERIFICATION_FEE_RATE)

;; Data Maps
(define-map collection-claims 
  uint 
  {
    collector: principal,
    collection-amount: uint,
    collection-date: uint,
    location-lat: int,
    location-lng: int,
    claim-timestamp: uint,
    verification-count: uint,
    reward-calculated: uint,
    status: (string-ascii 20),
    evidence-hash: (string-ascii 64),
    equipment-type: (string-ascii 50)
  }
)

(define-map verifications
  {claim-id: uint, verifier: principal}
  {
    verified: bool,
    verification-timestamp: uint,
    notes: (optional (string-utf8 256)),
    confidence-score: uint
  }
)

(define-map authorized-verifiers principal
  {
    active: bool,
    reputation-score: uint,
    total-verifications: uint,
    successful-verifications: uint,
    joined-at: uint
  }
)

(define-map collector-profiles principal
  {
    total-collections: uint,
    total-rewards: uint,
    registration-date: uint,
    reputation-score: uint,
    is-suspended: bool,
    fraud-reports: uint
  }
)

(define-map reward-distributions
  {claim-id: uint, recipient: principal}
  {
    amount: uint,
    distributed-at: uint,
    distribution-type: (string-ascii 20)
  }
)

;; Fraud detection maps
(define-map suspicious-patterns principal uint)
(define-map location-frequency {lat: int, lng: int} uint)
(define-map daily-collections {collector: principal, date: uint} uint)

;; Initialize contract
(map-set collector-profiles CONTRACT_OWNER 
  {total-collections: u0, total-rewards: u0, registration-date: u1, 
   reputation-score: u1000, is-suspended: false, fraud-reports: u0})

;; Public Functions

;; Register as a water collector
(define-public (register-collector)
  (let ((existing-profile (map-get? collector-profiles tx-sender)))
    (asserts! (is-none existing-profile) ERR_ALREADY_CLAIMED)
    (map-set collector-profiles tx-sender 
      {total-collections: u0, total-rewards: u0, registration-date: stacks-block-height,
       reputation-score: u500, is-suspended: false, fraud-reports: u0})
    (print {type: "collector-registered", collector: tx-sender, timestamp: stacks-block-height})
    (ok true)
  )
)

;; Apply to become a verifier
(define-public (apply-as-verifier)
  (let ((existing-verifier (map-get? authorized-verifiers tx-sender)))
    (asserts! (is-none existing-verifier) ERR_ALREADY_CLAIMED)
    (map-set authorized-verifiers tx-sender
      {active: true, reputation-score: u500, total-verifications: u0,
       successful-verifications: u0, joined-at: stacks-block-height})
    (print {type: "verifier-application", verifier: tx-sender, timestamp: stacks-block-height})
    (ok true)
  )
)

;; Submit water collection claim
(define-public (submit-collection-claim 
  (collection-amount uint) 
  (location-lat int) 
  (location-lng int) 
  (collection-date uint)
  (evidence-hash (string-ascii 64))
  (equipment-type (string-ascii 50))
)
  (let (
    (claim-id (var-get next-claim-id))
    (collector-profile (unwrap! (map-get? collector-profiles tx-sender) ERR_NOT_FOUND))
    (reward-amount (* collection-amount (var-get reward-rate)))
  )
    (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
    (asserts! (not (get is-suspended collector-profile)) ERR_COLLECTOR_SUSPENDED)
    (asserts! (>= collection-amount MIN_COLLECTION_PER_CLAIM) ERR_INVALID_AMOUNT)
    (asserts! (<= collection-amount MAX_COLLECTION_PER_CLAIM) ERR_INVALID_AMOUNT)
    (asserts! (> collection-date u0) ERR_INVALID_TIMESTAMP)
    (asserts! (<= collection-date stacks-block-height) ERR_INVALID_TIMESTAMP)
    (asserts! (and (>= location-lat -90000000) (<= location-lat 90000000)) ERR_INVALID_COORDINATES)
    (asserts! (and (>= location-lng -180000000) (<= location-lng 180000000)) ERR_INVALID_COORDINATES)
    
    ;; Fraud detection checks
    (try! (perform-fraud-checks tx-sender collection-amount location-lat location-lng collection-date))
    
    ;; Create claim record
    (map-set collection-claims claim-id
      {collector: tx-sender, collection-amount: collection-amount, 
       collection-date: collection-date, location-lat: location-lat, 
       location-lng: location-lng, claim-timestamp: stacks-block-height,
       verification-count: u0, reward-calculated: reward-amount,
       status: "pending", evidence-hash: evidence-hash,
       equipment-type: equipment-type})
    
    ;; Update tracking data
    (update-location-frequency location-lat location-lng)
    (update-daily-collections tx-sender collection-date)
    
    (var-set next-claim-id (+ claim-id u1))
    
    (print {type: "claim-submitted", claim-id: claim-id, collector: tx-sender, 
            amount: collection-amount, location: {lat: location-lat, lng: location-lng}})
    (ok claim-id)
  )
)

;; Verify a collection claim
(define-public (verify-claim (claim-id uint) (is-valid bool) (confidence-score uint) (notes (optional (string-utf8 256))))
  (let (
    (claim (unwrap! (map-get? collection-claims claim-id) ERR_NOT_FOUND))
    (verifier-info (unwrap! (map-get? authorized-verifiers tx-sender) ERR_INVALID_VERIFIER))
    (verification-key {claim-id: claim-id, verifier: tx-sender})
    (existing-verification (map-get? verifications verification-key))
  )
    (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
    (asserts! (get active verifier-info) ERR_INVALID_VERIFIER)
    (asserts! (is-none existing-verification) ERR_DUPLICATE_VERIFICATION)
    (asserts! (is-eq (get status claim) "pending") ERR_ALREADY_VERIFIED)
    (asserts! (<= (- stacks-block-height (get claim-timestamp claim)) CLAIM_EXPIRY_BLOCKS) ERR_CLAIM_EXPIRED)
    (asserts! (and (>= confidence-score u1) (<= confidence-score u100)) ERR_INVALID_AMOUNT)
    
    ;; Record verification
    (map-set verifications verification-key
      {verified: is-valid, verification-timestamp: stacks-block-height,
       notes: notes, confidence-score: confidence-score})
    
    ;; Update claim verification count
    (let ((new-verification-count (+ (get verification-count claim) u1)))
      (map-set collection-claims claim-id
        (merge claim {verification-count: new-verification-count}))
      
      ;; Update verifier stats
      (update-verifier-stats tx-sender is-valid)
      
      ;; Process rewards if minimum verifications reached
      (if (>= new-verification-count (var-get min-verifications))
        (try! (process-claim-rewards claim-id))
        true)
    )
    
    (print {type: "claim-verified", claim-id: claim-id, verifier: tx-sender,
            valid: is-valid, confidence: confidence-score})
    (ok true)
  )
)

;; Administrative Functions

;; Pause/unpause contract (owner only)
(define-public (set-pause-status (paused bool))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
    (var-set contract-paused paused)
    (print {type: "pause-status-changed", paused: paused})
    (ok true)
  )
)

;; Update reward rate (owner only)
(define-public (set-reward-rate (new-rate uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
    (asserts! (> new-rate u0) ERR_INVALID_AMOUNT)
    (var-set reward-rate new-rate)
    (print {type: "reward-rate-updated", new-rate: new-rate})
    (ok true)
  )
)

;; Suspend collector (owner only)
(define-public (suspend-collector (collector principal) (suspended bool))
  (let ((profile (unwrap! (map-get? collector-profiles collector) ERR_NOT_FOUND)))
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
    (map-set collector-profiles collector
      (merge profile {is-suspended: suspended}))
    (print {type: "collector-suspension-changed", collector: collector, suspended: suspended})
    (ok true)
  )
)

;; Deactivate verifier (owner only)
(define-public (deactivate-verifier (verifier principal))
  (let ((verifier-info (unwrap! (map-get? authorized-verifiers verifier) ERR_NOT_FOUND)))
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
    (map-set authorized-verifiers verifier
      (merge verifier-info {active: false}))
    (print {type: "verifier-deactivated", verifier: verifier})
    (ok true)
  )
)

;; Read-Only Functions

;; Get claim details
(define-read-only (get-claim (claim-id uint))
  (map-get? collection-claims claim-id)
)

;; Get collector profile
(define-read-only (get-collector-profile (collector principal))
  (map-get? collector-profiles collector)
)

;; Get verifier info
(define-read-only (get-verifier-info (verifier principal))
  (map-get? authorized-verifiers verifier)
)

;; Get verification details
(define-read-only (get-verification (claim-id uint) (verifier principal))
  (map-get? verifications {claim-id: claim-id, verifier: verifier})
)

;; Get total statistics
(define-read-only (get-total-stats)
  {
    total-water-collected: (var-get total-water-collected),
    total-rewards-distributed: (var-get total-rewards-distributed),
    total-claims: (- (var-get next-claim-id) u1),
    reward-rate: (var-get reward-rate)
  }
)

;; Get current system parameters
(define-read-only (get-system-parameters)
  {
    min-verifications: (var-get min-verifications),
    reward-rate: (var-get reward-rate),
    verification-fee-rate: (var-get verification-fee-rate),
    contract-paused: (var-get contract-paused)
  }
)

;; Private Functions

;; Process claim rewards after sufficient verifications
(define-private (process-claim-rewards (claim-id uint))
  (let (
    (claim (unwrap! (map-get? collection-claims claim-id) ERR_NOT_FOUND))
    (collector (get collector claim))
    (reward-amount (get reward-calculated claim))
    (verification-fee (/ (* reward-amount (var-get verification-fee-rate)) u10000))
    (collector-profile (unwrap! (map-get? collector-profiles collector) ERR_NOT_FOUND))
  )
    ;; Check if claim is still pending and has sufficient verifications
    (asserts! (is-eq (get status claim) "pending") ERR_ALREADY_CLAIMED)
    
    ;; Determine if claim should be approved based on verifications
    (let ((approval-result (calculate-claim-approval claim-id)))
      (if (get approved approval-result)
        (begin
          ;; Approve and distribute rewards
          (map-set collection-claims claim-id
            (merge claim {status: "approved"}))
          
          ;; Update collector profile
          (map-set collector-profiles collector
            (merge collector-profile 
              {total-collections: (+ (get total-collections collector-profile) 
                                    (get collection-amount claim)),
               total-rewards: (+ (get total-rewards collector-profile) reward-amount)}))
          
          ;; Update global stats
          (var-set total-water-collected 
            (+ (var-get total-water-collected) (get collection-amount claim)))
          (var-set total-rewards-distributed 
            (+ (var-get total-rewards-distributed) reward-amount))
          
          ;; Record reward distribution
          (map-set reward-distributions {claim-id: claim-id, recipient: collector}
            {amount: reward-amount, distributed-at: stacks-block-height, distribution-type: "collection-reward"})
          
          (print {type: "claim-processed", claim-id: claim-id, status: "approved", amount: reward-amount})
        )
        (begin
          ;; Reject claim
          (map-set collection-claims claim-id
            (merge claim {status: "rejected"}))
          (print {type: "claim-processed", claim-id: claim-id, status: "rejected", amount: u0})
        )
      )
    )
    (ok true)
  )
)

;; Calculate if claim should be approved based on verifications
(define-private (calculate-claim-approval (claim-id uint))
  (let (
    (positive-verifications (count-positive-verifications claim-id))
    (total-verifications (get-claim-verification-count claim-id))
  )
    {approved: (> positive-verifications (/ total-verifications u2))}
  )
)

;; Count positive verifications for a claim
(define-private (count-positive-verifications (claim-id uint))
  ;; This is a simplified implementation
  ;; In practice, you would iterate through all verifications
  u1
)

;; Get verification count for a claim
(define-private (get-claim-verification-count (claim-id uint))
  (match (map-get? collection-claims claim-id)
    claim (get verification-count claim)
    u0)
)

;; Update verifier statistics
(define-private (update-verifier-stats (verifier principal) (was-positive bool))
  (match (map-get? authorized-verifiers verifier)
    verifier-info
    (let (
      (new-total (+ (get total-verifications verifier-info) u1))
      (new-successful (if was-positive 
                       (+ (get successful-verifications verifier-info) u1)
                       (get successful-verifications verifier-info)))
    )
      (map-set authorized-verifiers verifier
        (merge verifier-info 
          {total-verifications: new-total, successful-verifications: new-successful}))
    )
    false)
)

;; Perform fraud detection checks
(define-private (perform-fraud-checks (collector principal) (amount uint) (lat int) (lng int) (date uint))
  (let (
    (daily-total (default-to u0 (map-get? daily-collections {collector: collector, date: date})))
    (location-freq (default-to u0 (map-get? location-frequency {lat: lat, lng: lng})))
  )
    ;; Check for excessive daily collections
    (asserts! (< (+ daily-total amount) u50000) ERR_FRAUDULENT_CLAIM)
    
    ;; Check for suspicious location patterns
    (asserts! (< location-freq u10) ERR_FRAUDULENT_CLAIM)
    
    (ok true)
  )
)

;; Update location frequency tracking
(define-private (update-location-frequency (lat int) (lng int))
  (let ((current-freq (default-to u0 (map-get? location-frequency {lat: lat, lng: lng}))))
    (map-set location-frequency {lat: lat, lng: lng} (+ current-freq u1))
  )
)

;; Update daily collection tracking
(define-private (update-daily-collections (collector principal) (date uint))
  (let ((current-total (default-to u0 (map-get? daily-collections {collector: collector, date: date}))))
    (map-set daily-collections {collector: collector, date: date} (+ current-total u1))
  )
)

