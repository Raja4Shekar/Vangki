// src/facets/OfferFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol"; // Added for NFT support
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol"; // Added for NFT support
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
    error CountrySanctioned(); // For sanctions filtering
    error InvalidNFT(); // For NFT validation
    error KYCRequiredForHighValue(); // New: For transaction value > $2k liquid

    // Constants
    uint256 private constant KYC_THRESHOLD_USD = 2000 * 1e18; // $2k scaled (assuming 18 decimals for USD prices)

    /**
     * @notice Creates a new offer for lending or borrowing ERC-20 tokens or NFTs.
     * @dev Locks the appropriate assets in the user's escrow proxy.
     *      Liquidity is determined via an internal call to OracleFacet.
     *      Mints an NFT for the creator representing the offer.
     *      Enhanced: Supports NFT lending (approvals for ERC721, transfer for ERC1155).
     *      Validates rentable NFTs (checks IERC4907 support via try-catch).
     *      Reverts if paused or sanctioned country.
     *      Illiquid Handling: Requires consent if illiquid; sets liquidity flag.
     *      Emits OfferCreated.
     * @param offerType The type of offer (Lender or Borrower).
     * @param asset The lending asset (ERC20/NFT contract).
     * @param amount The amount (principal for ERC20, rental fee for NFT).
     * @param interestRateBps The interest/rental rate in basis points.
     * @param collateralAsset The collateral asset (ERC20 only for Phase 1).
     * @param collateralAmount The collateral amount.
     * @param durationDays The duration in days (min 1, max 365 for Phase 1).
     * @param illiquidConsent Consent for illiquid assets (required if illiquid).
     * @param tokenId Token ID for NFTs (0 for ERC20).
     * @param quantity Quantity for ERC1155 (1 for ERC721, 0 for ERC20).
     * @param assetType The asset type (ERC20, ERC721, ERC1155).
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
        uint256 tokenId,
        uint256 quantity,
        LibVangki.AssetType assetType
    ) external nonReentrant whenNotPaused {
        if (durationDays == 0 || durationDays > 365) revert InvalidDuration();
        if (offerType == LibVangki.OfferType.Lender && amount == 0)
            revert InvalidOfferType(); // Example validation
        if (assetType == LibVangki.AssetType.ERC721 && quantity != 1)
            revert InvalidAssetType();
        if (
            assetType == LibVangki.AssetType.ERC20 &&
            (tokenId != 0 || quantity != 0)
        ) revert InvalidAssetType();

        LibVangki.Storage storage s = LibVangki.storageSlot();
        // New: Check country sanctions (assume userCountry set via ProfileFacet)
        string memory creatorCountry = s.userCountry[msg.sender];
        if (bytes(creatorCountry).length == 0) revert CountrySanctioned(); // Require registration

        uint256 offerId;
        unchecked {
            offerId = ++s.nextOfferId;
        } // Gas opt

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
        offer.tokenId = tokenId;
        offer.quantity = quantity;
        offer.assetType = assetType;

        // Determine liquidity via cross-facet staticcall
        (bool success, bytes memory result) = address(this).staticcall(
            abi.encodeWithSelector(OracleFacet.checkLiquidity.selector, asset)
        );
        if (!success) revert CrossFacetCallFailed("Liquidity check failed");
        offer.liquidity = abi.decode(result, (LibVangki.LiquidityStatus));

        if (
            offer.liquidity != LibVangki.LiquidityStatus.Liquid &&
            !illiquidConsent
        ) revert IlliquidConsentRequired();

        // Lock assets in escrow via cross-facet call
        if (offerType == LibVangki.OfferType.Lender) {
            if (assetType == LibVangki.AssetType.ERC20) {
                IERC20(asset).safeTransferFrom(
                    msg.sender,
                    address(this),
                    amount
                );
                (success, ) = address(this).call(
                    abi.encodeWithSelector(
                        EscrowFactoryFacet.escrowDepositERC20.selector,
                        msg.sender,
                        asset,
                        amount
                    )
                );
            } else if (assetType == LibVangki.AssetType.ERC721) {
                // For rentals: Approve escrow as operator (NFT stays with lender)
                IERC721(asset).approve(
                    getOrCreateUserEscrow(msg.sender),
                    tokenId
                );
                // Validate rentable (try setUser to self and reset)
                try
                    IERC4907(asset).setUser(
                        tokenId,
                        msg.sender,
                        uint64(block.timestamp + 1 days)
                    )
                {} catch {
                    revert InvalidNFT();
                }
                IERC4907(asset).setUser(tokenId, address(0), 0); // Reset test
            } else if (assetType == LibVangki.AssetType.ERC1155) {
                // Transfer to escrow
                IERC1155(asset).safeTransferFrom(
                    msg.sender,
                    getOrCreateUserEscrow(msg.sender),
                    tokenId,
                    quantity,
                    ""
                );
            }
            if (!success) revert CrossFacetCallFailed("Deposit failed");
        } else {
            // Borrower: Lock collateral (ERC20 only Phase 1)
            IERC20(collateralAsset).safeTransferFrom(
                msg.sender,
                address(this),
                collateralAmount
            );
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowDepositERC20.selector,
                    msg.sender,
                    collateralAsset,
                    collateralAmount
                )
            );
            if (!success) revert CrossFacetCallFailed("Deposit failed");
        }

        // Mint NFT for creator via cross-facet call
        (success, result) = address(this).call(
            abi.encodeWithSelector(
                VangkiNFTFacet.mintNFT.selector,
                msg.sender,
                offerId,
                true // isCreator
            )
        );
        if (!success) revert CrossFacetCallFailed("Mint failed");

        emit OfferCreated(offerId, msg.sender, offerType);
    }

    /**
     * @notice Accepts an existing offer, initiating a loan.
     * @dev Transfers assets, mints acceptor NFT, initiates loan via LoanFacet.
     *      Enhanced: Handles NFT rentals (setUser on accept).
     *      Checks country match for sanctions (creator vs acceptor).
     *      Reverts if paused, own offer, or sanctioned.
     *      New Illiquid Handling: Calculates transaction value (liquid lent + collateral in USD); if > $2k, requires KYC for both.
     *      For NFT rentals, value = amount * durationDays if liquid (but NFTs illiquid, $0).
     *      Emits OfferAccepted.
     * @param offerId The ID of the offer to accept.
     */
    function acceptOffer(uint256 offerId) external nonReentrant whenNotPaused {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Offer storage offer = s.offers[offerId];
        if (offer.accepted) revert OfferAlreadyAccepted();
        if (offer.creator == msg.sender) revert CannotAcceptOwnOffer();

        // New: Sanctions check
        string memory acceptorCountry = s.userCountry[msg.sender];
        string memory creatorCountry = s.userCountry[offer.creator];
        if (
            keccak256(bytes(acceptorCountry)) !=
            keccak256(bytes(creatorCountry))
        ) revert CountrySanctioned(); // Simple match; expand for sanction lists

        // New Illiquid Handling: Calculate transaction value for KYC (liquid parts in USD)
        uint256 transactionValueUSD = _calculateTransactionValueUSD(offer);
        if (transactionValueUSD > KYC_THRESHOLD_USD) {
            if (
                !ProfileFacet(address(this)).isKYCVerified(offer.creator) ||
                !ProfileFacet(address(this)).isKYCVerified(msg.sender)
            ) revert KYCRequiredForHighValue();
        }

        bool success;
        if (offer.offerType == LibVangki.OfferType.Lender) {
            // Acceptor is borrower: Lock collateral
            IERC20(offer.collateralAsset).safeTransferFrom(
                msg.sender,
                address(this),
                offer.collateralAmount
            );
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowDepositERC20.selector,
                    msg.sender,
                    offer.collateralAsset,
                    offer.collateralAmount
                )
            );
            if (!success) revert CrossFacetCallFailed("Collateral lock failed");

            // Transfer principal to borrower
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowWithdrawERC20.selector,
                    offer.creator,
                    offer.lendingAsset,
                    msg.sender,
                    offer.amount
                )
            );
            if (!success)
                revert CrossFacetCallFailed("Principal transfer failed");

            // If NFT lending: Set renter (borrower)
            if (offer.assetType != LibVangki.AssetType.ERC20) {
                uint64 expires = uint64(
                    block.timestamp + offer.durationDays * 1 days
                );
                (success, ) = address(this).call(
                    abi.encodeWithSelector(
                        EscrowFactoryFacet.setNFTUser.selector,
                        offer.creator,
                        offer.lendingAsset,
                        offer.tokenId,
                        msg.sender,
                        expires
                    )
                );
                if (!success) revert CrossFacetCallFailed("Set renter failed");
            }
        } else {
            // Acceptor is lender: Lock principal
            if (offer.assetType == LibVangki.AssetType.ERC20) {
                IERC20(offer.lendingAsset).safeTransferFrom(
                    msg.sender,
                    address(this),
                    offer.amount
                );
                (success, ) = address(this).call(
                    abi.encodeWithSelector(
                        EscrowFactoryFacet.escrowDepositERC20.selector,
                        msg.sender,
                        offer.lendingAsset,
                        offer.amount
                    )
                );
            } else if (offer.assetType == LibVangki.AssetType.ERC721) {
                IERC721(offer.lendingAsset).approve(
                    getOrCreateUserEscrow(msg.sender),
                    offer.tokenId
                );
            } else if (offer.assetType == LibVangki.AssetType.ERC1155) {
                IERC1155(offer.lendingAsset).safeTransferFrom(
                    msg.sender,
                    getOrCreateUserEscrow(msg.sender),
                    offer.tokenId,
                    offer.quantity,
                    ""
                );
            }
            if (!success) revert CrossFacetCallFailed("Principal lock failed");

            // Transfer collateral to lender? No, collateral from borrower offer is released to acceptor? Specs: For borrower offer, acceptor (lender) locks principal, borrower gets principal, collateral locked.
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowWithdrawERC20.selector,
                    offer.creator,
                    offer.collateralAsset,
                    offer.creator,
                    offer.collateralAmount // Release to borrower? Specs clarify
                )
            );
            if (!success)
                revert CrossFacetCallFailed("Collateral release failed");

            // Transfer principal to borrower (creator)
            if (offer.assetType == LibVangki.AssetType.ERC20) {
                (success, ) = address(this).call(
                    abi.encodeWithSelector(
                        EscrowFactoryFacet.escrowWithdrawERC20.selector,
                        msg.sender,
                        offer.lendingAsset,
                        offer.creator,
                        offer.amount
                    )
                );
            } // For NFTs: Set user as above
            if (!success)
                revert CrossFacetCallFailed("Principal transfer failed");
        }

        offer.accepted = true;

        // Mint NFT for acceptor
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                VangkiNFTFacet.mintNFT.selector,
                msg.sender,
                offerId,
                false // Not creator
            )
        );
        if (!success) revert CrossFacetCallFailed("Mint failed");

        // Initiate loan via LoanFacet
        bytes memory loanResult;
        (success, loanResult) = address(this).call(
            abi.encodeWithSelector(
                LoanFacet.initiateLoan.selector,
                offerId,
                msg.sender // Acceptor
            )
        );
        if (!success) revert CrossFacetCallFailed("Loan init failed");
        uint256 loanId = abi.decode(loanResult, (uint256));

        emit OfferAccepted(offerId, loanId);
    }

    /**
     * @notice Cancels an existing offer if not accepted.
     * @dev Releases locked assets from escrow.
     *      Enhanced: Handles NFT revokes/resets.
     *      Reverts if paused or not creator.
     *      Emits OfferCancelled.
     * @param offerId The ID of the offer to cancel.
     */
    function cancelOffer(uint256 offerId) external nonReentrant whenNotPaused {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Offer storage offer = s.offers[offerId];
        if (offer.creator != msg.sender) revert NotOfferCreator();
        if (offer.accepted) revert OfferAlreadyAccepted();

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
            }
            if (!success) revert CrossFacetCallFailed("Withdraw failed");
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
            if (!success) revert CrossFacetCallFailed("Withdraw failed");
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

    // Helper to get/create escrow (from EscrowFactoryFacet)
    function getOrCreateUserEscrow(address user) internal returns (address) {
        (bool success, bytes memory result) = address(this).call(
            abi.encodeWithSelector(
                EscrowFactoryFacet.getOrCreateUserEscrow.selector,
                user
            )
        );
        if (!success) revert CrossFacetCallFailed("Escrow creation failed");
        return abi.decode(result, (address));
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
