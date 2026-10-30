# RAYP Arbitrum Sepolia Deployment

**Date:** 2026-04-17
**Chain:** Arbitrum Sepolia (421614)
**Deployer:** 0x9F4BE17689018e8e56c225d4E5D775E917C7f815
**Explorer:** https://sepolia.arbiscan.io

## Protocol Contracts

| Contract | Address |
|---|---|
| RAYPVault | `0x8739d8101e8f9cebe5d62a075b132ebd12a0b4d5` |
| OracleAggregator | `0x4dedaeab1063ec4867dcd6902b4e5d7298fb0b9f` |
| RegimeDampener | `0x596281184591df85cee239c7251c836c3efb620d` |
| KeeperRegistry | `0xf37d3d6fba95bf6f7c59150ee2b1987b52f4f2b9` |
| NeutralStrategy (Regime 0) | `0xb560af59d20089f69cd9d505b5dccc374d423cf0` |
| BullStrategy (Regime 1) | `0x88a67b3a8bbd3ffb16ff5f343e9edaeb1b439f1a` |
| BearStrategy (Regime 2) | `0xa3938b1bd61b64b7a8ce6e05c175218afd9ead26` |
| CrisisStrategy (Regime 3) | `0x3186c7485e812e1af6ec6f778c26aaa03f25355a` |

## Mock Contracts (testnet only)

| Contract | Address |
|---|---|
| MockERC20 (ARB) | `0x8e7b7b5f2fa3930dd81a245642bcb1d049a7e917` |
| MockChainlinkAggregator (vol) | `0x1bb7ddca70fe0d6b52b556b7846e4fb8846a61f0` |
| MockChainlinkAggregator (funding) | `0x09e8e4aca09fe7d60681d4b5c30b9f4ea4966676` |
| MockPyth | `0x13538739894475bd4f6a0a04b156fd047fb684a4` |

## External Dependencies (Arbitrum Sepolia)

| Contract | Address |
|---|---|
| Aave v3 Pool | `0xBfC91D59fdAA134A4ED45f7B584cAf96D7792Eff` |
| Aave v3 Rewards | `0x3A203B14CF8749a1e3b7314c6c49004B77Ee667A` |
| Uniswap V3 Router | `0x101F443B4d1b059569D643917553c771E1b9663E` |
| WETH | `0x1dF462e2712496373A347f8ad10802a5E95f053D` |
| USDC | `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d` |
| Chainlink ETH/USD | `0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165` |

## Roles

- **Admin / Guardian / Treasury:** Deployer (0x9F4BE17689018e8e56c225d4E5D775E917C7f815)
- **KEEPER_ROLE:** KeeperRegistry (0xf37d3d6fba95bf6f7c59150ee2b1987b52f4f2b9)

## Verified State

- Active regime: 0 (NEUTRAL)
- All 4 strategies registered
- KeeperRegistry has KEEPER_ROLE
- RegimeDampener wired to vault
