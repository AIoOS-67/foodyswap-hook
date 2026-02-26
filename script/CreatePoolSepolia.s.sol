// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

/// @title CreatePoolSepolia — Create FOODY/MockUSDC Pool + Add Liquidity on Base Sepolia
/// @notice Standalone script (no BaseScript dependency) for real V4 deployment.
///
/// @dev Usage:
///   forge script script/CreatePoolSepolia.s.sol \
///     --rpc-url base_sepolia \
///     --private-key $PRIVATE_KEY \
///     --sender 0xB4ffaAc40f4cA6ECb006AE6d739262f1458b64a3 \
///     --broadcast
contract CreatePoolSepoliaScript is Script {
    using CurrencyLibrary for Currency;

    // =========================================================================
    // Base Sepolia Infrastructure (from hookmate AddressConstants, chain 84532)
    // =========================================================================
    IPoolManager constant POOL_MANAGER = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    IPositionManager constant POSITION_MANAGER = IPositionManager(0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80);
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    // =========================================================================
    // Tokens (verified: FOODY address < MockUSDC address → FOODY = currency0)
    // =========================================================================
    IERC20 constant FOODY = IERC20(0x55aEcFfA2F2E4DDcc63B40bac01b939A9C23f91A);       // 18 decimals
    IERC20 constant MOCK_USDC = IERC20(0x83a42BF2f2830E3abEe6C8BCB2137947F15aBD45);   // 6 decimals

    // =========================================================================
    // FoodySwap Hook
    // =========================================================================
    IHooks constant HOOK = IHooks(0x7f10f52a355E5574C02Eac81B93cAce904Cfd0C0);

    // =========================================================================
    // Pool Configuration
    // =========================================================================
    /// @dev DYNAMIC_FEE_FLAG (0x800000) — Hook controls the LP fee via beforeSwap
    uint24 constant LP_FEE = 0x800000;
    int24 constant TICK_SPACING = 60;

    /// @dev Target price: 1 FOODY ≈ 0.001 USDC (1000 FOODY = 1 USDC)
    ///      price_raw = 0.001 * 1e6 / 1e18 = 1e-15
    ///      tick = floor(ln(1e-15) / ln(1.0001)) ≈ -345,420
    ///      Must be a multiple of tickSpacing (60): -345420 / 60 = -5757 ✓
    int24 constant TARGET_TICK = -345420;

    // =========================================================================
    // Liquidity: 100K FOODY + 100 MockUSDC
    // =========================================================================
    uint256 public token0Amount = 100_000e18;   // 100,000 FOODY
    uint256 public token1Amount = 100e6;         // 100 USDC

    function run() external {
        // Sanity: verify token ordering (currency0 < currency1)
        require(address(FOODY) < address(MOCK_USDC), "Token ordering wrong: FOODY must be < USDC");

        Currency currency0 = Currency.wrap(address(FOODY));
        Currency currency1 = Currency.wrap(address(MOCK_USDC));

        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: HOOK
        });

        // Compute sqrtPriceX96 from target tick
        uint160 startingPrice = TickMath.getSqrtPriceAtTick(TARGET_TICK);

        console2.log("=== Create FOODY/USDC Pool on Base Sepolia ===");
        console2.log("FOODY  (currency0):", address(FOODY));
        console2.log("USDC   (currency1):", address(MOCK_USDC));
        console2.log("Hook:", address(HOOK));
        console2.log("Fee: 0x800000 (DYNAMIC_FEE)");
        console2.log("TickSpacing:", uint24(TICK_SPACING));
        console2.log("Target tick:", TARGET_TICK);
        console2.log("sqrtPriceX96:", startingPrice);

        // Check deployer balances
        uint256 foodyBal = FOODY.balanceOf(msg.sender);
        uint256 usdcBal = MOCK_USDC.balanceOf(msg.sender);
        console2.log("");
        console2.log("Deployer FOODY balance:", foodyBal / 1e18);
        console2.log("Deployer USDC balance:", usdcBal / 1e6);
        require(foodyBal >= token0Amount, "Not enough FOODY");
        require(usdcBal >= token1Amount, "Not enough USDC");

        // Calculate tick range (wide: ±750 * tickSpacing around target)
        int24 tickLower = _truncate((TARGET_TICK - 750 * TICK_SPACING), TICK_SPACING);
        int24 tickUpper = _truncate((TARGET_TICK + 750 * TICK_SPACING), TICK_SPACING);

        console2.log("");
        console2.log("Tick lower:", tickLower);
        console2.log("Tick upper:", tickUpper);

        // Convert token amounts to liquidity units
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            startingPrice,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            token0Amount,
            token1Amount
        );

        console2.log("Liquidity units:", liquidity);

        // Slippage protection (generous for testnet)
        uint256 amount0Max = token0Amount + 1;
        uint256 amount1Max = token1Amount + 1;

        // Encode mint actions: MINT_POSITION → SETTLE_PAIR → SWEEP → SWEEP
        bytes memory hookData = new bytes(0);
        (bytes memory actions, bytes[] memory mintParams) = _mintLiquidityParams(
            poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, msg.sender, hookData
        );

        // Build multicall: [0] initializePool + [1] modifyLiquidities
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encodeWithSelector(
            POSITION_MANAGER.initializePool.selector, poolKey, startingPrice, hookData
        );
        params[1] = abi.encodeWithSelector(
            POSITION_MANAGER.modifyLiquidities.selector,
            abi.encode(actions, mintParams),
            block.timestamp + 3600
        );

        // =====================================================================
        // Execute on-chain
        // =====================================================================
        vm.startBroadcast();

        // Step 1: Approve tokens → Permit2 → PositionManager
        FOODY.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(FOODY), address(POSITION_MANAGER), type(uint160).max, type(uint48).max);

        MOCK_USDC.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(MOCK_USDC), address(POSITION_MANAGER), type(uint160).max, type(uint48).max);

        console2.log("Approvals done");

        // Step 2: Atomically create pool + add liquidity
        POSITION_MANAGER.multicall(params);

        vm.stopBroadcast();

        // =====================================================================
        // Log results
        // =====================================================================
        console2.log("");
        console2.log("========================================");
        console2.log("  POOL CREATED + LIQUIDITY ADDED!");
        console2.log("========================================");
        console2.log("FOODY provided:", token0Amount / 1e18, "tokens");
        console2.log("USDC provided:", token1Amount / 1e6, "tokens");
        console2.log("Price: 1 FOODY ~ 0.001 USDC");
        console2.log("");
        console2.log("Next: Test swap via SwapRouter");
    }

    // =========================================================================
    // Internal helpers (copied from LiquidityHelpers to avoid BaseScript)
    // =========================================================================

    function _mintLiquidityParams(
        PoolKey memory poolKey,
        int24 _tickLower,
        int24 _tickUpper,
        uint256 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        address recipient,
        bytes memory hookData
    ) internal pure returns (bytes memory, bytes[] memory) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR),
            uint8(Actions.SWEEP),
            uint8(Actions.SWEEP)
        );

        bytes[] memory mintParams = new bytes[](4);
        mintParams[0] = abi.encode(
            poolKey, _tickLower, _tickUpper, liquidity, amount0Max, amount1Max, recipient, hookData
        );
        mintParams[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        mintParams[2] = abi.encode(poolKey.currency0, recipient);
        mintParams[3] = abi.encode(poolKey.currency1, recipient);

        return (actions, mintParams);
    }

    function _truncate(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        return ((tick / tickSpacing) * tickSpacing);
    }
}
