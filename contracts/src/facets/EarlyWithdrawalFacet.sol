// src/facets/EarlyWithdrawalFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OracleFacet} from "./OracleFacet.sol"; // For rate/price checks if needed
import {VangkiNFTFacet} from "./VangkiNFTFacet.sol"; // For NFT updates
import {EscrowFactoryFacet} from "./EscrowFactoryFacet.sol"; // For transfers
import {OfferFacet} from "./OfferFacet.sol"; // For offer interactions

/**
 * @title EarlyWithdrawalFacet
 * @author Vangki Developer Team
 * @notice This facet handles early withdrawal by lenders via loan sales (Options 1 & 2 from specs).
 * @dev Part of Diamond Standard (EIP-2535). Uses shared LibVangki storage.
 *      Option 1: Sell via accepting new Lender Offer or new lender accepting sale offer.
 *      Option 2: Create sale as "Borrower Offer".
 *      Forfeits accrued interest to treasury; handles rate shortfalls.
 *      Custom errors, events, ReentrancyGuard. Cross-facet calls for escrow/NFT.
 *      Assumes treasury address in LibVangki (add if needed).
 *      Expand for Phase 2 (e.g., auctions).
 */
contract EarlyWithdrawalFacet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Emitted when a loan is sold to a new lender.
    /// @param loanId The ID of the sold loan.
    /// @param originalLender The original lender's address.
    /// @param newLender The new lender's address.
    /// @param shortfallPaid Any shortfall amount paid by original lender.
    event LoanSold(
        uint256 indexed loanId,
        address indexed originalLender,
        address indexed newLender,
        uint256 shortfallPaid
    );

    // Custom errors for gas efficiency and clarity.
    error NotLender();
    error LoanNotActive();
    error InvalidSaleOffer();
    error RateShortfallTooHigh();
    error CrossFacetCallFailed(string reason);

    // Assume treasury address (add to LibVangki.Storage as address treasury;)
    // For now, hardcoded as immutable; make configurable.
    address private immutable TREASURY =
        address(0xb985F8987720C6d76f02909890AA21C11bC6EBCA); // Replace with actual

    /**
     * @notice Allows original lender to sell an active loan by accepting a new Lender Offer.
     * @dev Option 1: Liam accepts Noah's Lender Offer. Transfers principal, forfeits accrued to treasury,
     *      calculates/pays shortfall if rates differ. Updates NFTs, loan lender.
     *      Callable only by original lender. Emits LoanSold.
     * @param loanId The active loan ID to sell.
     * @param buyOfferId The new Lender Offer ID from Noah.
     */
    function sellLoanViaBuyOffer(
        uint256 loanId,
        uint256 buyOfferId
    ) external nonReentrant {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];
        if (loan.lender != msg.sender) revert NotLender();
        if (loan.status != LibVangki.LoanStatus.Active) revert LoanNotActive();

        LibVangki.Offer storage buyOffer = s.offers[buyOfferId];
        if (
            buyOffer.offerType != LibVangki.OfferType.Lender ||
            buyOffer.accepted
        ) revert InvalidSaleOffer();

        // Calculate accrued interest (forfeit to treasury)
        uint256 elapsed = block.timestamp - loan.startTime;
        uint256 accrued = (loan.principal * loan.interestRateBps * elapsed) /
            (365 days * LibVangki.BASIS_POINTS);
        uint256 remainingDays = loan.durationDays - (elapsed / 1 days);

        // Calculate shortfall if new rate > original (Liam pays difference for remaining term)
        uint256 originalRemainingInterest = (loan.principal *
            loan.interestRateBps *
            remainingDays) / (365 * LibVangki.BASIS_POINTS);
        uint256 newRemainingInterest = (loan.principal *
            buyOffer.interestRateBps *
            remainingDays) / (365 * LibVangki.BASIS_POINTS);
        uint256 shortfall = 0;
        if (newRemainingInterest > originalRemainingInterest) {
            shortfall = newRemainingInterest - originalRemainingInterest;
            // Offset with accrued (specs: use accrued first, Liam pays remainder)
            if (accrued >= shortfall) {
                uint256 excessAccrued = accrued - shortfall;
                _transferToTreasury(loan.principalAsset, excessAccrued); // Excess to treasury
                accrued = 0; // All used
            } else {
                uint256 remainingShortfall = shortfall - accrued;
                IERC20(loan.principalAsset).safeTransferFrom(
                    msg.sender,
                    loan.lender,
                    remainingShortfall
                );
                shortfall = remainingShortfall; // For event
                accrued = 0;
            }
        } else {
            // No shortfall; all accrued to treasury
            _transferToTreasury(loan.principalAsset, accrued);
        }

        // Transfer principal from new lender (Noah) to original (Liam)
        bool success;
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                EscrowFactoryFacet.escrowWithdrawERC20.selector,
                buyOffer.creator, // Noah
                loan.principalAsset,
                msg.sender, // Liam
                loan.principal
            )
        );
        if (!success) revert CrossFacetCallFailed("Principal transfer failed");

        // Update loan: new lender = Noah
        loan.lender = buyOffer.creator;

        // Update NFTs: Burn old lender NFT, mint new for Noah
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                VangkiNFTFacet.burnNFT.selector,
                loan.lenderTokenId
            )
        );
        if (!success) revert CrossFacetCallFailed("Burn old NFT failed");

        // Mint new NFT for Noah (lender role, active)
        uint256 newTokenId;
        unchecked {
            newTokenId = ++s.nextTokenId;
        }
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                VangkiNFTFacet.mintNFT.selector,
                buyOffer.creator,
                newTokenId,
                "Lender" // Role
            )
        );
        if (!success) revert CrossFacetCallFailed("Mint new NFT failed");
        loan.lenderTokenId = newTokenId; // Update loan struct

        // Mark buyOffer accepted
        buyOffer.accepted = true;

        emit LoanSold(loanId, msg.sender, buyOffer.creator, shortfall);
    }

    /**
     * @notice Allows original lender to create a sale offer mimicking a Borrower Offer (Option 2).
     * @dev Liam creates offer for his loan position; new lender accepts via OfferFacet.acceptOffer.
     *      Terms: Remaining duration, same assets/collateral. Links offer to loan via new mapping.
     *      Callable only by original lender. No event here (emitted on acceptance in OfferFacet).
     * @param loanId The loan ID to sell.
     * @param interestRateBps The sale interest rate (may differ from original).
     * @param illiquidConsent Consent for illiquid assets (if applicable).
     */
    function createLoanSaleOffer(
        uint256 loanId,
        uint256 interestRateBps,
        bool illiquidConsent
    ) external nonReentrant {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];
        if (loan.lender != msg.sender) revert NotLender();
        if (loan.status != LibVangki.LoanStatus.Active) revert LoanNotActive();

        // Calculate remaining days
        uint256 elapsed = block.timestamp - loan.startTime;
        uint256 remainingDays;
        unchecked {
            remainingDays = loan.durationDays - (elapsed / 1 days);
        }

        // Create mimicking Borrower Offer via cross-facet call
        bool success;
        bytes memory result;
        (success, result) = address(this).call(
            abi.encodeWithSelector(
                OfferFacet.createOffer.selector,
                LibVangki.OfferType.Borrower, // Mimic Borrower for sale
                loan.principalAsset,
                loan.principal,
                interestRateBps,
                loan.collateralAsset,
                loan.collateralAmount,
                remainingDays,
                loan.assetType,
                loan.tokenId,
                loan.quantity,
                illiquidConsent
            )
        );
        if (!success) revert CrossFacetCallFailed("Sale offer creation failed");

        // Link sale offer to loan (assume added mapping in LibVangki: mapping(uint256 => uint256) loanToSaleOfferId;)
        uint256 saleOfferId = abi.decode(result, (uint256)); // Assume createOffer returns id
        s.loanToSaleOfferId[loanId] = saleOfferId;
    }

    // Internal helpers
    /**
     * @dev Transfers amount to treasury and updates balance.
     * @param asset The ERC-20 asset.
     * @param amount The amount to transfer.
     */
    function _transferToTreasury(address asset, uint256 amount) internal {
        if (amount == 0) return;
        LibVangki.Storage storage s = LibVangki.storageSlot();
        unchecked {
            s.treasuryBalances[asset] += amount;
        }
        IERC20(asset).safeTransfer(TREASURY, amount);
    }
}
