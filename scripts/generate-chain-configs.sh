#!/usr/bin/env bash
# generate-chain-configs.sh
# Generates chain_XXXX.yaml config files for N ZKsync OS L2 chains.
# All operator keys are embedded — no upstream downloads required.
#
# Supports:
#   --version=v30.2   Chains settle directly to L1 (Anvil). pubdata_mode: Blobs
#   --version=v31.0   Chains settle directly to L1 (Anvil). pubdata_mode: Blobs
#   --version=v31.0 --gateway
#                     A gateway chain (506) settles to L1; L2 chains settle to
#                     the gateway. pubdata_mode: RelayedL2Calldata for L2s.

set -euo pipefail

readonly SCRIPT_NAME="generate-chain-configs.sh"
readonly BASE_CHAIN_ID=6564

# ── ZKsync OS L1 contract addresses ──────────────────────────────────────────
# These are fixed per protocol version and the same for all chains within a version.

readonly BRIDGEHUB_V302='0xd8f8df05efacd52f28cdf11be22ce3d6ae0fabf7'
readonly BYTECODE_SUPPLIER_V302='0x9f3f32ea83c8a1c8e993fd9035d1d077545467ac'

readonly BRIDGEHUB_V310='0x589cd43f17f3d2fc803a2c6b413b48c42dadc2ee'
readonly BYTECODE_SUPPLIER_V310='0x1b47ccd40a68f47698aca71cc84fb0525794cba7'

# ── Gateway chain constants ───────────────────────────────────────────────────
# Gateway chain ID 506 settles to L1; L2 chains point to it via gateway_rpc_url.
# The gateway service name in Docker compose is "gateway-506", internal port 3052.
readonly GATEWAY_CHAIN_ID=506
readonly GATEWAY_INTERNAL_PORT=3052
readonly GATEWAY_DOCKER_URL="http://gateway-506:${GATEWAY_INTERNAL_PORT}"

# ── Operator private keys — v30.2 (L1 settlement) ────────────────────────────
# Chain 1 (6565) and chain 2 (6566): upstream multi_chain keys.
# Chains 3+ (6567 …): sequential Hardhat test accounts (acct 2,3,4 for chain 3; etc.)

readonly -a V302_COMMIT_KEYS=(
  ""                                                                      # [0] unused
  "0xafc49c5bb410acc43973d0b6cf638220d3cedc3109a08aefa82cffb4853d4eb4"   # [1] 6565
  "0xedc88f85d7a0e5aa8c48a11fc0261eb6bbe16f7fb1523df53bf570b250998a31"   # [2] 6566
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"   # [3] 6567 — hardhat 2
  "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba"   # [4] 6568 — hardhat 5
  "0xdbda1821b80551c9d65939329250132c444b566a09e8e4eabb00f52e4d56b847"   # [5] 6569 — hardhat 8
  "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6"   # [6] 6570 — hardhat 9
  "0xf214f2b2cd398c806f84e317254e0f0b801d0643303237d97a22a48e01628897"   # [7] 6571 — hardhat 10
  "0x701b615bbdfb9de65240bc28bd21bbc0d996645a3dd57e7b12bc2bdf6f192c82"   # [8] 6572 — hardhat 11
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"   # [9] 6573 — hardhat 0
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"   # [10] 6574 — hardhat 1
)

readonly -a V302_PROVE_KEYS=(
  ""
  "0x2b099802815e63d929e07bec5bacd57732c75d5087c5bf6545b095cdc1a1b853"   # [1] 6565
  "0x1f2f23356ff1f9c5998a059381ef678edde790080f94e791698047b1a35ef1b8"   # [2] 6566
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"   # [3] 6567 — hardhat 3
  "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e"   # [4] 6568 — hardhat 6
  "0xa267530f49f8280200edf313ee7af6b827f2a8bce2897751d06a843f644967b1"   # [5] 6569 — hardhat 12
  "0x47c99abed3324a2707c28affff1267e45918ec8c3f20b8aa892e8b065d2942dd"   # [6] 6570 — hardhat 13
  "0xc526ee95bf44d8fc405a158bb884d9d1238d99f0612e9f33d006bb0789009aaa"   # [7] 6571 — hardhat 14
  "0x8166f546bab6da521a8369cab06c5d2b9e46670292d85c875ee9ec20e84ffb61"   # [8] 6572 — hardhat 15
  "0x27e5cb19aab75e7cd27e3c5a553fd7a11f4c73cb37c680cadc31bd7a8fc6bba0"   # [9] 6573 — hardhat 18
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"   # [10] 6574 — hardhat 0
)

