# ZKsync OS Priority Queue and L1→L2 Deposit Mechanics

*Session 5 — March 2026. Debugging why chain 6567's rich account had 0 ETH on L2 while chains 6565 and 6566 had ~100 ETH.*

---

## Symptom

```bash
cast balance 0x36615Cf349d7F6344891B1e7CA7C72883F5dc049 --rpc-url http://localhost:5250
# 100000318197022664000  ✓

cast balance 0x36615Cf349d7F6344891B1e7CA7C72883F5dc049 --rpc-url http://localhost:5450
# 0  ✗
```

Reproducible on a clean Docker state (no stale volumes). Chain 6567 was simply never funded.

---

## Key concepts

### Priority queue

Each ZKsync chain has a **priority queue** in its L1 diamond proxy contract. L1→L2 transactions
(deposits, forced upgrades) enter the queue as `NewPriorityRequest` events. The queue has:

- **head** (`getFirstUnprocessedPriorityTx()`): next txId zksyncos needs to process. Advances as
  L2 batches are executed on L1 via `executeBatches`.
- **tail** (`getTotalPriorityTxs()`): total txs ever enqueued. Never decreases.

### zksyncos startup assertion

When a zksyncos node starts **fresh** (no L2 database), it always sets
`next_l1_priority_id = 0`. It then scans L1 for `NewPriorityRequest` events and asserts:

```
// model.rs:87
assert_eq!(priority_tx_id, next_l1_priority_id)
```

The **first event it finds must have txId=0**. If not, zksyncos panics:

```
thread 'main' panicked at 'assertion failed: `(left == right)`
  left: `6`,
 right: `0`', src/l1_watcher/model.rs:87
```

### L1 watcher confirmation delay

`l1_watcher_config: confirmations: 2` — the watcher only processes events up to
`currentBlock - 2`. A deposit at block N is not visible until block N+2 exists.

---

## Root cause

During `zkstack ecosystem init` (genesis generation), zkstack sends **6 initialization priority
transactions** to chain 6567's diamond proxy (txIds 0–5). These advance the priority queue head
to 6. However, the Anvil state was dumped with `anvil_dumpState` **after** those txs were
processed and the L2 batches were committed — meaning:

1. The diamond proxy's storage had **head=6** (all 6 init txs processed)
2. But the **event logs** for those init txs were no longer in the Anvil transaction history
   (they were either pruned or simply not captured in the snapshot)

This created an inconsistent state:
- Storage says: "start reading priority queue from position 6"
- Event logs say: nothing at positions 0–5 exists

When zksyncos boots fresh with `next_l1_priority_id=0` and the first event it finds has txId=6,
it panics.

The chain 6567 deposit was also **missing entirely** because `SKIP_DEPOSIT_TX=1` skips
`zksync_os_generate_deposit` during Docker genesis (the binary is not available at runtime), and
`patch_deposits.py` — which handles deposits post-genesis — was only added as part of this fix.

---

## Diagnosis steps

### 1. Confirm the panic

```bash
docker logs <zksyncos_6567_container>
# thread 'main' panicked ... left=6, right=0 ... model.rs:87
```

### 2. Inspect priority queue state via L1 RPC

```bash
# Get diamond proxy address from contracts_6567.yaml
DIAMOND=$(grep diamond_proxy_addr dev/l1/contracts_6567.yaml | awk '{print $2}')

# head pointer
cast call $DIAMOND "getFirstUnprocessedPriorityTx()(uint256)" --rpc-url http://localhost:5010
# → 6   (problem: should be 0 for fresh node)

# tail pointer
cast call $DIAMOND "getTotalPriorityTxs()(uint256)" --rpc-url http://localhost:5010
# → 7   (includes the deposit tx that was supposedly sent)
```

Compare with a working chain (6565):
```bash
cast call $DIAMOND_6565 "getFirstUnprocessedPriorityTx()(uint256)" --rpc-url http://localhost:5010
# → 0   (correct)
cast call $DIAMOND_6565 "getTotalPriorityTxs()(uint256)" --rpc-url http://localhost:5010
# → 6   (6 init txs; deposit will be txId=6 once submitted)
```

### 3. Find the diamond proxy storage slots

The priority queue head and tail are stored in diamond proxy storage. Scan for them:

```python
# Load the l1-state.json.gz, find the diamond proxy in state["accounts"]
# Compare slot values between a working chain (head=0) and broken chain (head=6)
# Slot 52 = head, Slot 54 = tail (confirmed for ZKsync OS v30.2 protocol)
```

---

## Fix procedure

The fix modifies `l1-state.json.gz` in three steps:

### Step 1: Remove the stale deposit event

Load the state JSON and remove the `NewPriorityRequest` log entry for txId=6 from the broken
chain's diamond proxy. This log is stale — it references a txId (6) that zksyncos can't reconcile
with a fresh `next_l1_priority_id=0`.

```python
# Topic 0 of NewPriorityRequest:
# 0x4531cd5729ef28e...  (first 8 chars: 4531cd57)
# txId is encoded in the log data; filter by diamond proxy address
```

### Step 2: Reset priority queue head and tail to 0

Start Anvil with the cleaned state, then use `anvil_setStorageAt` to reset slots:

