#!/usr/bin/env bash
set -euo pipefail

# Shared devtools installer for devcontainer images.
# Version defaults below are the source of truth — Renovate updates them here.
# Containerfile ARGs can override via env vars if a specific container needs to pin differently.

# yq releases: https://github.com/mikefarah/yq/releases
# renovate: datasource=github-releases depName=mikefarah/yq extractVersion=^v(?<version>.*)$
YQ_VERSION="${YQ_VERSION:-4.52.4}"

# copier releases: https://pypi.org/project/copier/
# renovate: datasource=pypi depName=copier
COPIER_VERSION="${COPIER_VERSION:-9.14.0}"

# Codex releases: https://github.com/openai/codex/releases
# renovate: datasource=github-releases depName=openai/codex extractVersion=^rust-v(?<version>.*)$
CODEX_VERSION="${CODEX_VERSION:-0.116.0}"

# Python runtime dependencies (needed by copier/uv; no-op on Python-based images)
# Developer experience tools: curl, wget, bat, bats, git, jq, openssh-client, tree, zsh
apt-get update && apt-get install -y \
    libssl3 zlib1g libbz2-1.0 libreadline8 libsqlite3-0 \
    libncursesw6 libffi8 liblzma5 tk \
    curl wget bat bats git jq openssh-client tree zsh

# Make bat (installed as batcat) available as bat
# See: https://github.com/sharkdp/bat
ln -sf /usr/bin/batcat /usr/local/bin/bat

# Install yq (mikefarah/yq - Go-based YAML processor)
curl -fsSL "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" -o /usr/local/bin/yq
chmod +x /usr/local/bin/yq

# Install Claude Code (native installer)
curl -fsSL https://claude.ai/install.sh | bash

# Install OpenAI Codex (native binary)
wget "https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}/codex-x86_64-unknown-linux-gnu.tar.gz" -O /tmp/codex.tar.gz
tar -xzf /tmp/codex.tar.gz -C /tmp
mv /tmp/codex-x86_64-unknown-linux-gnu /usr/local/bin/codex
chmod +x /usr/local/bin/codex
rm /tmp/codex.tar.gz

# Install oh-my-zsh. Needs to be per user. See: https://ohmyz.sh/
sh -c "$(wget https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -O -)" --unattended

# Set zsh as the default shell for the main (root) user
chsh -s /bin/zsh root

# Install uv (fast Python package installer)
# See: https://github.com/astral-sh/uv
curl -LsSf https://astral.sh/uv/install.sh | sh

# Install copier (template engine)
/root/.local/bin/uv pip install --system "copier==${COPIER_VERSION}"

# Clean up
apt-get clean
rm -rf /tmp/*
rm -rf /var/lib/apt/lists/*
