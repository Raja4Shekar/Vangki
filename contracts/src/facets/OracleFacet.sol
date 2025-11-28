// src/facets/OracleFacet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {LibVangki} from "../libraries/LibVangki.sol";
import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
import {FeedRegistryInterface} from "@chainlink/contracts/src/v0.8/interfaces/FeedRegistryInterface.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleFacet
 * @author Vangki Developer Team
 * @notice This facet handles asset liquidity determination and price feeds using Chainlink's Feed Registry in the Vangki platform.
 * @dev This contract is part of the Diamond Standard (EIP-2535) and uses shared storage from LibVangki.
 *      Liquidity check: Verifies Chainlink price feed via registry (asset vs USD) and Uniswap v3 pool with USDT.
 *      Includes liquidity volume threshold: Approximates USD liquidity > $1M equivalent (using pool liquidity and price).
 *      Manual updates to liquidAssets mapping via owner (multi-sig/governance).
 *      On-chain precedence: Overrides frontend assessments.
 *      If registry query or pool check fails, defaults to Illiquid.
 *      Custom errors for gas efficiency. No reentrancy as view/update functions.
 *      Events emitted for updates.
 *      Expand for Health Factor and full liquidation triggers later.
 *      Registry address hardcoded for Ethereum mainnet; for other networks, use direct feeds or alternatives.
 *      Note: Feed Registry is deprecated; consider migrating to direct aggregators in future phases.
 *      Liquidity threshold: 1e6 USD (adjustable if needed); uses asset price for conversion.
 *      Added LTV calculation: (borrowedValueUSD * 10000) / collateralValueUSD; 0 for illiquid/NFT collateral.
 */
