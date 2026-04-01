# LLM Agent Collaboration Retrospective

*Using Claude Code (claude-sonnet-4-6) as implementation agent across multiple sessions. Written from the agent's perspective — what went well, what caused rework, what would have made it faster.*

## Project purpose

The upstream Matter Labs tooling supports **1–2 pre-configured chains** locally out of the box, with chain IDs hardcoded throughout. There is no supported path for spinning up N independent instances with a single command.

This project provides:
- `configure-l2s.sh --count=N` — docker-compose for N bare ZKsync OS L2 chains
- `configure-prividiums.sh --count=N` — docker-compose for N full Prividium stacks
- A Docker-based genesis generator for chains beyond the pre-built limit, built on a minimal fork of `matter-labs/zksync-os-scripts`

The key technical challenge: chains beyond the pre-built limit require deploying L1 contracts via `zkstack` and dumping the resulting Anvil state — tightly coupled to the upstream server repo layout and requiring 10+ minutes of compilation.

## Repos

| Repo | Description |
|------|-------------|
| [jodator-ai/the-three-chains-problem](https://github.com/jodator-ai/the-three-chains-problem) | Main project — configure-l2s / configure-prividiums scripts |
| [jodator-ai/zksync-os-scripts](https://github.com/jodator-ai/zksync-os-scripts) (branch: `multi-chain-n-support`) | Fork used as genesis engine |
| [matter-labs/zksync-os-scripts](https://github.com/matter-labs/zksync-os-scripts) | Upstream of the fork |
| [matter-labs/zksync-os-server](https://github.com/matter-labs/zksync-os-server) | Source of pre-built chain configs and l1-state |
| [matter-labs/local-prividium](https://github.com/matter-labs/local-prividium) | Prividium docker-compose reference |

---

## Project arc

Started as a multi-L2 POC (`configure-l2s.sh`) and expanded over three sessions to include Docker-based genesis generation, full Prividium stacks (`configure-prividiums.sh`), and a minimal fork of `matter-labs/zksync-os-scripts` as the genesis engine.

**53 commits total, 18 (~34%) were fixes** — almost all in the genesis generator subsystem.

---

## Time analysis

*Inferred from git commit timestamps. Short gaps between commits = agent working; long gaps = user testing/building.*

### Sessions

| Session | Date | Span | Wall time |
|---------|------|------|-----------|
| 1 | Mar 17–18 | 17:46 → (overnight) → 10:00–17:37 | ~7h40m active |
| 2 | Mar 19 | 09:11–18:29 | ~9h20m active |
| 3 | Mar 20 | 11:48–14:07 | ~2h20m active |
| 4 | Mar 2026 | Anvil v1.5.1 upgrade + state format fix | ~1h active |
| 5 | Mar 31 | Chain 6567 rich account 0 ETH diagnosis + fix | ~3h active |
| 6 | Apr 1 | Blocks stuck at "sealed" — fake prover diagnosis + fix | ~1h active |

**Total active session time: ~25h** across 6 sessions.

### Session 5 — Chain 6567 rich account fix

The pre-built `l1-state.json.gz` was missing an L1→L2 deposit for chain 6567, and additionally
the diamond proxy's priority queue head was at position 6 (from genesis init txs) while zksyncos
always starts expecting position 0 — causing a panic at `model.rs:87`. Fix required:

1. Understanding the priority queue head/tail mechanics (see
   [`priority-queue-deposit-fix.md`](./priority-queue-deposit-fix.md))
2. Surgical JSON manipulation of the L1 state to remove the stale `NewPriorityRequest` log
3. Resetting diamond proxy storage slots 52 and 54 via `anvil_setStorageAt`
4. Re-submitting the deposit as txId=0, mining 5 confirmation blocks
5. Adding `patch_deposits.py` to automate this for future genesis runs

**~2h was diagnostic** (confirming the stale-volume hypothesis was wrong, tracing the panic to the
priority queue mismatch, finding the storage slots). **~1h was implementation** (patch_deposits.py,
entrypoint.sh update, syncing to all 4 examples).

### Where the time went

**Agent working independently: ~12h** — sessions 1 and 3 were mostly agent-driven (3–30 min between commits). Session 2 had ~4h of agent stretches.

**User-side (testing, Docker builds, feedback): ~7h20m** — the dominant cost was Docker build cycles during genesis debugging. Each cycle: `docker build` (~25 min), observe failure, paste output back. Commit gaps on Mar 19: 09:59→12:17 (2h18m), 13:13→14:27 (74m), 15:36→17:06 (90m), 17:06→18:00 (54m) — all Docker build/test cycles (~5h15m). The remaining ~2h was review, stack testing, and directional feedback.

**Rework from unclear requirements: ~2h (agent) + ~30m (clarification)**
- Fork implemented twice (248→96 line diff): ~1h agent + ~15m back-and-forth
- `SKIP_BUILD`/`SKIP_DEPOSIT_TX` removed then re-added: ~30m agent
- `--start` flag added then reverted: ~20m agent + ~10m clarification

### Could this have been faster?

The Docker build loop was the main bottleneck and partly structural — 15 fix commits × (write fix ~5m + docker build ~25m + observe failure ~5m) = the bulk of session 2. Even if the agent could run Docker locally it would have been faster but not eliminated; the root cause was missing knowledge of undocumented runtime behavior, not missing execution ability.

**~2h of rework was avoidable** with two upfront clarifications: "the fork should be a minimal upstream-ready PR" and "the runtime Docker image has no Rust/cargo." With those plus a reference genesis run log, session 2 could plausibly have been ~5h instead of ~9h20m.

---

## What went well

**Codebase exploration** — reading `zksync-os-server`, `zksync-os-scripts`, and `local-prividium` to infer conventions, config formats, and tool expectations worked without human guidance.

**Docker-compose generation** — the composability pattern (one file per service, merged with `-f`) and port-stride layout for N instances were correct on the first attempt.

**README and doc alignment** — catching discrepancies (wrong Foundry version, wrong chain range) was a clean task with a clear signal.

**Fork identification and setup** — identifying `matter-labs/zksync-os-scripts` as the right upstream, understanding why `generate_chains.py` existed, and planning the minimal diff were done without blocking on the user.

**Cross-session continuity** — the memory system plus auto-generated conversation summaries preserved enough context that sessions resumed without re-explaining the project.

---

## What required user input or caused rework

### 1. Fork diff size — implemented twice

**What happened:** First implementation produced a 248+/125- diff (large block re-indentation for `if skip_build:` guards). User flagged "many things — can it be less intrusive?" Rewritten to 96+/19- then refined further.

**Root cause:** Agent optimized for correctness, not diff minimality. "Implement the fork" didn't signal it should be upstreamable / PR-worthy.

**What would have helped:** "The fork should be a minimal upstream-ready PR, not a local patch."

### 2. ~15 fix commits in the genesis Dockerfile / Python script

Each fix required a full Docker build (no fast feedback). Failures included:
- `forge`/`cast` vs `anvil` from different Foundry distributions (foundry-zksync vs standard foundry)
- `era-contracts/.git` must be preserved for `zkstack submodule update`
- `default-configs` directory must exist before `zkstack ctm set-ctm-contracts`
- `--ignore-prerequisites` missing from zkstack commands
- Python f-string backslash syntax error (Python < 3.12)
- Multi-line shell commands needing newline collapsing
- YAML-parsed addresses being integers, not hex strings
- `PROTOCOL_VERSION` (`v30.2`) needing to strip to `30` for `--execution-version`
- `zkstack` binary path wrong in SKIP_BUILD mode

**Root cause:** Undocumented runtime behavior of `zkstack`, `foundry-zksync`, and `era-contracts` — only observable by running the system.

**What would have helped:** A reference genesis run log; which Foundry distribution provides which binaries; the `--ignore-prerequisites` requirement; a known-quirks list for zkstack/era-contracts.

### 3. `--start` flag added then immediately reverted

**What happened:** User asked for "1 command after checkout." Agent added a `--start` flag combining generate + start. User clarified the two-step flow (configure → `./start.sh`) was fine; they just wanted generate to be single-command, which it already was.

**Root cause:** "1 command" was ambiguous between generate-only and generate-and-start.

**What would have helped:** "The configure script is already 1 command; separate `./start.sh` is fine."

### 4. SKIP_BUILD / SKIP_DEPOSIT_TX — removed, then re-added

**What happened:** In response to "less intrusive fork" feedback, these flags were removed as seeming Docker-specific. Then analysis showed they are mandatory for Docker (no Rust/cargo in runtime image; `zksync_os_generate_deposit` package unavailable) and had to be re-added, this time without re-indenting block content.

**Root cause:** Agent didn't fully trace the Docker runtime environment before deciding what was "required" vs "optional." Analysis was reactive.

**What would have helped:** "The runtime Docker image has no Rust/cargo — all build artifacts are pre-baked."

---

## Structural observations

**Iterative fix loops are expensive without a fast feedback loop.** The genesis generator accumulated 15 fix commits because failures were only discoverable via slow Docker builds. Tasks with fast feedback (shell scripts, Python syntax, README edits) completed in one pass. For tasks where the agent cannot execute and observe, expect more iteration — either provide a human-in-the-loop to run and paste output, or structure work so the agent can validate locally first.

**Upstream knowledge gaps can't be filled from code alone.** Runtime quirks of third-party tools (`zkstack`, `foundry-zksync`, `era-contracts`) aren't in documentation and only appear at runtime. A reference run log or known-gotchas doc is worth more than any amount of source reading.

**Diff minimality must be stated as a constraint.** The agent defaults to "make it work correctly." If "minimal diff vs upstream" is also a requirement, it needs to be explicit — these goals are sometimes in tension and the agent resolves ambiguity toward correctness.

**Cross-session memory is coarse.** Memory files preserve high-level decisions but not reasoning chains. When resuming after context compression, nuance (e.g., why `SKIP_BUILD` was removed, exact committed state of the fork) had to be re-derived from `git log` rather than recalled. More granular memory — capturing not just *what* was decided but *why* — would reduce re-derivation time.

---

## What would have made this go faster

1. **A reference genesis run log** — successful `update_server.py` output showing each tool call and expected result. Would have cut the 15 fix commits roughly in half.
2. **"The fork should be a minimal upstream-ready PR"** — stated upfront, saves a full re-implementation.
3. **"The runtime image has no Rust/cargo"** — one sentence that clarifies SKIP_BUILD is mandatory, not optional.
4. **"The configure script is 1 command; `./start.sh` separately is fine"** — saves the `--start` flag cycle.
5. **Known zkstack quirks** — `--ignore-prerequisites`, `era-contracts/.git` retention, `default-configs` prereq. None are documented.

---

## Session 5 learnings — ZKsync OS priority queue mechanics

These were learned during the chain 6567 rich account fix and are not obvious from reading the code.

### The priority queue head/tail invariant

Every ZKsync OS chain has a diamond proxy on L1 with a priority queue. The queue is used for
L1→L2 deposits and system upgrades. **zksyncos always starts fresh with `next_l1_priority_id=0`
and asserts the first event it finds has txId=0.** This means the L1 state snapshot must either:

- Have head=0 (no init txs were processed before the snapshot), OR
- Have the event logs for txIds 0..(head-1) still present in the Anvil history

In practice, `zkstack ecosystem init` sends 6 initialization priority txs per chain. If the state
is dumped after L2 batches execute those txs (advancing head to 6), the event logs are gone and
zksyncos panics.

**Fix:** Reset head and tail to 0 via `anvil_setStorageAt`, then re-submit the deposit as txId=0.

### anvil_dumpState drops historical_states

`anvil_dumpState` RPC does not include `historical_states` in the returned blob. Always:
1. Load original state: `original = json.load(gzip.open(state_file))`
2. Extract: `historical = original.get("historical_states")`
3. After patching and dumping new state: `new_state["historical_states"] = historical`

Without this, historical block queries on the L1 will return empty results.

### l1-state.json.gz is shared across prividium examples

`prividium-1`, `prividium-2`, and `prividium-3` all use the **same `l1-state.json.gz`**. All 3
chains (6565, 6566, 6567) are pre-deployed and funded on L1 in that single file. The examples
differ only in which L2 containers they start. Patching the state requires syncing 4 files:
`configs/v30.2/l1-state.json.gz` and all three `examples/prividium-*/dev/l1/l1-state.json.gz`.

---

## Session 6 learnings — fake prover required for batch execution

### Blocks stuck at "sealed" — root cause

zksyncos seals blocks into batches and then waits for an **FRI proof** before committing the
batch to L1. Without a proof, the L1 sender never commits, so blocks stay sealed forever and
L2 transactions are never finalised. This is **not** an operator funding issue — operators at
100 ETH still won't fix it.

The full pipeline is: `sealed → FRI proof → SNARK proof → commit L1 tx → prove L1 tx → execute L1 tx`

### Fix: enable fake provers in the chain config

zksyncos has a built-in fake prover pool for local development. It is disabled by default.
Enable it by adding to `chain_XXXX.yaml`:

```yaml
prover_api:
  fake_fri_provers:
    enabled: true       # 5 workers, 2s compute time per batch
  fake_snark_provers:
    enabled: true       # runs immediately after FRI proof
```

With this config, batches go from sealed → fully executed on L1 in ~30 seconds. No external
prover service is required.

### Diagnosing the stuck-at-sealed symptom

```bash
# Look for the proof-waiting signal (no error — just silence after this line):
docker logs <zksyncos-container> 2>&1 | grep "FRI proving"
# → "Received batch for FRI proving: N" followed by nothing = missing fake prover

# After enabling fake provers, expected sequence:
# "fake prover submitted proof"  (after ~5s)
# "Received batch after FRI proving: N"
# "sent to L1, waiting for inclusion" (commit)
# "sent to L1, waiting for inclusion" (prove)
# "sent to L1, waiting for inclusion" (execute)
# "▶▶▶ Batch has been fully processed"
```

### Available config knobs (from `zksync-os-server config help prover_api`)

| Key | Default | Notes |
|-----|---------|-------|
| `prover_api.fake_fri_provers.enabled` | false | Enable fake FRI pool |
| `prover_api.fake_fri_provers.workers` | 5 | Parallel fake FRI workers |
| `prover_api.fake_fri_provers.compute_time` | 2s | Simulated proof time |
| `prover_api.fake_snark_provers.enabled` | false | Enable fake SNARK pool |

Always run `zksync-os-server config help <section>` to enumerate available options for a
given config section — the built-in help is the authoritative source.

---

### patch_deposits.py is the canonical deposit fix tool

`genesis/patch_deposits.py` automates the full fix: starts Anvil with existing state, impersonates
the rich account, calls `requestL2TransactionDirect` on each chain's bridgehub, dumps patched
state, merges `historical_states` back. It runs automatically as part of Docker genesis
(`entrypoint.sh` calls it after `update_server.py`) and is called by `generate_chains.py` for
the local genesis path.
