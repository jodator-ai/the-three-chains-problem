# The Three Chains Problem

A toolkit for running **multiple ZKsync OS L2 chains** (or full **Prividium** stacks) against a
single local L1 (Anvil) — all from a single command.

Built on top of [local-prividium](https://github.com/matter-labs/local-prividium) and
[zksync-os-scripts](https://github.com/matter-labs/zksync-os-scripts).

## Commands

| Command | Description |
|---|---|
| `./configure-l2s.sh --count=N` | N bare ZKsync OS L2 sequencers sharing one L1 |
| `./configure-prividiums.sh --count=N` | N full Prividium stacks sharing one L1 |

Both commands generate composable docker-compose files — one file per service instance, one
shared L1 file — that you merge with `docker compose -f … -f … up`.

---

## configure-l2s.sh — Multiple L2 Chains

### Quick Start

```bash
# Generate compose files for 4 chains
./configure-l2s.sh --count=4

# Start (use the printed docker compose command, or build it yourself):
docker compose \
  -f generated/docker-compose.l1.yml \
  -f generated/docker-compose.zksyncos-6565.yml \
  -f generated/docker-compose.zksyncos-6566.yml \
  -f generated/docker-compose.zksyncos-6567.yml \
  -f generated/docker-compose.zksyncos-6568.yml \
  up -d
```

### Chain IDs and Ports

| Chain # | Chain ID | RPC (host) |
|---------|----------|-----------|
| 1       | 6565     | :5050     |
| 2       | 6566     | :5051     |
| 3       | 6567     | :5052     |
| 4       | 6568     | :5053     |
| N       | 6564+N   | :5049+N   |

**L1 (Anvil):** `http://localhost:5010` (chain ID: 31337)

Chains 1–4 are pre-configured (keys embedded, L1 state in repo). Chains 5–8 require genesis
generation first — see [Genesis Generation](#genesis-generation-for-5-chains).

### Options

```
./configure-l2s.sh --count=N [options]

  --count=N           Number of L2 chains (1–4 pre-configured; 5–8 require genesis)
  --output-dir=DIR    Output directory (default: ./generated)
  --force-genesis     Re-extract genesis.json from image
  --version=VER       Protocol version (default: v30.2)
  --server-image=IMG  zksync-os-server image (default: latest)
```

### How It Works

```
configure-l2s.sh --count=N
       │
       ├── scripts/generate-chain-configs.sh
       │   └── writes configs/v30.2/chain_XXXX.yaml (embedded operator keys)
       │
       ├── extracts genesis.json from zksync-os-server image
       │
       └── scripts/generate-compose.sh
           ├── generated/docker-compose.l1.yml
           └── generated/docker-compose.zksyncos-XXXX.yml  (one per chain)
```

### Docker Compose Commands

```bash
# One-chain example — adapt -f list for your count
COMPOSE="docker compose -f generated/docker-compose.l1.yml -f generated/docker-compose.zksyncos-6565.yml"

$COMPOSE up -d        # start
$COMPOSE logs -f      # stream logs
$COMPOSE ps           # check health
$COMPOSE down         # stop (keep volumes)
$COMPOSE down -v      # stop + wipe volumes
```

---

## configure-prividiums.sh — Multiple Prividium Instances

Each instance is a complete [Prividium](https://github.com/matter-labs/local-prividium) stack:
zksyncos sequencer, postgres, keycloak, prividium-api, admin panel, user panel, and block explorer.
All instances share a single L1 (Anvil).

> **Requires quay.io access** for enterprise Prividium images.
> Run `docker login quay.io` first.

### Quick Start

```bash
# Generate compose files for 2 Prividium instances
./configure-prividiums.sh --count=2

# Start:
docker compose \
  -f generated-prividiums/docker-compose.l1.yml \
  -f generated-prividiums/docker-compose.prividium-6565.yml \
  -f generated-prividiums/docker-compose.prividium-6566.yml \
  up -d
```

### Port Layout (stride: 200 per instance)

| Service        | Instance 1 | Instance 2 | Instance N |
|----------------|-----------|-----------|------------|
| Admin Panel    | 3000      | 3200      | 3000+(N-1)×200 |
| User Panel     | 3001      | 3201      | 3001+(N-1)×200 |
| Prividium API  | 8000      | 8200      | 8000+(N-1)×200 |
| Block Explorer | 3010      | 3210      | 3010+(N-1)×200 |
| zkSync RPC     | 5050      | 5250      | 5050+(N-1)×200 |
| Keycloak       | 5080      | 5280      | 5080+(N-1)×200 |
| Postgres       | 5432      | 5632      | 5432+(N-1)×200 |

**L1 (Anvil):** `http://localhost:5010` (shared by all instances)

Instance 1 uses the same default ports as upstream
[local-prividium](https://github.com/matter-labs/local-prividium).

### Options

```
./configure-prividiums.sh --count=N [options]

  --count=N                Number of Prividium instances (1–4)
  --output-dir=DIR         Output directory (default: ./generated-prividiums)
  --force-refresh          Re-download keycloak realm + re-extract genesis.json
  --version=VER            Protocol version (default: v30.2)
  --server-image=IMG       zksync-os-server image (default: latest)
  --prividium-version=V    Prividium image tag (default: v1.153.1)
```

### How It Works

```
configure-prividiums.sh --count=N
       │
       ├── scripts/generate-chain-configs.sh
       │   └── writes configs/v30.2/chain_XXXX.yaml (embedded operator keys)
       │
       ├── extracts genesis.json from zksync-os-server image
       │
       ├── downloads configs/v30.2/keycloak-realm.json from local-prividium
       │
       └── scripts/generate-prividium-compose.sh
           ├── generated-prividiums/docker-compose.l1.yml
           └── generated-prividiums/docker-compose.prividium-XXXX.yml  (one per instance)
               └── services: postgres, keycloak, zksyncos, prividium-api,
                              admin-panel, user-panel, block-explorer stack
```

---

## Genesis Generation for 5+ Chains

Chains 1–4 have pre-built genesis state (L1 contracts pre-deployed in `configs/v30.2/l1-state.json.gz`).
Chains 5–8 require deploying new L1 contracts:

### Option A: Docker (recommended, no local tools needed)

```bash
# Generate genesis for 5 chains (~30min first run, cached after)
./scripts/generate-genesis.sh --docker --count=5

# Then configure as usual
./configure-l2s.sh --count=5
```

### Option B: Local (fastest if tools already installed)

Required tools: Rust ≥ 1.89, yarn ≥ 1.22, Foundry 1.3.5

```bash
export ERA_CONTRACTS_PATH=/path/to/era-contracts   # tag: zkos-v0.30.2
export ZKSYNC_ERA_PATH=/path/to/zksync-era         # tag: protocol-upgrade-v1.3.1
export PROTOCOL_VERSION=v30.2

./scripts/generate-genesis.sh --count=5
./configure-l2s.sh --count=5
```

---

## Repository Structure

```
the-three-chains-problem/
├── configure-l2s.sh              # Generate N bare L2 chains
├── configure-prividiums.sh       # Generate N full Prividium stacks
├── scripts/
│   ├── generate-chain-configs.sh # Writes chain_XXXX.yaml (embedded keys)
│   ├── generate-compose.sh       # Generates zksyncos compose files
│   ├── generate-prividium-compose.sh  # Generates prividium compose files
│   └── generate-genesis.sh       # Genesis generation for chains 5+
├── genesis/
│   ├── Dockerfile                # Self-contained genesis generator image
│   └── generate_chains.py        # Genesis generation script
├── configs/
│   └── v30.2/
│       └── l1-state.json.gz      # Anvil L1 state (chains 1–4 pre-deployed)
└── example/                      # Example output for 4 chains
    ├── docker-compose.l1.yml
    ├── docker-compose.zksyncos-6565.yml … 6568.yml
    └── configs/
        ├── chain_6565.yaml … 6568.yaml
        └── genesis.json
```

Generated files (gitignored):
- `generated/` — output of `configure-l2s.sh`
- `generated-prividiums/` — output of `configure-prividiums.sh`
- `configs/v30.2/chain_*.yaml`, `genesis.json`, `keycloak-realm.json` — re-generated on each run

## Compatibility

| Component        | Version / Tag                    |
|------------------|----------------------------------|
| zksync-os-server | latest (or `v0.12.0` for pinned) |
| Protocol version | v30.2                            |
| Prividium images | v1.153.1                         |
| era-contracts    | `zkos-v0.30.2`                   |
| zkstack-cli      | `protocol-upgrade-v1.3.1`        |
| Foundry          | 1.3.5                            |
| Rust             | ≥ 1.89                           |

## Troubleshooting

**Chain fails to start / connection refused:**
The server takes 20–30s to initialize. Check health:
```bash
docker compose -f generated/docker-compose.l1.yml ... ps
```

**Prividium image pull fails:**
Login to quay.io:
```bash
docker login quay.io
```

**Port conflicts:**
Check for conflicts with `lsof -i :5010` and `lsof -i :5050-5057`.
Use `--output-dir` to run multiple isolated setups side by side.

**Genesis generation fails with "zkstack not found":**
```bash
cargo build --release --bin zkstack
```
