#!/usr/bin/env bats

SCRIPT="$(dirname "${BATS_TEST_FILENAME}")/../src/post-create"

setup() {
    # Isolate global git config writes to a throwaway file, and neutralize system
    # config, so the script never touches the real environment.
    BIN=$(mktemp -d)
    PATH="$BIN:$PATH"
    export GIT_CONFIG_GLOBAL="$(mktemp)"
    export GIT_CONFIG_SYSTEM=/dev/null
    unset GITHUB_TOKEN
    CAPTURE_DIR=$(mktemp -d)
    # Isolate ~/.claude.json writes from the real home directory.
    export HOME="$(mktemp -d)"
    # Isolate the proxy-CA install from the real trust store. PROXY_CA_SOURCE
    # defaults to a missing path so the certificate authority install no-ops unless a test provides
    # it; stub update-ca-certificates so it never touches the host.
    export CA_CERTIFICATES_DIR="$(mktemp -d)"
    export PROXY_CA_SOURCE="$CAPTURE_DIR/missing-ca.pem"
    cat > "$BIN/update-ca-certificates" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$BIN/update-ca-certificates"
}

teardown() {
    rm -rf "$BIN" "$GIT_CONFIG_GLOBAL" "$CAPTURE_DIR" "$HOME" "$CA_CERTIFICATES_DIR"
}

# Put a fake gh on PATH.
# Usage: mock_gh AUTH_EXIT USER_JSON [API_USER_EXIT]
mock_gh() {
    local auth_exit="$1" user_json="$2" api_user_exit="${3:-0}"
    cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2" == "auth status" ]]; then exit $auth_exit; fi
if [[ "\$1 \$2" == "api user" ]]; then echo '$user_json'; exit $api_user_exit; fi
EOF
    chmod +x "$BIN/gh"
}

# Put a fake apparmor_parser on PATH.
# Usage: mock_apparmor_parser EXIT_CODE
mock_apparmor_parser() {
    local exit_code="$1"
    cat > "$BIN/apparmor_parser" <<EOF
#!/usr/bin/env bash
exit $exit_code
EOF
    chmod +x "$BIN/apparmor_parser"
}

# Put a fake sysctl on PATH reporting the given userns-restriction value.
# Usage: mock_sysctl RESTRICTION_VALUE
mock_sysctl() {
    local restriction="$1"
    cat > "$BIN/sysctl" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2" == "-n kernel.apparmor_restrict_unprivileged_userns" ]]; then
    echo "$restriction"
    exit 0
fi
exit 1
EOF
    chmod +x "$BIN/sysctl"
}

# Put a fake systemctl on PATH.
# Usage: mock_systemctl IS_RUNNING_EXIT [RELOAD_EXIT]
mock_systemctl() {
    local is_running_exit="$1" reload_exit="${2:-0}"
    cat > "$BIN/systemctl" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "is-system-running" ]]; then exit $is_running_exit; fi
if [[ "\$1 \$2" == "reload apparmor" ]]; then exit $reload_exit; fi
EOF
    chmod +x "$BIN/systemctl"
}

# Put a fake tee on PATH that captures stdin instead of writing to the real path.
# Usage: mock_tee [EXIT_CODE]
mock_tee() {
    local exit_code="${1:-0}"
    cat > "$BIN/tee" <<EOF
#!/usr/bin/env bash
cat > "$CAPTURE_DIR/tee-output"
exit $exit_code
EOF
    chmod +x "$BIN/tee"
}

get_name() { git config --global --get user.name; }
get_email() { git config --global --get user.email; }
get_pager() { git config --global --get core.pager; }

# configure_proxy_ca

@test "installs the proxy certificate authority into the trust store when present" {
    export PROXY_CA_SOURCE="$CAPTURE_DIR/ca.pem"
    echo "FAKE CA" > "$PROXY_CA_SOURCE"
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$CA_CERTIFICATES_DIR/mitmproxy.crt" ]
    [ "$(cat "$CA_CERTIFICATES_DIR/mitmproxy.crt")" = "FAKE CA" ]
    [[ "$output" == *"Trusted credential proxy certificate authority"* ]]
}

@test "warns and continues when the proxy certificate authority is absent" {
    # PROXY_CA_SOURCE defaults to a missing path (see setup).
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$CA_CERTIFICATES_DIR/mitmproxy.crt" ]
    [[ "$output" == *"Proxy certificate authority not found"* ]]
}

@test "configure_proxy_ca is idempotent" {
    export PROXY_CA_SOURCE="$CAPTURE_DIR/ca.pem"
    echo "FAKE CA" > "$PROXY_CA_SOURCE"
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$CA_CERTIFICATES_DIR/mitmproxy.crt")" = "FAKE CA" ]
}

# configure_identity

@test "sets name and email from GitHub when unset" {
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(get_name)" = "The Octocat" ]
    [ "$(get_email)" = "583231+octocat@users.noreply.github.com" ]
}

@test "falls back to login when name is null" {
    mock_gh 0 '{"login":"octocat","name":null,"id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(get_name)" = "octocat" ]
    [ "$(get_email)" = "583231+octocat@users.noreply.github.com" ]
}

