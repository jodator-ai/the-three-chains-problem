#!/usr/bin/env bash
# generate-prividium-compose.sh
# Generates composable docker-compose files for N Prividium instances:
#
#   <output-dir>/docker-compose.l1.yml              (Anvil L1 + shared postgres)
#   <output-dir>/docker-compose.<id>.deps.yml       (zksyncos, keycloak, block-explorer per instance;
#                                                    includes docker-compose.l1.yml)
#   <output-dir>/docker-compose.<id>.yml            (admin-panel, prividium-api, user-panel per instance;
#                                                    includes docker-compose.<id>.deps.yml)
#
# The include chain means a single `-f docker-compose-<id>.yaml` brings up everything.
# For multi-instance: `-f docker-compose-6565.yaml -f docker-compose-6566.yaml up`
# (shared L1/postgres are deduplicated automatically by Docker Compose).
#
# Port layout per instance N (1-indexed), offset = (N-1)*200:
#   zksyncos RPC  : 5050 + offset  (external)  →  3049 + N (internal, matches chain config)
#   admin-panel   : 3000 + offset
#   user-panel    : 3001 + offset
#   prividium-api : 8000 + offset
#   api metrics   : 9091 + offset
#   keycloak      : 5080 + offset
#   block-explorer: 3010 + offset
#   data-fetcher  : 3040 + offset
#   explorer-api  : 3002 + offset
#   prometheus    : 9090 + offset
#   grafana       : 3100 + offset
#   webhook-svc   : 8080 + offset  (API), 8081 + offset (internal)
#   bundler       : 4337 + offset
#   postgres      : 5432  (shared, single instance in docker-compose-l1.yaml)

set -euo pipefail

readonly SCRIPT_NAME="generate-prividium-compose.sh"

# ── defaults ──────────────────────────────────────────────────────────────────
readonly DEFAULT_COUNT=1
readonly DEFAULT_VERSION="v30.2"
readonly DEFAULT_SERVER_IMAGE="ghcr.io/matter-labs/zksync-os-server:v0.18.1"
readonly DEFAULT_L1_IMAGE="ghcr.io/foundry-rs/foundry:v1.5.1"
readonly DEFAULT_PRIVIDIUM_VERSION="v1.169.1"
readonly DEFAULT_FOUNDRY_IMAGE="ghcr.io/foundry-rs/foundry:v1.5.1"
readonly BASE_CHAIN_ID=6564
readonly PORT_STRIDE=200

# ── helpers ───────────────────────────────────────────────────────────────────
die()        { echo "[$SCRIPT_NAME] ERROR: $*" >&2; exit 1; }
log()        { echo "[$SCRIPT_NAME] $*"; }
is_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Generates composable docker-compose files for N Prividium instances.
Volume paths in output files are relative to <output-dir>.

Options:
  --count=N                Number of Prividium instances (default: $DEFAULT_COUNT)
  --output-dir=DIR         Directory to write compose files (required)
  --configs-dir=DIR        Directory containing chain configs and genesis (required)
  --version=VER            ZKsync OS protocol version (default: $DEFAULT_VERSION)
  --zksyncos-version=VER   zksync-os-server image tag, e.g. v0.18.1 (sets --server-image)
  --server-image=IMG       Full zksync-os-server image ref (default: $DEFAULT_SERVER_IMAGE)
  --l1-image=IMG           Anvil image (default: $DEFAULT_L1_IMAGE)
  --prividium-version=V    Prividium services image tag (default: $DEFAULT_PRIVIDIUM_VERSION)
  --foundry-image=IMG      Foundry image for entrypoint deployer (default: $DEFAULT_FOUNDRY_IMAGE)
  --help, -h               Show this message
EOF
  exit 0
}

# ── argument parsing ──────────────────────────────────────────────────────────
count="$DEFAULT_COUNT"
output_dir=""
configs_dir=""
version="$DEFAULT_VERSION"
server_image="$DEFAULT_SERVER_IMAGE"
l1_image="$DEFAULT_L1_IMAGE"
prividium_version="$DEFAULT_PRIVIDIUM_VERSION"
foundry_image="$DEFAULT_FOUNDRY_IMAGE"

for arg in "$@"; do
  case "$arg" in
    --count=*)                count="${arg#*=}" ;;
    --output-dir=*)           output_dir="${arg#*=}" ;;
    --configs-dir=*)          configs_dir="${arg#*=}" ;;
    --version=*)              version="${arg#*=}" ;;
    --server-image=*)         server_image="${arg#*=}" ;;
    --zksyncos-version=*)     server_image="ghcr.io/matter-labs/zksync-os-server:${arg#*=}" ;;
    --l1-image=*)             l1_image="${arg#*=}" ;;
    --prividium-version=*)    prividium_version="${arg#*=}" ;;
    --foundry-image=*)        foundry_image="${arg#*=}" ;;
    --help|-h)                usage ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

