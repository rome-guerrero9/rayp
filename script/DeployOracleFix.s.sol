// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {OracleAggregator} from "../src/OracleAggregator.sol";
import {MockPythChainlinkMirror} from "./MockPythChainlinkMirror.sol";

/**
 * @title  DeployOracleFix
 * @notice Sepolia-only fix: replaces the broken MockPyth (which returned the
 *         same hardcoded payload for every feed ID) with MockPythChainlinkMirror,
 *         then redeploys OracleAggregator pointing at it. All other feed
 *         parameters are preserved from the existing deployment so the rest of
 *         the RAYP stack (vault, dampener, strategies) keeps working.
 *
 *         The vault and dampener are NOT redeployed. The bot reads
 *         OracleAggregator directly, so updating its ADDRESSES constant after
 *         this deploy is sufficient to unblock real metrics in the post.
 *
 * Usage:
 *   export DEPLOYER_PRIVATE_KEY=0x...
 *   export ARBITRUM_SEPOLIA_RPC=https://sepolia-rollup.arbitrum.io/rpc
 *   forge script script/DeployOracleFix.s.sol:DeployOracleFix \
 *     --rpc-url $ARBITRUM_SEPOLIA_RPC \
 *     --broadcast \
 *     -vvvv
 */
contract DeployOracleFix is Script {

    // ── Existing Arb Sepolia addresses (captured from on-chain reads) ────────

    address constant CHAINLINK_ETH_USD  = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;
    address constant MOCK_CL_VOL        = 0x1Bb7dDcA70Fe0D6b52B556b7846E4Fb8846A61f0;
    address constant MOCK_CL_FUNDING    = 0x09E8e4acA09fE7d60681D4b5C30b9f4EA4966676;
    address constant USDC               = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;

    bytes32 constant PYTH_ETH_USD_ID    = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 constant PYTH_VOL_ID        = bytes32(uint256(1));

    uint256 constant REFERENCE_MARKET_CAP_E18 = 50_000_000_000e18;  // $50B

    // ── Mock Pyth vol payload (sane testnet values) ──────────────────────────
    //
    //   volPrice / 10^|volExpo| = 0.50  (i.e. 50% annualised vol)
    //   volConf  / volPrice     = 0.10% (well under MAX_PYTH_CONF_BPS = 50 bps)
    //
    //   After OracleAggregator._normalisePyth(5e7, -8) = 5e17 = 50% in 1e18 units.
    //   Matches MockChainlinkAggregator(MOCK_CL_VOL) which also returns 50%,
    //   so vol consensus diff = 0 and no penalty flag.

    int64  constant VOL_PRICE       = 50_000_000;   // 5e7
    uint64 constant VOL_CONF        = 50_000;       // 0.1% of volPrice → 10 bps
    int32  constant VOL_EXPO        = -8;
    uint64 constant PRICE_CONF_BPS  = 10;           // 0.10% conf on the mirrored price

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        // Testnet: deployer holds admin + guardian on the new oracle
        address admin    = deployer;
        address guardian = deployer;

        console.log("=== RAYP Oracle Fix Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerKey);

        // ── Step 1: Deploy MockPythChainlinkMirror ───────────────────────────

        MockPythChainlinkMirror mockPyth = new MockPythChainlinkMirror(
            CHAINLINK_ETH_USD,
            PYTH_ETH_USD_ID,
            PYTH_VOL_ID,
            PRICE_CONF_BPS,
            VOL_PRICE,
            VOL_CONF,
            VOL_EXPO
        );
        console.log("MockPythChainlinkMirror:", address(mockPyth));

        // ── Step 2: Redeploy OracleAggregator pointing at the new mock ───────

        OracleAggregator oracle = new OracleAggregator(
            guardian,
            admin,
            CHAINLINK_ETH_USD,
            MOCK_CL_VOL,
            MOCK_CL_FUNDING,
            address(mockPyth),
            PYTH_ETH_USD_ID,
            PYTH_VOL_ID,
            USDC,
            6,
            REFERENCE_MARKET_CAP_E18
        );
        console.log("OracleAggregator (new):", address(oracle));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Done ===");
        console.log("Update bot/src/contracts.ts ADDRESSES.oracleAggregator to:");
        console.log(address(oracle));
    }
}
