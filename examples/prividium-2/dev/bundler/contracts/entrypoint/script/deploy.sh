#!/bin/bash
# Deploy EntryPoint contracts with deterministic addresses
# Uses pre-compiled bytecode from the official deployment to ensure matching addresses

set -e

SCRIPT_DIR="$(dirname "$0")"
cd "$SCRIPT_DIR/.."

# Ensure soldeer dependencies are installed
forge soldeer install

RPC_URL="${RPC_URL:-http://localhost:5050}"
PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

# CREATE2 factory addresses (from deterministic-deployment-proxy)
# See: https://github.com/Arachnid/deterministic-deployment-proxy
CREATE2_FACTORY="0x4e59b44847b379578588920cA78FbF26c0B4956C"
FACTORY_DEPLOYER="0x3fAB184622Dc19b6109349B94811493BF2a45362"

# Salt used for deterministic deployment (mined to produce 0x4337... address)
SALT="0x0a59dbff790c23c976a548690c27297883cc66b4c67024f9117b0238995e35e9"

# Known deterministic EntryPoint address (deployed via CREATE2 with specific salt)
ENTRYPOINT_ADDRESS="0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108"

# Pre-signed transaction to deploy the CREATE2 factory
# This works on any chain - the deployer address has nonce 0 and this tx deploys the factory
FACTORY_DEPLOY_TX="0xf8a58085174876e800830186a08080b853604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf31ba02222222222222222222222222222222222222222222222222222222222222222a02222222222222222222222222222222222222222222222222222222222222222"

# Path to the official deployment JSON with pre-compiled bytecode
ENTRYPOINT_DEPLOYMENT="dependencies/eth-infinitism-account-abstraction-0.8.0/deployments/ethereum/EntryPoint.json"

# Check if EntryPoint is already deployed
echo "Checking if EntryPoint is already deployed at $ENTRYPOINT_ADDRESS..."
ENTRYPOINT_CODE=$(cast code $ENTRYPOINT_ADDRESS --rpc-url $RPC_URL 2>/dev/null || echo "0x")

if [ "$ENTRYPOINT_CODE" != "0x" ] && [ -n "$ENTRYPOINT_CODE" ]; then
    echo "EntryPoint already deployed at $ENTRYPOINT_ADDRESS"
    exit 0
fi

echo "EntryPoint not found, proceeding with deployment..."

echo "Checking CREATE2 factory at $CREATE2_FACTORY..."

# Check if CREATE2 factory exists
FACTORY_CODE=$(cast code $CREATE2_FACTORY --rpc-url $RPC_URL 2>/dev/null || echo "0x")

if [ "$FACTORY_CODE" = "0x" ] || [ -z "$FACTORY_CODE" ]; then
    echo "CREATE2 factory not found, deploying..."

    # Fund the factory deployer (needs ~0.1 ETH for gas)
    echo "Funding factory deployer at $FACTORY_DEPLOYER..."
    cast send $FACTORY_DEPLOYER --value 0.1ether --private-key $PRIVATE_KEY --rpc-url $RPC_URL

    # Send the pre-signed deployment transaction
    echo "Deploying CREATE2 factory..."
    cast publish $FACTORY_DEPLOY_TX --rpc-url $RPC_URL

    # Verify deployment
    sleep 2
    FACTORY_CODE=$(cast code $CREATE2_FACTORY --rpc-url $RPC_URL)
    if [ "$FACTORY_CODE" = "0x" ] || [ -z "$FACTORY_CODE" ]; then
        echo "ERROR: CREATE2 factory deployment failed"
        exit 1
    fi
    echo "CREATE2 factory deployed successfully at $CREATE2_FACTORY"
else
    echo "CREATE2 factory already deployed"
fi

# Extract pre-compiled bytecode from official deployment
echo "Extracting pre-compiled EntryPoint bytecode..."
if [ ! -f "$ENTRYPOINT_DEPLOYMENT" ]; then
    echo "ERROR: EntryPoint deployment file not found at $ENTRYPOINT_DEPLOYMENT"
    exit 1
fi

# Get bytecode and remove 0x prefix for concatenation
BYTECODE=$(sed -nE 's/.*"bytecode" *: *"(0x)?([^"]*)".*/\2/p' "$ENTRYPOINT_DEPLOYMENT")

# The CREATE2 factory expects: salt (32 bytes) ++ initCode
# Salt without 0x prefix
SALT_NO_PREFIX=$(echo $SALT | sed 's/^0x//')

# Concatenate salt + bytecode
PAYLOAD="0x${SALT_NO_PREFIX}${BYTECODE}"

echo "Deploying EntryPoint via CREATE2 factory..."
RESULT=$(cast send --legacy $CREATE2_FACTORY "$PAYLOAD" --private-key $PRIVATE_KEY --rpc-url $RPC_URL --json 2>&1)

# Verify deployment
sleep 2
DEPLOYED_CODE=$(cast code $ENTRYPOINT_ADDRESS --rpc-url $RPC_URL 2>/dev/null || echo "0x")

if [ "$DEPLOYED_CODE" = "0x" ] || [ -z "$DEPLOYED_CODE" ]; then
    echo "ERROR: EntryPoint deployment failed"
    echo "Expected address: $ENTRYPOINT_ADDRESS"
    exit 1
fi

echo "EntryPoint deployed successfully at $ENTRYPOINT_ADDRESS"