[[ -n "$output_dir"  ]] || die "--output-dir is required"
[[ -n "$configs_dir" ]] || die "--configs-dir is required"
is_integer "$count"    || die "--count must be a positive integer"
[[ "$count" -ge 1 ]]   || die "--count must be at least 1"

mkdir -p "$output_dir"

# Compute relative path from output_dir to configs_dir.
# Uses Python for portability (macOS realpath lacks --relative-to).
output_abs="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$output_dir")"
configs_abs="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$configs_dir")"
rel_configs="$(python3 -c "import os,sys; p=os.path.relpath(sys.argv[1], sys.argv[2]); print(p if p.startswith('.') else './'+p)" "$configs_abs" "$output_abs")"

# ── postgres init SQL (creates per-instance databases) ────────────────────────
build_postgres_init_sql() {
  local sql=""
  local i chain_id
  for i in $(seq 1 "$count"); do
    chain_id=$(( BASE_CHAIN_ID + i ))
    sql+="      CREATE DATABASE prividium_api_${chain_id};"$'\n'
    sql+="      CREATE DATABASE prividium_block_explorer_${chain_id};"$'\n'
  done
  echo "$sql"
}

# ── l1 compose file (Anvil + shared postgres) ─────────────────────────────────
generate_l1() {
  local -r out="$output_dir/docker-compose.l1.yml"
  local -r init_sql="$(build_postgres_init_sql)"

  cat > "$out" <<EOF
# Auto-generated by $SCRIPT_NAME — do not edit manually.
# Shared infrastructure: Anvil L1 and postgres for all Prividium instances.
name: zksync-prividiums

services:

  # ── L1 (Anvil) ──────────────────────────────────────────────────────────────
  l1:
    image: $l1_image
    volumes:
      - ${rel_configs}/l1/l1-state.json.gz:/l1-state.json.gz:ro
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
        echo 'Decompressing L1 state...'
        gzip -d < /l1-state.json.gz > /home/foundry/l1state/state.json
      fi
      anvil --state=/home/foundry/l1state/state.json --preserve-historical-states --port 5010 --host 0.0.0.0
      "

  # ── Shared postgres ─────────────────────────────────────────────────────────
  # One database server for all Prividium instances; each instance gets its own
  # databases: prividium_api_<chain_id> and prividium_block_explorer_<chain_id>
  postgres:
    image: postgres:15
    restart: unless-stopped
    ports:
      - '127.0.0.1:5432:5432'
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
${init_sql}
      SQLEOF
      exec docker-entrypoint.sh postgres
      "

volumes:
  l1state:
  postgres:
EOF
  log "Generated $out"
}

