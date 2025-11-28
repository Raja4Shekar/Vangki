// src/facets/LoanFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OracleFacet} from "./OracleFacet.sol"; // For potential LTV checks (stubbed for now)
import {VangkiNFTFacet} from "./VangkiNFTFacet.sol"; // For NFT updates and burns
import {EscrowFactoryFacet} from "./EscrowFactoryFacet.sol"; // For escrow selectors

/**
 * @title LoanFacet
 * @author Vangki Developer Team
 * @notice This facet handles loan repayment, closure, defaults, and liquidations in the Vangki P2P lending platform.
 * @dev This contract is part of the Diamond Standard (EIP-2535) and uses shared storage from LibVangki.
 *      It integrates with per-user escrow proxies for asset transfers.
 *      Interest is calculated using seconds-based accrual for precision.
 *      Late fees are applied post-due date within grace periods.
 *      Treasury collects 1% of interest and late fees.
 *      For liquid collateral, liquidation is stubbed (integrate DEX like 1inch later).
 *      For illiquid, full collateral transfer on default.
 *      NFTs are updated/burned via VangkiNFTFacet on closure/default.
 *      Custom errors for gas efficiency. ReentrancyGuard protects against attacks.
 *      Events emitted for all state changes.
 *      If this facet grows (e.g., with refinancing), consider splitting into RepayFacet, DefaultFacet, etc.
 */
