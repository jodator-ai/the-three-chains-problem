#!/usr/bin/env bash
# configure-l2s.sh — Generate a self-contained output directory for N ZKsync OS L2 chains.
#
# All generated files (chain configs, genesis, compose files) land in --output (default: ./out).
# The directory is wiped and recreated on every run.
#
# Settlement modes:
#   default (v30.2 or v31.0)   All chains settle directly to L1 (Anvil).
#   --gateway (v31.0 only)      A gateway chain (506) settles to L1; L2 chains settle
#                               to the gateway via RelayedL2Calldata pubdata mode.
#
# Usage:
#   ./configure-l2s.sh --count=3
#   ./configure-l2s.sh --count=2 --version=v31.0 --gateway
#   ./configure-l2s.sh --count=4 --output=./my-setup
#
# After running, execute the printed docker compose command to start the chains.

set -euo pipefail

# ── constants ─────────────────────────────────────────────────────────────────
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

readonly DEFAULT_VERSION="v30.2"
readonly DEFAULT_SERVER_IMAGE="ghcr.io/matter-labs/zksync-os-server:latest"
readonly DEFAULT_L1_IMAGE="ghcr.io/foundry-rs/foundry:v1.3.4"
readonly DEFAULT_OUTPUT="./out"
readonly BASE_CHAIN_ID=6564
readonly GATEWAY_CHAIN_ID=506
readonly GATEWAY_EXTERNAL_PORT=5049

# Chains 1-4 have pre-configured keys + L1 state for v30.2.
# v31.0 upstream only ships configs for chains 1-2 (6565, 6566).
readonly PREBUILT_MAX_V302=4
readonly PREBUILT_MAX_V310=2

# Upstream raw URLs for v31.0 assets (downloadable on demand; not in the server image)
readonly UPSTREAM_BASE="https://raw.githubusercontent.com/matter-labs/zksync-os-server/main/local-chains"
readonly V310_L1_STATE_URL="$UPSTREAM_BASE/v31.0/l1-state.json.gz"
readonly V310_GENESIS_URL="$UPSTREAM_BASE/v31.0/genesis.json"
readonly V310_GATEWAY_DB_URL="$UPSTREAM_BASE/v31.0/gateway-db.tar.gz"

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

download_file() {
  local -r url="$1"
  local -r dest="$2"
  local -r label="$3"
  info "Downloading $label..."
  if cmd_exists curl; then
    curl -fL --progress-bar "$url" -o "$dest" || die "Download failed: $url"
  elif cmd_exists wget; then
    wget -q --show-progress "$url" -O "$dest" || die "Download failed: $url"
  else
    die "Neither curl nor wget found. Install one to proceed."
  fi
  log "Downloaded → $dest"
}

# ── usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
${BOLD}$SCRIPT_NAME${NC} — Generate a self-contained directory for multiple ZKsync OS L2 chains

All files (chain configs, genesis, compose files) are written to --output.
The output directory is wiped and recreated on every run.

${BOLD}Usage:${NC}
  $SCRIPT_NAME --count=N [options]

${BOLD}Options:${NC}
  --count=N           Number of L2 chains to configure
  --output=DIR        Output directory (default: $DEFAULT_OUTPUT)
  --version=VER       ZKsync OS protocol version: v30.2 | v31.0 (default: $DEFAULT_VERSION)
  --gateway           v31.0 only: run gateway chain (506); L2 chains settle to it
  --force-genesis     Re-download/re-extract genesis.json (and gateway-db.tar.gz)
  --server-image=IMG  Docker image for zksync-os-server (default: latest)
  --help, -h          Show this help message

${BOLD}Settlement modes:${NC}
  v30.2               Chains 1–4 pre-configured; settle to L1.  pubdata: Blobs
  v31.0               Chains 1–2 pre-configured; settle to L1.  pubdata: Blobs
  v31.0 --gateway     Chains 1–2 pre-configured; gateway (506) settles to L1,
                      L2 chains settle to gateway.  pubdata: RelayedL2Calldata

${BOLD}Examples:${NC}
  $SCRIPT_NAME --count=2
  $SCRIPT_NAME --count=4                              # v30.2, 4 chains to L1
  $SCRIPT_NAME --count=2 --version=v31.0 --gateway   # v31.0, gateway mode
  $SCRIPT_NAME --count=2 --output=./my-setup

${BOLD}Chain IDs and Ports:${NC}
  Gateway: ID=506,   RPC → http://localhost:$GATEWAY_EXTERNAL_PORT  (gateway mode only)
  Chain 1: ID=6565,  RPC → http://localhost:5050
  Chain 2: ID=6566,  RPC → http://localhost:5051
  Chain N: ID=$((BASE_CHAIN_ID))+N, RPC → http://localhost:$((5049))+N
  L1:      Chain ID=31337, RPC → http://localhost:5010

EOF
  exit 0
}

