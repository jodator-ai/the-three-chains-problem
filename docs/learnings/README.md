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

**Total active session time: ~19h20m** across 3 days (overnight gaps excluded).

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
