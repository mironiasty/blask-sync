#!/usr/bin/env bash
# Builds BlaskSync and wraps it in build/BlaskSync.app.
# Usage: scripts/bundle.sh [debug|release]   (SIGN_IDENTITY overrides ad-hoc signing)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/BlaskSync.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/BlaskSync" "$APP/Contents/MacOS/BlaskSync"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"

echo "Built $APP"