# ── argument parsing ──────────────────────────────────────────────────────────
parse_args() {
  local -r _hint="Run $SCRIPT_NAME --help for usage."

  count=""
  output="$DEFAULT_OUTPUT"
  version="$DEFAULT_VERSION"
  gateway=false
  force_genesis=false
  server_image="$DEFAULT_SERVER_IMAGE"
  l1_image="$DEFAULT_L1_IMAGE"

  for arg in "$@"; do
    case "$arg" in
      --count=*)        count="${arg#*=}" ;;
      --output=*)       output="${arg#*=}" ;;
      --version=*)      version="${arg#*=}" ;;
      --gateway)        gateway=true ;;
      --force-genesis)  force_genesis=true ;;
      --server-image=*) server_image="${arg#*=}" ;;
      --help|-h)        usage ;;
      *) die "Unknown argument: $arg. $_hint" ;;
    esac
  done

  [[ -n "$count" ]]    || die "--count=N is required. $_hint"
  is_integer "$count"  || die "--count must be a positive integer."
  [[ "$count" -ge 1 ]] || die "--count must be at least 1."
  [[ "$count" -le 10 ]] || die "--count must be at most 10."

  [[ "$version" == "v30.2" || "$version" == "v31.0" ]] \
    || die "Unsupported version '$version'. Supported: v30.2, v31.0."

  if [[ "$gateway" == true && "$version" != "v31.0" ]]; then
    die "--gateway requires --version=v31.0 (gateway mode was introduced in v31.0)."
  fi
}

# ── step: check genesis requirement ──────────────────────────────────────────
check_genesis_requirement() {
  local -r prebuilt_max="$1"

  [[ "$count" -le "$prebuilt_max" ]] && return 0

  # Check sentinel file written by generate-genesis.sh --docker
  local sentinel="$SCRIPT_DIR/configs/$version/genesis-max-count"
  local generated_count=0
  if [[ -f "$sentinel" ]]; then
    generated_count="$(cat "$sentinel" 2>/dev/null || echo 0)"
  fi

  local chains_needing_genesis=()
  local i
  for i in $(seq 1 "$count"); do
    if [[ "$i" -gt "$prebuilt_max" ]]; then
      chains_needing_genesis+=("$(( BASE_CHAIN_ID + i ))")
    fi
  done

  if [[ "$generated_count" -lt "$count" ]]; then
    warn "Chains ${chains_needing_genesis[*]} are not pre-configured for $version."
    echo ""
    echo -e "They need L1 contract deployment via genesis generation."
    echo -e "Run (Docker required):"
    echo ""
    echo -e "  ${BOLD}./scripts/generate-genesis.sh --docker --count=$count${NC}"
    echo ""
    echo "Then re-run this command."
    exit 1
  fi
}

# ── step: ensure l1-state.json.gz ────────────────────────────────────────────
# v30.2: tracked in repo (custom L1 state with 4 chains registered via state surgery)
# v31.0: downloaded from upstream on first run; cached in configs/v31.0/
ensure_l1_state() {
  local -r dest="$1"
  mkdir -p "$(dirname "$dest")"

  if [[ "$version" == "v30.2" ]]; then
    local -r src="$SCRIPT_DIR/configs/v30.2/l1-state.json.gz"
    file_exists "$src" \
      || die "L1 state not found: $src — the v30.2 l1-state.json.gz must be present in the repo."
    cp "$src" "$dest"
    info "Copied l1-state.json.gz → $dest"
    return
  fi

  # v31.0: cache in configs/v31.0/, then copy to output
  local -r cache="$SCRIPT_DIR/configs/v31.0/l1-state.json.gz"
  mkdir -p "$SCRIPT_DIR/configs/v31.0"
  if ! file_exists "$cache"; then
    download_file "$V310_L1_STATE_URL" "$cache" "v31.0 l1-state.json.gz (~23 MB)"
  fi
  cp "$cache" "$dest"
  info "Copied l1-state.json.gz → $dest"
}

# ── step: generate chain configs ──────────────────────────────────────────────
generate_chain_configs() {
  local -r out_dir="$1"
  info "Generating chain config files..."
  local gateway_flag=""
  [[ "$gateway" == true ]] && gateway_flag="--gateway"

  "$SCRIPT_DIR/scripts/generate-chain-configs.sh" \
    --count="$count" \
    --output-dir="$out_dir" \
    --version="$version" \
    ${gateway_flag:+"$gateway_flag"}
}

# ── step: ensure genesis.json ─────────────────────────────────────────────────
# v30.2: extracted from the server Docker image
# v31.0: downloaded from upstream (newer images don't ship local-chains/)
ensure_genesis_json() {
  local -r dest="$1"
  mkdir -p "$(dirname "$dest")"

  if [[ "$version" == "v31.0" ]]; then
    download_file "$V310_GENESIS_URL" "$dest" "v31.0 genesis.json"
    return
  fi

  info "Extracting genesis.json from server image ($version)..."
  docker run --rm \
    --platform linux/amd64 \
    --entrypoint /bin/sh \
    "$server_image" \
    -c "cat /app/local-chains/$version/default/genesis.json" \
    > "$dest" \
    || die "Failed to extract genesis.json from $server_image"
  log "Extracted → $dest"
}

