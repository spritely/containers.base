#!/usr/bin/env bats

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

# Core tools required by apply-templates

@test "git is installed" {
    run git --version
    [ "$status" -eq 0 ]
}

@test "python3 is installed" {
    run python3 --version
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

# Developer experience tools

@test "jq is installed" {
    run jq --version
    [ "$status" -eq 0 ]
}

@test "curl is installed" {
    run curl --version
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

@test "uv is installed" {
    run uv --version
    [ "$status" -eq 0 ]
}

@test "claude is installed" {
    run claude --version
    [ "$status" -eq 0 ]
}

# Shell environment

@test "zsh is the default shell" {
    run getent passwd root
    [ "$status" -eq 0 ]
    [[ "$output" == */bin/zsh ]]
}

@test "oh-my-zsh is installed" {
    [ -d "$HOME/.oh-my-zsh" ]
}