# ── per-instance keycloak realm config ───────────────────────────────────────
# Generated (not downloaded) so redirect URIs match each instance's actual ports.
generate_keycloak_realm() {
  local -r instance_num="$1"
  local -r chain_id="$2"
  local -r p_admin="$3"
  local -r p_user="$4"
  local -r p_explorer_api="$5"
  local -r p_explorer_app="$6"
  local -r p_keycloak="$7"

  local -r out_dir="$configs_abs/prividium-${instance_num}/keycloak"
  mkdir -p "$out_dir"
  local -r out="$out_dir/realm-export.json"

  python3 - "$out" "${p_admin}" "${p_user}" "${p_explorer_api}" "${p_explorer_app}" "${p_keycloak}" <<'PYEOF'
import json, sys
out, p_admin, p_user, p_explorer_api, p_explorer_app, p_keycloak = sys.argv[1:]
realm = {
    "id": "prividium",
    "realm": "prividium",
    "enabled": True,
    "sslRequired": "none",
    "registrationAllowed": False,
    "loginWithEmailAllowed": True,
    "duplicateEmailsAllowed": False,
    "resetPasswordAllowed": True,
    "editUsernameAllowed": False,
    "bruteForceProtected": True,
    "accessTokenLifespan": 3600,
    "ssoSessionIdleTimeout": 3600,
    "ssoSessionMaxLifespan": 36000,
    "offlineSessionIdleTimeout": 2592000,
    "accessCodeLifespan": 60,
    "accessCodeLifespanUserAction": 300,
    "accessCodeLifespanLogin": 1800,
    "clients": [
        {
            "clientId": "prividium-client",
            "name": "Prividium Local Development",
            "description": "OAuth client for Prividium local testing",
            "enabled": True,
            "clientAuthenticatorType": "client-secret",
            "secret": "prividium-local-secret",
            "redirectUris": [
                "http://localhost:{}/*".format(p_admin),
                "http://localhost:{}/*".format(p_user),
                "http://localhost:{}/*".format(p_explorer_api),
                "http://localhost:{}/*".format(p_explorer_app),
                "http://localhost:{}/*".format(p_keycloak),
                "http://localhost:4000/*",
                "http://localhost:5173/*"
            ],
            "webOrigins": ["+"],
            "protocol": "openid-connect",
            "publicClient": True,
            "standardFlowEnabled": True,
            "implicitFlowEnabled": False,
            "directAccessGrantsEnabled": True,
            "serviceAccountsEnabled": False,
            "attributes": {
                "pkce.code.challenge.method": "S256",
                "access.token.lifespan": "3600",
                "post.logout.redirect.uris": "+"
            },
            "protocolMappers": [
                {
                    "name": "email",
                    "protocol": "openid-connect",
                    "protocolMapper": "oidc-usermodel-property-mapper",
                    "consentRequired": False,
                    "config": {
                        "userinfo.token.claim": "true",
                        "user.attribute": "email",
                        "id.token.claim": "true",
                        "access.token.claim": "true",
                        "claim.name": "email",
                        "jsonType.label": "String"
                    }
                },
                {
                    "name": "preferred_username",
                    "protocol": "openid-connect",
                    "protocolMapper": "oidc-usermodel-property-mapper",
                    "consentRequired": False,
                    "config": {
                        "userinfo.token.claim": "true",
                        "user.attribute": "username",
                        "id.token.claim": "true",
                        "access.token.claim": "true",
                        "claim.name": "preferred_username",
                        "jsonType.label": "String"
                    }
                }
            ]
        }
    ],
    "roles": {
        "realm": [
            {"name": "admin", "description": "Administrator role"},
            {"name": "user", "description": "Regular user role"}
        ]
    },
    "users": [
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "username": "admin@local.dev", "email": "admin@local.dev",
            "emailVerified": True, "enabled": True,
            "firstName": "Admin", "lastName": "User",
            "credentials": [{"type": "password", "value": "password", "temporary": False}],
            "realmRoles": ["admin", "user"]
        },
        {
            "id": "00000000-0000-0000-0000-000000000002",
            "username": "user@local.dev", "email": "user@local.dev",
            "emailVerified": True, "enabled": True,
            "firstName": "Regular", "lastName": "User",
            "credentials": [{"type": "password", "value": "password", "temporary": False}],
            "realmRoles": ["user"]
        },
        {
            "id": "00000000-0000-0000-0000-000000000003",
            "username": "test@local.dev", "email": "test@local.dev",
            "emailVerified": True, "enabled": True,
            "firstName": "Test", "lastName": "User",
            "credentials": [{"type": "password", "value": "password", "temporary": False}],
            "realmRoles": ["user"]
        }
    ]
}
with open(out, "w") as f:
    json.dump(realm, f, indent=4)
PYEOF
  log "Generated $out  (keycloak realm, chain_id=$chain_id)"
}

# ── block-explorer config.js ──────────────────────────────────────────────────
generate_explorer_config() {
  local -r instance_num="$1"
  local -r chain_id="$2"
  local -r explorer_api_port="$3"
  local -r explorer_app_port="$4"
  local -r user_panel_port="$5"
  local -r prividium_api_port="$6"

  local -r out_dir="$configs_abs/prividium-${instance_num}/block-explorer"
  mkdir -p "$out_dir"
  cat > "$out_dir/block-explorer-config.js" <<EOF
window['##runtimeConfig'] = {
  appEnvironment: 'prividium',
  environmentConfig: {
    networks: [{
      apiUrl: 'http://localhost:${explorer_api_port}',
      hostnames: ['localhost:${explorer_app_port}'],
      rpcUrl: 'http://localhost:${prividium_api_port}/rpc',
      l2ChainId: ${chain_id},
      l2NetworkName: 'Prividium Local (${chain_id})',
      baseTokenAddress: '0x000000000000000000000000000000000000800A',
      prividium: true,
      userPanelUrl: 'http://localhost:${user_panel_port}',
      published: true,
      maintenance: false
    }]
  }
};
EOF
}

# ── per-instance prometheus config ───────────────────────────────────────────
generate_prometheus_config() {
  local -r instance_num="$1"
  local -r chain_id="$2"
  local -r p_api_metrics="$3"

  local -r out_dir="$configs_abs/prividium-${instance_num}/prometheus"
  mkdir -p "$out_dir"
  cat > "$out_dir/prometheus.yml" <<EOF
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'prividium-api'
    static_configs:
      - targets: ['prividium-api-${chain_id}:9091']
EOF
  log "Generated $out_dir/prometheus.yml"
}