contract OracleFacet {
    /// @notice Emitted when an asset's liquidity status is manually updated.
    /// @param asset The asset token address.
    /// @param isLiquid True if set to Liquid, false for Illiquid.
    event AssetLiquidityUpdated(address indexed asset, bool isLiquid);

    // Custom errors for clarity and gas efficiency.
    error InvalidAsset();
    error NoPriceFeed();
    error NoDexPool();
    error UpdateNotAllowed();
    error StalePriceData();
    error InsufficientLiquidity();
    error NonLiquidAsset();

    // Immutable network-specific configs (Ethereum mainnet examples; adjust for Polygon/Arbitrum)
    address private immutable UNISWAP_V3_FACTORY =
        0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address private immutable USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    FeedRegistryInterface private immutable CHAINLINK_REGISTRY =
        FeedRegistryInterface(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
    address private immutable USD =
        address(0x0000000000000000000000000000000000000348); // Chainlink USD denominator

    // Constants
    uint256 private constant MIN_LIQUIDITY_USD = 1_000_000 * 1e6; // $1M with 6 decimals (for USDT)
    uint256 private constant LTV_SCALE = 10000; // Basis points (e.g., 7500 = 75%)

    /**
     * @notice Manually updates the liquidity status of an ERC20 asset in the mapping.
     * @dev Used for high-value assets or overrides; callable only by Diamond owner (multi-sig/governance).
     *      Emits AssetLiquidityUpdated event.
     * @param asset The ERC20 token address.
     * @param isLiquid True to mark as Liquid, false for Illiquid.
     */
    function updateLiquidAsset(address asset, bool isLiquid) external {
        LibDiamond.enforceIsContractOwner();
        if (asset == address(0)) {
            revert InvalidAsset();
        }
        LibVangki.Storage storage s = LibVangki.storageSlot();
        s.liquidAssets[asset] = isLiquid;
        emit AssetLiquidityUpdated(asset, isLiquid);
    }

    /**
     * @notice Checks if an ERC20 asset is Liquid based on on-chain verification.
     * @dev View function: First checks manual mapping; if true, verifies Chainlink feed via registry (asset vs USD) and Uniswap v3 pool with USDT.
     *      Chainlink: Queries registry for feed, then latestRoundData for valid/updated price (not stale >1 hour, positive answer).
     *      Uniswap: Computes pool address for asset-USDT (0.3% fee), checks if initialized (slot0 sqrtPriceX96 > 0), and approximates liquidity > $1M USD.
     *      Liquidity approximation: Calls pool.liquidity(), converts to USD using asset price (assuming symmetric liquidity).
     *      Defaults to Illiquid on failure (e.g., no feed/pool/stale data/insufficient liquidity).
     *      For NFTs: Always Illiquid (handle in caller).
     * @param asset The ERC20 token address to check.
     * @return The liquidity status (Liquid or Illiquid).
     */
    function checkLiquidity(
        address asset
    ) external view returns (LibVangki.LiquidityStatus) {
        if (asset == address(0) || asset == USDT) {
            // USDT as base, skip or handle specially
            revert InvalidAsset();
        }
        LibVangki.Storage storage s = LibVangki.storageSlot();

        // Manual override check
        if (!s.liquidAssets[asset]) {
            return LibVangki.LiquidityStatus.Illiquid;
        }

        // Chainlink price feed check via registry (asset vs USD)
        AggregatorV3Interface feed = AggregatorV3Interface(
            CHAINLINK_REGISTRY.getFeed(asset, USD)
        );
        if (address(feed) == address(0)) {
            return LibVangki.LiquidityStatus.Illiquid;
        }
        (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = feed.latestRoundData();
        if (
            answer <= 0 ||
            updatedAt == 0 ||
            updatedAt < block.timestamp - 1 hours ||
            roundId != answeredInRound
        ) {
            return LibVangki.LiquidityStatus.Illiquid;
        }
        uint256 assetPrice = uint256(answer); // Assume 8 decimals; use feed.decimals() for precision

        // Uniswap v3 pool check for asset-USDT pair (0.3% fee)
        address token0 = asset < USDT ? asset : USDT;
        address token1 = asset < USDT ? USDT : asset;
        uint24 fee = 3000; // 0.3%
        address pool = address(
            uint160(
                uint(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            UNISWAP_V3_FACTORY,
                            keccak256(abi.encode(token0, token1, fee)),
                            hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f" // Uniswap v3 init code hash
                        )
                    )
                )
            )
        );

        // Check if pool is initialized (slot0 sqrtPriceX96 > 0)
        (bool success, bytes memory data) = pool.staticcall(
            abi.encodeWithSignature("slot0()")
        );
        if (!success) {
            return LibVangki.LiquidityStatus.Illiquid;
        }
        (uint160 sqrtPriceX96, , , , , , ) = abi.decode(
            data,
            (uint160, int24, uint16, uint16, uint16, uint8, bool)
        );
        if (sqrtPriceX96 == 0) {
            return LibVangki.LiquidityStatus.Illiquid;
        }

        // Check liquidity threshold (approximate USD value)
        (success, data) = pool.staticcall(
            abi.encodeWithSignature("liquidity()")
        );
        if (!success) {
            return LibVangki.LiquidityStatus.Illiquid;
        }
        uint128 poolLiquidity = abi.decode(data, (uint128));

        // Approximate USD liquidity: (poolLiquidity * assetPrice) / 10**decimals (assuming 8 for price)
        uint8 decimals = feed.decimals();
        uint256 approxUsdLiquidity = (uint256(poolLiquidity) * assetPrice) /
            (10 ** decimals);
        if (approxUsdLiquidity < MIN_LIQUIDITY_USD) {
            return LibVangki.LiquidityStatus.Illiquid;
        }

        return LibVangki.LiquidityStatus.Liquid;
    }

    /**
     * @notice Calculates the Loan-to-Value (LTV) ratio for a loan in basis points.
     * @dev LTV = (borrowedValueUSD * 10000) / collateralValueUSD; 0 for illiquid/NFT collateral.
     *      Uses Chainlink prices for liquid assets; reverts if non-liquid or no feed.
     *      Borrowed/collateral must be ERC20 liquid assets.
     *      Assumes amounts in native decimals; prices adjusted for feed decimals.
     * @param borrowedAsset The borrowed asset ERC20 address.
     * @param borrowedAmount The borrowed amount (in token decimals).
     * @param collateralAsset The collateral asset ERC20 address.
     * @param collateralAmount The collateral amount (in token decimals).
     * @return ltv The LTV in basis points (e.g., 7500 = 75%).
     */
    function calculateLTV(
        address borrowedAsset,
        uint256 borrowedAmount,
        address collateralAsset,
        uint256 collateralAmount
    ) external view returns (uint256 ltv) {
        if (collateralAmount == 0) {
            return 0;
        }
        LibVangki.Storage storage s = LibVangki.storageSlot();

        // Check if both are liquid
        if (
            !s.liquidAssets[borrowedAsset] || !s.liquidAssets[collateralAsset]
        ) {
            return 0; // Per doc: illiquid value $0
        }

        // Get borrowed value in USD
        AggregatorV3Interface borrowedFeed = AggregatorV3Interface(
            CHAINLINK_REGISTRY.getFeed(borrowedAsset, USD)
        );
        if (address(borrowedFeed) == address(0)) {
            revert NoPriceFeed();
        }
        (, int256 borrowedPrice, , , ) = borrowedFeed.latestRoundData();
        if (borrowedPrice <= 0) {
            revert StalePriceData();
        }
        uint256 borrowedValueUSD = (borrowedAmount * uint256(borrowedPrice)) /
            (10 ** borrowedFeed.decimals());

        // Get collateral value in USD
        AggregatorV3Interface collateralFeed = AggregatorV3Interface(
            CHAINLINK_REGISTRY.getFeed(collateralAsset, USD)
        );
        if (address(collateralFeed) == address(0)) {
            revert NoPriceFeed();
        }
        (, int256 collateralPrice, , , ) = collateralFeed.latestRoundData();
        if (collateralPrice <= 0) {
            revert StalePriceData();
        }
        uint256 collateralValueUSD = (collateralAmount *
            uint256(collateralPrice)) / (10 ** collateralFeed.decimals());

        // Calculate LTV in basis points
        ltv = (borrowedValueUSD * LTV_SCALE) / collateralValueUSD;
    }

    /**
     * @notice Gets the USD price of an asset from Chainlink (scaled by feed decimals).
     * @dev Queries registry for feed, then latestRoundData.answer.
     *      Reverts if no feed or stale/invalid price.
     *      Used by LTV/HF calculations.
     * @param asset The ERC20 token address.
     * @return price The USD price (scaled, e.g., 8 decimals).
     * @return decimals The feed's decimals for scaling.
     */
    function getAssetPrice(
        address asset
    ) external view returns (uint256 price, uint8 decimals) {
        AggregatorV3Interface feed = AggregatorV3Interface(
            CHAINLINK_REGISTRY.getFeed(asset, USD)
        );
        if (address(feed) == address(0)) {
            revert NoPriceFeed();
        }
        (, int256 answer, , uint256 updatedAt, ) = feed.latestRoundData();
        if (
            answer <= 0 ||
            updatedAt == 0 ||
            updatedAt < block.timestamp - 1 hours
        ) {
            revert StalePriceData();
        }
        price = uint256(answer);
        decimals = feed.decimals();
    }
}

