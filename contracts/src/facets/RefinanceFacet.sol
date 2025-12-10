// src/facets/RefinanceFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OracleFacet} from "./OracleFacet.sol"; // For liquidity check
import {VangkiNFTFacet} from "./VangkiNFTFacet.sol"; // For NFT updates
import {EscrowFactoryFacet} from "./EscrowFactoryFacet.sol"; // For collateral/principal transfers
import {RepayFacet} from "./RepayFacet.sol"; // For repayment calc
import {OfferFacet} from "./OfferFacet.sol"; // For new offer acceptance
import {RiskFacet} from "./RiskFacet.sol"; // For HF and LTV checks

/**
 * @title RefinanceFacet
 * @author Vangki Developer Team
 * @notice This facet handles borrower refinancing to a new lender with better terms.
 * @dev Part of Diamond Standard (EIP-2535). Uses shared LibVangki storage.
 *      Repays old loan using new principal, transfers collateral, handles shortfalls.
 *      Pro-rata interest for old lender (configurable via governance in Phase 2).
 *      Enhanced: Checks post-refinance HF >= min (1.5) and LTV <= maxLtvBps via RiskFacet.
 *      Custom errors, events, ReentrancyGuard. Cross-facet calls for repayment/offers/NFTs/risk.
 *      Assumes treasury address in LibVangki (add if needed).
 *      Expand for Phase 2 (e.g., different collateral).
 */