contract LoanFacet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Emitted when a loan is successfully repaid.
    /// @param loanId The ID of the repaid loan.
    event LoanRepaid(uint256 indexed loanId);

    /// @notice Emitted when a loan defaults.
    /// @param loanId The ID of the defaulted loan.
    event LoanDefaulted(uint256 indexed loanId);

    /// @notice Emitted when a liquidation is triggered for liquid collateral.
    /// @param loanId The ID of the liquidated loan.
    /// @param proceeds The amount recovered from liquidation.
    event LoanLiquidated(uint256 indexed loanId, uint256 proceeds);

    // Custom errors for clarity and gas efficiency.
    error NotBorrower();
    error InvalidLoanStatus();
    error RepaymentPastGracePeriod();
    error NotDefaultedYet();
    error CrossFacetCallFailed(string reason);
    error InsufficientProceeds();
    error LiquidationFailed();

    /**
     * @notice Repays a loan, including principal, interest, and any late fees.
     * @dev Calculates interest using seconds-based accrual.
     *      Applies late fees if past due but within grace period.
     *      Deducts treasury fee (1% of interest + late fees).
     *      Releases collateral to borrower and funds to lender via escrow.
     *      Updates loan status to Repaid and burns NFTs via VangkiNFTFacet.
     *      Only callable by the borrower.
     *      Emits LoanRepaid event.
     * @param loanId The ID of the loan to repay.
     */
    function repayLoan(uint256 loanId) external nonReentrant {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];
        if (loan.borrower != msg.sender) {
            revert NotBorrower();
        }
        if (loan.status != LibVangki.LoanStatus.Active) {
            revert InvalidLoanStatus();
        }

        uint256 durationSeconds = loan.durationDays * 1 days;
        uint256 endTime = loan.startTime + durationSeconds;
        uint256 grace = _gracePeriod(loan.durationDays);
        if (block.timestamp > endTime + grace) {
            revert RepaymentPastGracePeriod();
        }

        // Calculate interest (seconds-based)
        uint256 elapsed = block.timestamp - loan.startTime;
        uint256 interest = (loan.principal * loan.interestRateBps * elapsed) /
            (365 days * 10000); // Basis points / 10000

        // Calculate late fees
        uint256 lateFee = _calculateLateFee(loanId, endTime);

        uint256 totalDue = loan.principal + interest + lateFee;

        LibVangki.Offer storage offer = s.offers[loan.offerId];
        address lendingAsset = offer.lendingAsset;

        // Transfer repayment to lender's escrow (borrower pays)
        IERC20(lendingAsset).safeTransferFrom(
            msg.sender,
            _getUserEscrow(loan.lender),
            totalDue
        );

        // Treasury fee: 1% of interest + late fees
        uint256 treasuryAmount = (interest + lateFee) / 100;
        // Transfer to treasury (stub: send to owner or dedicated address; expand later)
        (bool success, ) = address(this).call(
            abi.encodeWithSelector(
                EscrowFactoryFacet.escrowWithdrawERC20.selector,
                loan.lender,
                lendingAsset,
                LibDiamond.contractOwner(),
                treasuryAmount
            )
        );
        if (!success) {
            revert CrossFacetCallFailed("Treasury transfer failed");
        }

        // Release remaining to lender (principal + interest + late - treasury)
        uint256 lenderAmount = totalDue - treasuryAmount;
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                EscrowFactoryFacet.escrowWithdrawERC20.selector,
                loan.lender,
                lendingAsset,
                loan.lender,
                lenderAmount
            )
        );
        if (!success) {
            revert CrossFacetCallFailed("Lender withdraw failed");
        }

        // Release collateral to borrower
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                EscrowFactoryFacet.escrowWithdrawERC20.selector,
                loan.borrower,
                loan.collateralAsset,
                loan.borrower,
                loan.collateralAmount
            )
        );
        if (!success) {
            revert CrossFacetCallFailed("Collateral release failed");
        }

        loan.status = LibVangki.LoanStatus.Repaid;

        // Update and burn NFTs (internal call to VangkiNFTFacet; assume tokenIds stored or queryable)
        // Stub: Call updateStatus and burn for both parties' NFTs
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                VangkiNFTFacet.updateNFTStatus.selector,
                loanId,
                "Loan Closed"
            ) // Add updateNFTStatus to VangkiNFTFacet if needed
        );
        if (!success) {
            revert CrossFacetCallFailed("NFT update failed");
        }
        // Burn calls similarly (add burnNFT to VangkiNFTFacet)

        emit LoanRepaid(loanId);
    }

    /**
     * @notice Triggers default and handles liquidation or full transfer for a loan past grace period.
     * @dev Callable by anyone (e.g., lender or keeper).
     *      For liquid collateral: Stub for DEX liquidation (integrate 1inch/Balancer later); distribute proceeds.
     *      For illiquid: Full collateral transfer to lender.
     *      Updates loan status to Defaulted.
     *      Updates NFTs via VangkiNFTFacet.
     *      Emits LoanDefaulted and LoanLiquidated (if applicable) events.
     * @param loanId The ID of the loan to default.
     */
    function triggerDefault(uint256 loanId) external nonReentrant {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];
        if (loan.status != LibVangki.LoanStatus.Active) {
            revert InvalidLoanStatus();
        }

        uint256 endTime = loan.startTime + loan.durationDays * 1 days;
        uint256 grace = _gracePeriod(loan.durationDays);
        if (block.timestamp <= endTime + grace) {
            revert NotDefaultedYet();
        }

        LibVangki.Offer storage offer = s.offers[loan.offerId];
        bool success;

        if (offer.liquidity == LibVangki.LiquidityStatus.Liquid) {
            // Liquidation stub: Simulate/Integrate DEX sale (e.g., via 1inch aggregator)
            // For now, assume full collateral value recovered; in reality, call external router
            uint256 proceeds = loan.collateralAmount; // Placeholder; replace with actual sale
            if (proceeds == 0) {
                revert LiquidationFailed();
            }

            // Calculate due (principal + interest + late + penalty; stub penalty 0)
            uint256 interest = (loan.principal *
                loan.interestRateBps *
                (block.timestamp - loan.startTime)) / (365 days * 10000);
            uint256 lateFee = _calculateLateFee(loanId, endTime);
            uint256 totalDue = loan.principal + interest + lateFee;

            // Treasury on interest/late
            uint256 treasuryAmount = (interest + lateFee) / 100;

            if (proceeds < totalDue) {
                // Under-recovery: Lender bears loss (as per doc)
                revert InsufficientProceeds(); // Or handle partial
            }

            // Distribute: Treasury, lender full due - treasury, excess to borrower
            // Stub transfers; use escrowWithdraw from borrower's escrow after "sale"
            uint256 lenderAmount = totalDue - treasuryAmount;
            // Transfer to treasury and lender (simulate)
            uint256 excess = proceeds - totalDue;
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowWithdrawERC20.selector,
                    loan.borrower,
                    loan.collateralAsset,
                    loan.borrower,
                    excess
                )
            );
            if (!success) {
                revert CrossFacetCallFailed("Excess return failed");
            }

            emit LoanLiquidated(loanId, proceeds);
        } else {
            // Illiquid: Full collateral transfer to lender
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowWithdrawERC20.selector,
                    loan.borrower,
                    loan.collateralAsset,
                    loan.lender,
                    loan.collateralAmount
                )
            );
            if (!success) {
                revert CrossFacetCallFailed("Full transfer failed");
            }
        }

        loan.status = LibVangki.LoanStatus.Defaulted;

        // Update NFTs to "Loan Defaulted" (internal call)
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                VangkiNFTFacet.updateNFTStatus.selector,
                loanId,
                "Loan Defaulted"
            )
        );
        if (!success) {
            revert CrossFacetCallFailed("NFT update failed");
        }

        emit LoanDefaulted(loanId);
    }

    // Internal helpers

    /// @dev Calculates the grace period based on loan duration.
    function _gracePeriod(
        uint256 durationDays
    ) internal pure returns (uint256) {
        if (durationDays < 7) return 1 hours;
        if (durationDays < 30) return 1 days;
        if (durationDays < 90) return 3 days;
        if (durationDays < 180) return 1 weeks;
        return 2 weeks;
    }

    /// @dev Calculates late fees: 1% on first day post-due, +0.5% daily, capped at 5% of principal.
    function _calculateLateFee(
        uint256 loanId,
        uint256 endTime
    ) internal view returns (uint256) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];

        if (block.timestamp <= endTime) {
            return 0;
        }

        uint256 daysLate = (block.timestamp - endTime) / 1 days;
        uint256 feePercent = 100 + (daysLate * 50); // 1% + 0.5% per day (in basis points)
        if (feePercent > 500) {
            feePercent = 500; // Cap 5%
        }

        return (loan.principal * feePercent) / 10000; // Basis points
    }

    // Helper to get user escrow (cross-facet staticcall)
    function _getUserEscrow(address user) internal view returns (address) {
        (bool success, bytes memory result) = address(this).staticcall(
            abi.encodeWithSelector(
                EscrowFactoryFacet.getOrCreateUserEscrow.selector,
                user
            )
        );
        if (!success) {
            revert CrossFacetCallFailed("Escrow query failed");
        }
        return abi.decode(result, (address));
    }
}

