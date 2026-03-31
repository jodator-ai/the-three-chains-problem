# Upgrading zksync-os-server to v0.18.1

*March 2026. Documents the breaking changes in zksync-os-server v0.18.1 vs v0.17.1 and how they were applied to this repo.*

---

## What changed in v0.18.1

### 1. Config file path and mount point

The server no longer reads its config from `/app/config/config.yaml`. It now reads from
a path supplied via `--config`, and the new conventional mount point is `/configs/`.

| | v0.17.1 | v0.18.1 |
|---|---|---|
| `--config` arg | `/app/config/config.yaml` | `/configs/chain_<id>.yaml` |
| Volume mount | `./config.yaml:/app/config/config.yaml:ro` | `./chain_6565.yaml:/configs/chain_6565.yaml:ro` |

The config filename also changed convention: from a generic `config.yaml` to a
chain-ID-scoped `chain_<id>.yaml`. This makes multi-chain deployments unambiguous.

### 2. Genesis file mount point

The genesis JSON is no longer loaded from `/app/config/genesis.json`.
It is now loaded from the path specified in `genesis_input_path` inside the config YAML,
which is expected to be at `/app/local-chains/<version>/genesis.json`.

| | v0.17.1 | v0.18.1 |
|---|---|---|
| Volume mount | `./genesis.json:/app/config/genesis.json:ro` | `./genesis.json:/app/local-chains/v30.2/genesis.json:ro` |
| Config `genesis_input_path` | `/app/config/genesis.json` (absolute) | `./local-chains/v30.2/genesis.json` (relative to working dir) |

### 3. Database volume path

The on-disk database location moved from `/app/db` to `/db`.

| | v0.17.1 | v0.18.1 |
|---|---|---|
| Volume | `zksyncos_db:/app/db` | `zksyncos_db:/db` |

### 4. New required config fields

v0.18.1 requires two new top-level sections in the YAML config that were absent in v0.17.1:

```yaml
# Required in v0.18.1 — not present in v0.17.1
general:
  ephemeral: false
  rocks_db_path: /db/node1   # must match the volume mount path above

rpc:
  address: 0.0.0.0:3050
```

Without `general.rocks_db_path`, the server may fail to locate its database.
Without `rpc.address`, the RPC port is not bound.

---

## Summary of compose changes

In `docker-compose-deps.yaml` (or equivalent deps file), the `zksyncos` service changes are:

```yaml
# v0.17.1
zksyncos:
  image: ghcr.io/matter-labs/zksync-os-server:v0.17.1
  command: ['/usr/bin/tini', '--', 'zksync-os-server', '--config', '/app/config/config.yaml']
  volumes:
    - zksyncos_db:/app/db
    - ./dev/zksyncos/config.yaml:/app/config/config.yaml:ro
    - ./dev/zksyncos/genesis.json:/app/config/genesis.json:ro
```

```yaml
# v0.18.1
zksyncos:
  image: ghcr.io/matter-labs/zksync-os-server:v0.18.1
  command: ['/usr/bin/tini', '--', 'zksync-os-server', '--config', '/configs/chain_6565.yaml']
  volumes:
    - zksyncos_db:/db
    - ./dev/zksyncos/chain_6565.yaml:/configs/chain_6565.yaml:ro
    - ./dev/l1/genesis.json:/app/local-chains/v30.2/genesis.json:ro
```

## Summary of config file changes

```yaml
# v0.17.1 — dev/zksyncos/config.yaml
genesis:
  bridgehub_address: '0x...'
  bytecode_supplier_address: '0x...'
  genesis_input_path: /app/config/genesis.json   # absolute path
  chain_id: 6565
l1_sender:
  pubdata_mode: Blobs
  operator_commit_sk: '0x...'
  operator_prove_sk: '0x...'
  operator_execute_sk: '0x...'
external_price_api_client:
  source: Forced
  forced_prices:
    '0x0000000000000000000000000000000000000001': 3000
```

```yaml
# v0.18.1 — dev/zksyncos/chain_6565.yaml
general:                                          # NEW section
  ephemeral: false
  rocks_db_path: /db/node1
genesis:
  bridgehub_address: '0x...'
  bytecode_supplier_address: '0x...'
  genesis_input_path: ./local-chains/v30.2/genesis.json  # relative path, new location
  chain_id: 6565
l1_sender:
  pubdata_mode: Blobs
  operator_commit_sk: '0x...'
  operator_prove_sk: '0x...'
  operator_execute_sk: '0x...'
rpc:                                              # NEW section
  address: 0.0.0.0:3050
external_price_api_client:
  source: Forced
  forced_prices:
    '0x0000000000000000000000000000000000000001': 3000
```

---

## Other fixes applied alongside this upgrade

### Bundler port was missing in local-prividium

The ERC-4337 bundler service had no `ports:` entry in local-prividium's
`docker-compose-deps.yaml`. The bundler was unreachable from the host. Fixed in this repo:

```yaml
bundler:
  ports:
    - '4337:4337'   # was missing
```

### prividium-api was missing bundler env vars

`BUNDLER_ENABLED`, `BUNDLER_RPC_URL`, and `RATE_LIMIT_*` vars were absent from
`prividium-api`. The API would start but the bundler integration would be silently disabled.
Fixed:

```yaml
prividium-api:
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
  depends_on:
    bundler:            # was missing — API would start before bundler was ready
      condition: service_started
```

### keycloak KC_METRICS_ENABLED

`KC_METRICS_ENABLED: 'true'` was present in local-prividium but absent in this repo's
generated configs. Added to all keycloak service definitions.

### Webhook service config file rename

The webhook service config file was renamed from `config.default.toml` to
`config.prividium.local.toml`. The `ZKSYNC_WEBHOOK_CHAIN_ID` and
`ZKSYNC_WEBHOOK_CHAIN_NAME` env vars were removed (now read from chain config internally).

```yaml
# was:
ZKSYNC_WEBHOOK_CONFIG: /app/config/config.default.toml
ZKSYNC_WEBHOOK_CHAIN_ID: 424242
ZKSYNC_WEBHOOK_CHAIN_NAME: 'local_prividium'

# now:
ZKSYNC_WEBHOOK_CONFIG: /app/config/config.prividium.local.toml
# (CHAIN_ID and CHAIN_NAME removed)
```

Note: The webhook config filename change is already applied in this repo's generator
(`config.prividium.local.toml`). The stale env vars are only present in
local-prividium's upstream `docker-compose-deps.yaml`.

---

## Prividium image versions

Alongside the server upgrade, Prividium service images were bumped:

| Service | Before | After |
|---------|--------|-------|
| prividium-permissions-api | v1.166.1 | v1.169.1 |
| prividium-adminv2 | v1.166.1 | v1.169.1 |
| prividium-user-panel | v1.166.1 | v1.169.1 |
| prividium-bundler | v1.166.1 | v1.169.1 |

The entrypoint deployer (Foundry) was pinned from `latest` to `v1.5.1` for reproducibility.
