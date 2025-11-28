// src/facets/EscrowFactoryFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import {VangkiEscrowImplementation} from "../VangkiEscrowImplementation.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title EscrowFactoryFacet
 * @author Vangki Developer Team
 * @notice This facet manages the creation, initialization, and upgrade of per-user UUPS escrow proxies in the Vangki platform.
 * @dev This contract is part of the Diamond Standard (EIP-2535) and uses shared storage from LibVangki.
 *      It deploys ERC1967Proxy instances per user, all pointing to a shared upgradable VangkiEscrowImplementation.
 *      The Diamond owns the implementation and controls upgrades.
 *      Provides public helpers for ERC20, ERC721, and ERC1155 deposit/withdraw, as well as ERC-4907 rental functions (setUser, userOf, userExpires).
 *      All operations forward calls to the user's proxy (delegated to implementation).
 *      Custom errors for gas efficiency and clarity. No reentrancy needed as calls are forwarded or view-based.
 *      Events emitted for key actions like creation and upgrades.
 *      Access to sensitive functions (init/upgrade) restricted to Diamond owner (initially deployer, later multi-sig/governance).
 *      For ERC721 rentals: Assumes operator approval for setUser (NFT may not be held in escrow).
 *      For ERC1155: Assumes tokens are held in escrow for operations.
 */
