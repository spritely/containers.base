#!/usr/bin/env bats

setup() {
    INSTALL_SCRIPT="/src/src/install-devtools.sh"
    extract_version() {
        grep -m1 "^${1}=" "$INSTALL_SCRIPT" | sed 's/.*:-\(.*\)}.*/\1/'
    }
    EXPECTED_COPIER_VERSION=$(extract_version COPIER_VERSION)
    EXPECTED_YQ_VERSION=$(extract_version YQ_VERSION)
    EXPECTED_CODEX_VERSION=$(extract_version CODEX_VERSION)
    EXPECTED_PYTHON_VERSION=$(extract_version PYTHON_VERSION)
    EXPECTED_UV_VERSION=$(extract_version UV_VERSION)
    EXPECTED_NODE_VERSION=$(extract_version NODE_VERSION)
    EXPECTED_PNPM_VERSION=$(extract_version PNPM_VERSION)
    EXPECTED_RENOVATE_VERSION=$(extract_version RENOVATE_VERSION)
}

# Version checks for tools with pinned versions in Containerfile

@test "copier version matches Containerfile" {
    run copier --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"${EXPECTED_COPIER_VERSION}"* ]]
}

@test "yq version matches Containerfile" {
    run yq --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"${EXPECTED_YQ_VERSION}"* ]]
}

@test "codex version matches Containerfile" {
    run codex --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"${EXPECTED_CODEX_VERSION}"* ]]
}

@test "python3 version matches Containerfile" {
    run python3 --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"${EXPECTED_PYTHON_VERSION}"* ]]
}

@test "uv version matches Containerfile" {
    run uv --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"${EXPECTED_UV_VERSION}"* ]]
}

@test "node version matches Containerfile" {
    run node --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"${EXPECTED_NODE_VERSION}"* ]]
}

@test "pnpm version matches Containerfile" {
    run pnpm --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"${EXPECTED_PNPM_VERSION}"* ]]
}

@test "renovate version matches Containerfile" {
    run renovate --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"${EXPECTED_RENOVATE_VERSION}"* ]]
}

# Core tools required by apply-templates

@test "git is installed" {
    run git --version
    [ "$status" -eq 0 ]
}

@test "bats is installed" {
    run bats --version
    [ "$status" -eq 0 ]
}

@test "apply-templates is on PATH and executable" {
    run which apply-templates
    [ "$status" -eq 0 ]
    [ -x "$(which apply-templates)" ]
}

@test "post-create is on PATH and executable" {
    run which post-create
    [ "$status" -eq 0 ]
    [ -x "$(which post-create)" ]
}

# Developer experience tools

@test "jq is installed" {
    run jq --version
    [ "$status" -eq 0 ]
}

@test "curl is installed" {
    run curl --version
    [ "$status" -eq 0 ]
}

@test "gh is installed" {
    run gh --version
    [ "$status" -eq 0 ]
}

@test "bat is installed and symlinked from batcat" {
    run bat --version
    [ "$status" -eq 0 ]
}

@test "tree is installed" {
    run tree --version
    [ "$status" -eq 0 ]
}

@test "zsh is installed" {
    run zsh --version
    [ "$status" -eq 0 ]
}

@test "ssh client is installed" {
    run ssh -V
    [ "$status" -eq 0 ]
}

@test "fd is installed and symlinked from fdfind" {
    run fd --version
    [ "$status" -eq 0 ]
}

@test "delta is installed" {
    run delta --version
    [ "$status" -eq 0 ]
}

@test "fzf is installed" {
    run fzf --version
    [ "$status" -eq 0 ]
}

@test "ripgrep is installed" {
    run rg --version
    [ "$status" -eq 0 ]
}

@test "tmux is installed" {
    run tmux -V
    [ "$status" -eq 0 ]
}

@test "bubblewrap is installed" {
    run bwrap --version
    [ "$status" -eq 0 ]
}

@test "hunspell is installed" {
    run hunspell --version
    [ "$status" -eq 0 ]
}

@test "socat is installed" {
    run socat -V
    [ "$status" -eq 0 ]
}

@test "claude is installed" {
    run claude --version
    [ "$status" -eq 0 ]
}

# Shell environment

@test "zsh is the default shell for root" {
    run getent passwd root
    [ "$status" -eq 0 ]
    [[ "$output" == */bin/zsh ]]
}

@test "oh-my-zsh is installed" {
    [ -d "$HOME/.oh-my-zsh" ]
}

@test "zsh is the default shell for dev" {
    run getent passwd dev
    [ "$status" -eq 0 ]
    [[ "$output" == */bin/zsh ]]
}

@test "oh-my-zsh is installed for dev" {
    [ -d "/home/dev/.oh-my-zsh" ]
}

@test "dev has passwordless sudo" {
    run sudo -n true
    [ "$status" -eq 0 ]
}
