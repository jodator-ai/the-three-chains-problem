#!/usr/bin/env bash
# configure-l2s.sh — Generate composable Docker Compose files for N ZKsync OS L2 chains.
#
# Usage:
#   ./configure-l2s.sh --count=3
#   ./configure-l2s.sh --count=4 --output-dir=./my-setup
#
# After running, execute the printed docker compose command to start the chains.

set -euo pipefail

# ── constants ─────────────────────────────────────────────────────────────────
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

readonly DEFAULT_VERSION="v30.2"
readonly DEFAULT_SERVER_IMAGE="ghcr.io/matter-labs/zksync-os-server:latest"
readonly DEFAULT_L1_IMAGE="ghcr.io/foundry-rs/foundry:v1.3.4"
readonly DEFAULT_OUTPUT_DIR="./generated"
readonly BASE_CHAIN_ID=6564

# Chains 1-4 have pre-configured keys + L1 state; chains 5+ require genesis generation.
readonly PREBUILT_MAX=4

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

# ── usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
${BOLD}$SCRIPT_NAME${NC} — Generate composable Docker Compose files for multiple ZKsync OS L2 chains

${BOLD}Usage:${NC}
  $SCRIPT_NAME --count=N [options]

${BOLD}Options:${NC}
  --count=N           Number of L2 chains to configure (1–$PREBUILT_MAX pre-configured; 5–8 require genesis)
  --output-dir=DIR    Directory to write generated compose files (default: $DEFAULT_OUTPUT_DIR)
  --force-genesis     Force regeneration of genesis.json even if it exists
  --version=VER       ZKsync OS protocol version (default: $DEFAULT_VERSION)
  --server-image=IMG  Docker image for zksync-os-server (default: latest)
  --help, -h          Show this help message

${BOLD}Examples:${NC}
  $SCRIPT_NAME --count=2
  $SCRIPT_NAME --count=4
  $SCRIPT_NAME --count=4 --output-dir=./my-setup

${BOLD}Chain IDs and Ports:${NC}
  Chain 1: ID=6565, RPC → http://localhost:5050
  Chain 2: ID=6566, RPC → http://localhost:5051
  Chain N: ID=$((BASE_CHAIN_ID))+N, RPC → http://localhost:$((5049))+N
  L1:      Chain ID=31337, RPC → http://localhost:5010

EOF
  exit 0
}

# ── argument parsing ──────────────────────────────────────────────────────────
parse_args() {
  local -r _usage_hint="Run $SCRIPT_NAME --help for usage."

  count=""
  output_dir="$DEFAULT_OUTPUT_DIR"
  force_genesis=false
  version="$DEFAULT_VERSION"
  server_image="$DEFAULT_SERVER_IMAGE"
  l1_image="$DEFAULT_L1_IMAGE"

  for arg in "$@"; do
    case "$arg" in
      --count=*)        count="${arg#*=}" ;;
      --output-dir=*)   output_dir="${arg#*=}" ;;
      --force-genesis)  force_genesis=true ;;
      --version=*)      version="${arg#*=}" ;;
      --server-image=*) server_image="${arg#*=}" ;;
      --help|-h)        usage ;;
      *) die "Unknown argument: $arg. $_usage_hint" ;;
    esac
  done

  [[ -n "$count" ]]    || die "--count=N is required. $_usage_hint"
  is_integer "$count"  || die "--count must be a positive integer."
  [[ "$count" -ge 1 ]] || die "--count must be at least 1."
  [[ "$count" -le 8 ]] || die "--count must be at most 8."
}