// ##EOF##
// pragma solidity ^0.8.29;

// import {LibVangki} from "../libraries/LibVangki.sol";
// import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
// import {FeedRegistryInterface} from "@chainlink/contracts/src/v0.8/interfaces/FeedRegistryInterface.sol";
// import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

// /**
//  * @title OracleFacet
//  * @author Vangki Developer Team
//  * @notice This facet handles asset liquidity determination and price feeds using Chainlink's Feed Registry in the Vangki platform.
//  * @dev This contract is part of the Diamond Standard (EIP-2535) and uses shared storage from LibVangki.
//  *      Liquidity check: Verifies Chainlink price feed via registry (asset vs USD) and Uniswap v3 pool with USDT.
//  *      Includes liquidity volume threshold: Approximates USD liquidity > $1M equivalent (using pool liquidity and price).
//  *      Manual updates to liquidAssets mapping via owner (multi-sig/governance).
//  *      On-chain precedence: Overrides frontend assessments.
//  *      If registry query or pool check fails, defaults to Illiquid.
//  *      Custom errors for gas efficiency. No reentrancy as view/update functions.
//  *      Events emitted for updates.
//  *      Expand for Health Factor and full liquidation triggers later.
//  *      Registry address hardcoded for Ethereum mainnet; for other networks, use direct feeds or alternatives.
//  *      Note: Feed Registry is deprecated; consider migrating to direct aggregators in future phases.
//  *      Liquidity threshold: 1e6 USD (adjustable if needed); uses asset price for conversion.
//  *      Added LTV calculation: (borrowedValueUSD / collateralValueUSD) * 10000 (basis points); 0 for illiquid/NFT collateral.
//  */
// contract OracleFacet {
//     /// @notice Emitted when an asset's liquidity status is manually updated.
//     /// @param asset The asset token address.
//     /// @param isLiquid True if set to Liquid, false for Illiquid.
//     event AssetLiquidityUpdated(address indexed asset, bool isLiquid);

