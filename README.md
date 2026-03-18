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
  -f generated/docker-compose.l1.yml \
  -f generated/docker-compose.zksyncos-6565.yml \
  -f generated/docker-compose.zksyncos-6566.yml \
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
  --output-dir=DIR    Output directory (default: ./generated)
  --force-genesis     Re-extract/re-download genesis assets
  --server-image=IMG  zksync-os-server image (default: latest)
```

### How It Works

```
configure-l2s.sh --count=N [--version=v31.0] [--gateway]
       │
       ├── scripts/generate-chain-configs.sh
       │   ├── v30.2: writes chain_XXXX.yaml (bridgehub/keys for v30.2)
       │   └── v31.0 [--gateway]:
       │       ├── chain_506.yaml    — gateway chain (settles to L1)
       │       └── chain_XXXX.yaml  — L2 chains (gateway_rpc_url → chain 506)
       │
       ├── genesis.json
       │   ├── v30.2: extracted from zksync-os-server Docker image
       │   └── v31.0: downloaded from upstream repo on first run
       │
       ├── [--gateway] gateway-db.tar.gz  — pre-seeded gateway state, downloaded
       │
       └── scripts/generate-compose.sh
           ├── generated/docker-compose.l1.yml
           ├── generated/docker-compose.gateway-506.yml   (gateway mode only)
           └── generated/docker-compose.zksyncos-XXXX.yml (one per chain)
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

docker compose \
  -f generated-prividiums/docker-compose.l1.yml \
  -f generated-prividiums/docker-compose.prividium-6565.yml \
  -f generated-prividiums/docker-compose.prividium-6566.yml \
  -f generated-prividiums/docker-compose.prividium-6567.yml \
  up -d
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
| Postgres | 5432 | 5632 | 5432+(N-1)×200 |

Instance 1 uses the same default ports as upstream
[local-prividium](https://github.com/matter-labs/local-prividium).

### Options

```
./configure-prividiums.sh --count=N [options]

  --count=N                Number of Prividium instances (1–4)
  --output-dir=DIR         Output directory (default: ./generated-prividiums)
  --force-refresh          Re-download keycloak realm + re-extract genesis.json
  --prividium-version=V    Prividium image tag (default: v1.153.1)
```

---

## Examples

Pre-generated output in `examples/`:

| Directory | Command | Description |
|---|---|---|
| `examples/l2s-v30.2-2/` | `./configure-l2s.sh --count=2` | 2 chains, v30.2, L1 settlement |
| `examples/l2s-v30.2-3/` | `./configure-l2s.sh --count=3` | 3 chains, v30.2, L1 settlement |
| `examples/l2s-v30.2-4/` | `./configure-l2s.sh --count=4` | 4 chains, v30.2, L1 settlement |
| `examples/l2s-v31.0-1/` | `./configure-l2s.sh --count=1 --version=v31.0` | 1 chain, v31.0, L1 settlement |
| `examples/l2s-v31.0-2/` | `./configure-l2s.sh --count=2 --version=v31.0` | 2 chains, v31.0, L1 settlement |
| `examples/l2s-v31.0-gateway-2/` | `./configure-l2s.sh --count=2 --version=v31.0 --gateway` | Gateway + 2 chains, v31.0 |
| `examples/prividium-1/` | `./configure-prividiums.sh --count=1` | 1 full Prividium stack |
| `examples/prividium-3/` | `./configure-prividiums.sh --count=3` | 3 full Prividium stacks (shared postgres) |

Each example includes all compose files and chain configs. The `l1-state.json.gz` is not
duplicated — v30.2 is tracked at `configs/v30.2/l1-state.json.gz`; v31.0 is downloaded on demand.

---

## Genesis Generation for 5+ Chains

Chains 1–4 (v30.2) and 1–2 (v31.0) are pre-configured. More chains require L1 contract deployment:

```bash
# Generate genesis for 5 chains (~30min first run; cached after)
./scripts/generate-genesis.sh --docker --count=5

# Then configure as usual
./configure-l2s.sh --count=5
```

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
- `generated/`, `generated-prividiums/` — output dirs
- `configs/v30.2/chain_*.yaml`, `genesis.json`, `keycloak-realm.json` — regenerated each run
- `configs/v31.0/` — downloaded from upstream on first run

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
