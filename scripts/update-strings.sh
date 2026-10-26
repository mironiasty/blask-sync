#!/usr/bin/env bash
# Adds new user-facing strings from the code to Resources/Localizable.xcstrings and marks removed ones stale.
# Run it after changing UI text, then translate the new entries (they show as untranslated in Xcode's
# String Catalog editor). scripts/bundle.sh compiles the catalog into the app.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# A separate build directory, so the extra compiler output doesn't invalidate the normal build.
swift build --scratch-path "$WORK/build" \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$WORK/strings"
xcrun xcstringstool sync Resources/Localizable.xcstrings --stringsdata "$WORK"/strings/*.stringsdata
echo "Updated Resources/Localizable.xcstrings"