//     // Custom errors for clarity and gas efficiency.
//     error InvalidAsset();
//     error NoPriceFeed();
//     error NoDexPool();
//     error UpdateNotAllowed();
//     error StalePriceData();
//     error InsufficientLiquidity();
//     error NonLiquidAsset();

//     // Immutable network-specific configs (Ethereum mainnet examples; adjust for Polygon/Arbitrum)
//     address private immutable UNISWAP_V3_FACTORY =
//         0x1F98431c8aD98523631AE4a59f267346ea31F984;
//     address private immutable USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
//     FeedRegistryInterface private immutable CHAINLINK_REGISTRY =
//         FeedRegistryInterface(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
//     address private immutable USD =
//         address(0x0000000000000000000000000000000000000348); // Chainlink USD denominator

//     // Constants
//     uint256 private constant MIN_LIQUIDITY_USD = 1_000_000 * 1e6; // $1M with 6 decimals (for USDT)
//     uint256 private constant LTV_SCALE = 10000; // Basis points (e.g., 7500 = 75%)

//     /**
//      * @notice Manually updates the liquidity status of an ERC20 asset in the mapping.
//      * @dev Used for high-value assets or overrides; callable only by Diamond owner (multi-sig/governance).
//      *      Emits AssetLiquidityUpdated event.
//      * @param asset The ERC20 token address.
//      * @param isLiquid True to mark as Liquid, false for Illiquid.
//      */
//     function updateLiquidAsset(address asset, bool isLiquid) external {
//         LibDiamond.enforceIsContractOwner();
//         if (asset == address(0)) {
//             revert InvalidAsset();
//         }
//         LibVangki.Storage storage s = LibVangki.storageSlot();
//         s.liquidAssets[asset] = isLiquid;
//         emit AssetLiquidityUpdated(asset, isLiquid);
//     }

//     /**
//      * @notice Checks if an ERC20 asset is Liquid based on on-chain verification.
//      * @dev View function: First checks manual mapping; if true, verifies Chainlink feed via registry (asset vs USD) and Uniswap v3 pool with USDT.
//      *      Chainlink: Queries registry for feed, then latestRoundData for valid/updated price (not stale >1 hour, positive answer).
//      *      Uniswap: Computes pool address for asset-USDT (0.3% fee), checks if initialized (slot0 sqrtPriceX96 > 0), and approximates liquidity > $1M USD.
//      *      Liquidity approximation: Calls pool.liquidity(), converts to USD using asset price (assuming symmetric liquidity).
//      *      Defaults to Illiquid on failure (e.g., no feed/pool/stale data/insufficient liquidity).
//      *      For NFTs: Always Illiquid (handle in caller).
//      * @param asset The ERC20 token address to check.
//      * @return The liquidity status (Liquid or Illiquid).
//      */
//     function checkLiquidity(
//         address asset
//     ) external view returns (LibVangki.LiquidityStatus) {
//         if (asset == address(0) || asset == USDT) {
//             // USDT as base, skip or handle specially
//             revert InvalidAsset();
//         }
//         LibVangki.Storage storage s = LibVangki.storageSlot();

//         // Manual override check
//         if (!s.liquidAssets[asset]) {
//             return LibVangki.LiquidityStatus.Illiquid;
//         }

//         // Chainlink price feed check via registry (asset vs USD)
//         AggregatorV3Interface feed = AggregatorV3Interface(
//             CHAINLINK_REGISTRY.getFeed(asset, USD)
//         );
//         if (address(feed) == address(0)) {
//             return LibVangki.LiquidityStatus.Illiquid;
//         }
//         (
//             uint80 roundId,
//             int256 answer,
//             uint256 startedAt,
//             uint256 updatedAt,
//             uint80 answeredInRound
//         ) = feed.latestRoundData();
//         if (
//             answer <= 0 ||
//             updatedAt == 0 ||
//             updatedAt < block.timestamp - 1 hours ||
//             roundId != answeredInRound
//         ) {
//             return LibVangki.LiquidityStatus.Illiquid;
//         }
//         uint256 assetPrice = uint256(answer); // Assume 8 decimals; use feed.decimals() for precision

