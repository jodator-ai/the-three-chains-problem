#!/usr/bin/env bash
# configure-prividiums.sh — Generate a self-contained output directory for N Prividium instances.
#
# Each instance is a full Prividium stack (zksyncos sequencer, postgres, keycloak,
# prividium-api, admin panel, user panel, block explorer) all sharing a single L1 (Anvil).
# All generated files (chain configs, genesis, keycloak realm, compose files) land in --output.
# The output directory is wiped and recreated on every run.
#
# Usage:
#   ./configure-prividiums.sh --count=2
#   ./configure-prividiums.sh --count=1 --output=./my-prividium
#
# Requires quay.io access for enterprise Prividium images.
# See: https://github.com/matter-labs/local-prividium

set -euo pipefail

# ── constants ─────────────────────────────────────────────────────────────────
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

readonly DEFAULT_VERSION="v30.2"
readonly DEFAULT_SERVER_IMAGE="ghcr.io/matter-labs/zksync-os-server:latest"
readonly DEFAULT_L1_IMAGE="ghcr.io/foundry-rs/foundry:v1.3.4"
readonly DEFAULT_PRIVIDIUM_VERSION="v1.153.1"
readonly DEFAULT_OUTPUT="./out"
readonly BASE_CHAIN_ID=6564
readonly PORT_STRIDE=200

# Chains 1-4 have pre-configured keys + L1 state; chains 5+ require genesis generation.
readonly PREBUILT_MAX=4

# Upstream URL for the keycloak realm configuration
readonly KEYCLOAK_REALM_URL="https://raw.githubusercontent.com/matter-labs/local-prividium/main/dev/keycloak/realm-export.json"

# ── colours ───────────────────────────────────────────────────────────────────
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# ── helpers ───────────────────────────────────────────────────────────────────
die()         { echo -e "${RED}[$SCRIPT_NAME] ERROR:${NC} $*" >&2; exit 1; }
log()         { echo -e "${GREEN}[$SCRIPT_NAME]${NC} $*"; }
warn()        { echo -e "${YELLOW}[$SCRIPT_NAME]${NC} $*"; }
info()        { echo -e "${BLUE}[$SCRIPT_NAME]${NC} $*"; }
is_integer()  { [[ "$1" =~ ^[0-9]+$ ]]; }
file_exists() { [[ -f "$1" ]]; }
cmd_exists()  { command -v "$1" &>/dev/null; }

# ── usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
${BOLD}$SCRIPT_NAME${NC} — Generate a self-contained directory for multiple Prividium instances

Each instance is a complete Prividium stack sharing a single L1 (Anvil):
  zksyncos sequencer, postgres, keycloak, prividium-api, admin panel, user panel, block explorer

All files (chain configs, genesis, keycloak realm, compose files) are written to --output.
The output directory is wiped and recreated on every run.

${BOLD}Usage:${NC}
  $SCRIPT_NAME --count=N [options]

${BOLD}Options:${NC}
  --count=N                Number of Prividium instances (1–$PREBUILT_MAX pre-configured)
  --output=DIR             Output directory (default: $DEFAULT_OUTPUT)
  --version=VER            ZKsync OS protocol version (default: $DEFAULT_VERSION)
  --server-image=IMG       zksync-os-server image (default: latest)
  --prividium-version=V    Prividium image tag (default: $DEFAULT_PRIVIDIUM_VERSION)
  --help, -h               Show this help message

${BOLD}Port layout per instance N (stride: $PORT_STRIDE):${NC}
  Instance 1: admin=3000 user=3001 api=8000 keycloak=5080 zksyncos=5050 explorer=3010 postgres=5432
  Instance 2: admin=3200 user=3201 api=8200 keycloak=5280 zksyncos=5250 explorer=3210 postgres=5632
  Instance N: each port = base + (N-1)*$PORT_STRIDE

