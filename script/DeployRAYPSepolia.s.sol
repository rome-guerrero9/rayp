// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {RAYPVault} from "../src/RAYPVault.sol";
import {OracleAggregator} from "../src/OracleAggregator.sol";
import {RegimeDampener} from "../src/RegimeDampener.sol";
import {KeeperRegistry} from "../src/KeeperRegistry.sol";
import {NeutralStrategy} from "../src/NeutralStrategy.sol";
import {BullStrategy} from "../src/BullStrategy.sol";
import {BearStrategy} from "../src/BearStrategy.sol";
import {CrisisStrategy} from "../src/CrisisStrategy.sol";

// ─── Mock contracts for testnet ──────────────────────────────────────────────

/// @notice Minimal ERC-20 mock used as a stand-in for the ARB reward token.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8  public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name     = _name;
        symbol   = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply   += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from]             -= amount;
        balanceOf[to]               += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @notice Mock Chainlink aggregator returning a fixed answer.
///         Used for vol and funding feeds which don't exist on Sepolia.
contract MockChainlinkAggregator {
    int256  public immutable fixedAnswer;
    uint8   public immutable _decimals;
    string  public description;

    constructor(string memory _desc, int256 _answer, uint8 __decimals) {
        description = _desc;
        fixedAnswer = _answer;
        _decimals   = __decimals;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, fixedAnswer, block.timestamp, block.timestamp, 1);
    }
}

/// @notice Minimal mock Pyth oracle. Returns a fixed price and confidence.
contract MockPyth {
    struct Price {
        int64  price;
        uint64 conf;
        int32  expo;
        uint   publishTime;
    }

    int64  public immutable fixedPrice;
    uint64 public immutable fixedConf;
    int32  public immutable fixedExpo;

    constructor(int64 _price, uint64 _conf, int32 _expo) {
        fixedPrice = _price;
        fixedConf  = _conf;
        fixedExpo  = _expo;
    }

    function getPriceNoOlderThan(bytes32, uint) external view returns (Price memory) {
        return Price(fixedPrice, fixedConf, fixedExpo, block.timestamp);
    }

    function updatePriceFeeds(bytes[] calldata) external payable {}

    function getUpdateFee(bytes[] calldata) external pure returns (uint) {
        return 0;
    }
}

// ─── Deployment script ───────────────────────────────────────────────────────

/**
 * @title  DeployRAYPSepolia
 * @notice Deploys the complete RAYP protocol stack to Arbitrum Sepolia testnet.
 *
 * Usage:
 *   source .env
 *   export PATH="$PATH:/home/romex/.config/.foundry/bin"
 *   forge script script/DeployRAYPSepolia.s.sol:DeployRAYPSepolia \
 *     --rpc-url $ARBITRUM_SEPOLIA_RPC \
 *     --broadcast \
 *     -vvvv
 */
