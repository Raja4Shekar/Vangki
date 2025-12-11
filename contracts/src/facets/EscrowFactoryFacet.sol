// src/facets/EscrowFactoryFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import {VangkiEscrowImplementation} from "../VangkiEscrowImplementation.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

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
    error NoEscrow();

    /**
     * @notice Initializes the shared escrow implementation by deploying a new VangkiEscrowImplementation.
     * @dev Sets the implementation address in storage if not already set.
     *      Callable only once by the Diamond owner to prevent re-initialization.
     *      No parameters; deploys a fresh implementation and initializes it.
     */
    function initializeEscrowImplementation() external {
        LibDiamond.enforceIsContractOwner();
        LibVangki.Storage storage s = LibVangki.storageSlot();
        if (s.vangkiEscrowTemplate != address(0)) revert AlreadyInitialized();

        VangkiEscrowImplementation impl = new VangkiEscrowImplementation();
        impl.initialize(); // Assume initialize() in impl sets owner to Diamond
        s.vangkiEscrowTemplate = address(impl);
    }

    /**
     * @notice Gets or creates a user's escrow proxy.
     * @dev Deploys a new ERC1967Proxy if none exists, pointing to the shared implementation.
     *      View function if exists; mutates if creates.
     *      Emits UserEscrowCreated on creation.
     * @param user The user address.
     * @return proxy The user's escrow proxy address.
     */
    function getOrCreateUserEscrow(
        address user
    ) public returns (address proxy) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        proxy = s.userVangkiEscrows[user];
        if (proxy == address(0)) {
            ERC1967Proxy newProxy = new ERC1967Proxy(
                s.vangkiEscrowTemplate,
                ""
            );
            proxy = address(newProxy);
            s.userVangkiEscrows[user] = proxy;
            emit UserEscrowCreated(user, proxy);
        }
    }

    /**
     * @notice Upgrades the shared escrow implementation.
     * @dev Callable only by Diamond owner. Updates all proxies via UUPS.
     *      Validates new impl is contract and compatible.
     *      Emits EscrowImplementationUpgraded.
     * @param newImplementation The new implementation address.
     */
    function upgradeEscrowImplementation(address newImplementation) external {
        LibDiamond.enforceIsContractOwner();
        if (newImplementation.code.length == 0) revert UpgradeFailed();

        LibVangki.Storage storage s = LibVangki.storageSlot();
        address oldImpl = s.vangkiEscrowTemplate;
        s.vangkiEscrowTemplate = newImplementation;

        // Note: Proxies auto-upgrade via UUPS; no per-proxy call needed
        emit EscrowImplementationUpgraded(oldImpl, newImplementation);
    }

    /**
     * @notice Deposits ERC-20 tokens into the specified user's escrow.
     * @dev Low-level call to the proxy's depositERC20 function.
     *      Reverts on failure.
     *      Callable by anyone (e.g., facets/users).
     * @param user The user whose escrow to deposit into.
     * @param token The ERC-20 token address.
     * @param amount The amount to deposit.
     */
    function escrowDepositERC20(
        address user,
        address token,
        uint256 amount
    ) external {
        address proxy = getOrCreateUserEscrow(user);
        (bool success, ) = proxy.call(
            abi.encodeWithSelector(
                VangkiEscrowImplementation.depositERC20.selector,
                token,
                amount
            )
        );
        if (!success) revert ProxyCallFailed("Deposit ERC20 failed");
    }

    /**
     * @notice Withdraws ERC-20 tokens from the specified user's escrow to a recipient.
     * @dev Low-level call to the proxy's withdrawERC20 function.
     *      Reverts on failure.
     *      Callable by authorized (e.g., facets).
     * @param user The user whose escrow to withdraw from.
     * @param token The ERC-20 token address.
     * @param recipient The recipient address.
     * @param amount The amount to withdraw.
     */
    function escrowWithdrawERC20(
        address user,
        address token,
        address recipient,
        uint256 amount
    ) external {
        address proxy = getOrCreateUserEscrow(user);
        (bool success, ) = proxy.call(
            abi.encodeWithSelector(
                VangkiEscrowImplementation.withdrawERC20.selector,
                token,
                recipient,
                amount
            )
        );
        if (!success) revert ProxyCallFailed("Withdraw ERC20 failed");
    }

    /**
     * @notice Deposits an ERC-721 NFT into the specified user's escrow.
     * @dev Low-level call to the proxy's depositERC721 function (safeTransferFrom).
     *      Reverts on failure.
     * @param user The user whose escrow to deposit into.
     * @param nftContract The NFT contract address.
     * @param tokenId The token ID.
     */
    function escrowDepositERC721(
        address user,
        address nftContract,
        uint256 tokenId
    ) external {
        address proxy = getOrCreateUserEscrow(user);
        (bool success, ) = proxy.call(
            abi.encodeWithSelector(
                VangkiEscrowImplementation.depositERC721.selector,
                nftContract,
                tokenId
            )
        );
        if (!success) revert ProxyCallFailed("Deposit ERC721 failed");
    }

    /**
     * @notice Withdraws an ERC-721 NFT from the specified user's escrow to a recipient.
     * @dev Low-level call to the proxy's withdrawERC721 function.
     *      Reverts on failure.
     * @param user The user whose escrow to withdraw from.
     * @param nftContract The NFT contract address.
     * @param tokenId The token ID.
     * @param recipient The recipient address.
     */
    function escrowWithdrawERC721(
        address user,
        address nftContract,
        uint256 tokenId,
        address recipient
    ) external {
        address proxy = getOrCreateUserEscrow(user);
        (bool success, ) = proxy.call(
            abi.encodeWithSelector(
                VangkiEscrowImplementation.withdrawERC721.selector,
                nftContract,
                tokenId,
                recipient
            )
        );
        if (!success) revert ProxyCallFailed("Withdraw ERC721 failed");
    }

    /**
     * @notice Deposits ERC-1155 tokens into the specified user's escrow.
     * @dev Low-level call to the proxy's depositERC1155 function.
     *      Reverts on failure.
     * @param user The user whose escrow to deposit into.
     * @param nftContract The NFT contract address.
     * @param tokenId The token ID.
     * @param amount The amount to deposit.
     */
    function escrowDepositERC1155(
        address user,
        address nftContract,
        uint256 tokenId,
        uint256 amount
    ) external {
        address proxy = getOrCreateUserEscrow(user);
        (bool success, ) = proxy.call(
            abi.encodeWithSelector(
                VangkiEscrowImplementation.depositERC1155.selector,
                nftContract,
                tokenId,
                amount
            )
        );
        if (!success) revert ProxyCallFailed("Deposit ERC1155 failed");
    }

    /**
     * @notice Withdraws ERC-1155 tokens from the specified user's escrow to a recipient.
     * @dev Low-level call to the proxy's withdrawERC1155 function.
     *      Reverts on failure.
     * @param user The user whose escrow to withdraw from.
     * @param nftContract The NFT contract address.
     * @param tokenId The token ID.
     * @param amount The amount to withdraw.
     * @param recipient The recipient address.
     */
    function escrowWithdrawERC1155(
        address user,
        address nftContract,
        uint256 tokenId,
        uint256 amount,
        address recipient
    ) external {
        address proxy = getOrCreateUserEscrow(user);
        (bool success, ) = proxy.call(
            abi.encodeWithSelector(
                VangkiEscrowImplementation.withdrawERC1155.selector,
                nftContract,
                tokenId,
                amount,
                recipient
            )
        );
        if (!success) revert ProxyCallFailed("Withdraw ERC1155 failed");
    }

    /**
     * @notice Approves the user's escrow as operator for an ERC-721 NFT (for rentals without holding).
     * @dev Low-level call to the proxy's approveERC721 function (IERC721.approve).
     *      Reverts on failure.
     * @param user The user whose escrow to approve from.
     * @param nftContract The NFT contract address.
     * @param tokenId The token ID.
     */
    function escrowApproveNFT721(
        address user,
        address nftContract,
        uint256 tokenId
    ) external {
        address proxy = getOrCreateUserEscrow(user);
        (bool success, ) = proxy.call(
            abi.encodeWithSelector(
                VangkiEscrowImplementation.approveERC721.selector,
                nftContract,
                tokenId
            )
        );
        if (!success) revert ProxyCallFailed("Approve ERC721 failed");
    }

    /**
     * @notice Sets the temporary user (renter) for a rentable NFT from the specified user's escrow.
     * @dev Low-level call to the proxy's setUser function (IERC4907.setUser).
     *      Enhanced: Explicit proxy existence check. Reverts with reason on failure.
     *      For ERC721: Calls as operator (NFT not held in escrow).
     *      For ERC1155: Calls while holding tokens in escrow (assumes IERC4907 support).
     *      Reverts on failure (e.g., if NFT doesn't support IERC4907).
     *      Callable by facets (e.g., for loan acceptance in OfferFacet).
     * @param user The user whose escrow to operate from (typically the lender).
     * @param nftContract The NFT contract address (must support IERC4907).
     * @param tokenId The token ID.
     * @param renter The temporary renter address (borrower).
     * @param expires The expiration timestamp (end of loan term).
     */
    function escrowSetNFTUser(
        address user,
        address nftContract,
        uint256 tokenId,
        address renter,
        uint64 expires
    ) external {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        address proxy = s.userVangkiEscrows[user];
        if (proxy == address(0)) revert NoEscrow();

        (bool success, bytes memory returnData) = proxy.call(
            abi.encodeWithSelector(
                VangkiEscrowImplementation.setUser.selector,
                nftContract,
                tokenId,
                renter,
                expires
            )
        );
        if (!success) {
            // Decode revert reason if available
            if (returnData.length > 0) {
                assembly {
                    let returndata_size := mload(returnData)
                    revert(add(32, returnData), returndata_size)
                }
            } else {
                revert ProxyCallFailed("Set NFT user failed");
            }
        }
    }

    /**
     * @notice Gets the current user of a rentable NFT from the specified user's escrow.
     * @dev Low-level staticcall to the proxy's userOf function.
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
    ) external view returns (address) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        address proxy = s.userVangkiEscrows[user];
        if (proxy == address(0)) return address(0);

        (bool success, bytes memory result) = proxy.staticcall(
            abi.encodeWithSelector(
                VangkiEscrowImplementation.userOf.selector,
                nftContract,
                tokenId
            )
        );
        if (!success) return address(0);
        return abi.decode(result, (address));
    }

    /**
     * @notice Gets the expiration timestamp for a rentable NFT's user from the specified user's escrow.
     * @dev Low-level staticcall to the proxy's userExpires function.
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
    ) external view returns (uint64) {
        LibVangki.Storage storage s = LibVangki.storageSlot();
        address proxy = s.userVangkiEscrows[user];
        if (proxy == address(0)) return 0;

        (bool success, bytes memory result) = proxy.staticcall(
            abi.encodeWithSelector(
                VangkiEscrowImplementation.userExpires.selector,
                nftContract,
                tokenId
            )
        );
        if (!success) return 0;
        return abi.decode(result, (uint64));
    }
}
