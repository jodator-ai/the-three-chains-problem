# Migration: local-prividium → 3-chain setup

*How to take the upstream [matter-labs/local-prividium](https://github.com/matter-labs/local-prividium)
single-chain setup and run 3 independent Prividium instances sharing one L1.*

Applies to: local-prividium commit `a0a251c` ("Automated sync for version v1.166.2", March 2026).

---

## Overview of changes

local-prividium is a single-chain reference setup. This migration:

1. **Upgrades zksync-os-server** v0.17.1 → v0.18.1 (breaking config changes)
2. **Adds 3 independent chain instances** with chain-ID-scoped service names, databases, and ports
3. **Fixes missing bundler port** and prividium-api bundler integration
4. **Restructures the dev/ directory** for per-instance isolation
5. **Adopts a 3-file compose structure** (shared L1, per-chain deps, per-chain main)

The result matches the `examples/prividium-3/` directory in this repo.

---

## Step 1 — Upgrade zksync-os-server to v0.18.1

### 1a. Update the image

In `docker-compose-deps.yaml`:

```yaml
# before
image: ghcr.io/matter-labs/zksync-os-server:v0.17.1

# after
image: ghcr.io/matter-labs/zksync-os-server:v0.18.1
```

### 1b. Update command and volume mounts

```yaml
# before
command: ['/usr/bin/tini', '--', 'zksync-os-server', '--config', '/app/config/config.yaml']
volumes:
  - zksyncos_db:/app/db
  - ./dev/zksyncos/config.yaml:/app/config/config.yaml:ro
  - ./dev/zksyncos/genesis.json:/app/config/genesis.json:ro

# after
command: ['/usr/bin/tini', '--', 'zksync-os-server', '--config', '/configs/chain_6565.yaml']
volumes:
  - zksyncos_db:/db
  - ./dev/zksyncos/chain_6565.yaml:/configs/chain_6565.yaml:ro
  - ./dev/l1/genesis.json:/app/local-chains/v30.2/genesis.json:ro
```

### 1c. Update the chain config file

Rename `dev/zksyncos/config.yaml` → `dev/zksyncos/chain_6565.yaml` and add two new required sections:

```yaml
# Add at the top:
general:
  ephemeral: false
  rocks_db_path: /db/node1

genesis:
  bridgehub_address: '0xd8f8df05efacd52f28cdf11be22ce3d6ae0fabf7'
  bytecode_supplier_address: '0x9f3f32ea83c8a1c8e993fd9035d1d077545467ac'
  genesis_input_path: ./local-chains/v30.2/genesis.json   # was: /app/config/genesis.json
  chain_id: 6565
l1_sender:
  # ... (unchanged)

# Add at the bottom:
rpc:
  address: 0.0.0.0:3050
```

### 1d. Move the genesis file

The genesis.json mount point changed. Move the file:

```
dev/zksyncos/genesis.json  →  dev/l1/genesis.json
```

Or just update the volume mount path without moving the file if you prefer.

---

## Step 2 — Fix bundler port and prividium-api integration

### 2a. Expose bundler port

In `docker-compose-deps.yaml`, the `bundler` service is missing a `ports:` entry:

```yaml
bundler:
  # ... existing config ...
  ports:
    - '4337:4337'   # add this
```

### 2b. Add bundler env vars and dependency to prividium-api

In `docker-compose.yaml`:

```yaml
prividium-api:
  depends_on:
    - postgres
    - zksyncos
    - bundler      # add this — api must start after bundler
  environment:
    # ... existing vars ...
    - BUNDLER_ENABLED=true
    - BUNDLER_RPC_URL=http://bundler:4337
    - RATE_LIMIT_ENABLED=true
    - RATE_LIMIT_AUTH_MAX=100
    - RATE_LIMIT_PUBLIC_MAX=300
    - RATE_LIMIT_USER_MAX=300
    - RATE_LIMIT_RPC_MAX=1000
    - RATE_LIMIT_WINDOW_MS=60000
```

### 2c. Add KC_METRICS_ENABLED to keycloak

```yaml
keycloak:
  environment:
    # ... existing vars ...
    KC_METRICS_ENABLED: 'true'   # add this
```

### 2d. Fix webhook service config file and remove stale env vars

```yaml
zksync-webhook-service:
  environment:
    ZKSYNC_WEBHOOK_CONFIG: /app/config/config.prividium.local.toml  # was config.default.toml
    # Remove these two lines:
    # ZKSYNC_WEBHOOK_CHAIN_ID: 424242
    # ZKSYNC_WEBHOOK_CHAIN_NAME: 'local_prividium'
```

### 2e. Pin entrypoint-deployer to a fixed Foundry version

```yaml
entrypoint-deployer:
  image: ghcr.io/foundry-rs/foundry:v1.5.1   # was: latest
```

After steps 1–2, you have a corrected single-chain setup. **Test it before continuing.**

---

## Step 3 — Restructure for 3 chains

The multi-chain setup splits one compose stack into a 3-file hierarchy per instance:

```
docker-compose.l1.yml           ← shared Anvil L1 + postgres (new file)
docker-compose.6565.deps.yml    ← zksyncos, keycloak, block-explorer for chain 6565
docker-compose.6565.yml         ← prividium-api, admin, user-panel for chain 6565
docker-compose.6566.deps.yml    ← same for chain 6566
docker-compose.6566.yml
docker-compose.6567.deps.yml    ← same for chain 6567
docker-compose.6567.yml
```

Each `.yml` includes its `.deps.yml` via Docker Compose `include:`, which in turn includes
`docker-compose.l1.yml`. A single `docker compose -f docker-compose.6565.yml up` brings up
the full chain 6565 stack. Running all three:

```bash
docker compose \
  -f docker-compose.6565.yml \
  -f docker-compose.6566.yml \
  -f docker-compose.6567.yml \
  up -d
```

### 3a. Create docker-compose.l1.yml

Extract the `l1` and `postgres` services from `docker-compose-deps.yaml` into a new file.
Key changes vs the original:

- L1 state is gzip-compressed: mount `l1-state.json.gz`, decompress on first run
- Use `--state` (persists changes) instead of `--load-state` (read-only)
- Add `--preserve-historical-states` for block explorer historical queries

```yaml
name: zksync-prividiums

services:
  l1:
    image: ghcr.io/foundry-rs/foundry:v1.5.1
    volumes:
      - ./dev/l1/l1-state.json.gz:/l1-state.json.gz:ro
      - l1state:/home/foundry/l1state
    entrypoint: ''
    user: 'root'
    ports:
      - '5010:5010'
    healthcheck:
      test: ['CMD-SHELL', 'cast chain-id -r http://localhost:5010']
      interval: 10s
      timeout: 5s
      retries: 5
    command: |
      bash -c "
      if [[ ! -f /home/foundry/l1state/state.json ]]; then
        gzip -d < /l1-state.json.gz > /home/foundry/l1state/state.json
      fi
      anvil --state=/home/foundry/l1state/state.json --preserve-historical-states --port 5010 --host 0.0.0.0
      "

  postgres:
    image: postgres:15
    restart: unless-stopped
    ports:
      - '5432:5432'
    volumes:
      - postgres:/var/lib/postgresql/data
    environment:
      POSTGRES_PASSWORD: postgres
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U postgres']
      interval: 10s
      timeout: 5s
      retries: 5
    entrypoint: |
      bash -c "
      cat > /docker-entrypoint-initdb.d/init.sql << 'SQLEOF'
      CREATE DATABASE prividium_api_6565;
      CREATE DATABASE prividium_block_explorer_6565;
      CREATE DATABASE prividium_api_6566;
      CREATE DATABASE prividium_block_explorer_6566;
      CREATE DATABASE prividium_api_6567;
      CREATE DATABASE prividium_block_explorer_6567;
      SQLEOF
      exec docker-entrypoint.sh postgres
      "

volumes:
  l1state:
  postgres:
```

### 3b. Prepare the L1 state for 3 chains

local-prividium ships a single `dev/zksyncos/l1-state.json` with only chain 6565 deployed.
For 3 chains, you need an L1 state that has chains 6565, 6566, and 6567 all pre-deployed
and funded.

**Use the pre-built state from this repo:**

```bash
cp /path/to/the-three-chains-problem/configs/v30.2/l1-state.json.gz  dev/l1/
cp /path/to/the-three-chains-problem/configs/v30.2/genesis.json       dev/l1/
```

The pre-built state has all 3 chains deployed with `requestL2TransactionDirect` deposits
for the rich account (`0x36615Cf349d7F6344891B1e7CA7C72883F5dc049`). See
[`docs/learnings/priority-queue-deposit-fix.md`](learnings/priority-queue-deposit-fix.md)
for why this matters.

**Or regenerate from scratch** (requires Docker, ~30 min, 4 GB RAM):

```bash
# From the-three-chains-problem root:
./scripts/generate-genesis.sh --docker --count=3
# Outputs configs/v30.2/l1-state.json.gz with 3 chains
```

### 3c. Create per-chain configs

Copy the chain 6565 config and create variants for 6566 and 6567.
Get the chain-specific values (bridgehub address, keys) from this repo's
`configs/v30.2/chain_6566.yaml` and `configs/v30.2/chain_6567.yaml`.

```
dev/
├── l1/
│   ├── l1-state.json.gz
│   └── genesis.json
├── prividium-1/           # instance 1 (chain 6565)
│   ├── zksyncos/chain_6565.yaml
│   ├── keycloak/realm-export.json
│   ├── block-explorer/block-explorer-config.js
│   ├── prometheus/prometheus.yml
│   └── grafana/datasources/prometheus.yml
├── prividium-2/           # instance 2 (chain 6566)
│   ├── zksyncos/chain_6566.yaml
│   └── ...
└── prividium-3/           # instance 3 (chain 6567)
    ├── zksyncos/chain_6567.yaml
    └── ...
```

Chain config values for 6566 and 6567 (operator keys, bridgehub address) come from
`configs/v30.2/chain_6566.yaml` and `configs/v30.2/chain_6567.yaml` in this repo.

### 3d. Scope service names and databases to chain ID

All service names get a `-<chain_id>` suffix and all database names get a `_<chain_id>` suffix.
This allows multiple instances to run on the same Docker network without name collisions.

| Service | before | after (chain 6565) |
|---------|--------|---------------------|
| `zksyncos` | `zksyncos` | `zksyncos-6565` |
| `keycloak` | `keycloak` | `keycloak-6565` |
| `prividium-api` | `prividium-api` | `prividium-api-6565` |
| `admin-panel` | `admin-panel` | `admin-panel-6565` |
| `bundler` | `bundler` | `bundler-6565` |
| ... | ... | ...-6565 |
| Database | `prividium_api` | `prividium_api_6565` |

Update all inter-service references in environment variables accordingly:

```yaml
# example — prividium-api for chain 6566
SEQUENCER_RPC_URL: http://zksyncos-6566:3051   # internal port = 3049 + instance_num
DATABASE_URL: postgres://...@postgres:5432/prividium_api_6566
OIDC_JWKS_URI: http://keycloak-6566:8080/...
BUNDLER_RPC_URL: http://bundler-6566:4337
```

> **Note — alternative naming scheme (TBD):** The chain-ID suffix (`-6565`, `-6566`, `-6567`) has
> two practical drawbacks: the numbers are visually similar and easy to misread, and suffix-based
> names prevent `docker ps` from grouping all services of one instance together (they sort by
> service type, not by instance). A cleaner alternative is an **instance token as prefix**, e.g.
> `prividium-alpha`, `prividium-beta`, `prividium-gamma` (or `prividium-1/2/3`, `prividium-a/b/c`).
>
> Under such a scheme the examples above would become:
>
> | compose file | service | dev dir |
> |---|---|---|
> | `compose.prividium-alpha.yml` | `prividium-alpha-api` | `dev/prividium-alpha/` |
> | `compose.prividium-beta.yml` | `prividium-beta-api` | `dev/prividium-beta/` |
> | `compose.prividium-gamma.yml` | `prividium-gamma-api` | `dev/prividium-gamma/` |
>
> `docker ps` then lists all `prividium-alpha-*` services together. The chain ID stays inside the
> config file (`chain_6565.yaml`) where precision matters, not in every filename.
>
> The specific token (`alpha/beta/gamma`, `a/b/c`, `1/2/3`) is not yet decided. The generator
> script (`scripts/generate-prividium-compose.sh`) and the examples directory would both need
> updating once a convention is chosen.

### 3e. Apply port stride (200 per instance)

Each instance gets its own port range to avoid conflicts on the host:

| Service | Instance 1 (6565) | Instance 2 (6566) | Instance 3 (6567) |
|---------|:-----------------:|:-----------------:|:-----------------:|
| zksyncos RPC | 5050 | 5250 | 5450 |
| prividium-api | 8000 | 8200 | 8400 |
| admin panel | 3000 | 3200 | 3400 |
| user panel | 3001 | 3201 | 3401 |
| keycloak | 5080 | 5280 | 5480 |
| block explorer | 3010 | 3210 | 3410 |
| prometheus | 9090 | 9290 | 9490 |
| grafana | 3100 | 3300 | 3500 |
| bundler | 4337 | 4537 | 4737 |
| webhook | 8080 / 8081 | 8280 / 8281 | 8480 / 8481 |

The internal zksyncos port (inside the container) = `3049 + instance_number`:
- Instance 1 → internal port 3050
- Instance 2 → internal port 3051
- Instance 3 → internal port 3052

This avoids all port conflicts when running all 3 instances simultaneously.

### 3f. Per-instance keycloak realm config

Each keycloak instance needs its own `realm-export.json` with redirect URIs matching its
specific ports. Use the files from `examples/prividium-3/dev/prividium-*/keycloak/` or
regenerate with `./scripts/generate-prividium-compose.sh`.

---

## Step 4 — Use the generator (recommended)

Instead of manually creating all files, use this repo's generator script:

```bash
# From the-three-chains-problem root:

# 1. Ensure genesis is available
cp configs/v30.2/l1-state.json.gz  /path/to/output/dev/l1/
cp configs/v30.2/genesis.json       /path/to/output/dev/l1/

# 2. Generate all compose files and per-instance configs
./scripts/generate-prividium-compose.sh \
  --count=3 \
  --output-dir=/path/to/output \
  --configs-dir=/path/to/output/dev

# 3. Start everything
cd /path/to/output
./start.sh
```

The script produces all 7 compose files, per-instance keycloak realms, block-explorer configs,
prometheus configs, and a `start.sh` wrapper in one pass.

---

## Step 5 — Verify

```bash
# All three chains should respond
cast chain-id --rpc-url http://localhost:5050   # → 6565
cast chain-id --rpc-url http://localhost:5250   # → 6566
cast chain-id --rpc-url http://localhost:5450   # → 6567

# Rich account should have ~100 ETH on each L2 (takes ~30s after start)
cast balance 0x36615Cf349d7F6344891B1e7CA7C72883F5dc049 --rpc-url http://localhost:5050
cast balance 0x36615Cf349d7F6344891B1e7CA7C72883F5dc049 --rpc-url http://localhost:5250
cast balance 0x36615Cf349d7F6344891B1e7CA7C72883F5dc049 --rpc-url http://localhost:5450
# Expected: ~100000131250000000000 each

# Bundler should respond
curl http://localhost:4337  # chain 6565
curl http://localhost:4537  # chain 6566
curl http://localhost:4737  # chain 6567
```

---

## What stays the same

These do not change between local-prividium and the 3-chain setup:

- All image tags (keycloak, postgres, block-explorer, prometheus, grafana, webhook)
- All Keycloak configuration (users, roles, OIDC settings)
- The bundler entrypoint contract address (`0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108`)
- Private keys (operator, bundler executor) — same for all instances in local dev
- All health check definitions

---

## Changes that should be contributed back to local-prividium

The following are bugs or improvements that apply to single-chain setups too:

1. **Bundler port missing** — add `ports: - '4337:4337'` to the bundler service
2. **prividium-api missing bundler env vars** — `BUNDLER_ENABLED`, `BUNDLER_RPC_URL`, `RATE_LIMIT_*`
3. **prividium-api missing bundler dependency** — add `bundler` to `depends_on`
4. **KC_METRICS_ENABLED** — should be `'true'` in keycloak environment
5. **Webhook config filename** — `config.default.toml` → `config.prividium.local.toml`
6. **CORS/SIWE domains** — add `:3010` (block-explorer app) and `:3002` (block-explorer API)
   to `CORS_ORIGIN` and `SIWE_VALID_DOMAINS` so block-explorer auth works
7. **zksync-os-server v0.18.1** — config path changes, new `general`/`rpc` config sections
8. **entrypoint-deployer pinning** — `ghcr.io/foundry-rs/foundry:v1.5.1` instead of `:latest`
