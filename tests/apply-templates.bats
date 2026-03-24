#!/usr/bin/env bats

FIXTURE_DIR="/tests/fixtures"

setup() {
    TEST_DIR=$(mktemp -d)
    TARGET_DIR=$(mktemp -d)
    CONFIG_DIR="$TEST_DIR/.templates"
    mkdir -p "$CONFIG_DIR"
    cd "$TEST_DIR"

    # Use env vars instead of git config to avoid mutating global state
    export GIT_AUTHOR_NAME="Test"
    export GIT_AUTHOR_EMAIL="test@test.com"
    export GIT_COMMITTER_NAME="Test"
    export GIT_COMMITTER_EMAIL="test@test.com"
    # Prevent "dubious ownership" errors in CI containers
    export GIT_CONFIG_COUNT=1
    export GIT_CONFIG_KEY_0=safe.directory
    export GIT_CONFIG_VALUE_0='*'
}

teardown() {
    rm -rf "$TEST_DIR" "$TARGET_DIR"
}

# --- Helpers ---

# Create a bare git repo from a fixture directory.
# Usage: create_git_repo REPO_DIR FIXTURE_DIR [--tag TAG]
create_git_repo() {
    local repo_dir="$1"
    local fixture_dir="$2"
    local tag=""
    if [[ "${3:-}" == "--tag" ]]; then
        tag="$4"
    fi

    mkdir -p "$repo_dir"
    git -C "$repo_dir" init --bare 2>/dev/null

    local work_dir
    work_dir=$(mktemp -d)
    git clone "$repo_dir" "$work_dir/checkout" 2>/dev/null
    cp -a "$fixture_dir"/. "$work_dir/checkout/"

    git -C "$work_dir/checkout" add -A
    git -C "$work_dir/checkout" commit -m "initial" 2>/dev/null
    if [[ -n "$tag" ]]; then
        git -C "$work_dir/checkout" tag "$tag"
        git -C "$work_dir/checkout" push --tags 2>/dev/null
    fi
    git -C "$work_dir/checkout" push 2>/dev/null

    rm -rf "$work_dir"
}

# Create a copier template git repo from the copier fixture.
# Usage: create_copier_template DEST TAG
create_copier_template() {
    local dest="$1"
    local tag="$2"

    cp -a "$FIXTURE_DIR/copier-template" "$dest"
    git -C "$dest" init 2>/dev/null
    git -C "$dest" add -A
    git -C "$dest" commit -m "init" 2>/dev/null
    git -C "$dest" tag "$tag"
}

# Assert a file exists and contains the expected content.
assert_file_content() {
    local file="$1"
    local expected="$2"
    [[ -f "$file" ]] || { echo "File not found: $file"; return 1; }
    local actual
    actual=$(cat "$file")
    [[ "$actual" == "$expected" ]] || {
        echo "Content mismatch in $file"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        return 1
    }
}

# ===== CLI tests =====

@test "cli: --help prints usage" {
    run apply-templates --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "cli: unknown argument errors" {
    run apply-templates --bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown argument"* ]]
}

# ===== Validation tests =====

@test "validation: missing config prints useful error" {
    run apply-templates --config-dir "$TEST_DIR/nonexistent"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Config file not found"* ]]
}

@test "validation: errors when both config.yaml and config.yml exist" {
    echo "templates: []" > "$CONFIG_DIR/config.yaml"
    echo "templates: []" > "$CONFIG_DIR/config.yml"

    run apply-templates --config-dir "$CONFIG_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Both"* ]]
    [[ "$output" == *"Use one or the other"* ]]
}

@test "validation: missing name field errors" {
    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - source: /some/path
    target: $TARGET_DIR
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing required 'name' field"* ]]
}

@test "validation: missing source field errors" {
    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: no-source
    target: $TARGET_DIR
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing required 'source' field"* ]]
}

@test "validation: unknown type errors" {
    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: bad-type
    type: foobar
    source: /some/path
    target: $TARGET_DIR
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown template type"* ]]
}

# ===== Git type tests =====

@test "git: copies files and excludes .git" {
    local repo_dir="$TEST_DIR/repo.git"
    create_git_repo "$repo_dir" "$FIXTURE_DIR/basic-template"

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: test-template
    source: $repo_dir
    target: $TARGET_DIR
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    [ "$status" -eq 0 ]
    assert_file_content "$TARGET_DIR/hello.txt" "hello world"
    assert_file_content "$TARGET_DIR/subdir/nested.txt" "nested content"
    [ ! -d "$TARGET_DIR/.git" ]
}

