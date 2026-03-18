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

Both commands generate **composable docker-compose files** — one file per service instance plus a
shared L1 file — merged with `docker compose -f … -f … up`.

---

## configure-l2s.sh — Multiple L2 Chains

### Settlement Modes

| Mode | Version | How chains settle | pubdata |
|---|---|---|---|
| default | v30.2 | L2 → L1 (Anvil) | `Blobs` |
| default | v31.0 | L2 → L1 (Anvil) | `Blobs` |
| `--gateway` | v31.0 | L2 → gateway (506) → L1 | `RelayedL2Calldata` |

Gateway mode mirrors production ZKsync topology: a gateway chain aggregates proofs from multiple
L2 chains and posts them to L1, reducing L1 costs. It was introduced in protocol v31.0.

### Quick Start

```bash
# 4 chains, v30.2, settle to L1 (pre-configured, fastest)
./configure-l2s.sh --count=4

# 2 chains + gateway, v31.0 (downloads ~24 MB of upstream assets on first run)
./configure-l2s.sh --count=2 --version=v31.0 --gateway

# Then use the printed docker compose command, e.g.:
docker compose \
  -f out/docker-compose.l1.yml \
  -f out/docker-compose.6565.yml \
  -f out/docker-compose.6566.yml \
  up -d
```

### Chain IDs and Ports

| Service | Chain ID | RPC (host) | Notes |
|---------|----------|-----------|-------|
| Gateway | 506 | :5049 | gateway mode only; settles to L1 |
| Chain 1 | 6565 | :5050 | |
| Chain 2 | 6566 | :5051 | |
| Chain 3 | 6567 | :5052 | |
| Chain 4 | 6568 | :5053 | |
| Chain N | 6564+N | :5049+N | |
| L1 | 31337 | :5010 | Anvil, shared by all |

### Options

```
./configure-l2s.sh --count=N [options]

  --count=N           Number of L2 chains
                        v30.2: chains 1–4 pre-configured; 5–8 require genesis generation
                        v31.0: chains 1–2 pre-configured; 3–8 require genesis generation
  --version=VER       Protocol version: v30.2 (default) | v31.0
  --gateway           Enable gateway mode (v31.0 only)
  --output=DIR        Output directory, wiped on each run (default: ./out)
  --force-genesis     Re-extract/re-download genesis assets
  --server-image=IMG  zksync-os-server image (default: latest)
```

### How It Works

```
configure-l2s.sh --count=N [--version=v31.0] [--gateway] [--output=DIR]
       │
       │  Wipes and recreates --output (default: ./out) then writes everything there:
       │
       ├── dev/
       │   ├── l1/
       │   │   ├── l1-state.json.gz    — copied from configs/v30.2/ (or downloaded for v31.0)
       │   │   ├── genesis.json        — extracted from image (v30.2) or downloaded (v31.0)
       │   │   └── gateway-db.tar.gz   — pre-seeded gateway state (gateway mode only)
       │   ├── XXXX/
       │   │   └── chain_XXXX.yaml     — per-chain config (bridgehub, keys, pubdata mode)
       │   └── 506/
       │       └── chain_506.yaml      — gateway chain config (gateway mode only)
       ├── docker-compose.l1.yml
       ├── docker-compose.506.yml          (gateway mode only)
       └── docker-compose.XXXX.yml         (one per chain)
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
./configure-prividiums.sh --count=3

# Each top-level compose file pulls in its full stack via include:
docker compose \
  -f out/docker-compose.6565.yml \
  -f out/docker-compose.6566.yml \
  -f out/docker-compose.6567.yml \
  up -d

# Or use the generated helper:
cd out && ./start.sh
```

### Output Layout

```
out/
├── docker-compose.l1.yml           # Shared Anvil L1 + postgres
├── docker-compose.<id>.deps.yml    # zksyncos, keycloak, block-explorer (per instance)
├── docker-compose.<id>.yml         # prividium-api, admin panel, user panel (per instance)
├── start.sh                        # Thin wrapper: ./start.sh [up -d | down | logs -f]
└── dev/
    ├── l1/
    │   ├── l1-state.json.gz
    │   └── genesis.json
    ├── prividium-1/
    │   ├── zksyncos/
    │   │   └── chain_6565.yaml
    │   ├── keycloak/
    │   │   └── realm-export.json   # per-instance, ports match this chain only
    │   └── block-explorer/
    │       └── block-explorer-config.js
    ├── prividium-2/
    │   ├── zksyncos/chain_6566.yaml
    │   ├── keycloak/realm-export.json
    │   └── block-explorer/block-explorer-config.js
    └── prividium-N/ …
```

### Port Layout (stride: 200 per instance)

| Service | Instance 1 | Instance 2 | Formula |
|---------|-----------|-----------|---------|
| Admin Panel | 3000 | 3200 | 3000+(N-1)×200 |
| User Panel | 3001 | 3201 | 3001+(N-1)×200 |
| Prividium API | 8000 | 8200 | 8000+(N-1)×200 |
| Block Explorer | 3010 | 3210 | 3010+(N-1)×200 |
| zkSync RPC | 5050 | 5250 | 5050+(N-1)×200 |
| Keycloak | 5080 | 5280 | 5080+(N-1)×200 |
| Prometheus | 9090 | 9290 | 9090+(N-1)×200 |
| Grafana | 3100 | 3300 | 3100+(N-1)×200 |
| Webhook Service | 8080 | 8280 | 8080+(N-1)×200 |
| Bundler (ERC-4337) | 4337 | 4537 | 4337+(N-1)×200 |
| Postgres | 5432 | 5632 | 5432+(N-1)×200 (shared) |

