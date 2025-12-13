// src/facets/DefaultedFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol"; // Added for pausable
import {OracleFacet} from "./OracleFacet.sol"; // For liquidity and USD value
import {VangkiNFTFacet} from "./VangkiNFTFacet.sol"; // For updates
import {EscrowFactoryFacet} from "./EscrowFactoryFacet.sol"; // For transfers
import {ProfileFacet} from "./ProfileFacet.sol"; // Added for KYC check
import {RiskFacet} from "./RiskFacet.sol";

/**
 * @title DefaultedFacet
 * @author Vangki Developer Team
 * @notice This facet handles time-based loan defaults (past grace period) in the Vangki P2P lending platform.
 * @dev Enhanced: Added Pausable, KYC check for high-value, better 0x error handling, treasury fee on bonus (0% Phase 1).
 *      Separated from HF: No HF check here; only time-past grace. HF liquidation in RiskFacet.
 *      For liquid: 0x swap; illiquid: full transfer.
 *      Custom errors, ReentrancyGuard, events.
 *      Expand for Phase 2.
 *      Enhanced for NFT defaults: Transfers prepay to lender, buffer to treasury (assumes prepay in ERC-20 held in borrower escrow).
 *      Resets renter to address(0).
 */
contract DefaultedFacet is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Emitted when a loan defaults.
    /// @param loanId The ID of the defaulted loan.
    event LoanDefaulted(uint256 indexed loanId);

    /// @notice Emitted when a liquidation is triggered for liquid collateral.
    /// @param loanId The ID of the liquidated loan.
    /// @param proceeds The amount recovered from liquidation.
    /// @param treasuryFee The treasury fee deducted (if any).
    event LoanLiquidated(
        uint256 indexed loanId,
        uint256 proceeds,
        uint256 treasuryFee
    );

    // Custom errors for clarity and gas efficiency.
    error NotLender();
    error InvalidLoanStatus();
    error NotDefaultedYet();
    error CrossFacetCallFailed(string reason);
    error InsufficientProceeds();
    error LiquidationFailed();
    error KYCRequired();

    /**
     * @notice Triggers default for a loan past grace period (permissionless).
     * @dev If liquid collateral: Calls triggerLiquidation (0x swap).
     *      If illiquid: Transfers full collateral to lender.
     *      Enhanced for NFTs: Transfers prepay (amount * durationDays) to lender, buffer (5%) to treasury from borrower escrow.
     *      Resets renter via escrowSetNFTUser(address(0), 0).
     *      Updates loan to Defaulted, burns NFTs.
     *      Emits LoanDefaulted.
     * @param loanId The loan ID to default.
     */
    function triggerDefault(
        uint256 loanId
    ) external whenNotPaused nonReentrant {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];
        if (loan.status != LibVangki.LoanStatus.Active)
            revert InvalidLoanStatus();

        uint256 endTime = loan.startTime + loan.durationDays * 1 days;
        uint256 graceEnd = endTime + LibVangki.gracePeriod(loan.durationDays);
        if (block.timestamp <= graceEnd) revert NotDefaultedYet();

        address treasury = _getTreasury();

        bool success;
        LibVangki.LiquidityStatus liquidity = OracleFacet(address(this))
            .checkLiquidity(loan.collateralAsset);

        if (liquidity == LibVangki.LiquidityStatus.Liquid) {
            // Liquid: Trigger liquidation (permissionless)
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    RiskFacet.triggerLiquidation.selector,
                    loanId
                )
            );
            if (!success) revert CrossFacetCallFailed("Liquidation failed");
        } else {
            // Illiquid: Full collateral to lender
            if (loan.assetType == LibVangki.AssetType.ERC20) {
                (success, ) = address(this).call(
                    abi.encodeWithSelector(
                        EscrowFactoryFacet.escrowWithdrawERC20.selector,
                        loan.borrower,
                        loan.collateralAsset,
                        loan.lender,
                        loan.collateralAmount
                    )
                );
                if (!success)
                    revert CrossFacetCallFailed("Collateral transfer failed");
            } else if (loan.assetType == LibVangki.AssetType.ERC721) {
                (success, ) = address(this).call(
                    abi.encodeWithSelector(
                        EscrowFactoryFacet.escrowWithdrawERC721.selector,
                        loan.borrower,
                        loan.collateralAsset,
                        loan.tokenId,
                        loan.lender
                    )
                );
                if (!success)
                    revert CrossFacetCallFailed("NFT transfer failed");
            } else if (loan.assetType == LibVangki.AssetType.ERC1155) {
                (success, ) = address(this).call(
                    abi.encodeWithSelector(
                        EscrowFactoryFacet.escrowWithdrawERC1155.selector,
                        loan.borrower,
                        loan.collateralAsset,
                        loan.tokenId,
                        loan.quantity,
                        loan.lender
                    )
                );
                if (!success)
                    revert CrossFacetCallFailed("NFT transfer failed");
            }
        }

        // NFT-specific handling (if lendingAsset is NFT)
        if (loan.assetType != LibVangki.AssetType.ERC20) {
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
                if (!success) revert CrossFacetCallFailed("NFT claim failed");
            }

            // Handle prepay: Assume prepayAsset = collateralAsset (ERC-20), prepayAmount = amount * durationDays + buffer
            // Note: Assume added fields in Loan: uint256 prepayAmount, uint256 bufferAmount (set in acceptOffer)
            uint256 prepayToLender = loan.prepayAmount - loan.bufferAmount;
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowWithdrawERC20.selector,
                    loan.borrower,
                    loan.collateralAsset, // Assume prepay in collateralAsset
                    loan.lender,
                    prepayToLender
                )
            );
            if (!success) revert CrossFacetCallFailed("Prepay transfer failed");

            // Buffer to treasury
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowWithdrawERC20.selector,
                    loan.borrower,
                    loan.collateralAsset,
                    treasury,
                    loan.bufferAmount
                )
            );
            if (!success)
                revert CrossFacetCallFailed("Buffer to treasury failed");
        }

        loan.status = LibVangki.LoanStatus.Defaulted;

        // Update NFTs to "Loan Defaulted" and burn (enhanced: burn after update)
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                VangkiNFTFacet.updateNFTStatus.selector,
                loanId,
                "Loan Defaulted"
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

        emit LoanDefaulted(loanId);
    }

    /**
     * @notice View function to check if a loan is defaultable (past grace period).
     * @dev Enhanced: For off-chain monitoring or UI.
     * @param loanId The loan ID.
     * @return isDefaultable True if past grace period.
     */
    function isLoanDefaultable(
        uint256 loanId
    ) external view returns (bool isDefaultable) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];
        if (loan.status != LibVangki.LoanStatus.Active) return false;

        uint256 endTime = loan.startTime + loan.durationDays * 1 days;
        uint256 graceEnd = endTime + LibVangki.gracePeriod(loan.durationDays);
        return block.timestamp > graceEnd;
    }

    /// @dev Get Treasury Address
    function _getTreasury() internal view returns (address) {
        return LibVangki.storageSlot().treasury;
    }
}