@test "git: respects ref field" {
    local repo_dir="$TEST_DIR/tagged-repo.git"
    create_git_repo "$repo_dir" "$FIXTURE_DIR/basic-template" --tag v1.0.0

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: tagged-template
    source: $repo_dir
    ref: v1.0.0
    target: $TARGET_DIR
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    [ "$status" -eq 0 ]
    assert_file_content "$TARGET_DIR/hello.txt" "hello world"
}

@test "git: defaults when type omitted" {
    local repo_dir="$TEST_DIR/default-repo.git"
    create_git_repo "$repo_dir" "$FIXTURE_DIR/basic-template"

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: default-type
    source: $repo_dir
    target: $TARGET_DIR
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    [ "$status" -eq 0 ]
    assert_file_content "$TARGET_DIR/hello.txt" "hello world"
}

# ===== Path field tests =====

@test "path: git type copies only files from subdirectory" {
    local repo_dir="$TEST_DIR/subdir-repo.git"
    create_git_repo "$repo_dir" "$FIXTURE_DIR/subdir-template"

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: subdir-template
    source: $repo_dir
    path: src
    target: $TARGET_DIR
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    [ "$status" -eq 0 ]
    assert_file_content "$TARGET_DIR/hello.txt" "hello from subdir"
    assert_file_content "$TARGET_DIR/subdir/nested.txt" "nested in subdir"
    [ ! -f "$TARGET_DIR/README.md" ]
    [ ! -d "$TARGET_DIR/.github" ]
}

@test "path: copy type copies only files from subdirectory" {
    local source_dir="$TEST_DIR/copy-subdir-source"
    cp -a "$FIXTURE_DIR/subdir-template" "$source_dir"

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: subdir-copy
    type: copy
    source: $source_dir
    path: src
    target: $TARGET_DIR
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    [ "$status" -eq 0 ]
    assert_file_content "$TARGET_DIR/hello.txt" "hello from subdir"
    assert_file_content "$TARGET_DIR/subdir/nested.txt" "nested in subdir"
    [ ! -f "$TARGET_DIR/README.md" ]
    [ ! -d "$TARGET_DIR/.github" ]
}

@test "path: git type errors on nonexistent path" {
    local repo_dir="$TEST_DIR/bad-path-repo.git"
    create_git_repo "$repo_dir" "$FIXTURE_DIR/basic-template"

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: bad-path
    source: $repo_dir
    path: nonexistent
    target: $TARGET_DIR
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Path 'nonexistent' does not exist"* ]]
}

@test "path: copy type errors on nonexistent path" {
    local source_dir="$TEST_DIR/copy-bad-path"
    cp -a "$FIXTURE_DIR/basic-template" "$source_dir"

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: bad-copy-path
    type: copy
    source: $source_dir
    path: nonexistent
    target: $TARGET_DIR
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Source path does not exist"* ]]
}

@test "path: copier type warns and ignores path" {
    local template_dir="$TEST_DIR/copier-path-tmpl"
    create_copier_template "$template_dir" v1.0.0

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: copier-with-path
    type: copier
    source: $template_dir
    path: should-be-ignored
    ref: v1.0.0
    target: $TARGET_DIR
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not supported for copier"* ]]
    [ -f "$TARGET_DIR/README.md" ]
}

# ===== Copy type tests =====

@test "copy: copies files and excludes .git" {
    local source_dir="$TEST_DIR/copy-source"
    cp -a "$FIXTURE_DIR/basic-template" "$source_dir"
    mkdir -p "$source_dir/.git/objects"
    echo "git internal" > "$source_dir/.git/config"

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: local-copy
    type: copy
    source: $source_dir
    target: $TARGET_DIR
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    [ "$status" -eq 0 ]
    assert_file_content "$TARGET_DIR/hello.txt" "hello world"
    assert_file_content "$TARGET_DIR/subdir/nested.txt" "nested content"
    [ ! -d "$TARGET_DIR/.git" ]
}

@test "copy: errors on nonexistent source" {
    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: missing-source
    type: copy
    source: /nonexistent/path
    target: $TARGET_DIR
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Source path does not exist"* ]]
}

# ===== Copier type tests =====

@test "copier: first run uses copier copy" {
    local template_dir="$TEST_DIR/copier-tmpl"
    create_copier_template "$template_dir" v1.0.0

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: copier-test
    type: copier
    source: $template_dir
    ref: v1.0.0
    target: $TARGET_DIR
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    echo "$output"
    [ "$status" -eq 0 ]
    [ -f "$TARGET_DIR/README.md" ]
    [ -f "$TARGET_DIR/.copier-answers.copier-test.yml" ]
}

