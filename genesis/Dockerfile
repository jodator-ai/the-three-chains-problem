# Genesis Generator for ZKsync OS multi-chain setup
#
# This Docker image provides a self-contained environment for generating
# ZKsync OS chain configurations and L1 state for N L2 chains.
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

RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch ${ZKSTACK_TAG} \
    https://github.com/matter-labs/zksync-era.git /zksync-era

WORKDIR /zksync-era/zkstack_cli
RUN cargo build --release --bin zkstack

# Strip binary to reduce size
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
    cargo run --release -- \
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
# anvil: install from standard foundry — foundry-zksync does not ship an anvil binary.
COPY --from=contracts-builder /root/.foundry/bin/forge /usr/local/bin/forge
COPY --from=contracts-builder /root/.foundry/bin/cast  /usr/local/bin/cast
RUN curl -L https://foundry.paradigm.xyz | bash && \
    /root/.foundry/bin/foundryup && \
    cp /root/.foundry/bin/anvil /usr/local/bin/anvil

# Copy compiled zkstack binary
COPY --from=zkstack-builder /zksync-era/zkstack_cli/target/release/zkstack /usr/local/bin/zkstack

# Copy era-contracts (source + compiled artifacts are needed by zkstack at runtime)
COPY --from=contracts-builder /era-contracts /era-contracts

# Copy zksync-era source (zkstack --link-to-code requires it at runtime).
# Exclude the Rust target/ directory — we only need the sources + zkstack binary.
COPY --from=zkstack-builder /zksync-era /zksync-era
# Remove the Rust build cache to keep runtime image lean
RUN rm -rf /zksync-era/zkstack_cli/target /zksync-era/target 2>/dev/null || true

# Copy pre-built genesis.json
COPY --from=contracts-builder /prebuilt/genesis.json /prebuilt/genesis.json

# Install Python deps
RUN pip3 install pyyaml

# Copy genesis generator script
COPY generate_chains.py /usr/local/bin/generate_chains.py
RUN chmod +x /usr/local/bin/generate_chains.py

# Tell generate_chains.py to skip the build steps (already done above)
ENV GENESIS_PREBUILT=1
# Point to the pre-built genesis.json
ENV GENESIS_JSON_CACHE=/prebuilt/genesis.json

ENV ERA_CONTRACTS_PATH=/era-contracts
ENV ZKSYNC_ERA_PATH=/zksync-era

WORKDIR /workspace

ENTRYPOINT ["python3", "/usr/local/bin/generate_chains.py"]
CMD ["--help"]