# ── per-instance grafana datasource config ────────────────────────────────────
generate_grafana_config() {
  local -r instance_num="$1"
  local -r chain_id="$2"

  local -r out_dir="$configs_abs/prividium-${instance_num}/grafana/datasources"
  mkdir -p "$out_dir"
  cat > "$out_dir/prometheus.yml" <<EOF
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    url: http://prometheus-${chain_id}:9090
    access: proxy
    isDefault: true
EOF
  log "Generated $out_dir/prometheus.yml"
}

# ── per-instance deps compose file (zksyncos, keycloak, block-explorer) ───────
generate_prividium_deps() {
  local -r instance_num="$1"
  local -r chain_id=$(( BASE_CHAIN_ID + instance_num ))
  local -r offset=$(( (instance_num - 1) * PORT_STRIDE ))

  local -r p_zksyncos=$(( 5050 + offset ))
  local -r p_api=$(( 8000 + offset ))
  local -r p_keycloak=$(( 5080 + offset ))
  local -r p_explorer_app=$(( 3010 + offset ))
  local -r p_explorer_api=$(( 3002 + offset ))
  local -r p_data_fetcher=$(( 3040 + offset ))
  local -r p_prometheus=$(( 9090 + offset ))
  local -r p_grafana=$(( 3100 + offset ))
  local -r p_webhook_api=$(( 8080 + offset ))
  local -r p_webhook_int=$(( 8081 + offset ))
  local -r p_bundler=$(( 4337 + offset ))
  local -r p_admin=$(( 3000 + offset ))
  local -r p_user=$(( 3001 + offset ))
  # Internal port must match what generate-chain-configs.sh writes: 3049 + chain_num
  local -r zksyncos_int_port=$(( 3049 + instance_num ))

  local -r s="${chain_id}"
  local -r kc_host="http://localhost:${p_keycloak}"

  local -r rel_inst="${rel_configs}/prividium-${instance_num}"

  local -r out="$output_dir/docker-compose.${chain_id}.deps.yml"

  cat > "$out" <<EOF
# Auto-generated by $SCRIPT_NAME — do not edit manually.
# Backend deps for Prividium instance chain ID: $chain_id
# (zksyncos sequencer, keycloak, block explorer)
# Included by docker-compose.${chain_id}.yml via the include: directive.
name: zksync-prividiums

include:
  - docker-compose.l1.yml

services:

  # ── zksyncos sequencer ───────────────────────────────────────────────────────
  zksyncos-${s}:
    image: $server_image
    platform: linux/amd64
    ports:
      - '${p_zksyncos}:${zksyncos_int_port}'
    environment:
      GENERAL_L1_RPC_URL: 'http://l1:5010'
    user: 'root'
    working_dir: '/app'
    entrypoint: ''
    command: ['/usr/bin/tini', '--', 'zksync-os-server', '--config', '/configs/chain_${chain_id}.yaml']
    volumes:
      - zksyncos_${s}_db:/db
      - ${rel_inst}/zksyncos/chain_${chain_id}.yaml:/configs/chain_${chain_id}.yaml:ro
      - ${rel_configs}/l1/genesis.json:/app/local-chains/${version}/genesis.json:ro
    depends_on:
      l1:
        condition: service_healthy
    healthcheck:
      test: ['CMD', '/usr/bin/bash', '-c', 'exec 3<>/dev/tcp/127.0.0.1/${zksyncos_int_port}']
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s

  # ── keycloak ────────────────────────────────────────────────────────────────
  keycloak-${s}:
    image: quay.io/keycloak/keycloak:26.0
    ports:
      - '${p_keycloak}:8080'
    environment:
      KEYCLOAK_ADMIN: admin
      KEYCLOAK_ADMIN_PASSWORD: admin
      KC_HTTP_RELATIVE_PATH: /
      KC_HEALTH_ENABLED: 'true'
      KC_HTTP_ENABLED: 'true'
      KC_HOSTNAME_STRICT: 'false'
      KC_HOSTNAME_STRICT_HTTPS: 'false'
      KC_HOSTNAME_URL: '${kc_host}'
      KC_HOSTNAME_ADMIN_URL: '${kc_host}'
      KC_METRICS_ENABLED: 'true'
    command:
      - start-dev
      - --import-realm
    volumes:
      - ${rel_inst}/keycloak/realm-export.json:/opt/keycloak/data/import/realm-export.json:ro
    healthcheck:
      test: ['CMD-SHELL', 'exec 3<>/dev/tcp/127.0.0.1/8080']
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 60s

  # ── block explorer ───────────────────────────────────────────────────────────
  block-explorer-api-${s}:
    image: ghcr.io/matter-labs/block-explorer-api:latest
    platform: linux/amd64
    extra_hosts:
      - 'host.docker.internal:host-gateway'
    environment:
      LOG_LEVEL: verbose
      NODE_ENV: development
      DATABASE_HOST: postgres
      DATABASE_NAME: prividium_block_explorer_${chain_id}
      DATABASE_USER: postgres
      DATABASE_PASSWORD: postgres
      DATABASE_ENABLE_SSL: 'false'
      NETWORK_NAME: testnet
      PRIVIDIUM: 'true'
      PRIVIDIUM_APP_URL: http://localhost:${p_explorer_app}
      PRIVIDIUM_PERMISSIONS_API_URL: http://host.docker.internal:${p_api}
      PRIVIDIUM_SESSION_SECRET: QkxPQ0tfRVhQTE9SRVJfU0VTU0lPTl9TRUNSRVQ=
      PRIVIDIUM_SESSION_MAX_AGE: 86400000
      PRIVIDIUM_SESSION_SAME_SITE: strict
      LIMITED_PAGINATION_MAX_ITEMS: '10000'
      API_LIMITED_PAGINATION_MAX_ITEMS: '1000'
      DISABLE_BFF_API_SCHEMA_DOCS: 'true'
    ports:
      - '${p_explorer_api}:3000'
    depends_on:
      postgres:
        condition: service_healthy

  block-explorer-data-fetcher-${s}:
    image: ghcr.io/matter-labs/block-explorer-data-fetcher:latest
    platform: linux/amd64
    extra_hosts:
      - 'host.docker.internal:host-gateway'
    environment:
      NETWORK_NAME: testnet
      BLOCKCHAIN_RPC_URL: http://zksyncos-${s}:${zksyncos_int_port}
      PRIVIDIUM: 'true'
      PRIVIDIUM_PERMISSIONS_API_URL: http://host.docker.internal:${p_api}/api
    ports:
      - '${p_data_fetcher}:3040'

  block-explorer-worker-${s}:
    image: ghcr.io/matter-labs/block-explorer-worker:latest
    platform: linux/amd64
    extra_hosts:
      - 'host.docker.internal:host-gateway'
    environment:
      DATABASE_HOST: postgres
      DATABASE_NAME: prividium_block_explorer_${chain_id}
      DATABASE_USER: postgres
      DATABASE_PASSWORD: postgres
      DATABASE_ENABLE_SSL: 'false'
      NETWORK_NAME: testnet
      BLOCKCHAIN_RPC_URL: http://zksyncos-${s}:${zksyncos_int_port}
      DATA_FETCHER_URL: http://block-explorer-data-fetcher-${s}:3040
      PRIVIDIUM: 'true'
      PRIVIDIUM_PERMISSIONS_API_URL: http://host.docker.internal:${p_api}/api
      ENABLE_TOKEN_OFFCHAIN_DATA_SAVER: 'true'
      BLOCKS_PROCESSING_BATCH_SIZE: '10'
      NUMBER_OF_BLOCKS_PER_DB_TRANSACTION: '10'
    depends_on:
      postgres:
        condition: service_healthy
      block-explorer-data-fetcher-${s}:
        condition: service_started

  block-explorer-app-${s}:
    image: ghcr.io/matter-labs/block-explorer-app:latest
    platform: linux/amd64
    volumes:
      - ${rel_inst}/block-explorer/block-explorer-config.js:/usr/share/nginx/html/config.js:ro
    ports:
      - '${p_explorer_app}:3010'
    depends_on:
      block-explorer-api-${s}:
        condition: service_started

  # ── prometheus ───────────────────────────────────────────────────────────────
  prometheus-${s}:
    image: prom/prometheus:v2.48.0
    restart: unless-stopped
    ports:
      - '${p_prometheus}:9090'
    extra_hosts:
      - 'host.docker.internal:host-gateway'
    volumes:
      - ${rel_inst}/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_${s}_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
      - '--storage.tsdb.retention.time=200h'
      - '--web.enable-lifecycle'
    healthcheck:
      test: ['CMD', 'wget', '--quiet', '--tries=1', '--spider', 'http://localhost:9090/-/healthy']
      interval: 10s
      timeout: 5s
      retries: 5

  # ── grafana ───────────────────────────────────────────────────────────────────
  grafana-${s}:
    image: grafana/grafana:10.2.0
    restart: unless-stopped
    ports:
      - '${p_grafana}:3000'
    volumes:
      - grafana_${s}_data:/var/lib/grafana
      - ${rel_inst}/grafana/datasources:/etc/grafana/provisioning/datasources:ro
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_SERVER_ROOT_URL=http://localhost:${p_grafana}
    depends_on:
      - prometheus-${s}
    healthcheck:
      test: ['CMD-SHELL', 'wget --quiet --tries=1 --spider http://localhost:3000/api/health || exit 1']
      interval: 10s
      timeout: 5s
      retries: 5

  # ── webhook ───────────────────────────────────────────────────────────────────
  zksync-webhook-db-${s}:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: password
      POSTGRES_DB: zksync_webhook_db
    volumes:
      - zksync_webhook_db_${s}_data:/var/lib/postgresql/data
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U postgres -d zksync_webhook_db']
      interval: 5s
      timeout: 5s
      retries: 10

  zksync-webhook-service-${s}:
    image: quay.io/matterlabs_enterprise/webhook-service:v0.1.19
    platform: linux/amd64
    init: true
    restart: unless-stopped
    depends_on:
      zksync-webhook-db-${s}:
        condition: service_healthy
    environment:
      DATABASE_HOST: zksync-webhook-db-${s}
      DATABASE_PORT: '5432'
      DATABASE_NAME: zksync_webhook_db
      DATABASE_USER: postgres
      DATABASE_PASSWORD: password
      DATABASE_ENABLE_SSL: 'false'
      DATABASE_SSL_REJECT_UNAUTHORIZED: 'true'
      ZKSYNC_WEBHOOK_CONFIG: /app/config/config.prividium.local.toml
      RUST_LOG: info
      ENCRYPTION_KEY: a40c350fed393623dfaa54d93d96addcbf8ae845e4f1b6eeaeb444aa3645e800
      ENCRYPTION_KDF_SALT: zksync-webhook-service:keycipher:v2
      PRIVIDIUM_SIGNER_KEY: ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
      PRIVIDIUM_RPC_URL: http://host.docker.internal:${p_zksyncos}
      PRIVIDIUM_PERMISSIONS_API: http://host.docker.internal:${p_api}
      PRIVIDIUM_SIWE_DOMAIN: http://host.docker.internal:${p_admin}
      ZKSYNC_WEBHOOK_API_CORS_ALLOW_ORIGIN: http://localhost:${p_admin}
      ZKSYNC_WEBHOOK_ALLOW_HTTP_LOCALHOST: 'true'
    extra_hosts:
      - 'host.docker.internal:host-gateway'
    ports:
      - '${p_webhook_api}:8080'
      - '${p_webhook_int}:8081'

  # ── bundler (ERC-4337) ────────────────────────────────────────────────────────
  bridge-funds-${s}:
    image: node:22-slim
    working_dir: /app
    volumes:
      - ${rel_configs}/bundler/contracts:/app
      - bridge_funds_${s}_node_modules:/app/node_modules
    environment:
      L1_RPC_URL: http://l1:5010
      L2_RPC_URL: http://zksyncos-${s}:${zksyncos_int_port}
      PRIVATE_KEY: '0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba'
    command: sh -c "corepack enable && pnpm install && pnpm tsx scripts/bridge-funds.ts"
    depends_on:
      zksyncos-${s}:
        condition: service_healthy

  entrypoint-deployer-${s}:
    image: ${foundry_image}
    entrypoint: ''
    user: 'root'
    volumes:
      - ${rel_configs}/bundler/contracts/entrypoint:/app
    working_dir: /app
    extra_hosts:
      - 'host.docker.internal:host-gateway'
    environment:
      RPC_URL: http://zksyncos-${s}:${zksyncos_int_port}
      PRIVATE_KEY: '0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba'
    command: >
      sh -c "forge soldeer install && ./script/deploy.sh"
    depends_on:
      bridge-funds-${s}:
        condition: service_completed_successfully

  bundler-${s}:
    image: quay.io/matterlabs_enterprise/prividium-bundler:${prividium_version}
    platform: linux/amd64
    restart: unless-stopped
    ports:
      - '${p_bundler}:4337'
    environment:
      BUNDLER_PORT: '4337'
      SEQUENCER_RPC_URL: http://zksyncos-${s}:${zksyncos_int_port}
      BUNDLER_EXECUTOR_PRIVATE_KEYS: '0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba'
      BUNDLER_UTILITY_PRIVATE_KEY: '0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba'
      BUNDLER_ENTRYPOINTS: '0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108'
      BUNDLER_MIN_BALANCE: '0'
      BUNDLER_NETWORK_NAME: 'local'
      BUNDLER_LOG_LEVEL: 'info'
    depends_on:
      entrypoint-deployer-${s}:
        condition: service_completed_successfully

volumes:
  zksyncos_${s}_db:
  prometheus_${s}_data:
  grafana_${s}_data:
  zksync_webhook_db_${s}_data:
  bridge_funds_${s}_node_modules:
EOF
  log "Generated $out"
}