//         // Uniswap v3 pool check for asset-USDT pair (0.3% fee)
//         address token0 = asset < USDT ? asset : USDT;
//         address token1 = asset < USDT ? USDT : asset;
//         uint24 fee = 3000; // 0.3%
//         address pool = address(
//             uint160(
//                 uint(
//                     keccak256(
//                         abi.encodePacked(
//                             hex"ff",
//                             UNISWAP_V3_FACTORY,
//                             keccak256(abi.encode(token0, token1, fee)),
//                             hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f" // Uniswap v3 init code hash
//                         )
//                     )
//                 )
//             )
//         );

//         // Check if pool is initialized (slot0 sqrtPriceX96 > 0)
//         (bool success, bytes memory data) = pool.staticcall(
//             abi.encodeWithSignature("slot0()")
//         );
//         if (!success) {
//             return LibVangki.LiquidityStatus.Illiquid;
//         }
//         (uint160 sqrtPriceX96, , , , , , ) = abi.decode(
//             data,
//             (uint160, int24, uint16, uint16, uint16, uint8, bool)
//         );
//         if (sqrtPriceX96 == 0) {
//             return LibVangki.LiquidityStatus.Illiquid;
//         }

//         // Check liquidity threshold (approximate USD value)
//         (success, data) = pool.staticcall(
//             abi.encodeWithSignature("liquidity()")
//         );
//         if (!success) {
//             return LibVangki.LiquidityStatus.Illiquid;
//         }
//         uint128 poolLiquidity = abi.decode(data, (uint128));

//         // Approximate USD liquidity: (poolLiquidity * assetPrice) / 10**decimals (assuming 8 for price)
//         uint8 decimals = feed.decimals();
//         uint256 approxUsdLiquidity = (uint256(poolLiquidity) * assetPrice) /
//             (10 ** decimals);
//         if (approxUsdLiquidity < MIN_LIQUIDITY_USD) {
//             return LibVangki.LiquidityStatus.Illiquid;
//         }

//         return LibVangki.LiquidityStatus.Liquid;
//     }

//     /**
//      * @notice Calculates the Loan-to-Value (LTV) ratio for a loan in basis points.
//      * @dev LTV = (borrowedValueUSD * 10000) / collateralValueUSD; 0 for illiquid/NFT collateral.
//      *      Uses Chainlink prices for liquid assets; reverts if non-liquid or no feed.
//      *      Borrowed/collateral must be ERC20 liquid assets.
//      *      Assumes amounts in native decimals; prices adjusted for feed decimals.
//      * @param borrowedAsset The borrowed asset ERC20 address.
//      * @param borrowedAmount The borrowed amount (in token decimals).
//      * @param collateralAsset The collateral asset ERC20 address.
//      * @param collateralAmount The collateral amount (in token decimals).
//      * @return ltv The LTV in basis points (e.g., 7500 = 75%).
//      */
//     function calculateLTV(
//         address borrowedAsset,
//         uint256 borrowedAmount,
//         address collateralAsset,
//         uint256 collateralAmount
//     ) external view returns (uint256 ltv) {
//         if (collateralAmount == 0) {
//             return 0;
//         }
//         LibVangki.Storage storage s = LibVangki.storageSlot();

//         // Check if both are liquid
//         if (
//             !s.liquidAssets[borrowedAsset] || !s.liquidAssets[collateralAsset]
//         ) {
//             return 0; // Per doc: illiquid value $0
//         }

//         // Get borrowed value in USD
//         AggregatorV3Interface borrowedFeed = AggregatorV3Interface(
//             CHAINLINK_REGISTRY.getFeed(borrowedAsset, USD)
//         );
//         if (address(borrowedFeed) == address(0)) {
//             revert NoPriceFeed();
//         }
//         (, int256 borrowedPrice, , , ) = borrowedFeed.latestRoundData();
//         if (borrowedPrice <= 0) {
//             revert StalePriceData();
//         }
//         uint256 borrowedValueUSD = (borrowedAmount * uint256(borrowedPrice)) /
//             (10 ** borrowedFeed.decimals());

//         // Get collateral value in USD
//         AggregatorV3Interface collateralFeed = AggregatorV3Interface(
//             CHAINLINK_REGISTRY.getFeed(collateralAsset, USD)
//         );
//         if (address(collateralFeed) == address(0)) {
//             revert NoPriceFeed();
//         }
//         (, int256 collateralPrice, , , ) = collateralFeed.latestRoundData();
//         if (collateralPrice <= 0) {
//             revert StalePriceData();
//         }
//         uint256 collateralValueUSD = (collateralAmount *
//             uint256(collateralPrice)) / (10 ** collateralFeed.decimals());