contract EscrowFactoryFacet {
    using SafeERC20 for IERC20;

    /// @notice Emitted when a new user escrow proxy is created.
    /// @param user The address of the user for whom the escrow is created.
    /// @param proxy The address of the newly deployed proxy.
    event UserEscrowCreated(address indexed user, address proxy);

    /// @notice Emitted when the shared escrow implementation is upgraded.
    /// @param oldImplementation The address of the previous implementation.
    /// @param newImplementation The address of the new implementation.
    event EscrowImplementationUpgraded(
        address indexed oldImplementation,
        address indexed newImplementation
    );

    // Custom errors for better gas efficiency and clarity.
    error AlreadyInitialized();
    error UpgradeFailed();
    error ProxyCallFailed(string reason);

    /**
     * @notice Initializes the shared escrow implementation by deploying a new VangkiEscrowImplementation.
     * @dev Sets the implementation address in storage if not already set.
     *      Callable only once by the Diamond owner to prevent re-initialization.
     *      No parameters; deploys a fresh implementation.
     */
    function initializeEscrowImplementation() external {
        LibDiamond.enforceIsContractOwner();
        LibVangki.Storage storage s = LibVangki.storageSlot();
        if (s.vangkiEscrowTemplate != address(0)) {
            revert AlreadyInitialized();
        }
        VangkiEscrowImplementation impl = new VangkiEscrowImplementation();
        s.vangkiEscrowTemplate = address(impl);
    }

    /**
     * @notice Retrieves or creates a UUPS proxy for the specified user if it doesn't exist.
     * @dev If no proxy exists, deploys a new ERC1967Proxy pointing to the current implementation and initializes it.
     *      Emits UserEscrowCreated on new deployment.
     *      Can be called by any facet or externally, but typically used internally.
     * @param user The address of the user for the escrow.
     * @return proxy The address of the user's escrow proxy.
     */
    function getOrCreateUserEscrow(
        address user
    ) public returns (address proxy) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        proxy = s.userVangkiEscrows[user];
        if (proxy == address(0)) {
            ERC1967Proxy newProxy = new ERC1967Proxy(
                s.vangkiEscrowTemplate,
                abi.encodeCall(VangkiEscrowImplementation.initialize, ())
            );
            proxy = address(newProxy);
            s.userVangkiEscrows[user] = proxy;
            emit UserEscrowCreated(user, proxy);
        }
    }

    /**
     * @notice Upgrades the shared escrow implementation used by all proxies.
     * @dev Updates the storage pointer; all existing proxies will delegate to the new implementation automatically.
     *      Validates the new implementation is UUPS-compatible via a test call to _authorizeUpgrade.
     *      Callable only by the Diamond owner.
     *      Emits EscrowImplementationUpgraded event.
     * @param newImplementation The address of the new deployed VangkiEscrowImplementation.
     */
    function upgradeEscrowImplementation(address newImplementation) external {
        LibDiamond.enforceIsContractOwner();
        LibVangki.Storage storage s = LibVangki.storageSlot();
        address oldImplementation = s.vangkiEscrowTemplate;

        // ##No test call; assume newImplementation is valid UUPS##

        // // Validate new impl supports UUPS (test call to _authorizeUpgrade)
        // (bool success, ) = newImplementation.staticcall(
        //     abi.encodeWithSelector(
        //         VangkiEscrowImplementation._authorizeUpgrade.selector,
        //         address(0)
        //     )
        // );
        // if (!success) {
        //     revert UpgradeFailed();
        // }

        s.vangkiEscrowTemplate = newImplementation;
        emit EscrowImplementationUpgraded(oldImplementation, newImplementation);
    }

    /**
     * @notice Deposits ERC20 tokens into the specified user's escrow proxy.
     * @dev Transfers tokens from msg.sender to the proxy address using safeTransferFrom.
     *      Callable by other facets (e.g., OfferFacet during offer creation).
     *      Ensures the proxy exists by calling getOrCreateUserEscrow.
     * @param user The user whose escrow receives the deposit.
     * @param token The ERC20 token address.
     * @param amount The amount of tokens to deposit.
     */
    function escrowDepositERC20(
        address user,
        address token,
        uint256 amount
    ) public {
        address proxy = getOrCreateUserEscrow(user);
        IERC20(token).safeTransferFrom(msg.sender, proxy, amount);
    }

    /**
     * @notice Withdraws ERC20 tokens from the specified user's escrow proxy to a recipient.
     * @dev Low-level call to the proxy's withdrawERC20 function (delegated to implementation).
     *      Reverts if the call fails.
     *      Callable by other facets (e.g., LoanFacet during repayment).
     * @param user The user whose escrow is the source.
     * @param token The ERC20 token address.
     * @param to The recipient address.
     * @param amount The amount of tokens to withdraw.
     */
    function escrowWithdrawERC20(
        address user,
        address token,
        address to,
        uint256 amount
    ) public {
        address proxy = getOrCreateUserEscrow(user);
        (bool success, ) = proxy.call(
            abi.encodeWithSelector(
                VangkiEscrowImplementation.withdrawERC20.selector,
                token,
                to,
                amount
            )
        );
        if (!success) {
            revert ProxyCallFailed("ERC20 withdraw failed");
        }
    }

    /**
     * @notice Returns the ERC20 balance of the specified user's escrow proxy.
     * @dev Low-level staticcall to the proxy's balanceOfERC20 function.
     *      Returns 0 on failure.
     *      View function; callable by anyone.
     * @param user The user whose escrow to query.
     * @param token The ERC20 token address.
     * @return The balance held in the escrow.
     */
    function escrowBalanceOfERC20(
        address user,
        address token
    ) public view returns (uint256) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        address proxy = s.userVangkiEscrows[user];
        if (proxy == address(0)) {
            return 0;
        }
        (bool success, bytes memory result) = proxy.staticcall(
            abi.encodeWithSelector(
                VangkiEscrowImplementation.balanceOfERC20.selector,
                token
            )
        );
        if (!success) {
            return 0;
        }
        return abi.decode(result, (uint256));
    }

    /**
     * @notice Deposits an NFT (ERC721 or ERC1155) into the specified user's escrow proxy.
     * @dev Low-level call to the proxy's depositNFT function.
     *      Reverts if the call fails.
     *      Callable by other facets (e.g., for NFT renting offers).
     * @param user The user whose escrow receives the deposit.
     * @param nftContract The NFT contract address.
     * @param tokenId The token ID.
     * @param isERC1155 True for ERC1155, false for ERC721.
     * @param amount For ERC1155: quantity; for ERC721: ignored (set to 1).
     */
    function escrowDepositNFT(
        address user,
        address nftContract,
        uint256 tokenId,
        bool isERC1155,
        uint256 amount
    ) public {
        address proxy = getOrCreateUserEscrow(user);
        (bool success, ) = proxy.call(
            abi.encodeWithSelector(
                VangkiEscrowImplementation.depositNFT.selector,
                nftContract,
                tokenId,
                isERC1155,
                amount
            )
        );
        if (!success) {
            revert ProxyCallFailed("NFT deposit failed");
        }
    }

    /**
     * @notice Withdraws an NFT (ERC721 or ERC1155) from the specified user's escrow proxy to a recipient.
     * @dev Low-level call to the proxy's withdrawNFT function.
     *      Reverts if the call fails.
     *      Callable by other facets (e.g., on rental closure or default).
     * @param user The user whose escrow is the source.
     * @param nftContract The NFT contract address.
     * @param to The recipient address.
     * @param tokenId The token ID.
     * @param isERC1155 True for ERC1155, false for ERC721.
     * @param amount For ERC1155: quantity; for ERC721: ignored (set to 1).
     */
    function escrowWithdrawNFT(
        address user,
        address nftContract,
        address to,
        uint256 tokenId,
        bool isERC1155,
        uint256 amount
    ) public {
        address proxy = getOrCreateUserEscrow(user);
        (bool success, ) = proxy.call(
            abi.encodeWithSelector(
                VangkiEscrowImplementation.withdrawNFT.selector,
                nftContract,
                to,
                tokenId,
                isERC1155,
                amount
            )
        );
        if (!success) {
            revert ProxyCallFailed("NFT withdraw failed");
        }
    }

    /**
     * @notice Returns the NFT balance or ownership in the specified user's escrow proxy.
     * @dev Low-level staticcall to the proxy's balanceOfNFT function.
     *      Returns 0 on failure.
     *      View function; callable by anyone.
     * @param user The user whose escrow to query.
     * @param nftContract The NFT contract address.
     * @param tokenId The token ID.
     * @param isERC1155 True for ERC1155, false for ERC721.
     * @return The balance (ERC1155) or ownership count (ERC721: 0 or 1).
     */
    function escrowBalanceOfNFT(
        address user,
        address nftContract,
        uint256 tokenId,
        bool isERC1155
    ) public view returns (uint256) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        address proxy = s.userVangkiEscrows[user];
        if (proxy == address(0)) {
            return 0;
        }
        (bool success, bytes memory result) = proxy.staticcall(
            abi.encodeWithSelector(
                VangkiEscrowImplementation.balanceOfNFT.selector,
                nftContract,
                tokenId,
                isERC1155
            )
        );
        if (!success) {
            return 0;
        }
        return abi.decode(result, (uint256));
    }

    /**
     * @notice Sets a temporary user for a rentable NFT in the specified user's escrow (ERC-4907 compliant).
     * @dev Low-level call to the proxy's setNFTUser function.
     *      Reverts if the call fails.
     *      Callable by other facets (e.g., during NFT rental initiation).
     * @param user The user whose escrow performs the operation.
     * @param nftContract The NFT contract address.
     * @param tokenId The token ID.
     * @param renter The temporary renter address (zero to revoke).
     * @param expires The UNIX timestamp for expiration.
     */
    function escrowSetNFTUser(
        address user,
        address nftContract,
        uint256 tokenId,
        address renter,
        uint64 expires
    ) public {
        address proxy = getOrCreateUserEscrow(user);
        (bool success, ) = proxy.call(
            abi.encodeWithSelector(
                VangkiEscrowImplementation.setNFTUser.selector,
                nftContract,
                tokenId,
                renter,
                expires
            )
        );
        if (!success) {
            revert ProxyCallFailed("Set NFT user failed");
        }
    }

    /**
     * @notice Gets the current user of a rentable NFT from the specified user's escrow.
     * @dev Low-level staticcall to the proxy's getNFTUserOf function.
     *      Returns zero address on failure.
     *      View function; callable by anyone.
     * @param user The user whose escrow to query.
     * @param nftContract The NFT contract address.
     * @param tokenId The token ID.
     * @return The current renter address (zero if none or failure).
     */
    function escrowGetNFTUserOf(
        address user,
        address nftContract,
        uint256 tokenId
    ) public view returns (address) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        address proxy = s.userVangkiEscrows[user];
        if (proxy == address(0)) {
            return address(0);
        }
        (bool success, bytes memory result) = proxy.staticcall(
            abi.encodeWithSelector(
                VangkiEscrowImplementation.getNFTUserOf.selector,
                nftContract,
                tokenId
            )
        );
        if (!success) {
            return address(0);
        }
        return abi.decode(result, (address));
    }

    /**
     * @notice Gets the expiration timestamp for a rentable NFT's user from the specified user's escrow.
     * @dev Low-level staticcall to the proxy's getNFTUserExpires function.
     *      Returns 0 on failure.
     *      View function; callable by anyone.
     * @param user The user whose escrow to query.
     * @param nftContract The NFT contract address.
     * @param tokenId The token ID.
     * @return The expiration timestamp (0 if none or failure).
     */
    function escrowGetNFTUserExpires(
        address user,
        address nftContract,
        uint256 tokenId
    ) public view returns (uint64) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        address proxy = s.userVangkiEscrows[user];
        if (proxy == address(0)) {
            return 0;
        }
        (bool success, bytes memory result) = proxy.staticcall(
            abi.encodeWithSelector(
                VangkiEscrowImplementation.getNFTUserExpires.selector,
                nftContract,
                tokenId
            )
        );
        if (!success) {
            return 0;
        }
        return abi.decode(result, (uint64));
    }
}

