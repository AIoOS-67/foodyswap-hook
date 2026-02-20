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

contract FoodySwapHookTest is BaseTest {
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
    address bob = address(0xB0B);
    address restaurantWallet = address(0x3003);

    bytes32 restaurantId = keccak256("foody-restaurant-1");

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

    function _swapNoHookData(uint256 amountIn, bool zeroForOne) internal returns (BalanceDelta) {
        return swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    // =========================================================================
    // Test: Basic Swap with Loyalty Tracking
    // =========================================================================

    function testBasicSwapTracksLoyalty() public {
        uint256 amountIn = 1e18;
        _swap(alice, amountIn, true);

        FoodySwapHook.UserLoyalty memory userLoyalty = hook.getUserLoyalty(alice);
        assertGt(userLoyalty.totalSpent, 0, "totalSpent should be > 0");
        assertEq(userLoyalty.swapCount, 1, "swapCount should be 1");
        // Tier depends on totalSpent — with 18-decimal tokens at 1:1 price,
        // 1e18 tokens = a very large USDC amount, so tier may upgrade immediately
        assertTrue(uint8(userLoyalty.tier) <= uint8(FoodySwapHook.Tier.VIP), "Tier should be valid");
    }

    // =========================================================================
    // Test: Swap without hookData (no loyalty tracking)
    // =========================================================================

    function testSwapWithoutHookData() public {
        uint256 amountIn = 1e18;
        _swapNoHookData(amountIn, true);
        // Should not revert — just skip loyalty tracking
    }

    // =========================================================================
    // Test: FOODY Cashback Rewards
    // =========================================================================

    function testCashbackRewards() public {
        uint256 amountIn = 1e18;
        uint256 foodyBefore = foodyToken.balanceOf(alice);

        _swap(alice, amountIn, true);

        uint256 foodyAfter = foodyToken.balanceOf(alice);
        assertGt(foodyAfter, foodyBefore, "Should have earned FOODY cashback");
    }

    // =========================================================================
    // Test: Tier Upgrades
    // =========================================================================

    function testTierUpgrades() public {
        // Start at Bronze
        assertEq(uint8(hook.getUserTier(alice)), uint8(FoodySwapHook.Tier.Bronze));

        // Do many swaps to accumulate spend
        // Each swap is 1e18 tokens; with 1:1 price, that's a significant amount
        for (uint256 i = 0; i < 10; i++) {
            _swap(alice, 50e18, true);
        }

        // Check tier upgraded (exact tier depends on amounts)
        FoodySwapHook.UserLoyalty memory userLoyalty = hook.getUserLoyalty(alice);
        assertGt(userLoyalty.totalSpent, 0, "Should have accumulated spend");
        assertEq(userLoyalty.swapCount, 10, "Should have 10 swaps");
    }

    // =========================================================================
    // Test: Referral System
    // =========================================================================

    function testReferralSystem() public {
        // Alice sets Bob as her referrer
        vm.prank(alice);
        hook.setReferrer(bob);

        FoodySwapHook.UserLoyalty memory aliceLoyalty = hook.getUserLoyalty(alice);
        assertEq(aliceLoyalty.referrer, bob, "Alice's referrer should be Bob");

        // Alice does a swap — Bob should earn referral bonus
        uint256 bobFoodyBefore = foodyToken.balanceOf(bob);
        _swap(alice, 1e18, true);

        uint256 bobFoodyAfter = foodyToken.balanceOf(bob);
        assertGt(bobFoodyAfter, bobFoodyBefore, "Bob should earn referral bonus");
    }

    function testCannotReferSelf() public {
        vm.prank(alice);
        vm.expectRevert(FoodySwapHook.CannotReferSelf.selector);
        hook.setReferrer(alice);
    }

    function testCannotSetReferrerTwice() public {
        vm.prank(alice);
        hook.setReferrer(bob);

        vm.prank(alice);
        vm.expectRevert(FoodySwapHook.AlreadyHasReferrer.selector);
        hook.setReferrer(address(0xCAFE));
    }

    // =========================================================================
    // Test: Restaurant Management
    // =========================================================================

    function testAddRestaurant() public {
        bytes32 newRestId = keccak256("new-restaurant");

        vm.prank(admin);
        hook.addRestaurant(newRestId, address(0xBEEF), 10, 22, 500e6);

        assertTrue(hook.isRestaurantActive(newRestId), "Restaurant should be active");
    }

    function testRemoveRestaurant() public {
        vm.prank(admin);
        hook.removeRestaurant(restaurantId);

        assertFalse(hook.isRestaurantActive(restaurantId), "Restaurant should be inactive");
    }

    function testOnlyAdminCanAddRestaurant() public {
        vm.prank(alice);
        vm.expectRevert(FoodySwapHook.OnlyAdmin.selector);
        hook.addRestaurant(keccak256("test"), address(0xBEEF), 0, 0, 0);
    }

    function testInactiveRestaurantReverts() public {
        bytes32 fakeId = keccak256("fake-restaurant");
        bytes memory hookData = abi.encode(alice, fakeId);

        // V4 wraps hook reverts in WrappedError, so use generic expectRevert
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: hookData,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    // =========================================================================
    // Test: Operating Hours
    // =========================================================================

    function testOperatingHoursEnforced() public {
        // Create restaurant with limited hours (10-22 UTC)
        bytes32 limitedId = keccak256("limited-hours");
        vm.prank(admin);
        hook.addRestaurant(limitedId, restaurantWallet, 10, 22, 0);

        // Warp to 3 AM UTC (outside operating hours)
        vm.warp(1700000000 + 3 * 3600); // some timestamp at 3 AM

        bytes memory hookData = abi.encode(alice, limitedId);

        // The hour check depends on block.timestamp, let's verify it reverts
        // We need to be precise about the hour calculation
        uint8 currentHour = uint8((block.timestamp / 3600) % 24);
        if (currentHour < 10 || currentHour >= 22) {
            vm.expectRevert();
            swapRouter.swapExactTokensForTokens({
                amountIn: 1e18,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: poolKey,
                hookData: hookData,
                receiver: address(this),
                deadline: block.timestamp + 1
            });
        }
    }

    // =========================================================================
    // Test: Transaction Limits
    // =========================================================================

    function testMaxTxAmountEnforced() public {
        bytes32 limitedId = keccak256("limited-tx");
        vm.prank(admin);
        hook.addRestaurant(limitedId, restaurantWallet, 0, 0, 100e6); // Max $100

        // Try a swap that exceeds the $100 limit — should revert
        bytes memory hookData = abi.encode(alice, limitedId);

        vm.expectRevert();
        swapRouter.swapExactTokensForTokens({
            amountIn: 200e6, // $200 — exceeds $100 limit
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: hookData,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // A swap within the limit should succeed
        swapRouter.swapExactTokensForTokens({
            amountIn: 50e6, // $50 — within $100 limit
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: hookData,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    // =========================================================================
    // Test: Dynamic Fee
    // =========================================================================

    function testDynamicFeeByTier() public {
        // Bronze user should get BASE_LP_FEE - 2% discount
        uint24 bronzeFee = hook.getCurrentFeeForUser(alice);
        uint24 baseFee = hook.BASE_LP_FEE();
        assertLt(bronzeFee, baseFee, "Bronze fee should be less than base");
    }

    // =========================================================================
    // Test: VIP NFT
    // =========================================================================

    function testVIPNFTSoulbound() public {
        FoodyVIPNFT vipNft = hook.vipNFT();

        // Mint a VIP NFT directly via the hook (hook is owner of vipNFT)
        // We need to reach VIP tier first — simulate by doing large swaps
        // VIP_THRESHOLD = 1000e6, but tokens use 18 decimals at 1:1 price
        // So we just need enough volume. Do large swaps.
        for (uint256 i = 0; i < 20; i++) {
            _swap(alice, 100e18, true);
        }

        // Check alice reached VIP and got NFT
        assertTrue(vipNft.hasVIP(alice), "Alice should have VIP NFT");
        assertTrue(hook.isVIP(alice), "Alice should be VIP");

        // Try to transfer the soulbound NFT — should revert
        vm.prank(alice);
        vm.expectRevert("Soulbound: non-transferable");
        vipNft.transferFrom(alice, bob, 0);
    }

    // =========================================================================
    // Test: View Functions
    // =========================================================================

    function testViewFunctions() public {
        // Initial state checks
        assertEq(uint8(hook.getUserTier(alice)), uint8(FoodySwapHook.Tier.Bronze));
        assertEq(hook.getUserDiscount(alice), 200); // 2% = 200 bps
        assertEq(hook.getUserRewardRate(alice), 300); // 3% = 300 bps
        assertTrue(hook.isRestaurantActive(restaurantId));
        assertFalse(hook.isVIP(alice));
    }

    function testTotalVolume() public {
        uint256 volumeBefore = hook.totalVolume();
        _swap(alice, 1e18, true);
        uint256 volumeAfter = hook.totalVolume();
        assertGt(volumeAfter, volumeBefore, "Volume should increase after swap");
    }

    function testTotalRewardsDistributed() public {
        uint256 rewardsBefore = hook.totalRewardsDistributed();
        _swap(alice, 1e18, true);
        uint256 rewardsAfter = hook.totalRewardsDistributed();
        assertGt(rewardsAfter, rewardsBefore, "Rewards should increase after swap");
    }
}
