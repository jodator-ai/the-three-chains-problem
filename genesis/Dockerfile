# Genesis Generator for ZKsync OS multi-chain setup
#
# This Docker image provides a self-contained environment for generating
# ZKsync OS chain configurations and L1 state for N L2 chains.
#
# Uses https://github.com/jodator-ai/zksync-os-scripts (fork of matter-labs/zksync-os-scripts)
# with added support for CHAIN_IDS, OUTPUT_DIR, SKIP_BUILD and SKIP_DEPOSIT_TX env vars.
#
# All heavy compilation (Rust, Solidity/foundry) happens at IMAGE BUILD TIME.
# At runtime, only the fast Anvil-based deployment runs (~2-3 min).
#
# Build:
#   docker build --build-arg PROTOCOL_VERSION=v30.2 -t zksync-genesis-generator:v30.2 .
#
# Run:
#   docker run --rm -v /path/to/output:/output zksync-genesis-generator:v30.2 \
#     --chain-ids 6565,6566,6567 --output /output

# ── Stage 1: Compile zkstack CLI ───────────────────────────────────────────────
# Use the official Rust image to avoid installing Rust from scratch.
FROM rust:1.82 AS zkstack-builder

ARG ZKSTACK_TAG=protocol-upgrade-v1.3.1

RUN apt-get update && apt-get install -y git mold && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch ${ZKSTACK_TAG} \
    https://github.com/matter-labs/zksync-era.git /zksync-era

WORKDIR /zksync-era/zkstack_cli
# Two memory culprits on 2GB hosts:
#   1. LLVM opt passes at opt-level=3 → killed during rustc codegen
#   2. GNU ld holding all .rlib files in RAM during link
# Fixes: opt-level=0 skips heavy LLVM passes; mold uses 5-10x less link RAM.
# Use -C link-arg=-fuse-ld=mold (not -C linker=mold) so GCC remains the
# linker driver and handles GCC-specific flags (-m64 etc.) before calling mold.
ENV RUSTFLAGS="-C opt-level=0 -C debuginfo=0 -C link-arg=-fuse-ld=mold"
RUN cargo build --release --jobs 1 --bin zkstack

# Strip debug symbols to reduce binary size
RUN strip target/release/zkstack

# ── Stage 2: Build era-contracts + genesis-gen ────────────────────────────────
FROM rust:1.82 AS contracts-builder

ARG ERA_CONTRACTS_TAG=zkos-v0.30.2
ARG PROTOCOL_VERSION=v30.2

