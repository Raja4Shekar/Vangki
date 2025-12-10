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

/**
 * @title DefaultedFacet
 * @author Vangki Developer Team
 * @notice This facet handles time-based loan defaults (past grace period) in the Vangki P2P lending platform.
 * @dev Enhanced: Added Pausable, KYC check for high-value, better 0x error handling, treasury fee on bonus (0% Phase 1).
 *      Separated from HF: No HF check here; only time-past grace. HF liquidation in RiskFacet.
 *      For liquid: 0x swap; illiquid: full transfer.
 *      Custom errors, ReentrancyGuard, events.
 *      Expand for Phase 2.
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

    // Immutable 0x ExchangeProxy (mainnet; make configurable in Phase 2 via storage)
    address private immutable ZERO_EX_PROXY =
        0xDef1C0ded9bec7F1a1670819833240f027b25EfF;

    // Assume treasury (hardcoded; move to LibVangki)
    address private immutable TREASURY =
        address(0xb985F8987720C6d76f02909890AA21C11bC6EBCA);

    // Constants
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant LIQ_TREASURY_FEE_BPS = 0; // 0% Phase 1; configurable in Phase 2
    uint256 private constant KYC_THRESHOLD_USD = 2000 * 1e18; // $2k, assuming 18 decimals for USD

    /**
     * @notice Triggers default on a loan past grace period.
     * @dev Callable by lender when not paused. Transfers full collateral (illiquid) or liquidates via 0x (liquid).
     *      Enhanced: Checks KYC if proceeds > $2k USD (via Oracle), deducts treasury fee on proceeds.
     *      No HF check (separated to RiskFacet.triggerLiquidation).
     *      Updates status to Defaulted, burns NFTs after update.
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
    ) external nonReentrant whenNotPaused {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Loan storage loan = s.loans[loanId];
        if (loan.lender != msg.sender) revert NotLender();
        if (loan.status != LibVangki.LoanStatus.Active)
            revert InvalidLoanStatus();

        uint256 endTime = loan.startTime + loan.durationDays * 1 days;
        uint256 graceEnd = endTime + LibVangki.gracePeriod(loan.durationDays);
        if (block.timestamp <= graceEnd) revert NotDefaultedYet();

        // Determine liquidity via cross-facet staticcall
        (bool liqSuccess, bytes memory liqResult) = address(this).staticcall(
            abi.encodeWithSelector(
                OracleFacet.checkLiquidity.selector,
                loan.collateralAsset
            )
        );
        if (!liqSuccess) revert CrossFacetCallFailed("Liquidity check failed");
        LibVangki.LiquidityStatus liquidity = abi.decode(
            liqResult,
            (LibVangki.LiquidityStatus)
        );

        uint256 proceeds = 0;
        bool success;
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
            if (!swapSuccess) {
                // Enhanced error handling: Decode revert reason if possible
                if (swapResult.length > 0) {
                    assembly {
                        revert(add(swapResult, 0x20), mload(swapResult))
                    }
                } else {
                    revert LiquidationFailed();
                }
            }
            proceeds = abi.decode(swapResult, (uint256));

            if (proceeds < minOutputAmount) revert InsufficientProceeds();

            // Deduct treasury fee on proceeds (0% Phase 1)
            uint256 treasuryFee = (proceeds * LIQ_TREASURY_FEE_BPS) /
                BASIS_POINTS;
            s.treasuryBalances[loan.principalAsset] += treasuryFee;
            IERC20(loan.principalAsset).safeTransfer(TREASURY, treasuryFee);

            // Check KYC if proceeds - fee > $2k USD
            uint256 netProceeds = proceeds - treasuryFee;
            (bool priceSuccess, bytes memory priceResult) = address(this)
                .staticcall(
                    abi.encodeWithSelector(
                        OracleFacet.getAssetPrice.selector,
                        loan.principalAsset
                    )
                );
            if (priceSuccess) {
                (uint256 price, uint8 decimals) = abi.decode(
                    priceResult,
                    (uint256, uint8)
                );
                uint256 proceedsUSD = (netProceeds * price) / (10 ** decimals);
                if (proceedsUSD > KYC_THRESHOLD_USD) {
                    (bool kycSuccess, bytes memory kycResult) = address(this)
                        .staticcall(
                            abi.encodeWithSelector(
                                ProfileFacet.isKYCVerified.selector,
                                msg.sender
                            )
                        );
                    if (!kycSuccess || !abi.decode(kycResult, (bool)))
                        revert KYCRequired();
                }
            } // Ignore if price fail (non-liquid shouldn't reach here)

            IERC20(loan.principalAsset).safeTransfer(loan.lender, netProceeds);

            emit LoanLiquidated(loanId, proceeds, treasuryFee);
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
}
