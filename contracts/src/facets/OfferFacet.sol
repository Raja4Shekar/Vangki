// src/facets/OfferFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OracleFacet} from "./OracleFacet.sol"; // For selector
import {VangkiNFTFacet} from "./VangkiNFTFacet.sol"; // For selector
import {EscrowFactoryFacet} from "./EscrowFactoryFacet.sol"; // For escrow selectors

/**
 * @title OfferFacet
 * @author Vangki Developer Team
 * @notice This facet handles the creation, acceptance, and cancellation of offers in the Vangki P2P lending platform.
 * @dev This contract is part of the Diamond Standard (EIP-2535) and uses shared storage from LibVangki.
 *      It integrates with per-user escrow proxies for asset locking and OracleFacet for liquidity checks.
 *      Offers are for ERC-20 lending in Phase 1. NFT renting will be added in future facets.
 *      Custom errors are used for gas efficiency. ReentrancyGuard protects against reentrancy attacks.
 *      Events are emitted for all state changes to enable off-chain tracking (e.g., notifications).
 *      If this facet grows, consider splitting into sub-facets like CreateOfferFacet, AcceptOfferFacet, etc.
 *      Cross-facet calls (e.g., to EscrowFactoryFacet) use low-level call on address(this).
 */
contract OfferFacet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Emitted when a new offer is created.
    /// @param offerId The unique ID of the created offer.
    /// @param creator The address of the user creating the offer.
    /// @param offerType The type of offer (Lender or Borrower).
    event OfferCreated(
        uint256 indexed offerId,
        address indexed creator,
        LibVangki.OfferType offerType
    );

    /// @notice Emitted when an offer is accepted, initiating a loan.
    /// @param offerId The ID of the accepted offer.
    /// @param loanId The ID of the newly created loan.
    event OfferAccepted(uint256 indexed offerId, uint256 indexed loanId);

    /// @notice Emitted when an offer is cancelled.
    /// @param offerId The ID of the cancelled offer.
    event OfferCancelled(uint256 indexed offerId);

    // Custom errors for better gas efficiency and clarity.
    error InvalidOfferType();
    error InvalidDuration();
    error OfferAlreadyAccepted();
    error NotOfferCreator();
    error CannotAcceptOwnOffer();
    error IlliquidConsentRequired();
    error InvalidLiquidityStatus();
    error CrossFacetCallFailed(string reason);

    /**
     * @notice Creates a new offer for lending or borrowing ERC-20 tokens.
     * @dev Locks the appropriate assets in the user's escrow proxy.
     *      Liquidity is determined via an internal call to OracleFacet.
     *      If the asset is illiquid, the user must provide consent.
     *      Duration is validated to be between 1 day and 1 year.
     *      Emits OfferCreated event.
     * @param offerType The type of offer: Lender (offering to lend) or Borrower (requesting to borrow).
     * @param lendingAsset The ERC-20 token address for the lending asset.
     * @param amount The amount of the lending asset (principal for lenders, requested amount for borrowers).
     * @param interestRateBps The interest rate in basis points (e.g., 500 for 5%).
     * @param collateralAsset The ERC-20 token address for the collateral (must be single asset per offer).
     * @param collateralAmount The required collateral amount.
     * @param durationDays The loan duration in days (1 to 365).
     * @param illiquidConsent Explicit consent if the asset is determined to be illiquid (true if consenting).
     */
    function createOffer(
        LibVangki.OfferType offerType,
        address lendingAsset,
        uint256 amount,
        uint256 interestRateBps,
        address collateralAsset,
        uint256 collateralAmount,
        uint256 durationDays,
        bool illiquidConsent
    ) external nonReentrant {
        if (
            offerType != LibVangki.OfferType.Lender &&
            offerType != LibVangki.OfferType.Borrower
        ) {
            revert InvalidOfferType();
        }
        if (durationDays < 1 || durationDays > 365) {
            revert InvalidDuration();
        }

        LibVangki.Storage storage s = LibVangki.storageSlot();

        // Determine liquidity status via cross-facet call to OracleFacet
        (bool success, bytes memory result) = address(this).staticcall(
            abi.encodeWithSelector(
                OracleFacet.checkLiquidity.selector,
                lendingAsset
            )
        );
        if (!success) {
            revert CrossFacetCallFailed("Liquidity check failed");
        }
        LibVangki.LiquidityStatus liquidity = abi.decode(
            result,
            (LibVangki.LiquidityStatus)
        );

        if (
            liquidity == LibVangki.LiquidityStatus.Illiquid && !illiquidConsent
        ) {
            revert IlliquidConsentRequired();
        }

        uint256 offerId = ++s.nextOfferId;
        s.offers[offerId] = LibVangki.Offer({
            id: offerId,
            creator: msg.sender,
            offerType: offerType,
            lendingAsset: lendingAsset,
            amount: amount,
            interestRateBps: interestRateBps,
            collateralAsset: collateralAsset,
            collateralAmount: collateralAmount,
            durationDays: durationDays,
            liquidity: liquidity,
            accepted: false
        });

        // Lock assets in user's escrow proxy via cross-facet call
        if (offerType == LibVangki.OfferType.Lender) {
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowDepositERC20.selector,
                    msg.sender,
                    lendingAsset,
                    amount
                )
            );
            if (!success) {
                revert CrossFacetCallFailed("Deposit failed");
            }
        } else {
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowDepositERC20.selector,
                    msg.sender,
                    collateralAsset,
                    collateralAmount
                )
            );
            if (!success) {
                revert CrossFacetCallFailed("Deposit failed");
            }
        }

        emit OfferCreated(offerId, msg.sender, offerType);
    }

    /**
     * @notice Accepts an existing offer, initiating a loan.
     * @dev Determines lender and borrower roles based on offer type.
     *      Locks the acceptor's assets in their escrow.
     *      Transfers principal to the borrower from lender's escrow.
     *      Creates a new loan entry and marks offer as accepted.
     *      Mints Vangki NFTs for both parties via VangkiNFTFacet.
     *      If illiquid, requires consent from acceptor.
     *      Emits OfferAccepted event.
     * @param offerId The ID of the offer to accept.
     * @param illiquidConsent Explicit consent if the offer involves illiquid assets.
     */
    function acceptOffer(
        uint256 offerId,
        bool illiquidConsent
    ) external nonReentrant {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Offer storage offer = s.offers[offerId];
        if (offer.accepted) {
            revert OfferAlreadyAccepted();
        }
        if (offer.creator == msg.sender) {
            revert CannotAcceptOwnOffer();
        }
        if (
            offer.liquidity == LibVangki.LiquidityStatus.Illiquid &&
            !illiquidConsent
        ) {
            revert IlliquidConsentRequired();
        }

        address lender = offer.offerType == LibVangki.OfferType.Lender
            ? offer.creator
            : msg.sender;
        address borrower = offer.offerType == LibVangki.OfferType.Borrower
            ? offer.creator
            : msg.sender;

        // Lock acceptor's assets via cross-facet call
        bool success;
        if (offer.offerType == LibVangki.OfferType.Lender) {
            // Borrower accepting: lock collateral
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowDepositERC20.selector,
                    msg.sender,
                    offer.collateralAsset,
                    offer.collateralAmount
                )
            );
            if (!success) {
                revert CrossFacetCallFailed("Deposit failed");
            }
        } else {
            // Lender accepting: lock principal
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowDepositERC20.selector,
                    msg.sender,
                    offer.lendingAsset,
                    offer.amount
                )
            );
            if (!success) {
                revert CrossFacetCallFailed("Deposit failed");
            }
        }

        // Create loan
        uint256 loanId = ++s.nextLoanId;
        s.loans[loanId] = LibVangki.Loan({
            id: loanId,
            offerId: offerId,
            lender: lender,
            borrower: borrower,
            principal: offer.amount,
            interestRateBps: offer.interestRateBps,
            startTime: block.timestamp,
            durationDays: offer.durationDays,
            collateralAsset: offer.collateralAsset,
            collateralAmount: offer.collateralAmount,
            status: LibVangki.LoanStatus.Active
        });

        offer.accepted = true;

        // Transfer principal to borrower from lender's escrow via cross-facet call
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                EscrowFactoryFacet.escrowWithdrawERC20.selector,
                lender,
                offer.lendingAsset,
                borrower,
                offer.amount
            )
        );
        if (!success) {
            revert CrossFacetCallFailed("Withdraw failed");
        }

        // Mint NFTs for creator and acceptor (internal call to VangkiNFTFacet)
        // Assuming separate tokenId counter; add uint256 nextTokenId to LibVangki.Storage if not present
        uint256 creatorTokenId = ++s.nextTokenId; // Add nextTokenId to Storage if needed
        uint256 acceptorTokenId = ++s.nextTokenId;
        string memory creatorURI = _generateTokenURI(offerId, true, false); // Active, creator role
        string memory acceptorURI = _generateTokenURI(offerId, false, false);

        (success, ) = address(this).call(
            abi.encodeWithSelector(
                VangkiNFTFacet.mintNFT.selector,
                offer.creator,
                creatorTokenId,
                creatorURI
            )
        );
        if (!success) {
            revert CrossFacetCallFailed("Creator NFT mint failed");
        }
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                VangkiNFTFacet.mintNFT.selector,
                msg.sender,
                acceptorTokenId,
                acceptorURI
            )
        );
        if (!success) {
            revert CrossFacetCallFailed("Acceptor NFT mint failed");
        }

        emit OfferAccepted(offerId, loanId);
    }

    /**
     * @notice Cancels an existing offer if not yet accepted.
     * @dev Releases locked assets from the creator's escrow.
     *      Only callable by the offer creator.
     *      Deletes the offer from storage.
     *      Emits OfferCancelled event.
     * @param offerId The ID of the offer to cancel.
     */
    function cancelOffer(uint256 offerId) external nonReentrant {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Offer storage offer = s.offers[offerId];
        if (offer.creator != msg.sender) {
            revert NotOfferCreator();
        }
        if (offer.accepted) {
            revert OfferAlreadyAccepted();
        }

        // Release assets from creator's escrow via cross-facet call
        bool success;
        if (offer.offerType == LibVangki.OfferType.Lender) {
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowWithdrawERC20.selector,
                    msg.sender,
                    offer.lendingAsset,
                    msg.sender,
                    offer.amount
                )
            );
            if (!success) {
                revert CrossFacetCallFailed("Withdraw failed");
            }
        } else {
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowWithdrawERC20.selector,
                    msg.sender,
                    offer.collateralAsset,
                    msg.sender,
                    offer.collateralAmount
                )
            );
            if (!success) {
                revert CrossFacetCallFailed("Withdraw failed");
            }
        }

        delete s.offers[offerId];
        emit OfferCancelled(offerId);
    }

    // Internal helper for generating tokenURI (basic placeholder; expand with IPFS/base64 JSON)
    /// @dev Generates a dynamic tokenURI string (e.g., JSON metadata with status and role).
    ///      Currently a stub; implement base64 encoding for on-chain metadata or IPFS links.
    function _generateTokenURI(
        uint256 offerId,
        bool isCreator,
        bool isClosed
    ) internal pure returns (string memory) {
        // Example: return string(abi.encodePacked("ipfs://Qm...", "/metadata.json?offer=", offerId));
        // Or dynamic: Use base64 library if added, or off-chain pointer.
        return
            string(
                abi.encodePacked(
                    'data:application/json,{"offerId":',
                    offerId,
                    '","role":"',
                    isCreator ? '"creator"' : '"acceptor"',
                    '","status":"',
                    isClosed ? '"closed"' : '"active"',
                    '"}'
                )
            );
    }
}
