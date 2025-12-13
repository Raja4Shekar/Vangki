// src/facets/RiskFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import {OracleFacet} from "./OracleFacet.sol"; // For price queries
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol"; // For pausable
import {VangkiNFTFacet} from "./VangkiNFTFacet.sol"; // For NFT updates/burns
import {EscrowFactoryFacet} from "./EscrowFactoryFacet.sol"; // For transfers
import {ProfileFacet} from "./ProfileFacet.sol"; // For KYC if high-value

/**
 * @title RiskFacet
 * @author Vangki Developer Team
 * @notice This facet handles risk parameter management, LTV, Health Factor calculations, and HF-triggered liquidations in the Vangki platform.
 * @dev This contract is part of the Diamond Standard (EIP-2535) and uses shared storage from LibVangki.
 *      Risk parameters (maxLtvBps, liqThresholdBps, liqBonusBps, reserveFactorBps) are stored per asset and updatable by owner/governance.
 *      LTV (current): (currentBorrowBalanceUSD * 10000) / collateralValueUSD in basis points; includes accrued interest.
 *      Health Factor (HF): (collateralValueUSD * liqThresholdBps / 10000) / currentBorrowBalanceUSD; scaled to 1e18.
 *      Current borrow balance = principal + accrued interest (pro-rata time-based).
 *      Interest accrual: (principal * rateBps * elapsedSeconds) / (365 days * 10000).
 *      Uses OracleFacet for USD prices; reverts if non-liquid.
 *      Enhanced: Added HF trigger for liquidation (triggerLiquidation) if HF < 1e18 for liquid assets (permissionless).
 *      Liquidation logic: 0x swap, liqBonus to liquidator, remainder to lender.
 *      Custom errors for gas efficiency. ReentrancyGuard/Pausable for actions.
 *      Events emitted for parameter updates and liquidations.
 *      Expand for multi-asset, variable rates in future.
 *      Initial params set in deployment script.
 *      New: Explicit revert for illiquid assets in LTV/HF calcs and liquidation (NonLiquidAsset error).
 */