# ── step: check genesis requirement ──────────────────────────────────────────
check_genesis_requirement() {
  local chains_needing_genesis=()

  local i
  for i in $(seq 1 "$count"); do
    if [[ "$i" -gt "$PREBUILT_MAX" ]]; then
      chains_needing_genesis+=("$(( BASE_CHAIN_ID + i ))")
    fi
  done

  if [[ ${#chains_needing_genesis[@]} -gt 0 ]]; then
    echo ""
    warn "Chains ${chains_needing_genesis[*]} require genesis generation (chains 5+)."
    echo ""
    echo -e "These chains need L1 contract deployment. Run one of the following:"
    echo ""
    echo -e "  ${BOLD}Docker (recommended — no local tools needed, ~30min first run):${NC}"
    echo -e "  ./scripts/generate-genesis.sh --docker --count=$count"
    echo ""
    echo -e "  ${BOLD}Local (requires Rust, yarn, foundry — see README):${NC}"
    echo -e "  ./scripts/generate-genesis.sh --count=$count"
    echo ""
    echo "After genesis generation, re-run:"
    echo -e "  ${BOLD}./$SCRIPT_NAME --count=$count${NC}"
    echo ""
    exit 1
  fi
}

# ── step: verify l1-state ─────────────────────────────────────────────────────
verify_l1_state() {
  local -r l1_state="$1"
  file_exists "$l1_state" \
    || die "L1 state not found: $l1_state — ensure configs/$version/l1-state.json.gz is present in the repo."
}

# ── step: generate chain configs ──────────────────────────────────────────────
generate_chain_configs() {
  local -r configs_dir="$1"
  info "Generating chain config files..."
  "$SCRIPT_DIR/scripts/generate-chain-configs.sh" \
    --count="$count" \
    --output-dir="$configs_dir" \
    --version="$version"
}

# ── step: ensure genesis.json ─────────────────────────────────────────────────
ensure_genesis_json() {
  local -r genesis_file="$1"

  if file_exists "$genesis_file" && [[ "$force_genesis" != true ]]; then
    info "genesis.json already present — skipping extraction (use --force-genesis to redo)."
    return
  fi

  info "Extracting genesis.json from zksync-os-server image..."
  docker run --rm \
    --entrypoint /bin/sh \
    "$server_image" \
    -c "cat /app/local-chains/$version/genesis.json" \
    > "$genesis_file" \
    || die "Failed to extract genesis.json from image $server_image"
  log "Extracted genesis.json → $genesis_file"
}

# ── step: generate compose files ─────────────────────────────────────────────
generate_compose_files() {
  local -r compose_dir="$1"
  local -r configs_dir="$2"
  info "Generating composable docker-compose files in $compose_dir..."
  "$SCRIPT_DIR/scripts/generate-compose.sh" \
    --count="$count" \
    --output-dir="$compose_dir" \
    --configs-dir="$configs_dir" \
    --version="$version" \
    --server-image="$server_image" \
    --l1-image="$l1_image"
}

# ── step: print summary ───────────────────────────────────────────────────────
print_summary() {
  local -r compose_dir="$1"
  local compose_args="-f $compose_dir/docker-compose.l1.yml"

  local i chain_id ext_port
  for i in $(seq 1 "$count"); do
    chain_id=$(( BASE_CHAIN_ID + i ))
    ext_port=$(( 5049 + i ))
    echo "  Chain $i: ID=$chain_id  RPC → http://localhost:$ext_port"
    compose_args="$compose_args -f $compose_dir/docker-compose.zksyncos-${chain_id}.yml"
  done

  echo ""
  echo -e "${BOLD}L1 (Anvil):${NC} http://localhost:5010  (chain ID: 31337)"
  echo ""
  echo -e "${BOLD}To start:${NC}"
  echo ""
  echo -e "  ${BOLD}docker compose $compose_args up -d${NC}"
  echo ""
  echo -e "${BOLD}To view logs:${NC}"
  echo ""
  echo -e "  ${BOLD}docker compose $compose_args logs -f${NC}"
  echo ""
  echo -e "${BOLD}To stop:${NC}"
  echo ""
  echo -e "  ${BOLD}docker compose $compose_args down${NC}"
  echo ""
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"

  local -r configs_dir="$SCRIPT_DIR/configs/$version"
  local -r compose_dir="$(realpath "$output_dir")"

  mkdir -p "$configs_dir" "$compose_dir"

  log "Configuring $count L2 chain(s) for ZKsync OS $version"
  echo ""

  check_genesis_requirement
  verify_l1_state "$configs_dir/l1-state.json.gz"
  generate_chain_configs "$configs_dir"
  ensure_genesis_json "$configs_dir/genesis.json"
  generate_compose_files "$compose_dir" "$configs_dir"

  echo ""
  echo -e "${GREEN}${BOLD}✓ Configuration complete!${NC}"
  echo ""
  echo -e "${BOLD}Generated files in $compose_dir:${NC}"
  print_summary "$compose_dir"
}

main "$@"
