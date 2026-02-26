// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {FoodySwapHook} from "../src/FoodySwapHook.sol";

/// @title TestSwapSepolia — Execute a test swap through FoodySwap Hook
/// @notice Swaps FOODY → USDC via hookmate SwapRouter on Base Sepolia.
///         Encodes hookData with user + restaurantId so the Hook processes loyalty.
///
/// @dev Usage:
///   forge script script/TestSwapSepolia.s.sol \
///     --rpc-url base_sepolia \
///     --private-key $PRIVATE_KEY \
///     --sender 0xB4ffaAc40f4cA6ECb006AE6d739262f1458b64a3 \
///     --broadcast -vvv
contract TestSwapSepoliaScript is Script {
    using CurrencyLibrary for Currency;

    // =========================================================================
    // Contracts
    // =========================================================================
    FoodySwapHook constant hook = FoodySwapHook(0x7f10f52a355E5574C02Eac81B93cAce904Cfd0C0);
    IUniswapV4Router04 constant swapRouter = IUniswapV4Router04(payable(0x71cD4Ea054F9Cb3D3BF6251A00673303411A7DD9));

    IERC20 constant FOODY = IERC20(0x55aEcFfA2F2E4DDcc63B40bac01b939A9C23f91A);
    IERC20 constant MOCK_USDC = IERC20(0x83a42BF2f2830E3abEe6C8BCB2137947F15aBD45);
    IHooks constant HOOK = IHooks(0x7f10f52a355E5574C02Eac81B93cAce904Cfd0C0);

    // =========================================================================
    // Swap Parameters
    // =========================================================================
    address constant DEPLOYER = 0xB4ffaAc40f4cA6ECb006AE6d739262f1458b64a3;

    /// @dev Sichuan Garden restaurant ID (from SetupTestnet)
    bytes32 constant SICHUAN_ID = 0x7e51c7f41531cde2898654d369fd09d3b5d2a39029d278858f88b37c748a04b9;

    /// @dev Swap 100 FOODY → USDC (zeroForOne = true, since FOODY is currency0)
    uint256 constant SWAP_AMOUNT = 100e18;

    function run() external {
        Currency currency0 = Currency.wrap(address(FOODY));
        Currency currency1 = Currency.wrap(address(MOCK_USDC));

        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0x800000,        // DYNAMIC_FEE_FLAG
            tickSpacing: int24(60),
            hooks: HOOK
        });

        // hookData: abi.encode(userAddress, restaurantId)
        bytes memory hookData = abi.encode(DEPLOYER, SICHUAN_ID);

        // Log pre-swap state
        console2.log("=== Test Swap: FOODY -> USDC via FoodySwap Hook ===");
        console2.log("Swapping:", SWAP_AMOUNT / 1e18, "FOODY");
        console2.log("User:", DEPLOYER);
        console2.log("Restaurant: Sichuan Garden");

        uint256 foodyBefore = FOODY.balanceOf(DEPLOYER);
        uint256 usdcBefore = MOCK_USDC.balanceOf(DEPLOYER);
        console2.log("");
        console2.log("Before swap:");
        console2.log("  FOODY:", foodyBefore / 1e18);
        console2.log("  USDC:", usdcBefore / 1e6);

        // Read loyalty BEFORE swap
        FoodySwapHook.UserLoyalty memory loyaltyBefore = hook.getUserLoyalty(DEPLOYER);
        console2.log("  Tier:", uint8(loyaltyBefore.tier));
        console2.log("  Total spent:", loyaltyBefore.totalSpent);
        console2.log("  Swap count:", loyaltyBefore.swapCount);

        vm.startBroadcast();

        // Approve tokens to SwapRouter
        FOODY.approve(address(swapRouter), type(uint256).max);

        // Execute swap: FOODY → USDC (zeroForOne = true)
        swapRouter.swapExactTokensForTokens({
            amountIn: SWAP_AMOUNT,
            amountOutMin: 0,           // No slippage for testnet
            zeroForOne: true,          // FOODY → USDC
            poolKey: poolKey,
            hookData: hookData,
            receiver: DEPLOYER,
            deadline: block.timestamp + 300
        });

        vm.stopBroadcast();

        // Log post-swap state
        uint256 foodyAfter = FOODY.balanceOf(DEPLOYER);
        uint256 usdcAfter = MOCK_USDC.balanceOf(DEPLOYER);
        console2.log("");
        console2.log("After swap:");
        console2.log("  FOODY:", foodyAfter / 1e18);
        console2.log("  USDC:", usdcAfter / 1e6);
        console2.log("  FOODY spent:", (foodyBefore - foodyAfter) / 1e18);
        console2.log("  USDC received:", (usdcAfter - usdcBefore) / 1e6);

        // Read loyalty AFTER swap
        FoodySwapHook.UserLoyalty memory loyaltyAfter = hook.getUserLoyalty(DEPLOYER);
        console2.log("");
        console2.log("Loyalty updated:");
        console2.log("  Tier:", uint8(loyaltyAfter.tier));
        console2.log("  Total spent:", loyaltyAfter.totalSpent);
        console2.log("  FOODY earned:", loyaltyAfter.foodyEarned);
        console2.log("  Swap count:", loyaltyAfter.swapCount);

        console2.log("");
        console2.log("=== Swap Test Complete! ===");
    }
}