contract RiskFacet is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Emitted when an asset's risk parameters are updated.
    /// @param asset The asset address.
    /// @param maxLtvBps New max LTV in basis points.
    /// @param liqThresholdBps New liquidation threshold in basis points.
    /// @param liqBonusBps New liquidation bonus in basis points.
    /// @param reserveFactorBps New reserve factor in basis points.
    event RiskParamsUpdated(
        address indexed asset,
        uint256 maxLtvBps,
        uint256 liqThresholdBps,
        uint256 liqBonusBps,
        uint256 reserveFactorBps
    );

    /// @notice Emitted when a liquidation is triggered via HF.
    /// @param loanId The ID of the liquidated loan.
    /// @param liquidator The caller who triggered.
    /// @param proceeds The recovered amount.
    event HFLiquidationTriggered(
        uint256 indexed loanId,
        address indexed liquidator,
        uint256 proceeds
    );

    // Custom errors for clarity and gas efficiency.
    error InvalidAsset();
    error InvalidLoan();
    error UpdateNotAllowed();
    error NonLiquidAsset();
    error ZeroCollateral();
    error HealthFactorNotLow();
    error LiquidationFailed();
    error InsufficientProceeds();
    error CrossFacetCallFailed(string reason);
    error KYCRequired();

    /**
     * @notice Updates risk parameters for an asset.
     * @dev Callable only by Diamond owner (multi-sig/governance).
     *      Validates params (e.g., liqThreshold > maxLtv).
     *      Emits RiskParamsUpdated.
     * @param asset The asset address (collateral/lending).
     * @param maxLtvBps Max LTV in bps (e.g., 8000 for 80%).
     * @param liqThresholdBps Liquidation threshold in bps (> maxLtv).
     * @param liqBonusBps Liquidation bonus in bps (e.g., 500 for 5%).
     * @param reserveFactorBps Reserve factor in bps.
     */
    function updateRiskParams(
        address asset,
        uint256 maxLtvBps,
        uint256 liqThresholdBps,
        uint256 liqBonusBps,
        uint256 reserveFactorBps
    ) external {
        LibDiamond.enforceIsContractOwner();
        if (asset == address(0)) revert InvalidAsset();
        if (liqThresholdBps <= maxLtvBps) revert UpdateNotAllowed(); // Basic validation

        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.RiskParams storage params = s.assetRiskParams[asset];
        params.maxLtvBps = maxLtvBps;
        params.liqThresholdBps = liqThresholdBps;
        params.liqBonusBps = liqBonusBps;
        params.reserveFactorBps = reserveFactorBps;

        emit RiskParamsUpdated(
            asset,
            maxLtvBps,
            liqThresholdBps,
            liqBonusBps,
            reserveFactorBps
        );
    }

    /**
     * @notice Calculates the current LTV for a loan in basis points.
     * @dev LTV = (borrowedValueUSD * 10000) / collateralValueUSD.
     *      Reverts if collateral illiquid (NonLiquidAsset).
     *      Uses Oracle for prices.
     *      For Vangki Phase 1 single-asset; expand for multi.
     * @param loanId The loan ID.
     * @return ltv The LTV in basis points (e.g., 7500 for 75%).
     */
    function calculateLTV(uint256 loanId) external view returns (uint256 ltv) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];
        if (loan.id == 0 || loan.collateralAmount == 0) revert InvalidLoan();

        // Explicit revert for illiquid
        if (loan.liquidity != LibVangki.LiquidityStatus.Liquid)
            revert NonLiquidAsset();

        uint256 currentBorrowBalance = _calculateCurrentBorrowBalance(loan);
        (uint256 borrowPrice, uint8 borrowDecimals) = OracleFacet(address(this))
            .getAssetPrice(loan.principalAsset);
        uint256 borrowedValueUSD = (currentBorrowBalance * borrowPrice) /
            (10 ** borrowDecimals);

        (uint256 collateralPrice, uint8 collateralDecimals) = OracleFacet(
            address(this)
        ).getAssetPrice(loan.collateralAsset);
        uint256 collateralValueUSD = (loan.collateralAmount * collateralPrice) /
            (10 ** collateralDecimals);
        if (collateralValueUSD == 0) revert ZeroCollateral();

        ltv = (borrowedValueUSD * LibVangki.BASIS_POINTS) / collateralValueUSD;
    }

    /**
     * @notice Calculates the Health Factor (HF) for a loan.
     * @dev HF = (collateralValueUSD * liqThresholdBps / 10000) / currentBorrowBalanceUSD; scaled to 1e18.
     *      Includes accrued interest in borrow balance.
     *      Reverts if collateral illiquid (NonLiquidAsset).
     *      Uses Oracle for prices.
     *      For Vangki Phase 1 single-asset; expand for multi.
     * @param loanId The loan ID.
     * @return healthFactor The HF scaled to 1e18 (e.g., 1.5e18 = 1.5).
     */
    function calculateHealthFactor(
        uint256 loanId
    ) external view returns (uint256 healthFactor) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];
        if (loan.id == 0 || loan.collateralAmount == 0) revert InvalidLoan();

        // Explicit revert for illiquid
        if (loan.liquidity != LibVangki.LiquidityStatus.Liquid)
            revert NonLiquidAsset();

        uint256 currentBorrowBalance = _calculateCurrentBorrowBalance(loan);
        (uint256 borrowPrice, uint8 borrowDecimals) = OracleFacet(address(this))
            .getAssetPrice(loan.principalAsset);
        uint256 borrowValueUSD = (currentBorrowBalance * borrowPrice) /
            (10 ** borrowDecimals);

        (uint256 collateralPrice, uint8 collateralDecimals) = OracleFacet(
            address(this)
        ).getAssetPrice(loan.collateralAsset);
        uint256 collateralValueUSD = (loan.collateralAmount * collateralPrice) /
            (10 ** collateralDecimals);

        uint256 liqThresholdBps = s
            .assetRiskParams[loan.collateralAsset]
            .liqThresholdBps;
        uint256 riskAdjustedCollateral = (collateralValueUSD *
            liqThresholdBps) / LibVangki.BASIS_POINTS;

        if (borrowValueUSD == 0) return type(uint256).max; // Infinite HF if no borrow

        healthFactor =
            (riskAdjustedCollateral * LibVangki.HF_SCALE) /
            borrowValueUSD;
    }

    /**
     * @notice Triggers liquidation if HF < 1e18 for liquid collateral loans.
     * @dev Permissionless (anyone can call). Similar to Aave: Liquidates via 0x swap, applies liqBonus to liquidator.
     *      Checks KYC if bonus > $2k. Updates status to Defaulted, burns NFTs.
     *      For illiquid: Reverts (NonLiquidAsset).
     *      Emits HFLiquidationTriggered.
     * @param loanId The loan ID to liquidate.
     * @param fillData 0x fill data for swap.
     * @param minOutputAmount Min output for slippage.
     */
    function triggerLiquidation(
        uint256 loanId,
        bytes calldata fillData,
        uint256 minOutputAmount
    ) external nonReentrant whenNotPaused {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];
        if (loan.status != LibVangki.LoanStatus.Active) revert InvalidLoan();

        // Check HF < 1e18
        uint256 hf = this.calculateHealthFactor(loanId);
        if (hf >= LibVangki.HF_LIQUIDATION_THRESHOLD)
            revert HealthFactorNotLow();

        // Liquidity check (revert if non-liquid)
        LibVangki.LiquidityStatus liquidity = OracleFacet(address(this))
            .checkLiquidity(loan.collateralAsset);
        if (liquidity != LibVangki.LiquidityStatus.Liquid)
            revert NonLiquidAsset();

        address zeroExProxy = _getZeroExProxy();

        // Liquidate: Withdraw collateral, swap via 0x
        bool success;
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                EscrowFactoryFacet.escrowWithdrawERC20.selector,
                loan.borrower,
                loan.collateralAsset,
                address(this),
                loan.collateralAmount
            )
        );
        if (!success) revert CrossFacetCallFailed("Withdraw failed");

        IERC20(loan.collateralAsset).approve(
            zeroExProxy,
            loan.collateralAmount
        );

        (bool swapSuccess, bytes memory swapResult) = zeroExProxy.call(
            fillData
        );
        if (!swapSuccess) {
            if (swapResult.length > 0) {
                assembly {
                    revert(add(swapResult, 0x20), mload(swapResult))
                }
            } else {
                revert LiquidationFailed();
            }
        }
        uint256 proceeds = abi.decode(swapResult, (uint256));
        if (proceeds < minOutputAmount) revert InsufficientProceeds();

        // Apply liqBonus to liquidator (e.g., 5% of proceeds)
        uint256 liqBonusBps = s
            .assetRiskParams[loan.collateralAsset]
            .liqBonusBps;
        uint256 bonus = (proceeds * liqBonusBps) / LibVangki.BASIS_POINTS;
        IERC20(loan.principalAsset).safeTransfer(msg.sender, bonus);

        // Remainder to lender
        IERC20(loan.principalAsset).safeTransfer(loan.lender, proceeds - bonus);

        // KYC check for liquidator if high value
        (uint256 price, uint8 decimals) = OracleFacet(address(this))
            .getAssetPrice(loan.principalAsset);
        uint256 bonusUSD = (bonus * price) / (10 ** decimals);
        if (
            bonusUSD > LibVangki.KYC_THRESHOLD_USD &&
            !ProfileFacet(address(this)).isKYCVerified(msg.sender)
        ) revert KYCRequired();

        // Close loan
        loan.status = LibVangki.LoanStatus.Defaulted;

        // NFT handling (reset/burn similar to default)
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                VangkiNFTFacet.updateNFTStatus.selector,
                loanId,
                "Loan Liquidated"
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

        emit HFLiquidationTriggered(loanId, msg.sender, proceeds);
    }

    // Internal helper for current borrow balance with accrued interest
    function _calculateCurrentBorrowBalance(
        LibVangki.Loan storage loan
    ) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - loan.startTime;
        uint256 accruedInterest = (loan.principal *
            loan.interestRateBps *
            elapsed) / (LibVangki.SECONDS_PER_YEAR * LibVangki.BASIS_POINTS);
        return loan.principal + accruedInterest;
    }

    /// @dev Get 0x Proxy address
    function _getZeroExProxy() internal view returns (address) {
        return LibVangki.storageSlot().zeroExProxy;
    }
}
