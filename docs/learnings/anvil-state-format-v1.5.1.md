# Anvil v1.5.1 State Format Breaking Change

*Session 4 — March 2026. Debugging why `./start.sh` failed for prividium examples after upgrading to foundry v1.5.1.*

---

## What broke

All prividium examples failed to start. The L1 container (Anvil) crashed immediately with:

```
failed to parse json file: missing field `index` at line 1 column 3080948
```

Anvil v1.5.1 could not load the existing `l1-state.json.gz` files.

---

## Investigation path

### Wrong fix first: reverted to v1.3.4

The initial response was to revert Foundry from v1.5.1 → v1.3.4 across all scripts and examples. This worked (v1.3.4 loaded the state fine) but didn't address the root cause. Committed and pushed.

**Why this was the wrong call:** The state file is *generated* by the genesis Docker image, which already uses the latest Anvil (whatever `foundryup` installs). Pinning the runtime to v1.3.4 while the generator uses v1.5.1 would create a version mismatch as soon as genesis is re-run.

**Better approach:** Fix the state file format, then use v1.5.1 everywhere.

### Identifying the real fix

The `missing field 'index'` error reported a column offset in the *decompressed* JSON (not the gzip). Extracting the context at column 3093755:

```
"position": 1}], "ordering": [{"Call": 0}, {"Log": 0}]}, {"parent": 3, ...
```

The error fired after `"position": 1}` — the closing brace of a **log entry** inside a trace node. Serde finished parsing the object and found that the required field `index` was never seen.

Confirmed by running Anvil v1.5.1 fresh, sending a transaction that emits an event, then dumping state:

```json
"logs": [{"raw_log": {...}, "decoded": null, "position": 0, "index": 0}]
```

v1.5.1 added `index` as a **required** field alongside the existing `position` field in `TraceLog`. Old state files only have `position`.

### Why `index` was suspected in the wrong place

The first attempt (previous session) added `index` to **top-level transaction objects** (`tx.index = tx.info.transaction_index`). This was wrong — v1.5.1's own `--dump-state` output has no `index` at that level. The column offset in the error pointed to a different position, but without tracing it through the decompressed JSON it appeared to be in a transaction.

---

## The fix

Add `index = position` to every log entry inside trace nodes:

```python
for tx in state.get('transactions', []):
    for node in tx.get('info', {}).get('traces', []):
        for log in node.get('logs', []):
            if 'index' not in log:
                log['index'] = log.get('position', 0)
```

293 log entries fixed in `configs/v30.2/l1-state.json.gz`. Result: Anvil v1.5.1 loads the state, returns block `122` and chain-id `31337`.

---

## What to do when upgrading Anvil versions

1. **Check the `--dump-state` format** by running the new Anvil on a scratch instance, sending a transaction with logs (not just a plain transfer — those have empty `logs` arrays in traces), and inspecting the output.

2. **Compare log entry keys** between the new dump and your existing state file. Any new required key needs to be back-filled.

3. **Test state load** before committing the version bump:
   ```bash
   docker run --rm --entrypoint "" --user root \
     -v "$(pwd)/configs/v30.2/l1-state.json.gz:/l1-state.json.gz:ro" \
     ghcr.io/foundry-rs/foundry:NEW_VERSION \
     sh -c 'gzip -d < /l1-state.json.gz > /tmp/s.json && \
            anvil --load-state /tmp/s.json & sleep 8 && \
            cast block-number --rpc-url http://localhost:8545'
   ```
   Expected: block `122` (0x7a). Any parse error = state migration needed.

4. **Update `genesis/Dockerfile`** to pin `anvil` via `COPY --from=ghcr.io/foundry-rs/foundry:VERSION` instead of `foundryup` (which installs latest). This ensures regenerated state files match the runtime version.

---

## Gotchas

- **`anvil_dumpState` format vs `--dump-state` format differ between versions.** v1.3.4 returned `base64(plain_json)` from the JSON-RPC endpoint; v1.5.1 returns `hex(gzip(json))`. The `generate_chains.py` genesis script does `base64.b64decode` on the result, which will fail with v1.5.1. This needs fixing before genesis re-generation works with the new Anvil.

- **`--state` vs `--load-state` vs `--dump-state`:** In v1.5.1, `--state` is an alias for both `--load-state` and `--dump-state`. They all use the same plain-JSON file format. The `anvil_dumpState` RPC endpoint uses a *different* format (hex-gzip-encoded).

- **The `--preserve-historical-states` flag** makes `--dump-state` include historical snapshots in the state file. This is used in the genesis compose to support historical block queries. It has no effect on the file format's field requirements.

- **Wrong path: migrating trace `index`** — there is no `index` field in `trace.trace` (the inner call trace object). The field that was missing was `index` in `trace.logs[*]` (log entries within a trace node). Don't confuse the two.