@test "copier: subsequent run uses copier update" {
    local template_dir="$TEST_DIR/copier-update-tmpl"
    create_copier_template "$template_dir" v1.0.0

    # Target must be a git repo for copier update
    git -C "$TARGET_DIR" init 2>/dev/null
    git -C "$TARGET_DIR" commit --allow-empty -m "init" 2>/dev/null

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: copier-update
    type: copier
    source: $template_dir
    ref: v1.0.0
    target: $TARGET_DIR
EOF

    # First run (copier copy)
    run apply-templates --config-dir "$CONFIG_DIR"
    echo "First run: $output"
    [ "$status" -eq 0 ]
    [ -f "$TARGET_DIR/.copier-answers.copier-update.yml" ]

    # Commit so copier update can diff
    git -C "$TARGET_DIR" add -A
    git -C "$TARGET_DIR" commit -m "first template apply" 2>/dev/null

    # Second run (copier update)
    run apply-templates --config-dir "$CONFIG_DIR"
    echo "Second run: $output"
    [ "$status" -eq 0 ]
}

# ===== File extension tests =====

@test "extension: config.yml is accepted" {
    local source_dir="$TEST_DIR/yml-source"
    mkdir -p "$source_dir"
    echo "yml content" > "$source_dir/file.txt"

    cat > "$CONFIG_DIR/config.yml" <<EOF
templates:
  - name: yml-template
    type: copy
    source: $source_dir
    target: $TARGET_DIR
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    [ "$status" -eq 0 ]
    assert_file_content "$TARGET_DIR/file.txt" "yml content"
}

@test "extension: config.local.yml is accepted" {
    local source1="$TEST_DIR/yml-shared"
    local source2="$TEST_DIR/yml-local"
    mkdir -p "$source1" "$source2"
    echo "shared" > "$source1/shared.txt"
    echo "local" > "$source2/local.txt"

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: shared-template
    type: copy
    source: $source1
    target: $TARGET_DIR
EOF

    cat > "$CONFIG_DIR/config.local.yml" <<EOF
templates:
  - name: local-template
    type: copy
    source: $source2
    target: $TARGET_DIR
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    [ "$status" -eq 0 ]
    assert_file_content "$TARGET_DIR/shared.txt" "shared"
    assert_file_content "$TARGET_DIR/local.txt" "local"
}

@test "extension: mixed extensions (config.yml + config.local.yaml)" {
    local source1="$TEST_DIR/mixed-main"
    local source2="$TEST_DIR/mixed-local"
    mkdir -p "$source1" "$source2"
    echo "main" > "$source1/main.txt"
    echo "local" > "$source2/local.txt"

    cat > "$CONFIG_DIR/config.yml" <<EOF
templates:
  - name: main-template
    type: copy
    source: $source1
    target: $TARGET_DIR
EOF

    cat > "$CONFIG_DIR/config.local.yaml" <<EOF
templates:
  - name: local-template
    type: copy
    source: $source2
    target: $TARGET_DIR
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    [ "$status" -eq 0 ]
    assert_file_content "$TARGET_DIR/main.txt" "main"
    assert_file_content "$TARGET_DIR/local.txt" "local"
}

# ===== Config tests =====

@test "config: merges shared and local configs" {
    local source1="$TEST_DIR/shared-source"
    local source2="$TEST_DIR/local-source"
    mkdir -p "$source1" "$source2"
    echo "shared" > "$source1/shared.txt"
    echo "local" > "$source2/local.txt"

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: shared-template
    type: copy
    source: $source1
    target: $TARGET_DIR
EOF

    cat > "$CONFIG_DIR/config.local.yaml" <<EOF
templates:
  - name: local-template
    type: copy
    source: $source2
    target: $TARGET_DIR
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    [ "$status" -eq 0 ]
    assert_file_content "$TARGET_DIR/shared.txt" "shared"
    assert_file_content "$TARGET_DIR/local.txt" "local"
}

@test "config: target subdirectory" {
    local source_dir="$TEST_DIR/target-source"
    mkdir -p "$source_dir"
    echo "targeted" > "$source_dir/file.txt"

    local subdir="$TARGET_DIR/subdir"

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: targeted-template
    type: copy
    source: $source_dir
    target: $subdir
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    [ "$status" -eq 0 ]
    assert_file_content "$subdir/file.txt" "targeted"
}

# ===== Integration tests =====

