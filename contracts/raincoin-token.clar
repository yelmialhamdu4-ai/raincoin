;; RainCoin Token Contract
;; SIP-010 compliant fungible token for tokenized rainwater harvesting credits
;; Enables transparent, incentivized water conservation through blockchain technology

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_OWNER_ONLY (err u100))
(define-constant ERR_NOT_TOKEN_OWNER (err u101))
(define-constant ERR_INSUFFICIENT_BALANCE (err u102))
(define-constant ERR_INVALID_AMOUNT (err u103))
(define-constant ERR_CONTRACT_PAUSED (err u104))
(define-constant ERR_UNAUTHORIZED_MINTER (err u105))
(define-constant ERR_UNAUTHORIZED_BURNER (err u106))
(define-constant ERR_INVALID_PRINCIPAL (err u107))
(define-constant ERR_TRANSFER_FAILED (err u108))
(define-constant ERR_MINT_FAILED (err u109))
(define-constant ERR_BURN_FAILED (err u110))

;; Token Properties
(define-constant TOKEN_NAME "RainCoin")
(define-constant TOKEN_SYMBOL "RAIN")
(define-constant TOKEN_DECIMALS u6)
(define-constant TOKEN_MAX_SUPPLY u100000000000000) ;; 100M tokens with 6 decimals
(define-constant INITIAL_SUPPLY u50000000000000) ;; 50M tokens initially

;; Data Variables
(define-data-var total-supply uint u0)
(define-data-var contract-paused bool false)
(define-data-var token-uri (optional (string-utf8 256)) none)

;; Data Maps
(define-map token-balances principal uint)
(define-map token-allowances {owner: principal, spender: principal} uint)
(define-map authorized-minters principal bool)
(define-map authorized-burners principal bool)
(define-map user-nonces principal uint)
(define-map freeze-status principal bool)

;; Initialize contract with initial supply to owner
(map-set token-balances CONTRACT_OWNER INITIAL_SUPPLY)
(var-set total-supply INITIAL_SUPPLY)
(map-set authorized-minters CONTRACT_OWNER true)
(map-set authorized-burners CONTRACT_OWNER true)

;; SIP-010 Standard Functions

;; Transfer tokens between accounts
(define-public (transfer (amount uint) (from principal) (to principal) (memo (optional (buff 34))))
  (begin
    (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (is-eq from tx-sender) ERR_NOT_TOKEN_OWNER)
    (asserts! (not (default-to false (map-get? freeze-status from))) ERR_NOT_TOKEN_OWNER)
    (asserts! (not (default-to false (map-get? freeze-status to))) ERR_INVALID_PRINCIPAL)
    (asserts! (>= (get-balance from) amount) ERR_INSUFFICIENT_BALANCE)
    
    (try! (ft-transfer? raincoin-token amount from to))
    
    (print {type: "transfer", amount: amount, from: from, to: to})
    
    (ok true)
  )
)

;; Get token name
(define-read-only (get-name)
  (ok TOKEN_NAME)
)

;; Get token symbol
(define-read-only (get-symbol)
  (ok TOKEN_SYMBOL)
)

;; Get token decimals
(define-read-only (get-decimals)
  (ok TOKEN_DECIMALS)
)

;; Get balance of an account
(define-read-only (get-balance (who principal))
  (default-to u0 (map-get? token-balances who))
)

;; Get total supply
(define-read-only (get-total-supply)
  (ok (var-get total-supply))
)

;; Get token URI
(define-read-only (get-token-uri)
  (ok (var-get token-uri))
)

;; Administrative Functions

;; Set token URI (owner only)
(define-public (set-token-uri (value (string-utf8 256)))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
    (var-set token-uri (some value))
    (print {type: "token-uri-updated", uri: value})
    (ok true)
  )
)

;; Pause/unpause contract (owner only)
(define-public (set-pause-status (paused bool))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
    (var-set contract-paused paused)
    (print {type: "pause-status-changed", paused: paused})
    (ok true)
  )
)

;; Add authorized minter (owner only)
(define-public (add-minter (minter principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
    (map-set authorized-minters minter true)
    (print {type: "minter-added", minter: minter})
    (ok true)
  )
)

;; Remove authorized minter (owner only)
(define-public (remove-minter (minter principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
    (map-delete authorized-minters minter)
    (print {type: "minter-removed", minter: minter})
    (ok true)
  )
)

;; Add authorized burner (owner only)
(define-public (add-burner (burner principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
    (map-set authorized-burners burner true)
    (print {type: "burner-added", burner: burner})
    (ok true)
  )
)

;; Remove authorized burner (owner only)
(define-public (remove-burner (burner principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
    (map-delete authorized-burners burner)
    (print {type: "burner-removed", burner: burner})
    (ok true)
  )
)

;; Freeze/unfreeze account (owner only)
(define-public (set-freeze-status (account principal) (frozen bool))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
    (map-set freeze-status account frozen)
    (print {type: "freeze-status-changed", account: account, frozen: frozen})
    (ok true)
  )
)

;; Minting Functions

;; Mint tokens (authorized minters only)
(define-public (mint (amount uint) (recipient principal))
  (begin
    (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (default-to false (map-get? authorized-minters tx-sender)) ERR_UNAUTHORIZED_MINTER)
    (asserts! (<= (+ (var-get total-supply) amount) TOKEN_MAX_SUPPLY) ERR_MINT_FAILED)
    
    (try! (ft-mint? raincoin-token amount recipient))
    (var-set total-supply (+ (var-get total-supply) amount))
    
    (print {type: "tokens-minted", amount: amount, recipient: recipient, minter: tx-sender})
    (ok amount)
  )
)

;; Burn tokens (authorized burners only)
(define-public (burn (amount uint) (owner principal))
  (begin
    (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (default-to false (map-get? authorized-burners tx-sender)) ERR_UNAUTHORIZED_BURNER)
    (asserts! (>= (get-balance owner) amount) ERR_INSUFFICIENT_BALANCE)
    
    (try! (ft-burn? raincoin-token amount owner))
    (var-set total-supply (- (var-get total-supply) amount))
    
    (print {type: "tokens-burned", amount: amount, owner: owner, burner: tx-sender})
    (ok amount)
  )
)

;; Read-only Functions

;; Check if account is frozen
(define-read-only (is-frozen (account principal))
  (default-to false (map-get? freeze-status account))
)

;; Check if principal is authorized minter
(define-read-only (is-minter (principal principal))
  (default-to false (map-get? authorized-minters principal))
)

;; Check if principal is authorized burner
(define-read-only (is-burner (principal principal))
  (default-to false (map-get? authorized-burners principal))
)

;; Get contract pause status
(define-read-only (is-paused)
  (var-get contract-paused)
)

;; Get maximum supply
(define-read-only (get-max-supply)
  TOKEN_MAX_SUPPLY
)

;; Get contract owner
(define-read-only (get-contract-owner)
  CONTRACT_OWNER
)

;; Get user nonce for potential future signature verification
(define-read-only (get-user-nonce (user principal))
  (default-to u0 (map-get? user-nonces user))
)

;; Token Definition
(define-fungible-token raincoin-token)

;; title: raincoin-token
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

