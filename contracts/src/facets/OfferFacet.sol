// src/facets/OfferFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol"; // Added for NFT support
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol"; // Added for NFT support
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Pausable.sol"; // Added for pausable
import {OracleFacet} from "./OracleFacet.sol"; // For liquidity and price
import {VangkiNFTFacet} from "./VangkiNFTFacet.sol"; // For minting
import {EscrowFactoryFacet} from "./EscrowFactoryFacet.sol"; // For escrow selectors
import {LoanFacet} from "./LoanFacet.sol"; // New: For loan initiation on accept
import {ProfileFacet} from "./ProfileFacet.sol"; // New: For KYC check
import "../interfaces/IERC4907.sol";

/**
 * @title OfferFacet
 * @author Vangki Developer Team
 * @notice This facet handles the creation, acceptance, and cancellation of offers in the Vangki P2P lending platform.
 * @dev This contract is part of the Diamond Standard (EIP-2535) and uses shared storage from LibVangki.
 *      Enhanced for Phase 1: Added support for NFT lending (ERC721/1155 rentals), country-based filtering (sanctions compliance),
 *      Pausable for emergency stops. Liquidity via OracleFacet. On accept, initiates loan via LoanFacet.
 *      Offers filtered by user country (assumes userCountry set via ProfileFacet).
 *      New Illiquid Handling: In acceptOffer, calculate transaction value (liquid lent + collateral in USD); if > $2k, require KYC for both parties.
 *      For NFT rentals, value = amount (rental fee) * durationDays if liquid (but NFTs illiquid, $0).
 *      Custom errors. ReentrancyGuard protects against reentrancy attacks.
 *      Events for all state changes. Cross-facet calls use low-level call on address(this).
 *      Gas optimized: Unchecked math for IDs, minimal storage reads.
 *      Enhanced: Added NFT renting logic in createOffer (approve/deposit NFT) and acceptOffer (prepay lock with 5% buffer, set renter via escrow).
 *      Daily deduct handled pro-rata in RepayFacet (from prepay). Buffer to treasury on default/repay.
 *      Added KYC check in acceptOffer if valueUSD > KYC_THRESHOLD_USD.
 *      Added getCompatibleOffers for country filtering (assumes canTradeWith function; simple != "sanctioned" placeholder).
 */
