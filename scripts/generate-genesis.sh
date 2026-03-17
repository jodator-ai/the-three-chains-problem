#!/usr/bin/env bash
# generate-genesis.sh
# Generates genesis state and chain configs for N ZKsync OS L2 chains.
#
# This script wraps the genesis generator (Python, based on zksync-os-scripts fork).
# It can run in two modes:
#   --docker   Use a Docker container (no local tool installation required)
#   (default)  Run locally (requires: Rust, yarn, foundry, Python 3.12+)
#
# The genesis generator is a fork of:
#   https://github.com/matter-labs/zksync-os-scripts
# with added support for arbitrary chain counts.
# Fork: https://github.com/matter-labs/zksync-os-scripts (see genesis/ directory)
#
# Usage:
#   ./scripts/generate-genesis.sh --chains 6567 6568
#   ./scripts/generate-genesis.sh --docker --chains 6567 6568
#   ./scripts/generate-genesis.sh --count=4   # generates for ALL 4 chains

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

CHAINS=()
COUNT=""
USE_DOCKER=false
VERSION="v30.2"
OUTPUT_DIR=""
BASE_CHAIN_ID=6564

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${GREEN}[genesis]${NC} $*"; }
warn()  { echo -e "${YELLOW}[genesis]${NC} $*"; }
error() { echo -e "${RED}[genesis] ERROR:${NC} $*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --chains)   ;;  # handled below
    --chains=*) IFS=',' read -ra CHAINS <<< "${arg#*=}" ;;
    --count=*)  COUNT="${arg#*=}" ;;
    --docker)   USE_DOCKER=true ;;
    --version=*) VERSION="${arg#*=}" ;;
    --output-dir=*) OUTPUT_DIR="${arg#*=}" ;;
    [0-9]*)     CHAINS+=("$arg") ;;  # bare chain IDs
    *) warn "Unknown argument: $arg" ;;
  esac
done

# If --count is given, generate for all N chains
if [[ -n "$COUNT" ]]; then
  CHAINS=()
  for i in $(seq 1 "$COUNT"); do
    CHAINS+=($((BASE_CHAIN_ID + i)))
  done
fi

[[ ${#CHAINS[@]} -eq 0 ]] && error "Specify chains with --chains=6567,6568 or --count=N"

[[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="$REPO_DIR/configs/$VERSION"
mkdir -p "$OUTPUT_DIR"

log "Generating genesis for chains: ${CHAINS[*]}"
log "Output directory: $OUTPUT_DIR"
echo ""

if [[ "$USE_DOCKER" == "true" ]]; then
  # ────────────────────────────────────────────────────────────────
  # Docker mode: build and run the genesis generator container
  # ────────────────────────────────────────────────────────────────
  GENESIS_DIR="$REPO_DIR/genesis"

  if [[ ! -f "$GENESIS_DIR/Dockerfile" ]]; then
    error "Genesis Dockerfile not found at $GENESIS_DIR/Dockerfile"
  fi

  # Build the generator image if not present
  IMAGE_NAME="zksync-genesis-generator:$VERSION"
  if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    log "Building genesis generator Docker image (this may take 20-30 minutes on first run)..."
    docker build \
      --build-arg PROTOCOL_VERSION="$VERSION" \
      -t "$IMAGE_NAME" \
      "$GENESIS_DIR"
  else
    log "Using existing genesis generator image: $IMAGE_NAME"
  fi

  # Run genesis generation
  log "Running genesis generation in Docker..."
  docker run --rm \
    -v "$OUTPUT_DIR:/output" \
    "$IMAGE_NAME" \
    --chain-ids "$(IFS=','; echo "${CHAINS[*]}")" \
    --output /output

  log "Genesis generation complete. Configs written to $OUTPUT_DIR/"

else
  # ────────────────────────────────────────────────────────────────
  # Local mode: run genesis generator Python script directly
  # ────────────────────────────────────────────────────────────────
  GENESIS_SCRIPT="$REPO_DIR/genesis/generate_chains.py"

  if [[ ! -f "$GENESIS_SCRIPT" ]]; then
    error "Genesis script not found at $GENESIS_SCRIPT"
  fi

  # Check required tools
  check_cmd() {
    command -v "$1" &>/dev/null || error "$1 is required but not installed."
  }
  check_cmd python3
  check_cmd cargo
  check_cmd yarn
  check_cmd anvil
  check_cmd cast
  check_cmd forge

  # Check required environment variables
  [[ -z "${ERA_CONTRACTS_PATH:-}" ]] && error "ERA_CONTRACTS_PATH must be set (path to era-contracts repo at tag zkos-$VERSION)"
  [[ -z "${ZKSYNC_ERA_PATH:-}" ]] && error "ZKSYNC_ERA_PATH must be set (path to zksync-era repo)"

  log "Running genesis generator locally..."
  python3 "$GENESIS_SCRIPT" \
    --chain-ids "$(IFS=','; echo "${CHAINS[*]}")" \
    --version "$VERSION" \
    --output "$OUTPUT_DIR"
fi

# Verify output
echo ""
MISSING=()
for CHAIN_ID in "${CHAINS[@]}"; do
  [[ ! -f "$OUTPUT_DIR/chain_${CHAIN_ID}.yaml" ]] && MISSING+=("$CHAIN_ID")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  error "Genesis generation completed but configs missing for chains: ${MISSING[*]}"
fi

echo -e "${GREEN}${BOLD}✓ Genesis generation complete!${NC}"
echo ""
echo "Generated configs:"
for CHAIN_ID in "${CHAINS[@]}"; do
  echo "  $OUTPUT_DIR/chain_${CHAIN_ID}.yaml"
done
echo ""
echo "Now re-run configure-l2s to generate the docker-compose file."
