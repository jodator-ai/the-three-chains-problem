#!/usr/bin/env bash
# generate-chain-configs.sh
# Generates chain_XXXX.yaml config files for N ZKsync OS L2 chains.
# All operator keys are embedded — no upstream downloads required.

set -euo pipefail

readonly SCRIPT_NAME="generate-chain-configs.sh"

# ── ZKsync OS L1 contract addresses (same for all chains) ────────────────────
readonly BRIDGEHUB_ADDRESS='0xd8f8df05efacd52f28cdf11be22ce3d6ae0fabf7'
readonly BYTECODE_SUPPLIER_ADDRESS='0x9f3f32ea83c8a1c8e993fd9035d1d077545467ac'

readonly BASE_CHAIN_ID=6564

# ── Operator private keys ─────────────────────────────────────────────────────
# Each chain uses 3 keys: commit, prove, execute.
# Chains 1-2 use upstream-specific keys.
# Chains 3-8 use sequential Hardhat test accounts (accounts 2, 3, 4 for chain 3, etc.)
#
# Format: CHAIN_COMMIT_KEYS[chain_num], CHAIN_PROVE_KEYS[chain_num], CHAIN_EXECUTE_KEYS[chain_num]

readonly -a CHAIN_COMMIT_KEYS=(
  ""                                                                   # [0] unused
  "0xafc49c5bb410acc43973d0b6cf638220d3cedc3109a08aefa82cffb4853d4eb4"  # [1] chain 6565
  "0xedc88f85d7a0e5aa8c48a11fc0261eb6bbe16f7fb1523df53bf570b250998a31"  # [2] chain 6566
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"  # [3] chain 6567 — hardhat acct 2
  "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba"  # [4] chain 6568 — hardhat acct 5
  "0xdbda1821b80551c9d65939329250132c444b566a09e8e4eabb00f52e4d56b847"  # [5] chain 6569 — hardhat acct 8
  "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6"  # [6] chain 6570 — hardhat acct 9
  "0xf214f2b2cd398c806f84e317254e0f0b801d0643303237d97a22a48e01628897"  # [7] chain 6571 — hardhat acct 10
  "0x701b615bbdfb9de65240bc28bd21bbc0d996645a3dd57e7b12bc2bdf6f192c82"  # [8] chain 6572 — hardhat acct 11
)

readonly -a CHAIN_PROVE_KEYS=(
  ""                                                                   # [0] unused
  "0x2b099802815e63d929e07bec5bacd57732c75d5087c5bf6545b095cdc1a1b853"  # [1] chain 6565
  "0x1f2f23356ff1f9c5998a059381ef678edde790080f94e791698047b1a35ef1b8"  # [2] chain 6566
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"  # [3] chain 6567 — hardhat acct 3
  "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e"  # [4] chain 6568 — hardhat acct 6
  "0xa267530f49f8280200edf313ee7af6b827f2a8bce2897751d06a843f644967b1"  # [5] chain 6569 — hardhat acct 12
  "0x47c99abed3324a2707c28affff1267e45918ec8c3f20b8aa892e8b065d2942dd"  # [6] chain 6570 — hardhat acct 13
  "0xc526ee95bf44d8fc405a158bb884d9d1238d99f0612e9f33d006bb0789009aaa"  # [7] chain 6571 — hardhat acct 14
  "0x8166f546bab6da521a8369cab06c5d2b9e46670292d85c875ee9ec20e84ffb61"  # [8] chain 6572 — hardhat acct 15
)

readonly -a CHAIN_EXECUTE_KEYS=(
  ""                                                                   # [0] unused
  "0xefe771b62e5371edc4401bbf8b7aacddb3ed66abae4e6c901cd546fca50295e8"  # [1] chain 6565
  "0xb878497fc910d43e9d692ccc256964f62d5a223293b4cff0a8c4bb9d352b3292"  # [2] chain 6566
  "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926b"  # [3] chain 6567 — hardhat acct 4
  "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356"  # [4] chain 6568 — hardhat acct 7
  "0xea6c44ac03bff858b476bba28179e306548d5b3f837de7c63ace0a0ca7e30769"  # [5] chain 6569 — hardhat acct 16
  "0x092db5b4b974b989547f9b71b7e50af2e18db749a81db2e2d0cef36c62af9b29"  # [6] chain 6570 — hardhat acct 17
  "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356"  # [7] chain 6571 (placeholder)
  "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356"  # [8] chain 6572 (placeholder)
)

# ── helpers ───────────────────────────────────────────────────────────────────
die()        { echo "[$SCRIPT_NAME] ERROR: $*" >&2; exit 1; }
log()        { echo "[$SCRIPT_NAME] $*"; }
is_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Generates chain_XXXX.yaml config files for N ZKsync OS L2 chains.

Options:
  --count=N         Number of chains to generate (default: 2, max: 8)
  --output-dir=DIR  Directory to write config files (required)
  --version=VER     ZKsync OS protocol version (default: v30.2)
  --help, -h        Show this message
EOF
  exit 0
}

# ── argument parsing ──────────────────────────────────────────────────────────
count=2
output_dir=""
version="v30.2"

for arg in "$@"; do
  case "$arg" in
    --count=*)      count="${arg#*=}" ;;
    --output-dir=*) output_dir="${arg#*=}" ;;
    --version=*)    version="${arg#*=}" ;;
    --help|-h)      usage ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

[[ -n "$output_dir" ]] || die "--output-dir is required"
is_integer "$count"    || die "--count must be a positive integer"
[[ "$count" -ge 1 ]]   || die "--count must be at least 1"
[[ "$count" -le 8 ]]   || die "--count must be at most 8"

mkdir -p "$output_dir"

# ── config generation ─────────────────────────────────────────────────────────
generate_chain_config() {
  local chain_num="$1"
  local chain_id=$(( BASE_CHAIN_ID + chain_num ))
  local int_port=$(( 3049 + chain_num ))
  local commit_sk="${CHAIN_COMMIT_KEYS[$chain_num]}"
  local prove_sk="${CHAIN_PROVE_KEYS[$chain_num]}"
  local execute_sk="${CHAIN_EXECUTE_KEYS[$chain_num]}"
  local out="$output_dir/chain_${chain_id}.yaml"

  [[ -n "$commit_sk"  ]] || die "No commit key for chain $chain_num"
  [[ -n "$prove_sk"   ]] || die "No prove key for chain $chain_num"
  [[ -n "$execute_sk" ]] || die "No execute key for chain $chain_num"

  cat > "$out" <<EOF
general:
  ephemeral: true
genesis:
  bridgehub_address: '$BRIDGEHUB_ADDRESS'
  bytecode_supplier_address: '$BYTECODE_SUPPLIER_ADDRESS'
  genesis_input_path: ./local-chains/${version}/genesis.json
  chain_id: $chain_id
l1_sender:
  pubdata_mode: Blobs
  operator_commit_sk: '$commit_sk'
  operator_prove_sk: '$prove_sk'
  operator_execute_sk: '$execute_sk'
rpc:
  address: 0.0.0.0:${int_port}
external_price_api_client:
  source: Forced
  forced_prices:
    '0x0000000000000000000000000000000000000001': 3000
EOF
  log "Generated $out  (chain_id=$chain_id, rpc=:$int_port)"
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
  local i
  for i in $(seq 1 "$count"); do
    generate_chain_config "$i"
  done
  log "Done. $count chain config(s) written to: $output_dir"
}

main
