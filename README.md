# Vangki | Decentralized P2P Lending Platform (Phase 1)

## Technical Project Details for Developers

Vangki is a decentralized peer-to-peer (P2P) lending platform built on Ethereum, and Layer 2 networks Polygon and Arbitrum. It facilitates lending and borrowing of ERC-20 tokens and rentable ERC-721/1155 NFTs, using any ERC-20 or NFT assets as collateral. The platform mints NFTs to represent offers and loans, ensuring transparency and traceability. This document outlines the technical architecture, smart contract interactions, and operational examples for Phase 1.

## 1. Supported Assets and Networks (Phase 1)

### Lending and Collateral Assets

**Lending Assets:**

- **ERC-20 Tokens:** Any ERC-20 token (e.g., USDC, ETH, WBTC) on Ethereum, Polygon, or Arbitrum.
- **Rentable ERC-721/1155 NFTs:** Unique NFTs that are ERC-4907 compliant (like NFTs from Warena and Axie Infinity) which can be rented (NFTs in which `setUser` and `userOf` functions can be called) with lender-specified daily rental charges.
  - For ERC-721 tokens, the token remains with the owner (lender) during the rental period. The lender only needs to provide approval to the Vangki Escrow contract to act as an operator for renting the token.
  - For ERC-1155 tokens, the tokens will be held in the Vangki Escrow contract during the rental period. This is because ERC-1155 allows for multiple tokens of the same `tokenId`, and escrowing ensures tokens can be tracked effectively.

**Collateral Assets:**

- Any ERC-20 tokens or ERC-721/1155 NFTs for ERC-20 Lending.
- Only ERC-20 tokens for NFT Lending/Renting.

**Supported Networks (Phase 1):**

- Ethereum Mainnet
- Polygon Network
- Arbitrum Network

_Note: For Phase 1, all lending, borrowing, and collateralization activities for a specific loan must occur on a single network (e.g., a loan initiated on Polygon must have its collateral and repayment on Polygon)._

### Asset Viability, Oracles, and Liquidity Determination

The platform distinguishes between liquid and illiquid assets, which affects how defaults and LTV calculations are handled.

- **Liquid Asset Criteria:** An ERC-20 token is considered "Liquid" if:
  1.  It has an active and reliable Chainlink Price Feed on the respective network.
  2.  It has a corresponding liquidity pool on a recognized Decentralized Exchange (DEX) on the respective network (e.g., Uniswap, Curve, Sushiswap) with 24 hour trading volume more than $1M.
- **Illiquid Assets:**
  - All ERC-721 and ERC-721 NFTs are considered "Illiquid" by the platform for valuation and LTV purposes. Their platform-assessed value is $0.
  - ERC-20 tokens that do not meet both criteria for a Liquid Asset are considered "Illiquid".
