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
        address(0xb985F8987720C6d76f02909890AA21C11bC6EBCA); // Replace with actual ##Treasury Account## ##**##**##

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
            (365 days * 10000);
        uint256 remainingDays = loan.durationDays - (elapsed / 1 days);

        // Calculate shortfall if new rate > original (Liam pays difference for remaining term)
        uint256 originalRemainingInterest = (loan.principal *
            loan.interestRateBps *
            remainingDays) / (365 * 10000);
        uint256 newRemainingInterest = (loan.principal *
            buyOffer.interestRateBps *
            remainingDays) / (365 * 10000);
        uint256 shortfall = 0;
        if (newRemainingInterest > originalRemainingInterest) {
            shortfall = newRemainingInterest - originalRemainingInterest;
            // Offset with accrued (specs: use accrued first, Liam pays remainder)
            if (accrued >= shortfall) {
                uint256 excessAccrued = accrued - shortfall;
                _transferToTreasury(loan.collateralAsset, excessAccrued); // Excess to treasury
                accrued = 0; // All used
            } else {
                uint256 remainingShortfall = shortfall - accrued;
                IERC20(loan.collateralAsset).safeTransferFrom(
                    msg.sender,
                    address(this),
                    remainingShortfall
                );
                shortfall = remainingShortfall; // For event
                accrued = 0;
            }
        } else {
            // No shortfall; all accrued to treasury
            _transferToTreasury(loan.collateralAsset, accrued);
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

        // Update NFTs: Close Liam's, mint new for Noah
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                VangkiNFTFacet.burnNFT.selector, // Assume burn for closed; or update status
                loan.lenderTokenId
            )
        );
        if (!success) revert CrossFacetCallFailed("Burn old NFT failed");

        uint256 newTokenId = ++s.nextTokenId;
        string memory newURI = _generateSaleURI(loanId, false, false); // Acceptor role, active
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                VangkiNFTFacet.mintNFT.selector,
                buyOffer.creator,
                newTokenId,
                newURI
            )
        );
        if (!success) revert CrossFacetCallFailed("Mint new NFT failed");

        // Mark buyOffer accepted
        buyOffer.accepted = true;

        emit LoanSold(loanId, msg.sender, buyOffer.creator, shortfall);
    }

    /**
     * @notice Allows original lender to create a sale offer as a "Borrower Offer".
     * @dev Option 2: Liam creates offer mimicking borrow request for his loan position.
     *      Specifies terms; new lender accepts it.
     *      Reuses OfferFacet.createOffer internally (cross-facet).
     * @param loanId The loan ID to sell.
     * @param interestRateBps Sale interest rate (may differ).
     */

    //  * @param otherTerms Other params matching specs (duration <= remaining, etc.).
    function createLoanSaleOffer(
        uint256 loanId,
        uint256 interestRateBps
    )
        external
        // Add params: asset, amount, collateral, durationDays, illiquidConsent
        nonReentrant
    {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];
        if (loan.lender != msg.sender) revert NotLender();
        if (loan.status != LibVangki.LoanStatus.Active) revert LoanNotActive();

        // Reuse OfferFacet.createOffer (set as Borrower type, but for sale)
        bool success;
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                OfferFacet.createOffer.selector,
                LibVangki.OfferType.Borrower, // Mimic Borrower for sale
                loan.principalAsset,
                loan.principal,
                interestRateBps,
                loan.collateralAsset,
                loan.collateralAmount,
                loan.durationDays -
                    ((block.timestamp - loan.startTime) / 1 days), // Remaining days
                true // Illiquid consent if needed
            )
        );
        if (!success) revert CrossFacetCallFailed("Sale offer creation failed");

        // Link sale offer to loan (add mapping uint256 loanIdToSaleOfferId in LibVangki if needed)
        // s.loanToSaleOffer[loanId] = s.nextOfferId - 1;
    }

    // Internal helpers
    function _transferToTreasury(address asset, uint256 amount) internal {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        s.treasuryBalances[asset] += amount;
        IERC20(asset).safeTransfer(TREASURY, amount);
    }

    // Stub for URI generation (reuse from VangkiNFTFacet or expand)
    function _generateSaleURI(
        uint256 id,
        bool isCreator,
        bool isClosed
    ) internal pure returns (string memory) {
        // Similar to VangkiNFTFacet._generateTokenURI
        return string(abi.encodePacked("data:application/json,{...}")); // Expand as per specs
    }
}
