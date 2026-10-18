#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="$SCRIPT_DIR/Sources"
BUILD_DIR="${SIMPLENTFS_BUILD_DIR:-$SCRIPT_DIR/.build}"
APP_BUNDLE="${SIMPLENTFS_APP_DIR:-$SCRIPT_DIR/apps/SimpleNTFS.app}"
SDK="${SDKROOT:-$(xcrun --show-sdk-path)}"

mkdir -p "$BUILD_DIR"
STAGING_DIR="$(mktemp -d "$BUILD_DIR/compile.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

SWIFT_FILES=()
while IFS= read -r source; do SWIFT_FILES+=("$source"); done < <(find "$SOURCES_DIR" -name '*.swift' -type f | LC_ALL=C sort)

echo "🔨 开始编译..."
swiftc -sdk "$SDK" -target arm64-apple-macos12.0 -O "${SWIFT_FILES[@]}" -o "$STAGING_DIR/SimpleNTFS"

# Publish only after a successful compile; never clear an existing build or app directory.
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$STAGING_DIR/SimpleNTFS" "$BUILD_DIR/SimpleNTFS"
cp "$STAGING_DIR/SimpleNTFS" "$APP_BUNDLE/Contents/MacOS/SimpleNTFS"

cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>SimpleNTFS</string>
    <key>CFBundleIdentifier</key><string>com.local.simplentfs</string>
    <key>CFBundleName</key><string>SimpleNTFS</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "✅ 编译完成：$APP_BUNDLE"
