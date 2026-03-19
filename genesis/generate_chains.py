#!/usr/bin/env python3
"""
generate_chains.py - Genesis and chain config generator for N ZKsync OS L2 chains.

This script is based on / forked from:
  https://github.com/matter-labs/zksync-os-scripts (scripts/update_server.py)

Key difference from upstream: instead of hardcoding chains [6565, 6566],
this script accepts --chain-ids and generates configs for arbitrary chains.

Usage:
  python3 generate_chains.py --chain-ids 6565,6566,6567 --version v30.2 --output /output

Required environment variables (local mode):
  ERA_CONTRACTS_PATH   Path to era-contracts at tag matching the version
  ZKSYNC_ERA_PATH      Path to zksync-era (for zkstack CLI)
  PROTOCOL_VERSION     e.g. "v30.2"

Required tools (local mode):
  cargo, yarn, anvil, cast, forge (see versions.yaml for exact versions)
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml


# ──────────────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────────────

ANVIL_DEFAULT_URL = "http://localhost:8545"
ANVIL_RICH_PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"


def sh(cmd: str, cwd: Path | None = None, env: dict | None = None) -> None:
    """Run a shell command, streaming output."""
    merged_env = {**os.environ, **(env or {})}
    result = subprocess.run(
        cmd,
        shell=True,
        cwd=cwd,
        env=merged_env,
    )
    if result.returncode != 0:
        print(f"ERROR: Command failed with exit code {result.returncode}: {cmd}", file=sys.stderr)
        sys.exit(result.returncode)


def require_env(name: str) -> str:
    val = os.environ.get(name)
    if not val:
        print(f"ERROR: Environment variable {name} is required but not set.", file=sys.stderr)
        sys.exit(1)
    return val


def require_path(name: str) -> Path:
    val = require_env(name)
    p = Path(val)
    if not p.exists():
        print(f"ERROR: Path from {name} does not exist: {p}", file=sys.stderr)
        sys.exit(1)
    return p.resolve()


def load_yaml(path: Path) -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


def normalize_hex(val: str, length: int = 40) -> str:
    val = val.strip()
    if val.startswith("0x") or val.startswith("0X"):
        val = val[2:]
    return "0x" + val.zfill(length).lower()


def addresses_from_wallets_yaml(data: dict) -> list[str]:
    """Extract all wallet addresses from a wallets.yaml dict."""
    addresses = []
    for entry in data.values():
        if isinstance(entry, dict) and "address" in entry:
            addresses.append(entry["address"])
    return addresses


# ──────────────────────────────────────────────────────────────────────────────
# Core functions (adapted from zksync-os-scripts/scripts/update_server.py)
# ──────────────────────────────────────────────────────────────────────────────

def fund_accounts(ecosystem_dir: Path) -> None:
    """Fund all wallet addresses with ETH via Anvil RPC."""
    wallets_files = list(ecosystem_dir.rglob("wallets.yaml"))
    if not wallets_files:
        print(f"WARNING: No wallets.yaml found under {ecosystem_dir}", file=sys.stderr)
        return

    all_addrs: set[str] = set()
    for wf in wallets_files:
        data = load_yaml(wf)
        addrs = addresses_from_wallets_yaml(data)
        all_addrs.update(addrs)

    amount_100eth = hex(100 * 10**18)
    for addr in sorted(all_addrs):
        sh(f"cast rpc anvil_setBalance {addr} {amount_100eth} --rpc-url {ANVIL_DEFAULT_URL}")

    amount_9000eth = hex(9000 * 10**18)
    sh(f"cast rpc anvil_setBalance 0xa61464658afeaf65cccaafd3a512b69a83b77618 {amount_9000eth} --rpc-url {ANVIL_DEFAULT_URL}")
    sh(f"cast rpc anvil_setBalance 0x36615cf349d7f6344891b1e7ca7c72883f5dc049 {amount_9000eth} --rpc-url {ANVIL_DEFAULT_URL}")


def get_contract_address(contracts_yaml: Path, field: str) -> str:
    data = load_yaml(contracts_yaml)
    val = data.get("ecosystem_contracts", {}).get(field)
    if not val:
        print(f"ERROR: {field} not found in {contracts_yaml}", file=sys.stderr)
        sys.exit(1)
    return normalize_hex(val, length=40)


def write_chain_config(
    output_path: Path,
    chain_id: int,
    bridgehub_address: str,
    bytecode_supplier_address: str,
    operator_commit_sk: str,
    operator_prove_sk: str,
    operator_execute_sk: str,
    rpc_port: int,
    version: str,
) -> None:
    """Write a chain_XXXX.yaml config for the zksync-os-server."""
    config = {
        "general": {"ephemeral": True},
        "genesis": {
            "bridgehub_address": bridgehub_address,
            "bytecode_supplier_address": bytecode_supplier_address,
            "genesis_input_path": f"./local-chains/{version}/genesis.json",
            "chain_id": chain_id,
        },
        "l1_sender": {
            "pubdata_mode": "Blobs",
            "operator_commit_sk": operator_commit_sk,
            "operator_prove_sk": operator_prove_sk,
            "operator_execute_sk": operator_execute_sk,
        },
        "rpc": {
            "address": f"0.0.0.0:{rpc_port}",
        },
        "external_price_api_client": {
            "source": "Forced",
            "forced_prices": {
                "0x0000000000000000000000000000000000000001": 3000,
            },
        },
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        yaml.safe_dump(config, f, default_flow_style=False, sort_keys=False)
        f.write("\n")


def generate_genesis_json(
    era_contracts_path: Path,
    output_path: Path,
    execution_version: str,
) -> None:
    sh(
        f"cargo run -- --output-file {output_path} --execution-version {execution_version}",
        cwd=era_contracts_path / "tools" / "zksync-os-genesis-gen",
    )


def init_multi_chain_ecosystem(
    zkstack_bin: Path,
    zksync_era_path: Path,
    era_contracts_path: Path,
    workspace: Path,
    chain_ids: list[int],
    version: str,
    output_dir: Path,
) -> None:
    """
    Initialize a zkStack ecosystem with the given chain IDs and deploy L1 contracts.
    This is the multi-chain variant - runs one ecosystem with all chains.
    """
    ecosystem_name = "multi_chain"
    ecosystems_dir = workspace / "ecosystems"
    ecosystem_dir = ecosystems_dir / ecosystem_name
    ecosystems_dir.mkdir(parents=True, exist_ok=True)

    # Remove previous ecosystem if exists
    if ecosystem_dir.exists():
        shutil.rmtree(ecosystem_dir)

    print(f"  Creating ecosystem '{ecosystem_name}'...")
    sh(
        f"""
        {zkstack_bin}
          ecosystem create
          --ecosystem-name {ecosystem_name}
          --l1-network localhost
          --chain-name tmp-chain
          --chain-id 12345
          --prover-mode no-proofs
          --wallet-creation random
          --link-to-code {zksync_era_path}
          --l1-batch-commit-data-generator-mode rollup
          --start-containers false
          --base-token-address 0x0000000000000000000000000000000000000001
          --base-token-price-nominator 1
          --base-token-price-denominator 1
          --evm-emulator false
        """,
        cwd=ecosystems_dir,
    )

    # Set CTM contracts for zksync-os mode
    sh(
        f"""
        {zkstack_bin}
          ctm set-ctm-contracts
          --contracts-src-path {era_contracts_path}
          --default-configs-src-path {era_contracts_path}/etc/env/file_based
          --zksync-os
        """,
        cwd=ecosystem_dir,
    )

    # Remove default era chain (non zksync-os), then create our chains
    chains_dir = ecosystem_dir / "chains"
    if chains_dir.exists():
        shutil.rmtree(chains_dir)

    for chain_id in chain_ids:
        print(f"  Creating chain {chain_id}...")
        sh(
            f"""
            {zkstack_bin}
              chain create
              --chain-name {chain_id}
              --chain-id {chain_id}
              --prover-mode no-proofs
              --wallet-creation random
              --l1-batch-commit-data-generator-mode rollup
              --base-token-address 0x0000000000000000000000000000000000000001
              --base-token-price-nominator 1
              --base-token-price-denominator 1
              --evm-emulator false
              --set-as-default=true
              --zksync-os
            """,
            cwd=ecosystem_dir,
        )

    # Start Anvil, deploy, dump state
    print("  Starting Anvil and deploying L1 contracts...")
    l1_state_path = output_dir / "l1-state.json"

    with tempfile.NamedTemporaryFile(suffix=".pid", delete=False) as f:
        pid_file = f.name

    # Start Anvil in background
    anvil_proc = subprocess.Popen(
        f"anvil --port 8545 --host 127.0.0.1",
        shell=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    import time
    import urllib.request

    print("  Waiting for Anvil...")
    for _ in range(30):
        try:
            urllib.request.urlopen(
                urllib.request.Request(
                    ANVIL_DEFAULT_URL,
                    data=b'{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}',
                    headers={"Content-Type": "application/json"},
                ),
                timeout=2,
            )
            break
        except Exception:
            time.sleep(1)

    try:
        fund_accounts(ecosystem_dir)

        sh(
            f"""
            {zkstack_bin}
              ecosystem init
              --deploy-paymaster=false
              --deploy-erc20=false
              --observability=false
              --no-port-reallocation
              --deploy-ecosystem
              --l1-rpc-url="{ANVIL_DEFAULT_URL}"
              --zksync-os
            """,
            cwd=ecosystem_dir,
        )

        # Extract configs per chain
        for i, chain_id in enumerate(chain_ids):
            contracts_yaml = ecosystem_dir / "chains" / str(chain_id) / "configs" / "contracts.yaml"
            wallets_yaml   = ecosystem_dir / "chains" / str(chain_id) / "configs" / "wallets.yaml"

            bridgehub_address = get_contract_address(contracts_yaml, "bridgehub_proxy_addr")
            bytecode_supplier = get_contract_address(contracts_yaml, "l1_bytecodes_supplier_addr")

            wallets = load_yaml(wallets_yaml)
            commit_sk  = normalize_hex(wallets["blob_operator"]["private_key"], length=64)
            prove_sk   = normalize_hex(wallets["prove_operator"]["private_key"], length=64)
            execute_sk = normalize_hex(wallets["execute_operator"]["private_key"], length=64)

            rpc_port = 3050 + i  # 3050, 3051, 3052, ...

            write_chain_config(
                output_path=output_dir / f"chain_{chain_id}.yaml",
                chain_id=chain_id,
                bridgehub_address=bridgehub_address,
                bytecode_supplier_address=bytecode_supplier,
                operator_commit_sk=commit_sk,
                operator_prove_sk=prove_sk,
                operator_execute_sk=execute_sk,
                rpc_port=rpc_port,
                version=version,
            )

            # Copy wallets/contracts for reference
            shutil.copy(wallets_yaml, output_dir / f"wallets_{chain_id}.yaml")
            shutil.copy(contracts_yaml, output_dir / f"contracts_{chain_id}.yaml")

        # Dump Anvil state
        print("  Dumping L1 state...")
        sh(
            f"cast rpc anvil_dumpState --rpc-url {ANVIL_DEFAULT_URL} | python3 -c "
            f"\"import sys, json; print(json.load(sys.stdin)['result'])\" "
            f"| python3 -c \"import sys, base64; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read().strip()))\" "
            f"> {l1_state_path}"
        )

        # Compress
        sh(f"gzip -9 < {l1_state_path} > {output_dir}/l1-state.json.gz")
        l1_state_path.unlink()

    finally:
        anvil_proc.terminate()
        try:
            os.unlink(pid_file)
        except Exception:
            pass

    print(f"  Configs written to {output_dir}/")


# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="Generate ZKsync OS multi-chain configs")
    parser.add_argument("--chain-ids", required=True, help="Comma-separated chain IDs, e.g. 6565,6566,6567")
    parser.add_argument("--version", default="v30.2", help="Protocol version (default: v30.2)")
    parser.add_argument("--output", required=True, help="Output directory for generated configs")
    args = parser.parse_args()

    chain_ids = [int(c.strip()) for c in args.chain_ids.split(",")]
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    version = args.version
    era_contracts_path = require_path("ERA_CONTRACTS_PATH")
    zksync_era_path    = require_path("ZKSYNC_ERA_PATH")
    protocol_version   = require_env("PROTOCOL_VERSION")

    if skip_build:
        # In the pre-built image the binary was installed to /usr/local/bin
        zkstack_bin = Path("zkstack")
    else:
        zkstack_bin = zksync_era_path / "zkstack_cli" / "target" / "release" / "zkstack"

    workspace = output_dir / ".workspace"
    workspace.mkdir(parents=True, exist_ok=True)

    # When GENESIS_PREBUILT=1, binaries are already compiled in the Docker image —
    # skip the expensive build steps (1 and 2) to avoid rebuilding from scratch.
    skip_build = os.environ.get("GENESIS_PREBUILT", "0") == "1"

    print(f"\n=== ZKsync OS Genesis Generator ===")
    print(f"Chain IDs:        {chain_ids}")
    print(f"Protocol version: {version}")
    print(f"Output directory: {output_dir}")
    if skip_build:
        print(f"Mode:             pre-built image (skipping compilation)")
    print()

    if not skip_build:
        # Step 1: Build contracts
        print("[1/4] Building era-contracts...")
        sh("yarn install", cwd=era_contracts_path)
        sh("yarn build:foundry", cwd=era_contracts_path / "da-contracts")
        sh("yarn build:foundry", cwd=era_contracts_path / "l1-contracts")

        # Step 2: Build zkstack CLI
        print("[2/4] Building zkstack CLI...")
        sh("cargo build --release --bin zkstack", cwd=zksync_era_path / "zkstack_cli")
    else:
        print("[1/4] Skipped (pre-built image)")
        print("[2/4] Skipped (pre-built image)")

    # Step 3: Generate genesis.json
    # If GENESIS_JSON_CACHE points to a pre-built genesis.json, reuse it.
    genesis_cache = os.environ.get("GENESIS_JSON_CACHE", "")
    genesis_output = output_dir / "genesis.json"
    if genesis_cache and Path(genesis_cache).exists():
        print(f"[3/4] Using cached genesis.json from {genesis_cache}")
        shutil.copy(genesis_cache, genesis_output)
    else:
        print("[3/4] Generating genesis.json...")
        # Get execution_version from the protocol version mapping
        # For v30.2, execution_version = "30.2"
        execution_version = version.lstrip("v")
        generate_genesis_json(era_contracts_path, genesis_output, execution_version)

    # Step 4: Initialize ecosystem and deploy L1 contracts
    print("[4/4] Initializing ecosystem and deploying L1 contracts...")
    init_multi_chain_ecosystem(
        zkstack_bin=zkstack_bin,
        zksync_era_path=zksync_era_path,
        era_contracts_path=era_contracts_path,
        workspace=workspace,
        chain_ids=chain_ids,
        version=version,
        output_dir=output_dir,
    )

    print()
    print("✓ Genesis generation complete!")
    print()
    for chain_id in chain_ids:
        print(f"  {output_dir}/chain_{chain_id}.yaml")
    print(f"  {output_dir}/genesis.json")
    print(f"  {output_dir}/l1-state.json.gz")


if __name__ == "__main__":
    main()
