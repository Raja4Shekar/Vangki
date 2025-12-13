// src/facets/PartialWithdrawalFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OracleFacet} from "./OracleFacet.sol"; // For liquidity check
import {RiskFacet} from "./RiskFacet.sol"; // For LTV and HF calc
import {EscrowFactoryFacet} from "./EscrowFactoryFacet.sol"; // For withdraw

/**
 * @title PartialWithdrawalFacet
 * @author Vangki Developer Team
 * @notice This facet allows borrowers to withdraw partial collateral from active loans if post-withdrawal Health Factor remains above threshold and LTV below max.
 * @dev Part of Diamond Standard (EIP-2535). Uses shared LibVangki storage.
 *      Calculates max withdrawable to maintain min HF (e.g., 150%) and max LTV (e.g., per asset maxLtvBps).
 *      Enhanced: Integrated HF validation post-withdrawal (>= min HF) alongside LTV check.
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
    /// @param newLTV The post-withdrawal LTV (in bps).
    event PartialCollateralWithdrawn(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 amount,
        uint256 newHF,
        uint256 newLTV
    );

    // Custom errors for gas efficiency and clarity.
    error NotBorrower();
    error LoanNotActive();
    error IlliquidAsset();
    error AmountTooHigh();
    error CrossFacetCallFailed(string reason);
    error HealthFactorTooLow();
    error LTVExceeded(); // For post-withdrawal LTV > maxLtvBps

    /**
     * @notice Allows borrower to withdraw partial collateral from an active loan.
     * @dev Checks liquidity (must be liquid), simulates post-HF >= min and post-LTV <= max, withdraws from escrow, updates loan.collateralAmount.
     *      Reverts if illiquid, low HF, or high LTV post-withdrawal.
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

        // Check liquidity: Must be liquid
        (bool liqSuccess, bytes memory liqResult) = address(this).staticcall(
            abi.encodeWithSelector(
                OracleFacet.checkLiquidity.selector,
                loan.collateralAsset
            )
        );
        if (
            !liqSuccess ||
            abi.decode(liqResult, (LibVangki.LiquidityStatus)) !=
            LibVangki.LiquidityStatus.Liquid
        ) revert IlliquidAsset();

        // Simulate post-withdrawal HF and LTV
        uint256 tempCollateral = loan.collateralAmount - amount;
        uint256 simulatedHF = _simulateHF(loan, tempCollateral);
        if (simulatedHF < LibVangki.MIN_HEALTH_FACTOR)
            revert HealthFactorTooLow();

        uint256 simulatedLTV = _simulateLTV(loan, tempCollateral);
        uint256 maxLtvBps = s.assetRiskParams[loan.collateralAsset].maxLtvBps;
        if (simulatedLTV > maxLtvBps) revert LTVExceeded();

        // Withdraw from escrow to borrower
        (bool success, ) = address(this).call(
            abi.encodeWithSelector(
                EscrowFactoryFacet.escrowWithdrawERC20.selector,
                msg.sender,
                loan.collateralAsset,
                msg.sender,
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
            simulatedHF,
            simulatedLTV
        );
    }

    /**
     * @notice View function to calculate the maximum withdrawable collateral amount.
     * @dev Simulates withdrawals to find max amount where HF >= min and LTV <= maxLtvBps.
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

        // Binary search for max amount
        uint256 low = 0;
        uint256 high = loan.collateralAmount;
        while (low < high) {
            uint256 mid = (low + high + 1) / 2; // Ceiling
            uint256 tempCollateral = loan.collateralAmount - mid;

            // Simulate HF and LTV
            uint256 simHF = _simulateHF(loan, tempCollateral);
            uint256 simLTV = _simulateLTV(loan, tempCollateral);
            uint256 maxLtvBps = s
                .assetRiskParams[loan.collateralAsset]
                .maxLtvBps;

            if (simHF >= LibVangki.MIN_HEALTH_FACTOR && simLTV <= maxLtvBps) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        return low;
    }

    // Internal sim helpers (inline RiskFacet logic for tempCollateral; adjust decimals/prices as per Oracle)
    /// @dev Simulates HF with temp collateral (riskAdjusted / borrowUSD * 1e18).
    function _simulateHF(
        LibVangki.Loan storage loan,
        uint256 tempCollateral
    ) internal view returns (uint256) {
        LibVangki.Storage storage s = LibVangki.storageSlot();

        uint256 currentBorrowBalance = _calculateCurrentBorrowBalance(loan);
        (uint256 borrowPrice, uint8 borrowDecimals) = OracleFacet(address(this))
            .getAssetPrice(loan.principalAsset);
        uint256 borrowValueUSD = (currentBorrowBalance * borrowPrice) /
            (10 ** borrowDecimals);

        (uint256 collateralPrice, uint8 collateralDecimals) = OracleFacet(
            address(this)
        ).getAssetPrice(loan.collateralAsset);
        uint256 collateralValueUSD = (tempCollateral * collateralPrice) /
            (10 ** collateralDecimals);

        uint256 liqThresholdBps = s
            .assetRiskParams[loan.collateralAsset]
            .liqThresholdBps;
        uint256 riskAdjustedCollateral = (collateralValueUSD *
            liqThresholdBps) / LibVangki.BASIS_POINTS;

        if (borrowValueUSD == 0) return type(uint256).max;
        return (riskAdjustedCollateral * LibVangki.HF_SCALE) / borrowValueUSD;
    }

    /// @dev Simulates LTV with temp collateral (borrowUSD * 10000 / collateralUSD).
    function _simulateLTV(
        LibVangki.Loan storage loan,
        uint256 tempCollateral
    ) internal view returns (uint256) {
        uint256 currentBorrowBalance = _calculateCurrentBorrowBalance(loan);
        (uint256 borrowPrice, uint8 borrowDecimals) = OracleFacet(address(this))
            .getAssetPrice(loan.principalAsset);
        uint256 borrowedValueUSD = (currentBorrowBalance * borrowPrice) /
            (10 ** borrowDecimals);

        (uint256 collateralPrice, uint8 collateralDecimals) = OracleFacet(
            address(this)
        ).getAssetPrice(loan.collateralAsset);
        uint256 collateralValueUSD = (tempCollateral * collateralPrice) /
            (10 ** collateralDecimals);
        if (collateralValueUSD == 0) return type(uint256).max; // Infinite LTV

        return (borrowedValueUSD * LibVangki.BASIS_POINTS) / collateralValueUSD;
    }

    // Internal helper for current borrow balance with accrued interest
    function _calculateCurrentBorrowBalance(
        LibVangki.Loan storage loan
    ) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - loan.startTime;
        uint256 accruedInterest = (loan.principal *
            loan.interestRateBps *
            (elapsed / 1 days)) / (365 * LibVangki.BASIS_POINTS);
        return loan.principal + accruedInterest;
    }
}
