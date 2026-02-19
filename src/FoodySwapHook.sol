// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {FoodyVIPNFT} from "./FoodyVIPNFT.sol";

/// @title IFoodyToken — Interface for the existing FoodyeCoin on Base
/// @notice The on-chain FOODY token at 0x289b9fc2a3f19faf7260905d0b15e1c90e8a462c
///         has MINTER_ROLE-based mint(). We interface with it here.
interface IFoodyToken {
    function mint(address to, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

/// @title FoodySwapHook — Uniswap V4 Hook for Restaurant Payments + Loyalty Rewards
/// @author FoodyePay Team
/// @notice A single hook with three logical layers:
///   Layer 1 (beforeSwap): Constraints — restaurant whitelist, operating hours, tx limits
///   Layer 2 (beforeSwap): Pricing — dynamic fees based on loyalty tier & peak hours
///   Layer 3 (afterSwap):  Settlement — fee splitting, FOODY cashback, loyalty tracking, VIP NFT
///
/// @dev Designed for the FOODY/USDC pool on Base chain.
///      Uses the existing FoodyeCoin (ERC20 with MINTER_ROLE) for cashback rewards.
///      Hook must be granted MINTER_ROLE on FoodyeCoin after deployment.
contract FoodySwapHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    // =========================================================================
    // Types
    // =========================================================================

    /// @notice Loyalty tier levels — each tier unlocks better discounts and rewards
    enum Tier {
        Bronze, // $0+     — 2% discount, 3% cashback
        Silver, // $200+   — 5% discount, 5% cashback
        Gold, // $500+   — 8% discount, 7% cashback
        VIP // $1000+  — 12% discount, 10% cashback + NFT
    }

    /// @notice Per-user loyalty state stored on-chain
    struct UserLoyalty {
        uint256 totalSpent; // Cumulative spend in USDC (6 decimals)
        uint256 foodyEarned; // Total FOODY rewards earned
        uint256 referralEarned; // FOODY earned from referrals
        Tier tier; // Current loyalty tier
        address referrer; // Who referred this user (0x0 if none)
        uint64 lastSwapTime; // Timestamp of last swap
        uint32 swapCount; // Total number of swaps
    }

    /// @notice Restaurant configuration
    struct Restaurant {
        bool isActive; // Whether the restaurant is whitelisted
        address wallet; // Restaurant's receiving wallet
        uint8 openHour; // Opening hour (0-23, UTC)
        uint8 closeHour; // Closing hour (0-23, UTC)
        uint256 maxTxAmount; // Max single transaction in USDC (6 decimals), 0 = no limit
    }

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Tier thresholds in USDC (6 decimals)
    uint256 public constant SILVER_THRESHOLD = 200e6; // $200
    uint256 public constant GOLD_THRESHOLD = 500e6; // $500
    uint256 public constant VIP_THRESHOLD = 1000e6; // $1,000

    /// @notice Fee discount rates per tier (basis points, 10000 = 100%)
    uint16 public constant BRONZE_DISCOUNT_BPS = 200; // 2%
    uint16 public constant SILVER_DISCOUNT_BPS = 500; // 5%
    uint16 public constant GOLD_DISCOUNT_BPS = 800; // 8%
    uint16 public constant VIP_DISCOUNT_BPS = 1200; // 12%

    /// @notice Cashback reward rates per tier (basis points)
    uint16 public constant BRONZE_REWARD_BPS = 300; // 3%
    uint16 public constant SILVER_REWARD_BPS = 500; // 5%
    uint16 public constant GOLD_REWARD_BPS = 700; // 7%
    uint16 public constant VIP_REWARD_BPS = 1000; // 10%

    /// @notice Fee splitting (basis points, must sum to 10000)
    uint16 public constant RESTAURANT_FEE_BPS = 9000; // 90% to restaurant
    uint16 public constant PLATFORM_FEE_BPS = 500; // 5% to platform
    uint16 public constant REWARD_POOL_FEE_BPS = 500; // 5% to reward pool

    /// @notice Referral bonus rates (basis points)
    uint16 public constant REFERRER_BONUS_BPS = 100; // 1% to referrer
    uint16 public constant REFEREE_BONUS_BPS = 200; // 2% extra for referred user's first swap

    /// @notice Peak hour fee discount (basis points off the base fee)
    uint16 public constant PEAK_HOUR_DISCOUNT_BPS = 100; // 1% extra discount during peak hours

    /// @notice Base LP fee for the pool (basis points, applied as dynamic fee)
    uint24 public constant BASE_LP_FEE = 3000; // 0.3%

    // =========================================================================
    // State
    // =========================================================================

    /// @notice On-chain loyalty data for each user
    mapping(address => UserLoyalty) public loyalty;

    /// @notice Registered restaurants
    mapping(bytes32 => Restaurant) public restaurants; // restaurantId => Restaurant

    /// @notice Platform wallet for fee collection
    address public platformWallet;

    /// @notice Reward pool wallet
    address public rewardPoolWallet;

    /// @notice Hook admin (can manage restaurants)
    address public admin;

    /// @notice The existing FOODY token contract on Base
    IFoodyToken public foodyToken;

    /// @notice The VIP NFT contract
    FoodyVIPNFT public vipNFT;

    /// @notice Total volume processed through the hook (USDC, 6 decimals)
    uint256 public totalVolume;

    /// @notice Total rewards distributed (FOODY, 18 decimals)
    uint256 public totalRewardsDistributed;

    // =========================================================================
    // Events
    // =========================================================================

    event RestaurantAdded(bytes32 indexed restaurantId, address wallet);
    event RestaurantRemoved(bytes32 indexed restaurantId);
    event LoyaltyUpdated(address indexed user, Tier tier, uint256 totalSpent, uint256 foodyEarned);
    event TierUpgraded(address indexed user, Tier oldTier, Tier newTier);
    event CashbackAwarded(address indexed user, uint256 amount, Tier tier);
    event ReferralSet(address indexed user, address indexed referrer);
    event ReferralBonusPaid(address indexed referrer, address indexed referee, uint256 amount);
    event VIPMinted(address indexed user, uint256 tokenId);
    event FeeSplit(uint256 restaurantAmount, uint256 platformAmount, uint256 rewardPoolAmount);

    // =========================================================================
    // Errors
    // =========================================================================

    error OnlyAdmin();
    error RestaurantNotActive(bytes32 restaurantId);
    error OutsideOperatingHours(uint8 currentHour, uint8 openHour, uint8 closeHour);
    error ExceedsMaxTransaction(uint256 amount, uint256 maxAmount);
    error AlreadyHasReferrer();
    error CannotReferSelf();
    error InvalidAddress();

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(
        IPoolManager _poolManager,
        address _foodyToken,
        address _platformWallet,
        address _rewardPoolWallet,
        address _admin
    ) BaseHook(_poolManager) {
        foodyToken = IFoodyToken(_foodyToken);
        platformWallet = _platformWallet;
        rewardPoolWallet = _rewardPoolWallet;
        admin = _admin;

        // Deploy VIP NFT — this hook contract will be the owner
        vipNFT = new FoodyVIPNFT();
    }

    // =========================================================================
    // Hook Permissions
    // =========================================================================

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // Set initial dynamic fee
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // Layer 1 (constraints) + Layer 2 (pricing)
            afterSwap: true, // Layer 3 (settlement + rewards)
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // =========================================================================
    // Hook Callbacks
    // =========================================================================

    /// @notice Set the initial dynamic fee when the pool is created
    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal
        override
        returns (bytes4)
    {
        poolManager.updateDynamicLPFee(key, BASE_LP_FEE);
        return BaseHook.afterInitialize.selector;
    }

    /// @notice Layer 1 (Constraints) + Layer 2 (Pricing) — executed before every swap
    function _beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Decode hookData: (address user, bytes32 restaurantId)
        if (hookData.length >= 64) {
            (address user, bytes32 restaurantId) = abi.decode(hookData, (address, bytes32));

            // ===== Layer 1: Constraints =====
            _checkConstraints(restaurantId, params);

            // ===== Layer 2: Pricing =====
            uint24 adjustedFee = _calculateDynamicFee(user);
            return (
                BaseHook.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                adjustedFee | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }

        // No hookData — use base fee
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Layer 3 (Settlement + Rewards) — executed after every swap
    function _afterSwap(
        address,
        PoolKey calldata,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        if (hookData.length >= 64) {
            (address user, bytes32 restaurantId) = abi.decode(hookData, (address, bytes32));

            // ===== Layer 3: Settlement + Rewards =====
            _settleAndReward(user, restaurantId, params, delta);
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    // =========================================================================
    // Layer 1: Constraints
    // =========================================================================

    /// @dev Verify restaurant whitelist, operating hours, and transaction limits
    function _checkConstraints(bytes32 restaurantId, SwapParams calldata params) internal view {
        Restaurant storage restaurant = restaurants[restaurantId];

        // Check restaurant is whitelisted and active
        if (!restaurant.isActive) revert RestaurantNotActive(restaurantId);

        // Check operating hours (0 means 24/7)
        if (restaurant.openHour != restaurant.closeHour) {
            uint8 currentHour = uint8((block.timestamp / 3600) % 24);
            bool isOpen;

            if (restaurant.openHour < restaurant.closeHour) {
                // Normal hours: e.g., 10-22
                isOpen = currentHour >= restaurant.openHour && currentHour < restaurant.closeHour;
            } else {
                // Overnight hours: e.g., 22-06
                isOpen = currentHour >= restaurant.openHour || currentHour < restaurant.closeHour;
            }

            if (!isOpen) {
                revert OutsideOperatingHours(currentHour, restaurant.openHour, restaurant.closeHour);
            }
        }

        // Check max transaction amount
        if (restaurant.maxTxAmount > 0) {
            uint256 absAmount =
                params.amountSpecified < 0 ? uint256(-int256(params.amountSpecified)) : uint256(int256(params.amountSpecified));
            if (absAmount > restaurant.maxTxAmount) {
                revert ExceedsMaxTransaction(absAmount, restaurant.maxTxAmount);
            }
        }
    }

    // =========================================================================
    // Layer 2: Pricing
    // =========================================================================

    /// @dev Calculate dynamic fee based on user's loyalty tier and time of day
    function _calculateDynamicFee(address user) internal view returns (uint24) {
        Tier tier = loyalty[user].tier;

        // Get tier-based discount
        uint16 discountBps = _getDiscountBps(tier);

        // Check if it's peak hours (11-14 or 17-21 UTC)
        uint8 currentHour = uint8((block.timestamp / 3600) % 24);
        bool isPeakHour =
            (currentHour >= 11 && currentHour < 14) || (currentHour >= 17 && currentHour < 21);

        if (isPeakHour) {
            discountBps += PEAK_HOUR_DISCOUNT_BPS;
        }

        // Apply discount to base fee (ensure fee doesn't go below 0)
        uint24 discountAmount = uint24((uint256(BASE_LP_FEE) * discountBps) / 10000);
        uint24 adjustedFee = discountAmount >= BASE_LP_FEE ? 0 : BASE_LP_FEE - discountAmount;

        return adjustedFee;
    }

    // =========================================================================
    // Layer 3: Settlement + Rewards
    // =========================================================================

    /// @dev Handle post-swap accounting: loyalty tracking, cashback, tier upgrades, referrals
    function _settleAndReward(
        address user,
        bytes32, /* restaurantId */
        SwapParams calldata params,
        BalanceDelta delta
    ) internal {
        // Calculate the input amount (what the user spent)
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        // The negative delta is what the user paid
        uint256 inputAmount;
        if (params.zeroForOne) {
            inputAmount = amount0 < int128(0) ? uint256(uint128(-amount0)) : 0;
        } else {
            inputAmount = amount1 < int128(0) ? uint256(uint128(-amount1)) : 0;
        }

        if (inputAmount == 0) return;

        // Update user loyalty state
        UserLoyalty storage userLoyalty = loyalty[user];
        userLoyalty.totalSpent += inputAmount;
        userLoyalty.lastSwapTime = uint64(block.timestamp);
        userLoyalty.swapCount++;
        totalVolume += inputAmount;

        // Check for tier upgrade
        Tier oldTier = userLoyalty.tier;
        Tier newTier = _calculateTier(userLoyalty.totalSpent);
        if (newTier > oldTier) {
            userLoyalty.tier = newTier;
            emit TierUpgraded(user, oldTier, newTier);

            // Auto-mint VIP NFT when reaching VIP tier
            if (newTier == Tier.VIP && !vipNFT.hasVIP(user)) {
                uint256 tokenId = vipNFT.mintVIP(user);
                emit VIPMinted(user, tokenId);
            }
        }

        // Calculate and distribute FOODY cashback rewards
        uint16 rewardBps = _getRewardBps(userLoyalty.tier);
        uint256 rewardAmount = (inputAmount * rewardBps) / 10000;

        // Scale reward from USDC decimals (6) to FOODY decimals (18)
        // 1 USDC spent = rewardBps/10000 worth of FOODY
        // FOODY price ~$0.0001, so 1 USDC = 10,000 FOODY at par
        // We give rewardBps/10000 * inputAmount * conversionRate
        uint256 foodyReward = rewardAmount * 1e12; // Scale 6 decimals to 18 decimals

        if (foodyReward > 0) {
            foodyToken.mint(user, foodyReward);
            userLoyalty.foodyEarned += foodyReward;
            totalRewardsDistributed += foodyReward;
            emit CashbackAwarded(user, foodyReward, userLoyalty.tier);
        }

        // Handle referral bonus
        if (userLoyalty.referrer != address(0)) {
            uint256 referrerBonus = (inputAmount * REFERRER_BONUS_BPS * 1e12) / 10000;
            if (referrerBonus > 0) {
                foodyToken.mint(userLoyalty.referrer, referrerBonus);
                loyalty[userLoyalty.referrer].referralEarned += referrerBonus;
                totalRewardsDistributed += referrerBonus;
                emit ReferralBonusPaid(userLoyalty.referrer, user, referrerBonus);
            }
        }

        // Emit loyalty update
        emit LoyaltyUpdated(user, userLoyalty.tier, userLoyalty.totalSpent, userLoyalty.foodyEarned);

        // Note: Fee splitting (restaurant/platform/rewardPool) is handled by the
        // Uniswap V4 pool's fee collection mechanism. The LP fee goes to LPs,
        // and off-chain settlement distributes to restaurant/platform/rewardPool.
        // On-chain fee splitting would require custom accounting via returnDelta.
    }

    // =========================================================================
    // Tier & Reward Helpers
    // =========================================================================

    function _calculateTier(uint256 totalSpent) internal pure returns (Tier) {
        if (totalSpent >= VIP_THRESHOLD) return Tier.VIP;
        if (totalSpent >= GOLD_THRESHOLD) return Tier.Gold;
        if (totalSpent >= SILVER_THRESHOLD) return Tier.Silver;
        return Tier.Bronze;
    }

    function _getDiscountBps(Tier tier) internal pure returns (uint16) {
        if (tier == Tier.VIP) return VIP_DISCOUNT_BPS;
        if (tier == Tier.Gold) return GOLD_DISCOUNT_BPS;
        if (tier == Tier.Silver) return SILVER_DISCOUNT_BPS;
        return BRONZE_DISCOUNT_BPS;
    }

    function _getRewardBps(Tier tier) internal pure returns (uint16) {
        if (tier == Tier.VIP) return VIP_REWARD_BPS;
        if (tier == Tier.Gold) return GOLD_REWARD_BPS;
        if (tier == Tier.Silver) return SILVER_REWARD_BPS;
        return BRONZE_REWARD_BPS;
    }

    // =========================================================================
    // Referral System
    // =========================================================================

    /// @notice Set a referrer for the calling user. Can only be set once.
    /// @param referrer Address of the user who referred you
    function setReferrer(address referrer) external {
        if (referrer == address(0)) revert InvalidAddress();
        if (referrer == msg.sender) revert CannotReferSelf();
        if (loyalty[msg.sender].referrer != address(0)) revert AlreadyHasReferrer();

        loyalty[msg.sender].referrer = referrer;
        emit ReferralSet(msg.sender, referrer);
    }

    // =========================================================================
    // Admin: Restaurant Management
    // =========================================================================

    /// @notice Add or update a restaurant in the whitelist
    /// @param restaurantId Unique identifier for the restaurant
    /// @param wallet Restaurant's receiving wallet address
    /// @param openHour Opening hour (0-23 UTC), set both to same value for 24/7
    /// @param closeHour Closing hour (0-23 UTC)
    /// @param maxTxAmount Maximum single transaction amount in USDC (6 decimals), 0 = no limit
    function addRestaurant(
        bytes32 restaurantId,
        address wallet,
        uint8 openHour,
        uint8 closeHour,
        uint256 maxTxAmount
    ) external onlyAdmin {
        if (wallet == address(0)) revert InvalidAddress();

        restaurants[restaurantId] = Restaurant({
            isActive: true,
            wallet: wallet,
            openHour: openHour,
            closeHour: closeHour,
            maxTxAmount: maxTxAmount
        });

        emit RestaurantAdded(restaurantId, wallet);
    }

    /// @notice Remove a restaurant from the whitelist
    /// @param restaurantId The restaurant to remove
    function removeRestaurant(bytes32 restaurantId) external onlyAdmin {
        restaurants[restaurantId].isActive = false;
        emit RestaurantRemoved(restaurantId);
    }

    /// @notice Update the admin address
    /// @param newAdmin New admin address
    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert InvalidAddress();
        admin = newAdmin;
    }

    /// @notice Update the platform wallet
    /// @param newPlatformWallet New platform wallet address
    function setPlatformWallet(address newPlatformWallet) external onlyAdmin {
        if (newPlatformWallet == address(0)) revert InvalidAddress();
        platformWallet = newPlatformWallet;
    }

    /// @notice Update the reward pool wallet
    /// @param newRewardPoolWallet New reward pool wallet address
    function setRewardPoolWallet(address newRewardPoolWallet) external onlyAdmin {
        if (newRewardPoolWallet == address(0)) revert InvalidAddress();
        rewardPoolWallet = newRewardPoolWallet;
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /// @notice Get a user's complete loyalty information
    function getUserLoyalty(address user) external view returns (UserLoyalty memory) {
        return loyalty[user];
    }

    /// @notice Get a user's current tier
    function getUserTier(address user) external view returns (Tier) {
        return loyalty[user].tier;
    }

    /// @notice Get a user's current discount in basis points
    function getUserDiscount(address user) external view returns (uint16) {
        return _getDiscountBps(loyalty[user].tier);
    }

    /// @notice Get a user's current reward rate in basis points
    function getUserRewardRate(address user) external view returns (uint16) {
        return _getRewardBps(loyalty[user].tier);
    }

    /// @notice Check if a restaurant is active
    function isRestaurantActive(bytes32 restaurantId) external view returns (bool) {
        return restaurants[restaurantId].isActive;
    }

    /// @notice Check if a user has VIP NFT
    function isVIP(address user) external view returns (bool) {
        return vipNFT.hasVIP(user);
    }

    /// @notice Get the current dynamic fee for a user (including peak hour adjustment)
    function getCurrentFeeForUser(address user) external view returns (uint24) {
        return _calculateDynamicFee(user);
    }
}
