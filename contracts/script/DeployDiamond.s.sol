// script/DeployDiamond.s.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Script.sol";
import "../src/VangkiDiamond.sol";
import "../src/facets/DiamondCutFacet.sol";
import "../src/facets/DiamondLoupeFacet.sol";
import "../src/facets/OwnershipFacet.sol";
import "../src/facets/OfferFacet.sol";
import "../src/facets/LoanFacet.sol";
import "../src/facets/EscrowFactoryFacet.sol";
import "../src/facets/OracleFacet.sol";
// import "../src/facets/VangkiNFTFacet.sol";
import "../src/facets/RiskFacet.sol";
import {IDiamondCut} from "@diamond-3/interfaces/IDiamondCut.sol";

contract DeployDiamond is Script {
    function run() external {
        vm.startBroadcast();

        // Deploy facets
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        OfferFacet offerFacet = new OfferFacet();
        LoanFacet loanFacet = new LoanFacet();
        EscrowFactoryFacet escrowFactoryFacet = new EscrowFactoryFacet();
        OracleFacet oracleFacet = new OracleFacet();
        VangkiNFTFacet nftFacet = new VangkiNFTFacet("", "", "", "");
        RiskFacet riskFacet = new RiskFacet();

        // Deploy Diamond (with owner as deployer; change to multi-sig if needed)
        address owner = msg.sender;
        VangkiDiamond diamond = new VangkiDiamond(owner, address(cutFacet));

        // Prepare diamondCut: Add all facets
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](8); // Number of facets

        // Cut for DiamondLoupeFacet
        bytes4[] memory loupeSelectors = new bytes4[](4);
        loupeSelectors[0] = IDiamondLoupe.facets.selector;
        loupeSelectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        loupeSelectors[2] = IDiamondLoupe.facetAddresses.selector;
        loupeSelectors[3] = IDiamondLoupe.facetAddress.selector;
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(loupeFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: loupeSelectors
        });

        // Cut for OwnershipFacet
        bytes4[] memory ownershipSelectors = new bytes4[](2);
        ownershipSelectors[0] = IERC173.owner.selector;
        ownershipSelectors[1] = IERC173.transferOwnership.selector;
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(ownershipFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: ownershipSelectors
        });

        // Cut for OfferFacet (add selectors; assume 3 for example)
        bytes4[] memory offerSelectors = new bytes4[](3);
        offerSelectors[0] = OfferFacet.createOffer.selector;
        offerSelectors[1] = OfferFacet.acceptOffer.selector;
        offerSelectors[2] = OfferFacet.cancelOffer.selector;
        cuts[2] = IDiamondCut.FacetCut({
            facetAddress: address(offerFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: offerSelectors
        });

        // Cut for LoanFacet (add selectors; assume 2)
        bytes4[] memory loanSelectors = new bytes4[](2);
        loanSelectors[0] = LoanFacet.repayLoan.selector;
        loanSelectors[1] = LoanFacet.triggerDefault.selector;
        cuts[3] = IDiamondCut.FacetCut({
            facetAddress: address(loanFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: loanSelectors
        });

        // Cut for EscrowFactoryFacet (add selectors; assume 5)
        bytes4[] memory escrowSelectors = new bytes4[](5);
        escrowSelectors[0] = EscrowFactoryFacet
            .initializeEscrowImplementation
            .selector;
        escrowSelectors[1] = EscrowFactoryFacet.getOrCreateUserEscrow.selector;
        escrowSelectors[2] = EscrowFactoryFacet.escrowDepositERC20.selector;
        escrowSelectors[3] = EscrowFactoryFacet.escrowWithdrawERC20.selector;
        escrowSelectors[4] = EscrowFactoryFacet
            .upgradeEscrowImplementation
            .selector;
        cuts[4] = IDiamondCut.FacetCut({
            facetAddress: address(escrowFactoryFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: escrowSelectors
        });

        // Cut for OracleFacet (add selectors; assume 2)
        bytes4[] memory oracleSelectors = new bytes4[](2);
        oracleSelectors[0] = OracleFacet.updateLiquidAsset.selector;
        oracleSelectors[1] = OracleFacet.checkLiquidity.selector;
        cuts[5] = IDiamondCut.FacetCut({
            facetAddress: address(oracleFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: oracleSelectors
        });

        // Cut for VangkiNFTFacet (add selectors; assume 3)
        bytes4[] memory nftSelectors = new bytes4[](3);
        nftSelectors[0] = VangkiNFTFacet.mintNFT.selector;
        nftSelectors[1] = VangkiNFTFacet.updateNFTStatus.selector;
        nftSelectors[2] = VangkiNFTFacet.burnNFT.selector;
        cuts[6] = IDiamondCut.FacetCut({
            facetAddress: address(nftFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: nftSelectors
        });

        // Cut for RiskFacet (add selectors; assume 2)
        bytes4[] memory riskSelectors = new bytes4[](2);
        riskSelectors[0] = RiskFacet.updateAssetRiskParams.selector;
        riskSelectors[1] = RiskFacet.calculateHealthFactor.selector;
        cuts[7] = IDiamondCut.FacetCut({
            facetAddress: address(riskFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: riskSelectors
        });

        // Execute diamondCut (no init calldata)
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");

        // Initialize EscrowFactoryFacet
        (bool success, ) = address(diamond).call(
            abi.encodeWithSelector(
                EscrowFactoryFacet.initializeEscrowImplementation.selector
            )
        );
        require(success, "Escrow init failed");

        vm.stopBroadcast();
    }
}
// ##EOF##
// pragma solidity ^0.8.29;

// import "forge-std/Script.sol";
// import "../src/VangkiDiamond.sol";
// import "@diamond-3/facets/DiamondCutFacet.sol";
// import "@diamond-3/facets/DiamondLoupeFacet.sol";
// import "@diamond-3/facets/OwnershipFacet.sol";
// import "../src/facets/OfferFacet.sol";
// import "../src/facets/LoanFacet.sol";
// // import "../src/facets/EscrowFacet.sol";
// // import "../src/facets/OracleFacet.sol";
// // import "../src/facets/VangkiNFTFacet.sol";
// import {IDiamondCut} from "@diamond-3/interfaces/IDiamondCut.sol";

// contract DeployDiamond is Script {
//     function run() external {
//         vm.startBroadcast();

//         // Deploy facets
//         DiamondCutFacet cutFacet = new DiamondCutFacet();
//         DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
//         OwnershipFacet ownershipFacet = new OwnershipFacet();
//         OfferFacet offerFacet = new OfferFacet();
//         LoanFacet loanFacet = new LoanFacet();
//         // EscrowFacet escrowFacet = new EscrowFacet();
//         // OracleFacet oracleFacet = new OracleFacet();
//         // VangkiNFTFacet nftFacet = new VangkiNFTFacet();

//         // Deploy Diamond
//         VangkiDiamond diamond = new VangkiDiamond(
//             msg.sender,
//             address(cutFacet)
//         );

//         // Prepare cuts
//         IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](6); // Add all facets

//         // Loupe
//         bytes4[] memory loupeSelectors = new bytes4[](4);
//         loupeSelectors[0] = IDiamondLoupe.facets.selector;
//         loupeSelectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
//         loupeSelectors[2] = IDiamondLoupe.facetAddresses.selector;
//         loupeSelectors[3] = IDiamondLoupe.facetAddress.selector;
//         cuts[0] = IDiamondCut.FacetCut({
//             facetAddress: address(loupeFacet),
//             action: IDiamondCut.FacetCutAction.Add,
//             functionSelectors: loupeSelectors
//         });

//         // Ownership
//         bytes4[] memory ownershipSelectors = new bytes4[](2);
//         ownershipSelectors[0] = IERC173.owner.selector;
//         ownershipSelectors[1] = IERC173.transferOwnership.selector;
//         cuts[1] = IDiamondCut.FacetCut({
//             facetAddress: address(ownershipFacet),
//             action: IDiamondCut.FacetCutAction.Add,
//             functionSelectors: ownershipSelectors
//         });

//         // Offer
//         bytes4[] memory offerSelectors = new bytes4[](3);
//         offerSelectors[0] = OfferFacet.createOffer.selector;
//         offerSelectors[1] = OfferFacet.acceptOffer.selector;
//         offerSelectors[2] = OfferFacet.cancelOffer.selector;
//         cuts[2] = IDiamondCut.FacetCut({
//             facetAddress: address(offerFacet),
//             action: IDiamondCut.FacetCutAction.Add,
//             functionSelectors: offerSelectors
//         });

//         // Loan
//         bytes4[] memory loanSelectors = new bytes4[](2);
//         loanSelectors[0] = LoanFacet.repayLoan.selector;
//         loanSelectors[1] = LoanFacet.triggerDefault.selector;
//         cuts[3] = IDiamondCut.FacetCut({
//             facetAddress: address(loanFacet),
//             action: IDiamondCut.FacetCutAction.Add,
//             functionSelectors: loanSelectors
//         });

//         // // Escrow
//         // bytes4[] memory escrowSelectors = new bytes4[](1);
//         // escrowSelectors[0] = EscrowFacet.initializeEscrow.selector;
//         // cuts[4] = IDiamondCut.FacetCut({
//         //     facetAddress: address(escrowFacet),
//         //     action: IDiamondCut.FacetCutAction.Add,
//         //     functionSelectors: escrowSelectors
//         // });

//         // // Oracle
//         // bytes4[] memory oracleSelectors = new bytes4[](2);
//         // oracleSelectors[0] = OracleFacet.updateLiquidAsset.selector;
//         // oracleSelectors[1] = OracleFacet.checkLiquidity.selector;
//         // cuts[5] = IDiamondCut.FacetCut({
//         //     facetAddress: address(oracleFacet),
//         //     action: IDiamondCut.FacetCutAction.Add,
//         //     functionSelectors: oracleSelectors
//         // });

//         // NFT (add similarly)

//         // Cut the diamond
//         (bool success, ) = address(diamond).call(
//             abi.encodeWithSelector(
//                 IDiamondCut.diamondCut.selector,
//                 cuts,
//                 address(0),
//                 new bytes(0)
//             )
//         );
//         require(success, "Diamond cut failed");

//         // // Initialize escrow
//         // (success, ) = address(diamond).call(
//         //     abi.encodeWithSelector(EscrowFacet.initializeEscrow.selector)
//         // );
//         // require(success, "Escrow init failed");

//         vm.stopBroadcast();
//     }
// }
