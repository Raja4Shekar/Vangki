// src/facets/ProfileFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title ProfileFacet
 * @author Vangki Developer Team
 * @notice This facet handles user profile management, including country setting for sanctions compliance and KYC verification in the Vangki platform.
 * @dev Part of the Diamond Standard (EIP-2535). Uses shared LibVangki storage for userCountry and kycVerified mappings.
 *      Users can set their country (self-reported ISO code). KYC is set by Diamond owner (admin/multi-sig) after off-chain verification.
 *      Required for offer filtering (sanctions) and KYC checks (> $2k liquid transactions).
 *      Custom errors, events. No reentrancy as no asset transfers. Pausable for emergencies.
 *      View functions for queries. Phase 1: Simple flags; expand in Phase 2 for governance/levels.
 *      Best practices: Nat-spec comments, access control, gas-optimized (minimal storage).
 */
contract ProfileFacet is Pausable {
    /// @notice Emitted when a user sets their country.
    /// @param user The user's address.
    /// @param country The ISO country code set.
    event UserCountrySet(address indexed user, string country);

    /// @notice Emitted when a user's KYC status is updated.
    /// @param user The user's address.
    /// @param verified The new KYC verification status.
    event KYCStatusUpdated(address indexed user, bool verified);

    // Custom errors for gas efficiency and clarity.
    error InvalidCountry();
    error NotOwner();
    error AlreadyRegistered();
    error CrossFacetCallFailed(string reason); // If future integrations

    /**
     * @notice Sets the user's country for sanctions compliance.
     * @dev Callable by anyone for their own address. Validates non-empty string (ISO code assumed off-chain).
     *      Reverts if paused or already set (to prevent changes; adjustable in Phase 2).
     *      Emits UserCountrySet.
     * @param country The ISO country code (e.g., "US").
     */
    function setUserCountry(string calldata country) external whenNotPaused {
        if (bytes(country).length == 0) revert InvalidCountry();

        LibVangki.Storage storage s = LibVangki.storageSlot();
        if (bytes(s.userCountry[msg.sender]).length > 0)
            revert AlreadyRegistered();

        s.userCountry[msg.sender] = country;

        emit UserCountrySet(msg.sender, country);
    }

    /**
     * @notice Updates a user's KYC verification status.
     * @dev Owner-only (admin/multi-sig). Used after off-chain KYC process.
     *      Emits KYCStatusUpdated.
     * @param user The user's address.
     * @param verified The new KYC status (true for verified).
     */
    function updateKYCStatus(
        address user,
        bool verified
    ) external whenNotPaused {
        LibDiamond.enforceIsContractOwner();

        LibVangki.Storage storage s = LibVangki.storageSlot();
        s.kycVerified[user] = verified;

        emit KYCStatusUpdated(user, verified);
    }

    /**
     * @notice Gets a user's country.
     * @dev View function; returns empty string if not set.
     * @param user The user's address.
     * @return country The ISO country code.
     */
    function getUserCountry(
        address user
    ) external view returns (string memory country) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        return s.userCountry[user];
    }

    /**
     * @notice Checks if a user is KYC verified.
     * @dev View function; used in offer acceptance/loan init for >$2k checks.
     * @param user The user's address.
     * @return verified True if KYC verified.
     */
    function isKYCVerified(address user) external view returns (bool verified) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        return s.kycVerified[user];
    }

    /**
     * @notice Sets trade allowance between two countries.
     * @dev Owner-only (multi-sig). Calls LibVangki.setTradeAllowance.
     *      Emits event if needed (add TradeAllowanceSet).
     *      Callable when not paused.
     * @param countryA ISO code for country A.
     * @param countryB ISO code for country B.
     * @param allowed True to allow, false to block.
     */
    function setTradeAllowance(
        string calldata countryA,
        string calldata countryB,
        bool allowed
    ) external whenNotPaused {
        LibDiamond.enforceIsContractOwner();
        LibVangki.setTradeAllowance(countryA, countryB, allowed);
    }
}
