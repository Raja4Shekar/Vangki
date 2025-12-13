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
        if (asset == address(0) || asset == _getUsdtContract()) {
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
            FeedRegistryInterface(_getChainlnkRegistry()).getFeed(
                asset,
                _getUsdChainlinkDenominator()
            )
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
        address token0 = asset < _getUsdtContract()
            ? asset
            : _getUsdtContract();
        address token1 = asset < _getUsdtContract()
            ? _getUsdtContract()
            : asset;
        uint24 fee = 3000; // 0.3%
        address pool = address(
            uint160(
                uint(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            _getUniswapV3Factory(),
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
        if (approxUsdLiquidity < LibVangki.MIN_LIQUIDITY_USD) {
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
            FeedRegistryInterface(_getChainlnkRegistry()).getFeed(
                borrowedAsset,
                _getUsdChainlinkDenominator()
            )
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
            FeedRegistryInterface(_getChainlnkRegistry()).getFeed(
                collateralAsset,
                _getUsdChainlinkDenominator()
            )
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
        ltv = (borrowedValueUSD * LibVangki.LTV_SCALE) / collateralValueUSD;
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
            FeedRegistryInterface(_getChainlnkRegistry()).getFeed(
                asset,
                _getUsdChainlinkDenominator()
            )
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

    /// @dev Get USD Chainlink Denominator
    function _getUsdChainlinkDenominator() internal view returns (address) {
        return LibVangki.storageSlot().usdChainlinkDenominator;
    }

    /// @dev Get Chainlnk Registry
    function _getChainlnkRegistry() internal view returns (address) {
        return LibVangki.storageSlot().chainlnkRegistry;
    }

    /// @dev Get USDT Contract Address
    function _getUsdtContract() internal view returns (address) {
        return LibVangki.storageSlot().usdtContract;
    }

    /// @dev Get Uniswap V3 Factory Address
    function _getUniswapV3Factory() internal view returns (address) {
        return LibVangki.storageSlot().uniswapV3Factory;
    }
}
