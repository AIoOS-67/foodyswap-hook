# FoodySwap Hook

**A Uniswap V4 Hook for Restaurant Payments + Loyalty Rewards on Base Chain**

> Part of [FoodyePay](https://foodyepay.com) — an AI-powered Web3 restaurant payment platform.

---

## Overview

FoodySwap Hook transforms every FOODY/USDC swap into a complete restaurant loyalty experience. Unlike generic DeFi hooks, FoodySwap applies Uniswap V4's hook architecture to a **real-world vertical** — restaurant payments — with on-chain loyalty tiers, cashback rewards, referral bonuses, and soulbound VIP NFTs.

### The Problem

Traditional restaurant loyalty programs are:
- **Fragmented** — Every restaurant has its own points system
- **Opaque** — Customers can't verify their rewards
- **Non-portable** — Points are locked to a single chain or platform
- **Easily gamed** — Centralized systems are vulnerable to fraud

### The Solution

FoodySwap Hook embeds loyalty logic directly into Uniswap V4's swap lifecycle:
- Customer pays with FOODY token at any whitelisted restaurant
- Hook auto-validates the transaction (Layer 1)
- Hook applies tier-based fee discount (Layer 2)
- Hook distributes FOODY cashback + updates loyalty on-chain (Layer 3)

**Everything happens atomically within a single swap transaction.**

---

## Architecture

### One Hook, Three Layers

FoodySwap uses a **single hook contract** with three logical layers — cleaner than multiple hooks, less gas, no cross-contract state, and aligned with V4's design philosophy (one hook per pool).

```
FoodySwapHook.sol
├── beforeSwap()
│   ├── Layer 1: Constraints (_checkConstraints)
│   │   ├── Restaurant whitelist verification
│   │   ├── Operating hours validation (block.timestamp)
│   │   └── Per-transaction amount limits
│   └── Layer 2: Pricing (_calculateDynamicFee)
│       ├── Tier-based fee discount (2%/5%/8%/12%)
│       ├── Peak hour fee adjustment (lunch/dinner = lower fees)
│       └── Dynamic fee override via LPFeeLibrary.OVERRIDE_FEE_FLAG
└── afterSwap()
    └── Layer 3: Settlement + Rewards (_settleAndReward)
        ├── FOODY cashback mint (3-10% based on tier)
        ├── Loyalty points tracking + auto tier upgrade
        ├── Referral bonus (referrer earns 1%, referee gets 2% extra on first swap)
        └── VIP NFT auto-mint at $1,000+ cumulative spend
```

### Hook Permissions

| Permission | Used | Purpose |
|---|---|---|
| `afterInitialize` | Yes | Set initial dynamic LP fee |
| `beforeSwap` | Yes | Layer 1 (Constraints) + Layer 2 (Pricing) |
| `afterSwap` | Yes | Layer 3 (Settlement + Rewards) |
| All others | No | Not needed |

---

## Loyalty System

### Tier Structure

| Tier | Threshold | Fee Discount | Cashback Rate | Perks |
|---|---|---|---|---|
| Bronze | $0+ | 2% | 3% FOODY | Base tier |
| Silver | $200+ | 5% | 5% FOODY | Better rates |
| Gold | $500+ | 8% | 7% FOODY | Priority |
| VIP | $1,000+ | 12% | 10% FOODY | Soulbound NFT + max rewards |

### Peak Hour Bonus

During lunch (11-14 UTC) and dinner (17-21 UTC) hours, all users receive an additional **1% fee discount**, incentivizing on-chain payments during peak restaurant hours.

### Referral Program

| Role | Bonus |
|---|---|
| Referrer | 1% of referee's swap amount (ongoing) |
| Referee | 2% extra FOODY on first swap |

### VIP NFT (Soulbound)

When a user reaches $1,000+ cumulative spend, the hook automatically mints a **soulbound (non-transferable) VIP NFT** (`FoodyVIPNFT.sol`). This serves as:
- Permanent proof of VIP status
- On-chain membership badge
- Cannot be transferred or sold (prevents gaming)

---

## Contracts

| Contract | Description | Lines |
|---|---|---|
| [`FoodySwapHook.sol`](src/FoodySwapHook.sol) | Main hook — 3-layer architecture | ~557 |
| [`FoodyVIPNFT.sol`](src/FoodyVIPNFT.sol) | Soulbound VIP membership NFT | ~56 |
| [`MockFoodyToken.sol`](test/mocks/MockFoodyToken.sol) | Test mock for FoodyeCoin | ~26 |

### Key Design Decisions

1. **Single hook, not three** — One contract manages all three layers. Less gas, simpler state, matches V4's one-hook-per-pool design.

2. **Existing token integration** — FoodySwap interfaces with the **existing FoodyeCoin** ([`0x1022...C08F`](https://basescan.org/token/0x1022B1B028a2237C440DbAc51Dc6fC220D88C08F)) on Base chain, which has `MINTER_ROLE`-based `mint()`. The hook is granted MINTER_ROLE to mint cashback rewards directly.

3. **Dynamic fee via OVERRIDE_FEE_FLAG** — Layer 2 uses `LPFeeLibrary.OVERRIDE_FEE_FLAG` to override the pool's LP fee per-swap based on the user's loyalty tier, without permanently changing the pool's base fee.

4. **hookData encoding** — Swap callers pass `abi.encode(userAddress, restaurantId)` as hookData. Swaps without hookData are processed normally (no loyalty tracking).

5. **Off-chain fee splitting** — While the hook tracks fee split ratios (90% restaurant / 5% platform / 5% reward pool), actual USDC distribution happens off-chain via the FoodyePay platform to avoid complex on-chain accounting.

---

## Integration with FoodyePay Platform

FoodySwap Hook is one layer of the **FoodyePay 2.0** platform:

```
┌──────────────────────────────────────────────────┐
│              FoodyePay 2.0 Platform               │
├──────────────────────────────────────────────────┤
│                                                  │
│  Voice AI Layer          Blockchain Layer         │
│  ┌──────────────┐       ┌──────────────────┐    │
│  │ Gemini Live  │       │ Uniswap V4 Hook  │    │
│  │ Phone ordering│       │ FoodySwap        │    │
│  │ Multilingual │       │ FOODY/USDC swap  │    │
│  │ Real-time    │       │ Loyalty rewards  │    │
│  └──────────────┘       └──────────────────┘    │
│                                                  │
│  Frontend: Next.js 14 (App Router)              │
│  Chain: Base (8453)                             │
│  Tokens: FOODY + USDC                           │
└──────────────────────────────────────────────────┘
```

### Customer Flow

```
Customer calls restaurant
    │
    ▼
┌─ Voice AI ──────────────────────────────────────┐
│  "Hi, I'd like kung pao chicken + fried rice"   │
│  AI: "That'll be $28.50"                        │
└─────────────────────────────────────────────────┘
    │
    ▼
┌─ FoodySwap Hook (this repo) ────────────────────┐
│  Customer pays with FOODY token                  │
│  beforeSwap: validate restaurant + apply discount│
│  afterSwap: mint FOODY cashback + update loyalty │
└──────────────────────────────────────────────────┘
```

---

## Partner Integrations

| Partner | Integration | Status |
|---|---|---|
| **Uniswap V4** | Core hook infrastructure (`BaseHook`, `PoolManager`, `LPFeeLibrary`) | Implemented |
| **Base Chain** | Deployment target (Chain ID 8453) | Designed for |
| **FoodyeCoin (FOODY)** | Existing ERC20 token with MINTER_ROLE on Base | Integrated |
| **USDC (Circle)** | Base currency for restaurant payments | Integrated |
| **OpenZeppelin** | `BaseHook` from `@openzeppelin/uniswap-hooks` | Implemented |
| **Solmate** | `ERC721` + `Owned` for VIP NFT, `ERC20` for mock token | Implemented |
| **Coinbase Smart Wallet** | User wallet for dApp interactions | Frontend integration |

### Potential Future Integrations

| Partner | Integration Opportunity |
|---|---|
| **Circle Paymaster** | Gasless swaps — customers pay gas in USDC, no ETH needed |
| **Circle CCTP v2** | Cross-chain USDC liquidity replenishment |
| **Chainlink** | Oracle-based dynamic fee adjustment using external volatility data |

---

## Getting Started

### Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (stable)
- Solidity ^0.8.26

### Install

```bash
git clone https://github.com/anthropics/foodyswap-hook.git
cd foodyswap-hook
forge install
```

### Build

```bash
forge build
```

### Test

```bash
forge test
```

**Expected output: 18/18 tests passing**

```
[PASS] testAddRestaurant()
[PASS] testBasicSwapTracksLoyalty()
[PASS] testCannotReferSelf()
[PASS] testCannotSetReferrerTwice()
[PASS] testCashbackRewards()
[PASS] testDynamicFeeByTier()
[PASS] testInactiveRestaurantReverts()
[PASS] testMaxTxAmountEnforced()
[PASS] testOnlyAdminCanAddRestaurant()
[PASS] testOperatingHoursEnforced()
[PASS] testReferralSystem()
[PASS] testRemoveRestaurant()
[PASS] testSwapWithoutHookData()
[PASS] testTierUpgrades()
[PASS] testTotalRewardsDistributed()
[PASS] testTotalVolume()
[PASS] testVIPNFTSoulbound()
[PASS] testViewFunctions()

Suite result: ok. 18 passed; 0 failed; 0 skipped
```

### Deploy (Anvil)

```bash
# Start local node
anvil

# Deploy hook
forge script script/DeployFoodySwap.s.sol \
    --rpc-url http://localhost:8545 \
    --private-key <PRIVATE_KEY> \
    --broadcast
```

### Deploy (Base Sepolia)

```bash
# 1. Copy .env.example and fill in your values
cp .env.example .env

# 2. Source the env file
source .env

# 3. Deploy with verification
forge script script/DeployFoodySwap.s.sol \
    --rpc-url base_sepolia \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify
```

### Deploy (Base Mainnet)

```bash
forge script script/DeployFoodySwap.s.sol \
    --rpc-url base \
    --account <KEYSTORE_NAME> \
    --sender <WALLET_ADDRESS> \
    --broadcast \
    --verify
```

> **Note:** After deployment, the hook contract must be granted `MINTER_ROLE` on the FoodyeCoin contract to mint cashback rewards.

---

## Test Coverage

| Category | Tests | Description |
|---|---|---|
| **Loyalty** | `testBasicSwapTracksLoyalty` | Verifies swap updates totalSpent, swapCount, tier |
| **Cashback** | `testCashbackRewards` | Verifies FOODY tokens minted as cashback |
| **Tiers** | `testTierUpgrades` | Verifies tier progression with cumulative spend |
| **Referrals** | `testReferralSystem` | Verifies referrer earns bonus on referee's swaps |
| **Referrals** | `testCannotReferSelf` | Prevents self-referral |
| **Referrals** | `testCannotSetReferrerTwice` | Prevents changing referrer |
| **Restaurants** | `testAddRestaurant` | Admin can add restaurants |
| **Restaurants** | `testRemoveRestaurant` | Admin can deactivate restaurants |
| **Restaurants** | `testOnlyAdminCanAddRestaurant` | Non-admin cannot manage restaurants |
| **Constraints** | `testInactiveRestaurantReverts` | Swap fails for non-whitelisted restaurant |
| **Constraints** | `testOperatingHoursEnforced` | Swap fails outside operating hours |
| **Constraints** | `testMaxTxAmountEnforced` | Transaction limit enforcement |
| **Pricing** | `testDynamicFeeByTier` | Fee discount varies by loyalty tier |
| **VIP** | `testVIPNFTSoulbound` | Soulbound NFT properties |
| **Views** | `testViewFunctions` | All getter functions return correct data |
| **Tracking** | `testTotalVolume` | Volume counter increments |
| **Tracking** | `testTotalRewardsDistributed` | Reward counter increments |
| **Fallback** | `testSwapWithoutHookData` | Swaps without hookData work normally |

### Fuzz Tests

```bash
forge test --match-contract FoodySwapHookFuzzTest -vvv
# Deep run (10,000 iterations):
forge test --match-contract FoodySwapHookFuzzTest --fuzz-runs 10000
```

| Test | Fuzz Input | Invariant |
|---|---|---|
| `testFuzz_DynamicFeeNeverExceedsBase` | `address user` | Fee <= BASE_LP_FEE for any user at any tier |
| `testFuzz_RewardScalingNoOverflow` | `uint256 inputAmount` | 1e12 scaling never overflows for up to $10M swaps |
| `testFuzz_OperatingHoursLogic` | `uint8 open, uint8 close, uint256 time` | Overnight wrapping logic always correct |
| `testFuzz_SwapVaryingAmounts` | `uint256 amountIn` | Swaps of any size track loyalty correctly |
| `testFuzz_ReferralCannotBeExploited` | `address referrer, address referee` | Self-referral blocked, double-set blocked |

---

## Gas Report

Gas snapshots are stored in `.forge-snapshots/`. To regenerate:

```bash
forge snapshot --match-path test/FoodySwapHook.t.sol --snap .forge-snapshots/FoodySwapHook.snap
```

### Key Operations

| Operation | Gas | Description |
|---|---|---|
| `beforeSwap` + `afterSwap` (basic swap) | ~455K | Full hook pipeline with loyalty tracking |
| `afterSwap` with cashback rewards | ~451K | Swap + FOODY mint + loyalty update |
| `afterSwap` with referral bonus | ~519K | Swap + cashback + referrer bonus mint |
| `afterSwap` with tier upgrades (10 swaps) | ~1.08M | Multi-swap accumulation + tier progression |
| `beforeSwap` constraint check (inactive) | ~42K | Restaurant whitelist revert |
| `beforeSwap` operating hours check | ~82K | Time-based constraint validation |
| Swap without hookData (passthrough) | ~129K | No loyalty overhead, base V4 swap |
| `addRestaurant` | ~64K | Admin restaurant management |
| `setReferrer` | ~40K | One-time referral setup |
| `getCurrentFeeForUser` (view) | ~13K | Dynamic fee calculation |

> Gas values measured on Cancun EVM with `forge snapshot`. Check regression with `forge snapshot --check`.

---

## On-Chain References

| Asset | Address | Chain |
|---|---|---|
| FoodyeCoin (FOODY) | [`0x1022B1B028a2237C440DbAc51Dc6fC220D88C08F`](https://basescan.org/token/0x1022B1B028a2237C440DbAc51Dc6fC220D88C08F) | Base |
| USDC | [`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`](https://basescan.org/token/0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913) | Base |
| FOODY/USDC V4 Pool | Position #60816 (0.3% fee) | Base |
| FOODY/USDC V3 Pool | Position #3093011 | Base |

---

## Technical Stack

- **Solidity** 0.8.26+ (compiled with 0.8.30)
- **Foundry** (forge, anvil)
- **Uniswap V4 Core** — PoolManager, Hooks, LPFeeLibrary, BalanceDelta
- **OpenZeppelin Uniswap Hooks** — BaseHook
- **Solmate** — ERC721, ERC20, Owned
- **EVM Version** — Cancun (transient storage support)

---

## Security Considerations

| Area | Mitigation | Status |
|---|---|---|
| **Admin privilege** | Only `admin` can add/remove restaurants, update wallets | Implemented |
| **Reentrancy** | Hook callbacks are called by PoolManager within its lock — no external calls before state updates | Safe by design |
| **Integer overflow** | Solidity 0.8+ built-in overflow checks; reward scaling verified via fuzz tests | Tested |
| **Self-referral** | `setReferrer()` reverts on `msg.sender == referrer` | Tested |
| **Double referral** | Referrer can only be set once per user | Tested |
| **Soulbound NFT** | `transferFrom()` always reverts — VIP NFT cannot be sold/transferred | Tested |
| **hookData validation** | Swaps without hookData (length < 64) skip loyalty logic gracefully | Tested |
| **Operating hours** | Overnight wrapping (e.g., 22:00-06:00) handled correctly | Fuzz tested |
| **Max tx limits** | Per-restaurant configurable caps prevent whale exploitation | Tested |
| **MINTER_ROLE** | Hook requires MINTER_ROLE on FoodyeCoin — must be explicitly granted post-deploy | Documented |
| **Fee bounds** | Dynamic fee can never exceed BASE_LP_FEE (3000 bps = 0.3%) | Fuzz tested |

### Pre-production Checklist

- [ ] Formal audit by a reputable security firm
- [ ] Multi-sig for `admin` role (Gnosis Safe recommended)
- [ ] Time-lock on admin functions (e.g., OpenZeppelin TimelockController)
- [ ] Rate limiting on FOODY cashback minting
- [ ] Emergency pause mechanism
- [ ] Monitor FOODY token supply inflation from cashback rewards

---

## License

MIT

---

## Links

- [FoodyePay Platform](https://foodyepay.com)
- [FoodyeCoin on BaseScan](https://basescan.org/token/0x1022B1B028a2237C440DbAc51Dc6fC220D88C08F)
- [Uniswap V4 Docs](https://docs.uniswap.org/contracts/v4/overview)
- [UHI Hookathon 8](https://www.uniswapfoundation.org/hookathon)
