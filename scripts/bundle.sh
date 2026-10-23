#!/usr/bin/env bash
# Builds BlaskSync and wraps it in build/BlaskSync.app.
# Usage: scripts/bundle.sh [debug|release]
# Signs with SIGN_IDENTITY if set, else the first "Apple Development" certificate, else ad hoc.
# Ad-hoc builds lose the Screen Recording permission on every rebuild.
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
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad hoc}"

echo "Built $APP"
