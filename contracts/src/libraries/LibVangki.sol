// src/libraries/LibVangki.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";

/**
 * @title LibVangki
 * @author Vangki Developer Team
 * @notice This library provides shared storage and data structures for the Vangki P2P lending platform.
 * @dev Used in the Diamond Standard (EIP-2535) to manage global state across facets.
 *      Storage is accessed via a specific slot to avoid collisions.
 *      Includes enums for asset types, liquidity, offer types, and loan statuses.
 *      Structs for Offers and Loans store key details.
 *      The Storage struct holds mappings and counters for offers, loans, escrows, and asset liquidity.
 *      No functions beyond storage access; all logic in facets.
 *      Expand for future phases (e.g., cross-chain, governance).
 */
library LibVangki {
    // Storage position to avoid collisions in Diamond proxy.
    bytes32 internal constant VANGKI_STORAGE_POSITION =
        keccak256("vangki.storage");

    // Constants (configurable via governance in Phase 2)
    uint256 constant MIN_HEALTH_FACTOR = 150 * 1e16; // 1.5 scaled to 1e18
    uint256 constant TREASURY_FEE_BPS = 100; // 1% of interest
    uint256 constant BASIS_POINTS = 10000;

    error CrossFacetCallFailed(string reason);

    /**
     * @notice Enum for supported asset types.
     * @dev ERC20 for tokens, NFT721 for unique NFTs, NFT1155 for semi-fungible NFTs.
     */
    enum AssetType {
        ERC20,
        ERC721,
        ERC1155
    }

    /**
     * @notice Enum for asset liquidity status.
     * @dev Liquid if Chainlink feed and DEX pool exist; Illiquid otherwise (includes all NFTs).
     */
    enum LiquidityStatus {
        Liquid,
        Illiquid
    }

    /**
     * @notice Enum for offer types.
     * @dev Lender offers to lend, Borrower requests to borrow.
     */
    enum OfferType {
        Lender,
        Borrower
    }

    /**
     * @notice Enum for loan statuses.
     * @dev Active during term, Repaid on successful closure, Defaulted on failure.
     */
    enum LoanStatus {
        Active,
        Repaid,
        Defaulted
    }

    /**
     * @notice Struct for an offer (lender or borrower).
     * @dev Stores details for matching and loan initiation.
     *      Liquidity determined at creation.
     *      Accepted flag prevents re-acceptance.
     */
    struct Offer {
        uint256 id;
        address creator;
        OfferType offerType;
        address lendingAsset; // ERC20 or NFT contract
        uint256 amount; // Principal/rental fee
        uint256 interestRateBps; // Basis points for interest/rental rate
        address collateralAsset; // ERC20 only for Phase 1
        uint256 collateralAmount;
        uint256 durationDays;
        LiquidityStatus liquidity;
        bool accepted;
        uint256 tokenId; // For NFT721/1155; 0 for ERC20
        uint256 quantity; // For ERC1155; 1 for ERC721; 0 for ERC20
        AssetType assetType;
        bool useFullTermInterest;
        bool illiquidConsent;
        address prepayAsset; // ERC20 for NFT rental fees (e.g., USDC); address(0) for ERC20 loans
    }

    /**
     * @notice Struct for an active loan.
     * @dev Created on offer acceptance; tracks repayment/default.
     *      References original offerId for details.
     */
    struct Loan {
        uint256 id;
        uint256 offerId;
        address lender;
        address borrower;
        uint256 lenderTokenId;
        uint256 borrowerTokenId;
        uint256 principal; // Lent amount or rental value
        address principalAsset;
        uint256 interestRateBps;
        uint256 startTime; // Timestamp of initiation
        uint256 durationDays;
        address collateralAsset;
        uint256 collateralAmount;
        LiquidityStatus liquidity;
        LoanStatus status;
        uint256 tokenId; // For NFT lending assets
        uint256 quantity; // For ERC1155
        AssetType assetType;
        bool useFullTermInterest;
        uint256 prepayAmount;
        uint256 bufferAmount;
        uint256 lastDeductTime;
        address prepayAsset; // ERC20 for NFT rental fees (e.g., USDC); address(0) for ERC20 loans
    }

    struct RiskParams {
        uint256 maxLtvBps; // Max LTV in basis points
        uint256 liqThresholdBps; // Liquidation Threshold in basis points
        uint256 liqBonusBps; // Liquidation Bonus in basis points
        uint256 reserveFactorBps; // Reserve Factor in basis points
        uint256 minPartialBps; // Min partial repay % (e.g., 100 for 1%)
    }

    /**
     * @notice Main storage struct for Vangki.
     * @dev Holds all global data: offers, loans, IDs, escrows, asset configs.
     *      Accessed via storageSlot function.
     *      Expand with care to preserve layout for upgrades.
     */
    struct Storage {
        uint256 nextOfferId;
        uint256 nextLoanId;
        uint256 nextTokenId; // For Vangki NFTs
        address vangkiEscrowTemplate; // Shared UUPS implementation
        address treasury; // Configurable treasury address
        address zeroExProxy; // 0x proxy for liquidations
        mapping(uint256 => uint256) loanToSaleOfferId;
        mapping(uint256 => Offer) offers;
        mapping(uint256 => Loan) loans;
        mapping(address => address) userVangkiEscrows; // Per-user proxy addresses
        mapping(address => bool) liquidAssets; // Manual liquidity overrides
        mapping(address => RiskParams) assetRiskParams;
        mapping(address => uint256) treasuryBalances;
        mapping(address => string) userCountry; // ISO code, e.g., "US"
        mapping(address => bool) kycVerified;
        mapping(bytes32 => mapping(bytes32 => bool)) allowedTrades; // hash(countryA) => hash(countryB) => true if A can trade with B
    }

    /**
     * @notice Retrieves the Vangki storage slot.
     * @dev Uses assembly to load the struct at the predefined position.
     *      Used by all facets to access shared state.
     * @return s The Storage struct.
     */
    function storageSlot() internal pure returns (Storage storage s) {
        bytes32 position = VANGKI_STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }

    /// @dev Sets country
    function setUserCountry(address user, string memory country) internal {
        Storage storage s = storageSlot();
        s.userCountry[user] = country;
    }

    /// @dev Calculates the grace period based on loan duration.
    function gracePeriod(uint256 durationDays) internal pure returns (uint256) {
        if (durationDays < 7) return 1 hours;
        if (durationDays < 30) return 1 days;
        if (durationDays < 90) return 3 days;
        if (durationDays < 180) return 1 weeks;
        return 2 weeks;
    }

    /// @dev Calculates late fees: 1% on first day post-due, +0.5% daily, capped at 5% of principal.
    function calculateLateFee(
        uint256 loanId,
        uint256 endTime
    ) internal view returns (uint256) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];

        if (block.timestamp <= endTime) return 0;

        uint256 daysLate = (block.timestamp - endTime) / 1 days;
        uint256 feePercent = 100 + (daysLate * 50); // 1% + 0.5% per day (in basis points)
        if (feePercent > 500) feePercent = 500; // Cap 5%

        return (loan.principal * feePercent) / 10000; // Basis points
    }

    /**
     * @notice Sets trade allowance between two countries (owner-only).
     * @dev Bidirectional by default (sets both A->B and B->A); for asymmetric, call twice.
     *      Uses keccak256 for string hashing to save gas.
     *      Callable via a facet (e.g., ProfileFacet) by Diamond owner.
     * @param countryA ISO code for country A.
     * @param countryB ISO code for country B.
     * @param allowed True to allow trade, false to block.
     */
    function setTradeAllowance(
        string memory countryA,
        string memory countryB,
        bool allowed
    ) internal {
        LibDiamond.enforceIsContractOwner();
        Storage storage s = storageSlot();
        bytes32 hashA = keccak256(bytes(countryA));
        bytes32 hashB = keccak256(bytes(countryB));
        s.allowedTrades[hashA][hashB] = allowed;
        s.allowedTrades[hashB][hashA] = allowed; // Bidirectional; remove if asymmetric needed
    }

    /**
     * @notice Checks if two countries can trade.
     * @dev View helper; checks allowedTrades mapping (defaults false if unset).
     * @param countryA ISO code for country A.
     * @param countryB ISO code for country B.
     * @return canTrade True if allowed.
     */
    function canTradeBetween(
        string memory countryA,
        string memory countryB
    ) internal view returns (bool canTrade) {
        Storage storage s = storageSlot();
        bytes32 hashA = keccak256(bytes(countryA));
        bytes32 hashB = keccak256(bytes(countryB));
        return s.allowedTrades[hashA][hashB]; // Assumes bidirectional
    }

    /// @dev set Treasury in initialize
    function setTreasury(address newTreasury) internal {
        LibDiamond.enforceIsContractOwner();
        Storage storage s = storageSlot();
        s.treasury = newTreasury;
    }

    /// @dev set 0x Proxy
    function setZeroExProxy(address newProxy) internal {
        LibDiamond.enforceIsContractOwner();
        Storage storage s = storageSlot();
        s.zeroExProxy = newProxy;
    }
}
