#!/usr/bin/env bash
# download-upstream-configs.sh
# Downloads pre-built chain configs and L1 state from the upstream zksync-os-server repository.
#
# Pre-built configs are available for chains 6565 and 6566 (the default multi-chain setup).
# For chains 3+, use generate-genesis.sh instead.

set -euo pipefail

UPSTREAM_REPO="matter-labs/zksync-os-server"
UPSTREAM_RAW="https://raw.githubusercontent.com/$UPSTREAM_REPO/main"

CHAIN_ID=""
VERSION="v30.2"
OUTPUT_DIR="./configs/v30.2"
GENESIS_ONLY=false
L1_STATE_ONLY=false

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log()   { echo -e "${GREEN}[download]${NC} $*"; }
error() { echo -e "${RED}[download] ERROR:${NC} $*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --chain-id=*)    CHAIN_ID="${arg#*=}" ;;
    --version=*)     VERSION="${arg#*=}" ;;
    --output-dir=*)  OUTPUT_DIR="${arg#*=}" ;;
    --genesis-only)  GENESIS_ONLY=true ;;
    --l1-state-only) L1_STATE_ONLY=true ;;
  esac
done

mkdir -p "$OUTPUT_DIR"

BASE_PATH="local-chains/$VERSION/multi_chain"

download_file() {
  local url="$1"
  local dest="$2"
  log "Downloading $(basename "$dest")..."
  if command -v curl &>/dev/null; then
    curl -fsSL "$url" -o "$dest" || error "Failed to download $url"
  elif command -v wget &>/dev/null; then
    wget -q "$url" -O "$dest" || error "Failed to download $url"
  else
    error "Neither curl nor wget found. Please install one."
  fi
}

download_github_lfs() {
  # GitHub Raw doesn't serve LFS files; use the GitHub API or gh CLI
  local repo="$1"
  local path="$2"
  local dest="$3"
  log "Downloading LFS file $(basename "$dest")..."
  if command -v gh &>/dev/null; then
    gh api "repos/$repo/contents/$path" --jq '.download_url' | xargs curl -fsSL -o "$dest" \
      || error "Failed to download LFS file $path"
  else
    # Fallback: try direct download URL pattern
    local url="https://github.com/$repo/raw/main/$path"
    download_file "$url" "$dest"
  fi
}

if [[ "$GENESIS_ONLY" == "true" ]]; then
  # Download genesis.json (from multi_chain, which is the one referenced by chain configs)
  download_file "$UPSTREAM_RAW/$BASE_PATH/genesis.json" "$OUTPUT_DIR/genesis.json"
  log "genesis.json downloaded to $OUTPUT_DIR/"
  exit 0
fi

if [[ "$L1_STATE_ONLY" == "true" ]]; then
  # l1-state.json.gz may be an LFS file
  L1_STATE_PATH="local-chains/$VERSION/l1-state.json.gz"
  if command -v gh &>/dev/null; then
    log "Downloading l1-state.json.gz via GitHub API..."
    DOWNLOAD_URL=$(gh api "repos/$UPSTREAM_REPO/contents/$L1_STATE_PATH" --jq '.download_url' 2>/dev/null || echo "")
    if [[ -n "$DOWNLOAD_URL" ]] && [[ "$DOWNLOAD_URL" != "null" ]]; then
      curl -fsSL "$DOWNLOAD_URL" -o "$OUTPUT_DIR/l1-state.json.gz"
    else
      # Try LFS download URL
      LFS_URL=$(gh api "repos/$UPSTREAM_REPO/contents/$L1_STATE_PATH" --jq '.git_url' 2>/dev/null || echo "")
      gh api "repos/$UPSTREAM_REPO/git/blobs/$(gh api "repos/$UPSTREAM_REPO/contents/$L1_STATE_PATH" --jq '.sha')" \
        --header "Accept: application/vnd.github.raw" \
        > "$OUTPUT_DIR/l1-state.json.gz" || error "Failed to download l1-state.json.gz"
    fi
  else
    # Try direct raw URL (may not work for LFS files)
    download_file "https://github.com/$UPSTREAM_REPO/raw/main/$L1_STATE_PATH" "$OUTPUT_DIR/l1-state.json.gz"
  fi
  log "l1-state.json.gz downloaded to $OUTPUT_DIR/"
  exit 0
fi

# Download chain config files
[[ -z "$CHAIN_ID" ]] && error "--chain-id is required (unless --genesis-only or --l1-state-only)"

# Only 6565 and 6566 have pre-built configs
if [[ "$CHAIN_ID" != "6565" ]] && [[ "$CHAIN_ID" != "6566" ]]; then
  error "Chain $CHAIN_ID does not have pre-built configs. Use scripts/generate-genesis.sh for chains 3+."
fi

CHAIN_PATH="$BASE_PATH"
download_file "$UPSTREAM_RAW/$CHAIN_PATH/chain_${CHAIN_ID}.yaml" "$OUTPUT_DIR/chain_${CHAIN_ID}.yaml"
download_file "$UPSTREAM_RAW/$CHAIN_PATH/wallets_${CHAIN_ID}.yaml" "$OUTPUT_DIR/wallets_${CHAIN_ID}.yaml"
download_file "$UPSTREAM_RAW/$CHAIN_PATH/contracts_${CHAIN_ID}.yaml" "$OUTPUT_DIR/contracts_${CHAIN_ID}.yaml"

log "Chain $CHAIN_ID configs downloaded to $OUTPUT_DIR/"
