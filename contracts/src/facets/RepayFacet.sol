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
import {RiskFacet} from "./RiskFacet.sol"; // For post-repay HF check
import {OracleFacet} from "./OracleFacet.sol"; // For value checks if needed

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
 *      Enhanced for NFT rentals: Treats "interest" as rental fee; deducts pro-rata (or full) from prepay held in escrow.
 *      New: Partial repayments via repayPartial (reduces principal/duration/prepay).
 *      New: Auto daily deduct for NFTs via autoDeductDaily (permissionless, checks daily elapsed).
 *      Assume added Loan fields: uint256 prepayAmount, uint256 bufferAmount, uint256 lastDeductTime (set in acceptOffer/initiateLoan).
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

    /// @notice Emitted when a partial repayment is made.
    /// @param loanId The ID of the loan.
    /// @param amountRepaid The partial amount repaid (principal or days' fees).
    /// @param newPrincipal The updated principal (for ERC20) or duration (for NFT).
    event PartialRepaid(
        uint256 indexed loanId,
        uint256 amountRepaid,
        uint256 newPrincipal
    );

    /// @notice Emitted when auto daily deduct is triggered for an NFT rental.
    /// @param loanId The ID of the loan.
    /// @param dayFeeDeducted The daily fee deducted.
    event AutoDailyDeducted(uint256 indexed loanId, uint256 dayFeeDeducted);

    // Custom errors for clarity and gas efficiency.
    error NotBorrower();
    error InvalidLoanStatus();
    error RepaymentPastGracePeriod();
    error CrossFacetCallFailed(string reason);
    error InsufficientPrepay();
    error InsufficientPartialAmount();
    error NotDailyYet();
    error HealthFactorTooLow();
    error NotNFTRental();

    // Constants
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant TREASURY_FEE_BPS = 100; // 1%
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant ONE_DAY = 1 days;
    uint256 private constant MIN_HEALTH_FACTOR = 150 * 1e16; // 1.5 scaled to 1e18

    // Assume treasury (hardcoded; move to LibVangki)
    // address private immutable TREASURY =
    //     address(0xb985F8987720C6d76f02909890AA21C11bC6EBCA); // Replace with actual

    /**
     * @notice Repays an active loan in full.
     * @dev Caller must approve totalDue (from calculateRepaymentAmount).
     *      Handles ERC20/NFT differently: For ERC20, pays principal + interest/late.
     *      For NFT, deducts accrued rental from prepay, refunds unused + buffer.
     *      Distributes fees: 99% lender, 1% treasury.
     *      Releases collateral/resets renter, burns NFTs, sets status Repaid.
     *      Reverts if past grace or not borrower.
     *      Emits LoanRepaid.
     *      Callable only by borrower.
     * @param loanId The loan ID to repay.
     */
    function repayLoan(uint256 loanId) external nonReentrant {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];
        if (loan.borrower != msg.sender) revert NotBorrower();
        if (loan.status != LibVangki.LoanStatus.Active)
            revert InvalidLoanStatus();

        uint256 endTime = loan.startTime + loan.durationDays * ONE_DAY;
        uint256 graceEnd = endTime + LibVangki.gracePeriod(loan.durationDays);
        if (block.timestamp > graceEnd) revert RepaymentPastGracePeriod();

        uint256 interest; // Or rental fee
        uint256 lateFee = LibVangki.calculateLateFee(loanId, endTime);
        address treasury = _getTreasury();

        bool success;
        bytes memory result;
        if (loan.assetType == LibVangki.AssetType.ERC20) {
            // ERC20 loan: Interest + late
            if (loan.useFullTermInterest) {
                interest =
                    (loan.principal *
                        loan.interestRateBps *
                        loan.durationDays) /
                    (SECONDS_PER_YEAR * BASIS_POINTS);
            } else {
                uint256 elapsed = block.timestamp - loan.startTime;
                interest =
                    (loan.principal *
                        loan.interestRateBps *
                        (elapsed / ONE_DAY)) /
                    (SECONDS_PER_YEAR * BASIS_POINTS);
            }

            uint256 totalInterest = interest + lateFee;
            uint256 treasuryShare = (totalInterest * TREASURY_FEE_BPS) /
                BASIS_POINTS;
            uint256 lenderShare = totalInterest - treasuryShare;

            // Transfer from borrower
            IERC20(loan.principalAsset).safeTransferFrom(
                msg.sender,
                loan.lender,
                loan.principal + lenderShare
            );
            IERC20(loan.principalAsset).safeTransferFrom(
                msg.sender,
                treasury,
                treasuryShare
            );

            // Release collateral
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
        } else {
            // NFT rental: Deduct full accrued from prepay
            if (loan.prepayAmount == 0) revert InsufficientPrepay();

            uint256 elapsedDays = (block.timestamp - loan.startTime) / ONE_DAY;
            if (loan.useFullTermInterest) {
                interest = loan.principal * loan.durationDays;
            } else {
                interest = loan.principal * elapsedDays;
            }

            uint256 totalDue = interest + lateFee;
            if (totalDue > loan.prepayAmount) revert InsufficientPrepay();

            uint256 treasuryShare = (totalDue * TREASURY_FEE_BPS) /
                BASIS_POINTS;
            uint256 lenderShare = totalDue - treasuryShare;

            // Deduct from prepay in borrower escrow
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowWithdrawERC20.selector,
                    msg.sender, // Borrower
                    loan.prepayAsset,
                    loan.lender,
                    lenderShare
                )
            );
            if (!success)
                revert CrossFacetCallFailed("Lender share transfer failed");

            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowWithdrawERC20.selector,
                    msg.sender,
                    loan.prepayAsset,
                    treasury,
                    treasuryShare
                )
            );
            if (!success)
                revert CrossFacetCallFailed("Treasury share transfer failed");

            // Refund unused prepay + buffer to borrower
            uint256 refund = loan.prepayAmount - totalDue + loan.bufferAmount;
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowWithdrawERC20.selector,
                    msg.sender,
                    loan.prepayAsset,
                    msg.sender,
                    refund
                )
            );
            if (!success) revert CrossFacetCallFailed("Refund failed");

            // Reset renter
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowSetNFTUser.selector,
                    loan.lender,
                    loan.principalAsset,
                    loan.tokenId,
                    address(0),
                    0
                )
            );
            if (!success) revert CrossFacetCallFailed("Reset renter failed");

            // If ERC1155, return tokens to lender
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
                if (!success)
                    revert CrossFacetCallFailed("Return ERC1155 failed");
            }
        }

        // Check post-repay HF (though full repay should improve it)
        (success, result) = address(this).staticcall(
            abi.encodeWithSelector(
                RiskFacet.calculateHealthFactor.selector,
                loanId
            )
        );
        if (!success) revert CrossFacetCallFailed("HF check failed");
        uint256 hf = abi.decode(result, (uint256));
        if (hf < MIN_HEALTH_FACTOR) revert HealthFactorTooLow();

        // Common: Update NFTs and status
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

        emit LoanRepaid(loanId, interest, lateFee);
    }

    /**
     * @notice Makes a partial repayment on an active loan.
     * @dev For ERC20: Repays specified principal amount + accrued interest to date. Updates loan.principal.
     *      For NFT: Repays for specified days (deducts days * amount from prepay), reduces durationDays and prepayAmount.
     *      Distributes accrued fees. No late fees in partial (handled on full).
     *      Checks post-HF >= min. Reverts if insufficient or past grace.
     *      Emits PartialRepaid.
     *      Callable only by borrower.
     * @param loanId The loan ID.
     * @param partialAmount The partial principal (ERC20) or days (NFT) to repay.
     */
    function repayPartial(
        uint256 loanId,
        uint256 partialAmount
    ) external nonReentrant {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];
        if (loan.borrower != msg.sender) revert NotBorrower();
        if (loan.status != LibVangki.LoanStatus.Active)
            revert InvalidLoanStatus();
        if (partialAmount == 0) revert InsufficientPartialAmount();
        uint256 minPartial = (loan.principal *
            s.assetRiskParams[loan.principalAsset].minPartialBps) /
            BASIS_POINTS;
        if (partialAmount < minPartial) revert InsufficientPartialAmount();

        uint256 endTime = loan.startTime + loan.durationDays * ONE_DAY;
        uint256 graceEnd = endTime + LibVangki.gracePeriod(loan.durationDays);
        if (block.timestamp > graceEnd) revert RepaymentPastGracePeriod();
        address treasury = _getTreasury();

        uint256 accrued;
        bool success;
        bytes memory result;
        if (loan.assetType == LibVangki.AssetType.ERC20) {
            // ERC20: Accrued to now + partial principal
            uint256 elapsed = block.timestamp - loan.startTime;
            accrued =
                (loan.principal * loan.interestRateBps * (elapsed / ONE_DAY)) /
                (SECONDS_PER_YEAR * BASIS_POINTS);

            uint256 treasuryShare = (accrued * TREASURY_FEE_BPS) / BASIS_POINTS;
            uint256 lenderShare = accrued - treasuryShare;

            if (partialAmount > loan.principal)
                revert InsufficientPartialAmount();

            // Pay accrued + partial
            IERC20(loan.principalAsset).safeTransferFrom(
                msg.sender,
                loan.lender,
                partialAmount + lenderShare
            );
            IERC20(loan.principalAsset).safeTransferFrom(
                msg.sender,
                treasury,
                treasuryShare
            );

            unchecked {
                loan.principal -= partialAmount;
            }
            loan.startTime = block.timestamp; // Reset accrual start

            emit PartialRepaid(loanId, partialAmount, loan.principal);
        } else {
            // NFT: Deduct for partialDays (partialAmount = days)
            if (partialAmount > loan.durationDays)
                revert InsufficientPartialAmount();

            accrued = loan.principal * partialAmount; // Daily fee * days

            if (accrued > loan.prepayAmount) revert InsufficientPrepay();

            uint256 treasuryShare = (accrued * TREASURY_FEE_BPS) / BASIS_POINTS;
            uint256 lenderShare = accrued - treasuryShare;

            // Deduct from prepay
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowWithdrawERC20.selector,
                    msg.sender,
                    loan.collateralAsset,
                    loan.lender,
                    lenderShare
                )
            );
            if (!success) revert CrossFacetCallFailed("Lender share failed");

            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowWithdrawERC20.selector,
                    msg.sender,
                    loan.collateralAsset,
                    treasury,
                    treasuryShare
                )
            );
            if (!success) revert CrossFacetCallFailed("Treasury share failed");

            unchecked {
                loan.prepayAmount -= accrued;
                loan.durationDays -= partialAmount;
            }

            // Update renter expires if reduced
            uint64 newExpires = uint64(
                loan.startTime + loan.durationDays * ONE_DAY
            );
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowSetNFTUser.selector,
                    loan.lender,
                    loan.principalAsset,
                    loan.tokenId,
                    msg.sender, // Still renter
                    newExpires
                )
            );
            if (!success) revert CrossFacetCallFailed("Update expires failed");

            emit PartialRepaid(loanId, partialAmount, loan.durationDays);
        }

        // Post-repay HF check
        (success, result) = address(this).staticcall(
            abi.encodeWithSelector(
                RiskFacet.calculateHealthFactor.selector,
                loanId
            )
        );
        if (!success) revert CrossFacetCallFailed("HF check failed");
        uint256 hf = abi.decode(result, (uint256));
        if (hf < MIN_HEALTH_FACTOR) revert HealthFactorTooLow();
    }

    /**
     * @notice Permissionless auto deduct for NFT rental daily fee.
     * @dev Callable by anyone after each day (checks lastDeductTime + 1 day <= now).
     *      Deducts one day's fee from prepay to lender (99%) and treasury (1%).
     *      Updates lastDeductTime, reduces prepayAmount and durationDays by 1.
     *      If insufficient prepay, reverts (default via DefaultedFacet).
     *      No incentive yet (Phase 2: Small bounty from treasury).
     *      Reverts if not NFT or not daily yet.
     *      Emits AutoDailyDeducted.
     * @param loanId The NFT rental loan ID.
     */
    function autoDeductDaily(uint256 loanId) external nonReentrant {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];
        if (loan.status != LibVangki.LoanStatus.Active)
            revert InvalidLoanStatus();
        if (loan.assetType == LibVangki.AssetType.ERC20) revert NotNFTRental();

        if (block.timestamp < loan.lastDeductTime + ONE_DAY)
            revert NotDailyYet();

        uint256 dayFee = loan.principal; // Daily rental fee
        if (dayFee > loan.prepayAmount) revert InsufficientPrepay();

        uint256 treasuryShare = (dayFee * TREASURY_FEE_BPS) / BASIS_POINTS;
        uint256 lenderShare = dayFee - treasuryShare;
        address treasury = _getTreasury();

        bool success;
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                EscrowFactoryFacet.escrowWithdrawERC20.selector,
                loan.borrower,
                loan.prepayAsset,
                loan.lender,
                lenderShare
            )
        );
        if (!success) revert CrossFacetCallFailed("Lender deduct failed");

        (success, ) = address(this).call(
            abi.encodeWithSelector(
                EscrowFactoryFacet.escrowWithdrawERC20.selector,
                loan.borrower,
                loan.prepayAsset,
                treasury,
                treasuryShare
            )
        );
        if (!success) revert CrossFacetCallFailed("Treasury deduct failed");

        unchecked {
            loan.prepayAmount -= dayFee;
            loan.durationDays -= 1;
            loan.lastDeductTime += ONE_DAY;
        }

        // Update renter expires
        uint64 newExpires = uint64(
            loan.startTime + loan.durationDays * ONE_DAY
        );
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                EscrowFactoryFacet.escrowSetNFTUser.selector,
                loan.lender,
                loan.principalAsset,
                loan.tokenId,
                loan.borrower,
                newExpires
            )
        );
        if (!success) revert CrossFacetCallFailed("Update expires failed");

        // If duration 0, close loan (optional; or require full repay)
        if (loan.durationDays == 0) {
            loan.status = LibVangki.LoanStatus.Repaid;
            // Burn NFTs, etc. (call internal close logic)
        }

        emit AutoDailyDeducted(loanId, dayFee);
    }

    /**
     * @notice View function to calculate the repayment amount for a loan.
     * @dev Includes principal, configured interest (per-loan flag), and late fees (if applicable).
     *      Enhanced for NFTs: Returns prepay due (accrued rental + late) + refunds unused.
     *      But for repay call, borrower approves total principal (unused refunded internally).
     * @param loanId The loan ID.
     * @return totalDue The total repayment amount (principal + interest + lateFee for ERC20; 0 for NFT as from prepay).
     */
    function calculateRepaymentAmount(
        uint256 loanId
    ) external view returns (uint256 totalDue) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];
        if (loan.status != LibVangki.LoanStatus.Active) return 0;

        uint256 endTime = loan.startTime + loan.durationDays * ONE_DAY;

        // Interest/Rental based on per-loan flag
        uint256 interest;
        uint256 elapsed = block.timestamp - loan.startTime;
        uint256 elapsedDays = elapsed / ONE_DAY;
        if (loan.assetType == LibVangki.AssetType.ERC20) {
            if (loan.useFullTermInterest) {
                interest =
                    (loan.principal *
                        loan.interestRateBps *
                        loan.durationDays) /
                    (SECONDS_PER_YEAR * BASIS_POINTS);
            } else {
                interest =
                    (loan.principal * loan.interestRateBps * elapsedDays) /
                    (SECONDS_PER_YEAR * BASIS_POINTS);
            }
            totalDue = loan.principal + interest;
        } else {
            // NFT: Accrued rental
            if (loan.useFullTermInterest) {
                interest = loan.principal * loan.durationDays;
            } else {
                interest = loan.principal * elapsedDays;
            }
            totalDue = 0; // From prepay; borrower approves principal for safety, but internal deduct
        }

        // Late fee if past endTime
        uint256 lateFee = 0;
        if (block.timestamp > endTime) {
            lateFee = LibVangki.calculateLateFee(loanId, endTime);
        }

        totalDue += lateFee;
    }

    /// @dev Get Treasury Address
    function _getTreasury() internal view returns (address) {
        return LibVangki.storageSlot().treasury;
    }
}
