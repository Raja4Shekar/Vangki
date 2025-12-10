// src/facets/OfferFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
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
    error InvalidAssetType();

    /**
     * @notice Creates a new offer for lending or borrowing ERC-20 tokens or NFTs.
     * @dev Locks the appropriate assets in the user's escrow proxy.
     *      Liquidity is determined via an internal call to OracleFacet.
     *      If the asset is illiquid, the user must provide consent.
     *      Emits OfferCreated event.
     *      Reverts on invalid inputs or failed cross-facet calls.
     *      For NFTs: Lender offers rental; approves/locks in escrow.
     * @param offerType The type of offer (Lender or Borrower).
     * @param asset The asset contract (ERC-20 or NFT).
     * @param amount The amount (ERC-20) or quantity (ERC-1155).
     * @param interestRateBps The interest/rental rate in basis points.
     * @param collateralAsset The ERC-20 collateral asset (Phase 1: ERC-20 only).
     * @param collateralAmount The collateral amount.
     * @param durationDays The loan/rental duration in days (min 1).
     * @param illiquidConsent Consent flag for illiquid assets.
     * @param assetType The asset type (ERC20, NFT721, NFT1155).
     * @param tokenId The NFT token ID (for NFT721/1155).
     */
    function createOffer(
        LibVangki.OfferType offerType,
        address asset,
        uint256 amount,
        uint256 interestRateBps,
        address collateralAsset,
        uint256 collateralAmount,
        uint256 durationDays,
        bool illiquidConsent,
        LibVangki.AssetType assetType,
        uint256 tokenId
    ) external nonReentrant {
        if (
            offerType != LibVangki.OfferType.Lender &&
            offerType != LibVangki.OfferType.Borrower
        ) {
            revert InvalidOfferType();
        }
        if (durationDays == 0) {
            revert InvalidDuration();
        }

        LibVangki.Storage storage s = LibVangki.storageSlot();
        uint256 offerId = ++s.nextOfferId;

        LibVangki.Offer storage offer = s.offers[offerId];
        offer.id = offerId;
        offer.creator = msg.sender;
        offer.offerType = offerType;
        offer.lendingAsset = asset;
        offer.amount = amount;
        offer.interestRateBps = interestRateBps;
        offer.collateralAsset = collateralAsset;
        offer.collateralAmount = collateralAmount;
        offer.durationDays = durationDays;
        offer.accepted = false;
        offer.assetType = assetType;
        offer.tokenId = (assetType != LibVangki.AssetType.ERC20) ? tokenId : 0;
        offer.quantity = (assetType == LibVangki.AssetType.ERC1155)
            ? amount
            : (assetType == LibVangki.AssetType.ERC721 ? 1 : 0);

        // Determine liquidity via cross-facet staticcall
        (bool success, bytes memory result) = address(this).staticcall(
            abi.encodeWithSelector(
                OracleFacet.checkLiquidity.selector,
                offerType == LibVangki.OfferType.Lender
                    ? asset
                    : collateralAsset
            )
        );
        if (!success) {
            revert CrossFacetCallFailed("Liquidity check failed");
        }
        offer.liquidity = abi.decode(result, (LibVangki.LiquidityStatus));

        if (
            offer.liquidity == LibVangki.LiquidityStatus.Illiquid &&
            !illiquidConsent
        ) {
            revert IlliquidConsentRequired();
        }

        // Lock assets in creator's escrow via cross-facet call
        if (offerType == LibVangki.OfferType.Lender) {
            if (assetType == LibVangki.AssetType.ERC20) {
                (success, ) = address(this).call(
                    abi.encodeWithSelector(
                        EscrowFactoryFacet.escrowDepositERC20.selector,
                        msg.sender,
                        asset,
                        amount
                    )
                );
                if (!success) {
                    revert CrossFacetCallFailed("ERC20 deposit failed");
                }
            } else if (assetType == LibVangki.AssetType.ERC721) {
                // Approve escrow as operator
                (success, ) = address(this).call(
                    abi.encodeWithSelector(
                        EscrowFactoryFacet.escrowApproveNFT721.selector,
                        msg.sender,
                        asset,
                        tokenId
                    )
                );
                if (!success) {
                    revert CrossFacetCallFailed("NFT721 approve failed");
                }
            } else if (assetType == LibVangki.AssetType.ERC1155) {
                // Deposit to escrow
                (success, ) = address(this).call(
                    abi.encodeWithSelector(
                        EscrowFactoryFacet.escrowDepositERC1155.selector,
                        msg.sender,
                        asset,
                        tokenId,
                        offer.quantity
                    )
                );
                if (!success) {
                    revert CrossFacetCallFailed("NFT1155 deposit failed");
                }
            } else {
                revert InvalidAssetType();
            }
        } else {
            // Borrower offer: Collateral (ERC-20 only Phase 1)
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowDepositERC20.selector,
                    msg.sender,
                    collateralAsset,
                    collateralAmount
                )
            );
            if (!success) {
                revert CrossFacetCallFailed("Collateral deposit failed");
            }
        }

        emit OfferCreated(offerId, msg.sender, offerType);
    }

    /**
     * @notice Accepts an existing offer, initiating a loan or rental.
     * @dev Transfers locked assets, creates a loan, mints NFTs for both parties.
     *      For NFT lending: Sets renter via ERC-4907.
     *      Marks offer as accepted to prevent reuse.
     *      Emits OfferAccepted event.
     *      Reverts if already accepted, own offer, or cross-facet failure.
     * @param offerId The ID of the offer to accept.
     */
    function acceptOffer(uint256 offerId) external nonReentrant {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Offer storage offer = s.offers[offerId];

        if (offer.accepted) {
            revert OfferAlreadyAccepted();
        }
        if (offer.creator == msg.sender) {
            revert CannotAcceptOwnOffer();
        }

        uint256 loanId = ++s.nextLoanId;
        LibVangki.Loan storage loan = s.loans[loanId];
        loan.id = loanId;
        loan.offerId = offerId;
        loan.lender = offer.offerType == LibVangki.OfferType.Lender
            ? offer.creator
            : msg.sender;
        loan.borrower = offer.offerType == LibVangki.OfferType.Lender
            ? msg.sender
            : offer.creator;
        loan.principal = offer.amount;
        loan.principalAsset = offer.lendingAsset;
        loan.interestRateBps = offer.interestRateBps;
        loan.startTime = block.timestamp;
        loan.durationDays = offer.durationDays;
        loan.collateralAsset = offer.collateralAsset;
        loan.collateralAmount = offer.collateralAmount;
        loan.status = LibVangki.LoanStatus.Active;
        loan.assetType = offer.assetType; // Propagate for repayment/default
        loan.tokenId = offer.tokenId;
        loan.quantity = offer.quantity;

        // Transfer assets via cross-facet calls
        bool success;
        if (offer.offerType == LibVangki.OfferType.Lender) {
            if (offer.assetType == LibVangki.AssetType.ERC20) {
                (success, ) = address(this).call(
                    abi.encodeWithSelector(
                        EscrowFactoryFacet.escrowWithdrawERC20.selector,
                        offer.creator,
                        offer.lendingAsset,
                        msg.sender,
                        offer.amount
                    )
                );
                if (!success) {
                    revert CrossFacetCallFailed("Principal transfer failed");
                }
            } else {
                // For NFTs: Set renter (no transfer; access grant)
                uint64 expires = uint64(
                    block.timestamp + offer.durationDays * 1 days
                );
                (success, ) = address(this).call(
                    abi.encodeWithSelector(
                        EscrowFactoryFacet.setNFTUser.selector,
                        offer.creator,
                        offer.lendingAsset,
                        offer.tokenId,
                        loan.borrower,
                        expires
                    )
                );
                if (!success) {
                    revert CrossFacetCallFailed("Set NFT user failed");
                }
            }

            // Borrower deposits collateral (ERC-20 only)
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowDepositERC20.selector,
                    msg.sender,
                    offer.collateralAsset,
                    offer.collateralAmount
                )
            );
            if (!success) {
                revert CrossFacetCallFailed("Collateral deposit failed");
            }
        } else {
            // Borrower offer acceptance: Symmetric logic if needed (Phase 1 focus on lender offers)
        }

        // Mint NFTs for creator and acceptor
        uint256 creatorTokenId = ++s.nextTokenId;
        string memory creatorURI = _generateTokenURI(offerId, true, false); // Creator role, active
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

        uint256 acceptorTokenId = ++s.nextTokenId;
        string memory acceptorURI = _generateTokenURI(offerId, false, false); // Acceptor role, active
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

        // Update loan with tokenIds
        loan.lenderTokenId = offer.offerType == LibVangki.OfferType.Lender
            ? creatorTokenId
            : acceptorTokenId;
        loan.borrowerTokenId = offer.offerType == LibVangki.OfferType.Lender
            ? acceptorTokenId
            : creatorTokenId;

        offer.accepted = true;

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
                if (!success) {
                    revert CrossFacetCallFailed("Withdraw failed");
                }
            } else if (offer.assetType == LibVangki.AssetType.ERC721) {
                // Revoke approval if set (optional; specs don't require)
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
                if (!success) {
                    revert CrossFacetCallFailed("Withdraw failed");
                }
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
                    offerId.toString(),
                    '","role":"',
                    isCreator ? '"creator"' : '"acceptor"',
                    '","status":"',
                    isClosed ? '"closed"' : '"active"',
                    '"}'
                )
            );
    }
}