${BOLD}Prerequisites:${NC}
  - Docker login to quay.io (for enterprise Prividium images):
      docker login quay.io

${BOLD}Examples:${NC}
  $SCRIPT_NAME --count=1    # Single Prividium (matches local-prividium defaults)
  $SCRIPT_NAME --count=3    # Three independent Prividium instances

EOF
  exit 0
}

# ── argument parsing ──────────────────────────────────────────────────────────
parse_args() {
  local -r _usage_hint="Run $SCRIPT_NAME --help for usage."

  count=""
  output="$DEFAULT_OUTPUT"
  version="$DEFAULT_VERSION"
  server_image="$DEFAULT_SERVER_IMAGE"
  l1_image="$DEFAULT_L1_IMAGE"
  prividium_version="$DEFAULT_PRIVIDIUM_VERSION"

  for arg in "$@"; do
    case "$arg" in
      --count=*)               count="${arg#*=}" ;;
      --output=*)              output="${arg#*=}" ;;
      --version=*)             version="${arg#*=}" ;;
      --server-image=*)        server_image="${arg#*=}" ;;
      --prividium-version=*)   prividium_version="${arg#*=}" ;;
      --help|-h)               usage ;;
      *) die "Unknown argument: $arg. $_usage_hint" ;;
    esac
  done

  [[ -n "$count" ]]    || die "--count=N is required. $_usage_hint"
  is_integer "$count"  || die "--count must be a positive integer."
  [[ "$count" -ge 1 ]] || die "--count must be at least 1."
  [[ "$count" -le "$PREBUILT_MAX" ]] \
    || die "--count must be at most $PREBUILT_MAX (chains 5+ require genesis generation — run ./scripts/generate-genesis.sh first)."
}

# ── step: copy l1-state ───────────────────────────────────────────────────────
copy_l1_state() {
  local -r dest="$1"
  mkdir -p "$(dirname "$dest")"
  local -r src="$SCRIPT_DIR/configs/$version/l1-state.json.gz"
  file_exists "$src" \
    || die "L1 state not found: $src — ensure configs/$version/l1-state.json.gz is present in the repo."
  cp "$src" "$dest"
  info "Copied l1-state.json.gz → $dest"
}

# ── step: generate chain configs ──────────────────────────────────────────────
generate_chain_configs() {
  local -r out_dir="$1"
  info "Generating chain config files..."
  "$SCRIPT_DIR/scripts/generate-chain-configs.sh" \
    --count="$count" \
    --output-dir="$out_dir" \
    --version="$version"
}

# ── step: extract genesis.json ────────────────────────────────────────────────
ensure_genesis_json() {
  local -r dest="$1"
  mkdir -p "$(dirname "$dest")"
  info "Extracting genesis.json from zksync-os-server image..."
  docker run --rm \
    --platform linux/amd64 \
    --entrypoint /bin/sh \
    "$server_image" \
    -c "cat /app/local-chains/$version/default/genesis.json" \
    > "$dest" \
    || die "Failed to extract genesis.json from image $server_image"
  log "Extracted genesis.json → $dest"
}

# ── step: download keycloak realm ─────────────────────────────────────────────
download_keycloak_realm() {
  local -r dest="$1"
  mkdir -p "$(dirname "$dest")"
  info "Downloading Keycloak realm config from local-prividium..."

  if cmd_exists curl; then
    curl -fsSL "$KEYCLOAK_REALM_URL" -o "$dest" \
      || die "Failed to download keycloak realm from $KEYCLOAK_REALM_URL"
  elif cmd_exists wget; then
    wget -qO "$dest" "$KEYCLOAK_REALM_URL" \
      || die "Failed to download keycloak realm from $KEYCLOAK_REALM_URL"
  else
    die "Neither curl nor wget found. Install one to proceed."
  fi

  log "Downloaded realm-export.json → $dest"
}

