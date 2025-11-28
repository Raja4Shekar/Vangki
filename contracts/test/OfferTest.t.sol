// test/OfferTest.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../src/VangkiDiamond.sol";

// Import other facets...

contract OfferTest is Test {
    VangkiDiamond diamond;

    // Setup: Deploy diamond as in script, but in setUp()

    function setUp() public {
        // Deploy facets and diamond, cut them
        // Approve tokens, etc.
    }

    function testCreateOffer() public {
        // Call createOffer via diamond
        // Assert storage, events
    }

    // Add more: accept, cancel, etc.
}