# ── per-instance main compose file (admin-panel, prividium-api, user-panel) ───
generate_prividium_main() {
  local -r instance_num="$1"
  local -r chain_id=$(( BASE_CHAIN_ID + instance_num ))
  local -r offset=$(( (instance_num - 1) * PORT_STRIDE ))

  local -r p_zksyncos=$(( 5050 + offset ))
  local -r zksyncos_int_port=$(( 3049 + instance_num ))
  local -r p_admin=$(( 3000 + offset ))
  local -r p_user=$(( 3001 + offset ))
  local -r p_api=$(( 8000 + offset ))
  local -r p_api_metrics=$(( 9091 + offset ))
  local -r p_keycloak=$(( 5080 + offset ))
  local -r p_explorer_app=$(( 3010 + offset ))
  local -r p_explorer_api=$(( 3002 + offset ))

  local -r s="${chain_id}"
  local -r kc_host="http://localhost:${p_keycloak}"

  local -r out="$output_dir/docker-compose.${chain_id}.yml"

  cat > "$out" <<EOF
# Auto-generated by $SCRIPT_NAME — do not edit manually.
# Prividium instance for chain ID: $chain_id
# Ports: admin=$p_admin user=$p_user api=$p_api keycloak=$p_keycloak zksyncos=$p_zksyncos
#
# Includes docker-compose.${chain_id}.deps.yml (zksyncos, keycloak, block-explorer)
# which in turn includes docker-compose.l1.yml (Anvil L1, shared postgres).
# A single: docker compose -f docker-compose.${chain_id}.yml up
# brings up the full stack.
name: zksync-prividiums

include:
  - docker-compose.${chain_id}.deps.yml

services:

  # ── prividium-api ────────────────────────────────────────────────────────────
  prividium-api-${s}:
    image: quay.io/matterlabs_enterprise/prividium-permissions-api:${prividium_version}
    platform: linux/amd64
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      zksyncos-${s}:
        condition: service_healthy
      bundler-${s}:
        condition: service_started
    ports:
      - '${p_api}:8000'
      - '${p_api_metrics}:9091'
    environment:
      - PORT=8000
      - METRICS_PORT=9091
      - SEQUENCER_RPC_URL=http://zksyncos-${s}:${zksyncos_int_port}
      - DATABASE_URL=postgres://postgres:postgres@postgres:5432/prividium_api_${chain_id}
      - CORS_ORIGIN=http://localhost:${p_admin},http://localhost:${p_user},http://localhost:${p_explorer_app},http://localhost:${p_explorer_api}
      - AUTH_METHODS=oidc,crypto_native
      - NODE_ENV=production
      - SIWE_CHAIN_ID=${chain_id}
      - SIWE_VALID_DOMAINS=localhost:${p_admin},localhost:${p_user},localhost:${p_explorer_app},localhost:${p_explorer_api}
      - SIWE_HMAC_SECRET=aaaaaaaa00000000aaaaaaaa00000000aaaaaaaa00000000aaaaaaaa00000000
      - OIDC_JWKS_URI=http://keycloak-${s}:8080/realms/prividium/protocol/openid-connect/certs
      - OIDC_JWT_AUD=prividium-client
      - OIDC_JWT_ISSUER=${kc_host}/realms/prividium
      - OIDC_ADMIN_SUBS=00000000-0000-0000-0000-000000000001
      - CORS_CACHE_DURATION_MS=600000
      - ADMIN_PANEL_REDIRECT_URLS=http://localhost:${p_admin}/callback
      - BLOCK_EXPLORER_REDIRECT_URLS=http://localhost:${p_explorer_app}/auth/callback
      - WALLETS_API_ENABLED=true
      - WEBAUTHN_RP_NAME=ZKsync Prividium
      - WEBAUTHN_RP_ID=localhost
      - WEBAUTHN_ORIGIN=http://localhost:${p_user}
      - WEBAUTHN_REQUIRE_USER_VERIFICATION=false
      - EXTRA_PUBLIC_CODE_ADDRESSES=0x36615cf349d7f6344891b1e7ca7c72883f5dc049
      - BUNDLER_ENABLED=true
      - BUNDLER_RPC_URL=http://bundler-${s}:4337
      - RATE_LIMIT_ENABLED=true
      - RATE_LIMIT_AUTH_MAX=100
      - RATE_LIMIT_PUBLIC_MAX=300
      - RATE_LIMIT_USER_MAX=300
      - RATE_LIMIT_RPC_MAX=1000
      - RATE_LIMIT_WINDOW_MS=60000

  # ── admin panel ──────────────────────────────────────────────────────────────
  admin-panel-${s}:
    image: quay.io/matterlabs_enterprise/prividium-adminv2:${prividium_version}
    platform: linux/amd64
    restart: unless-stopped
    environment:
      - VITE_PRIVIDIUM_API_URL=http://localhost:${p_api}
      - VITE_USER_PANEL_URL=http://localhost:${p_user}
      - VITE_EXPLORER_URL=http://localhost:${p_explorer_app}
      - PORT=3000
    depends_on:
      - prividium-api-${s}
    ports:
      - '${p_admin}:3000'

  # ── user panel ───────────────────────────────────────────────────────────────
  user-panel-${s}:
    image: quay.io/matterlabs_enterprise/prividium-user-panel:${prividium_version}
    platform: linux/amd64
    restart: unless-stopped
    environment:
      - VITE_OIDC_AUTHORITY=${kc_host}/realms/prividium
      - VITE_OIDC_CLIENT_ID=prividium-client
      - VITE_OIDC_REDIRECT_URI=http://localhost:${p_user}/callback
      - VITE_OIDC_POST_LOGOUT_REDIRECT_URI=http://localhost:${p_user}/login
      - VITE_OIDC_BUTTON_TEXT=Sign in with Keycloak
      - VITE_ADMIN_PANEL_REDIRECT_URI=http://localhost:${p_admin}/callback
      - VITE_AUTH_METHODS=oidc,crypto_native
      - VITE_CHAIN_ID=${chain_id}
      - VITE_CHAIN_NAME=Prividium Local
      - VITE_WALLETS_ENABLED=true
      - VITE_BRIDGING_ENABLED=true
      - VITE_L1_RPC_URL=http://localhost:5010
      - VITE_L1_CHAIN_ID=31337
      - VITE_L1_CHAIN_NAME=Anvil Localhost
      - VITE_PRIVIDIUM_API_URL=http://localhost:${p_api}
      - VITE_EXPLORER_URL=http://localhost:${p_explorer_app}
      - VITE_ADMIN_PANEL_URL=http://localhost:${p_admin}
      - VITE_REOWN_PROJECT_ID=
      - PORT=3000
    depends_on:
      - prividium-api-${s}
    ports:
      - '${p_user}:3000'
EOF
  log "Generated $out"
}

