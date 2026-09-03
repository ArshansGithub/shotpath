#!/bin/bash
# Build ShotPath.app (no third-party deps, single swiftc invocation).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/ShotPath.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

swiftc -O \
  -target arm64-apple-macos13.0 \
  -o "$APP/Contents/MacOS/ShotPath" \
  Sources/main.swift \
  -framework Cocoa \
  -framework UserNotifications \
  -framework ServiceManagement \
  -framework ImageIO \
  -framework UniformTypeIdentifiers

codesign --force --deep --sign - "$APP"
echo "Built $(pwd)/$APP"