contract RefinanceFacet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Emitted when a loan is refinanced to a new lender.
    /// @param oldLoanId The ID of the original loan.
    /// @param newLoanId The ID of the new refinanced loan.
    /// @param borrower The borrower's address.
    /// @param oldLender The original lender's address.
    /// @param newLender The new lender's address.
    /// @param shortfallPaid Any shortfall amount paid by borrower.
    event LoanRefinanced(
        uint256 indexed oldLoanId,
        uint256 indexed newLoanId,
        address indexed borrower,
        address oldLender,
        address newLender,
        uint256 shortfallPaid
    );

    // Custom errors for gas efficiency and clarity.
    error NotBorrower();
    error LoanNotActive();
    error InvalidRefinanceOffer();
    error HealthFactorTooLow();
    error LTVExceeded(); // New: Post-refinance LTV > max
    error CrossFacetCallFailed(string reason);

    // Constants (configurable via governance in Phase 2)
    uint256 private constant MIN_HEALTH_FACTOR = 150 * 1e16; // 1.5 scaled to 1e18

    // Assume treasury address (add to LibVangki.Storage as address treasury;)
    // For now, hardcoded as immutable; make configurable.
    address private immutable TREASURY =
        address(0xb985F8987720C6d76f02909890AA21C11bC6EBCA); // Replace with actual

    /**
     * @notice Allows borrower to refinance an active loan by accepting a new lender offer.
     * @dev Repays old loan (principal + pro-rata interest) using new principal from new offer.
     *      Handles interest shortfall if new terms lower. Transfers collateral to new escrow.
     *      Enhanced: After new loan initiation, checks new HF >= min and LTV <= maxLtvBps.
     *      Updates NFTs: Closes old, new ones minted in acceptOffer.
     *      Callable only by borrower. Emits LoanRefinanced.
     * @param oldLoanId The current loan ID to refinance.
     * @param newOfferId The new lender offer ID to accept for refinancing.
     */
    function refinanceLoan(
        uint256 oldLoanId,
        uint256 newOfferId
    ) external nonReentrant {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage oldLoan = s.loans[oldLoanId];
        if (oldLoan.borrower != msg.sender) revert NotBorrower();
        if (oldLoan.status != LibVangki.LoanStatus.Active)
            revert LoanNotActive();

        LibVangki.Offer storage newOffer = s.offers[newOfferId];
        if (
            newOffer.offerType != LibVangki.OfferType.Lender ||
            newOffer.accepted
        ) revert InvalidRefinanceOffer();
        if (newOffer.amount < oldLoan.principal) revert InvalidRefinanceOffer(); // Must cover principal

        // Accept new offer (initiates new loan)
        bool success;
        bytes memory result;
        (success, result) = address(this).call(
            abi.encodeWithSelector(OfferFacet.acceptOffer.selector, newOfferId)
        );
        if (!success) revert CrossFacetCallFailed("Accept new offer failed");
        uint256 newLoanId = abi.decode(result, (uint256)); // Assume acceptOffer returns loanId

        // Repay old loan using new principal (transfer to old lender)
        uint256 oldInterest = RepayFacet(address(this))
            .calculateRepaymentAmount(oldLoanId) - oldLoan.principal; // Interest + late
        IERC20(oldLoan.principalAsset).safeTransferFrom(
            msg.sender,
            oldLoan.lender,
            oldLoan.principal + oldInterest
        ); // Specs: Borrower may pay shortfall

        // Handle shortfall if new offer interest lower (full-term comparison)
        uint256 oldExpectedInterest = (oldLoan.principal *
            oldLoan.interestRateBps *
            oldLoan.durationDays) / (365 * 10000);
        uint256 newExpectedInterest = (newOffer.amount *
            newOffer.interestRateBps *
            newOffer.durationDays) / (365 * 10000);
        uint256 shortfall = 0;
        if (newExpectedInterest < oldExpectedInterest) {
            shortfall = oldExpectedInterest - newExpectedInterest;
            IERC20(oldLoan.principalAsset).safeTransferFrom(
                msg.sender,
                oldLoan.lender,
                shortfall
            );
        }

        // Transfer collateral from old escrow to new (or release and re-lock)
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                EscrowFactoryFacet.escrowWithdrawERC20.selector,
                msg.sender, // Borrower escrow
                oldLoan.collateralAsset,
                address(this), // Temp hold
                oldLoan.collateralAmount
            )
        );
        if (!success) revert CrossFacetCallFailed("Collateral withdraw failed");

        (success, ) = address(this).call(
            abi.encodeWithSelector(
                EscrowFactoryFacet.escrowDepositERC20.selector,
                msg.sender,
                oldLoan.collateralAsset,
                oldLoan.collateralAmount
            )
        );
        if (!success) revert CrossFacetCallFailed("Collateral deposit failed");

        // New: Check post-refinance HF >= min
        (success, result) = address(this).staticcall(
            abi.encodeWithSelector(
                RiskFacet.calculateHealthFactor.selector,
                newLoanId
            )
        );
        if (!success) revert CrossFacetCallFailed("HF calc failed");
        uint256 newHF = abi.decode(result, (uint256));
        if (newHF < MIN_HEALTH_FACTOR) revert HealthFactorTooLow();

        // New: Check post-refinance LTV <= maxLtvBps
        (success, result) = address(this).staticcall(
            abi.encodeWithSelector(RiskFacet.calculateLTV.selector, newLoanId)
        );
        if (!success) revert CrossFacetCallFailed("LTV calc failed");
        uint256 newLTV = abi.decode(result, (uint256));
        uint256 maxLtvBps = s
            .assetRiskParams[oldLoan.collateralAsset]
            .maxLtvBps; // Assume same collateral
        if (newLTV > maxLtvBps) revert LTVExceeded();

        // Update NFTs: Close old, new ones already minted in acceptOffer
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                VangkiNFTFacet.updateNFTStatus.selector,
                oldLoanId,
                "Loan Closed" // Or burn
            )
        );
        if (!success) revert CrossFacetCallFailed("Old NFT update failed");

        // Mark old loan closed
        oldLoan.status = LibVangki.LoanStatus.Repaid;

        emit LoanRefinanced(
            oldLoanId,
            newLoanId,
            msg.sender,
            oldLoan.lender,
            newOffer.creator,
            shortfall
        );
    }

    // Internal helpers
    function _transferToTreasury(address asset, uint256 amount) internal {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        s.treasuryBalances[asset] += amount;
        IERC20(asset).safeTransfer(TREASURY, amount);
    }
}
