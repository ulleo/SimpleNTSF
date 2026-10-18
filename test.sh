#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/simplentfs-tests.XXXXXX")"
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(find "$ROOT/Sources/Models" "$ROOT/Sources/Services" "$ROOT/Sources/Utilities" -name '*.swift' ! -name 'SimpleNTFSApp.swift' | sort)
SDK="$(xcrun --show-sdk-path)"
for test in "$ROOT"/Tests/*Tests.swift; do
    name="$(basename "$test" .swift)"
    if [[ $# -gt 0 && " $* " != *" $name "* ]]; then continue; fi
    swiftc -sdk "$SDK" -target arm64-apple-macos12.0 "${SOURCES[@]}" "$test" -o "$TEST_BUILD_DIR/$name"
    "$TEST_BUILD_DIR/$name"
done
