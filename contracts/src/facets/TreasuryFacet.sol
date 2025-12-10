// src/facets/TreasuryFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TreasuryFacet
 * @author Vangki Developer Team
 * @notice This facet manages treasury fee accumulation and claims for the Vangki platform.
 * @dev Part of Diamond Standard (EIP-2535). Uses shared LibVangki storage for balances.
 *      Fees (1% of interest/late) accumulate in Diamond proxy.
 *      Owner-only claims to specified address (multi-sig in production).
 *      Supports ERC-20 assets; custom errors, events, ReentrancyGuard.
 *      Callable only by Diamond owner. Expand for Phase 2 (governance distributions, reserves).
 */
contract TreasuryFacet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Emitted when treasury fees are claimed.
    /// @param asset The ERC-20 asset claimed.
    /// @param amount The claimed amount.
    /// @param claimant The address receiving the claim (specified by owner).
    event TreasuryFeesClaimed(
        address indexed asset,
        uint256 amount,
        address indexed claimant
    );

    // Custom errors for gas efficiency and clarity.
    error NotOwner();
    error ZeroAmount();
    error InsufficientBalance();
    error CrossFacetCallFailed(string reason); // If future integrations

    /**
     * @notice Allows Diamond owner to claim accumulated treasury fees for an asset.
     * @dev Transfers full available balance to claimant (e.g., multi-sig wallet).
     *      Reverts if insufficient or zero. Updates treasuryBalances.
     *      Emits TreasuryFeesClaimed.
     * @param asset The ERC-20 asset to claim.
     * @param claimant The address to receive the fees (must != address(0)).
     */
    function claimTreasuryFees(
        address asset,
        address claimant
    ) external nonReentrant {
        LibDiamond.enforceIsContractOwner(); // Owner-only
        if (claimant == address(0)) revert NotOwner(); // Misuse as error; adjust if needed

        LibVangki.Storage storage s = LibVangki.storageSlot();
        uint256 balance = s.treasuryBalances[asset];
        if (balance == 0) revert ZeroAmount();

        // Transfer to claimant
        IERC20(asset).safeTransfer(claimant, balance);

        // Update balance
        s.treasuryBalances[asset] = 0;

        emit TreasuryFeesClaimed(asset, balance, claimant);
    }

    /**
     * @notice View function to get treasury balance for an asset.
     * @dev Returns accumulated fees (from repayments, forfeitures, etc.).
     * @param asset The ERC-20 asset.
     * @return balance The treasury balance for the asset.
     */
    function getTreasuryBalance(
        address asset
    ) external view returns (uint256 balance) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        return s.treasuryBalances[asset];
    }
}
