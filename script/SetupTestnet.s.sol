// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {FoodySwapHook} from "../src/FoodySwapHook.sol";

/// @title SetupTestnet — Deploy MockUSDC + Whitelist Restaurants + Distribute Tokens
/// @notice Run on Base Sepolia after FoodySwapHook is deployed.
///
/// @dev Usage:
///   forge script script/SetupTestnet.s.sol \
///     --rpc-url base_sepolia \
///     --private-key $PRIVATE_KEY \
///     --sender 0xB4ffaAc40f4cA6ECb006AE6d739262f1458b64a3 \
///     --broadcast
contract SetupTestnetScript is Script {
    // =========================================================================
    // Deployed contracts
    // =========================================================================
    FoodySwapHook constant hook = FoodySwapHook(0xA42d7D6947E3a9f0412e2ed1AB7E36Afa00F10c0);

    // =========================================================================
    // OpenClaw Agent Wallets
    // =========================================================================
    address constant DEPLOYER      = 0xB4ffaAc40f4cA6ECb006AE6d739262f1458b64a3;
    address constant MEI_LIN       = 0xA5178af57139c7081104d7A1a2ECB6Cd6E63A121;
    address constant DAVID_CHEN    = 0x3fA507dc3185A9c5AC6b66184Fd2248f5ee92242;
    address constant SOFIA         = 0x3c2204D6EC590C70adFbfBce44D2F95B8d100232;
    address constant JAMES_WU      = 0x940Beb572afA69FCe20F09cE3A3054dB69d15199;
    address constant AMY_ZHANG     = 0x24265bE054D94AFFcAb000d553a6653e2eBc6a5E;

    address constant SICHUAN_GARDEN = 0xcF5c56396128557eaD615d5B6BEED756159c0c13;
    address constant PEARL_DIM_SUM  = 0x7355048E9134CF7B641787E2061db87847E5d334;
    address constant GOLDEN_PHO     = 0x9c958328f273782FdDA6012fD28E556F466B118B;

    function run() external {
        console2.log("=== FoodySwap Testnet Setup ===");
        console2.log("Hook:", address(hook));

        vm.startBroadcast();

        // =====================================================================
        // Step 1: Deploy MockUSDC
        // =====================================================================
        MockUSDC usdc = new MockUSDC();
        console2.log("MockUSDC deployed:", address(usdc));

        // =====================================================================
        // Step 2: Mint USDC to deployer and diner wallets
        // =====================================================================
        usdc.mint(DEPLOYER, 1_000_000e6);    // 1M USDC to deployer (for LP)
        usdc.mint(MEI_LIN, 10_000e6);        // 10K to each diner
        usdc.mint(DAVID_CHEN, 10_000e6);
        usdc.mint(SOFIA, 10_000e6);
        usdc.mint(JAMES_WU, 10_000e6);
        usdc.mint(AMY_ZHANG, 10_000e6);
        console2.log("USDC minted to deployer + 5 diners");

        // =====================================================================
        // Step 3: Whitelist restaurants on Hook
        // =====================================================================
        // restaurantId = keccak256 of restaurant name
        // openHour=0, closeHour=0 → 24/7 operation
        // maxTxAmount=0 → no limit
        bytes32 sichuanId = keccak256("sichuan_garden");
        bytes32 pearlId = keccak256("pearl_dim_sum");
        bytes32 goldenId = keccak256("golden_pho");

        hook.addRestaurant(sichuanId, SICHUAN_GARDEN, 0, 0, 0);
        console2.log("Restaurant added: Sichuan Garden", SICHUAN_GARDEN);
        console2.log("  restaurantId:", vm.toString(sichuanId));

        hook.addRestaurant(pearlId, PEARL_DIM_SUM, 0, 0, 0);
        console2.log("Restaurant added: Pearl Dim Sum", PEARL_DIM_SUM);
        console2.log("  restaurantId:", vm.toString(pearlId));

        hook.addRestaurant(goldenId, GOLDEN_PHO, 0, 0, 0);
        console2.log("Restaurant added: Golden Pho", GOLDEN_PHO);
        console2.log("  restaurantId:", vm.toString(goldenId));

        vm.stopBroadcast();

        // =====================================================================
        // Log summary
        // =====================================================================
        console2.log("");
        console2.log("=== Setup Complete ===");
        console2.log("MockUSDC:", address(usdc));
        console2.log("FoodySwapHook:", address(hook));
        console2.log("");
        console2.log("Next steps:");
        console2.log("1. Create FOODY/USDC pool on V4 PoolManager");
        console2.log("2. Add initial liquidity");
        console2.log("3. Grant MINTER_ROLE on FOODY to hook (OpenClaw)");
    }
}
