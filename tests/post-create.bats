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
    # Never let configure_mount_ownership fall through to the real /src —
    # without this, every test here (not just the ones for that function)
    # would run a real recursive chown against this actual checkout.
    export WORKSPACE_DIR="$(mktemp -d)"
    # Feed mount discovery an empty fixture by default so it never reads the
    # real kernel mount table; ownership tests populate it via add_mount.
    export MOUNTINFO="$CAPTURE_DIR/mountinfo"
    : > "$MOUNTINFO"
    # Pin $SUDO's detection to "already root" so it stays out of the way of
    # the mocks above regardless of which real user runs bats.
    mock_id 0
}

teardown() {
    rm -rf "$BIN" "$GIT_CONFIG_GLOBAL" "$CAPTURE_DIR" "$HOME" "$CA_CERTIFICATES_DIR" "$WORKSPACE_DIR"
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

# Put a fake id on PATH reporting the given UID/GID (root=0 by default). sudo
# resets PATH, which would otherwise let it bypass every mock above once
# post-create runs $SUDO-prefixed commands as non-root — pinning id keeps
# $SUDO's own detection (and therefore all the mocking) deterministic.
# Usage: mock_id [UID] [GID]
mock_id() {
    local uid="${1:-0}" gid="${2:-${1:-0}}"
    cat > "$BIN/id" <<EOF
#!/usr/bin/env bash
case "\$1" in
    -u) echo "$uid"; exit 0 ;;
    -g) echo "$gid"; exit 0 ;;
esac
exit 1
EOF
    chmod +x "$BIN/id"
}

# Put a fake sudo on PATH that just execs through — proves a $SUDO-prefixed
# call reached sudo without needing real privilege escalation in the test
# sandbox.
mock_sudo() {
    cat > "$BIN/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
    chmod +x "$BIN/sudo"
}

# Put a fake chown on PATH that records its arguments instead of touching
# real ownership (the test sandbox may not have permission to chown to an
# arbitrary UID). Appends, so tests that normalize several mounts can assert
# on each chown independently. Cross-test isolation is unaffected: CAPTURE_DIR
# is a fresh mktemp per setup() and removed in teardown(), so chown-args never
# survives from one test into the next.
mock_chown() {
    cat > "$BIN/chown" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CAPTURE_DIR/chown-args"
exit 0
EOF
    chmod +x "$BIN/chown"
}

# Append a mountinfo(5) line for MOUNTPOINT to the MOUNTINFO fixture. The
# defaults describe a writable host bind mount (the case we care about); pass
# FSTYPE/OPTIONS to exercise the filters. Includes an optional field (shared:1)
# so the parser's handling of the variable pre-"-" section is covered.
# Usage: add_mount MOUNTPOINT [FSTYPE] [OPTIONS]
add_mount() {
    local mp="$1" fstype="${2:-ext4}" opts="${3:-rw,relatime}"
    printf '36 35 8:3 /host%s %s %s shared:1 - %s /dev/sda3 rw\n' \
        "$mp" "$mp" "$opts" "$fstype" >> "$MOUNTINFO"
}

# Put a fake stat on PATH reporting the given UID for "-c %u" queries — makes
# configure_mount_ownership's owner check deterministic regardless of real user.
# Usage: mock_stat_owner UID
mock_stat_owner() {
    local uid="$1"
    cat > "$BIN/stat" <<EOF
#!/usr/bin/env bash
[[ "\$1 \$2" == "-c %u" ]] && { echo "$uid"; exit 0; }
exit 1
EOF
    chmod +x "$BIN/stat"
}

get_name() { git config --global --get user.name; }
get_email() { git config --global --get user.email; }
get_pager() { git config --global --get core.pager; }

# configure_mount_ownership

@test "leaves workspace ownership alone when it already matches the current user" {
    mock_id 1000
    mock_stat_owner 1000
    export WORKSPACE_DIR="$(mktemp -d)"
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Fixed ownership"* ]]
}