//         // Calculate LTV in basis points
//         ltv = (borrowedValueUSD * 10000) / collateralValueUSD;
//     }
// }

// ##EOF##
// pragma solidity ^0.8.29;

// import {LibVangki} from "../libraries/LibVangki.sol";
// import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
// import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol"; // From Chainlink library

// /**
//  * @title OracleFacet
//  * @author Vangki Developer Team
//  * @notice This facet handles asset liquidity determination and price feeds using Chainlink oracles in the Vangki platform.
//  * @dev This contract is part of the Diamond Standard (EIP-2535) and uses shared storage from LibVangki.
//  *      Liquidity check: Verifies Chainlink price feed existence and DEX pool (e.g., Uniswap v3) with sufficient volume.
//  *      For DEX: Checks pool existence via factory (network-specific; configurable).
//  *      Manual updates to liquidAssets mapping via owner (multi-sig/governance).
//  *      On-chain precedence: Overrides frontend assessments.
//  *      If API/oracle unavailable, defaults to Illiquid.
//  *      Custom errors for gas efficiency. No reentrancy as view/update functions.
//  *      Events emitted for updates.
//  *      Expand for LTV calculations, Health Factor, and full liquidation triggers later.
//  *      Network-specific configs (e.g., Uniswap factory addresses) set as immutables or via init.
//  */
// contract OracleFacet {
//     /// @notice Emitted when an asset's liquidity status is manually updated.
//     /// @param asset The asset token address.
//     /// @param isLiquid True if set to Liquid, false for Illiquid.
//     event AssetLiquidityUpdated(address indexed asset, bool isLiquid);

//     // Custom errors for clarity and gas efficiency.
//     error InvalidAsset();
//     error NoPriceFeed();
//     error NoDexPool();
//     error UpdateNotAllowed();

//     // Immutable network-specific configs (set in constructor or init; for simplicity, hardcode examples).
//     address private immutable UNISWAP_V3_FACTORY; // e.g., 0x1F98431c8aD98523631AE4a59f267346ea31F984 for Ethereum
//     address private immutable BASE_TOKEN; // e.g., USDC for pool checks: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48

//     constructor(address uniswapFactory, address baseToken) {
//         UNISWAP_V3_FACTORY = uniswapFactory;
//         BASE_TOKEN = baseToken;
//     }

//     /**
//      * @notice Manually updates the liquidity status of an ERC20 asset in the mapping.
//      * @dev Used for high-value assets or overrides; callable only by Diamond owner (multi-sig/governance).
//      *      Emits AssetLiquidityUpdated event.
//      * @param asset The ERC20 token address.
//      * @param isLiquid True to mark as Liquid, false for Illiquid.
//      */
//     function updateLiquidAsset(address asset, bool isLiquid) external {
//         LibDiamond.enforceIsContractOwner();
//         if (asset == address(0)) {
//             revert InvalidAsset();
//         }
//         LibVangki.Storage storage s = LibVangki.storageSlot();
//         s.liquidAssets[asset] = isLiquid;
//         emit AssetLiquidityUpdated(asset, isLiquid);
//     }

//     /**
//      * @notice Checks if an ERC20 asset is Liquid based on on-chain verification.
//      * @dev View function: First checks manual mapping; if true, verifies Chainlink feed and DEX pool.
//      *      Chainlink: Calls latestRoundData; reverts if no data or stale.
//      *      DEX: Checks Uniswap v3 pool existence and (stub) volume > $1M (for volume, use off-chain or approximate via reserves).
//      *      Defaults to Illiquid on failure (e.g., no feed/pool).
//      *      For NFTs: Always Illiquid (handle in caller).
//      * @param asset The ERC20 token address to check.
//      * @return The liquidity status (Liquid or Illiquid).
//      */
//     function checkLiquidity(
//         address asset
//     ) external view returns (LibVangki.LiquidityStatus) {
//         if (asset == address(0)) {
//             revert InvalidAsset();
//         }
//         LibVangki.Storage storage s = LibVangki.storageSlot();

