#!/usr/bin/env bash
set -euo pipefail

# Shared devtools installer for devcontainer images.
# Version defaults below are the source of truth — Renovate updates them here.
# Containerfile ARGs can override via env vars if a specific container needs to pin differently.

# Every consuming Containerfile is expected to create the 'dev' user before calling this script.
# Fail fast rather than silently skip the dev-specific setup below if that contract is broken.
id dev >/dev/null 2>&1 || { echo "install-devtools.sh requires a 'dev' user to already exist" >&2; exit 1; }

# copier releases: https://pypi.org/project/copier/
# renovate: datasource=pypi depName=copier
COPIER_VERSION="${COPIER_VERSION:-9.16.0}"

# Codex releases: https://github.com/openai/codex/releases
# renovate: datasource=github-releases depName=openai/codex extractVersion=^rust-v(?<version>.*)$
CODEX_VERSION="${CODEX_VERSION:-0.144.3}"

# Python (used by copier; also the interpreter uv provisions on non-Python images)
# renovate: datasource=docker depName=python versioning=docker
PYTHON_VERSION="${PYTHON_VERSION:-3.14.6}"

# uv releases: https://github.com/astral-sh/uv/releases
# renovate: datasource=github-releases depName=astral-sh/uv extractVersion=^(?<version>.*)$
UV_VERSION="${UV_VERSION:-0.11.32}"

# yq releases: https://github.com/mikefarah/yq/releases
# renovate: datasource=github-releases depName=mikefarah/yq extractVersion=^v(?<version>.*)$
YQ_VERSION="${YQ_VERSION:-4.53.3}"

# Developer experience tools
apt-get update && apt-get install -y \
    bubblewrap openssh-client socat sudo \
    curl bat bats fd-find fzf jq ripgrep tree wget \
    gh git git-delta \
    hunspell hunspell-en-us \
    tmux zsh

# Grant dev passwordless sudo. post-create needs root for proxy CA trust and
# the AppArmor userns exception, both of which depend on runtime state that
# only exists once the container has started.
echo "dev ALL=(root) NOPASSWD:ALL" > /etc/sudoers.d/dev
chmod 0440 /etc/sudoers.d/dev

# Make bat (installed as batcat) available as bat
# See: https://github.com/sharkdp/bat
ln -sf "$(command -v batcat)" /usr/local/bin/bat

# Make fdfind available as fd
# See: https://github.com/sharkdp/fd
ln -sf "$(command -v fdfind)" /usr/local/bin/fd

# Install yq (mikefarah/yq - Go-based YAML processor)
curl -fsSL "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" -o /usr/local/bin/yq
chmod +x /usr/local/bin/yq

# Install Claude Code (native installer)
curl -fsSL https://claude.ai/install.sh | HOME=/opt/claude bash
ln -sf /opt/claude/.local/bin/claude /usr/local/bin/claude
chmod -R a+rX /opt/claude

# Install OpenAI Codex (native binary)
wget "https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}/codex-x86_64-unknown-linux-musl.tar.gz" -O /tmp/codex.tar.gz
tar -xzf /tmp/codex.tar.gz -C /tmp
mv /tmp/codex-x86_64-unknown-linux-musl /usr/local/bin/codex
chmod +x /usr/local/bin/codex
rm /tmp/codex.tar.gz

# Install oh-my-zsh. Needs to be per user. See: https://ohmyz.sh/
# Note that zsh doesn't have specific versions available for pinning
sh -c "$(wget https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -O -)" --unattended

# Set zsh as the default shell for the main (root) user
# Note that some downstream containers use docker-in-docker, which needs dockerd
# running as root, so root keeps a full setup too even where dev is the default
chsh -s /bin/zsh root

# Same for dev — the account every containers.base image now runs as by default
su - dev -c 'sh -c "$(wget https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -O -)" --unattended'
chsh -s /bin/zsh dev

# Install uv (fast Python package installer)
# See: https://github.com/astral-sh/uv
curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | UV_INSTALL_DIR=/usr/local/bin sh

# Install Python if the image doesn't already it.
if ! UV_PYTHON_INSTALL_DIR=/opt/python uv python find "${PYTHON_VERSION}" >/dev/null 2>&1; then
    UV_PYTHON_INSTALL_DIR=/opt/python UV_PYTHON_BIN_DIR=/usr/local/bin uv python install --default "${PYTHON_VERSION}"
    chmod -R a+rX /opt/python
fi

# Install copier (template engine)
UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin UV_PYTHON_INSTALL_DIR=/opt/python UV_PYTHON_DOWNLOADS=never uv tool install --python "${PYTHON_VERSION}" "copier==${COPIER_VERSION}"
chmod -R a+rX /opt/uv-tools

# Clean up
apt-get clean
rm -rf /tmp/*
rm -rf /var/lib/apt/lists/*
