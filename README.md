# The Three Chains Problem

A toolkit for running **multiple ZKsync OS L2 chains** against a single local L1 (Anvil).

Built on top of [local-prividium](https://github.com/matter-labs/local-prividium) and
[zksync-os-scripts](https://github.com/matter-labs/zksync-os-scripts).

## Quick Start

### Prerequisites

- Docker and Docker Compose v2+
- `curl` or `wget`
- (optional) `gh` CLI for downloading LFS files

### Two chains (pre-built, fastest)

```bash
./configure-l2s --count=2
docker compose -f docker-compose.generated.yml up -d
```

### Three or more chains

Chains 3+ require generating new L1 contract deployments. Use the Docker-based
genesis generator (no local toolchain required):

```bash
# First, generate genesis for the additional chain(s)
./scripts/generate-genesis.sh --docker --count=3

# Then configure and start
./configure-l2s --count=3
docker compose -f docker-compose.generated.yml up -d
```

## How It Works

```
configure-l2s --count=N
       │
       ├── chains 1-2: download pre-built configs from upstream
       │   (zksync-os-server/local-chains/v30.2/multi_chain/)
       │
       ├── chains 3+:  generate-genesis.sh (uses Docker or local tools)
       │   └── runs forked zksync-os-scripts/genesis/generate_chains.py
       │       ├── builds zkstack CLI
       │       ├── deploys L1 contracts (bridgehub, bytecode supplier)
       │       ├── generates chain_XXXX.yaml per chain
       │       └── dumps l1-state.json.gz (Anvil state with all contracts)
       │
       └── generate-compose.sh → docker-compose.generated.yml
```

## Chain IDs and Ports

| Chain # | Chain ID | Internal Port | External Port |
|---------|----------|---------------|---------------|
| 1       | 6565     | 3050          | 5050          |
| 2       | 6566     | 3051          | 5051          |
| 3       | 6567     | 3052          | 5052          |
| 4       | 6568     | 3053          | 5053          |
| N       | 6564+N   | 3049+N        | 5049+N        |

**L1 (Anvil):** `http://localhost:5010` (chain ID: 31337)

## Usage Examples

```bash
# Two chains (uses pre-built genesis state)
./configure-l2s --count=2

# Three chains
./configure-l2s --count=3

# Four chains, custom output file
./configure-l2s --count=4 --output=four-chains.yml

# Force regenerate all configs
./configure-l2s --count=3 --force-genesis

# Custom server image
./configure-l2s --count=2 --server-image=ghcr.io/matter-labs/zksync-os-server:v0.12.0
```

## configure-l2s Options

```
./configure-l2s --count=N [options]

Options:
  --count=N           Number of L2 chains (1-8)
  --output=FILE       Output file (default: docker-compose.generated.yml)
  --force-genesis     Regenerate configs even if they exist
  --version=VER       Protocol version (default: v30.2)
  --server-image=IMG  zksync-os-server image (default: latest)
```

## Docker Compose Commands

```bash
# Start all chains
docker compose -f docker-compose.generated.yml up -d

# View logs for all chains
docker compose -f docker-compose.generated.yml logs -f

# View logs for a specific chain
docker compose -f docker-compose.generated.yml logs -f chain-6565

# Stop all chains (keeps data volumes)
docker compose -f docker-compose.generated.yml down

# Stop and remove all data (fresh restart)
docker compose -f docker-compose.generated.yml down -v
```

## Genesis Generation for 3+ Chains

### Option A: Docker (recommended, no local tools needed)

```bash
# Generate genesis for 3 chains (6565, 6566, 6567)
./scripts/generate-genesis.sh --docker --count=3

# Or specify exact chain IDs
./scripts/generate-genesis.sh --docker --chains 6565,6566,6567,6568
```

The Docker image (~2-4 GB) installs all required tools and pre-compiles dependencies.
**First build takes 20-40 minutes.** Subsequent runs reuse the cached image.

### Option B: Local (fastest if tools already installed)

Required tools:
- Rust ≥ 1.89 (`rustup update`)
- yarn ≥ 1.22
- Foundry 1.3.5 (`foundryup --version 1.3.5`)
- cargo, cast, forge, anvil

Required environment variables:
```bash
export ERA_CONTRACTS_PATH=/path/to/era-contracts   # tag: zkos-v0.30.2
export ZKSYNC_ERA_PATH=/path/to/zksync-era         # tag: protocol-upgrade-v1.3.1
export PROTOCOL_VERSION=v30.2
```

Clone the required repos:
```bash
git clone --branch zkos-v0.30.2 https://github.com/matter-labs/era-contracts
git clone --branch protocol-upgrade-v1.3.1 https://github.com/matter-labs/zksync-era
```

Run genesis generation:
```bash
./scripts/generate-genesis.sh --count=3
```

## Genesis Generation Script (Fork)

The `genesis/generate_chains.py` script is adapted from
[`zksync-os-scripts/scripts/update_server.py`](https://github.com/matter-labs/zksync-os-scripts/blob/main/scripts/update_server.py).

**Key differences from upstream:**
- Accepts `--chain-ids` parameter instead of hardcoded `[6565, 6566]`
- Standalone Python file (no dependency on the `lib/` package from zksync-os-scripts)
- Generates only chain configs and L1 state (no VK hash updates, no factory deps)
- Assigns RPC ports sequentially: 3050, 3051, 3052, ...

The upstream `update_server.py` also handles verification key hashes and factory
dependencies for the full zksync-os-server build. For local development (where
`general.ephemeral: true` in chain configs), these are not needed.

## Directory Structure

```
the-three-chains-problem/
├── configure-l2s              # Main script: generate configs + compose file
├── scripts/
│   ├── generate-compose.sh    # Generates docker-compose.generated.yml
│   ├── generate-genesis.sh    # Runs genesis generation for N chains
│   └── download-upstream-configs.sh  # Downloads pre-built configs for chains 1-2
├── genesis/
│   ├── Dockerfile             # Self-contained genesis generator image
│   └── generate_chains.py     # Genesis generation script (fork of zksync-os-scripts)
├── configs/
│   └── v30.2/                 # Auto-populated by configure-l2s
│       ├── chain_6565.yaml    # Chain configs (downloaded or generated)
│       ├── chain_6566.yaml
│       ├── genesis.json       # zkSync OS genesis state
│       └── l1-state.json.gz   # Anvil L1 state with deployed contracts
└── docker-compose.generated.yml  # Auto-generated by configure-l2s
```

## Architecture

Each L2 chain runs as a separate `zksync-os-server` process (Docker container).
All chains share:
- A single L1 (Anvil) node with all chain contracts pre-deployed
- The same `genesis.json` (zkSync OS execution parameters)

Each chain has its own:
- Chain config YAML (`chain_XXXX.yaml`) with unique chain ID, operator keys, RPC port
- Database volume (`chain_XXXX_db`)
- L1 contract registration (deployed during genesis generation)

### L1 State

The `l1-state.json.gz` is an Anvil state snapshot containing:
- zkStack ecosystem contracts (bridgehub, governance, verifier)
- Per-chain: CTM registration, operator funding, initial deposit transactions

For chains 1-2, this state is downloaded from the upstream
[`zksync-os-server`](https://github.com/matter-labs/zksync-os-server) repository.
For chains 3+, it is generated by `generate_chains.py` using `zkstack ecosystem init`.

## Compatibility

| Component        | Version / Tag                    |
|------------------|----------------------------------|
| zksync-os-server | latest (or `v0.12.0` for pinned) |
| Protocol version | v30.2                            |
| era-contracts    | `zkos-v0.30.2`                   |
| zkstack-cli      | `protocol-upgrade-v1.3.1`        |
| Foundry          | 1.3.5                            |
| Rust             | ≥ 1.89                           |

## Troubleshooting

**Chain fails to start with "connection refused":**
The chain server takes 20-30s to initialize. Check health:
```bash
docker compose -f docker-compose.generated.yml ps
```

**L1 state download fails (LFS file):**
Install the `gh` CLI for authenticated GitHub downloads:
```bash
gh auth login
./configure-l2s --count=2
```

**Genesis generation fails with "zkstack not found":**
Ensure `ZKSYNC_ERA_PATH` points to a built zksync-era repo:
```bash
cargo build --release --bin zkstack
```

**Port conflicts:**
The default ports (5050-5057, 5010) must be free. Check with:
```bash
lsof -i :5050-5058
lsof -i :5010
```
