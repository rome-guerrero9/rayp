# Arbitrum Sepolia Deployment

**Status:** Unverified. Addresses below are placeholders until you complete the recovery procedure.

The deploy script is `script/DeployRAYPSepolia.s.sol`. It creates 12 contracts (4 mocks + 8 production) in a fixed order from a single deployer EOA, all in one broadcast.

---

## Production contracts

| # | Contract | Address | Arbiscan |
|---|---|---|---|
| 1 | RAYPVault | `TODO` | TODO |
| 2 | OracleAggregator | `TODO` | TODO |
| 3 | RegimeDampener | `TODO` | TODO |
| 4 | KeeperRegistry | `TODO` | TODO |
| 5 | NeutralStrategy | `TODO` | TODO |
| 6 | BullStrategy | `TODO` | TODO |
| 7 | BearStrategy | `TODO` | TODO |
| 8 | CrisisStrategy | `TODO` | TODO |

## Mocks (testnet only — not for mainnet reference)

| # | Contract | Address | Notes |
|---|---|---|---|
| 1 | MockERC20 (mARB) | `TODO` | Mock ARB reward token |
| 2 | MockChainlinkAggregator (vol) | `TODO` | Volatility feed mock |
| 3 | MockChainlinkAggregator (funding) | `TODO` | Funding rate feed mock |
| 4 | MockPyth | `TODO` | Pyth oracle mock |

## Deployer

- EOA: `TODO` (candidate `0x9F4BE17689018e8e56c225d4E5D775E917C7f815` — confirm before trusting)
- Date of deploy: `TODO` (claimed 2026-04-17)
- Deploy tx batch: `TODO` (Arbiscan link to filtered tx list)

---

## Recovery procedure

The Arbiscan UI and the public Arbitrum Sepolia RPC are not reachable from this sandbox, so address recovery has to run on your machine. Run the steps below locally and paste the resulting addresses into the tables above.

### Step 0 — Confirm the deployer EOA

```bash
# If you still have the .env / DEPLOYER_PRIVATE_KEY for the original deploy:
cast wallet address $DEPLOYER_PRIVATE_KEY

# Or, if the key is in a wallet (MetaMask/Frame), copy the address from there.
```

### Step 1 — Pull tx history for the deployer

Two equivalent paths; pick whichever you have credentials for.

**Option A — Arbiscan API (needs free API key):**

```bash
DEPLOYER=0x9F4BE17689018e8e56c225d4E5D775E917C7f815   # replace with confirmed value
ARBISCAN_KEY=YourArbiscanApiKey

curl -sS "https://api-sepolia.arbiscan.io/api?module=account&action=txlist\
&address=${DEPLOYER}&startblock=0&endblock=99999999&sort=asc&apikey=${ARBISCAN_KEY}" \
  | jq '.result[] | select(.to == "") | {hash, blockNumber, timeStamp, contractAddress}'
```

This prints every contract-creation tx the EOA ever made, in chronological order.

**Option B — Direct RPC (no API key needed):**

```bash
DEPLOYER=0x9F4BE17689018e8e56c225d4E5D775E917C7f815
RPC=https://sepolia-rollup.arbitrum.io/rpc

# Total tx count:
cast nonce --rpc-url $RPC $DEPLOYER

# For each nonce N from 0 to (count - 1), the resulting contract address (if it
# was a create) is deterministic via CREATE:
for N in $(seq 0 11); do
  cast compute-address --nonce $N $DEPLOYER
done
```

The CREATE-address derivation only works if the deployer hasn't sent any non-create txs interleaved with the deploys. If they did, use Option A instead — `txlist` returns the actual `contractAddress` for each create.

### Step 2 — Map creations to contract names

The 12 creations come out in this exact order (from `script/DeployRAYPSepolia.s.sol`):

1. MockERC20 (mARB) — line 177
2. MockChainlinkAggregator (vol feed) — line 181
3. MockChainlinkAggregator (funding feed) — line 189
4. MockPyth — line 197
5. **RAYPVault** — line 210
6. **OracleAggregator** — line 232
7. **RegimeDampener** — line 252
8. **KeeperRegistry** — line 266
9. **NeutralStrategy** — line 280
10. **BullStrategy** — line 294
11. **BearStrategy** — line 312
12. **CrisisStrategy** — line 328

### Step 3 — Tie-break by bytecode metadata hash (only if needed)

If two creations have the same timestamp or you suspect an out-of-order anomaly, match the on-chain runtime bytecode against the local artifact:

```bash
forge build

CONTRACT=RAYPVault   # repeat per contract
LOCAL=$(jq -r '.deployedBytecode.object' out/${CONTRACT}.sol/${CONTRACT}.json)
ONCHAIN=$(cast code --rpc-url $RPC $CANDIDATE_ADDRESS)

# Compare the trailing IPFS metadata hash (last ~100 bytes):
echo "${LOCAL: -100}"
echo "${ONCHAIN: -100}"
```

The metadata hashes will match exactly. The non-metadata prefix differs because the constructor immutables (admin, treasury, oracle wiring) get baked in.

### Step 4 — Verify each contract on Arbiscan

Once you've matched addresses to names:

```bash
forge verify-contract \
  --chain arbitrum-sepolia \
  --watch \
  --etherscan-api-key $ARBISCAN_KEY \
  $RAYP_VAULT_ADDRESS \
  src/RAYPVault.sol:RAYPVault
```

Repeat for the other seven production contracts. Mocks don't need verification.

### Step 5 — Update this file

Paste the recovered addresses into the tables above, fill in the deployer EOA and deploy date, and commit:

```bash
git add docs/SEPOLIA_DEPLOYMENT.md
git commit -m "docs: record recovered Sepolia addresses"
```

---

## Fallback — fresh deploy

If Step 1 returns zero contract creations from the candidate deployer, the 2026-04-17 deploy never happened (or used a different key you've lost). Redeploy:

```bash
export DEPLOYER_PRIVATE_KEY=0x...
forge script script/DeployRAYPSepolia.s.sol:DeployRAYPSepolia \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc \
  --broadcast \
  --verify \
  --etherscan-api-key $ARBISCAN_KEY
```

`--verify` runs verification automatically post-deploy. The resulting `broadcast/DeployRAYPSepolia.s.sol/421614/run-latest.json` has the canonical address record — copy it back into this file.
