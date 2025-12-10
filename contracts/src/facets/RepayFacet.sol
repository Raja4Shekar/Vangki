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
 *      Enhanced: Interest calculation configurable per-loan via flag in Loan struct (useFullTermInterest).
 *      - If true: Full-term interest (principal * rateBps * durationDays / (365 * 10000)).
 *      - If false: Pro-rata interest (principal * rateBps * elapsedDays / (365 * 10000)).
 *      Adds late fees if past maturity but within grace (1% first day + 0.5%/day, cap 5% of principal).
 *      Distributes 99% of (interest + late fees) to lender, 1% to treasury.
 *      Grace period validation: Reverts if past grace (must default via DefaultedFacet).
 *      Releases collateral, resets NFT renter if applicable, updates/burns NFTs.
 *      Custom errors, ReentrancyGuard, events.
 *      Cross-facet calls for escrow/NFTs.
 *      Gas optimized: Unchecked math where safe, minimal storage reads.
 *      Note: Per-loan flag set during loan initiation (from Offer; see OfferFacet and LoanFacet updates).
 */
contract RepayFacet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Emitted when a loan is successfully repaid.
    /// @param loanId The ID of the repaid loan.
    /// @param interestPaid The interest paid (full-term or pro-rata based on per-loan config).
    /// @param lateFeePaid The late fee paid (if applicable).
    event LoanRepaid(
        uint256 indexed loanId,
        uint256 interestPaid,
        uint256 lateFeePaid
    );

    // Custom errors for clarity and gas efficiency.
    error NotBorrower();
    error InvalidLoanStatus();
    error RepaymentPastGracePeriod();
    error CrossFacetCallFailed(string reason);

    // Constants
    uint256 private constant BASIS_POINTS = 10000; // For bps calculations
    uint256 private constant TREASURY_FEE_BPS = 100; // 1%

    // Assume treasury address (add to LibVangki.Storage as address treasury; hardcoded for now)
    address private immutable TREASURY =
        address(0xb985F8987720C6d76f02909890AA21C11bC6EBCA); // Replace with actual

    /**
     * @notice Repays a loan, including principal, configured interest, and any late fees.
     * @dev Interest: Full-term or pro-rata based on per-loan flag (loan.useFullTermInterest).
     *      If past maturity but within grace, adds late fees.
     *      Distributes: Principal + 99% (interest + late) to lender; 1% to treasury.
     *      Releases collateral from borrower's escrow to borrower.
     *      For NFT lending: Resets renter (setUser to 0), returns if held (ERC1155).
     *      Updates loan status to Repaid, updates and burns NFTs.
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
        uint256 graceEnd = endTime + LibVangki.gracePeriod(loan.durationDays);
        if (block.timestamp > graceEnd) revert RepaymentPastGracePeriod();

        // Calculate interest based on per-loan flag
        uint256 interest;
        if (loan.useFullTermInterest) {
            interest =
                (loan.principal * loan.interestRateBps * loan.durationDays) /
                (365 * BASIS_POINTS);
        } else {
            uint256 elapsed = block.timestamp - loan.startTime;
            interest =
                (loan.principal * loan.interestRateBps * (elapsed / 1 days)) /
                (365 * BASIS_POINTS);
        }

        // Calculate late fee if past maturity
        uint256 lateFee = 0;
        if (block.timestamp > endTime) {
            lateFee = LibVangki.calculateLateFee(loanId, endTime);
        }

        // Total fees = interest + lateFee
        uint256 totalFees = interest + lateFee;
        uint256 treasuryShare = (totalFees * TREASURY_FEE_BPS) / BASIS_POINTS;
        uint256 lenderShare = totalFees - treasuryShare;

        // Transfer from borrower: principal + lenderShare to lender, treasuryShare to treasury
        IERC20(loan.principalAsset).safeTransferFrom(
            msg.sender,
            loan.lender,
            loan.principal + lenderShare
        );
        IERC20(loan.principalAsset).safeTransferFrom(
            msg.sender,
            TREASURY,
            treasuryShare
        );

        // Update treasury balance
        s.treasuryBalances[loan.principalAsset] += treasuryShare;

        // Release collateral to borrower
        bool success;
        if (loan.assetType == LibVangki.AssetType.ERC20) {
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowWithdrawERC20.selector,
                    msg.sender,
                    loan.collateralAsset,
                    msg.sender,
                    loan.collateralAmount
                )
            );
            if (!success)
                revert CrossFacetCallFailed("Collateral release failed");
        } // For NFT collateral: Similar, but specs Phase 1 ERC20 collateral for NFT lending

        // For NFT lending (principal is NFT): Reset renter and return if held
        if (loan.assetType != LibVangki.AssetType.ERC20) {
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.setNFTUser.selector,
                    loan.lender,
                    loan.principalAsset,
                    loan.tokenId,
                    address(0),
                    0
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

        // Update NFTs to "Loan Repaid" and burn
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
                loan.lenderTokenId // Assume fields in Loan struct; adjust if needed
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

        emit LoanRepaid(loanId, interest, lateFee);
    }

    /**
     * @notice View function to calculate the repayment amount for a loan.
     * @dev Includes principal, configured interest (per-loan flag), and late fees (if applicable).
     * @param loanId The loan ID.
     * @return totalDue The total repayment amount (principal + interest + lateFee).
     */
    function calculateRepaymentAmount(
        uint256 loanId
    ) external view returns (uint256 totalDue) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];
        if (loan.status != LibVangki.LoanStatus.Active) return 0;

        uint256 endTime = loan.startTime + loan.durationDays * 1 days;

        // Interest based on per-loan flag
        uint256 interest;
        if (loan.useFullTermInterest) {
            interest =
                (loan.principal * loan.interestRateBps * loan.durationDays) /
                (365 * BASIS_POINTS);
        } else {
            uint256 elapsed = block.timestamp - loan.startTime;
            interest =
                (loan.principal * loan.interestRateBps * (elapsed / 1 days)) /
                (365 * BASIS_POINTS);
        }

        // Late fee if past endTime
        uint256 lateFee = 0;
        if (block.timestamp > endTime) {
            lateFee = LibVangki.calculateLateFee(loanId, endTime);
        }

        totalDue = loan.principal + interest + lateFee;
    }
}
