# Multisig

**Status:** Verified on-chain 2026-06-16 — 2-of-3 Safe at `0xa7a8Eb8FF9dD7481b62BC6900F4e331BacBe638d` on Arbitrum One.

## Arbitrum One — protocol Safe

| Field | Value |
|---|---|
| Address | `0xa7a8Eb8FF9dD7481b62BC6900F4e331BacBe638d` |
| Network | Arbitrum One (chain ID 42161) |
| Threshold | 2-of-3 |
| Owner count | 3 |
| Safe app URL | `https://app.safe.global/home?safe=arb1:0xa7a8Eb8FF9dD7481b62BC6900F4e331BacBe638d` |
| Last verified | 2026-06-16 via direct RPC call |

## Owner set

Owner addresses are public on-chain (anyone can call `getOwners()`), so listing them here adds no leakage:

| # | Address | Role |
|---|---|---|
| 1 | `0x6aeDf63D3caDDf4F6A902d01a1ADA6a6B776bb50` | Recovery — added 2026-06-16 |
| 2 | `0x2b7f9d23A8BDd665294561e0fbEEfD0B58b833F8` | Operating signer |
| 3 | `0x05FD5259cDd72D3F946E1d82a36ab4ea1A0c14f1` | Operating signer (also the Paragraph/Mirror author wallet) |

What is **not** in-repo and should not be: the mapping of address → device, the seed phrases, and the recovery plan for a lost signer. Track those in a password manager.

## Verification record

The 2-of-3 state was confirmed by direct RPC call against Arbitrum One:

```
$ cast call 0xa7a8Eb8FF9dD7481b62BC6900F4e331BacBe638d \
    "getThreshold()(uint256)" --rpc-url https://arb1.arbitrum.io/rpc
2

$ cast call 0xa7a8Eb8FF9dD7481b62BC6900F4e331BacBe638d \
    "getOwners()(address[])" --rpc-url https://arb1.arbitrum.io/rpc
[
  0x6aeDf63D3caDDf4F6A902d01a1ADA6a6B776bb50,
  0x2b7f9d23A8BDd665294561e0fbEEfD0B58b833F8,
  0x05FD5259cDd72D3F946E1d82a36ab4ea1A0c14f1
]
```

Re-run these any time you want to confirm the Safe state hasn't changed.

## Signer policy

The following live outside this repo (password manager / hardware wallet documentation):

- Address → device mapping (which signer is on which hardware wallet / MetaMask profile)
- Hot-wallet vs. cold-wallet split
- Recovery procedure if one signer is lost (a 2-of-3 survives one loss; lose two and the Safe is bricked)
- Quorum-online policy (e.g., "at least 2 signers reachable within 24h")

Owner #1 (`0x6aeD…bb50`) was explicitly added as a recovery signer to gain fault tolerance over the original 2-of-2 configuration. Keep its key in cold storage and out of any operating workflow.

## Roles to grant the Safe (post-mainnet-deploy)

When mainnet is live, the Safe should own these roles on the protocol contracts:

- `RAYPVault` — admin, treasury
- `OracleAggregator` — admin
- `RegimeDampener` — admin, guardian
- `KeeperRegistry` — admin
- All four strategies — admin

The deployer EOA used for testnet is **not** the right owner for mainnet. Before any mainnet broadcast, update `script/DeployStrategies.s.sol` (and any future top-level mainnet deploy script) to take the Safe address as a constructor / setup arg and grant it all admin roles in the same broadcast — no post-deploy ownership transfer.
