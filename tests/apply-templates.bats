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
