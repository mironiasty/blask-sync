#!/usr/bin/env bash
# Builds the Mac App Store app and packages it as a signed installer for App Store Connect.
# Usage: VERSION=1.0.0 BUILD_NUMBER=42 PROVISIONING_PROFILE=path/to/BlaskSync.provisionprofile \
#            scripts/package-appstore.sh [--upload]
# Needs, in the keychain: an "Apple Distribution" certificate (signs the app) and a
# "3rd Party Mac Developer Installer" certificate (signs the .pkg); override them with SIGN_IDENTITY and
# INSTALLER_IDENTITY. The profile is a Mac App Store Connect profile for APP_STORE_BUNDLE_ID
# (default asia.miron.BlaskSync). BUILD_NUMBER must grow with every upload.
# --upload validates and uploads build/AppStore/BlaskSync.pkg with an App Store Connect API key:
# ASC_KEY_ID, ASC_ISSUER_ID, and the key file AuthKey_<ASC_KEY_ID>.p8 in ~/.appstoreconnect/private_keys
# (or ./private_keys, ~/private_keys, ~/.private_keys).
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?Set VERSION, e.g. 1.0.0}"
: "${BUILD_NUMBER:?Set BUILD_NUMBER, higher than the last upload}"
: "${PROVISIONING_PROFILE:?Set PROVISIONING_PROFILE to the Mac App Store profile}"

find_identity() {
    security find-identity -v "$@" | awk -F'"' -v kind="$KIND" 'index($2, kind) == 1 { print $2; exit }'
}
KIND="Apple Distribution"
SIGN_IDENTITY="${SIGN_IDENTITY:-$(find_identity -p codesigning)}"
KIND="3rd Party Mac Developer Installer"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-$(find_identity)}"
[[ -n "$SIGN_IDENTITY" ]] || { echo "No Apple Distribution certificate in the keychain" >&2; exit 1; }
[[ -n "$INSTALLER_IDENTITY" ]] || { echo "No 3rd Party Mac Developer Installer certificate" >&2; exit 1; }

export VARIANT=appstore UNIVERSAL=1 VERSION BUILD_NUMBER PROVISIONING_PROFILE SIGN_IDENTITY
scripts/bundle.sh release

APP="build/AppStore/BlaskSync.app"
PKG="build/AppStore/BlaskSync.pkg"
codesign --verify --strict --deep "$APP"
productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG"
echo "Packaged $PKG"

if [[ "${1:-}" == --upload ]]; then
    : "${ASC_KEY_ID:?Set ASC_KEY_ID (App Store Connect API key ID)}"
    : "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID (App Store Connect API issuer ID)}"
    AUTH=(--apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID")
    xcrun altool --validate-app --type macos --file "$PKG" "${AUTH[@]}"
    xcrun altool --upload-app --type macos --file "$PKG" "${AUTH[@]}"
fi
