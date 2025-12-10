// src/VangkiEscrowImplementation.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import "./interfaces/IERC4907.sol";

/**
 * @title VangkiEscrowImplementation
 * @author Vangki Developer Team
 * @notice This is the upgradable implementation for per-user escrow contracts in the Vangki platform.
 * @dev This contract uses UUPS for upgradeability and Ownable for access control (owned by the Diamond).
 *      It handles ERC20 deposits/withdrawals and NFT (ERC721/1155) deposits/withdrawals.
 *      Supports ERC-4907 for rentable NFTs: setUser, userOf, userExpires (calls on external NFT contracts).
 *      Implements IERC721Receiver and IERC1155Receiver for safe transfers.
 *      For ERC721 rentals: Escrow calls setUser without necessarily holding the NFT (assumes operator approval).
 *      For ERC1155: Holds tokens, calls setUser if the contract supports IERC4907 (try-catch to handle non-support).
 *      Custom errors for gas efficiency. No reentrancy as asset ops are atomic.
 *      Initialize sets owner to Diamond. Expand for Phase 2 (e.g., multi-asset batches).
 */
contract VangkiEscrowImplementation is
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC165Upgradeable,
    IERC721Receiver,
    IERC1155Receiver
{
    using SafeERC20 for IERC20;

    // Custom errors for clarity and gas efficiency.
    error NotAuthorized();
    error InvalidAmount();
    error TransferFailed();

    /**
     * @notice Initializes the escrow implementation.
     * @dev Sets the owner to the Diamond proxy. Called on deployment.
     *      Uses initializer modifier to prevent re-init.
     */
    function initialize() external initializer {
        __Ownable_init(msg.sender); // Diamond as owner
        __ERC165_init();
    }

    /**
     * @notice Deposits ERC-20 tokens into this escrow.
     * @dev Safe transfer from caller. Callable by owner (Diamond/facets).
     * @param token The ERC-20 token address.
     * @param amount The amount to deposit.
     */
    function depositERC20(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Withdraws ERC-20 tokens from this escrow to a recipient.
     * @dev Safe transfer. Callable by owner (Diamond/facets).
     * @param token The ERC-20 token address.
     * @param recipient The recipient address.
     * @param amount The amount to withdraw.
     */
    function withdrawERC20(
        address token,
        address recipient,
        uint256 amount
    ) external onlyOwner {
        IERC20(token).safeTransfer(recipient, amount);
    }

    /**
     * @notice Deposits an ERC-721 NFT into this escrow.
     * @dev Safe transfer from caller. Callable by owner.
     * @param nftContract The NFT contract address.
     * @param tokenId The token ID.
     */
    function depositERC721(
        address nftContract,
        uint256 tokenId
    ) external onlyOwner {
        IERC721(nftContract).safeTransferFrom(
            msg.sender,
            address(this),
            tokenId
        );
    }

    /**
     * @notice Withdraws an ERC-721 NFT from this escrow to a recipient.
     * @dev Safe transfer. Callable by owner.
     * @param nftContract The NFT contract address.
     * @param tokenId The token ID.
     * @param recipient The recipient address.
     */
    function withdrawERC721(
        address nftContract,
        uint256 tokenId,
        address recipient
    ) external onlyOwner {
        IERC721(nftContract).safeTransferFrom(
            address(this),
            recipient,
            tokenId
        );
    }

    /**
     * @notice Deposits ERC-1155 tokens into this escrow.
     * @dev Safe transfer from caller. Callable by owner.
     * @param nftContract The NFT contract address.
     * @param tokenId The token ID.
     * @param amount The amount to deposit.
     */
    function depositERC1155(
        address nftContract,
        uint256 tokenId,
        uint256 amount
    ) external onlyOwner {
        IERC1155(nftContract).safeTransferFrom(
            msg.sender,
            address(this),
            tokenId,
            amount,
            ""
        );
    }

    /**
     * @notice Withdraws ERC-1155 tokens from this escrow to a recipient.
     * @dev Safe transfer. Callable by owner.
     * @param nftContract The NFT contract address.
     * @param tokenId The token ID.
     * @param amount The amount to withdraw.
     * @param recipient The recipient address.
     */
    function withdrawERC1155(
        address nftContract,
        uint256 tokenId,
        uint256 amount,
        address recipient
    ) external onlyOwner {
        IERC1155(nftContract).safeTransferFrom(
            address(this),
            recipient,
            tokenId,
            amount,
            ""
        );
    }

    /**
     * @notice Approves this escrow as operator for an ERC-721 NFT (for rentals without holding).
     * @dev Calls IERC721.approve. Callable by owner (facets for lender offers).
     * @param nftContract The NFT contract address.
     * @param tokenId The token ID.
     */
    function approveERC721(
        address nftContract,
        uint256 tokenId
    ) external onlyOwner {
        IERC721(nftContract).approve(address(this), tokenId);
    }

    /**
     * @notice Sets the temporary user (renter) for a rentable NFT.
     * @dev Calls IERC4907.setUser on the external NFT contract.
     *      Uses try-catch to handle non-supporting contracts (reverts if fail).
     *      For ERC721: Assumes prior approval as operator.
     *      For ERC1155: Assumes held in escrow.
     *      Callable by owner (facets for loan acceptance).
     * @param nftContract The NFT contract address.
     * @param tokenId The token ID.
     * @param user The temporary user address.
     * @param expires The UNIX timestamp for expiration.
     */
    function setUser(
        address nftContract,
        uint256 tokenId,
        address user,
        uint64 expires
    ) external onlyOwner {
        try IERC4907(nftContract).setUser(tokenId, user, expires) {} catch {
            revert TransferFailed(); // Or custom error
        }
    }

    /**
     * @notice Gets the current user of a rentable NFT.
     * @dev Calls IERC4907.userOf on the external NFT contract.
     *      Returns zero on failure or non-support.
     *      View function.
     * @param nftContract The NFT contract address.
     * @param tokenId The token ID.
     * @return The current user address (zero if none or failure).
     */
    function userOf(
        address nftContract,
        uint256 tokenId
    ) external view returns (address) {
        try IERC4907(nftContract).userOf(tokenId) returns (
            address currentUser
        ) {
            return currentUser;
        } catch {
            return address(0);
        }
    }

    /**
     * @notice Gets the expiration timestamp for a rentable NFT's user.
     * @dev Calls IERC4907.userExpires on the external NFT contract.
     *      Returns 0 on failure or non-support.
     *      View function.
     * @param nftContract The NFT contract address.
     * @param tokenId The token ID.
     * @return The expiration timestamp (0 if none or failure).
     */
    function userExpires(
        address nftContract,
        uint256 tokenId
    ) external view returns (uint64) {
        try IERC4907(nftContract).userExpires(tokenId) returns (uint64 expiry) {
            return expiry;
        } catch {
            return 0;
        }
    }

    // Receiver hooks for safe transfers
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    // Supports interface for ERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165Upgradeable, IERC165) returns (bool) {
        return
            interfaceId == type(IERC721Receiver).interfaceId ||
            interfaceId == type(IERC1155Receiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // UUPS authorize upgrade
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
