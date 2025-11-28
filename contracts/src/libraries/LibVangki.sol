// src/libraries/LibVangki.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

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

    /**
     * @notice Enum for supported asset types.
     * @dev ERC20 for tokens, NFT721 for unique NFTs, NFT1155 for semi-fungible NFTs.
     */
    enum AssetType {
        ERC20,
        NFT721,
        NFT1155
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
        uint256 amount; // Principal/rental fee or quantity for NFTs
        uint256 interestRateBps; // Basis points for interest/rental rate
        address collateralAsset; // ERC20 only for Phase 1
        uint256 collateralAmount;
        uint256 durationDays;
        LiquidityStatus liquidity;
        bool accepted;
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
        uint256 principal; // Lent amount or rental value
        uint256 interestRateBps;
        uint256 startTime; // Timestamp of initiation
        uint256 durationDays;
        address collateralAsset;
        uint256 collateralAmount;
        LoanStatus status;
    }

    struct RiskParams {
        uint256 maxLtvBps; // Max LTV in basis points
        uint256 liqThresholdBps; // Liquidation Threshold in basis points
        uint256 liqBonusBps; // Liquidation Bonus in basis points
        uint256 reserveFactorBps; // Reserve Factor in basis points
    }

    /**
     * @notice Main storage struct for Vangki.
     * @dev Holds all global data: offers, loans, IDs, escrows, asset configs.
     *      Accessed via storageSlot function.
     *      Expand with care to preserve layout for upgrades.
     */
    struct Storage {
        mapping(uint256 => Offer) offers;
        mapping(uint256 => Loan) loans;
        uint256 nextOfferId;
        uint256 nextLoanId;
        uint256 nextTokenId; // For Vangki NFTs
        address vangkiEscrowTemplate; // Shared UUPS implementation
        mapping(address => address) userVangkiEscrows; // Per-user proxy addresses
        mapping(address => bool) liquidAssets; // Manual liquidity overrides
        mapping(address => RiskParams) assetRiskParams;
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
}

// ##EOF##
// pragma solidity ^0.8.29;

// import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import "@openzeppelin/contracts/utils/ReentrancyGuard.sol"; // For guards

// library LibVangki {
//     bytes32 constant VANGKI_STORAGE_POSITION = keccak256("vangki.storage");

//     enum AssetType {
//         ERC20,
//         NFT721,
//         NFT1155
//     } // For future expansion
//     enum LiquidityStatus {
//         Liquid,
//         Illiquid
//     }
//     enum OfferType {
//         Lender,
//         Borrower
//     }
//     enum LoanStatus {
//         Active,
//         Repaid,
//         Defaulted
//     }

//     struct Offer {
//         uint256 id;
//         address creator;
//         OfferType offerType;
//         address lendingAsset; // ERC20 token
//         uint256 amount; // Principal or requested amount
//         uint256 interestRateBps; // Basis points (e.g., 500 = 5%)
//         address collateralAsset; // ERC20 for now
//         uint256 collateralAmount;
//         uint256 durationDays;
//         LiquidityStatus liquidity;
//         bool accepted;
//     }

//     struct Loan {
//         uint256 id;
//         uint256 offerId;
//         address lender;
//         address borrower;
//         uint256 principal;
//         uint256 interestRateBps;
//         uint256 startTime;
//         uint256 durationDays;
//         address collateralAsset;
//         uint256 collateralAmount;
//         LoanStatus status;
//     }

//     struct Storage {
//         mapping(uint256 => Offer) offers;
//         mapping(uint256 => Loan) loans;
//         uint256 nextOfferId;
//         uint256 nextLoanId;
//         uint256 nextTokenId;
//         address vangkiEscrowTemplate; // Base Escrow contract address
//         mapping(address => address) userVangkiEscrows; // Per-user escrow address
//         address nftContract; // VangkiNFT address
//         mapping(address => bool) liquidAssets; // Manual mapping for high-value assets (update via ownership)
//         // Add more as needed (e.g., Chainlink feeds)
//     }

//     function storageSlot() internal pure returns (Storage storage s) {
//         bytes32 position = VANGKI_STORAGE_POSITION;
//         assembly {
//             s.slot := position
//         }
//     }
// }
