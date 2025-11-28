// src/VangkiDiamond.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IDiamondCut} from "@diamond-3/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "@diamond-3/interfaces/IDiamondLoupe.sol";
import {IERC173} from "@diamond-3/interfaces/IERC173.sol"; // For ownership
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";

/**
 * @title VangkiDiamond
 * @author Vangki Developer Team
 * @notice This is the central proxy contract for the Vangki platform using the Diamond Standard (EIP-2535).
 * @dev Acts as the entry point for all calls, delegating to facets based on function selectors.
 *      Supports modular upgrades via diamondCut.
 *      Constructor initializes ownership and adds the DiamondCutFacet.
 *      Fallback handles delegation to facets; reverts if function not found.
 *      Receive allows ETH reception.
 *      No additional storage or logic; all in libraries/facets.
 *      Custom errors via LibDiamond.
 *      Deploy with owner (deployer/multi-sig) and DiamondCutFacet address.
 */
contract VangkiDiamond {
    error FunctionDoesNotExist();

    /**
     * @notice Constructs the VangkiDiamond proxy.
     * @dev Sets the contract owner and initializes with an empty cut (facets added post-deployment).
     *      Requires the DiamondCutFacet to be pre-deployed.
     * @param contractOwner The initial owner address (e.g., deployer or multi-sig).
     * @param diamondCutFacet The address of the deployed DiamondCutFacet.
     */

    constructor(address contractOwner, address diamondCutFacet) {
        LibDiamond.setContractOwner(contractOwner);

        // Add DiamondCutFacet via initial cut (empty facets array)
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](0);
        LibDiamond.diamondCut(cut, address(0), "");
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds
            .selectorToFacetAndPosition[IDiamondCut.diamondCut.selector]
            .facetAddress = diamondCutFacet;
    }

    /**
     * @dev Fallback function to delegate calls to the appropriate facet.
     *      Looks up the facet for msg.sig and delegates if found.
     *      Reverts if no facet supports the selector.
     */
    fallback() external payable {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
        if (facet == address(0)) {
            revert FunctionDoesNotExist();
        }
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    /**
     * @dev Receive function to accept ETH transfers.
     */
    receive() external payable {}
}

// ##EOF##
// pragma solidity ^0.8.29;

// import {IDiamondCut} from "@diamond-3/interfaces/IDiamondCut.sol";
// import {IDiamondLoupe} from "@diamond-3/interfaces/IDiamondLoupe.sol";
// import {IERC173} from "@diamond-3/interfaces/IERC173.sol"; // Ownership
// import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
// import {DiamondCutFacet} from "@diamond-3/facets/DiamondCutFacet.sol";
// import {DiamondLoupeFacet} from "@diamond-3/facets/DiamondLoupeFacet.sol";
// import {OwnershipFacet} from "@diamond-3/facets/OwnershipFacet.sol";

// contract VangkiDiamond {
//     constructor(address _contractOwner, address _diamondCutFacet) {
//         LibDiamond.setContractOwner(_contractOwner);
//         DiamondCutFacet diamondCutFacet = DiamondCutFacet(_diamondCutFacet);
//         diamondCutFacet.diamondCut(
//             new IDiamondCut.FacetCut[](0),
//             address(0),
//             new bytes(0)
//         );
//     }

//     fallback() external payable {
//         LibDiamond.DiamondStorage storage ds;
//         bytes32 position = LibDiamond.DIAMOND_STORAGE_POSITION;
//         assembly {
//             ds.slot := position
//         }
//         address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
//         require(facet != address(0), "Diamond: Function does not exist");
//         assembly {
//             calldatacopy(0, 0, calldatasize())
//             let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
//             returndatacopy(0, 0, returndatasize())
//             switch result
//             case 0 {
//                 revert(0, returndatasize())
//             }
//             default {
//                 return(0, returndatasize())
//             }
//         }
//     }

//     receive() external payable {}
// }
