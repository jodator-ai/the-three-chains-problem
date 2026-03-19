# Genesis Generator for ZKsync OS multi-chain setup
#
# This Docker image provides a self-contained environment for generating
# ZKsync OS chain configurations and L1 state for N L2 chains.
#
# Build:
#   docker build --build-arg PROTOCOL_VERSION=v30.2 -t zksync-genesis-generator:v30.2 .
#
# Run:
#   docker run --rm -v /path/to/output:/output zksync-genesis-generator:v30.2 \
#     --chain-ids 6565,6566,6567 --output /output
#
# Note: First build takes 20-40 minutes due to Rust compilation.

FROM ubuntu:22.04

ARG PROTOCOL_VERSION=v30.2

# Build metadata
LABEL org.opencontainers.image.title="ZKsync OS Genesis Generator"
LABEL org.opencontainers.image.description="Generates multi-chain genesis configs for ZKsync OS"

ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    curl \
    git \
    pkg-config \
    libssl-dev \
    python3 \
    python3-pip \
    python3-venv \
    wget \
    jq \
    gzip \
    && rm -rf /var/lib/apt/lists/*

# Install Rust
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV PATH=/usr/local/cargo/bin:$PATH

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path

# Install Node.js 22 (for yarn)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    npm install -g yarn corepack

# Install Foundry-ZKsync (required for `forge build --zksync` in era-contracts)
# Standard foundry does not have --zksync support; era-contracts l1-contracts
# needs forge build --zksync to produce zkEVM artifacts used by zkstack for
# L1 contract deployment.
RUN curl -sSfL https://raw.githubusercontent.com/matter-labs/foundry-zksync/main/foundryup-zksync/install | bash && \
    /root/.foundry/bin/foundryup-zksync && \
    ln -s /root/.foundry/bin/anvil /usr/local/bin/anvil && \
    ln -s /root/.foundry/bin/cast  /usr/local/bin/cast  && \
    ln -s /root/.foundry/bin/forge /usr/local/bin/forge && \
    forge --version

# Clone era-contracts at the correct tag for the protocol version
# Tag from local-chains/v30.2/versions.yaml: era-contracts tag = zkos-v0.30.2
ARG ERA_CONTRACTS_TAG=zkos-v0.30.2
RUN git clone --depth 1 --branch ${ERA_CONTRACTS_TAG} \
    --recurse-submodules --shallow-submodules \
    https://github.com/matter-labs/era-contracts.git /era-contracts

# Clone zksync-era (for zkstack CLI)
# Tag from versions.yaml: zkstack-cli tag = protocol-upgrade-v1.3.1
ARG ZKSTACK_TAG=protocol-upgrade-v1.3.1
RUN git clone --depth 1 --branch ${ZKSTACK_TAG} \
    https://github.com/matter-labs/zksync-era.git /zksync-era

# Pre-build era-contracts
WORKDIR /era-contracts
RUN yarn install --frozen-lockfile || yarn install
RUN yarn build:foundry --cwd da-contracts 2>/dev/null || (cd da-contracts && yarn build:foundry)
RUN yarn build:foundry --cwd l1-contracts 2>/dev/null || (cd l1-contracts && yarn build:foundry)

# Pre-build zkstack CLI
WORKDIR /zksync-era/zkstack_cli
RUN cargo build --release --bin zkstack

# Pre-build the genesis generator
WORKDIR /era-contracts
RUN cargo build --release --package zksync_os_generate_deposit 2>/dev/null || true

# Install Python dependencies for generate_chains.py
RUN pip3 install pyyaml packaging

# Copy genesis generator script
COPY generate_chains.py /usr/local/bin/generate_chains.py
RUN chmod +x /usr/local/bin/generate_chains.py

# Set environment variables for the generator
ENV ERA_CONTRACTS_PATH=/era-contracts
ENV ZKSYNC_ERA_PATH=/zksync-era
ENV PROTOCOL_VERSION=${PROTOCOL_VERSION}

WORKDIR /workspace

ENTRYPOINT ["python3", "/usr/local/bin/generate_chains.py"]
CMD ["--help"]