@test "integration: multiple templates of mixed types" {
    local repo_dir="$TEST_DIR/multi-repo.git"
    create_git_repo "$repo_dir" "$FIXTURE_DIR/basic-template"

    local copy_dir="$TEST_DIR/multi-copy"
    mkdir -p "$copy_dir"
    echo "copied" > "$copy_dir/copy.txt"

    local git_target="$TARGET_DIR/from-git"
    local copy_target="$TARGET_DIR/from-copy"

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: git-template
    type: git
    source: $repo_dir
    target: $git_target
  - name: copy-template
    type: copy
    source: $copy_dir
    target: $copy_target
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    [ "$status" -eq 0 ]
    assert_file_content "$git_target/hello.txt" "hello world"
    assert_file_content "$copy_target/copy.txt" "copied"
}

@test "integration: fail-fast stops on first failure" {
    local source_dir="$TEST_DIR/valid-source"
    mkdir -p "$source_dir"
    echo "valid" > "$source_dir/valid.txt"

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: bad-template
    type: copy
    source: /nonexistent/path/that/does/not/exist
    target: $TARGET_DIR
  - name: good-template
    type: copy
    source: $source_dir
    target: $TARGET_DIR
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    [ "$status" -ne 0 ]
    [ ! -f "$TARGET_DIR/valid.txt" ]
}

# ===== Strategy tests =====

@test "merge: deep merges JSON files" {
    local source_dir="$TEST_DIR/merge-source"
    cp -a "$FIXTURE_DIR/merge-template" "$source_dir"

    # Create base JSON file in target
    mkdir -p "$TARGET_DIR"
    echo '{"name":"base","version":"1.0","base_only":"preserved","extra":{"existing":true}}' > "$TARGET_DIR/config.json"

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: merge-json
    type: copy
    source: $source_dir
    target: $TARGET_DIR
    strategy: merge
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    echo "$output"
    [ "$status" -eq 0 ]

    # Overlay wins conflicts
    [[ "$(jq -r '.name' "$TARGET_DIR/config.json")" == "overlay" ]]
    [[ "$(jq -r '.version' "$TARGET_DIR/config.json")" == "2.0" ]]
    # Base-only keys preserved
    [[ "$(jq -r '.base_only' "$TARGET_DIR/config.json")" == "preserved" ]]
    # New nested keys added
    [[ "$(jq -r '.extra.added' "$TARGET_DIR/config.json")" == "true" ]]
    # Existing nested keys preserved
    [[ "$(jq -r '.extra.existing' "$TARGET_DIR/config.json")" == "true" ]]
}

@test "merge: deletes JSON keys set to null" {
    local source_dir="$TEST_DIR/merge-null-source"
    cp -a "$FIXTURE_DIR/merge-template" "$source_dir"

    mkdir -p "$TARGET_DIR"
    echo '{"name":"base","debug":true}' > "$TARGET_DIR/config.json"

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: merge-null
    type: copy
    source: $source_dir
    target: $TARGET_DIR
    strategy: merge
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    echo "$output"
    [ "$status" -eq 0 ]

    # debug was set to null in overlay, should be removed
    [[ "$(jq 'has("debug")' "$TARGET_DIR/config.json")" == "false" ]]
}

@test "merge: deep merges YAML files" {
    local source_dir="$TEST_DIR/merge-yaml-source"
    cp -a "$FIXTURE_DIR/merge-template" "$source_dir"

    mkdir -p "$TARGET_DIR"
    cat > "$TARGET_DIR/settings.yaml" <<'YAMLEOF'
name: base
version: "1.0"
base_only: preserved
extra:
  existing: true
YAMLEOF

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: merge-yaml
    type: copy
    source: $source_dir
    target: $TARGET_DIR
    strategy: merge
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    echo "$output"
    [ "$status" -eq 0 ]

    # Overlay wins conflicts
    [[ "$(yq '.name' "$TARGET_DIR/settings.yaml")" == "overlay" ]]
    [[ "$(yq '.version' "$TARGET_DIR/settings.yaml")" == "2.0" ]]
    # Base-only keys preserved
    [[ "$(yq '.base_only' "$TARGET_DIR/settings.yaml")" == "preserved" ]]
    # New nested keys added
    [[ "$(yq '.extra.added' "$TARGET_DIR/settings.yaml")" == "true" ]]
    # Existing nested keys preserved
    [[ "$(yq '.extra.existing' "$TARGET_DIR/settings.yaml")" == "true" ]]
}