//         // Manual override check
//         if (!s.liquidAssets[asset]) {
//             return LibVangki.LiquidityStatus.Illiquid;
//         }

//         // Chainlink price feed check (assume feed address stored or registry; stub with example)
//         // For real: Use Chainlink registry or mapping; here, assume a function getFeed(asset)
//         address feed = _getChainlinkFeed(asset); // Stub; implement mapping or registry call
//         if (feed == address(0)) {
//             return LibVangki.LiquidityStatus.Illiquid;
//         }
//         try AggregatorV3Interface(feed).latestRoundData() returns (
//             uint80 roundId,
//             int256 answer,
//             uint256 startedAt,
//             uint256 updatedAt,
//             uint80 answeredInRound
//         ) {
//             if (updatedAt == 0 || answer <= 0 || roundId != answeredInRound) {
//                 return LibVangki.LiquidityStatus.Illiquid;
//             }
//         } catch {
//             return LibVangki.LiquidityStatus.Illiquid;
//         }

//         // DEX pool check (Uniswap v3 example: pool existence with BASE_TOKEN)
//         address pool = _getUniswapV3Pool(asset, BASE_TOKEN); // Compute deterministic pool address
//         if (pool == address(0) || !_poolHasLiquidity(pool)) {
//             return LibVangki.LiquidityStatus.Illiquid;
//         }

//         return LibVangki.LiquidityStatus.Liquid;
//     }

//     // Internal helpers (stubs; expand with mappings/registries)

//     /// @dev Stub for getting Chainlink feed address for an asset (e.g., from mapping or registry).
//     function _getChainlinkFeed(address asset) internal view returns (address) {
//         // Example: return asset == WETH ? ETH_USD_FEED : address(0);
//         return address(0); // Placeholder; add actual logic/mapping
//     }

//     /// @dev Computes Uniswap v3 pool address for token pair (deterministic).
//     function _getUniswapV3Pool(
//         address tokenA,
//         address tokenB
//     ) internal view returns (address) {
//         if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
//         return
//             address(
//                 uint160(
//                     uint(
//                         keccak256(
//                             abi.encodePacked(
//                                 hex"ff",
//                                 UNISWAP_V3_FACTORY,
//                                 keccak256(abi.encode(tokenA, tokenB, 3000)), // Fee tier stub 0.3%
//                                 hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f" // INIT_CODE_HASH for v3
//                             )
//                         )
//                     )
//                 )
//             );
//     }

//     /// @dev Checks if a pool has sufficient liquidity (stub: check balance or slot0; for volume, use off-chain).
//     function _poolHasLiquidity(address pool) internal view returns (bool) {
//         // Example: Check if sqrtPriceX96 > 0 from slot0
//         (bool success, bytes memory data) = pool.staticcall(
//             abi.encodeWithSignature("slot0()")
//         );
//         if (!success) return false;
//         (uint160 sqrtPriceX96, , , , , , ) = abi.decode(
//             data,
//             (uint160, int24, uint16, uint16, uint16, uint8, bool)
//         );
//         return sqrtPriceX96 > 0;
//     }
// }

// ##EOF##
// pragma solidity ^0.8.29;

// import {LibVangki} from "../libraries/LibVangki.sol";
// import {LibDiamond} from "@diamond-3/libraries/LibDiamond.sol";
// import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol"; // From OpenZeppelin or Chainlink repo (add if needed)

// contract OracleFacet {
//     event AssetLiquidityUpdated(address asset, bool isLiquid);

//     function updateLiquidAsset(address asset, bool isLiquid) external {
//         LibDiamond.enforceIsContractOwner();
//         LibVangki.Storage storage s = LibVangki.storageSlot();
//         s.liquidAssets[asset] = isLiquid;
//         emit AssetLiquidityUpdated(asset, isLiquid);
//     }

//     function checkLiquidity(
//         address asset
//     ) external view returns (LibVangki.LiquidityStatus) {
//         LibVangki.Storage storage s = LibVangki.storageSlot();
//         if (!s.liquidAssets[asset]) return LibVangki.LiquidityStatus.Illiquid;
//         // Add on-chain Chainlink check: AggregatorV3Interface(feed).latestRoundData();
//         // Add DEX pool check (e.g., Uniswap factory.getPair)
//         return LibVangki.LiquidityStatus.Liquid;
//     }

//     // Add LTV calculation functions later
// }