readonly -a V302_EXECUTE_KEYS=(
  ""
  "0xefe771b62e5371edc4401bbf8b7aacddb3ed66abae4e6c901cd546fca50295e8"   # [1] 6565
  "0xb878497fc910d43e9d692ccc256964f62d5a223293b4cff0a8c4bb9d352b3292"   # [2] 6566
  "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926b"   # [3] 6567 — hardhat 4
  "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356"   # [4] 6568 — hardhat 7
  "0xea6c44ac03bff858b476bba28179e306548d5b3f837de7c63ace0a0ca7e30769"   # [5] 6569 — hardhat 16
  "0x092db5b4b974b989547f9b71b7e50af2e18db749a81db2e2d0cef36c62af9b29"   # [6] 6570 — hardhat 17
  "0xc526ee95bf44d8fc405a158bb884d9d1238d99f0612e9f33d006bb0789009aaa"   # [7] 6571 — hardhat 14
  "0x8166f546bab6da521a8369cab06c5d2b9e46670292d85c875ee9ec20e84ffb61"   # [8] 6572 — hardhat 15
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"   # [9] 6573 — hardhat 1
  "0x27e5cb19aab75e7cd27e3c5a553fd7a11f4c73cb37c680cadc31bd7a8fc6bba0"   # [10] 6574 — hardhat 18
)

# ── Operator private keys — v31.0 L2 chains (Gateway settlement) ─────────────
# Chain 1 (6565) and chain 2 (6566): from upstream v31.0/multi_chain/.
# Chains 3+ (6567 …): sequential Hardhat accounts (same as v30.2 fallback).

readonly -a V310_COMMIT_KEYS=(
  ""
  "0xf9369900f40eb0c7772f7bec554295b07cc76c0ec29504eb529a14f8b2600e18"   # [1] 6565
  "0x9ca83d68f3dee0fbc196a797b3d08861fa8c4b645e356f400105861c2507f2b1"   # [2] 6566
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"   # [3] 6567 — hardhat 2
  "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba"   # [4] 6568 — hardhat 5
)

readonly -a V310_PROVE_KEYS=(
  ""
  "0x69c333badf7f14e17545a501cb4322051803ae76fa7db6c4919e9b7c8ed18e43"   # [1] 6565
  "0x96e8145b4dcc68fe645e918683dc8b8e38f96cd3f63da46bf1e5447d8336fcfb"   # [2] 6566
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"   # [3] 6567 — hardhat 3
  "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e"   # [4] 6568 — hardhat 6
)

readonly -a V310_EXECUTE_KEYS=(
  ""
  "0x9a14976f00bcdfdd45675985ba80080d71c41025e6700886d39e93fcd48b6236"   # [1] 6565
  "0x7d89e249224bad5c66aa29a6f6aeea59fd0e83e75e7ebe9edcac7619b4d27bba"   # [2] 6566
  "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926b"   # [3] 6567 — hardhat 4
  "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356"   # [4] 6568 — hardhat 7
)

# Gateway chain 506 operator keys (same across both modes that use the gateway)
readonly GATEWAY_COMMIT_SK='0x4004d243114dbed5c228e0dfcfd6266c94f65b9dfcf0843b99b7036a281195db'
readonly GATEWAY_PROVE_SK='0x1d25c21af4cd33291175e1a2a88fba4ddee4853a0ec4fabed509d214ece50b86'
readonly GATEWAY_EXECUTE_SK='0x8e16afc65094b0a6c9b45693c0650c03988056894ee20aa6ca213972c3ab2f82'

# ── helpers ───────────────────────────────────────────────────────────────────
die()        { echo "[$SCRIPT_NAME] ERROR: $*" >&2; exit 1; }
log()        { echo "[$SCRIPT_NAME] $*"; }
is_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Generates chain_XXXX.yaml config files for N ZKsync OS L2 chains.

Options:
  --count=N         Number of chains to generate (default: 2)
  --output-dir=DIR  Directory to write config files (required)
  --version=VER     Protocol version: v30.2 or v31.0 (default: v30.2)
  --gateway         v31.0 only: also generate gateway chain config (chain 506);
                    L2 chains will settle to the gateway instead of L1 directly
  --help, -h        Show this message

Settlement modes:
  v30.2             All chains settle to L1.  pubdata_mode: Blobs
  v31.0 (default)   All chains settle to L1.  pubdata_mode: Blobs
  v31.0 --gateway   Gateway (506) settles to L1; L2 chains settle to gateway.
                    pubdata_mode: RelayedL2Calldata for L2 chains.
EOF
  exit 0
}

# ── argument parsing ──────────────────────────────────────────────────────────
count=2
output_dir=""
version="v30.2"
gateway=false

for arg in "$@"; do
  case "$arg" in
    --count=*)      count="${arg#*=}" ;;
    --output-dir=*) output_dir="${arg#*=}" ;;
    --version=*)    version="${arg#*=}" ;;
    --gateway)      gateway=true ;;
    --help|-h)      usage ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

[[ -n "$output_dir" ]] || die "--output-dir is required"
is_integer "$count"    || die "--count must be a positive integer"
[[ "$count" -ge 1 ]]   || die "--count must be at least 1"
[[ "$count" -le 10 ]]  || die "--count must be at most 10"

