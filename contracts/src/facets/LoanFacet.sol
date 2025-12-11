// src/facets/LoanFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import {RiskFacet} from "./RiskFacet.sol"; // For HF and LTV checks
import {VangkiNFTFacet} from "./VangkiNFTFacet.sol"; // For updates

/**
 * @title LoanFacet
 * @author Vangki Developer Team
 * @notice This facet handles loan initiation and general queries in the Vangki P2P lending platform.
 * @dev New for Phase 1: Called from OfferFacet.acceptOffer to create loans.
 *      Sets loan details, checks initial HF > min (1.5), and LTV <= maxLtvBps.
 *      Updates NFTs to "Loan Active".
 *      Custom errors, ReentrancyGuard, Pausable.
 *      Events for loan creation.
 *      Gas optimized: Unchecked for IDs.
 *      Enhanced: Explicit revert for illiquid assets (NonLiquidAsset) before LTV/HF checks, as illiquid have $0 value per specs.
 */
contract LoanFacet is ReentrancyGuard, Pausable {
    /// @notice Emitted when a new loan is initiated.
    /// @param loanId The unique ID of the loan.
    /// @param offerId The associated offer ID.
    /// @param lender The lender's address.
    /// @param borrower The borrower's address.
    event LoanInitiated(
        uint256 indexed loanId,
        uint256 indexed offerId,
        address indexed lender,
        address borrower
    );

    // Custom errors for clarity and gas efficiency.
    error InvalidOffer();
    error HealthFactorTooLow();
    error LTVExceeded(); // For LTV validation
    error NonLiquidAsset(); // New: Explicit revert for illiquid assets
    error CrossFacetCallFailed(string reason);

    /**
     * @notice Initiates a loan after offer acceptance.
     * @dev Internal: Called by OfferFacet. Sets loan struct, checks HF and LTV.
     *      Updates NFTs to active loan status.
     *      Reverts if paused, low HF, high LTV, or illiquid asset (NonLiquidAsset).
     *      Emits LoanInitiated.
     * @param offerId The accepted offer ID.
     * @param acceptor The acceptor address (borrower or lender based on offerType).
     * @return loanId The new loan ID.
     */
    function initiateLoan(
        uint256 offerId,
        address acceptor
    ) external nonReentrant whenNotPaused returns (uint256 loanId) {
        if (msg.sender != address(this))
            revert CrossFacetCallFailed("Unauthorized"); // Only via Diamond

        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Offer storage offer = s.offers[offerId];
        if (offer.id == 0 || offer.accepted) revert InvalidOffer();

        // New: Explicit revert if illiquid (specs: $0 value, no LTV/HF)
        if (offer.liquidity != LibVangki.LiquidityStatus.Liquid)
            revert NonLiquidAsset();

        unchecked {
            loanId = ++s.nextLoanId;
        }

        LibVangki.Loan storage loan = s.loans[loanId];
        loan.id = loanId;
        loan.offerId = offerId;
        loan.startTime = block.timestamp;
        loan.durationDays = offer.durationDays;
        loan.interestRateBps = offer.interestRateBps;
        loan.principal = offer.amount;
        loan.collateralAmount = offer.collateralAmount;
        loan.principalAsset = offer.lendingAsset;
        loan.collateralAsset = offer.collateralAsset;
        loan.tokenId = offer.tokenId;
        loan.quantity = offer.quantity;
        loan.assetType = offer.assetType;
        loan.status = LibVangki.LoanStatus.Active;
        loan.liquidity = offer.liquidity; // Copy from offer
        loan.useFullTermInterest = offer.useFullTermInterest; // Assume added to Offer if per-loan
        loan.prepayAsset = offer.prepayAsset;

        if (offer.offerType == LibVangki.OfferType.Lender) {
            loan.lender = offer.creator;
            loan.borrower = acceptor;
        } else {
            loan.lender = acceptor;
            loan.borrower = offer.creator;
        }

        // Check initial LTV <= maxLtvBps via cross-facet staticcall
        (bool ltvSuccess, bytes memory ltvResult) = address(this).staticcall(
            abi.encodeWithSelector(RiskFacet.calculateLTV.selector, loanId)
        );
        if (!ltvSuccess) revert CrossFacetCallFailed("LTV check failed");
        uint256 ltv = abi.decode(ltvResult, (uint256));
        uint256 maxLtvBps = s.assetRiskParams[loan.collateralAsset].maxLtvBps;
        if (ltv > maxLtvBps) revert LTVExceeded();

        // Check initial HF
        (bool hfSuccess, bytes memory hfResult) = address(this).staticcall(
            abi.encodeWithSelector(
                RiskFacet.calculateHealthFactor.selector,
                loanId
            )
        );
        if (!hfSuccess) revert CrossFacetCallFailed("HF check failed");
        uint256 hf = abi.decode(hfResult, (uint256));
        if (hf < 150 * 1e16) revert HealthFactorTooLow(); // Min 1.5

        // Update NFTs to active loan status
        (bool success, ) = address(this).call(
            abi.encodeWithSelector(
                VangkiNFTFacet.updateNFTStatus.selector,
                loanId, // Use loanId for NFTs post-accept
                "Loan Active"
            )
        );
        if (!success) revert CrossFacetCallFailed("NFT update failed");

        emit LoanInitiated(loanId, offerId, loan.lender, loan.borrower);
    }

    /**
     * @notice Gets details of a loan.
     * @dev View function for off-chain queries.
     * @param loanId The loan ID.
     * @return loan The Loan struct.
     */
    function getLoanDetails(
        uint256 loanId
    ) external view returns (LibVangki.Loan memory loan) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        return s.loans[loanId];
    }
}
