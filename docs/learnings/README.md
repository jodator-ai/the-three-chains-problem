# LLM Agent Collaboration Retrospective

## Project purpose

[ZKsync OS](https://github.com/matter-labs/zksync-os-server) is Matter Labs' next-generation ZK rollup stack. [Prividium](https://github.com/matter-labs/local-prividium) is their enterprise product built on top of it — a full self-contained stack per tenant (sequencer, postgres, keycloak, API, admin/user panels, block explorer).

The upstream tooling supports running **one or two pre-configured chains** locally out of the box. There is no supported path for spinning up N independent instances with a single command.

**Why this was needed:** Testing multi-tenant or multi-chain scenarios locally requires being able to run 3, 5, or 10 independent Prividium instances (or bare L2 chains) against a shared local L1. The upstream repos assume a fixed single-chain or two-chain setup and hardcode chain IDs throughout.

This project provides:
- `configure-l2s.sh --count=N` — generate docker-compose for N bare ZKsync OS L2 chains
- `configure-prividiums.sh --count=N` — generate docker-compose for N full Prividium stacks
- A Docker-based genesis generator for chains beyond the pre-built limit, built on a minimal fork of `matter-labs/zksync-os-scripts`

The key technical challenge was that chains beyond the pre-configured limit require deploying L1 contracts via `zkstack` and dumping the resulting Anvil state — a process that normally takes 10+ minutes of compilation and is tightly coupled to the upstream server repo layout.

## Repos

| Repo | Description |
|------|-------------|
| [jodator-ai/the-three-chains-problem](https://github.com/jodator-ai/the-three-chains-problem) | Main project — configure-l2s / configure-prividiums scripts |
| [jodator-ai/zksync-os-scripts](https://github.com/jodator-ai/zksync-os-scripts) (branch: `multi-chain-n-support`) | Fork used as genesis engine |
| [matter-labs/zksync-os-scripts](https://github.com/matter-labs/zksync-os-scripts) | Upstream of the fork |
| [matter-labs/zksync-os-server](https://github.com/matter-labs/zksync-os-server) | Source of pre-built chain configs and l1-state |
| [matter-labs/local-prividium](https://github.com/matter-labs/local-prividium) | Prividium docker-compose reference |

---

This document reflects on using Claude Code (claude-sonnet-4-6) as an implementation agent across multiple sessions to build this project. It is written from the agent's perspective — what went well, what was unclear, what caused rework, and what would have made the work go faster.

---

## Project arc

The project started as a multi-L2 ZKsync OS POC (`configure-l2s.sh`) and expanded over two multi-hour sessions to include:
- Docker-based genesis generation for chains beyond the pre-built limit
- Full Prividium stacks (`configure-prividiums.sh`)
- A minimal fork of `matter-labs/zksync-os-scripts` used as the genesis engine

Total: **53 commits**, of which **18 (~34%) were fixes** — almost all in the genesis generator subsystem.

---

## What went well

### Codebase exploration and orientation
Reading the upstream repos (`zksync-os-server`, `zksync-os-scripts`, `local-prividium`) to understand conventions, config formats, and tool expectations worked well without human guidance. The agent was able to infer design intent from code and match it.

### Docker-compose generation
The composability pattern (one file per service, merged with `-f`) and the port-stride layout for N instances were implemented correctly on the first attempt without iteration.

### README and documentation alignment
Catching discrepancies between the README and the actual code (wrong Foundry version, wrong chain range) was a clean task with a clear signal.

### Fork identification and setup
Identifying that `matter-labs/zksync-os-scripts` was the right upstream to fork, understanding why the existing `generate_chains.py` existed, and planning the minimal diff were done well. The fork was created and initial implementation was completed without blocking on the user.

### Memory and continuity across sessions
The memory system preserved enough context that the second session resumed without needing the user to re-explain the project. The auto-generated conversation summary at context limits also helped.

---

## What required user input or caused rework

### 1. Fork diff size — two implementations, one thrown away

**What happened:** The first fork implementation wrapped build sections with extra indentation throughout (`if skip_build:` wrapping large blocks), producing a 248+/125- diff. The user flagged this as "many things — can the changes be less intrusive?" The implementation was rewritten to be 96+/19- (then refined further).

**Root cause:** The agent optimized for correctness over diff minimality without being told that minimizing the upstream diff was a priority. The instruction "implement the fork" didn't signal that the fork was intended to be upstreamable / PR-worthy.

**What would have helped:** Stating the goal upfront — e.g. "the fork should be a minimal upstream-ready PR, not a local patch" — would have produced the right result on the first attempt.

---

### 2. ~15 fix commits in the genesis Dockerfile / Python script

The genesis generator required many iteration cycles because it runs inside Docker and there is no fast feedback loop — each test requires a full Docker build followed by a multi-minute runtime. The fixes included:

- `forge`/`cast` vs `anvil` coming from different Foundry distributions (foundry-zksync vs standard foundry)
- `era-contracts/.git` needing to be preserved for `zkstack submodule update`
- `default-configs` directory needing to exist before `zkstack ctm set-ctm-contracts`
- `--ignore-prerequisites` missing from zkstack commands
- Python f-string backslash syntax error (Python < 3.12 incompatibility)
- Multi-line shell commands needing newline collapsing
- YAML-parsed addresses being integers, not hex strings
- `PROTOCOL_VERSION` containing a minor version (`v30.2`) that needed stripping to just `30` for `--execution-version`
- `zkstack` binary path in SKIP_BUILD mode pointing to a pre-built binary rather than the compiled target

**Root cause:** The genesis generation workflow requires knowledge of undocumented runtime behavior of `zkstack`, `foundry-zksync`, and `era-contracts` that is only observable by running the system. The agent had no way to test Docker builds and had to reason from documentation and code, which misses real behavior.

**What would have helped:**
- A working reference run log showing what a successful genesis generation looks like
- Knowing upfront which Foundry distribution provides which binaries (foundry-zksync provides `forge`/`cast` but not `anvil`; standard foundry provides `anvil`)
- The `--ignore-prerequisites` flag requirement for zkstack in a non-standard environment
- A list of known quirks or past gotchas in the zkstack / era-contracts setup

---

### 3. `--start` flag added then immediately reverted

**What happened:** The user asked for "1 command after checkout" for 3 prividiums. The agent interpreted this as meaning the configure + start steps should be combined into one flag (`--start`). The user clarified they were fine with two separate commands and just wanted the configure step to be single-command (which it already was).

**Root cause:** Ambiguous requirement. "1 command" could mean combining all steps or just having a clean single entrypoint for configuration.

**What would have helped:** "The configure script is already one command; the separate `./start.sh` for Docker is fine" would have avoided the extra commit/revert cycle.

---

### 4. SKIP_BUILD / SKIP_DEPOSIT_TX — removed, then re-added

**What happened:** In response to the "less intrusive fork" feedback, `SKIP_BUILD` and `SKIP_DEPOSIT_TX` were removed from the fork as they seemed Docker-specific. Then it became clear they are actually required for Docker (no Rust/cargo in runtime image, `zksync_os_generate_deposit` package not available) and had to be re-added — but now more carefully, without re-indenting block content.

**Root cause:** The agent didn't fully trace the Docker runtime environment before deciding what was "required" vs "optional" in the fork. The analysis of what fails in Docker was done reactively after the flag was removed.

**What would have helped:** Knowing upfront that the runtime Docker image has no Rust/cargo installed would have made it clear that `SKIP_BUILD` is mandatory, not an optimization.

---

## Structural observations on LLM-agent development

### Iterative fix loops are expensive without a fast feedback loop
The genesis generator accumulated 15 fix commits because each failure could only be discovered by running a Docker build (slow) followed by a Docker run (slow). The agent cannot run Docker, so it was reasoning blind. In contrast, tasks with fast feedback (shell script logic, Python syntax, README edits) completed in one pass.

**Implication:** For tasks where the agent cannot execute and observe, expect more iteration. Either provide a human-in-the-loop to run tests and paste output, or structure the work so the agent can validate locally before the slow path.

### Upstream knowledge gaps are hard to fill from code alone
Several of the genesis fixes required knowing runtime behavior of third-party tools (`zkstack`, `foundry-zksync`, `era-contracts` build system) that isn't documented. The agent read the source code but missed behavioral quirks that only appear at runtime.

**Implication:** For tasks that integrate multiple complex upstream tools, a reference run log or a "known gotchas" doc is worth more than any amount of source reading.

### Diff minimality needs to be stated as a constraint, not inferred
The agent defaults to "make it work correctly." If "make it work with minimal diff vs upstream" is also a requirement, it needs to be explicit. These are sometimes in tension and the agent will resolve ambiguity toward correctness.

### Cross-session continuity works but memory is coarse
Memory files preserve high-level decisions but not the reasoning chains behind them. When a session was resumed after context compression, some nuance (e.g., why `SKIP_BUILD` was removed, what the exact committed state of the fork was) had to be re-derived from `git log` and file reads rather than recalled. More granular memory (e.g., "we removed SKIP_BUILD because X, but it is still needed because Y") would have reduced the re-derivation time.

---

## What would have made this go faster

In order of impact:

1. **A reference genesis run log** — showing what a successful `update_server.py` invocation produces, which tool is called at each step, what output is expected. This alone would have cut the 15 fix commits in half.

2. **Explicit diff-minimality constraint** — "the fork should look like a PR to upstream, not a local patch" stated upfront.

3. **Docker runtime environment description** — "the runtime image has no Rust/cargo; build artifacts are pre-baked" clarifies what SKIP_BUILD must cover without needing to trace the Dockerfile.

4. **Clearer scope on the 1-command goal** — whether "1 command" meant generate-only or generate-and-start.

5. **Known zkstack quirks** — `--ignore-prerequisites` requirement, `era-contracts/.git` retention, `default-configs` directory prerequisite. These are not in documentation.

---

## Summary

The collaboration worked well for structured tasks (compose generation, script logic, README alignment, fork strategy) and poorly for tasks requiring runtime feedback (Docker + zkstack integration). The fix/iterate loop for genesis was the dominant cost — not any single decision, but the accumulation of small undocumentable runtime behaviors in a system the agent couldn't execute.

The fork implementation is an example where a single upfront constraint ("minimal upstream-ready diff") would have saved a full re-implementation cycle. Most of the other rework came from incomplete environmental knowledge that a brief description or a run log would have covered.