[[ "$gateway" == false || "$version" == "v31.0" ]] \
  || die "--gateway requires --version=v31.0"

mkdir -p "$output_dir"

# ── version-specific constants ────────────────────────────────────────────────
select_version_constants() {
  case "$version" in
    v30.2)
      bridgehub="$BRIDGEHUB_V302"
      bytecode_supplier="$BYTECODE_SUPPLIER_V302"
      ;;
    v31.0)
      bridgehub="$BRIDGEHUB_V310"
      bytecode_supplier="$BYTECODE_SUPPLIER_V310"
      ;;
    *) die "Unsupported version: $version (supported: v30.2, v31.0)" ;;
  esac
}

# ── gateway chain config ──────────────────────────────────────────────────────
generate_gateway_config() {
  local -r out="$output_dir/chain_${GATEWAY_CHAIN_ID}.yaml"
  cat > "$out" <<EOF
general:
  ephemeral: true
  ephemeral_state: ./local-chains/${version}/gateway-db.tar.gz
genesis:
  bridgehub_address: '${bridgehub}'
  bytecode_supplier_address: '${bytecode_supplier}'
  genesis_input_path: ./local-chains/${version}/genesis.json
  chain_id: ${GATEWAY_CHAIN_ID}
l1_sender:
  pubdata_mode: Blobs
  operator_commit_sk: '${GATEWAY_COMMIT_SK}'
  operator_prove_sk: '${GATEWAY_PROVE_SK}'
  operator_execute_sk: '${GATEWAY_EXECUTE_SK}'
rpc:
  address: 0.0.0.0:${GATEWAY_INTERNAL_PORT}
external_price_api_client:
  source: Forced
  forced_prices:
    '0x0000000000000000000000000000000000000001': 3000
EOF
  log "Generated $out  (chain_id=$GATEWAY_CHAIN_ID, rpc=:$GATEWAY_INTERNAL_PORT, gateway)"
}

# ── L2 chain config ───────────────────────────────────────────────────────────
generate_l2_config() {
  local -r chain_num="$1"
  local -r chain_id=$(( BASE_CHAIN_ID + chain_num ))
  local -r int_port=$(( 3049 + chain_num ))

  local commit_sk prove_sk execute_sk pubdata_mode gateway_line=""

  if [[ "$version" == "v31.0" ]]; then
    commit_sk="${V310_COMMIT_KEYS[$chain_num]:-}"
    prove_sk="${V310_PROVE_KEYS[$chain_num]:-}"
    execute_sk="${V310_EXECUTE_KEYS[$chain_num]:-}"
  else
    commit_sk="${V302_COMMIT_KEYS[$chain_num]:-}"
    prove_sk="${V302_PROVE_KEYS[$chain_num]:-}"
    execute_sk="${V302_EXECUTE_KEYS[$chain_num]:-}"
  fi

  [[ -n "$commit_sk"  ]] || die "No commit key defined for chain $chain_num (version $version)"
  [[ -n "$prove_sk"   ]] || die "No prove key defined for chain $chain_num (version $version)"
  [[ -n "$execute_sk" ]] || die "No execute key defined for chain $chain_num (version $version)"

  if [[ "$gateway" == true ]]; then
    pubdata_mode="RelayedL2Calldata"
    gateway_line="  gateway_rpc_url: '${GATEWAY_DOCKER_URL}'"
  else
    pubdata_mode="Blobs"
  fi

  local -r out="$output_dir/chain_${chain_id}.yaml"
  cat > "$out" <<EOF
general:
  ephemeral: false
  rocks_db_path: /db/node1
${gateway_line:+${gateway_line}
}genesis:
  bridgehub_address: '${bridgehub}'
  bytecode_supplier_address: '${bytecode_supplier}'
  genesis_input_path: ./local-chains/${version}/genesis.json
  chain_id: ${chain_id}
l1_sender:
  pubdata_mode: ${pubdata_mode}
  operator_commit_sk: '${commit_sk}'
  operator_prove_sk: '${prove_sk}'
  operator_execute_sk: '${execute_sk}'
rpc:
  address: 0.0.0.0:${int_port}
external_price_api_client:
  source: Forced
  forced_prices:
    '0x0000000000000000000000000000000000000001': 3000
EOF
  log "Generated $out  (chain_id=$chain_id, rpc=:$int_port, pubdata=$pubdata_mode)"
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
  select_version_constants

  if [[ "$gateway" == true ]]; then
    generate_gateway_config
  fi

  local i
  for i in $(seq 1 "$count"); do
    generate_l2_config "$i"
  done

  local extra=""
  [[ "$gateway" == true ]] && extra=" + gateway chain"
  log "Done. $count L2 chain config(s)${extra} written to: $output_dir"
}

main
