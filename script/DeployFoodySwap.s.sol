// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {FoodySwapHook} from "../src/FoodySwapHook.sol";

/// @title DeployFoodySwap — Deploy FoodySwapHook + FoodyVIPNFT
/// @notice Mines a CREATE2 salt for the correct hook permission flags,
///         then deploys FoodySwapHook which auto-deploys FoodyVIPNFT.
///
/// @dev Usage:
///   # Dry-run (no broadcast):
///   forge script script/DeployFoodySwap.s.sol --rpc-url base_sepolia
///
///   # Actual deployment:
///   forge script script/DeployFoodySwap.s.sol \
///     --rpc-url base_sepolia \
///     --private-key $PRIVATE_KEY \
///     --broadcast \
///     --verify
contract DeployFoodySwapScript is Script {
    // CREATE2_FACTORY is inherited from forge-std Script (0x4e59...956C)

    function run() public {
        // =====================================================================
        // Read deployment parameters from environment variables
        // =====================================================================
        address poolManagerAddr = vm.envAddress("POOL_MANAGER");
        address foodyToken = vm.envAddress("FOODY_TOKEN");
        address platformWallet = vm.envAddress("PLATFORM_WALLET");
        address rewardPoolWallet = vm.envAddress("REWARD_POOL_WALLET");
        address admin = vm.envAddress("ADMIN_ADDRESS");

        console2.log("=== FoodySwap Hook Deployment ===");
        console2.log("Pool Manager:", poolManagerAddr);
        console2.log("FOODY Token:", foodyToken);
        console2.log("Platform Wallet:", platformWallet);
        console2.log("Reward Pool Wallet:", rewardPoolWallet);
        console2.log("Admin:", admin);

        IPoolManager poolManager = IPoolManager(poolManagerAddr);

        // =====================================================================
        // Hook permission flags: afterInitialize + beforeSwap + afterSwap
        // These must match FoodySwapHook.getHookPermissions()
        // =====================================================================
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        // =====================================================================
        // Constructor arguments for FoodySwapHook
        // =====================================================================
        bytes memory constructorArgs = abi.encode(
            poolManager,
            foodyToken,
            platformWallet,
            rewardPoolWallet,
            admin
        );

        // =====================================================================
        // Mine a salt that produces a hook address with the correct flag bits
        // =====================================================================
        console2.log("Mining CREATE2 salt for hook address flags...");
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY,
            flags,
            type(FoodySwapHook).creationCode,
            constructorArgs
        );

        console2.log("Target hook address:", hookAddress);
        console2.log("Salt:", vm.toString(salt));

        // =====================================================================
        // Deploy via CREATE2
        // =====================================================================
        vm.startBroadcast();
        FoodySwapHook hook = new FoodySwapHook{salt: salt}(
            poolManager,
            foodyToken,
            platformWallet,
            rewardPoolWallet,
            admin
        );
        vm.stopBroadcast();

        // Verify the deployed address matches the mined address
        require(
            address(hook) == hookAddress,
            "DeployFoodySwap: hook address mismatch"
        );

        // =====================================================================
        // Log results
        // =====================================================================
        console2.log("");
        console2.log("=== Deployment Successful ===");
        console2.log("FoodySwapHook:", address(hook));
        console2.log("FoodyVIPNFT:", address(hook.vipNFT()));
        console2.log("");
        console2.log("Next steps:");
        console2.log("1. Grant MINTER_ROLE on FoodyeCoin to:", address(hook));
        console2.log("2. Call hook.addRestaurant() to whitelist restaurants");
        console2.log("3. Create FOODY/USDC pool with this hook attached");
    }
}
