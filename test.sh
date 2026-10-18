#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Validate selectors before compiling anything, so typos cannot silently skip all tests.
TEST_FILES=("$ROOT"/Tests/*Tests.swift)
for requested in "$@"; do
    found=false
    for test in "${TEST_FILES[@]}"; do
        if [[ "$(basename "$test" .swift)" == "$requested" ]]; then found=true; break; fi
    done
    if [[ "$found" == false ]]; then
        echo "Unknown test suite: $requested" >&2
        echo "Available suites:" >&2
        for test in "${TEST_FILES[@]}"; do basename "$test" .swift >&2; done
        exit 2
    fi
done
TEST_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/simplentfs-tests.XXXXXX")"
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(find "$ROOT/Sources/Models" "$ROOT/Sources/Services" "$ROOT/Sources/Utilities" -name '*.swift' ! -name 'SimpleNTFSApp.swift' | sort)
SDK="${SDKROOT:-$(xcrun --show-sdk-path)}"
for test in "${TEST_FILES[@]}"; do
    name="$(basename "$test" .swift)"
    if [[ $# -gt 0 ]]; then
        selected=false
        for requested in "$@"; do if [[ "$requested" == "$name" ]]; then selected=true; break; fi; done
        if [[ "$selected" == false ]]; then continue; fi
    fi
    swiftc -sdk "$SDK" -target arm64-apple-macos12.0 "${SOURCES[@]}" "$test" -o "$TEST_BUILD_DIR/$name"
    "$TEST_BUILD_DIR/$name"
done
