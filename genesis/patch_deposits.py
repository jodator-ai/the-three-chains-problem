#!/usr/bin/env python3
"""
patch_deposits.py — Post-process L1 genesis state to add rich account deposits.

After update_server.py runs with SKIP_DEPOSIT_TX=1 (because zksync_os_generate_deposit
is not available at runtime), the L1 state lacks L1→L2 deposit transactions for the
rich account (0x36615Cf349d7F6344891B1e7CA7C72883F5dc049).

This script patches the state by:
  1. Starting a temporary Anvil with the generated state
  2. Calling requestL2TransactionDirect on the bridgehub for each chain
  3. Dumping the patched state (with original historical_states merged back in)

Environment variables (same as update_server.py):
  OUTPUT_DIR   Directory containing l1-state.json.gz and contracts_*.yaml
  CHAIN_IDS    Comma-separated chain IDs, e.g. "6565,6566,6567"
"""

import gzip
import io
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import yaml

ANVIL_PORT = 18547
ANVIL_URL = f"http://localhost:{ANVIL_PORT}"

RICH_ACCOUNT = "0x36615cf349d7f6344891b1e7ca7c72883f5dc049"
L2_DEPOSIT_AMOUNT = 100 * 10**18   # 100 ETH
L2_GAS_LIMIT = 500_000
L2_GAS_PER_PUBDATA = 800


def rpc(method: str, params=None) -> object:
    import urllib.request
    body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params or [], "id": 1}).encode()
    req = urllib.request.Request(ANVIL_URL, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.load(resp)
    if "error" in data:
        raise RuntimeError(f"RPC {method} error: {data['error']}")
    return data["result"]


def sh(cmd: str) -> None:
    cmd = " ".join(cmd.split())
    result = subprocess.run(cmd, shell=True)
    if result.returncode != 0:
        print(f"ERROR: {cmd}", file=sys.stderr)
        sys.exit(result.returncode)


def sh_output(cmd: str) -> str:
    cmd = " ".join(cmd.split())
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ERROR: {cmd}\n{result.stderr}", file=sys.stderr)
        sys.exit(result.returncode)
    return result.stdout.strip()


def get_bridgehub(contracts_file: Path) -> str:
    data = yaml.safe_load(contracts_file.read_text())
    val = data["ecosystem_contracts"]["bridgehub_proxy_addr"]
    if isinstance(val, int):
        val = hex(val)
    return str(val)


def build_deposit_calldata(chain_id: int, mint_value: int) -> str:
    """Build ABI-encoded calldata for requestL2TransactionDirect."""
    def u256(v: int) -> str:
        return format(v, "064x")

    def padaddr(a: str) -> str:
        clean = a[2:] if a.startswith(("0x", "0X")) else a
        return clean.lower().zfill(64)

    # Struct head: 9 fields, dynamic fields (l2Calldata, factoryDeps) as offsets.
    # l2Calldata offset = 9*32 = 288; factoryDeps offset = 288+32 = 320.
    return "0x" + "".join([
        "d52471c1",                    # selector: requestL2TransactionDirect
        u256(32),                      # offset to struct
        u256(chain_id),                # chainId
        u256(mint_value),              # mintValue
        padaddr(RICH_ACCOUNT),         # l2Contract
        u256(L2_DEPOSIT_AMOUNT),       # l2Value
        u256(288),                     # l2Calldata offset (9 * 32)
        u256(L2_GAS_LIMIT),            # l2GasLimit
        u256(L2_GAS_PER_PUBDATA),      # l2GasPerPubdataByteLimit
        u256(320),                     # factoryDeps offset (288 + 32)
        padaddr(RICH_ACCOUNT),         # refundRecipient
        u256(0),                       # l2Calldata length = 0
        u256(0),                       # factoryDeps array length = 0
    ])


def main() -> None:
    output_dir = Path(os.environ.get("OUTPUT_DIR", ""))
    if not output_dir or not output_dir.is_dir():
        print("ERROR: OUTPUT_DIR must be set to an existing directory", file=sys.stderr)
        sys.exit(1)

    chain_ids = [int(c.strip()) for c in os.environ.get("CHAIN_IDS", "").split(",") if c.strip()]
    if not chain_ids:
        print("ERROR: CHAIN_IDS must be set (e.g. '6565,6566,6567')", file=sys.stderr)
        sys.exit(1)

    state_file = output_dir / "l1-state.json.gz"
    if not state_file.exists():
        print(f"ERROR: {state_file} not found", file=sys.stderr)
        sys.exit(1)

    print(f"[patch_deposits] Patching {state_file} for chains: {chain_ids}")

    # Load original state to preserve historical_states (which anvil_dumpState drops)
    with gzip.open(state_file) as f:
        original_state = json.load(f)
    original_historical = original_state.get("historical_states")

    # Start temporary Anvil with the state
    anvil_proc = subprocess.Popen(
        f"anvil --port {ANVIL_PORT} --load-state {state_file} --silent",
        shell=True,
        preexec_fn=os.setsid,
    )

    try:
        # Wait for Anvil to be ready
        ready = False
        for _ in range(60):
            try:
                rpc("eth_blockNumber")
                ready = True
                break
            except Exception:
                time.sleep(1)

        if not ready:
            print("ERROR: Anvil did not become ready in 60s", file=sys.stderr)
            sys.exit(1)

        rpc("anvil_impersonateAccount", [RICH_ACCOUNT])

        for chain_id in chain_ids:
            contracts_file = output_dir / f"contracts_{chain_id}.yaml"
            if not contracts_file.exists():
                print(f"ERROR: {contracts_file} not found", file=sys.stderr)
                sys.exit(1)

            bridgehub = get_bridgehub(contracts_file)
            gas_price = int(rpc("eth_gasPrice"), 16)

            base_cost = int(
                sh_output(
                    f"cast call {bridgehub}"
                    f" 'l2TransactionBaseCost(uint256,uint256,uint256,uint256)(uint256)'"
                    f" {chain_id} {gas_price} {L2_GAS_LIMIT} {L2_GAS_PER_PUBDATA}"
                    f" --rpc-url {ANVIL_URL}"
                ),
                16,
            )
            mint_value = L2_DEPOSIT_AMOUNT + base_cost
            calldata = build_deposit_calldata(chain_id, mint_value)

            sh(
                f"cast send --unlocked --from {RICH_ACCOUNT}"
                f" --value {mint_value}"
                f" --rpc-url {ANVIL_URL}"
                f" {bridgehub}"
                f" {calldata}"
            )
            print(f"[patch_deposits]   chain {chain_id}: deposited {L2_DEPOSIT_AMOUNT // 10**18} ETH")

        # Dump patched state
        result = rpc("anvil_dumpState")
        raw = bytes.fromhex(result[2:] if result.startswith("0x") else result)
        # raw is gzip — decompress to get JSON
        with gzip.open(io.BytesIO(raw)) as f:
            new_state = json.load(f)

        # Restore historical_states from the original dump (anvil_dumpState drops them)
        if original_historical is not None:
            new_state["historical_states"] = original_historical

        with gzip.open(state_file, "wt", compresslevel=9) as f:
            json.dump(new_state, f)

        print(f"[patch_deposits] Patched state saved ({state_file.stat().st_size // 1024 // 1024}MB)")

    finally:
        try:
            os.killpg(os.getpgid(anvil_proc.pid), signal.SIGTERM)
            anvil_proc.wait(timeout=10)
        except Exception:
            pass


if __name__ == "__main__":
    main()