RUN apt-get update && apt-get install -y \
    git curl pkg-config libssl-dev python3 \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22 + yarn
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && rm -rf /var/lib/apt/lists/* && \
    npm install -g yarn

# Install foundry-zksync (required for `forge build --zksync` in era-contracts)
RUN curl -sSfL https://raw.githubusercontent.com/matter-labs/foundry-zksync/main/foundryup-zksync/install | bash && \
    /root/.foundry/bin/foundryup-zksync && \
    ln -sf /root/.foundry/bin/forge /usr/local/bin/forge && \
    ln -sf /root/.foundry/bin/cast  /usr/local/bin/cast

RUN git clone --depth 1 --branch ${ERA_CONTRACTS_TAG} \
    --recurse-submodules --shallow-submodules \
    https://github.com/matter-labs/era-contracts.git /era-contracts

# Build Solidity contracts (needed by zkstack at deployment time)
WORKDIR /era-contracts
RUN yarn install --frozen-lockfile
RUN cd da-contracts  && yarn build:foundry
RUN cd l1-contracts  && yarn build:foundry

# Build and run genesis-gen to produce genesis.json at image-build time.
# genesis.json is deterministic per protocol version — no need to regenerate at runtime.
# Using `cargo run --release` avoids hardcoding the binary name from Cargo.toml.
WORKDIR /era-contracts/tools/zksync-os-genesis-gen
RUN EXEC_VER="${PROTOCOL_VERSION#v}" && EXEC_VER="${EXEC_VER%%.*}" && \
    mkdir -p /prebuilt && \
    cargo run --release --jobs 1 -- \
        --output-file /prebuilt/genesis.json \
        --execution-version "$EXEC_VER"

# Remove intermediate build artifacts to reduce layer size (keep compiled outputs)
RUN find /era-contracts -name "*.o" -delete && \
    find /era-contracts/tools -maxdepth 3 -name "deps" -type d -exec rm -rf {} + 2>/dev/null || true

# Keep /era-contracts/.git — zkstack runs `git submodule update` on it at runtime.
# Only remove .git from submodule subdirs (they're already checked out; we don't need their history).
RUN find /era-contracts -mindepth 2 -name ".git" -type d -exec rm -rf {} + 2>/dev/null || true

# ── Stage 3: Runtime image ────────────────────────────────────────────────────
FROM ubuntu:22.04

ARG PROTOCOL_VERSION=v30.2
ARG ZKOS_SCRIPTS_REF=multi-chain-n-support
ENV PROTOCOL_VERSION=${PROTOCOL_VERSION}

LABEL org.opencontainers.image.title="ZKsync OS Genesis Generator"
LABEL org.opencontainers.image.description="Generates multi-chain genesis configs for ZKsync OS"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    git \
    python3 \
    python3-pip \
    gzip \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22 + yarn (needed for zkstack chain create at runtime)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && rm -rf /var/lib/apt/lists/* && \
    npm install -g yarn

# forge + cast: copy from contracts-builder which already has foundry-zksync installed.
# anvil: copy from pinned foundry image — foundry-zksync does not ship an anvil binary.
# Pinned to v1.5.1 so the generated l1-state.json.gz matches the runtime Anvil version.
COPY --from=contracts-builder /root/.foundry/bin/forge /usr/local/bin/forge
COPY --from=contracts-builder /root/.foundry/bin/cast  /usr/local/bin/cast
COPY --from=ghcr.io/foundry-rs/foundry:v1.5.1 /usr/local/bin/anvil /usr/local/bin/anvil

# Copy compiled zkstack binary
COPY --from=zkstack-builder /zksync-era/zkstack_cli/target/release/zkstack /usr/local/bin/zkstack

# Copy era-contracts (source + compiled artifacts are needed by zkstack at runtime)
COPY --from=contracts-builder /era-contracts /era-contracts

# Copy zksync-era source (zkstack --link-to-code requires it at runtime).
# Exclude the Rust target/ directory — we only need the sources + zkstack binary.
COPY --from=zkstack-builder /zksync-era /zksync-era
# Remove the Rust build cache to keep runtime image lean
RUN rm -rf /zksync-era/zkstack_cli/target /zksync-era/target 2>/dev/null || true

# Clone zksync-os-scripts fork (provides update_server.py with CHAIN_IDS / OUTPUT_DIR support)
RUN git clone --depth 1 --branch ${ZKOS_SCRIPTS_REF} \
    https://github.com/jodator-ai/zksync-os-scripts.git /zksync-os-scripts

# Install Python deps from zksync-os-scripts
RUN pip3 install pyyaml packaging rich

# Copy pre-built genesis.json into the location update_server.py expects
RUN mkdir -p /zksync-os-scripts/local-chains/${PROTOCOL_VERSION}/default \
             /zksync-os-scripts/local-chains/${PROTOCOL_VERSION}/multi_chain
COPY --from=contracts-builder /prebuilt/genesis.json \
    /zksync-os-scripts/local-chains/${PROTOCOL_VERSION}/genesis.json

# Tell update_server.py to skip build steps (already done above) and deposit tx
# (not needed for the local dev setup — operators are funded via Anvil impersonation).
ENV SKIP_BUILD=1
ENV SKIP_DEPOSIT_TX=1
ENV GENESIS_PREBUILT=1

# Runtime env vars expected by update_server.py / lib/entry.py
ENV ERA_CONTRACTS_PATH=/era-contracts
ENV ZKSYNC_ERA_PATH=/zksync-era
ENV REPO_DIR=/zksync-os-scripts

WORKDIR /workspace

# Entrypoint: thin wrapper that maps --chain-ids / --output CLI args to env vars
# and then invokes update_server.py
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["--help"]
