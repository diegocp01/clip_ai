#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/clippy-layout-test.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "${TMPDIR:-/tmp}/clippy-swift-module-cache" \
  -framework AppKit "$project_dir/desktop/IslandLayout.swift" "$project_dir/desktop/IslandMotion.swift" \
  "$project_dir/test/native/main.swift" -o "$test_dir/layout-test"
"$test_dir/layout-test"
