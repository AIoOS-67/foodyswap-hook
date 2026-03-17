# FoodySwap Hook

**Intent-driven commerce on Uniswap v4: a single hook that turns AI payment intent into enforceable restaurant settlement, dynamic pricing, and on-chain loyalty.**

> Part of [FoodyePay](https://foodyepay.com), the broader platform for AI-powered restaurant commerce.

---

## Judge Summary

FoodySwap is a **real Uniswap v4 hook** for programmable commerce.

It does not stop at AI intent generation. It enforces merchant validity, time windows, transaction limits, dynamic fees, cashback, loyalty progression, referrals, and VIP rewards inside the swap lifecycle.

If you only read one thing in this README, read this:

- the website describes FoodySwap as a **5-layer commerce protocol**
- this repo implements the **on-chain enforcement layer** as a **single Uniswap v4 hook**
- those are two views of the same system, not two different architectures

---

## What This Repo Is

FoodySwap is presented publicly as a **5-layer commerce protocol**:

1. Intent Verification
2. Agent Market
3. Commerce Guard
4. Smart Pricing
5. Settlement + Loyalty

This repository implements the **on-chain execution and enforcement** of that system as a **single Uniswap v4 hook**.

That distinction matters:

- the website explains the full product architecture
- this repo focuses on the hook contract, tests, deployment scripts, and reproducible swap flow

So the website's **5 layers** and the repo's **single-hook design** are not in conflict. They are two levels of the same stack.

---

## Why It Matters

Most AI commerce demos stop at intent suggestion.

FoodySwap does not.

FoodySwap takes an AI-generated payment intent and makes it enforceable on-chain:

- only approved merchants can receive settlement
- transaction windows and per-merchant limits are checked
- LP fees adapt to diner context
- cashback, tiers, and VIP status update automatically
- swaps without valid hook context degrade safely

This is why FoodySwap is not just a loyalty demo. It is a Uniswap v4 hook for **real-world programmable commerce**.

---

## Architecture

### Product Narrative vs Contract Execution

At the product level, FoodySwap is described as a **5-layer protocol**.

At the contract level, those five layers compress into the hook lifecycle:

| Product layer | On-chain implementation in this repo |
|---|---|
| Layer 0: Intent Verification | Intent prepared off-chain and submitted through approved router flow |
| Layer 1: Agent Market | Best execution selected before swap submission |
| Layer 2: Commerce Guard | `beforeSwap()` merchant checks, hours checks, max transaction checks |
| Layer 3: Smart Pricing | `beforeSwap()` dynamic fee override via `LPFeeLibrary.OVERRIDE_FEE_FLAG` |
| Layer 4: Settlement + Loyalty | `afterSwap()` cashback, tier tracking, referrals, VIP rewards |

### One Hook, Three Hook Stages

FoodySwap uses a **single hook contract** because that is the cleanest v4 implementation:

- less gas than splitting logic across multiple contracts
- simpler state management
- aligned with v4's one-hook-per-pool model
- easier for judges to audit quickly

```text
FoodySwapHook.sol
|- afterInitialize()
|  `- initial dynamic fee setup
|- beforeSwap()
|  |- Commerce Guard
|  |  |- restaurant whitelist verification
|  |  |- operating hours validation
|  |  `- per-transaction amount limits
|  `- Smart Pricing
|     |- tier-based fee discount
|     |- peak-hour bonus
|     `- dynamic fee override
`- afterSwap()
   `- Settlement + Loyalty
      |- FOODY cashback mint
      |- loyalty points and tier upgrades
      |- referral bonus
      `- VIP NFT auto-mint
```

### Hook Permissions

| Permission | Used | Purpose |
|---|---|---|
| `afterInitialize` | Yes | Set initial dynamic LP fee configuration |
| `beforeSwap` | Yes | Enforce merchant constraints and compute dynamic pricing |
| `afterSwap` | Yes | Apply settlement-side rewards and loyalty accounting |
| All others | No | Intentionally omitted |

---

## Security Note: Review Feedback Addressed

One important trust-boundary issue was identified during review:

Earlier drafts allowed user identity to be inferred from caller-provided `hookData`, which could be spoofed.

That is **not** how the current hook works.

### Current Design

- `hookData` carries only `restaurantId`
- diner identity is resolved from the approved router via `IMsgSender(sender).msgSender()`

This ties discounts and rewards to the actual transaction initiator instead of trusting user-supplied calldata.

Relevant fix:
- [`ef1b1eb`](https://github.com/AIoOS-67/foodyswap-hook/commit/ef1b1ebf50a89faa8be6b2aba7d94d01ea02c928) - use `IMsgSender` instead of spoofable `hookData`

---

## Contracts

| Contract | Purpose |
|---|---|
| [`src/FoodySwapHook.sol`](src/FoodySwapHook.sol) | Main hook implementing constraints, pricing, settlement, and loyalty |
| [`src/FoodyVIPNFT.sol`](src/FoodyVIPNFT.sol) | Soulbound VIP membership NFT |
| [`src/MockUSDC.sol`](src/MockUSDC.sol) | Testnet / local mock USDC |
| [`test/mocks/MockFoodyToken.sol`](test/mocks/MockFoodyToken.sol) | Test mock for FoodyeCoin |

---

## Loyalty System

| Tier | Threshold | Fee Discount | Cashback Rate | Perks |
|---|---|---|---|---|
| Bronze | $0+ | 2% | 3% FOODY | Base tier |
| Silver | $200+ | 5% | 5% FOODY | Better rates |
| Gold | $500+ | 8% | 7% FOODY | Higher rewards |
| VIP | $1,000+ | 12% | 10% FOODY | Soulbound VIP NFT |

Additional mechanics:

- lunch / dinner peak-hour bonus applies an extra discount
- referrals reward both referrer and referee
- VIP status auto-mints a non-transferable NFT

---

## Partner Integrations

| Partner | Role in FoodySwap | Status |
|---|---|---|
| **Uniswap v4** | Hook lifecycle, pool manager, swap callbacks, fee override mechanics | Implemented |
| **Base** | Target chain for FOODY commerce flows | Implemented / targeted |
| **FoodyeCoin (FOODY)** | Reward token and loyalty asset | Integrated |
| **USDC** | Payment-side settlement currency | Integrated |
| **OpenZeppelin Uniswap Hooks** | `BaseHook` foundation | Implemented |
| **Solmate** | NFT and token primitives | Implemented |
| **FoodyePay app layer** | Voice AI, wallet UX, merchant-facing experience | Platform-level integration |

Potential future extensions:

- Circle Paymaster for gasless flows
- Circle CCTP for cross-chain USDC replenishment
- Chainlink for oracle-assisted pricing inputs

---

## Reproducible Setup

### Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Solidity `^0.8.26`

### Clone

```bash
git clone --recurse-submodules https://github.com/AIoOS-67/foodyswap-hook.git
cd foodyswap-hook
```

### Build

```bash
forge build
```

### Unit Tests

```bash
forge test --match-path test/FoodySwapHook.t.sol
```

Expected:

- `18` unit tests passing

### Fuzz Tests

```bash
forge test --match-path test/FoodySwapHook.fuzz.t.sol -vvv
```

Hookathon validation narrative reflected in recent commits:

- 18 unit tests
- 5 fuzz tests
- additional integration / script validation

Relevant commits:

- [`c21e668`](https://github.com/AIoOS-67/foodyswap-hook/commit/c21e668b7f32ff06b25f998dce8194862a3607f6)
- [`6298c1f`](https://github.com/AIoOS-67/foodyswap-hook/commit/6298c1fe05ddd40d267d2d5a68814b23dc7481d4)

---

## Deployment and Sepolia Evidence

This repo contains the scripts needed to reproduce the hook flow on Base Sepolia:

- [`script/DeployFoodySwap.s.sol`](script/DeployFoodySwap.s.sol)
- [`script/CreatePoolSepolia.s.sol`](script/CreatePoolSepolia.s.sol)
- [`script/SetupTestnet.s.sol`](script/SetupTestnet.s.sol)
- [`script/TestSwapSepolia.s.sol`](script/TestSwapSepolia.s.sol)

These scripts cover:

- hook deployment
- FOODY / USDC pool setup
- restaurant and user test configuration
- end-to-end swap verification through the hook

### Deploy (Anvil)

```bash
anvil

forge script script/DeployFoodySwap.s.sol \
  --rpc-url http://localhost:8545 \
  --private-key <PRIVATE_KEY> \
  --broadcast
```

### Deploy (Base Sepolia)

```bash
cp .env.example .env
# fill in your env vars

forge script script/DeployFoodySwap.s.sol \
  --rpc-url base_sepolia \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

> After deployment, the hook contract must be granted `MINTER_ROLE` on the FoodyeCoin contract to mint cashback rewards.

---

## On-Chain References

| Asset | Address | Chain |
|---|---|---|
| FoodyeCoin (FOODY) | [`0x1022B1B028a2237C440DbAc51Dc6fC220D88C08F`](https://basescan.org/token/0x1022B1B028a2237C440DbAc51Dc6fC220D88C08F) | Base |
| USDC | [`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`](https://basescan.org/token/0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913) | Base |

Verification notes:

- diner identity no longer comes from spoofable `hookData`
- this repo includes scripts for deploy, pool creation, and test swap verification
- recent hookathon commits document the expanded validation matrix and security fixes

---

## Technical Stack

- Solidity `0.8.26+` compiled with `0.8.30`
- Foundry
- Uniswap v4 Core
- OpenZeppelin Uniswap Hooks
- Solmate
- Cancun EVM

---

## Security Considerations

| Area | Mitigation | Status |
|---|---|---|
| Admin privilege | Only `admin` can add / remove restaurants and update wallets | Implemented |
| Reentrancy | Hook callbacks run through PoolManager flow; no unsafe external flow before state updates | Safe by design |
| Integer overflow | Solidity `0.8+` checks plus fuzz validation | Tested |
| Self-referral | `setReferrer()` rejects self-referral | Tested |
| Double referral | Referrer can only be set once | Tested |
| Soulbound NFT | VIP NFT transfer is blocked | Tested |
| hookData validation | Swaps without hookData skip loyalty logic safely | Tested |
| Operating hours | Overnight wrapping handled correctly | Fuzz tested |
| Max tx limits | Per-merchant caps reduce abuse | Tested |
| MINTER_ROLE | Cashback minting requires explicit post-deploy permission | Documented |
| Fee bounds | Dynamic fee cannot exceed base LP fee | Fuzz tested |

---

## Links

- [FoodySwap website](https://foodyswap.com)
- [FoodyePay platform](https://foodyepay.com)
- [FoodyeCoin on BaseScan](https://basescan.org/token/0x1022B1B028a2237C440DbAc51Dc6fC220D88C08F)
- [Uniswap v4 docs](https://docs.uniswap.org/contracts/v4/overview)
- [UHI Hookathon 8](https://www.uniswapfoundation.org/hookathon)

---

## License

MIT
