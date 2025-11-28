// src/VangkiEscrowImplementation.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol"; // Reverted to OwnableUpgradeable
import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

/**
 * @title IERC4907
 * @notice Interface for ERC-4907 rentable NFTs.
 * @dev Defines functions for setting and querying temporary users.
 */
interface IERC4907 {
    /**
     * @notice Emitted when the user of an NFT is changed or expires.
     * @param tokenId The NFT token ID.
     * @param user The new user address.
     * @param expires The expiration timestamp.
     */
    event UpdateUser(
        uint256 indexed tokenId,
        address indexed user,
        uint64 expires
    );

    /**
     * @notice Sets the temporary user of an NFT.
     * @dev Caller must be approved or owner.
     * @param tokenId The token ID.
     * @param user The temporary user address.
     * @param expires The UNIX timestamp for expiration.
     */
    function setUser(uint256 tokenId, address user, uint64 expires) external;

    /**
     * @notice Gets the current user of an NFT.
     * @param tokenId The token ID.
     * @return The current user address (zero if expired or none).
     */
    function userOf(uint256 tokenId) external view returns (address);

    /**
     * @notice Gets the expiration timestamp for an NFT's user.
     * @param tokenId The token ID.
     * @return The expiration timestamp (zero if none).
     */
    function userExpires(uint256 tokenId) external view returns (uint64);
}

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
 *      Initialization is called on proxy deployment; sets owner to Diamond.
 *      Custom errors for gas efficiency. No events as they can be emitted by the factory/facet.
 *      Storage layout must be preserved for upgrades (no new variables before existing ones).
 *      Overrides supportsInterface to resolve inheritance conflicts and indicate supported interfaces.
 */
