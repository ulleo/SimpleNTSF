#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="$SCRIPT_DIR/Sources"
BUILD_DIR="$SCRIPT_DIR/.build"
APP_DIR="$SCRIPT_DIR/apps/SimpleNTFS.app/Contents/MacOS"

echo "🔨 开始编译..."
rm -rf "$BUILD_DIR"/*
mkdir -p "$BUILD_DIR" "$APP_DIR"

# 收集所有 Swift 源文件
SWIFT_FILES=(
    "$SOURCES_DIR/Utilities/Constants.swift"
    "$SOURCES_DIR/Utilities/MountPoint.swift"
    "$SOURCES_DIR/Models/DiskInfo.swift"
    "$SOURCES_DIR/Models/VolumeOperation.swift"
    "$SOURCES_DIR/Models/PhysicalDisk.swift"
    "$SOURCES_DIR/Services/DiskManager.swift"
    "$SOURCES_DIR/Services/PermissionConfiguration.swift"
    "$SOURCES_DIR/Views/DiskRow.swift"
    "$SOURCES_DIR/Views/DiskListItem.swift"
    "$SOURCES_DIR/Views/AddDiskSheet.swift"
    "$SOURCES_DIR/Views/EditMountPointSheet.swift"
    "$SOURCES_DIR/Views/ContentView.swift"
    "$SOURCES_DIR/SimpleNTFSApp.swift"
)

swiftc \
    -sdk $(xcrun --show-sdk-path) \
    -target arm64-apple-macos12.0 \
    -O \
    "${SWIFT_FILES[@]}" \
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
