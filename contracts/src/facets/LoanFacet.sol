// src/facets/LoanFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import {RiskFacet} from "./RiskFacet.sol"; // For initial HF check
import {VangkiNFTFacet} from "./VangkiNFTFacet.sol"; // For updates

/**
 * @title LoanFacet
 * @author Vangki Developer Team
 * @notice This facet handles loan initiation and general queries in the Vangki P2P lending platform.
 * @dev New for Phase 1: Called from OfferFacet.acceptOffer to create loans.
 *      Sets loan details, checks initial HF > min (1.5), updates NFTs.
 *      Provides query functions (e.g., getLoanDetails).
 *      Custom errors, ReentrancyGuard, Pausable.
 *      Events for loan creation.
 *      Gas optimized: Unchecked for IDs.
 */
contract LoanFacet is ReentrancyGuard, Pausable {
    /// @notice Emitted when a new loan is initiated.
    /// @param loanId The unique ID of the loan.
    /// @param offerId The associated offer ID.
    /// @param lender The lender's address.
    /// @param borrower The borrower's address.
    event LoanInitiated(
        uint256 indexed loanId,
        uint256 indexed offerId,
        address indexed lender,
        address borrower
    );

    // Custom errors for clarity and gas efficiency.
    error InvalidOffer();
    error HealthFactorTooLow();
    error CrossFacetCallFailed(string reason);

    /**
     * @notice Initiates a loan after offer acceptance.
     * @dev Internal: Called by OfferFacet. Sets loan struct, checks HF.
     *      Updates NFTs to "Loan Active".
     *      Reverts if paused or low HF.
     *      Emits LoanInitiated.
     * @param offerId The accepted offer ID.
     * @param acceptor The acceptor address (borrower or lender based on offerType).
     * @return loanId The new loan ID.
     */
    function initiateLoan(
        uint256 offerId,
        address acceptor
    ) external nonReentrant whenNotPaused returns (uint256 loanId) {
        if (msg.sender != address(this))
            revert CrossFacetCallFailed("Unauthorized"); // Only via Diamond

        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Offer storage offer = s.offers[offerId];
        if (offer.id == 0 || offer.accepted) revert InvalidOffer();

        unchecked {
            loanId = ++s.nextLoanId;
        }

        LibVangki.Loan storage loan = s.loans[loanId];
        loan.id = loanId;
        loan.offerId = offerId;
        loan.startTime = block.timestamp;
        loan.durationDays = offer.durationDays;
        loan.interestRateBps = offer.interestRateBps;
        loan.principal = offer.amount;
        loan.collateralAmount = offer.collateralAmount;
        loan.principalAsset = offer.lendingAsset;
        loan.collateralAsset = offer.collateralAsset;
        loan.tokenId = offer.tokenId;
        loan.quantity = offer.quantity;
        loan.assetType = offer.assetType;
        loan.status = LibVangki.LoanStatus.Active;

        if (offer.offerType == LibVangki.OfferType.Lender) {
            loan.lender = offer.creator;
            loan.borrower = acceptor;
        } else {
            loan.lender = acceptor;
            loan.borrower = offer.creator;
        }

        // Check initial HF via cross-facet staticcall
        (bool success, bytes memory result) = address(this).staticcall(
            abi.encodeWithSelector(
                RiskFacet.calculateHealthFactor.selector,
                loanId
            )
        );
        if (!success) revert CrossFacetCallFailed("HF check failed");
        uint256 hf = abi.decode(result, (uint256));
        if (hf < 150 * 1e16) revert HealthFactorTooLow(); // Min 1.5

        // Update NFTs to active loan status
        (success, ) = address(this).call(
            abi.encodeWithSelector(
                VangkiNFTFacet.updateNFTStatus.selector,
                loanId, // Use loanId for NFTs post-accept
                "Loan Active"
            )
        );
        if (!success) revert CrossFacetCallFailed("NFT update failed");

        emit LoanInitiated(loanId, offerId, loan.lender, loan.borrower);
    }

    /**
     * @notice Gets details of a loan.
     * @dev View function for off-chain queries.
     * @param loanId The loan ID.
     * @return loan The Loan struct.
     */
    function getLoanDetails(
        uint256 loanId
    ) external view returns (LibVangki.Loan memory loan) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        return s.loans[loanId];
    }
}