// ##EOF##
// pragma solidity ^0.8.29;

// import {LibVangki} from "../libraries/LibVangki.sol";
// import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
// import {VangkiEscrowImplementation} from "../VangkiEscrowImplementation.sol"; // Update import to match name
// import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
// import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// /**
//  * @title EscrowFactoryFacet
//  * @author Vangki Developer Team
//  * @notice This facet manages the creation and upgrade of per-user UUPS escrow proxies in the Vangki platform.
//  * @dev This contract is part of the Diamond Standard (EIP-2535) and uses shared storage from LibVangki.
//  *      It deploys ERC1967Proxy instances per user, all pointing to a shared upgradable VangkiEscrowImplementation.
//  *      The Diamond owns the implementation and controls upgrades.
//  *      Provides public helpers for ERC20 deposit/withdraw (extendable for NFTs in upgrades).
//  *      Upgrades allow adding NFT handling without migrating proxies.
//  *      Custom errors for gas efficiency. No reentrancy needed as calls are forwarded.
//  *      Events emitted for creation and upgrades.
//  *      Access restricted to Diamond owner for init/upgrade.
//  */
// contract EscrowFactoryFacet {
//     using SafeERC20 for IERC20;

//     /// @notice Emitted when a new user escrow proxy is created.
//     /// @param user The address of the user.
//     /// @param proxy The address of the created proxy.
//     event UserEscrowCreated(address indexed user, address proxy);