Instance 1 uses the same default ports as upstream
[local-prividium](https://github.com/matter-labs/local-prividium).

### Options

```
./configure-prividiums.sh --count=N [options]

  --count=N                Number of Prividium instances (1–10; chains 5+ require genesis generation)
  --output=DIR             Output directory, wiped on each run (default: ./out)
  --prividium-version=V    Prividium image tag (default: v1.153.1)
```

---

## Examples

Pre-generated output in `examples/`:

| Directory | Command | Description |
|---|---|---|
| `examples/l2s-v30.2-2/` | `./configure-l2s.sh --count=2 --output=examples/l2s-v30.2-2` | 2 chains, v30.2, L1 settlement |
| `examples/l2s-v30.2-3/` | `./configure-l2s.sh --count=3 --output=examples/l2s-v30.2-3` | 3 chains, v30.2, L1 settlement |
| `examples/l2s-v30.2-4/` | `./configure-l2s.sh --count=4 --output=examples/l2s-v30.2-4` | 4 chains, v30.2, L1 settlement |
| `examples/l2s-v31.0-1/` | `./configure-l2s.sh --count=1 --version=v31.0 --output=examples/l2s-v31.0-1` | 1 chain, v31.0, L1 settlement |
| `examples/l2s-v31.0-2/` | `./configure-l2s.sh --count=2 --version=v31.0 --output=examples/l2s-v31.0-2` | 2 chains, v31.0, L1 settlement |
| `examples/l2s-v31.0-gateway-2/` | `./configure-l2s.sh --count=2 --version=v31.0 --gateway --output=examples/l2s-v31.0-gateway-2` | Gateway + 2 chains, v31.0 |
| `examples/prividium-1/` | `./configure-prividiums.sh --count=1 --output=examples/prividium-1` | 1 full Prividium stack |
| `examples/prividium-3/` | `./configure-prividiums.sh --count=3 --output=examples/prividium-3` | 3 full Prividium stacks (shared postgres) |

Each example is self-contained: all compose files, chain configs, genesis, and L1 state
are in the same directory. Volume paths in compose files are relative to the output directory.

---

## Genesis Generation for 5+ Chains

Chains 1–4 (v30.2) and 1–2 (v31.0) are pre-configured with operator keys and a bundled L1 state.
More chains require L1 contract deployment. Genesis generation always uses Docker:

```bash
# Generate genesis for 10 chains (~30min first run; Docker layer cache makes reruns fast)
./scripts/generate-genesis.sh --docker --count=10

# Then configure as usual
./configure-l2s.sh --count=10
./configure-prividiums.sh --count=10
```

The script writes a `configs/v30.2/genesis-max-count` sentinel file so the configure scripts
know genesis was generated for enough chains and skip the requirement check automatically.

---

## Repository Structure

```
the-three-chains-problem/
├── configure-l2s.sh              # Generate N bare L2 chains (v30.2 or v31.0 ± gateway)
├── configure-prividiums.sh       # Generate N full Prividium stacks
├── scripts/
│   ├── generate-chain-configs.sh # Writes chain_XXXX.yaml (embedded keys, version-aware)
│   ├── generate-compose.sh       # Generates zksyncos compose files (± gateway)
│   ├── generate-prividium-compose.sh  # Generates prividium compose files
│   └── generate-genesis.sh       # Genesis generation for chains 5+ (Docker mode)
├── genesis/
│   ├── Dockerfile                # Self-contained genesis generator image
│   └── generate_chains.py        # Genesis generation script
├── configs/
│   └── v30.2/
│       └── l1-state.json.gz      # Custom Anvil L1 state (chains 1–4 pre-deployed)
│                                 # (v31.0 assets are downloaded on first run)
└── examples/                     # Pre-generated output for reference
    ├── l2s-v30.2-2/              # 2 chains, v30.2
    ├── l2s-v30.2-3/              # 3 chains, v30.2
    ├── l2s-v30.2-4/              # 4 chains, v30.2
    ├── l2s-v31.0-1/              # 1 chain, v31.0
    ├── l2s-v31.0-2/              # 2 chains, v31.0
    ├── l2s-v31.0-gateway-2/      # gateway + 2 chains, v31.0
    ├── prividium-1/              # 1 Prividium instance
    └── prividium-3/              # 3 Prividium instances (shared postgres)
```

Generated files (gitignored):
- `out/` — default output directory (wiped and recreated on every run)

## Compatibility

| Component | Version |
|---|---|
| zksync-os-server | latest |
| Protocol v30.2 | Chains 1–4 pre-configured |
| Protocol v31.0 | Chains 1–2 pre-configured; gateway mode available |
| Prividium images | v1.153.1 |
| Foundry | 1.3.5 |

## Troubleshooting

**Chain fails to start:** Server takes 20–30s to initialize. Check: `docker compose … ps`

**Gateway chain hangs:** The `gateway-db.tar.gz` pre-seeds the gateway state. If it's corrupted,
delete `configs/v31.0/gateway-db.tar.gz` and re-run with `--force-genesis` to re-download.

**v31.0 assets download fails:** Check network connectivity. Files come from
`raw.githubusercontent.com/matter-labs/zksync-os-server/main/local-chains/v31.0/`.

**Prividium image pull fails:** Run `docker login quay.io` with Matter Labs credentials.

**Port conflicts:** Check with `lsof -i :5010` and `lsof -i :5049-5053`.
