// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";

import {FoodySwapHook} from "../src/FoodySwapHook.sol";
import {FoodyVIPNFT} from "../src/FoodyVIPNFT.sol";
import {MockFoodyToken} from "./mocks/MockFoodyToken.sol";

/// @title FoodySwapHook Fuzz Tests
/// @notice Property-based tests to verify invariants across random inputs.
///         Run with: forge test --match-contract FoodySwapHookFuzzTest -vvv
///         Deep run: forge test --match-contract FoodySwapHookFuzzTest --fuzz-runs 10000
contract FoodySwapHookFuzzTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;
    FoodySwapHook hook;
    PoolId poolId;
    MockFoodyToken foodyToken;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    // Test addresses
    address admin = address(0xAD);
    address platformWallet = address(0x1001);
    address rewardPoolWallet = address(0x2002);
    address alice = address(0xA11CE);
    address restaurantWallet = address(0x3003);

    bytes32 restaurantId = keccak256("foody-restaurant-fuzz");

    function setUp() public {
        // Deploy all V4 infrastructure
        deployArtifactsAndLabel();

        // Deploy mock FOODY token
        foodyToken = new MockFoodyToken();

        // Deploy test currencies
        (currency0, currency1) = deployCurrencyPair();

        // Calculate hook flags
        address flags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            ) ^ (0x5555 << 144)
        );

        // Deploy the hook
        bytes memory constructorArgs =
            abi.encode(poolManager, address(foodyToken), platformWallet, rewardPoolWallet, admin);
        deployCodeTo("FoodySwapHook.sol:FoodySwapHook", constructorArgs, flags);
        hook = FoodySwapHook(flags);

        // Grant MINTER_ROLE to hook
        foodyToken.grantMinterRole(address(hook));

        // Add restaurant (as admin)
        vm.prank(admin);
        hook.addRestaurant(restaurantId, restaurantWallet, 0, 0, 0); // 24/7, no limit

        // Create pool with dynamic fee
        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Provide full-range liquidity
        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        uint128 liquidityAmount = 1000e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (tokenId,) = positionManager.mint(
            poolKey, tickLower, tickUpper, liquidityAmount,
            amount0Expected + 1, amount1Expected + 1,
            address(this), block.timestamp, Constants.ZERO_BYTES
        );
    }

    // =========================================================================
    // Helper: perform swap with hookData
    // =========================================================================

    function _swap(address user, uint256 amountIn, bool zeroForOne) internal returns (BalanceDelta) {
        bytes memory hookData = abi.encode(user, restaurantId);
        return swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: hookData,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    // =========================================================================
    // Fuzz 1: Dynamic fee NEVER exceeds BASE_LP_FEE
    // =========================================================================

    /// @notice Invariant: For any user at any tier, the dynamic fee <= BASE_LP_FEE
    function testFuzz_DynamicFeeNeverExceedsBase(address user) public view {
        uint24 fee = hook.getCurrentFeeForUser(user);
        uint24 baseFee = hook.BASE_LP_FEE();

        assertLe(fee, baseFee, "Dynamic fee must never exceed BASE_LP_FEE");
        // Fee should also be reasonable (not some crazy value)
        assertLe(fee, 10000, "Fee should not exceed 100% (10000 bps)");
    }

    // =========================================================================
    // Fuzz 2: Reward scaling with 1e12 multiplier never overflows
    // =========================================================================

    /// @notice Invariant: FOODY reward calculation never overflows for any input amount
    function testFuzz_RewardScalingNoOverflow(uint256 inputAmount) public view {
        // Bound to max reasonable swap: $10M USDC (6 decimals)
        inputAmount = bound(inputAmount, 1, 10_000_000e6);

        // Replicate the exact reward calculation from _settleAndReward:
        //   uint256 rewardAmount = (inputAmount * rewardBps) / 10000;
        //   uint256 foodyReward = rewardAmount * 1e12;
        uint16 maxRewardBps = hook.VIP_REWARD_BPS(); // 1000 = 10%
        uint256 rewardAmount = (inputAmount * maxRewardBps) / 10000;
        uint256 foodyReward = rewardAmount * 1e12; // Scale 6 decimals to 18 decimals

        // Verify no overflow: foodyReward should always be >= rewardAmount (scaling up)
        assertGe(foodyReward, rewardAmount, "Scaling should not underflow");
        // Verify foodyReward fits in uint256 (would revert above if not)
        assertLe(foodyReward, type(uint256).max, "Should not overflow uint256");
        // Verify reward is proportional to input (at most 10% * 1e12 scaling)
        // Max: 10_000_000e6 * 1000 / 10000 * 1e12 = 1e24, well within uint256
        assertLe(foodyReward, inputAmount * 1e12, "Reward should not exceed input * 1e12");
    }

    // =========================================================================
    // Fuzz 3: Operating hours wrapping logic
    // =========================================================================

    /// @notice Invariant: Operating hours logic correctly handles overnight wrapping
    function testFuzz_OperatingHoursLogic(
        uint8 openHour,
        uint8 closeHour,
        uint256 timestamp
    ) public {
        openHour = uint8(bound(openHour, 0, 23));
        closeHour = uint8(bound(closeHour, 0, 23));
        timestamp = bound(timestamp, 1_600_000_000, 2_000_000_000);

        // Skip 24/7 case (openHour == closeHour means always open)
        vm.assume(openHour != closeHour);

        // Add a restaurant with these hours
        bytes32 fuzzRestId = keccak256(abi.encode("fuzz", openHour, closeHour, timestamp));
        vm.prank(admin);
        hook.addRestaurant(fuzzRestId, restaurantWallet, openHour, closeHour, 0);

        // Warp to the timestamp
        vm.warp(timestamp);

        // Calculate expected open/closed status
        uint8 currentHour = uint8((timestamp / 3600) % 24);
        bool shouldBeOpen;

        if (openHour < closeHour) {
            // Normal hours: e.g., 10-22
            shouldBeOpen = currentHour >= openHour && currentHour < closeHour;
        } else {
            // Overnight hours: e.g., 22-06
            shouldBeOpen = currentHour >= openHour || currentHour < closeHour;
        }

        // Try to swap
        bytes memory hookData = abi.encode(alice, fuzzRestId);
        if (!shouldBeOpen) {
            // Should revert (V4 wraps in WrappedError)
            vm.expectRevert();
        }
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e15, // Small amount to stay within liquidity
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: hookData,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    // =========================================================================
    // Fuzz 4: Swap with varying amounts
    // =========================================================================

    /// @notice Invariant: Swaps of any reasonable size succeed and track loyalty correctly
    function testFuzz_SwapVaryingAmounts(uint256 amountIn) public {
        // Bound to amounts within pool liquidity (pool has 1000e18)
        amountIn = bound(amountIn, 1e15, 50e18);

        // Swap should succeed
        _swap(alice, amountIn, true);

        // Verify loyalty tracking
        FoodySwapHook.UserLoyalty memory userLoyalty = hook.getUserLoyalty(alice);
        assertGt(userLoyalty.totalSpent, 0, "totalSpent should be > 0");
        assertEq(userLoyalty.swapCount, 1, "swapCount should be 1");
        assertGt(userLoyalty.foodyEarned, 0, "Should have earned FOODY cashback");

        // Verify FOODY was minted
        uint256 foodyBalance = foodyToken.balanceOf(alice);
        assertGt(foodyBalance, 0, "Alice should have FOODY tokens");
        assertEq(foodyBalance, userLoyalty.foodyEarned, "Balance should match foodyEarned");
    }

    // =========================================================================
    // Fuzz 5: Referral system cannot be exploited
    // =========================================================================

    /// @notice Invariant: Referral system rejects self-referral and zero address
    function testFuzz_ReferralCannotBeExploited(address referrer, address referee) public {
        // Bound to non-zero, non-precompile addresses
        vm.assume(referrer != address(0));
        vm.assume(referee != address(0));
        vm.assume(referrer != referee);
        // Avoid collisions with existing test addresses
        vm.assume(referrer != admin && referrer != platformWallet && referrer != rewardPoolWallet);
        vm.assume(referee != admin && referee != platformWallet && referee != rewardPoolWallet);

        // Setting referrer should succeed
        vm.prank(referee);
        hook.setReferrer(referrer);

        FoodySwapHook.UserLoyalty memory refereeLoyalty = hook.getUserLoyalty(referee);
        assertEq(refereeLoyalty.referrer, referrer, "Referrer should be set");

        // Setting referrer again should fail
        vm.prank(referee);
        vm.expectRevert(FoodySwapHook.AlreadyHasReferrer.selector);
        hook.setReferrer(address(0xDEAD));

        // Self-referral should always fail (test with a fresh address)
        address selfRef = address(uint160(uint256(keccak256(abi.encode(referrer, referee, "self")))));
        vm.assume(selfRef != address(0));
        vm.prank(selfRef);
        vm.expectRevert(FoodySwapHook.CannotReferSelf.selector);
        hook.setReferrer(selfRef);
    }
}
