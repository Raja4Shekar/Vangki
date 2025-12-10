// src/facets/DefaultedFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OracleFacet} from "./OracleFacet.sol"; // For liquidity
import {VangkiNFTFacet} from "./VangkiNFTFacet.sol"; // For updates
import {EscrowFactoryFacet} from "./EscrowFactoryFacet.sol"; // For transfers

/**
 * @title DefaultedFacet
 * @author Vangki Developer Team
 * @notice This facet handles loan defaults and liquidations in the Vangki P2P lending platform.
 * @dev Split from LoanFacet for modularity. Uses shared LibVangki storage.
 *      For liquid: Integrates 0x for swap (frontend provides fillData).
 *      For illiquid: Full transfer.
 *      For NFT lending: Lender claims/reset.
 *      Custom errors, ReentrancyGuard, events.
 *      Expand for Phase 2 (e.g., auctions).
 */
contract DefaultedFacet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Emitted when a loan defaults.
    /// @param loanId The ID of the defaulted loan.
    event LoanDefaulted(uint256 indexed loanId);

    /// @notice Emitted when a liquidation is triggered for liquid collateral.
    /// @param loanId The ID of the liquidated loan.
    /// @param proceeds The amount recovered from liquidation.
    event LoanLiquidated(uint256 indexed loanId, uint256 proceeds);

    // Custom errors for clarity and gas efficiency.
    error NotLender();
    error InvalidLoanStatus();
    error NotDefaultedYet();
    error CrossFacetCallFailed(string reason);
    error InsufficientProceeds();
    error LiquidationFailed();

    // 0x ExchangeProxy (mainnet; configurable in Phase 2)
    address private immutable ZERO_EX_PROXY =
        0xDef1C0ded9bec7F1a1670819833240f027b25EfF;

    /**
     * @notice Triggers default on a loan past grace period.
     * @dev Callable by lender. Transfers full collateral (illiquid) or liquidates via 0x (liquid).
     *      Updates status to Defaulted, updates NFTs.
     *      For NFT lending: Lender claims NFT, resets renter.
     *      Emits LoanDefaulted and LoanLiquidated (if applicable).
     *      Frontend provides fillData/minOutputAmount from 0x quote.
     * @param loanId The loan ID to default.
     * @param fillData The 0x fill quote data (calldata for swap; empty for illiquid).
     * @param minOutputAmount The minimum output amount for swap (slippage protection; 0 for illiquid).
     */
    function triggerDefault(
        uint256 loanId,
        bytes calldata fillData,
        uint256 minOutputAmount
    ) external nonReentrant {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];
        if (loan.lender != msg.sender) revert NotLender();
        if (loan.status != LibVangki.LoanStatus.Active)
            revert InvalidLoanStatus();

        uint256 endTime = loan.startTime + loan.durationDays * 1 days;
        uint256 graceEnd = endTime + LibVangki.gracePeriod(loan.durationDays);
        if (block.timestamp <= graceEnd) revert NotDefaultedYet();

        // Check liquidity for collateral
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

        uint256 proceeds = 0;
        if (liquidity == LibVangki.LiquidityStatus.Liquid) {
            // Liquid: Withdraw collateral to Diamond, approve 0x, execute swap
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowWithdrawERC20.selector,
                    loan.borrower,
                    loan.collateralAsset,
                    address(this),
                    loan.collateralAmount
                )
            );
            if (!success)
                revert CrossFacetCallFailed("Collateral withdraw failed");

            IERC20(loan.collateralAsset).forceApprove(
                ZERO_EX_PROXY,
                loan.collateralAmount
            );

            // Execute 0x fill (assume fillData targets swap to principalAsset)
            (bool swapSuccess, bytes memory swapResult) = ZERO_EX_PROXY.call(
                fillData
            );
            if (!swapSuccess) revert LiquidationFailed();
            proceeds = abi.decode(swapResult, (uint256));

            if (proceeds < minOutputAmount) revert InsufficientProceeds();

            IERC20(loan.principalAsset).safeTransfer(loan.lender, proceeds);

            emit LoanLiquidated(loanId, proceeds);
        } else {
            // Illiquid: Full collateral to lender
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    EscrowFactoryFacet.escrowWithdrawERC20.selector,
                    loan.borrower,
                    loan.collateralAsset,
                    loan.lender,
                    loan.collateralAmount
                )
            );
            if (!success) revert CrossFacetCallFailed("Full transfer failed");
        }

        // For NFT lending: Reset renter and claim if needed
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
                if (!success) revert CrossFacetCallFailed("NFT claim failed");
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
        if (!success) revert CrossFacetCallFailed("NFT update failed");

        emit LoanDefaulted(loanId);
    }
}
