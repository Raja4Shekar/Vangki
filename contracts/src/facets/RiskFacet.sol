// src/facets/RiskFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import {OracleFacet} from "./OracleFacet.sol"; // For price queries

/**
 * @title RiskFacet
 * @author Vangki Developer Team
 * @notice This facet handles risk parameter management, LTV, Health Factor calculations, and Aave-like risk logic in the Vangki platform.
 * @dev This contract is part of the Diamond Standard (EIP-2535) and uses shared storage from LibVangki.
 *      Risk parameters (maxLtvBps, liqThresholdBps, liqBonusBps, reserveFactorBps) are stored per asset and updatable by owner/governance.
 *      LTV (current): (currentBorrowBalanceUSD * 10000) / collateralValueUSD in basis points; includes accrued interest.
 *      Health Factor (HF): (collateralValueUSD * liqThresholdBps / 10000) / currentBorrowBalanceUSD; scaled to 1e18.
 *      Current borrow balance = principal + accrued interest (pro-rata time-based).
 *      Interest accrual: (principal * rateBps * elapsedSeconds) / (365 days * 10000).
 *      Uses OracleFacet for USD prices; reverts if non-liquid.
 *      Custom errors for gas efficiency. No reentrancy as view/update functions.
 *      Events emitted for parameter updates.
 *      Expand for multi-asset, variable rates in future.
 *      Initial params set in deployment script.
 */
contract RiskFacet {
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

    // Custom errors for clarity and gas efficiency.
    error InvalidAsset();
    error InvalidLoan();
    error UpdateNotAllowed();
    error NonLiquidAsset();
    error ZeroCollateral();

    // Constants
    uint256 private constant BASIS_POINTS = 10000; // For bps calculations
    uint256 private constant SECONDS_PER_YEAR = 365 days; // For interest accrual
    uint256 private constant HF_SCALE = 1e18; // Health Factor precision

    /**
     * @notice Updates risk parameters for an asset.
     * @dev Callable only by Diamond owner (multi-sig/governance).
     *      Validates params (e.g., maxLtvBps <= liqThresholdBps <= 10000 bps).
     *      Emits RiskParamsUpdated event.
     * @param asset The ERC20 asset address.
     * @param maxLtvBps Max LTV in basis points (0-10000).
     * @param liqThresholdBps Liquidation threshold in basis points (0-10000).
     * @param liqBonusBps Liquidation bonus in basis points (0-10000).
     * @param reserveFactorBps Reserve factor in basis points (0-10000).
     */
    function updateAssetRiskParams(
        address asset,
        uint256 maxLtvBps,
        uint256 liqThresholdBps,
        uint256 liqBonusBps,
        uint256 reserveFactorBps
    ) external {
        LibDiamond.enforceIsContractOwner();
        if (
            asset == address(0) ||
            maxLtvBps > liqThresholdBps ||
            liqThresholdBps > BASIS_POINTS
        ) {
            revert UpdateNotAllowed();
        }
        LibVangki.Storage storage s = LibVangki.storageSlot();
        s.assetRiskParams[asset] = LibVangki.RiskParams({
            maxLtvBps: maxLtvBps,
            liqThresholdBps: liqThresholdBps,
            liqBonusBps: liqBonusBps,
            reserveFactorBps: reserveFactorBps
        });
        emit RiskParamsUpdated(
            asset,
            maxLtvBps,
            liqThresholdBps,
            liqBonusBps,
            reserveFactorBps
        );
    }

    /**
     * @notice Calculates the current Loan-to-Value (LTV) ratio for a loan in basis points.
     * @dev Current LTV = (currentBorrowBalanceUSD * 10000) / collateralValueUSD.
     *      Includes accrued interest in borrow balance.
     *      Uses Oracle for prices; 0 for illiquid/NFT collateral.
     *      For Vangki Phase 1 single-asset; expand for multi.
     * @param loanId The loan ID.
     * @return ltv The current LTV in basis points (e.g., 7500 = 75%).
     */
    function calculateCurrentLTV(
        uint256 loanId
    ) external view returns (uint256 ltv) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];
        if (loan.id == 0 || loan.collateralAmount == 0) {
            return 0;
        }
        LibVangki.Offer storage offer = s.offers[loan.offerId];

        if (offer.liquidity != LibVangki.LiquidityStatus.Liquid) {
            return 0;
        }

        uint256 currentBorrowBalance = _calculateCurrentBorrowBalance(loan);
        (uint256 borrowPrice, uint8 borrowDecimals) = OracleFacet(address(this))
            .getAssetPrice(offer.lendingAsset);
        uint256 borrowedValueUSD = (currentBorrowBalance * borrowPrice) /
            (10 ** borrowDecimals);

        (uint256 collateralPrice, uint8 collateralDecimals) = OracleFacet(
            address(this)
        ).getAssetPrice(loan.collateralAsset);
        uint256 collateralValueUSD = (loan.collateralAmount * collateralPrice) /
            (10 ** collateralDecimals);

        ltv = (borrowedValueUSD * BASIS_POINTS) / collateralValueUSD;
    }

    /**
     * @notice Calculates the Health Factor (HF) for a loan.
     * @dev HF = (collateralValueUSD * liqThresholdBps / 10000) / currentBorrowBalanceUSD; scaled to 1e18.
     *      Includes accrued interest in borrow balance.
     *      Uses Oracle for prices; reverts if non-liquid.
     *      For Vangki Phase 1 single-asset; expand for multi.
     * @param loanId The loan ID.
     * @return healthFactor The HF scaled to 1e18 (e.g., 1.5e18 = 1.5).
     */
    function calculateHealthFactor(
        uint256 loanId
    ) external view returns (uint256 healthFactor) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];
        if (loan.id == 0 || loan.collateralAmount == 0) {
            revert InvalidLoan();
        }
        LibVangki.Offer storage offer = s.offers[loan.offerId];

        if (offer.liquidity != LibVangki.LiquidityStatus.Liquid) {
            revert NonLiquidAsset();
        }

        uint256 currentBorrowBalance = _calculateCurrentBorrowBalance(loan);
        (uint256 borrowPrice, uint8 borrowDecimals) = OracleFacet(address(this))
            .getAssetPrice(offer.lendingAsset);
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
            liqThresholdBps) / BASIS_POINTS;

        if (borrowValueUSD == 0) {
            return type(uint256).max; // Infinite HF if no borrow
        }

        healthFactor = (riskAdjustedCollateral * HF_SCALE) / borrowValueUSD;
    }

    // Internal helper for current borrow balance with accrued interest
    function _calculateCurrentBorrowBalance(
        LibVangki.Loan storage loan
    ) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - loan.startTime;
        uint256 accruedInterest = (loan.principal *
            loan.interestRateBps *
            elapsed) / (365 days * BASIS_POINTS);
        return loan.principal + accruedInterest;
    }
}