@test "does not overwrite an existing identity" {
    git config --global user.name "Existing Name"
    git config --global user.email "existing@example.com"
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(get_name)" = "Existing Name" ]
    [ "$(get_email)" = "existing@example.com" ]
}

@test "sets only the missing field" {
    git config --global user.name "Existing Name"
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(get_name)" = "Existing Name" ]
    [ "$(get_email)" = "583231+octocat@users.noreply.github.com" ]
}

@test "skips and exits 0 when gh is not authenticated" {
    mock_gh 1 ''
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run git config --global --get user.name
    [ "$status" -ne 0 ]
    run git config --global --get user.email
    [ "$status" -ne 0 ]
}

@test "skips and exits 0 when gh api user fails" {
    mock_gh 0 '' 1
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Could not fetch GitHub user info"* ]]
    run git config --global --get user.name
    [ "$status" -ne 0 ]
    run git config --global --get user.email
    [ "$status" -ne 0 ]
}

@test "is idempotent" {
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(get_name)" = "The Octocat" ]
    [ "$(get_email)" = "583231+octocat@users.noreply.github.com" ]
}

# configure_pager

@test "sets delta as the diff pager" {
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(get_pager)" = "delta" ]
}

@test "does not overwrite an existing pager setting" {
    git config --global core.pager less
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(get_pager)" = "less" ]
}

# Cross-function behavior

@test "still trusts the proxy certificate authority and sets the pager when identity is already set" {
    export PROXY_CA_SOURCE="$CAPTURE_DIR/ca.pem"
    echo "FAKE CA" > "$PROXY_CA_SOURCE"
    git config --global user.name "Existing Name"
    git config --global user.email "existing@example.com"
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$CA_CERTIFICATES_DIR/mitmproxy.crt" ]
    [ "$(get_pager)" = "delta" ]
}

# configure_apparmor_exception

@test "skips the AppArmor exception entirely when apparmor_parser is not installed" {
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    mock_tee
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$CAPTURE_DIR/tee-output" ]
}

# There is no equivalent "skips when bwrap is not installed" test. Unlike
# apparmor_parser, bwrap is genuinely installed wherever these tests run
# (see install-devtools.sh), and hiding it would mean restricting PATH to
# only $BIN — which breaks cat/rm/chmod, since the mock helpers and
# teardown depend on real coreutils being reachable on PATH.

@test "skips the AppArmor exception when the userns restriction is not active" {
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    mock_apparmor_parser 0
    mock_sysctl 0
    mock_tee
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$CAPTURE_DIR/tee-output" ]
}

@test "installs the AppArmor exception via apparmor_parser when systemd is unavailable" {
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    mock_apparmor_parser 0
    mock_sysctl 1
    mock_systemctl 1
    mock_tee
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$(cat "$CAPTURE_DIR/tee-output")" == *"profile bwrap"* ]]
    [[ "$output" == *"Installed and reloaded (via apparmor_parser)"* ]]
}

@test "installs the AppArmor exception via systemctl reload when systemd is running" {
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    mock_apparmor_parser 0
    mock_sysctl 1
    mock_systemctl 0 0
    mock_tee
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Installed and reloaded AppArmor userns exception"* ]]
}

@test "warns instead of failing when the AppArmor reload fails" {
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    mock_apparmor_parser 1
    mock_sysctl 1
    mock_systemctl 1
    mock_tee
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Could not load AppArmor profile"* ]]
}

# configure_claude

get_claude_json_field() { jq -r "$1" "$HOME/.claude.json"; }

@test "creates ~/.claude.json with onboarding defaults when absent" {
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(get_claude_json_field '.hasCompletedOnboarding')" = "true" ]
    [ "$(get_claude_json_field '.installMethod')" = "native" ]
    [ "$(get_claude_json_field '.projects["/src"].hasTrustDialogAccepted')" = "true" ]
}

@test "merges defaults into an existing ~/.claude.json without clobbering other keys" {
    echo '{"oauthAccount":{"foo":"bar"},"projects":{"/other":{"hasTrustDialogAccepted":false}}}' > "$HOME/.claude.json"
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(get_claude_json_field '.oauthAccount.foo')" = "bar" ]
    [ "$(get_claude_json_field '.projects["/other"].hasTrustDialogAccepted')" = "false" ]
    [ "$(get_claude_json_field '.projects["/src"].hasTrustDialogAccepted')" = "true" ]
    [ "$(get_claude_json_field '.hasCompletedOnboarding')" = "true" ]
}

@test "overrides an existing value that conflicts with our defaults" {
    echo '{"hasCompletedOnboarding": false}' > "$HOME/.claude.json"
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(get_claude_json_field '.hasCompletedOnboarding')" = "true" ]
}

@test "replaces a corrupted ~/.claude.json with defaults instead of leaving it broken" {
    echo 'not valid json{{' > "$HOME/.claude.json"
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(get_claude_json_field '.hasCompletedOnboarding')" = "true" ]
}

@test "does not leave a stray .claude.json.tmp file behind" {
    echo 'not valid json{{' > "$HOME/.claude.json"
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$HOME/.claude.json.tmp" ]
}

@test "configure_claude is idempotent" {
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(get_claude_json_field '.hasCompletedOnboarding')" = "true" ]
    [ "$(get_claude_json_field '.projects["/src"].hasTrustDialogAccepted')" = "true" ]
}