@test "merge: deletes YAML keys set to null" {
    local source_dir="$TEST_DIR/merge-yaml-null-source"
    cp -a "$FIXTURE_DIR/merge-template" "$source_dir"

    mkdir -p "$TARGET_DIR"
    cat > "$TARGET_DIR/settings.yaml" <<'YAMLEOF'
name: base
debug: true
YAMLEOF

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: merge-yaml-null
    type: copy
    source: $source_dir
    target: $TARGET_DIR
    strategy: merge
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    echo "$output"
    [ "$status" -eq 0 ]

    # debug was set to null in overlay, should be removed
    [[ "$(yq 'has("debug")' "$TARGET_DIR/settings.yaml")" == "false" ]]
}

@test "merge: overwrites non-JSON/YAML files" {
    local source_dir="$TEST_DIR/merge-plain-source"
    cp -a "$FIXTURE_DIR/merge-template" "$source_dir"

    mkdir -p "$TARGET_DIR"
    echo "original content" > "$TARGET_DIR/plain.txt"

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: merge-plain
    type: copy
    source: $source_dir
    target: $TARGET_DIR
    strategy: merge
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    echo "$output"
    [ "$status" -eq 0 ]

    assert_file_content "$TARGET_DIR/plain.txt" "overlay content"
}

@test "merge: copies new files not in target" {
    local source_dir="$TEST_DIR/merge-new-source"
    cp -a "$FIXTURE_DIR/merge-template" "$source_dir"

    mkdir -p "$TARGET_DIR"
    # Don't create new-file.json in target — it should be copied

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: merge-new
    type: copy
    source: $source_dir
    target: $TARGET_DIR
    strategy: merge
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    echo "$output"
    [ "$status" -eq 0 ]

    [[ "$(jq -r '.brand' "$TARGET_DIR/new-file.json")" == "new" ]]
}

@test "merge: works with git type" {
    local repo_dir="$TEST_DIR/merge-repo.git"
    create_git_repo "$repo_dir" "$FIXTURE_DIR/merge-template"

    mkdir -p "$TARGET_DIR"
    echo '{"name":"base","version":"1.0","base_only":"preserved"}' > "$TARGET_DIR/config.json"

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: merge-git
    type: git
    source: $repo_dir
    target: $TARGET_DIR
    strategy: merge
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    echo "$output"
    [ "$status" -eq 0 ]

    [[ "$(jq -r '.name' "$TARGET_DIR/config.json")" == "overlay" ]]
    [[ "$(jq -r '.base_only' "$TARGET_DIR/config.json")" == "preserved" ]]
}

@test "merge: default strategy is overwrite" {
    local source_dir="$TEST_DIR/default-strategy-source"
    cp -a "$FIXTURE_DIR/merge-template" "$source_dir"

    mkdir -p "$TARGET_DIR"
    echo '{"name":"base","base_only":"should_be_lost"}' > "$TARGET_DIR/config.json"

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: default-strategy
    type: copy
    source: $source_dir
    target: $TARGET_DIR
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    echo "$output"
    [ "$status" -eq 0 ]

    # Without strategy: merge, the file is overwritten entirely
    [[ "$(jq -r '.name' "$TARGET_DIR/config.json")" == "overlay" ]]
    [[ "$(jq 'has("base_only")' "$TARGET_DIR/config.json")" == "false" ]]
}

@test "merge: unknown strategy value errors" {
    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: bad-strategy
    type: copy
    source: /some/path
    target: $TARGET_DIR
    strategy: replace
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown strategy"* ]]
}

@test "merge: works with nested directories" {
    local source_dir="$TEST_DIR/merge-nested-source"
    cp -a "$FIXTURE_DIR/merge-template" "$source_dir"

    mkdir -p "$TARGET_DIR/subdir"
    echo '{"nested_key":"base_value","base_only":"kept","remove_me":"should_go"}' > "$TARGET_DIR/subdir/nested.json"

    cat > "$CONFIG_DIR/config.yaml" <<EOF
templates:
  - name: merge-nested
    type: copy
    source: $source_dir
    target: $TARGET_DIR
    strategy: merge
EOF

    run apply-templates --config-dir "$CONFIG_DIR"
    echo "$output"
    [ "$status" -eq 0 ]

    # Overlay wins
    [[ "$(jq -r '.nested_key' "$TARGET_DIR/subdir/nested.json")" == "overlay_value" ]]
    # Base-only keys preserved
    [[ "$(jq -r '.base_only' "$TARGET_DIR/subdir/nested.json")" == "kept" ]]
    # Null means delete
    [[ "$(jq 'has("remove_me")' "$TARGET_DIR/subdir/nested.json")" == "false" ]]
}