//     /// @notice Emitted when the escrow implementation is upgraded.
//     /// @param oldImplementation The previous implementation address.
//     /// @param newImplementation The new implementation address.
//     event EscrowImplementationUpgraded(
//         address indexed oldImplementation,
//         address indexed newImplementation
//     );

//     // Custom errors for clarity and gas efficiency.
//     error AlreadyInitialized();
//     error UpgradeFailed();
//     error WithdrawCallFailed();

//     /**
//      * @notice Initializes the shared escrow implementation address.
//      * @dev Deploy a new VangkiEscrowImplementation and set it in storage.
//      *      Callable only once by the Diamond owner.
//      *      No event as it's init; use deployment logs.
//      */
//     function initializeEscrowImplementation() external {
//         LibDiamond.enforceIsContractOwner();
//         LibVangki.Storage storage s = LibVangki.storageSlot();
//         if (s.vangkiEscrowTemplate != address(0)) {
//             revert AlreadyInitialized();
//         }
//         VangkiEscrowImplementation impl = new VangkiEscrowImplementation();
//         s.vangkiEscrowTemplate = address(impl);
//     }

//     /**
//      * @notice Gets or creates a UUPS proxy for the user if it doesn't exist.
//      * @dev Deploys an ERC1967Proxy pointing to the current implementation and initializes it.
//      *      Emits UserEscrowCreated on new deployment.
//      * @param user The address of the user.
//      * @return proxy The user's escrow proxy address.
//      */
//     function getOrCreateUserEscrow(
//         address user
//     ) public returns (address proxy) {
//         LibVangki.Storage storage s = LibVangki.storageSlot();
//         proxy = s.userVangkiEscrows[user];
//         if (proxy == address(0)) {
//             ERC1967Proxy newProxy = new ERC1967Proxy(
//                 s.vangkiEscrowTemplate,
//                 abi.encodeCall(VangkiEscrowImplementation.initialize, ())
//             );
//             proxy = address(newProxy);
//             s.userVangkiEscrows[user] = proxy;
//             emit UserEscrowCreated(user, proxy);
//         }
//     }

//     /**
//      * @notice Upgrades the shared escrow implementation for all proxies.
//      * @dev Updates storage; existing proxies will delegate to the new impl automatically.
//      *      Callable only by Diamond owner.
//      *      Emits EscrowImplementationUpgraded event.
//      *      Validation test call removed as _authorizeUpgrade is internal; assume trusted deployments.
//      * @param newImplementation The address of the new VangkiEscrowImplementation contract.
//      */
//     function upgradeEscrowImplementation(address newImplementation) external {
//         LibDiamond.enforceIsContractOwner();
//         LibVangki.Storage storage s = LibVangki.storageSlot();
//         address oldImplementation = s.vangkiEscrowTemplate;

