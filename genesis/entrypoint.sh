#!/usr/bin/env bash
# entrypoint.sh — wrapper around update_server.py
#
# Translates the legacy --chain-ids / --output CLI args used by generate-genesis.sh
# into the CHAIN_IDS / OUTPUT_DIR env vars expected by update_server.py.
#
# Usage (same interface as the old generate_chains.py):
#   entrypoint.sh --chain-ids 6565,6566,6567 --output /output
#   entrypoint.sh --help

set -euo pipefail

CHAIN_IDS_VAL=""
OUTPUT_DIR_VAL=""

for arg in "$@"; do
  case "$arg" in
    --chain-ids=*) CHAIN_IDS_VAL="${arg#*=}" ;;
    --chain-ids)   ;;   # value in next arg — not needed; generate-genesis.sh uses = form
    --output=*)    OUTPUT_DIR_VAL="${arg#*=}" ;;
    --output)      ;;
    --help|-h)
      echo "Usage: $(basename "$0") --chain-ids=<id,id,...> --output=<dir>"
      echo ""
      echo "  --chain-ids=IDS   Comma-separated chain IDs to generate (e.g. 6565,6566,6567)"
      echo "  --output=DIR      Output directory for generated configs"
      echo ""
      echo "Environment variables (override defaults):"
      echo "  CHAIN_IDS         Same as --chain-ids (default: 6565,6566)"
      echo "  OUTPUT_DIR        Same as --output"
      echo "  SKIP_BUILD        Set to 1 to skip contract/zkstack compilation (default: 1)"
      echo "  SKIP_DEPOSIT_TX   Set to 1 to skip deposit tx generation (default: 1)"
      echo "  PROTOCOL_VERSION  Protocol version (default: ${PROTOCOL_VERSION:-v30.2})"
      exit 0
      ;;
    *) echo "[entrypoint] Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# CLI args take precedence over pre-set env vars
[[ -n "$CHAIN_IDS_VAL"  ]] && export CHAIN_IDS="$CHAIN_IDS_VAL"
[[ -n "$OUTPUT_DIR_VAL" ]] && export OUTPUT_DIR="$OUTPUT_DIR_VAL"

# Require at least one of the two
[[ -n "${CHAIN_IDS:-}"  ]] || { echo "[entrypoint] ERROR: --chain-ids or CHAIN_IDS is required" >&2; exit 1; }
[[ -n "${OUTPUT_DIR:-}" ]] || { echo "[entrypoint] ERROR: --output or OUTPUT_DIR is required" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"

echo "[entrypoint] Chain IDs:   $CHAIN_IDS"
echo "[entrypoint] Output dir:  $OUTPUT_DIR"
echo "[entrypoint] Protocol:    ${PROTOCOL_VERSION:-v30.2}"

python3 /zksync-os-scripts/scripts/update_server.py

# Patch the generated L1 state to add rich-account deposits.
# update_server.py runs with SKIP_DEPOSIT_TX=1 (zksync_os_generate_deposit is unavailable
# at runtime), so deposits are missing from the state. patch_deposits.py adds them via
# cast send + Anvil impersonation.
python3 /patch_deposits.py
