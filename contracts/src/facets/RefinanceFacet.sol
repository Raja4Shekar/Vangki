// src/facets/RefinanceFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OracleFacet} from "./OracleFacet.sol"; // For Health Factor check
import {VangkiNFTFacet} from "./VangkiNFTFacet.sol"; // For NFT updates
import {EscrowFactoryFacet} from "./EscrowFactoryFacet.sol"; // For collateral/principal transfers
import {RepayFacet} from "./RepayFacet.sol"; // For repayment calc
import {OfferFacet} from "./OfferFacet.sol"; // For new offer acceptance
import {RiskFacet} from "./RiskFacet.sol"; // For HF check

/**
 * @title RefinanceFacet
 * @author Vangki Developer Team
 * @notice This facet handles borrower refinancing to a new lender with better terms.
 * @dev Part of Diamond Standard (EIP-2535). Uses shared LibVangki storage.
 *      Repays old loan using new principal, transfers collateral, handles shortfalls.
 *      Pro-rata interest for old lender (configurable via governance in Phase 2).
 *      Checks post-refinance Health Factor > min threshold (150%).
 *      Custom errors, events, ReentrancyGuard. Cross-facet calls for repayment/offers/NFTs.
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
    error CrossFacetCallFailed(string reason);

    // Constants (configurable via governance in Phase 2)
    uint256 private constant MIN_HEALTH_FACTOR = 150 * 1e16; // 1.5 scaled to 1e18

    // Assume treasury address (add to LibVangki.Storage as address treasury;)
    // For now, hardcoded as immutable; make configurable.
    address private immutable TREASURY =
        address(0xb985F8987720C6d76f02909890AA21C11bC6EBCA); // Replace with actual

    /**
     * @notice Allows borrower to refinance an active loan by accepting a new Borrower Offer.
     * @dev Full process: Accept new offer, use new principal to repay old (principal + interest),
     *      transfer collateral to new loan, pay shortfalls, update NFTs, check post-HF.
     *      Callable only by borrower. Emits LoanRefinanced.
     * @param oldLoanId The existing loan ID to refinance.
     * @param newOfferId The new Borrower Offer ID with better terms.
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
            newOffer.offerType != LibVangki.OfferType.Borrower ||
            newOffer.accepted
        ) revert InvalidRefinanceOffer();

        // Calculate old loan repayment amount (principal + pro-rata interest + late fees if any)
        (bool success, bytes memory result) = address(this).staticcall(
            abi.encodeWithSelector(
                RepayFacet.calculateRepaymentAmount.selector, // Assume added helper in RepayFacet; or inline calc
                oldLoanId
            )
        );
        if (!success) revert CrossFacetCallFailed("Repayment calc failed");
        uint256 repaymentAmount = abi.decode(result, (uint256));

        // Accept new offer (get new principal from new lender)
        (success, ) = address(this).call(
            abi.encodeWithSelector(OfferFacet.acceptOffer.selector, newOfferId)
        );
        if (!success) revert CrossFacetCallFailed("New offer accept failed");
        uint256 newLoanId = s.nextLoanId - 1; // Last created

        // Use new principal to repay old loan (transfer to old lender, treasury split)
        uint256 treasuryFee = repaymentAmount / 100; // 1%
        IERC20(oldLoan.principalAsset).safeTransfer(
            oldLoan.lender,
            repaymentAmount - treasuryFee
        );
        _transferToTreasury(oldLoan.principalAsset, treasuryFee);

        // Calculate shortfall (if new terms < old expected interest for full term)
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

        // Check post-refinance Health Factor
        (success, result) = address(this).staticcall(
            abi.encodeWithSelector(
                RiskFacet.calculateHealthFactor.selector,
                newLoanId
            )
        );
        if (!success) revert CrossFacetCallFailed("HF calc failed");
        uint256 newHF = abi.decode(result, (uint256));
        if (newHF < MIN_HEALTH_FACTOR) revert HealthFactorTooLow();

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