// ##EOF##
// pragma solidity ^0.8.29;

// import {LibVangki} from "../libraries/LibVangki.sol";
// import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// contract LoanFacet is ReentrancyGuard {
//     using SafeERC20 for IERC20;

//     event LoanRepaid(uint256 indexed loanId);
//     event LoanDefaulted(uint256 indexed loanId);

//     function repayLoan(uint256 loanId) external nonReentrant {
//         LibVangki.Storage storage s = LibVangki.storageSlot();
//         LibVangki.Loan storage loan = s.loans[loanId];
//         require(loan.borrower == msg.sender, "Not borrower");
//         require(loan.status == LibVangki.LoanStatus.Active, "Invalid status");
//         address userVangkiEscrow = s.userVangkiEscrows[msg.sender];

//         uint256 durationSeconds = loan.durationDays * 1 days;
//         uint256 endTime = loan.startTime + durationSeconds;
//         require(
//             block.timestamp <= endTime + gracePeriod(loan.durationDays),
//             "Past grace period"
//         ); // Add grace logic

//         // Calculate interest (seconds-based for precision)
//         uint256 elapsed = block.timestamp - loan.startTime;
//         uint256 interest = (loan.principal * loan.interestRateBps * elapsed) /
//             (365 days * 10000); // Bps = /10000

//         // Add late fees if past due (implement as function)
//         uint256 lateFee = calculateLateFee(loanId); // Stub for now

//         uint256 totalDue = loan.principal + interest + lateFee;
//         address lendingAsset = s.offers[loan.offerId].lendingAsset;

//         IERC20(lendingAsset).safeTransferFrom(
//             msg.sender,
//             userVangkiEscrow,
//             totalDue
//         );

//         // Treasury fee: 1% of interest + late
//         uint256 treasuryFee = (interest + lateFee) / 100;
//         // Transfer to treasury (address payable, or burn/stake later)

//         // Release to lender
//         IERC20(lendingAsset).safeTransfer(loan.lender, totalDue - treasuryFee);

//         // Release collateral
//         IERC20(loan.collateralAsset).safeTransferFrom(
//             userVangkiEscrow,
//             msg.sender,
//             loan.collateralAmount
//         );

//         loan.status = LibVangki.LoanStatus.Repaid;
//         emit LoanRepaid(loanId);
//     }

//     function triggerDefault(uint256 loanId) external nonReentrant {
//         LibVangki.Storage storage s = LibVangki.storageSlot();
//         LibVangki.Loan storage loan = s.loans[loanId];
//         require(loan.status == LibVangki.LoanStatus.Active, "Invalid status");

//         uint256 endTime = loan.startTime + loan.durationDays * 1 days;
//         uint256 grace = gracePeriod(loan.durationDays);
//         require(block.timestamp > endTime + grace, "Not defaulted");

//         if (
//             s.offers[loan.offerId].liquidity == LibVangki.LiquidityStatus.Liquid
//         ) {
//             // Liquidate via DEX (integrate 1inch/Oracle later)
//             // For now, stub: sell collateral, repay lender, excess to borrower
//         } else {
//             // Full transfer for illiquid
//             IERC20(loan.collateralAsset).safeTransfer(
//                 loan.lender,
//                 loan.collateralAmount
//             );
//         }

//         loan.status = LibVangki.LoanStatus.Defaulted;
//         emit LoanDefaulted(loanId);
//     }

//     // Helper functions
//     function gracePeriod(uint256 durationDays) internal pure returns (uint256) {
//         if (durationDays < 7) return 1 hours;
//         if (durationDays < 30) return 1 days;
//         if (durationDays < 90) return 3 days;
//         if (durationDays < 180) return 1 weeks;
//         return 2 weeks;
//     }

//     function calculateLateFee(uint256 loanId) internal view returns (uint256) {
//         // Implement 1% + 0.5%/day, cap 5%
//         // return 0; // Stub
//         LibVangki.Storage storage s = LibVangki.storageSlot();
//         LibVangki.Loan storage loan = s.loans[loanId];
//         // (loan.collateralAmount * 200) / 10000;
//         return (loan.collateralAmount * 200) / 10000;
//     }
// }