# ── start.sh (thin wrapper — passes args to docker compose) ───────────────────
generate_start_sh() {
  local compose_args=""
  local i chain_id
  for i in $(seq 1 "$count"); do
    chain_id=$(( BASE_CHAIN_ID + i ))
    [[ -n "$compose_args" ]] \
      && compose_args="$compose_args -f docker-compose.${chain_id}.yml" \
      || compose_args="-f docker-compose.${chain_id}.yml"
  done

  local -r out="$output_dir/start.sh"
  cat > "$out" <<EOF
#!/usr/bin/env bash
# Auto-generated — starts all Prividium instances in this directory.
# Usage:  ./start.sh           — runs: docker compose ... up -d
#         ./start.sh down      — tears down
#         ./start.sh logs -f   — follows logs
#         ./start.sh <any docker compose subcommand>
set -euo pipefail
cd "\$(dirname "\$0")"
if [[ \$# -eq 0 ]]; then
  exec docker compose $compose_args up -d
else
  exec docker compose $compose_args "\$@"
fi
EOF
  chmod +x "$out"
  log "Generated $out"
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
  generate_l1

  local i
  for i in $(seq 1 "$count"); do
    local chain_id=$(( BASE_CHAIN_ID + i ))
    local offset=$(( (i - 1) * PORT_STRIDE ))
    generate_keycloak_realm \
      "$i" "$chain_id" \
      "$(( 3000 + offset ))" \
      "$(( 3001 + offset ))" \
      "$(( 3002 + offset ))" \
      "$(( 3010 + offset ))" \
      "$(( 5080 + offset ))"
    generate_explorer_config \
      "$i" "$chain_id" \
      "$(( 3002 + offset ))" \
      "$(( 3010 + offset ))" \
      "$(( 3001 + offset ))" \
      "$(( 8000 + offset ))"
    generate_prometheus_config "$i" "$chain_id" "$(( 9091 + offset ))"
    generate_grafana_config "$i" "$chain_id"
    generate_prividium_deps "$i"
    generate_prividium_main "$i"
  done

  generate_start_sh

  log "Done. $count prividium stack(s) written to: $output_dir"
}

main