```bash
anvil --port 18547 --load-state /tmp/cleaned-state.json --silent &

# Reset head (slot 52) to 0
cast rpc anvil_setStorageAt \
  "0x<diamond_proxy_addr>" \
  "0x0000000000000000000000000000000000000000000000000000000000000034" \
  "0x0000000000000000000000000000000000000000000000000000000000000000" \
  --rpc-url http://localhost:18547

# Reset tail (slot 54) to 0
cast rpc anvil_setStorageAt \
  "0x<diamond_proxy_addr>" \
  "0x0000000000000000000000000000000000000000000000000000000000000036" \
  "0x0000000000000000000000000000000000000000000000000000000000000000" \
  --rpc-url http://localhost:18547
```

After this: `getFirstUnprocessedPriorityTx() == 0`, `getTotalPriorityTxs() == 0`.

### Step 3: Submit deposit as txId=0

```bash
# Impersonate rich account (no private key needed in Anvil)
cast rpc anvil_impersonateAccount 0x36615cf349d7f6344891b1e7ca7c72883f5dc049 \
  --rpc-url http://localhost:18547

# Query gas price and base cost
GAS_PRICE=$(cast gas-price --rpc-url http://localhost:18547)
BASE_COST=$(cast call $BRIDGEHUB \
  "l2TransactionBaseCost(uint256,uint256,uint256,uint256)(uint256)" \
  6567 $GAS_PRICE 500000 800 \
  --rpc-url http://localhost:18547)

MINT_VALUE=$((100000000000000000000 + BASE_COST))

# Send deposit via bridgehub
cast send --unlocked --from 0x36615cf349d7f6344891b1e7ca7c72883f5dc049 \
  --value $MINT_VALUE \
  --rpc-url http://localhost:18547 \
  $BRIDGEHUB \
  <abi_encoded_calldata>   # see patch_deposits.py:build_deposit_calldata()
```

### Step 4: Mine confirmation blocks

```bash
# Mine 5 blocks so watcher's 2-block confirmation is satisfied with headroom
cast rpc anvil_mine 5 --rpc-url http://localhost:18547
```

### Step 5: Dump and save the patched state

```python
result = rpc("anvil_dumpState")
raw = bytes.fromhex(result[2:])        # hex-encoded gzip
with gzip.open(io.BytesIO(raw)) as f:
    new_state = json.load(f)

# Preserve historical_states — anvil_dumpState drops them
new_state["historical_states"] = original_state.get("historical_states")

with gzip.open(state_file, "wt", compresslevel=9) as f:
    json.dump(new_state, f)
```

---

## Automated fix: patch_deposits.py

The entire procedure above is automated in `genesis/patch_deposits.py`. It runs as part of the
Docker genesis flow (called by `entrypoint.sh` after `update_server.py`) and handles all chains
in `CHAIN_IDS`. It also runs in `genesis/generate_chains.py` for the local (non-Docker) path.

---

## Verification

After applying the fix:

```bash
# Confirm priority queue is consistent
cast call $DIAMOND "getFirstUnprocessedPriorityTx()(uint256)" --rpc-url http://localhost:5010
# → 0

cast call $DIAMOND "getTotalPriorityTxs()(uint256)" --rpc-url http://localhost:5010
# → 1

# Start the stack and check L2 balance
docker compose ... up -d
sleep 30
cast balance 0x36615Cf349d7F6344891B1e7CA7C72883F5dc049 --rpc-url http://localhost:5452
# → 100000131250000000000  (~100 ETH)
```

zksyncos logs should show no panic and a clean startup:
```
received new events event_name=priority_tx event_count=1
```

---

## Gotchas for future agents

**anvil_dumpState returns hex(gzip(json)), not raw JSON.** Decode as:
```python
raw = bytes.fromhex(result[2:])   # strip 0x, hex-decode → raw gzip bytes
with gzip.open(io.BytesIO(raw)) as f:
    state = json.load(f)
```
Do NOT wrap the output in another `gzip.open(..., "wt")` when writing — that double-gzips.
Write raw bytes directly: `open(path, "wb").write(raw)` if you want to preserve the gzip as-is,
or `gzip.open(path, "wt")` when writing from the decoded `state` dict.

**historical_states is dropped by anvil_dumpState.** The `anvil_dumpState` RPC omits
`historical_states` from the returned blob. Always load the original state first, extract
`original_state.get("historical_states")`, and merge it back into the new state after dumping.
Without it, historical block queries will return empty.

**Priority queue storage slots (ZKsync OS v30.2):**
- Slot `0x34` (decimal 52) = `firstUnprocessedPriorityTx` (head)
- Slot `0x36` (decimal 54) = `totalPriorityTxs` (tail)

These are in the diamond proxy contract for each chain. To find them for a different protocol
version, scan slots 0–299 comparing a working chain (head=0) with a broken chain (head=N).

**cast send value must be decimal, not hex.** `cast send --value 0x56bc7e68b1c0e2740` fails
with "digit 33 is out of range for base 16" (odd number of hex digits). Convert to decimal first:
```bash
python3 -c "print(int('0x56bc7e68b1c0e2740', 16))"
# 100000149936117000000
```

**anvil_impersonateAccount must be called before cast send --unlocked.** Without it, cast returns
"No Signer available."

**All prividium examples (prividium-1, -2, -3) share the same l1-state.json.gz.** The L1 has
all 3 chains pre-deployed. The difference is only which L2 containers are started. Changing the
state file for one example requires syncing all three (and `configs/v30.2/l1-state.json.gz`).
