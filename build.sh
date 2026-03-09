#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="$SCRIPT_DIR/Sources"
BUILD_DIR="$SCRIPT_DIR/.build"
APP_DIR="$SCRIPT_DIR/apps/SimpleNTFS.app/Contents/MacOS"

echo "🔨 开始编译..."
rm -rf "$BUILD_DIR"/*
mkdir -p "$BUILD_DIR" "$APP_DIR"

swiftc \
    -sdk $(xcrun --show-sdk-path) \
    -target arm64-apple-macos12.0 \
    -O \
    "$SOURCES_DIR/ContentView.swift" \
    "$SOURCES_DIR/SimpleNTFSApp.swift" \
    -o "$BUILD_DIR/SimpleNTFS"

cp "$BUILD_DIR/SimpleNTFS" "$APP_DIR/"

cat > "$SCRIPT_DIR/apps/SimpleNTFS.app/Contents/Info.plist" << 'PLIST'
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

echo "✅ 编译完成！"