@test "chowns the workspace via sudo when it's root-owned and the current user isn't root" {
    mock_id 1000
    mock_stat_owner 0
    mock_sudo
    mock_chown
    export WORKSPACE_DIR="$(mktemp -d)"
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$(cat "$CAPTURE_DIR/chown-args")" == *"1000:1000 $WORKSPACE_DIR"* ]]
    [[ "$output" == *"Fixed ownership"* ]]
}

@test "uses HOST_UID and HOST_GID for chown when they differ from the container user" {
    mock_id 1000
    mock_stat_owner 0
    mock_sudo
    mock_chown
    export HOST_UID=1000
    export HOST_GID=100
    export WORKSPACE_DIR="$(mktemp -d)"
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$(cat "$CAPTURE_DIR/chown-args")" == *"1000:100 $WORKSPACE_DIR"* ]]
}

@test "warns but leaves ownership alone when owned by a different non-root user" {
    mock_id 1000
    mock_stat_owner 2000
    mock_sudo
    mock_chown
    export WORKSPACE_DIR="$(mktemp -d)"
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$CAPTURE_DIR/chown-args" ]
    [[ "$output" == *"owned by uid 2000"* ]]
}

@test "discovers and chowns an overflow-owned bind mount under HOME" {
    mock_id 1000
    mock_stat_owner 65534   # overflow uid — a host inode outside our userns map
    mock_sudo
    mock_chown
    mkdir -p "$HOME/.codex"
    add_mount "$HOME/.codex"
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$(cat "$CAPTURE_DIR/chown-args")" == *"1000:1000 $HOME/.codex"* ]]
    [[ "$output" == *"Fixed ownership of $HOME/.codex"* ]]
}

@test "skips VS Code's own server mount even when it needs fixing" {
    mock_id 1000
    mock_stat_owner 65534
    mock_sudo
    mock_chown
    mkdir -p "$HOME/.vscode-server" "$HOME/.codex"
    add_mount "$HOME/.vscode-server"
    add_mount "$HOME/.codex"
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$(cat "$CAPTURE_DIR/chown-args")" == *"$HOME/.codex"* ]]
    [[ "$(cat "$CAPTURE_DIR/chown-args")" != *".vscode-server"* ]]
}

@test "ignores mounts that are neither the workspace nor under HOME" {
    mock_id 1000
    mock_stat_owner 65534
    mock_sudo
    mock_chown
    add_mount "/vscode"        # a named volume, not under HOME
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$(cat "$CAPTURE_DIR/chown-args")" != *"/vscode"* ]]
}

@test "skips read-only and virtual-filesystem mounts under HOME" {
    mock_id 1000
    mock_stat_owner 65534
    mock_sudo
    mock_chown
    mkdir -p "$HOME/ro-mount" "$HOME/tmpfs-mount"
    add_mount "$HOME/ro-mount" ext4 ro,relatime
    add_mount "$HOME/tmpfs-mount" tmpfs rw,relatime
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$(cat "$CAPTURE_DIR/chown-args")" != *"ro-mount"* ]]
    [[ "$(cat "$CAPTURE_DIR/chown-args")" != *"tmpfs-mount"* ]]
}

@test "collapses a nested mount into its parent so it is chowned only once" {
    mock_id 1000
    mock_stat_owner 65534
    mock_sudo
    mock_chown
    mkdir -p "$HOME/.config/gh"
    add_mount "$HOME/.config"
    add_mount "$HOME/.config/gh"
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    # The recursive chown of the parent covers the child, so the child must not
    # appear as its own chown.
    [[ "$(cat "$CAPTURE_DIR/chown-args")" == *"$HOME/.config"* ]]
    [[ "$(cat "$CAPTURE_DIR/chown-args")" != *"$HOME/.config/gh"* ]]
}

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

@test "uses sudo for proxy CA trust when not root" {
    mock_id 1000
    mock_sudo
    export PROXY_CA_SOURCE="$CAPTURE_DIR/ca.pem"
    echo "FAKE CA" > "$PROXY_CA_SOURCE"
    mock_gh 0 '{"login":"octocat","name":"The Octocat","id":583231}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$CA_CERTIFICATES_DIR/mitmproxy.crt" ]
    [ "$(cat "$CA_CERTIFICATES_DIR/mitmproxy.crt")" = "FAKE CA" ]
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