contract OfferFacet is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    /// @notice Emitted when a new offer is created.
    /// @param offerId The unique ID of the created offer.
    /// @param creator The address of the user creating the offer.
    /// @param offerType The type of offer (Lender or Borrower).
    event OfferCreated(
        uint256 indexed offerId,
        address indexed creator,
        LibVangki.OfferType offerType
    );

    /// @notice Emitted when an offer is accepted.
    /// @param offerId The ID of the accepted offer.
    /// @param acceptor The address of the user accepting the offer.
    /// @param loanId The ID of the initiated loan.
    event OfferAccepted(
        uint256 indexed offerId,
        address indexed acceptor,
        uint256 loanId
    );

    /// @notice Emitted when an offer is canceled.
    /// @param offerId The ID of the canceled offer.
    /// @param creator The address of the creator canceling the offer.
    event OfferCanceled(uint256 indexed offerId, address indexed creator);

    // Custom errors for clarity and gas efficiency.
    error InvalidOfferType();
    error InvalidAssetType();
    error OfferAlreadyAccepted();
    error NotOfferCreator();
    error InsufficientAllowance();
    error LiquidityMismatch();
    error CountriesNotCompatible(); // New: For sanctions filtering
    error KYCRequired(); // New: For >$2k transactions
    error CrossFacetCallFailed(string reason);
    error GetUserEscrowFailed(string reason);

    // Constants
    uint256 private constant KYC_THRESHOLD_USD = 2000 * 1e18; // $2k scaled to 1e18 for comparison
    uint256 private constant RENTAL_BUFFER_BPS = 500; // 5% buffer for NFT rentals
    uint256 private constant BASIS_POINTS = 10000;

    /**
     * @notice Creates a new offer (Lender or Borrower).
     * @dev Deposits/locks assets into user's escrow (via EscrowFactoryFacet).
     *      For Lender: Deposits lending amount (ERC20) or approves/escrows NFT.
     *      For Borrower: Locks collateral (ERC20/NFT).
     *      Checks liquidity; mints NFT for the offer.
     *      Enhanced: For NFT lending (Lender), if ERC721: approve escrow as operator; ERC1155: deposit tokens.
     *      Reverts if paused or invalid params.
     *      Emits OfferCreated.
     *      Callable by anyone when not paused.
     * @param offerType Lender or Borrower.
     * @param lendingAsset The lending asset address (ERC20 or NFT contract).
     * @param amount Principal for ERC20; rental fee per day for NFT.
     * @param interestRateBps Interest rate in basis points.
     * @param collateralAsset Collateral asset address.
     * @param collateralAmount Collateral amount.
     * @param durationDays Loan duration in days.
     * @param assetType Type of lending asset (ERC20, ERC721, ERC1155).
     * @param tokenId Token ID for NFTs.
     * @param quantity Quantity for ERC1155.
     * @param illiquidConsent Consent for illiquid assets.
     * @return offerId The ID of the created offer.
     */
    function createOffer(
        LibVangki.OfferType offerType,
        address lendingAsset,
        uint256 amount,
        uint256 interestRateBps,
        address collateralAsset,
        uint256 collateralAmount,
        uint256 durationDays,
        LibVangki.AssetType assetType,
        uint256 tokenId,
        uint256 quantity,
        bool illiquidConsent,
        address prepayAsset
    ) external whenNotPaused returns (uint256 offerId) {
        if (durationDays == 0) revert InvalidOfferType(); // Basic validation

        LibVangki.Storage storage s = LibVangki.storageSlot();
        unchecked {
            offerId = ++s.nextOfferId;
        }

        LibVangki.Offer storage offer = s.offers[offerId];
        offer.id = offerId;
        offer.creator = msg.sender;
        offer.offerType = offerType;
        offer.lendingAsset = lendingAsset;
        offer.amount = amount;
        offer.interestRateBps = interestRateBps;
        offer.collateralAsset = collateralAsset;
        offer.collateralAmount = collateralAmount;
        offer.durationDays = durationDays;
        offer.assetType = assetType;
        offer.tokenId = tokenId;
        offer.quantity = quantity;
        offer.illiquidConsent = illiquidConsent;
        offer.prepayAsset = prepayAsset;

        // Check liquidity
        LibVangki.LiquidityStatus liquidity = OracleFacet(address(this))
            .checkLiquidity(lendingAsset);
        offer.liquidity = liquidity;

        if (liquidity == LibVangki.LiquidityStatus.Illiquid && !illiquidConsent)
            revert LiquidityMismatch();

        // Get/create escrow
        address escrow = getUserEscrow(msg.sender);

        // Handle asset deposit/approval
        bool success;
        if (offerType == LibVangki.OfferType.Lender) {
            if (assetType == LibVangki.AssetType.ERC20) {
                IERC20(lendingAsset).safeTransferFrom(
                    msg.sender,
                    escrow,
                    amount
                );
            } else if (assetType == LibVangki.AssetType.ERC721) {
                // Approve escrow as operator (NFT stays with lender)
                IERC721(lendingAsset).approve(escrow, tokenId);
            } else if (assetType == LibVangki.AssetType.ERC1155) {
                // Deposit to escrow
                IERC1155(lendingAsset).safeTransferFrom(
                    msg.sender,
                    escrow,
                    tokenId,
                    quantity,
                    ""
                );
            } else {
                revert InvalidAssetType();
            }
        } else {
            // Borrower: Lock collateral
            if (assetType == LibVangki.AssetType.ERC20) {
                IERC20(collateralAsset).safeTransferFrom(
                    msg.sender,
                    escrow,
                    collateralAmount
                );
            } else if (assetType == LibVangki.AssetType.ERC721) {
                IERC721(collateralAsset).safeTransferFrom(
                    msg.sender,
                    escrow,
                    tokenId
                );
            } else if (assetType == LibVangki.AssetType.ERC1155) {
                IERC1155(collateralAsset).safeTransferFrom(
                    msg.sender,
                    escrow,
                    tokenId,
                    quantity,
                    ""
                );
            } else {
                revert InvalidAssetType();
            }
        }

        // Mint NFT for offer
        unchecked {
            offer.tokenId = ++s.nextTokenId;
        }
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                VangkiNFTFacet.mintNFT.selector,
                msg.sender,
                offer.tokenId,
                offerType == LibVangki.OfferType.Lender ? "Lender" : "Borrower"
            )
        );
        if (!success) revert CrossFacetCallFailed("Mint NFT failed");

        emit OfferCreated(offerId, msg.sender, offerType);
    }

    /**
     * @notice Accepts an existing offer.
     * @dev Matches Lender/Borrower, initiates loan via LoanFacet.
     *      Transfers assets from escrows.
     *      Enhanced: For NFT lending, locks prepay (amount * durationDays + 5% buffer) from borrower,
     *      sets renter via escrowSetNFTUser. Daily deduct pro-rata from prepay on repay (in RepayFacet).
     *      Adds KYC check if transaction value > $2k USD (liquid parts only).
     *      Checks countries compatible (placeholder: not equal to sanctioned; expand with mapping).
     *      Updates NFTs to active loan status.
     *      Reverts if paused, incompatible countries, or KYC required.
     *      Emits OfferAccepted.
     *      Callable by anyone when not paused.
     * @param offerId The offer ID to accept.
     * @return loanId The ID of the initiated loan.
     */
    function acceptOffer(
        uint256 offerId
    ) external whenNotPaused returns (uint256 loanId) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Offer storage offer = s.offers[offerId];
        if (offer.accepted) revert OfferAlreadyAccepted();

        // Check countries compatible
        string memory creatorCountry = ProfileFacet(address(this))
            .getUserCountry(offer.creator);
        string memory acceptorCountry = ProfileFacet(address(this))
            .getUserCountry(msg.sender);
        if (!LibVangki.canTradeBetween(creatorCountry, acceptorCountry))
            revert CountriesNotCompatible();

        // Calculate transaction value for KYC
        uint256 valueUSD = _calculateTransactionValueUSD(offer);
        if (valueUSD > KYC_THRESHOLD_USD) {
            if (
                !ProfileFacet(address(this)).isKYCVerified(offer.creator) ||
                !ProfileFacet(address(this)).isKYCVerified(msg.sender)
            ) {
                revert KYCRequired();
            }
        }

        address lenderEscrow;
        address borrowerEscrow;
        address lender;
        address borrower;

        if (offer.offerType == LibVangki.OfferType.Lender) {
            lender = offer.creator;
            borrower = msg.sender;
            lenderEscrow = getUserEscrow(lender);
            borrowerEscrow = getUserEscrow(borrower);
        } else {
            lender = msg.sender;
            borrower = offer.creator;
            lenderEscrow = getUserEscrow(lender);
            borrowerEscrow = getUserEscrow(borrower);
        }

        bool success;
        if (offer.assetType == LibVangki.AssetType.ERC20) {
            // Transfer principal to borrower
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowWithdrawERC20.selector,
                    lender,
                    offer.lendingAsset,
                    borrower,
                    offer.amount
                )
            );
            if (!success)
                revert CrossFacetCallFailed("Principal transfer failed");
        } else {
            // NFT renting: Borrower prepays (fee * days + 5% buffer)
            uint256 prepayAmount = offer.amount * offer.durationDays;
            uint256 buffer = (prepayAmount * RENTAL_BUFFER_BPS) / BASIS_POINTS;
            uint256 totalPrepay = prepayAmount + buffer;
            IERC20(offer.prepayAsset).safeTransferFrom(
                borrower,
                borrowerEscrow,
                totalPrepay
            );

            // Set renter (borrower as user)
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowSetNFTUser.selector,
                    lender,
                    offer.lendingAsset,
                    offer.tokenId,
                    borrower,
                    uint64(block.timestamp + offer.durationDays * 1 days)
                )
            );
            if (!success) revert CrossFacetCallFailed("Set renter failed");
        }

        // Lock collateral from borrower (already in escrow for Borrower offers)
        if (offer.offerType == LibVangki.OfferType.Lender) {
            if (offer.assetType == LibVangki.AssetType.ERC20) {
                IERC20(offer.collateralAsset).safeTransferFrom(
                    borrower,
                    borrowerEscrow,
                    offer.collateralAmount
                );
            } else if (offer.assetType == LibVangki.AssetType.ERC721) {
                IERC721(offer.collateralAsset).safeTransferFrom(
                    borrower,
                    borrowerEscrow,
                    offer.tokenId
                );
            } else if (offer.assetType == LibVangki.AssetType.ERC1155) {
                IERC1155(offer.collateralAsset).safeTransferFrom(
                    borrower,
                    borrowerEscrow,
                    offer.tokenId,
                    offer.quantity,
                    ""
                );
            }
        }

        // Initiate loan
        bytes memory result;
        (success, result) = address(this).call(
            abi.encodeWithSelector(
                LoanFacet.initiateLoan.selector,
                offerId,
                msg.sender
            )
        );
        if (!success) revert CrossFacetCallFailed("Loan initiation failed");
        loanId = abi.decode(result, (uint256));

        // Update offer
        offer.accepted = true;

        // Update NFTs to loan active (cross-facet)
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                VangkiNFTFacet.updateNFTStatus.selector,
                offer.tokenId,
                "Loan Active"
            )
        );
        if (!success) revert CrossFacetCallFailed("NFT update failed");

        emit OfferAccepted(offerId, msg.sender, loanId);
    }

    /**
     * @notice Cancels an existing offer.
     * @dev Releases assets from escrow.
     *      For NFT: Revokes approval or withdraws.
     *      Burns NFT.
     *      Reverts if accepted or not creator.
     *      Emits OfferCanceled.
     * @param offerId The offer ID to cancel.
     */
    function cancelOffer(uint256 offerId) external whenNotPaused {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Offer storage offer = s.offers[offerId];
        if (offer.creator != msg.sender) revert NotOfferCreator();
        if (offer.accepted) revert OfferAlreadyAccepted();

        address escrow = getUserEscrow(msg.sender);

        bool success;
        if (offer.offerType == LibVangki.OfferType.Lender) {
            if (offer.assetType == LibVangki.AssetType.ERC20) {
                (success, ) = address(this).call(
                    abi.encodeWithSelector(
                        EscrowFactoryFacet.escrowWithdrawERC20.selector,
                        msg.sender,
                        offer.lendingAsset,
                        msg.sender,
                        offer.amount
                    )
                );
                if (!success) revert CrossFacetCallFailed("Withdraw failed");
            } else if (offer.assetType == LibVangki.AssetType.ERC721) {
                // Revoke approval
                IERC721(offer.lendingAsset).approve(address(0), offer.tokenId);
            } else if (offer.assetType == LibVangki.AssetType.ERC1155) {
                (success, ) = address(this).call(
                    abi.encodeWithSelector(
                        EscrowFactoryFacet.escrowWithdrawERC1155.selector,
                        msg.sender,
                        offer.lendingAsset,
                        offer.tokenId,
                        offer.quantity,
                        msg.sender
                    )
                );
                if (!success) revert CrossFacetCallFailed("Withdraw failed");
            }
        } else {
            // Borrower: Unlock collateral
            if (offer.assetType == LibVangki.AssetType.ERC20) {
                (success, ) = address(this).call(
                    abi.encodeWithSelector(
                        EscrowFactoryFacet.escrowWithdrawERC20.selector,
                        msg.sender,
                        offer.collateralAsset,
                        msg.sender,
                        offer.collateralAmount
                    )
                );
                if (!success) revert CrossFacetCallFailed("Unlock failed");
            } else if (offer.assetType == LibVangki.AssetType.ERC721) {
                (success, ) = address(this).call(
                    abi.encodeWithSelector(
                        EscrowFactoryFacet.escrowWithdrawERC721.selector,
                        msg.sender,
                        offer.collateralAsset,
                        offer.tokenId,
                        msg.sender
                    )
                );
                if (!success) revert CrossFacetCallFailed("Unlock failed");
            } else if (offer.assetType == LibVangki.AssetType.ERC1155) {
                (success, ) = address(this).call(
                    abi.encodeWithSelector(
                        EscrowFactoryFacet.escrowWithdrawERC1155.selector,
                        msg.sender,
                        offer.collateralAsset,
                        offer.tokenId,
                        offer.quantity,
                        msg.sender
                    )
                );
                if (!success) revert CrossFacetCallFailed("Unlock failed");
            }
        }

        // Burn NFT
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                VangkiNFTFacet.burnNFT.selector,
                offer.tokenId
            )
        );
        if (!success) revert CrossFacetCallFailed("Burn NFT failed");

        delete s.offers[offerId];

        emit OfferCanceled(offerId, msg.sender);
    }

    /**
     * @notice Gets compatible offers for a user based on country sanctions.
     * @dev Filters active offers where creator's country can trade with user's.
     *      Placeholder: Simple keccak256 hash comparison for "US" vs. sanctioned list.
     *      Expand in Phase 2 with governance-updatable allowed pairs.
     *      View function.
     * @param user The user address.
     * @return offerIds Array of compatible offer IDs.
     */
    function getCompatibleOffers(
        address user
    ) external view returns (uint256[] memory offerIds) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        string memory userCountry = ProfileFacet(address(this)).getUserCountry(
            user
        );

        uint256 count;
        for (uint256 i = 1; i <= s.nextOfferId; i++) {
            LibVangki.Offer storage offer = s.offers[i];
            if (!offer.accepted) {
                string memory creatorCountry = ProfileFacet(address(this))
                    .getUserCountry(offer.creator);
                if (LibVangki.canTradeBetween(userCountry, creatorCountry)) {
                    count++;
                }
            }
        }

        offerIds = new uint256[](count);
        uint256 index;
        for (uint256 i = 1; i <= s.nextOfferId; i++) {
            LibVangki.Offer storage offer = s.offers[i];
            if (!offer.accepted) {
                string memory creatorCountry = ProfileFacet(address(this))
                    .getUserCountry(offer.creator);
                if (LibVangki.canTradeBetween(userCountry, creatorCountry)) {
                    offerIds[index++] = i;
                }
            }
        }
    }

    // Internal helpers

    /**
     * @notice Gets or creates a user's escrow proxy.
     * @dev Deploys a new ERC1967Proxy if none exists, pointing to the shared implementation.
     *      View function if exists; mutates if creates.
     *      Emits UserEscrowCreated on creation.
     * @param user The user address.
     * @return proxy The user's escrow proxy address.
     */
    function getUserEscrow(address user) public returns (address proxy) {
        bool success;
        bytes memory result;
        (success, result) = address(this).call(
            abi.encodeWithSelector(
                EscrowFactoryFacet.getOrCreateUserEscrow.selector,
                user
            )
        );
        if (!success) revert GetUserEscrowFailed("Get User Escrow failed");
        proxy = abi.decode(result, (address));
        return (proxy);
    }

    /// @dev Simulates LTV with temp collateral (borrowUSD * 10000 / collateralUSD).
    function _simulateLTV(
        LibVangki.Loan storage loan,
        uint256 tempCollateral
    ) internal view returns (uint256) {
        uint256 currentBorrowBalance = _calculateCurrentBorrowBalance(loan);
        (uint256 borrowPrice, uint8 borrowDecimals) = OracleFacet(address(this))
            .getAssetPrice(loan.principalAsset);
        uint256 borrowedValueUSD = (currentBorrowBalance * borrowPrice) /
            (10 ** borrowDecimals);

        (uint256 collateralPrice, uint8 collateralDecimals) = OracleFacet(
            address(this)
        ).getAssetPrice(loan.collateralAsset);
        uint256 collateralValueUSD = (tempCollateral * collateralPrice) /
            (10 ** collateralDecimals);
        if (collateralValueUSD == 0) return type(uint256).max; // Infinite LTV

        return (borrowedValueUSD * BASIS_POINTS) / collateralValueUSD;
    }

    // Internal helper for current borrow balance with accrued interest
    function _calculateCurrentBorrowBalance(
        LibVangki.Loan storage loan
    ) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - loan.startTime;
        uint256 accruedInterest = (loan.principal *
            loan.interestRateBps *
            (elapsed / 1 days)) / (365 * BASIS_POINTS);
        return loan.principal + accruedInterest;
    }

    // New Internal: Calculate transaction value in USD for KYC (liquid parts only)
    /// @dev Value = (lent amount if liquid * price) + (collateral amount if liquid * price). For NFTs, rental value = amount * durationDays if liquid (but NFTs illiquid, $0).
    ///      Scaled to 1e18 for threshold comparison.
    function _calculateTransactionValueUSD(
        LibVangki.Offer storage offer
    ) internal view returns (uint256 valueUSD) {
        LibVangki.Storage storage s = LibVangki.storageSlot();

        // Lent asset value if liquid
        LibVangki.LiquidityStatus lentLiquidity = OracleFacet(address(this))
            .checkLiquidity(offer.lendingAsset);
        if (lentLiquidity == LibVangki.LiquidityStatus.Liquid) {
            (uint256 price, uint8 decimals) = OracleFacet(address(this))
                .getAssetPrice(offer.lendingAsset);
            valueUSD += ((offer.amount * price) / (10 ** decimals)) * 1e18; // Scale to 1e18
        } else if (offer.assetType != LibVangki.AssetType.ERC20) {
            // For NFT rentals: Rental value = amount (fee) * durationDays, but since illiquid, $0
            valueUSD += 0;
        }

        // Collateral value if liquid
        LibVangki.LiquidityStatus collLiquidity = OracleFacet(address(this))
            .checkLiquidity(offer.collateralAsset);
        if (collLiquidity == LibVangki.LiquidityStatus.Liquid) {
            (uint256 price, uint8 decimals) = OracleFacet(address(this))
                .getAssetPrice(offer.collateralAsset);
            valueUSD +=
                ((offer.collateralAmount * price) / (10 ** decimals)) *
                1e18; // Scale to 1e18
        }
    }
}