contract DeployRAYPSepolia is Script {

    // ── Arbitrum Sepolia verified addresses ──────────────────────────────────

    // Aave v3 on Arbitrum Sepolia
    address constant AAVE_POOL    = 0xBfC91D59fdAA134A4ED45f7B584cAf96D7792Eff;
    address constant AAVE_REWARDS = 0x3A203B14CF8749a1e3b7314c6c49004B77Ee667A;

    // Uniswap V3 on Arbitrum Sepolia
    address constant UNISWAP_ROUTER = 0x101F443B4d1b059569D643917553c771E1b9663E;

    // Tokens on Arbitrum Sepolia (Aave testnet tokens)
    address constant WETH = 0x1dF462e2712496373A347f8ad10802a5E95f053D;
    address constant USDC = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;

    // Chainlink ETH/USD on Arbitrum Sepolia
    address constant CHAINLINK_ETH_USD = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;

    // Regime constants
    uint8 constant REGIME_NEUTRAL = 0;
    uint8 constant REGIME_BULL    = 1;
    uint8 constant REGIME_BEAR    = 2;
    uint8 constant REGIME_CRISIS  = 3;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        // On testnet the deployer acts as admin, guardian, and treasury
        address admin    = deployer;
        address guardian = deployer;
        address treasury = deployer;

        console.log("=== RAYP Arbitrum Sepolia Full Deployment ===");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);

        // ─────────────────────────────────────────────────────────────────────
        // Step 0: Deploy mock dependencies not available on Sepolia
        // ─────────────────────────────────────────────────────────────────────

        // Mock ARB reward token (stand-in for ARB on testnet)
        MockERC20 mockARB = new MockERC20("Mock ARB", "mARB", 18);
        console.log("MockERC20 (ARB reward):", address(mockARB));

        // Mock Chainlink vol feed: returns 50% annualised vol (0.5e8 with 8 decimals)
        MockChainlinkAggregator mockVolFeed = new MockChainlinkAggregator(
            "Mock Vol Feed",
            50e6, // 0.50 in 8-decimal format (50% vol)
            8
        );
        console.log("MockChainlinkAggregator (vol):", address(mockVolFeed));

        // Mock Chainlink funding rate feed: returns 0.01% funding (1e4 in 8 decimals)
        MockChainlinkAggregator mockFundingFeed = new MockChainlinkAggregator(
            "Mock Funding Feed",
            1e4, // 0.0001 in 8-decimal format (0.01% funding)
            8
        );
        console.log("MockChainlinkAggregator (funding):", address(mockFundingFeed));

        // Mock Pyth oracle: ETH at ~$3000, conf $3 (~0.1%), expo -8
        MockPyth mockPyth = new MockPyth(
            300_000_000_000, // $3000.00 with expo -8
            300_000_000,     // $3.00 conf (0.1% of price)
            -8
        );
        console.log("MockPyth:", address(mockPyth));

        // ─────────────────────────────────────────────────────────────────────
        // Step 1: Deploy RAYPVault
        //   constructor(asset, regimeDampener, treasury, guardian, admin, initialRegime)
        //   Note: regimeDampener is set to address(0) initially; we wire it up later.
        // ─────────────────────────────────────────────────────────────────────

        RAYPVault vault = new RAYPVault(
            WETH,          // _asset
            address(0),    // _regimeDampener — placeholder, wired in Step 8
            treasury,      // _treasury
            guardian,       // _guardian
            admin,          // _admin
            REGIME_NEUTRAL  // _initialRegime
        );
        console.log("RAYPVault:", address(vault));

        // ─────────────────────────────────────────────────────────────────────
        // Step 2: Deploy OracleAggregator
        //   constructor(guardian, admin, clPrice, clVol, clFunding,
        //               pyth, pythPriceId, pythVolId,
        //               stableToken, stableDecimals, referenceMarketCapE18)
        // ─────────────────────────────────────────────────────────────────────

        // Standard Pyth ETH/USD price feed ID
        bytes32 pythEthUsdId = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
        // Synthetic vol feed ID (not real on testnet, mock handles it)
        bytes32 pythVolId    = bytes32(uint256(1));

        OracleAggregator oracle = new OracleAggregator(
            guardian,                   // _guardian
            admin,                      // _admin
            CHAINLINK_ETH_USD,          // _clPrice (real Sepolia feed)
            address(mockVolFeed),       // _clVol (mock)
            address(mockFundingFeed),   // _clFunding (mock)
            address(mockPyth),          // _pyth (mock)
            pythEthUsdId,               // _pythPriceId
            pythVolId,                  // _pythVolId
            USDC,                       // _stableToken (USDC as stablecoin reference)
            6,                          // _stableDecimals (USDC = 6 decimals)
            50_000_000_000e18           // _referenceMarketCapE18 ($50B reference market cap)
        );
        console.log("OracleAggregator:", address(oracle));

        // ─────────────────────────────────────────────────────────────────────
        // Step 3: Deploy RegimeDampener
        //   constructor(vault, oracle, guardian, admin, initialRegime)
        // ─────────────────────────────────────────────────────────────────────

        RegimeDampener dampener = new RegimeDampener(
            address(vault),   // _vault
            address(oracle),  // _oracle
            guardian,          // _guardian
            admin,             // _admin
            REGIME_NEUTRAL     // _initialRegime
        );
        console.log("RegimeDampener:", address(dampener));

        // ─────────────────────────────────────────────────────────────────────
        // Step 4: Deploy KeeperRegistry
        //   constructor(vault, treasury, guardian, admin)
        // ─────────────────────────────────────────────────────────────────────

        KeeperRegistry keeper = new KeeperRegistry(
            address(vault),  // _vault
            treasury,        // _treasury
            guardian,         // _guardian
            admin             // _admin
        );
        console.log("KeeperRegistry:", address(keeper));

        // ─────────────────────────────────────────────────────────────────────
        // Step 5: Deploy all 4 strategies
        // ─────────────────────────────────────────────────────────────────────

        // 5a. NeutralStrategy (regime 0)
        //   constructor(asset, vault, guardian, aavePool, aaveRewards, swapRouter, rewardToken)
        NeutralStrategy neutralStrat = new NeutralStrategy(
            WETH,
            address(vault),
            guardian,
            AAVE_POOL,
            AAVE_REWARDS,
            UNISWAP_ROUTER,
            address(mockARB)
        );
        console.log("NeutralStrategy:", address(neutralStrat));

        // 5b. BullStrategy (regime 1)
        //   constructor(asset, vault, guardian, aavePool, aaveRewards, swapRouter,
        //               rewardToken, usdc, priceFeed, swapFeeTier, targetLeverageBps)
        BullStrategy bullStrat = new BullStrategy(
            WETH,
            address(vault),
            guardian,
            AAVE_POOL,
            AAVE_REWARDS,
            UNISWAP_ROUTER,
            address(mockARB),
            USDC,
            CHAINLINK_ETH_USD,
            3000,  // 0.3% Uniswap fee tier
            15000  // 1.5x target leverage (150% in bps)
        );
        console.log("BullStrategy:", address(bullStrat));

        // 5c. BearStrategy (regime 2)
        //   constructor(asset, vault, guardian, aavePool, aaveRewards, swapRouter,
        //               rewardToken, usdc, priceFeed, swapFeeTier)
        BearStrategy bearStrat = new BearStrategy(
            WETH,
            address(vault),
            guardian,
            AAVE_POOL,
            AAVE_REWARDS,
            UNISWAP_ROUTER,
            address(mockARB),
            USDC,
            CHAINLINK_ETH_USD,
            3000  // 0.3% Uniswap fee tier
        );
        console.log("BearStrategy:", address(bearStrat));

        // 5d. CrisisStrategy (regime 3)
        //   constructor(asset, vault, guardian, aavePool, aaveRewards, swapRouter, rewardToken)
        CrisisStrategy crisisStrat = new CrisisStrategy(
            WETH,
            address(vault),
            guardian,
            AAVE_POOL,
            AAVE_REWARDS,
            UNISWAP_ROUTER,
            address(mockARB)
        );
        console.log("CrisisStrategy:", address(crisisStrat));

        // ─────────────────────────────────────────────────────────────────────
        // Step 6: Register strategies on vault
        //   vault.setStrategy(regime, strategyAddr) — requires GUARDIAN_ROLE
        // ─────────────────────────────────────────────────────────────────────

        vault.setStrategy(REGIME_NEUTRAL, address(neutralStrat));
        vault.setStrategy(REGIME_BULL,    address(bullStrat));
        vault.setStrategy(REGIME_BEAR,    address(bearStrat));
        vault.setStrategy(REGIME_CRISIS,  address(crisisStrat));
        console.log("Strategies registered on vault");

        // ─────────────────────────────────────────────────────────────────────
        // Step 7: Grant KEEPER_ROLE on vault to the KeeperRegistry
        // ─────────────────────────────────────────────────────────────────────

        bytes32 KEEPER_ROLE = keccak256("KEEPER_ROLE");
        vault.grantRole(KEEPER_ROLE, address(keeper));
        console.log("KEEPER_ROLE granted to KeeperRegistry");

        // ─────────────────────────────────────────────────────────────────────
        // Step 8: Wire up the RegimeDampener as the vault's dampener
        // ─────────────────────────────────────────────────────────────────────

        vault.setRegimeDampener(address(dampener));
        console.log("RegimeDampener wired to vault");

        vm.stopBroadcast();

        // ─────────────────────────────────────────────────────────────────────
        // Summary
        // ─────────────────────────────────────────────────────────────────────

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("RAYPVault:          ", address(vault));
        console.log("OracleAggregator:   ", address(oracle));
        console.log("RegimeDampener:     ", address(dampener));
        console.log("KeeperRegistry:     ", address(keeper));
        console.log("NeutralStrategy:    ", address(neutralStrat));
        console.log("BullStrategy:       ", address(bullStrat));
        console.log("BearStrategy:       ", address(bearStrat));
        console.log("CrisisStrategy:     ", address(crisisStrat));
        console.log("MockERC20 (ARB):    ", address(mockARB));
        console.log("MockVolFeed:        ", address(mockVolFeed));
        console.log("MockFundingFeed:    ", address(mockFundingFeed));
        console.log("MockPyth:           ", address(mockPyth));
        console.log("=== Deployment Complete ===");
    }
}