# ── step: generate compose files ─────────────────────────────────────────────
generate_compose_files() {
  local -r out_dir="$1"
  local -r dev_dir="$2"
  info "Generating composable docker-compose files..."
  "$SCRIPT_DIR/scripts/generate-prividium-compose.sh" \
    --count="$count" \
    --output-dir="$out_dir" \
    --configs-dir="$dev_dir" \
    --version="$version" \
    --server-image="$server_image" \
    --l1-image="$l1_image" \
    --prividium-version="$prividium_version"
}

# ── step: print summary ───────────────────────────────────────────────────────
print_summary() {
  local -r out_dir="$1"
  local compose_args
  compose_args=""

  local i chain_id offset
  for i in $(seq 1 "$count"); do
    chain_id=$(( BASE_CHAIN_ID + i ))
    offset=$(( (i - 1) * PORT_STRIDE ))
    echo "  Instance $i (chain $chain_id):"
    echo "    Admin Panel   → http://localhost:$(( 3000 + offset ))"
    echo "    User Panel    → http://localhost:$(( 3001 + offset ))"
    echo "    Prividium API → http://localhost:$(( 8000 + offset ))"
    echo "    Block Explorer→ http://localhost:$(( 3010 + offset ))"
    echo "    zkSync RPC    → http://localhost:$(( 5050 + offset ))"
    echo "    Keycloak      → http://localhost:$(( 5080 + offset ))"
    [[ -n "$compose_args" ]] && compose_args="$compose_args -f docker-compose.${chain_id}.yml" \
                              || compose_args="-f docker-compose.${chain_id}.yml"
  done

  echo ""
  echo -e "${BOLD}L1 (Anvil):${NC} http://localhost:5010  (chain ID: 31337)"
  echo ""
  echo -e "${YELLOW}Note:${NC} Prividium images require quay.io login:"
  echo -e "  ${BOLD}docker login quay.io${NC}"
  echo ""
  echo -e "${BOLD}To start:${NC}"
  echo ""
  echo -e "  ${BOLD}cd $out_dir && ./start.sh${NC}"
  echo ""
  echo -e "${BOLD}Or using docker compose directly:${NC}"
  echo ""
  echo -e "  ${BOLD}cd $out_dir${NC}"
  echo -e "  ${BOLD}docker compose $compose_args up -d${NC}"
  echo ""
  echo -e "${BOLD}To view logs:${NC}"
  echo ""
  echo -e "  ${BOLD}cd $out_dir && ./start.sh logs -f${NC}"
  echo ""
  echo -e "${BOLD}To stop:${NC}"
  echo ""
  echo -e "  ${BOLD}cd $out_dir && ./start.sh down${NC}"
  echo ""
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"

  # Clean and recreate the output directory
  rm -rf "$output"
  mkdir -p "$output"
  local -r out_dir="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$output")"
  local -r dev_dir="$out_dir/dev"
  mkdir -p "$dev_dir"

  log "Configuring $count Prividium instance(s) for ZKsync OS $version → $out_dir"
  echo ""

  copy_l1_state "$dev_dir/l1/l1-state.json.gz"
  generate_chain_configs "$dev_dir"
  # Move each chain config into its own per-chain subdir
  local i chain_id
  for i in $(seq 1 "$count"); do
    chain_id=$(( BASE_CHAIN_ID + i ))
    mkdir -p "$dev_dir/$chain_id"
    mv "$dev_dir/chain_${chain_id}.yaml" "$dev_dir/$chain_id/"
  done
  ensure_genesis_json "$dev_dir/l1/genesis.json"
  download_keycloak_realm "$dev_dir/keycloak/realm-export.json"
  generate_compose_files "$out_dir" "$dev_dir"

  echo ""
  echo -e "${GREEN}${BOLD}✓ Configuration complete!${NC}"
  echo ""
  echo -e "${BOLD}Generated files in $out_dir:${NC}"
  print_summary "$out_dir"
}

main "$@"
