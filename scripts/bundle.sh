#!/usr/bin/env bash
# Builds BlaskSync and wraps it in an app bundle.
# Usage: scripts/bundle.sh [debug|release]
# By default this is the development app, build/BlaskSync Dev.app ("Blask Sync Dev", bundle ID ending in
# .dev, DEV-badged icon, no self-updating), which installs next to the release without sharing its settings
# or permissions. VARIANT=release builds the published app, build/BlaskSync.app, as the release workflow does.
# VARIANT=appstore builds the Mac App Store app, build/AppStore/BlaskSync.app: sandboxed, without Sparkle,
# with the bundle ID in APP_STORE_BUNDLE_ID (scripts/package-appstore.sh signs and packages it for upload).
# UNIVERSAL=1 builds for both Apple Silicon and Intel. VERSION (e.g. 1.2.0) and BUILD_NUMBER, if set,
# are stamped into the app's Info.plist.
# Signs with SIGN_IDENTITY if set, else the first "Apple Development" certificate, else ad hoc. An Apple
# Distribution identity also turns on the hardened runtime and a secure timestamp, as the App Store requires. PROVISIONING_PROFILE, if set, is embedded (App Store builds need one).
# Ad-hoc builds lose the Screen Recording permission on every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
VARIANT="${VARIANT:-dev}"
BUILD_FLAGS=()
[[ "${UNIVERSAL:-0}" == 1 ]] && BUILD_FLAGS=(--arch arm64 --arch x86_64)
# The App Store variant drops Sparkle from the package (see Package.swift), so it builds in its own directory
# instead of invalidating the regular build each time.
if [[ "$VARIANT" == appstore ]]; then
    export APP_STORE=1
    BUILD_FLAGS+=(--scratch-path .build/appstore)
fi
swift build -c "$CONFIG" "${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}"
BIN_DIR="$(swift build -c "$CONFIG" "${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}" --show-bin-path)"

case "$VARIANT" in
    release)
        APP="build/BlaskSync.app"
        ICON="Resources/AppIcon.icns"
        ENTITLEMENTS=""
        ;;
    appstore)
        APP="build/AppStore/BlaskSync.app"
        ICON="Resources/AppIcon.icns"
        ENTITLEMENTS="Resources/Entitlements/AppStore.entitlements"
        ;;
    *)
        APP="build/BlaskSync Dev.app"
        ICON="Resources/AppIcon-Dev.icns"
        ENTITLEMENTS=""
        ;;
esac
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/BlaskSync" "$APP/Contents/MacOS/BlaskSync"
if [[ "$VARIANT" != appstore ]]; then
    # SwiftPM links Sparkle from next to the executable; in the bundle it lives in Contents/Frameworks.
    mkdir -p "$APP/Contents/Frameworks"
    ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/BlaskSync"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Author.svg "$APP/Contents/Resources/Author.svg"
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
# Translations: each String Catalog becomes <language>.lproj/*.strings(dict) next to the icon.
for CATALOG in Resources/*.xcstrings; do
    xcrun xcstringstool compile "$CATALOG" --output-directory "$APP/Contents/Resources"
done
PLIST="$APP/Contents/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST")"
case "$VARIANT" in
    release) ;;
    appstore)
        BUNDLE_ID="${APP_STORE_BUNDLE_ID:-asia.miron.BlaskSync}"
        /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Delete :SUFeedURL" \
            -c "Delete :SUPublicEDKey" -c "Delete :SUEnableAutomaticChecks" "$PLIST"
        ;;
    *)
        BUNDLE_ID="$BUNDLE_ID.dev"
        /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Set :CFBundleName Blask Sync Dev" \
            -c "Delete :SUFeedURL" -c "Delete :SUEnableAutomaticChecks" "$PLIST"
        ;;
esac
[[ -n "${VERSION:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
[[ -n "${BUILD_NUMBER:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
SIGN=(codesign --force --sign "${IDENTITY:--}")
# App Store builds need the hardened runtime and a secure timestamp.
if [[ "$IDENTITY" == "Apple Distribution"* || "$IDENTITY" == "3rd Party Mac Developer Application"* ]]; then
    SIGN+=(--options runtime --timestamp)
fi

if [[ -n "${PROVISIONING_PROFILE:-}" ]]; then
    cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
    # A provisioned app must claim the team and application identifiers its profile grants.
    PROFILE_PLIST="$(mktemp)"
    security cms -D -i "$PROVISIONING_PROFILE" > "$PROFILE_PLIST"
    TEAM_ID="$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier:0" "$PROFILE_PLIST")"
    MERGED="$(mktemp)"
    if [[ -n "$ENTITLEMENTS" ]]; then cp "$ENTITLEMENTS" "$MERGED"; else plutil -create xml1 "$MERGED"; fi
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" \
        -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$MERGED"
    ENTITLEMENTS="$MERGED"
    rm "$PROFILE_PLIST"
fi

# Downloaded files (a provisioning profile, say) carry com.apple.quarantine, which the App Store rejects.
xattr -cr "$APP"

if [[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]]; then
    # Sparkle's nested helpers first, then the app, so every piece carries the same signature.
    "${SIGN[@]}" --deep "$APP/Contents/Frameworks/Sparkle.framework"
fi
"${SIGN[@]}" ${ENTITLEMENTS:+--entitlements "$ENTITLEMENTS"} "$APP"
echo "Signed with: ${IDENTITY:-ad hoc}${ENTITLEMENTS:+ (entitlements: $ENTITLEMENTS)}"

echo "Built $APP"