# ── step: ensure gateway-db.tar.gz ───────────────────────────────────────────
# Downloaded from upstream on first run (v31.0 gateway mode only)
ensure_gateway_db() {
  local -r dest="$1"
  mkdir -p "$(dirname "$dest")"
  download_file "$V310_GATEWAY_DB_URL" "$dest" "v31.0 gateway-db.tar.gz (~1.4 MB)"
}

# ── step: generate compose files ─────────────────────────────────────────────
generate_compose_files() {
  local -r out_dir="$1"
  local -r dev_dir="$2"
  local gateway_flag=""
  [[ "$gateway" == true ]] && gateway_flag="--gateway"

  info "Generating composable docker-compose files..."
  "$SCRIPT_DIR/scripts/generate-compose.sh" \
    --count="$count" \
    --output-dir="$out_dir" \
    --configs-dir="$dev_dir" \
    --version="$version" \
    --server-image="$server_image" \
    --l1-image="$l1_image" \
    ${gateway_flag:+"$gateway_flag"}
}

# ── step: print summary ───────────────────────────────────────────────────────
print_summary() {
  local -r out_dir="$1"
  local compose_args="-f docker-compose.l1.yml"

  if [[ "$gateway" == true ]]; then
    echo "  Gateway:  ID=$GATEWAY_CHAIN_ID  RPC → http://localhost:$GATEWAY_EXTERNAL_PORT  (settles to L1)"
    compose_args="$compose_args -f docker-compose.${GATEWAY_CHAIN_ID}.yml"
  fi

  local i chain_id ext_port
  for i in $(seq 1 "$count"); do
    chain_id=$(( BASE_CHAIN_ID + i ))
    ext_port=$(( 5049 + i ))
    local settle_label="→ L1"
    [[ "$gateway" == true ]] && settle_label="→ gateway-$GATEWAY_CHAIN_ID"
    echo "  Chain $i:  ID=$chain_id  RPC → http://localhost:$ext_port  (settles $settle_label)"
    compose_args="$compose_args -f docker-compose.${chain_id}.yml"
  done

  echo ""
  echo -e "${BOLD}L1 (Anvil):${NC} http://localhost:5010  (chain ID: 31337)"
  echo ""
  echo -e "${BOLD}To start:${NC}"
  echo ""
  echo -e "  ${BOLD}cd $out_dir${NC}"
  echo -e "  ${BOLD}docker compose $compose_args up -d${NC}"
  echo ""
  echo -e "${BOLD}To stop:${NC}"
  echo ""
  echo -e "  ${BOLD}cd $out_dir${NC}"
  echo -e "  ${BOLD}docker compose $compose_args down${NC}"
  echo ""
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"

  local -r prebuilt_max="$( [[ "$version" == "v31.0" ]] && echo "$PREBUILT_MAX_V310" || echo "$PREBUILT_MAX_V302" )"

  # Clean and recreate the output directory
  rm -rf "$output"
  mkdir -p "$output"
  local -r out_dir="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$output")"
  local -r dev_dir="$out_dir/dev"
  mkdir -p "$dev_dir"

  local mode_label="$version, L1 settlement"
  [[ "$gateway" == true ]] && mode_label="$version, gateway mode"
  log "Configuring $count L2 chain(s) [$mode_label] → $out_dir"
  echo ""

  check_genesis_requirement "$prebuilt_max"
  ensure_l1_state "$dev_dir/l1/l1-state.json.gz"
  generate_chain_configs "$dev_dir"
  # Move each chain config into its own per-chain subdir
  local i chain_id
  for i in $(seq 1 "$count"); do
    chain_id=$(( BASE_CHAIN_ID + i ))
    mkdir -p "$dev_dir/$chain_id"
    mv "$dev_dir/chain_${chain_id}.yaml" "$dev_dir/$chain_id/"
  done
  if [[ "$gateway" == true ]]; then
    mkdir -p "$dev_dir/$GATEWAY_CHAIN_ID"
    mv "$dev_dir/chain_${GATEWAY_CHAIN_ID}.yaml" "$dev_dir/$GATEWAY_CHAIN_ID/"
  fi
  ensure_genesis_json "$dev_dir/l1/genesis.json"
  [[ "$gateway" == true ]] && ensure_gateway_db "$dev_dir/l1/gateway-db.tar.gz"
  generate_compose_files "$out_dir" "$dev_dir"

  echo ""
  echo -e "${GREEN}${BOLD}✓ Configuration complete!${NC}"
  echo ""
  echo -e "${BOLD}Generated files in $out_dir:${NC}"
  print_summary "$out_dir"
}

main "$@"
