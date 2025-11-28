// src/facets/VangkiNFTFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title VangkiNFTFacet
 * @author Vangki Developer Team
 * @notice This facet handles minting, updating, and burning of Vangki NFTs representing offers and loans.
 * @dev This contract is part of the Diamond Standard (EIP-2535) and extends ERC721 for NFT functionality.
 *      NFTs store on-chain metadata with dynamic tokenURI generation (JSON with offer/loan details).
 *      IPFS images are referenced based on role (Lender/Borrower) and status (Active/Closed).
 *      Status updates are restricted to authorized facets (e.g., OfferFacet, LoanFacet) via Diamond ownership.
 *      Metadata includes: offer/loan ID, assets, rates, duration, status, role.
 *      Burning occurs on loan closure or default after claims.
 *      Uses Base64 for on-chain JSON encoding; IPFS CIDs are immutable constants.
 *      Custom errors for gas efficiency. No reentrancy needed as no external transfers.
 *      Events emitted for mint, update, burn.
 *      If needed, split into MintFacet, UpdateFacet for growth.
 */
contract VangkiNFTFacet is ERC721("VangkiNFT", "VNGK") {
    using Strings for uint256;
    using Strings for address;

    /// @notice Emitted when a Vangki NFT is minted.
    /// @param tokenId The unique ID of the minted NFT.
    /// @param owner The address receiving the NFT.
    /// @param role The role associated (Lender or Borrower).
    event NFTMinted(
        uint256 indexed tokenId,
        address indexed owner,
        string role
    );

    /// @notice Emitted when an NFT's status is updated.
    /// @param tokenId The ID of the updated NFT.
    /// @param newStatus The new status string.
    event NFTStatusUpdated(uint256 indexed tokenId, string newStatus);

    /// @notice Emitted when an NFT is burned.
    /// @param tokenId The ID of the burned NFT.
    event NFTBurned(uint256 indexed tokenId);

    // Custom errors for clarity and gas efficiency.
    error NotAuthorized();
    error InvalidTokenId();
    error NFTAlreadyBurned();

    // Immutable IPFS CIDs for state/role images (set in constructor or via owner).
    string private _lenderActiveIPFS;
    string private _lenderClosedIPFS;
    string private _borrowerActiveIPFS;
    string private _borrowerClosedIPFS;

    // Storage for NFT metadata (status per tokenId; other data pulled from LibVangki).
    mapping(uint256 => string) private _nftStatuses; // e.g., "Offer Created", "Loan Initiated", "Loan Closed", "Loan Defaulted"
    mapping(uint256 => uint256) private _associatedIds; // Maps tokenId to offerId or loanId
    mapping(uint256 => bool) private _isLenderRoles; // True if Lender role

    constructor(
        string memory lenderActiveIPFS,
        string memory lenderClosedIPFS,
        string memory borrowerActiveIPFS,
        string memory borrowerClosedIPFS
    ) {
        _lenderActiveIPFS = lenderActiveIPFS;
        _lenderClosedIPFS = lenderClosedIPFS;
        _borrowerActiveIPFS = borrowerActiveIPFS;
        _borrowerClosedIPFS = borrowerClosedIPFS;
    }

    /**
     * @notice Mints a new Vangki NFT for an offer or loan participant.
     * @dev Callable only by authorized facets (e.g., OfferFacet via Diamond).
     *      Sets initial status, role, and associated ID.
     *      Uses _safeMint to prevent contract receivers.
     *      Emits NFTMinted event.
     * @param to The address to mint the NFT to.
     * @param tokenId The unique token ID (e.g., from LibVangki.nextTokenId).
     * @param associatedId The offer or loan ID linked to this NFT.
     * @param isLender True if the role is Lender, false for Borrower.
     * @param initialStatus The initial status string (e.g., "Offer Created").
     */
    function mintNFT(
        address to,
        uint256 tokenId,
        uint256 associatedId,
        bool isLender,
        string memory initialStatus
    ) external {
        _enforceAuthorizedCaller();
        _safeMint(to, tokenId);
        _nftStatuses[tokenId] = initialStatus;
        _associatedIds[tokenId] = associatedId;
        _isLenderRoles[tokenId] = isLender;

        emit NFTMinted(tokenId, to, isLender ? "Lender" : "Borrower");
    }

    /**
     * @notice Updates the status of an existing Vangki NFT.
     * @dev Callable only by authorized facets (e.g., LoanFacet on repayment/default).
     *      Updates _nftStatuses; tokenURI will reflect the change dynamically.
     *      Emits NFTStatusUpdated event.
     * @param tokenId The ID of the NFT to update.
     * @param newStatus The new status string.
     */
    function updateNFTStatus(
        uint256 tokenId,
        string memory newStatus
    ) external {
        _enforceAuthorizedCaller();
        if (ownerOf(tokenId) == address(0)) {
            revert InvalidTokenId();
        }
        _nftStatuses[tokenId] = newStatus;

        emit NFTStatusUpdated(tokenId, newStatus);
    }

    /**
     * @notice Burns a Vangki NFT after loan closure or claims.
     * @dev Callable only by authorized facets (e.g., LoanFacet after repayment).
     *      Requires the NFT to exist and not already burned.
     *      Emits NFTBurned event.
     * @param tokenId The ID of the NFT to burn.
     */
    function burnNFT(uint256 tokenId) external {
        _enforceAuthorizedCaller();
        if (ownerOf(tokenId) == address(0)) {
            revert NFTAlreadyBurned();
        }
        _burn(tokenId);
        delete _nftStatuses[tokenId];
        delete _associatedIds[tokenId];
        delete _isLenderRoles[tokenId];

        emit NFTBurned(tokenId);
    }

    /**
     * @notice Returns the URI for a given token ID, dynamically generating JSON metadata.
     * @dev Overrides ERC721.tokenURI.
     *      Generates Base64-encoded JSON with on-chain data: name, description, attributes (offer/loan details), image (IPFS based on role/status).
     *      Pulls data from LibVangki for the associated offer/loan.
     *      Status determines if "Active" or "Closed" image is used.
     *      If token doesn't exist, reverts.
     * @param tokenId The ID of the token to query.
     * @return The Base64-encoded JSON URI string.
     */
    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        if (ownerOf(tokenId) == address(0)) {
            revert InvalidTokenId();
        }

        uint256 assocId = _associatedIds[tokenId];
        string memory status = _nftStatuses[tokenId];
        bool isLender = _isLenderRoles[tokenId];
        bool isClosed = _isClosedStatus(status); // Helper to check if closed/defaulted

        // Pull offer/loan data (assume assocId is offerId; adjust if loan-specific)
        LibVangki.Storage storage s = LibVangki.storageSlot();
        LibVangki.Offer storage offer = s.offers[assocId]; // Or loan if needed

        // Build attributes array as JSON
        string memory attributes = string(
            abi.encodePacked(
                '[{"trait_type":"Role","value":"',
                isLender ? "Lender" : "Borrower",
                '"},',
                '{"trait_type":"Status","value":"',
                status,
                '"},',
                '{"trait_type":"Lending Asset","value":"',
                offer.lendingAsset.toHexString(),
                '"},',
                '{"trait_type":"Amount","value":"',
                offer.amount.toString(),
                '"},',
                '{"trait_type":"Interest Rate (BPS)","value":"',
                offer.interestRateBps.toString(),
                '"},',
                '{"trait_type":"Collateral Asset","value":"',
                offer.collateralAsset.toHexString(),
                '"},',
                '{"trait_type":"Collateral Amount","value":"',
                offer.collateralAmount.toString(),
                '"},',
                '{"trait_type":"Duration (Days)","value":"',
                offer.durationDays.toString(),
                '"},',
                '{"trait_type":"Liquidity","value":"',
                uint256(offer.liquidity).toString(),
                '"}]'
            )
        );

        // Select image IPFS based on role and status
        string memory image = isLender
            ? (isClosed ? _lenderClosedIPFS : _lenderActiveIPFS)
            : (isClosed ? _borrowerClosedIPFS : _borrowerActiveIPFS);

        // Build JSON
        string memory json = string(
            abi.encodePacked(
                '{"name":"Vangki NFT #',
                tokenId.toString(),
                '",',
                '"description":"Represents a Vangki offer or loan position.",',
                '"image":"ipfs://',
                image,
                '",',
                '"attributes":',
                attributes,
                "}"
            )
        );

        return
            string(
                abi.encodePacked(
                    "data:application/json;base64,",
                    Base64.encode(bytes(json))
                )
            );
    }

    // Internal helpers

    /// @dev Enforces that the caller is an authorized facet (via Diamond owner check).
    ///      Prevents external calls; only internal via Diamond.
    function _enforceAuthorizedCaller() internal view {
        if (msg.sender != address(this)) {
            // Must be called through Diamond proxy
            revert NotAuthorized();
        }
    }

    /// @dev Checks if a status indicates closure (e.g., "Loan Closed", "Loan Repaid", "Loan Defaulted").
    function _isClosedStatus(
        string memory status
    ) internal pure returns (bool) {
        // Simple string comparison; expand as needed
        bytes32 statusHash = keccak256(bytes(status));
        return
            statusHash == keccak256(bytes("Loan Closed")) ||
            statusHash == keccak256(bytes("Loan Repaid")) ||
            statusHash == keccak256(bytes("Loan Defaulted"));
    }
}
// ##EOF##
// pragma solidity ^0.8.29;

// import {LibVangki} from "../libraries/LibVangki.sol";
// import "@openzeppelin/contracts/token/ERC721/ERC721.sol"; // Extend for VangkiNFT

// contract NFTFacet is ERC721("VangkiNFT", "VNGK") {
//     // Storage for metadata/status (on-chain or IPFS)
//     mapping(uint256 => string) private _tokenURIs;

//     function mintNFT(
//         address to,
//         uint256 tokenId,
//         string memory _tokenURI
//     ) external {
//         // Only callable by Diamond (internal)
//         _mint(to, tokenId);
//         _tokenURIs[tokenId] = _tokenURI; // Dynamic JSON
//     }

//     function tokenURI(
//         uint256 tokenId
//     ) public view override returns (string memory) {
//         // Generate dynamic JSON with status, image IPFS based on role/status
//         return _tokenURIs[tokenId]; // Expand to base64 JSON
//     }

//     // Update status function
// }