- **NFT Valuation for Collateral (Lender's Discretion):**
  - The Vangki platform does not perform any valuation for NFT collateral due to their volatile and auction-driven nature. For LTV calculations and systematic risk assessment, NFTs used as collateral are assigned a value of zero.
  - Lenders can still specify an NFT as required collateral. The decision to accept such terms rests entirely with the borrower.
- **Oracle Usage:**
  - **Chainlink Price Feeds:** Used to provide real-time pricing for Liquid ERC-20 assets. This is crucial for LTV calculations and liquidation processes for loans with Liquid collateral.
- **Liquidity Determination Process & On-Chain Record:**
  1.  **Frontend Assessment:** The frontend interface will attempt to assess asset liquidity by checking for Chainlink feeds and querying DEX APIs (e.g., Uniswap, Curve) or general crypto data APIs (e.g., CoinGecko) for 24-hour trading volume data (aiming for >$1M as an indicator, though the primary on-chain check is binding).
  2.  **User Acceptance (Frontend - Illiquid):** If the frontend flags an asset as potentially illiquid, or if the asset is an NFT, the user (lender creating the offer or borrower providing collateral) will be presented with terms stating that the asset will be treated as illiquid (i.e., full collateral transfer on default, no LTV-based liquidation). The user must accept these terms. This acceptance is recorded.
  3.  **On-Chain Verification (Smart Contract):**
      - When an offer involving an ERC-20 asset (as a lending asset or collateral) is being created or accepted, and the frontend has _not_ marked it as illiquid, the smart contract will perform an on-chain check.
      - This check verifies the existence of a valid Chainlink price feed for the asset AND the presence of a recognized DEX liquidity pool for that asset on the current network.
      - **On-Chain Precedence:** If the on-chain check determines the asset is illiquid (e.g., missing price feed or DEX pool), this on-chain determination overrides any prior assessment by the frontend. The user will then be required to accept the terms for illiquid assets (full collateral transfer on default).
  4.  **Explicit Storage:** For every loan, the liquidity status (Liquid or Illiquid, based on the on-chain verification and user acceptance flow) of the lending asset and collateral asset is explicitly stored in the loan's on-chain data.
  5.  **API Unavailability:** If external APIs required by the frontend for initial assessment are unavailable, or if on-chain checks face temporary issues in accessing necessary validation data (e.g., registry lookups for Chainlink), the asset will default to being treated as "Illiquid" to ensure safety. In such cases, full collateral transfer terms on default will apply, and the user must consent. No manual overrides are permitted to classify an asset as liquid if checks fail or indicate illiquidity.
- **Handling of Illiquid Assets on Default:**
  - **ERC-20 Lending with Illiquid Collateral:** If the borrower defaults, the entire illiquid ERC-20 collateral is transferred to the lender. There is no auction or DEX-based liquidation process for these assets.
  - **NFT Lending/Renting:** If the borrower defaults (e.g., fails to close the rental, before expiry), then prepaid (total rental fees + 5% buffer) ERC-20 collateral provided by the borrower is transferred to the NFT owner (lender). The original NFT (if held in escrow, like ERC-1155s) is returned to the owner and the full buffer (5% extra) will be sent to treasury.
- **Frontend Warnings for Illiquid Assets:**
  - A clear, static warning message will be displayed in the frontend whenever a user selects or provides an asset that is determined to be illiquid (either by frontend assessment, because it's an NFT, or by on-chain verification). This warning will explicitly state that in case of default, the entire collateral will be transferred to the lender without a traditional liquidation process.
- **Prepayment for NFT Renting:**
  - For NFT renting, the borrower must lock ERC-20 tokens as collateral. This collateral will cover the total rental amount plus a 5% buffer. This entire amount is considered a prepayment. The 5% buffer is refunded to the borrower upon successful and timely rental closure of the NFT and payment of all rental fees.

## 2. Loan Durations and Flexibility

### Loan Terms

- **Durations:** Configurable from 1 day to 1 year.
- **Grace Periods:** Automatically and strictly assigned based on loan duration:
  - < 1 week: 1 hour
  - < 1 month: 1 day
  - < 3 months: 3 days
  - < 6 months: 1 week
  - \le 1 year: 2 weeks

## 3. Offer Creation

### Lenders:

- **For ERC-20 Tokens:**
  - Specify the lending asset (e.g., 1000 USDC), loan amount, interest rate (e.g., 5% APR), required collateral type (e.g., WETH) and amount (or maximum LTV or minimum Health Factor requirement if collateral is Liquid), and loan duration.
    - LTV = Borrowed Value / Collateral Value
    - Helath Factor = Collateral Value / Borrowed Value
  - Deposit the lending asset into the Vangki smart contract when creating the offer.
- **For Rentable NFTs (ERC-721/1155):**
  - Specify the NFT (e.g., Axie #1234), daily rental fee (e.g., 10 USDC/day), the ERC-20 token for rental payment and collateral (e.g., USDC), and rental duration (e.g., 7 days).
  - For ERC-1155 NFTs: Deposit the NFT into the Vangki Escrow contract when creating the offer.
  - For ERC-721 NFTs: Grant operator approval to the Vangki Escrow contract for the specific NFT. The NFT remains in the lender's wallet.

### Borrowers:

- **For ERC-20 Tokens:**
  - Specify the desired ERC-20 asset and amount, maximum acceptable interest rate, offered collateral (type and amount), and loan duration.
  - Lock the collateral in the Vangki smart contract upon offer submission.
- **For Rentable NFTs (ERC-721/1155):**
  - Specify the desired NFT (or type of NFT), maximum acceptable daily rental charge, the ERC-20 token to be used for prepayment (rental fees + 5% buffer), and rental duration.
  - Lock the prepayment (total rental fee + 5% buffer) in ERC-20 tokens in the Vangki smart contract upon offer submission. Rental payments will be deducted from this prepayment.

### Process:

- Offers are created through a React-based web interface.
- All offer details are recorded on-chain for transparency and immutability.

### NFT Minting for Offers

Vangki mints unique NFTs to represent offers, enhancing traceability and user ownership of their financial positions.

**NFT Metadata:**

- **On-Chain Data:** Key offer details are stored directly on-chain as part of the NFT's metadata. This includes asset types, amounts, rates, duration, and status (e.g., "Offer Created," "Offer Cancelled," "Offer Matched"). The status is updated by authorized smart contract roles (e.g., `VangkiOfferManagement.sol`) as the offer progresses.
- **`tokenURI()` Implementation:** The platform's NFT contract will implement a `tokenURI()` function that dynamically generates a JSON string containing all relevant loan information. This JSON can be consumed by third-party applications like OpenSea and other NFT marketplaces to display offer details.
- **Off-Chain Image Storage (IPFS):** Four distinct images representing different states/roles will be stored in IPFS:
  - `LenderActive.png`
  - `LenderClosed.png`
  - `BorrowerActive.png`
  - `BorrowerClosed.png`
    - The dynamically generated `tokenURI()` will point to the appropriate IPFS image URL based on who created the offer (Lender of Borrower) and its current status.
- **Metadata Updates:** The NFT metadata (specifically the status and potentially the image URL pointer) is updated by authorized smart contract roles (e.g., `VangkiOfferManagement.sol`) when an offer or loan state changes (e.g., accepted, cancelled).

### Example:

**Lender Offer (ERC-20):**

- Alice offers 1000 USDC at 5% interest for 30 days, requiring $1500 (150% Health Factor) worth of ETH as collateral (assuming ETH is liquid).
- Platform locks Alice's 1000 USDC from her wallet into the offer contract.
- Platform mints an "Vangki NFT" for Alice, detailing her offer terms and status as "Offer Created" and with role as "Lender"

**Borrower Offer (NFT Renting):**

- Bob wants to rent a specific CryptoPunk for 7 days and is willing to pay up to 15 USDC/day. He offers USDC as prepayment.
- Bob locks (7 days \* 15 USDC/day) + 5% buffer = 105 USDC + 5.25 USDC = 110.25 USDC into the offer contract.
- Platform mints an "Vangki NFT" for Bob, detailing his request and status "Offer Created" with "Borrower" role.

### Frontend Warnings (Reiteration)

- **Full Collateral Transfer for Illiquid Assets:** Users are explicitly warned that if they use or accept illiquid assets/collateral, default by the borrower will result in the full transfer of that collateral to the lender, without any LTV-based liquidation auction.
- **Full Collateral Transfer for Liquid Asset during Abnormal Periods:** When liquid assets are not able to liquidated due to any of the following conditions, then borrower's full collateral will be transferred to Lender
  - any market condition (too volatile or heavy crash)
  - any unavailability of liquid assets in the DEX pool
  - any technical issues in liquidating the assets
- **Collateral for NFT Renting:** The collateral for NFT renting is a prepayment of total rental fees + a 5% buffer, denominated in ERC-20 tokens.

## 4. Offer Book Display

### Frontend Implementation

- **Tabs:** Separate views for ERC-20 loan offers and NFT rental offers.
- **Sorting:**
  - ERC-20 offers: Sortable by interest rate (lowest for borrowers, highest for lenders), amount, duration.
  - NFT rental offers: Sortable by daily rental rate (lowest for renters, highest for owners), duration.
- **Guidance:** Display data from the last accepted offer with similar parameters (e.g., asset type, duration) to provide users with an indication of current market rates on Vangki.
- **Filters:** Users can filter offers by asset type, collateral requirements (if applicable), loan/rental duration, and amount.
- **Auto-Matching (Suggestion Engine):** The frontend can suggest potentially compatible offers to users based on their currently defined preferences or draft offers.

## 5. Loan Initiation

### Initiation:

- A borrower accepts a lender’s offer, or a lender accepts a borrower’s offer, via the Vangki interface.
- The accepting party pays the network gas fee for the transaction that initiates the loan.

### Smart Contract Actions:

- **Collateral Locking:**
  - For ERC-20 Loans: The borrower’s collateral is locked in an escrow contract.
  - For NFT Renting: The borrower’s prepayment (total rental fees + 5% buffer in ERC-20 tokens) is confirmed as locked.
- **Asset Transfer/NFT User Assignment:**
  - For ERC-20 Loans: The principal loan amount is transferred from the lender or lender's locked funds (in the Escrow) to the borrower.
  - For NFT Renting:
    - For ERC-721: The Vangki Escrow contract, having been approved by the lender, calls `setUser` on the NFT contract to assign the borrower as the 'user' of the NFT for the agreed rental duration. The NFT itself remains in the lender's wallet.
    - For ERC-1155: The NFT is already in the Vangki Escrow contract. The Escrow contract calls `setUser` on the NFT contract to assign the borrower as the 'user' of the specified quantity of tokens for the agreed rental duration.
- **Record Keeping:** All loan details (principal, interest rate/rental fee, duration, collateral details, parties involved, start/end dates, liquidity status of assets) are recorded on-chain.
- **NFT Updates & Minting:**
  - The original "Vangki NFT" (of the party who have created the offer and whose offer was accepted) is updated to "Loan Initiated" status.
  - A new "Vangki NFT" is minted for the offer acceptor, with "Loan Initiated" status.
  - "Vangki NFT" will have respective roles of the users (either as lender or borrower) with it.

### Example:

**ERC-20 Loan Initiation:**

- Bob (Borrower) accepts Alice's (Lender) offer for 1000 USDC.
- Bob locks his required ETH collateral. Gas fees for this acceptance transaction are paid by Bob.
- 1000 USDC is transferred to Bob.
- Alice's "Vangki NFT" status (with lender role) is updated as "Loan Initiated".
- A new "Vangki NFT" is minted for Bob (status: "Loan Initiated" and role: "Borrower").

## 6. Loan Closure & Repayment

### Repayment Logic

**ERC-20 Lending:**

- Borrower repays: `Principal + Interest`.
- Interest Formula: `Interest = (Principal * AnnualInterestRate * LoanDurationInDays) / (100 * 365)`. (Note: Using 100 for rate, ensure consistent precision, e.g., rate stored as basis points).
- Late fees apply if repayment occurs after the due date but within the grace period, or if repayment is forced post-grace period.

**NFT Lending (Renting):**

- Borrower's Obligation: Ensure the NFT can be 'returned' (user status revoked by the platform) and all rental fees are paid.
- Rental Fee Payment: Rental fees are automatically deducted from the borrower's initial prepayment.
- If borrower closes rental term for NFT on time:
  - The Vangki Escrow contract revokes the borrower's 'user' status for the NFT.
  - The 5% buffer from the prepayment is returned to the borrower.
  - The accumulated rental fees (minus treasury fee) are made available for the lender to claim.
- Late fees apply if the NFT 'rental closure' (user status revocation) is delayed beyond the agreed duration.

### Late Fees

- A late fee of 1% of the outstanding principal (for ERC-20 loans) or overdue rental amount (for NFT renting) is applied on the first day after the due date.
- The late fee increases by an additional 0.5% daily.
- The total late fee is capped at 5% of the outstanding principal or total rental amount.
- Late fees are collected along with the repayment and are subject to treasury fees.

### Treasury Fees

- The Vangki platform treasury collects a fee of 1% of any interest earned by lenders or rental fees earned by NFT owners.
- The treasury also collects late fees paid.
- These fees are automatically deducted by the smart contract before funds are made available to the lender/NFT owner.

### Claiming Funds/Assets

- **Lender/NFT Owner:** To claim their principal + interest (for ERC-20 loans) or rental fees (for NFT renting), the lender/NFT owner must interact with the platform and present their "Vangki NFT" to prove ownership and authorize the withdrawal of funds due to them.
- **Borrower:** To claim back their collateral (for ERC-20 loans, after full repayment) or their prepayment buffer (for NFT renting, after proper return and fee settlement), or after liquidation (if any remaining asset after covering total repayment and fees) the borrower must interact with the platform and present their "Vangki NFT" to claim thier funds.

### NFT Status Updates on Closure

- Upon successful repayment and claiming of all assets/funds by respective parties, the status of the relevant Vangki NFTs (both lender's and borrower's) is updated to "Loan Closed" and burned (after claiming all funds). The Loan status is updated to "Loan Repaid."

### Example: ERC-20 Repayment

- Bob (Borrower) took a 30-day loan of 1000 USDC from Alice (Lender) at 5% APR.
- Interest due: `(1000 * 5 * 30) / (100 * 365) = 4.11 USDC` (approx).
- Bob repays 1004.11 USDC.
- Treasury fee: `1% of 4.11 USDC = 0.0411 USDC`.
- Alice, upon presenting her Vangki NFT, can claim `1000 (principal) + 4.11 (interest) - 0.0411 (treasury fee) = 1004.0689 USDC`.
- Bob's ETH collateral is released to him upon presenting his Vangki NFT.
- Both Alice's and Bob's Vangki NFTs are updated to "Loan Closed" and burned.

## 7. Liquidation and Default

### Triggers

**ERC-20 Lending with Liquid Collateral:**

- **LTV Breach:** If the Loan-to-Value (LTV) ratio exceeds a critical threshold (e.g., 90%), based on Chainlink price feeds for both the borrowed asset and the collateral.
- **Non-Repayment Post Grace Period:** If the borrower fails to repay the loan (principal + interest + any late fees) by the end of the grace period.

**ERC-20 Lending with Illiquid Collateral:**

- **Non-Repayment Post Grace Period:** If the borrower fails to repay the loan by the end of the grace period. LTV is not applicable as illiquid collateral has a platform-assessed value of $0 for this purpose.

**NFT Lending (Renting):**

- **Non-Return/Fee Default Post Grace Period:** If the borrower fails to 'close the rental' of the NFT (allow user status to be properly revoked) and settle all rental fees by the end of the grace period.

### Processes

**ERC-20 Lending with Liquid Collateral:**

- **Liquidation:** The borrower's collateral is liquidated (e.g., sold on a DEX via integration like 1inch, Balancer et.,) to recover the outstanding loan amount (principal + accrued interest + late fees + liquidation penalty/fee).
- **Proceeds Distribution:**
  - Lender is repaid.
  - Treasury fees are collected.
  - Any excess funds remaining after covering all obligations are returned to the borrower.
  - If proceeds are insufficient to cover the lender's due amount, the lender bears that loss (unless specific undercollateralized loan insurance is a future feature).

**ERC-20 Lending with Illiquid Collateral:**

- **Full Collateral Transfer:** Upon default (non-repayment after grace period), the _entire_ illiquid ERC-20 collateral is transferred to the lender. No LTV calculations or liquidation auctions occur.

**NFT Lending (Renting) Default:**

- **Collateral Forfeiture:** The borrower’s full ERC-20 prepayment (which includes total rental fees + 5% buffer) is transferred to the NFT owner (lender), after deducting applicable treasury fees from the rental portion.
- **NFT Return:**
  - For ERC-721: The borrower's 'user' status is revoked by the platform. The NFT was always in the lender's wallet.
  - For ERC-1155: The NFT held in the Vangki Escrow is returned to the lender. The borrower's 'user' status is revoked.

### NFT Status Updates on Default/Liquidation

- The status of the relevant Vangki NFTs is updated to "Loan Defaulted" or "Loan Liquidated."

### Example: ERC-20 Liquidation (Liquid Collateral)

- Bob borrowed 1000 USDC against 0.5 WETH. WETH price drops, and his LTV exceeds 90%.
- The liquidation process is triggered. Bob's 0.5 WETH is sold.
- Assume sale yields 1020 USDC. Alice is owed 1004.11 USDC (principal + interest). After treasury fees on interest, Alice receives her due. Remaining amount (e.g., $1020 - ~$1004.11 - liquidation costs) is returned to Bob.

### Example: NFT Renting Default

- Bob rents a CryptoPunk for 7 days (total rental fee 70 USDC, prepayment 73.5 USDC including buffer).
- Bob fails to 'return' the NFT or there's an issue with fee settlement by the end of the grace period.
- The full 73.5 USDC prepayment is claimed by Alice (the lender), minus treasury fees on the 70 USDC rental portion. Alice's CryptoPunk 'user' status for Bob is revoked (or the ERC-1155 token is returned from Escrow).

## 8. Preclosing by Borrower (Early Repayment Options)

Borrowers have options to close their loans earlier than the scheduled maturity date.

### Option 1: Standard Early Repayment

- **Process:** The borrower repays the full outstanding principal _plus the full interest that would have been due for the original entire loan term_.
- This uses the same repayment logic as a normal loan closure.
- **Outcome:** The loan is closed, collateral is returned to the borrower, and Vangki NFTs are updated.

### Option 2: Loan Transfer to Another Borrower

The original borrower can transfer their loan obligation to a new borrower. This is facilitated by the original borrower accepting a "Borrower Offer" from a new borrower, or by the original borrower creating a "Lender Offer" which a new borrower accepts. The platform ensures the lender is not adversely affected.

- **Process:**
  1.  Original Borrower (Alice) has an active loan from Lender (Liam).
  2.  New Borrower (Ben) wishes to take over Alice's loan. Ben either has an active "Borrower Offer" or accepts a "Lender Offer" created by Alice (representing her desire to offload the loan).
- **Conditions for Transfer:**
  - **Collateral Requirement:** The new borrower (Ben) must provide collateral of the _same type_ as Alice's original collateral. The _amount_ of Ben's collateral must be greater than or equal to the amount of Alice's original collateral at the time of transfer. (Note: If original collateral was Liquid, LTV rules still apply based on current prices for Ben's position).
  - **Interest Rate & Income Protection for Lender (Liam):**
    - The interest rate for the new borrower (Ben) can differ from Alice's original rate.
    - Alice (original borrower) _must cover any shortfall_ in the total interest Lender Liam would receive by the end of the original loan term.
    - Shortfall Calculation: `(Original Interest Amount for Remaining Term) - (New Interest Amount for Remaining Term based on Ben's rate)`. Alice pays this shortfall to an escrow, which is eventually routed to Liam.
    - Alice must also pay all interest accrued on her loan up to the date of transfer. This accrued interest is also routed to Liam (after treasury fees).
  - **Loan Term Duration:** The new loan term for Ben must end on or before the original loan's maturity date.
- **Smart Contract Actions:**
  - Ben locks his collateral.
  - Alice's original collateral is released to her.
  - Alice pays any accrued interest and the calculated interest shortfall.
  - The loan obligation (principal repayment to Liam) is transferred from Alice to Ben.
  - Vangki NFTs are updated: Alice's Borrower NFT is closed. A new Borrower NFT is minted for Ben. Liam's Lender NFT is updated to reflect Ben as the borrower.
- **Funds Flow:** Any payments from Alice (accrued interest, shortfall) are held in an escrow (`heldForLender` field associated with Liam's loan) and become part of Liam's claimable amount at loan maturity or if Ben repays early.

### Option 3: Offset with a New Lender Offer (Original Borrower Becomes a Lender)

The original borrower can effectively preclose their loan by funding a new lender offer.

- **Process:**
  1.  Original Borrower (Alice) has an active loan from Lender (Liam).
  2.  Alice wishes to preclose. She deposits assets equivalent to her outstanding loan principal (same asset type she borrowed) and creates a new "Lender Offer" on Vangki.
  3.  The interest rate and duration for this new offer are set by Alice. The duration must not exceed the remaining term of her original loan with Liam.
- **Interest Handling for Original Lender (Liam):**
  - Alice must ensure Liam receives the full interest he was expecting.
  - If the interest Alice would earn from her new Lender Offer (if accepted and repaid) over the remaining term is _less than_ the remaining interest owed to Liam, Alice must pay this difference to an escrow for Liam at the time her new Lender Offer is accepted.
  - Alice also pays all interest accrued on her loan to Liam up to this point.
  - **Example:** Alice's loan from Liam: $10,000 USDC principal, 5% interest, 6 months remaining (expected $250 interest for Liam). Alice creates a new Lender Offer (with her $10,000 USDC) at 3% for 6 months (would earn $150 interest). Alice must pay Liam the $100 difference ($250 - $150) plus any interest accrued to date on her original loan.
- **Outcome when Alice's Lender Offer is Accepted by New Borrower (Charlie):**
  - Charlie locks collateral and accepts Alice's Lender Offer.
  - The $10,000 USDC (funded by Alice) is transferred to Charlie.
  - Alice's original collateral from her loan with Liam is released to her.
  - Alice's obligation to Liam is effectively covered (principal is now part of her offer to Charlie, interest difference paid). Liam's loan is now linked to Charlie's repayment to Alice.
  - Vangki NFTs are updated accordingly. Alice becomes a lender to Charlie. Her borrower position with Liam is closed.

## 9. Early Withdrawal by Lender

Lenders may wish to exit their loan positions before maturity.

### Option 1: Sell the Loan to Another Lender

The original lender can sell their active loan to a new lender. This is facilitated by the original lender accepting another "Lender Offer" (which is essentially a "buy offer" for a loan position) or by creating a "Borrower Offer" (which acts as a "sell offer" for their loan).

- **Process:**
  1.  Original Lender (Liam) has an active loan to Borrower (Alice).
  2.  New Lender (Noah) wants to take over Liam's loan position. Noah either has an active "Lender Offer" (offering to lend, which Liam's loan can satisfy) or accepts a "Borrower Offer" created by Liam (Liam offering his loan for sale).
- **Interest Handling & Principal Recovery:**
  - **Accrued Interest:** Any interest accrued on the loan up to the point of sale is _forfeited by the original lender (Liam) and sent to the Vangki platform's treasury_. This is an incentive for lenders to hold loans to maturity and protects the borrower and platform from complex interest recalculations during transfers.
  - **Principal Transfer:** The new lender (Noah) pays the outstanding principal amount of the loan. This principal is transferred to the original lender (Liam).
  - **Interest Rate Discrepancy:**
    - If the interest rate on the offer Noah is providing (or the rate Liam sets for his sale) results in a different overall return compared to the original loan terms for the remaining duration:
      - The original lender (Liam) might need to cover a shortfall or might find the terms unattractive.
      - Specifically, if Liam accepts a "Lender Offer" from Noah that has a higher interest rate than his current loan to Alice, Liam must pay the interest difference for the remaining term. This amount is offset by any accrued interest on Liam's loan (which would have gone to treasury). If accrued interest is insufficient, Liam pays the remainder. If accrued interest exceeds this shortfall, the excess of the accrued interest (after covering the shortfall) goes to treasury.
      - **Example:** Liam's loan to Alice is at 5%. Noah's offer is to lend at 7%. Liam wants to sell his loan by 'fulfilling' Noah's offer. Liam would need to cover the 2% interest difference for the remaining term. If Liam's loan had $50 accrued interest (normally for treasury) and the shortfall was $20, then $20 of accrued interest covers this, and $30 goes to treasury. If shortfall was $60, Liam would use the $50 accrued interest and pay an additional $10.
  - **Frontend Warnings:** The frontend will display how much the original lender (Liam) will net after accounting for forfeited accrued interest and any potential shortfall payments if they proceed with the sale.
- **Smart Contract Actions:**
  - Noah deposits the principal amount.
  - Principal is transferred to Liam.
  - Accrued interest (or its adjusted part) goes to treasury. Liam might pay a shortfall.
  - The loan rights (future principal and interest payments from Borrower Alice) are transferred to Noah.
  - Vangki NFTs are updated: Liam's Lender NFT is closed/marked sold. A new Lender NFT is minted for Noah, linked to Alice's existing Borrower NFT.
- **Borrower's Perspective:** Borrower Alice continues to make payments as per the original terms, but these payments now go to Noah.

### Option 2: Create a Loan Sale Offer (Original Lender Creates a "Borrower Offer")

- **Process:** The original lender (Liam) creates an offer that looks like a "Borrower Offer." He specifies the loan asset (the principal he is owed), the collateral securing it (Alice's collateral), and the interest rate he is willing to effectively 'pay' or 'receive' for someone to take over his lender position for the remaining duration.
- **Interest Handling:** Similar to Option 1. Liam forfeits accrued interest to the treasury. If the rate in his sale offer implies a less favorable return for the new lender than the original loan, Liam might recover less than his principal or need to subsidize the rate. The goal is typically to recover the principal.
- **Outcome:** If a new lender (Noah) accepts this offer, Noah pays the agreed amount (typically the principal) to Liam. The loan position transfers to Noah.

### Option 3: Wait for Loan Maturity

- **Condition:** If the lender cannot find a suitable offer to sell their loan or chooses not to sell, they must wait until the loan reaches its full term.
- **Process:** The loan continues as per the original agreement. At maturity, the borrower repays principal and full interest (or defaults), and funds are distributed according to the standard loan closure or default process. The lender claims their dues by presenting their Vangki NFT.

## 10. Governance

Vangki aims for community-led governance over key platform parameters and treasury usage.

### Voting Mechanism

- **Governance Token (VNGK):** A native governance token (e.g., VNGK) will be used for voting. Token holders can create proposals and vote on them.
- **Proposal Scope:** Proposals can cover:
  - Adjustments to treasury fee percentages.
  - Changes to late fee structures and caps.
  - Modifications to LTV thresholds for liquid collateral.
  - Grace period durations.
  - Allocations of funds from the treasury for development, security audits, liquidity mining programs, etc.
  - Upgrades to smart contracts (see Security and Upgradability).
- **Process:** Vangki will use OpenZeppelin's Governor module or a similar battle-tested framework.
  - **Proposal Submission:** Requires a minimum VNGK holding.
  - **Voting Period:** A defined period during which VNGK holders can cast their votes.
  - **Quorum:** A minimum percentage of the total VNGK token supply (or staked VNGK) must participate in a vote for it to be valid (e.g., 20%).
  - **Majority Threshold:** A minimum percentage of votes cast must be in favor for a proposal to pass (e.g., 51%).
- **Implementation:** Passed proposals are implemented automatically by the governance contract interacting with other platform contracts, or by a multi-sig controlled by the DAO executing the changes.

### Treasury and Revenue Sharing

- **Treasury Collection:** As defined (1% of interest/rental fees, 1% of late fees).
- **Revenue Distribution:** 50% of the fees collected by the treasury will be distributed monthly to VNGK token holders who actively stake their tokens in the platform's staking contract.
- **Treasury Dashboard:** A public dashboard (e.g., built with Dune Analytics or similar tools, integrated into the Vangki frontend) will display real-time treasury data:
  - Total income from fees.
  - The 50% portion allocated for distribution to VNGK stakers.
  - Historical fee data and distribution amounts.
  - This ensures full transparency regarding platform finances.

### VNGK Token Distribution

The VNGK governance token will be distributed to align incentives and encourage platform participation.

- **Proposed Allocation:**
  - Founders: 10%
  - Developers & Team: 15%
  - Testers & Early Contributors: 5%
  - Platform Admins/Operational Roles (e.g., initial multi-sig holders): 5%
  - Security Auditors: 2%
  - Regulatory Compliance Pool (if needed): 1%
  - Bug Bounty Programs: 2%
  - Exchange Listings & Market Making: 10%
  - **Platform Interaction Rewards: 30%**
    - Earned by users (lenders and borrowers) based on their activity (e.g., proportional to interest/rental fees generated/paid).
    - For borrowers, tokens are claimable only after proper loan repayment (not on liquidation or default).
    - Lenders receive their interaction rewards irrespective of borrower repayment status, based on the loan being active.
  - **Staking Rewards: 20%**
    - Distributed over time to users who stake their VNGK tokens in the platform's staking contract.
    - This allocation will contribute to an annual inflation rate for the VNGK token (e.g., a target of 2% of the staking rewards pool distributed annually) to incentivize staking.
- **Distribution Mechanism:** Rewards (Platform Interaction, Staking) will generally follow a pull model, where users claim their earned tokens via the Vangki dashboard. Initial distributions (e.g., for team, founders) may have vesting schedules.

## 11. Notifications (Phase 1: SMS/Email)

Effective communication is key for user experience and risk management. For Phase 1, Vangki will use SMS and Email notifications.

### Implementation

- **Mechanism:** An off-chain service will monitor key smart contract events. When a relevant event occurs, this service will trigger SMS/Email notifications to the concerned users.
- **Providers:** The platform will use established third-party APIs for sending SMS (e.g., Twilio) and Emails (e.g., SendGrid).
- **User Registration:** Users will need to provide and verify their phone number and/or email address in their Vangki profile to receive notifications. Opt-in/opt-out preferences for non-critical notifications can be managed.
- **Funding:** The cost of sending these SMS/Email notifications will be covered by the Vangki platform, funded from its treasury.
- **Criticality:** Notifications will be primarily for critical events to avoid alert fatigue.
- **Types of Notifications (Examples):**
  - **Loan Initiation:** Offer accepted, loan now active.
  - **Repayment Reminders:** Sent a few days before the loan due date and at the start of the grace period. (Paid by platform)
  - **LTV Warnings (for Liquid Collateral):** Alerts when LTV approaches critical levels (e.g., 80%, 85%). (Paid by platform)
  - **Successful Repayment:** Confirmation that a loan has been repaid.
  - **Funds/Collateral Claimable:** Notification when repayment is made and funds/collateral are ready for the counterparty to claim. (Paid by platform)
  - **Liquidation/Default Events:** Notification of loan default or initiation of liquidation. (Paid by platform)
  - **Offer Matched/Expired/Cancelled.**
  - **Governance Alerts:** New proposals, voting period starting/ending.

## 12. User Dashboard

A comprehensive user dashboard is essential for managing activities on Vangki.

### Features

- **Overview:** Summary of active loans (as lender and borrower), open offers, total value locked/borrowed.
- **Loan Management:** Detailed view of each loan:
  - Principal, interest rate/rental fee, duration, due dates.
  - Collateral details (type, amount, current value if liquid, LTV if applicable).
  - Repayment schedule and history.
  - Options to repay, preclose, or manage collateral (if applicable).
- **Offer Management:** View and manage created offers (active, matched, cancelled, expired).
- **NFT Portfolio:** Display of Vangki-minted NFTs (Vangki NFTs) held by the user, along with their status and associated loan/offer details.
- **Claim Center:** Clear interface to claim pending funds (repayments, rental fees) or collateral.
- **Transaction History:** Record of all platform interactions.
- **VNGK Token Management:** View VNGK balance, claimable rewards (interaction/staking), and interface for staking/unstaking.
- **Notification Settings:** Manage preferences for SMS/Email alerts.
- **Analytics:** Basic analytics on lending/borrowing performance.
- **Data Refresh:** The dashboard will update periodically (e.g., every minute or on user action) to reflect on-chain changes.

## 13. Technical Details

### Blockchain and Networks (Phase 1)

- **Supported Networks:** Ethereum, Polygon, Arbitrum.
- **Intra-Network Operations:** All aspects of a single loan (offer, acceptance, collateral, repayment) occur on the _same chosen network_.

### Smart Contracts

- **Language:** Solidity (latest stable version, e.g., 0.8.x, specify version like 0.8.29 if decided).
- **Core Contracts (Examples):**
  - `VangkiOfferManagement.sol`: Handles creation, cancellation, and matching of lender/borrower offers.
  - `VangkiLoanManagement.sol`: Manages active loans, repayments, defaults, and liquidations.
  - `VangkiEscrow.sol`: Holds collateral, NFTs (ERC-1155s), and funds during various stages.
  - `VangkiNFT.sol`: The ERC-721 contract responsible for minting and managing Vangki NFTs.
  - `VangkiGovernance.sol`: Manages proposals and voting.
  - `VangkiTreasury.sol`: Collects and manages platform fees.
  - `VangkiStaking.sol`: Manages VNGK token staking and reward distribution.
- **Libraries:**
  - OpenZeppelin Contracts: For robust implementations of ERC-20, ERC-721, ERC-1155 (if Vangki mints its own utility NFTs beyond offer/loan representations), AccessControl, ReentrancyGuard, and potentially Governor.
- **Security Considerations:**
  - **Audits:** Smart contracts will undergo thorough security audits by reputable third-party firms before mainnet deployment on each network.
  - **Upgradeable Proxies:** Utilize UUPS (Universal Upgradeable Proxy Standard) proxies for core contracts to allow for future upgrades and bug fixes without disrupting ongoing operations or requiring data migration. Upgrades will be governance-controlled.
  - **Reentrancy Guards:** Applied to all functions involving external calls or asset transfers.
  - **Access Control:** Granular roles (e.g., `LOAN_MANAGER_ROLE`, `OFFER_MANAGER_ROLE`, `TREASURY_ADMIN_ROLE`) managed via OpenZeppelin's AccessControl. Roles will be assigned initially by the contract deployer/owner, with plans to transition control to governance where appropriate.
  - **Batch Processing:** Support for batch processing of certain operations (e.g., distributing staking rewards) where feasible to optimize gas costs.

### Frontend

- **Framework:** React with Web3.js or Ethers.js for blockchain interaction.
- **State Management:** Robust state management solution (e.g., Redux, Zustand).
- **Languages:** Initial launch in English, with plans for multilingual support (e.g., Spanish, Mandarin) in subsequent updates.
- **API Standards:** Frontend will interact with smart contracts using standardized data formats (e.g., JSON-like structs or arrays returned by view functions).

## 14. Initial Deployment and Configuration (Phase 1)

- **Networks:** Ethereum, Polygon, Arbitrum. Network-specific optimizations (e.g., gas limits, contract deployment strategies) will be considered.
- **Initially Supported Lending/Collateral Assets (Examples):**
  - **ERC-20 (Liquid):** USDC, USDT, DAI, WETH, WBTC.
  - (The platform will allow any ERC-20, but these will be prominently featured or have easier frontend selection initially).
- **Loan Durations:** 1 day to 1 year.

## 15. NFT Verification Tool

### Purpose

A web-based tool, integrated as a dedicated page within the Vangki frontend, to allow anyone to track and validate the authenticity and status of NFTs minted by the Vangki platform (Vangki NFTs).

### Features

- **NFT Details Display:**
  - Input: Contract Address and Token ID of a Vangki NFT.
  - Output: Displays all associated on-chain metadata (e.g., offer ID, loan ID, involved assets, collateral details, interest rate/rental fee, duration, current status - "Offer Created," "Loan Active," "Repaid," "Defaulted," etc.).
- **Authenticity Validation:** Verifies if the NFT was indeed minted by the official VangkiNFT contract.
- **Status Verification:** Shows the current, real-time status of the underlying offer or loan as recorded on the blockchain.

### Implementation

- **Smart Contract Interaction:** The tool will directly query the `VangkiNFT.sol` contract's public view functions (like `tokenURI` and other specific getters for loan/offer data linked to an NFT) to fetch and display the on-chain data.

## 16. Regulatory Compliance Considerations

Vangki is committed to operating in a compliant manner within the evolving regulatory landscape for decentralized finance.

### Measures for Phase 1

- **KYC/AML Integration:**
  - The platform will integrate with decentralized KYC/AML solutions (e.g., Civic, Verite, ComplyCube, KYC-Chain, or Trust Node by ComplyAdvantage).
  - **Tiered Approach:**
    - **Tier 0 (No KYC/AML):** For transactions where the principal loan amount (for ERC-20 loans using liquid assets valued in USDC) or total rental value (for NFT renting, valued in USDC) is less than $1,000 USD.
    - **Tier 1 (Limited KYC):** For transaction values between $1,000 and $9,999 USD. This might involve basic identity verification.
    - **Tier 2 (Full KYC/AML):** For transaction values of $10,000 USD or more. This will require more comprehensive identity verification and AML checks.
  - **Valuation for KYC Thresholds:**
    - **ERC-20 Loans:** The USDC equivalent value of the _principal amount being lent_ (if liquid) determines the transaction value. If the principal asset is illiquid, or if collateral is illiquid/NFT, these are considered $0 for this specific calculation, relying on the value of the liquid component.
    - **NFT Renting:** The _total rental value_ (daily rate \* duration, converted to USDC equivalent) determines the transaction value.
    - The platform will use Chainlink oracles for converting liquid asset values to USDC for these threshold checks.
- **Implementation Timing:** KYC/AML measures will be part of the initial launch.
- **Ongoing Monitoring & Governance:** The platform will monitor regulatory developments and allow for governance proposals to update compliance measures as needed.

## Summary (Phase 1)

Vangki (Phase 1) is a decentralized P2P lending platform supporting ERC-20 tokens and rentable NFTs on Ethereum, Polygon, and Arbitrum (operating independently on each network). It leverages unique NFTs for transparent offer and loan tracking. Key features include distinct handling of liquid vs. illiquid assets, platform-funded SMS/Email notifications, and robust options for early loan closure and withdrawal, all governed by the VNGK token community. The integrated NFT verification tool enhances transparency.

## Further Notes on Key Topics (Phase 1 Focus)

### NFT Metadata and Status Updates

- **Metadata:** NFTs minted by Vangki (Vangki NFTs) store key details on-chain (e.g., asset, collateral, rate, duration, status). The `tokenURI` function dynamically generates this metadata, including pointers to IPFS-hosted images reflecting the NFT's role and status.
- **Status Updates:** Loan and Offer NFTs track statuses like "Offer Created," "Loan Active," "Repaid," "Defaulted," "Closed." These updates are performed by authorized smart contract roles (e.g., `VangkiLoanManagement.sol`, `VangkiOfferManagement.sol`).
- **Event Emission:** Detailed events are emitted for each state change, ensuring transparency and facilitating easier frontend tracking and off-chain service integration (like the notification system).
- **Claiming Funds/Assets/Collateral:** Users must present their relevant Vangki-minted NFT (e.g., Lender's Vangki NFT to claim repayment, Borrower's Vangki NFT to claim collateral back) to the platform's smart contracts. This acts as a proof of ownership and authorization for the claim.

### Liquidation and Collateral Handling (Recap)

- **Liquid ERC-20 Collateral:** Subject to LTV monitoring and DEX-based liquidation or auctions if LTV breaches thresholds or on default post-grace period. Excess proceeds return to the borrower.
- **Illiquid ERC-20 Collateral / All NFT Collateral:** Not subject to LTV-based liquidation. On default post-grace period, the full collateral is transferred to the lender. Users are explicitly warned and must agree to these terms if dealing with illiquid assets.
- **Illiquid Asset Warnings:** The frontend prominently displays warnings when users interact with assets identified as illiquid. Smart contracts enforce illiquid handling based on on-chain verification and recorded user consent.

### Governance and Treasury (Recap)

- **Governance:** OpenZeppelin Governor module (or similar) for VNGK token-based voting on parameters and treasury use.
- **Treasury:** 1% of interest/rental fees and 1% of late fees. 50% of treasury income is distributed monthly to VNGK stakers. A public dashboard will provide transparency.

### User Experience and Frontend

- **Clear Indicators:** The React-based frontend will use clear indicators for network selection, asset liquidity status, and potential risks.
- **Information Icons & Tooltips:** Information icons next to key fields and terms will provide tooltips with concise explanations. Links to more detailed documentation or FAQs will be available.
- **Critical Notifications:** SMS/Email notifications are concise, actionable, and platform-funded, focusing on essential events. Users manage their contact details for these alerts.

### Security and Upgradability

- **Access Control:** Granular roles via OpenZeppelin's AccessControl, initially set by the deployer and transferable to governance.
- **Reentrancy Guards:** Standard on relevant functions.
- **Upgradability (UUPS Proxies):** Core contracts use UUPS proxies. Upgrades are controlled by community governance via VNGK voting.
- **Emergency Updates:** For critical security vulnerabilities posing an immediate threat to user funds or platform integrity, emergency updates can be fast-tracked. These actions will require approval from a multi-signature (multi-sig) wallet, with the signers initially being core team members or trusted parties, and potentially transitioning to DAO-elected signers later. These emergency powers are strictly limited to critical patches.

### Testing and Auditing

- **Testing:** Comprehensive test suites (unit, integration, end-to-end) covering all functionalities, including positive/negative flows, edge cases, metadata/event checks, and various asset handling scenarios.
- **Internal Audits:** Use of static analysis tools (e.g., Slither, MythX) and thorough internal code reviews.
- **Fuzz Testing**: for math (e.g., interest calculations) and simulation of defaults/LTV breaches.
- **Open-Source Tests:** Test cases will be made open-source on GitHub post-mainnet deployment for community review.
- **External Auditing:** Mandatory third-party security audits by reputable firms before mainnet launch. Audit reports will be publicly available.

### Development Tools

- **Smart Contracts:** Foundry for development and testing.
- **Frontend:** React, Ethers.js for blockchain interaction.

## Phase 1 Additions: Borrower Collateral Management & Refinancing

The following features are planned for Phase 1:

### Allow Borrower to Add Collateral

- **Purpose:** To allow borrowers with loans against liquid collateral to proactively add more collateral to reduce their LTV and avoid potential liquidation if the value of their existing collateral is declining.
- **Process:** Borrowers can deposit additional units of the same collateral asset type already securing their loan. The platform recalculates LTV.

### Allow Borrower to Withdraw Excess Collateral (Health Factor)

- **Purpose:** If a borrower's liquid collateral has significantly appreciated in value, or if they have over-collateralized initially, they may be able to withdraw some collateral.
- **Condition:** The withdrawal must not cause the loan's "Health Factor" to drop below a safe threshold (e.g., 150%).
  - Health Factor defined as: `(Value of Liquid Collateral in USDC) / (Value of Borrowed Amount in USDC)`
  - The minimum Health Factor (e.g., 150%) must be maintained post-withdrawal.
- **Process:** Borrower requests withdrawal of a specific amount of collateral. The system checks if the Health Factor remains above the threshold. If so, the excess collateral is released.

### Allow Borrower to Choose New Lender with Better Offer (Refinance)

- **Purpose:** To enable a borrower to switch their existing loan to a new lender who is offering better terms (e.g., lower interest rate).
- **Process:**
  1.  The borrower (Alice) has an existing loan from Lender A.
  2.  Alice finds or creates a new "Borrower Offer" with her desired terms (e.g., lower interest rate).
  3.  A new Lender (Lender B) accepts Alice's Borrower Offer.
  4.  The principal amount from Lender B is used to instantly repay Alice's original loan to Lender A (principal + any full-term interest due to Lender A as per early repayment rules, or pro-rata interest if governance allows different early repayment terms for refinancing).
  5.  Alice's collateral from the loan with Lender A is then used to secure the new loan with Lender B (or she provides new/different collateral as per her offer with Lender B).
  6.  Alice may have to pay any shortfall (e.g., difference in interest amounts owed to Lender A vs. terms with Lender B) or additional fees for this refinancing.
  7.  Vangki NFTs are updated: Loan with Lender A is closed. New loan with Lender B is initiated.

---

**Note on "Illiquid" Definition for LTV and KYC:**
For utmost clarity:

- Any NFT is considered illiquid with a $0 platform-assessed value for LTV and collateral valuation. For KYC, the _rental value in USDC_ is used for NFT renting.
- An ERC-20 token is illiquid if it lacks a Chainlink feed OR a recognized DEX pool. Illiquid ERC-20s also have a $0 platform-assessed value for LTV. For KYC, if the _lent/borrowed asset itself_ is illiquid, it's $0, and KYC is based on other liquid components if any. If the collateral is illiquid, it doesn't add to the transaction value for KYC if the primary lent/borrowed asset is liquid.

## New features

- **Partial Lending and Borrowing:** Allowing users to accept offers with Partial lending amount, so that one offer may have more than one loan realated to it.
- **Flexible Interest:** Allowing lenders to earn flexible interest by using duration of the loan to 1 day and full filling the loan everyday at maximum interest rates in the list of available offers with same asset and collateral.

## Developement Approach

The Diamond Standard (EIP-2535) need to be followed for smart contract developement

# Special Note

## Security Note:

- The offers from users will be listed to only those users who are in the respective countries that can trade between themselves. This is done as there can be sactions between the countries.
- No common escrow account and only seperate Escrow account for each users (via clone factory for gas efficiency) would implemented which will then be managed by Vangki App. This is to avoid commingling of funds.
- Use Reentrancygaurd and pausable from Openzeppelin wherever needed.

## Other Notes:

- Keep cross chain functionality, governance, partial loan, flexible interest and multi collateral asset for later development (for phase 2) and complete other features first.
- Follow the coding standards, style conventions and develop code by following best practices approach and with proper nat comments
- Use Foundry for testing/fuzzing. Slither/Mythril for audits. Optimize: Batch claims, minimal storage.
