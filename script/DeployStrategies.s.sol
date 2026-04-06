// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {NeutralStrategy} from "../src/NeutralStrategy.sol";
import {BearStrategy} from "../src/BearStrategy.sol";
import {BullStrategy} from "../src/BullStrategy.sol";

/**
 * @title  DeployStrategies
 * @notice Foundry script to deploy all three new RAYP strategies on Arbitrum.
 *
 * Usage:
 *   forge script script/DeployStrategies.s.sol:DeployStrategies \
 *     --rpc-url $ARBITRUM_RPC \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 *
 * Environment variables required:
 *   DEPLOYER_PRIVATE_KEY  - deployer wallet private key
 *   VAULT_ADDRESS         - deployed RAYPVault address
 *   GUARDIAN_ADDRESS       - guardian multisig address
 */
contract DeployStrategies is Script {

    // ── Arbitrum mainnet addresses ────────────────────────────────────────────
    address constant AAVE_POOL       = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant AAVE_REWARDS    = 0x929EC64c34a17401F460460D4B9390518E5B473e;
    address constant UNISWAP_ROUTER  = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant WETH            = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant USDC            = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant ARB             = 0x912CE59144191C1204E64559FE8253a0e49E6548;
    address constant CHAINLINK_ETH   = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;

    function run() external {
        address vault    = vm.envAddress("VAULT_ADDRESS");
        address guardian = vm.envAddress("GUARDIAN_ADDRESS");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        // 1. Deploy NeutralStrategy (regime 0)
        NeutralStrategy neutral = new NeutralStrategy(
            WETH, vault, guardian,
            AAVE_POOL, AAVE_REWARDS, UNISWAP_ROUTER, ARB
        );
        console.log("NeutralStrategy deployed at:", address(neutral));

        // 2. Deploy BearStrategy (regime 2)
        BearStrategy bear = new BearStrategy(
            WETH, vault, guardian,
            AAVE_POOL, AAVE_REWARDS, UNISWAP_ROUTER, ARB,
            USDC, CHAINLINK_ETH,
            500 // 0.05% WETH/USDC pool tier
        );
        console.log("BearStrategy deployed at:", address(bear));

        // 3. Deploy BullStrategy (regime 1)
        BullStrategy bull = new BullStrategy(
            WETH, vault, guardian,
            AAVE_POOL, AAVE_REWARDS, UNISWAP_ROUTER, ARB,
            USDC, CHAINLINK_ETH,
            500,   // 0.05% WETH/USDC pool tier
            20000  // 2x leverage
        );
        console.log("BullStrategy deployed at:", address(bull));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Next steps ===");
        console.log("Register strategies on vault (guardian call):");
        console.log("  vault.setStrategy(0, neutral)  // NEUTRAL");
        console.log("  vault.setStrategy(1, bull)     // BULL");
        console.log("  vault.setStrategy(2, bear)     // BEAR");
    }
}
