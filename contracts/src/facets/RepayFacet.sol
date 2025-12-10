// src/facets/RepayFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {VangkiNFTFacet} from "./VangkiNFTFacet.sol"; // For NFT updates and burns
import {EscrowFactoryFacet} from "./EscrowFactoryFacet.sol"; // For escrow selectors

/**
 * @title RepayFacet
 * @author Vangki Developer Team
 * @notice This facet handles loan repayment and closure in the Vangki P2P lending platform.
 * @dev Split from LoanFacet for modularity. Uses shared LibVangki storage.
 *      Calculates interest/late fees, distributes to lender/treasury, releases collateral.
 *      For NFT lending: Resets renter on repay.
 *      Custom errors, ReentrancyGuard, events.
 *      Expand for Phase 2 (e.g., partial repayments).
 */
contract RepayFacet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Emitted when a loan is successfully repaid.
    /// @param loanId The ID of the repaid loan.
    event LoanRepaid(uint256 indexed loanId);

    // Custom errors for clarity and gas efficiency.
    error NotBorrower();
    error InvalidLoanStatus();
    error RepaymentPastGracePeriod();
    error CrossFacetCallFailed(string reason);

    /**
     * @notice Repays a loan, including principal, interest, and any late fees.
     * @dev Calculates interest using seconds-based accrual.
     *      Applies late fees if past due but within grace period.
     *      Distributes: Principal + 99% interest/late to lender; 1% to treasury.
     *      Releases collateral from borrower's escrow.
     *      For NFT lending: Resets renter (setUser to 0), returns if held (ERC1155).
     *      Updates loan status to Repaid, burns NFTs.
     *      Emits LoanRepaid.
     *      Callable only by borrower.
     * @param loanId The active loan ID to repay.
     */
    function repayLoan(uint256 loanId) external nonReentrant {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];
        if (loan.borrower != msg.sender) revert NotBorrower();
        if (loan.status != LibVangki.LoanStatus.Active)
            revert InvalidLoanStatus();

        uint256 endTime = loan.startTime + loan.durationDays * 1 days;
        uint256 graceEnd = endTime + LibVangki.gracePeriod(loan.durationDays); // Moved to lib
        if (block.timestamp > graceEnd) revert RepaymentPastGracePeriod();

        // Calculate total due: principal + interest + late fee
        uint256 interest = (loan.principal *
            loan.interestRateBps *
            (block.timestamp - loan.startTime)) / (365 days * 10000);
        uint256 lateFee = LibVangki.calculateLateFee(loanId, endTime); // Moved to lib
        uint256 totalDue = loan.principal + interest + lateFee;

        // Transfer from borrower to Diamond (then distribute)
        IERC20(loan.principalAsset).safeTransferFrom(
            msg.sender,
            address(this),
            totalDue
        );

        // Distribute: Lender gets principal + 99% (interest + late); treasury 1%
        uint256 fees = (interest + lateFee) / 100; // 1%
        s.treasuryBalances[loan.principalAsset] += fees;
        IERC20(loan.principalAsset).safeTransfer(loan.lender, totalDue - fees);

        // Release collateral from borrower's escrow via cross-facet call
        bool success;
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                EscrowFactoryFacet.escrowWithdrawERC20.selector,
                msg.sender,
                loan.collateralAsset,
                msg.sender,
                loan.collateralAmount
            )
        );
        if (!success) revert CrossFacetCallFailed("Collateral release failed");

        // For NFT lending: Reset renter
        if (loan.assetType != LibVangki.AssetType.ERC20) {
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.setNFTUser.selector,
                    loan.lender,
                    loan.principalAsset, // NFT contract
                    loan.tokenId,
                    address(0), // Reset
                    0 // Expire
                )
            );
            if (!success) revert CrossFacetCallFailed("Reset NFT user failed");

            if (loan.assetType == LibVangki.AssetType.ERC1155) {
                (success, ) = address(this).call(
                    abi.encodeWithSelector(
                        EscrowFactoryFacet.escrowWithdrawERC1155.selector,
                        loan.lender,
                        loan.principalAsset,
                        loan.tokenId,
                        loan.quantity,
                        loan.lender
                    )
                );
                if (!success) revert CrossFacetCallFailed("NFT return failed");
            }
        }

        // Update NFTs to "Loan Repaid" and burn (internal call)
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                VangkiNFTFacet.updateNFTStatus.selector,
                loanId,
                "Loan Repaid"
            )
        );
        if (!success) revert CrossFacetCallFailed("NFT update failed");

        (success, ) = address(this).call(
            abi.encodeWithSelector(
                VangkiNFTFacet.burnNFT.selector,
                loan.lenderTokenId
            )
        );
        if (!success) revert CrossFacetCallFailed("Burn lender NFT failed");

        (success, ) = address(this).call(
            abi.encodeWithSelector(
                VangkiNFTFacet.burnNFT.selector,
                loan.borrowerTokenId
            )
        );
        if (!success) revert CrossFacetCallFailed("Burn borrower NFT failed");

        loan.status = LibVangki.LoanStatus.Repaid;

        emit LoanRepaid(loanId);
    }

    /**
     * @notice View function to calculate the repayment amount for a loan.
     * @dev Includes principal, accrued interest, and late fees.
     * @param loanId The loan ID.
     * @return totalDue The total repayment amount.
     */
    function calculateRepaymentAmount(
        uint256 loanId
    ) external view returns (uint256 totalDue) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];

        uint256 endTime = loan.startTime + loan.durationDays * 1 days;
        uint256 interest = (loan.principal *
            loan.interestRateBps *
            (block.timestamp - loan.startTime)) / (365 days * 10000);
        uint256 lateFee = LibVangki.calculateLateFee(loanId, endTime); // Moved to lib
        totalDue = loan.principal + interest + lateFee;
    }
}