contract VangkiEscrowImplementation is
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC165Upgradeable,
    IERC721Receiver,
    IERC1155Receiver
{
    using SafeERC20 for IERC20;

    // No additional storage variables in base; add in upgrades at the end.

    // Custom errors for clarity and gas efficiency.
    error InvalidNFTType();
    error UnauthorizedCaller();
    error InvalidExpiration();
    error SetUserFailed();
    error QueryFailed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the escrow implementation (called on proxy creation).
     * @dev Sets the owner to the Diamond (msg.sender during proxy init).
     *      Uses OZ initializers for safety.
     */
    function initialize() external initializer {
        __Ownable_init(msg.sender);
        __ERC165_init();
    }

    /**
     * @notice Deposits ERC20 tokens into this escrow.
     * @dev Transfers from msg.sender to this contract.
     *      Only callable by owner (Diamond).
     * @param token The ERC20 token address.
     * @param amount The amount to deposit.
     */
    function depositERC20(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Withdraws ERC20 tokens from this escrow to a recipient.
     * @dev Transfers to the specified address.
     *      Only callable by owner (Diamond).
     * @param token The ERC20 token address.
     * @param to The recipient address.
     * @param amount The amount to withdraw.
     */
    function withdrawERC20(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Returns the ERC20 balance of this escrow.
     * @dev View function for querying balances.
     * @param token The ERC20 token address.
     * @return The balance held in this escrow.
     */
    function balanceOfERC20(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /**
     * @notice Deposits an NFT (ERC721 or ERC1155) into this escrow.
     * @dev For ERC721 (isERC1155=false): Uses safeTransferFrom; assumes approval granted.
     *      For ERC1155 (isERC1155=true): Uses safeTransferFrom with quantity (amount).
     *      Only callable by owner (Diamond).
     * @param nftContract The NFT contract address.
     * @param tokenId The token ID.
     * @param isERC1155 True for ERC1155, false for ERC721.
     * @param amount For ERC1155: quantity; for ERC721: ignored (set to 1).
     */
    function depositNFT(
        address nftContract,
        uint256 tokenId,
        bool isERC1155,
        uint256 amount
    ) external onlyOwner {
        if (isERC1155) {
            IERC1155(nftContract).safeTransferFrom(
                msg.sender,
                address(this),
                tokenId,
                amount,
                ""
            );
        } else {
            IERC721(nftContract).safeTransferFrom(
                msg.sender,
                address(this),
                tokenId
            );
        }
    }

    /**
     * @notice Withdraws an NFT (ERC721 or ERC1155) from this escrow to a recipient.
     * @dev For ERC721: Uses safeTransferFrom.
     *      For ERC1155: Uses safeTransferFrom with quantity.
     *      Only callable by owner (Diamond).
     * @param nftContract The NFT contract address.
     * @param to The recipient address.
     * @param tokenId The token ID.
     * @param isERC1155 True for ERC1155, false for ERC721.
     * @param amount For ERC1155: quantity; for ERC721: ignored (set to 1).
     */
    function withdrawNFT(
        address nftContract,
        address to,
        uint256 tokenId,
        bool isERC1155,
        uint256 amount
    ) external onlyOwner {
        if (isERC1155) {
            IERC1155(nftContract).safeTransferFrom(
                address(this),
                to,
                tokenId,
                amount,
                ""
            );
        } else {
            IERC721(nftContract).safeTransferFrom(address(this), to, tokenId);
        }
    }

    /**
     * @notice Returns the balance or ownership of an NFT in this escrow.
     * @dev For ERC721: Returns 1 if owned, 0 otherwise.
     *      For ERC1155: Returns the balance for the tokenId.
     * @param nftContract The NFT contract address.
     * @param tokenId The token ID.
     * @param isERC1155 True for ERC1155, false for ERC721.
     * @return The balance (ERC1155) or ownership count (ERC721: 0 or 1).
     */
    function balanceOfNFT(
        address nftContract,
        uint256 tokenId,
        bool isERC1155
    ) external view returns (uint256) {
        if (isERC1155) {
            return IERC1155(nftContract).balanceOf(address(this), tokenId);
        } else {
            try IERC721(nftContract).ownerOf(tokenId) returns (address owner) {
                return owner == address(this) ? 1 : 0;
            } catch {
                return 0;
            }
        }
    }

    /**
     * @notice Sets a temporary user for a rentable NFT (ERC-4907 compliant).
     * @dev Calls setUser on the external NFT contract.
     *      For ERC721: Escrow must be approved as operator (NFT may remain with owner).
     *      For ERC1155: Assumes escrow holds it.
     *      Reverts if call fails (e.g., not supported or unauthorized).
     *      Only callable by owner (Diamond).
     * @param nftContract The NFT contract address (must support IERC4907).
     * @param tokenId The token ID.
     * @param user The temporary user address (zero to revoke).
     * @param expires The UNIX timestamp for expiration.
     */
    function setNFTUser(
        address nftContract,
        uint256 tokenId,
        address user,
        uint64 expires
    ) external onlyOwner {
        if (expires < uint64(block.timestamp)) {
            revert InvalidExpiration();
        }
        (bool success, ) = nftContract.call(
            abi.encodeWithSelector(
                IERC4907.setUser.selector,
                tokenId,
                user,
                expires
            )
        );
        if (!success) {
            revert SetUserFailed();
        }
    }

    /**
     * @notice Gets the current user of a rentable NFT.
     * @dev Calls userOf on the external NFT contract; returns zero on failure.
     * @param nftContract The NFT contract address.
     * @param tokenId The token ID.
     * @return The current user address (zero if expired, none, or failure).
     */
    function getNFTUserOf(
        address nftContract,
        uint256 tokenId
    ) external view returns (address) {
        (bool success, bytes memory result) = nftContract.staticcall(
            abi.encodeWithSelector(IERC4907.userOf.selector, tokenId)
        );
        if (!success) {
            return address(0);
        }
        return abi.decode(result, (address));
    }

    /**
     * @notice Gets the expiration timestamp for a rentable NFT's user.
     * @dev Calls userExpires on the external NFT contract; returns zero on failure.
     * @param nftContract The NFT contract address.
     * @param tokenId The token ID.
     * @return The expiration timestamp (zero if none or failure).
     */
    function getNFTUserExpires(
        address nftContract,
        uint256 tokenId
    ) external view returns (uint64) {
        (bool success, bytes memory result) = nftContract.staticcall(
            abi.encodeWithSelector(IERC4907.userExpires.selector, tokenId)
        );
        if (!success) {
            return 0;
        }
        return abi.decode(result, (uint64));
    }

    /**
     * @notice ERC721 safe transfer receiver hook.
     * @dev Returns the selector to accept the transfer.
     * @return The magic value (IERC721Receiver.onERC721Received.selector).
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /**
     * @notice ERC1155 safe transfer receiver hook.
     * @dev Returns the selector to accept the transfer.
     * @return The magic value (IERC1155Receiver.onERC1155Received.selector).
     */
    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external override returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    /**
     * @notice ERC1155 batch safe transfer receiver hook.
     * @dev Returns the selector to accept the batch transfer.
     * @return The magic value (IERC1155Receiver.onERC1155BatchReceived.selector).
     */
    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external override returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    /**
     * @notice Checks if the contract supports a given interface.
     * @dev Overrides ERC165 to support multiple interfaces (e.g., IERC721Receiver, IERC1155Receiver).
     *      Returns true for supported interfaces.
     * @param interfaceId The interface ID to check.
     * @return True if supported, false otherwise.
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165Upgradeable, IERC165) returns (bool) {
        return
            interfaceId == type(IERC721Receiver).interfaceId ||
            interfaceId == type(IERC1155Receiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /**
     * @dev Authorizes upgrades; only callable by owner (Diamond).
     *      Required for UUPS.
     * @param newImplementation The new implementation address (unused in call; validated in factory).
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {
        // No additional logic; factory validates.
    }
}
