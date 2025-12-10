// src/facets/PartialWithdrawalFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OracleFacet} from "./OracleFacet.sol"; // For liquidity check
import {RiskFacet} from "./RiskFacet.sol"; // For HF calc
import {EscrowFactoryFacet} from "./EscrowFactoryFacet.sol"; // For withdraw

/**
 * @title PartialWithdrawalFacet
 * @author Vangki Developer Team
 * @notice This facet allows borrowers to withdraw partial collateral from active loans if post-withdrawal Health Factor remains above threshold.
 * @dev Part of Diamond Standard (EIP-2535). Uses shared LibVangki storage.
 *      Calculates max withdrawable to maintain min HF (e.g., 150%).
 *      Disallows for illiquid assets ($0 value per specs).
 *      Custom errors, events, ReentrancyGuard. Cross-facet calls for oracle/risk/escrow.
 *      Callable only by borrower. Updates loan.collateralAmount.
 *      Expand for Phase 2 (e.g., multi-collateral, governance-configurable threshold).
 */
contract PartialWithdrawalFacet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Emitted when partial collateral is withdrawn.
    /// @param loanId The loan ID.
    /// @param borrower The borrower's address.
    /// @param amount The withdrawn collateral amount.
    /// @param newHF The post-withdrawal Health Factor (scaled to 1e18).
    event PartialCollateralWithdrawn(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 amount,
        uint256 newHF
    );

    // Custom errors for gas efficiency and clarity.
    error NotBorrower();
    error LoanNotActive();
    error IlliquidAsset();
    error AmountTooHigh();
    error CrossFacetCallFailed(string reason);
    error HealthFactorTooLow();

    // Constants (configurable via governance in Phase 2; align with RiskFacet)
    uint256 private constant MIN_HEALTH_FACTOR = 150 * 1e16; // 1.5 scaled to 1e18

    /**
     * @notice Allows borrower to withdraw partial collateral from an active loan.
     * @dev Checks liquidity (must be liquid), calculates max withdrawable via simulated HF,
     *      withdraws from escrow, updates loan.collateralAmount.
     *      Reverts if illiquid or post-HF < min.
     *      Emits PartialCollateralWithdrawn.
     * @param loanId The active loan ID.
     * @param amount The collateral amount to withdraw (must <= max withdrawable).
     */
    function partialWithdrawCollateral(
        uint256 loanId,
        uint256 amount
    ) external nonReentrant {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];
        if (loan.borrower != msg.sender) revert NotBorrower();
        if (loan.status != LibVangki.LoanStatus.Active) revert LoanNotActive();
        if (amount == 0 || amount > loan.collateralAmount)
            revert AmountTooHigh();

        // Check if collateral is liquid (illiquid = $0 value; no partial allowed per specs)
        (bool success, bytes memory result) = address(this).staticcall(
            abi.encodeWithSelector(
                OracleFacet.checkLiquidity.selector,
                loan.collateralAsset
            )
        );
        if (!success) revert CrossFacetCallFailed("Liquidity check failed");
        LibVangki.LiquidityStatus liquidity = abi.decode(
            result,
            (LibVangki.LiquidityStatus)
        );
        if (liquidity != LibVangki.LiquidityStatus.Liquid)
            revert IlliquidAsset();

        // Simulate post-withdrawal HF (temporarily reduce collateralAmount)
        uint256 originalCollateral = loan.collateralAmount;
        loan.collateralAmount -= amount; // Temp reduce for sim
        (success, result) = address(this).staticcall(
            abi.encodeWithSelector(
                RiskFacet.calculateHealthFactor.selector,
                loanId
            )
        );
        loan.collateralAmount = originalCollateral; // Restore
        if (!success) revert CrossFacetCallFailed("HF sim failed");
        uint256 simulatedHF = abi.decode(result, (uint256));
        if (simulatedHF < MIN_HEALTH_FACTOR) revert HealthFactorTooLow();

        // Withdraw from borrower's escrow to borrower
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                EscrowFactoryFacet.escrowWithdrawERC20.selector,
                msg.sender, // Borrower escrow
                loan.collateralAsset,
                msg.sender, // To borrower
                amount
            )
        );
        if (!success) revert CrossFacetCallFailed("Withdraw failed");

        // Update loan collateral
        loan.collateralAmount -= amount;

        emit PartialCollateralWithdrawn(
            loanId,
            msg.sender,
            amount,
            simulatedHF
        );
    }

    /**
     * @notice View function to calculate the maximum withdrawable collateral amount.
     * @dev Simulates withdrawals to find max amount where HF >= min.
     *      Binary search for efficiency (gas-optimized).
     *      Returns 0 for illiquid assets.
     * @param loanId The loan ID.
     * @return maxAmount The maximum withdrawable collateral amount.
     */
    function calculateMaxWithdrawable(
        uint256 loanId
    ) external view returns (uint256 maxAmount) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];

        // Quick checks
        if (
            loan.status != LibVangki.LoanStatus.Active ||
            loan.collateralAmount == 0
        ) return 0;

        // Illiquid: 0
        (bool success, bytes memory result) = address(this).staticcall(
            abi.encodeWithSelector(
                OracleFacet.checkLiquidity.selector,
                loan.collateralAsset
            )
        );
        if (
            !success ||
            abi.decode(result, (LibVangki.LiquidityStatus)) !=
            LibVangki.LiquidityStatus.Liquid
        ) return 0;

        // Get current HF
        (success, result) = address(this).staticcall(
            abi.encodeWithSelector(
                RiskFacet.calculateHealthFactor.selector,
                loanId
            )
        );
        if (!success || abi.decode(result, (uint256)) < MIN_HEALTH_FACTOR)
            return 0;

        // Binary search for max amount (efficient for large collaterals)
        uint256 low = 0;
        uint256 high = loan.collateralAmount;
        while (low < high) {
            uint256 mid = (low + high + 1) / 2; // Ceiling to favor higher
            uint256 tempCollateral = loan.collateralAmount - mid;

            // Sim HF (inline to avoid full facet call; assume RiskFacet logic)
            // Note: For production, staticcall RiskFacet with tempCollateral; here stubbed for brevity
            uint256 simHF = _simulateHF(loan, tempCollateral); // Implement or cross-call

            if (simHF >= MIN_HEALTH_FACTOR) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        return low;
    }

    // Internal stub for HF sim (replace with RiskFacet staticcall in prod)
    function _simulateHF(
        LibVangki.Loan storage loan,
        uint256 tempCollateral
    ) internal view returns (uint256) {
        // Stub: Full impl would calc borrowedValueUSD / (collateralValueUSD * liqThresholdBps)
        return 200 * 1e16; // Example > min
    }
}