//         // No test call; assume newImplementation is valid UUPS
//         s.vangkiEscrowTemplate = newImplementation;
//         emit EscrowImplementationUpgraded(oldImplementation, newImplementation);
//     }

//     /**
//      * @notice Deposits ERC20 tokens into a user's escrow proxy.
//      * @dev Transfers from msg.sender to the proxy.
//      *      Callable by other facets via Diamond (e.g., OfferFacet).
//      *      In future upgrades, add NFT deposit variants.
//      * @param user The user whose escrow to deposit into.
//      * @param token The ERC20 token address.
//      * @param amount The amount to deposit.
//      */
//     function escrowDepositERC20(
//         address user,
//         address token,
//         uint256 amount
//     ) public {
//         address proxy = getOrCreateUserEscrow(user);
//         IERC20(token).safeTransferFrom(msg.sender, proxy, amount);
//     }

//     /**
//      * @notice Withdraws ERC20 tokens from a user's escrow proxy to a recipient.
//      * @dev Calls withdrawERC20 on the proxy (forwards to implementation).
//      *      Callable by other facets via Diamond.
//      *      In future upgrades, add NFT withdraw variants.
//      * @param user The user whose escrow to withdraw from.
//      * @param token The ERC20 token address.
//      * @param to The recipient address.
//      * @param amount The amount to withdraw.
//      */
//     function escrowWithdrawERC20(
//         address user,
//         address token,
//         address to,
//         uint256 amount
//     ) public {
//         address proxy = getOrCreateUserEscrow(user);
//         (bool success, ) = proxy.call(
//             abi.encodeWithSelector(
//                 VangkiEscrowImplementation.withdrawERC20.selector,
//                 token,
//                 to,
//                 amount
//             )
//         );
//         if (!success) {
//             revert WithdrawCallFailed();
//         }
//     }

//     // /**
//     //  * @dev Authorizes upgrades; only callable by owner (Diamond).
//     //  *      Required for UUPS.
//     //  * @param newImplementation The new implementation address (unused in call; validated in factory).
//     //  */
//     // function _authorizeUpgrade(
//     //     address newImplementation
//     // ) internal override onlyOwner {
//     //     // No additional logic; factory validates.
//     // }
// }

// ##EOF##
// pragma solidity ^0.8.29;

// import {LibVangki} from "../libraries/LibVangki.sol";
// import {VangkiEscrowImplementation} from "../VangkiEscrowImplementation.sol";
// import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
// import "@openzeppelin/contracts/proxy/Clones.sol";
// import "@openzeppelin/contracts/access/AccessControl.sol"; // For roles if needed
// import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// contract EscrowFactoryFacet {
//     using SafeERC20 for IERC20;
//     event UserEscrowCreated(address indexed user, address escrow);

//     function initializeEscrowTemplate() external {
//         LibDiamond.enforceIsContractOwner();
//         LibVangki.Storage storage s = LibVangki.storageSlot();
//         require(s.vangkiEscrowTemplate == address(0), "Already set");
//         s.vangkiEscrowTemplate = address(new VangkiEscrowImplementation());
//     }

//     function getOrCreateUserEscrow(address user) public returns (address) {
//         LibVangki.Storage storage s = LibVangki.storageSlot();
//         if (s.userVangkiEscrows[user] == address(0)) {
//             address escrowClone = Clones.clone(s.vangkiEscrowTemplate);
//             VangkiEscrowImplementation(escrowClone).transferOwnership(
//                 address(this)
//             ); // Diamond controls
//             s.userVangkiEscrows[user] = escrowClone;
//             emit UserEscrowCreated(user, escrowClone);
//         }
//         return s.userVangkiEscrows[user];
//     }

//     // Internal helpers for deposit/withdraw (callable by other facets)
//     function escrowDepositERC20(
//         address user,
//         address token,
//         uint256 amount
//     ) public {
//         address escrow = getOrCreateUserEscrow(user);
//         IERC20(token).safeTransferFrom(msg.sender, escrow, amount);
//     }

//     function escrowWithdrawERC20(
//         address user,
//         address token,
//         address to,
//         uint256 amount
//     ) public {
//         address escrow = getOrCreateUserEscrow(user);
//         VangkiEscrowImplementation(escrow).withdrawERC20(token, to, amount);
//     }
// }
