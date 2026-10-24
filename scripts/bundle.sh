#!/usr/bin/env bash
# Builds BlaskSync and wraps it in build/BlaskSync.app.
# Usage: scripts/bundle.sh [debug|release]
# UNIVERSAL=1 builds for both Apple Silicon and Intel. VERSION (e.g. 1.2.0) and BUILD_NUMBER, if set,
# are stamped into the app's Info.plist.
# Signs with SIGN_IDENTITY if set, else the first "Apple Development" certificate, else ad hoc.
# Ad-hoc builds lose the Screen Recording permission on every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
ARCH_FLAGS=()
[[ "${UNIVERSAL:-0}" == 1 ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}"
BIN_DIR="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" --show-bin-path)"

APP="build/BlaskSync.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/BlaskSync" "$APP/Contents/MacOS/BlaskSync"
# SwiftPM links Sparkle from next to the executable; in the bundle it lives in Contents/Frameworks.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/BlaskSync"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[[ -n "${VERSION:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
[[ -n "${BUILD_NUMBER:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
# Sparkle's nested helpers first, then the app, so every piece carries the same signature.
codesign --force --deep --sign "${IDENTITY:--}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad hoc}"

echo "Built $APP"
