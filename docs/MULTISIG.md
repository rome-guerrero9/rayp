# Multisig

**Status:** Candidate address recorded. Verify against the live Safe before treating as canonical or publishing externally.

## Arbitrum One — protocol Safe

| Field | Value |
|---|---|
| Address | `0xa7a8Eb8FF9dD7481b62BC6900F4e331BacBe638d` *(unverified)* |
| Network | Arbitrum One (chain ID 42161) |
| Threshold | 2-of-3 *(claimed; verify)* |
| Safe app URL | `https://app.safe.global/home?safe=arb1:0xa7a8Eb8FF9dD7481b62BC6900F4e331BacBe638d` |

## Verification checklist

Before this Safe is used for anything mainnet-touching:

- [ ] Address resolves to a deployed Safe at the URL above
- [ ] On-chain `getOwners()` returns 3 addresses you recognize
- [ ] On-chain `getThreshold()` returns 2
- [ ] You hold a signing key for at least one owner from each device you intend to sign from
- [ ] Recovery plan documented (what happens if one signer is lost)

Quick check from a node:

```bash
cast call 0xa7a8Eb8FF9dD7481b62BC6900F4e331BacBe638d \
  "getThreshold()(uint256)" --rpc-url https://arb1.arbitrum.io/rpc

cast call 0xa7a8Eb8FF9dD7481b62BC6900F4e331BacBe638d \
  "getOwners()(address[])" --rpc-url https://arb1.arbitrum.io/rpc
```

## Signer policy

**Do not commit signer addresses or device-to-signer mappings to this repo.** Track that mapping in a private note (e.g., a password manager entry) and reference it from here:

- Signer roster location: `TODO — link to private note`
- Hardware-wallet vs. hot-wallet split: `TODO`
- Quorum-online policy (e.g., "at least 2 signers reachable within 24h"): `TODO`

## Roles to grant the Safe (post-mainnet-deploy)

When mainnet is live, the Safe should own these roles on the protocol contracts:

- `RAYPVault` — admin, treasury
- `OracleAggregator` — admin
- `RegimeDampener` — admin, guardian
- `KeeperRegistry` — admin
- All four strategies — admin

The deployer EOA used for testnet is **not** the right owner for mainnet. Before any mainnet broadcast, update `script/DeployRAYP.s.sol` (or equivalent) to take the Safe address as a constructor arg and grant it all admin roles in the same broadcast.
