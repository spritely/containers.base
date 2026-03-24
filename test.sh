#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="apply-templates-test"
CONTAINERFILE="./src/Containerfile"
INSTALL_SCRIPT="./src/install-devtools.sh"

# Extract version defaults from install-devtools.sh
# Matches lines like: YQ_VERSION="${YQ_VERSION:-4.52.4}"
extract_version() {
    grep -m1 "^${1}=" "$INSTALL_SCRIPT" | sed 's/.*:-\(.*\)}.*/\1/'
}

COPIER_VERSION=$(extract_version COPIER_VERSION)
YQ_VERSION=$(extract_version YQ_VERSION)
CODEX_VERSION=$(extract_version CODEX_VERSION)

echo "Building image..."
docker build -f "$CONTAINERFILE" -t "$IMAGE_NAME" ./src

echo "Running tests..."
mkdir -p test-results
docker run --rm \
    -v "$(pwd)/tests:/tests:ro" \
    -v "$(pwd)/test-results:/test-results" \
    -e "EXPECTED_COPIER_VERSION=$COPIER_VERSION" \
    -e "EXPECTED_YQ_VERSION=$YQ_VERSION" \
    -e "EXPECTED_CODEX_VERSION=$CODEX_VERSION" \
    --entrypoint bats \
    "$IMAGE_NAME" \
    --report-formatter junit --output /test-results \
    /tests/container.bats /tests/apply-templates.bats
