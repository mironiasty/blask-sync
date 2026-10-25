#!/usr/bin/env bash
# Renders the app icon at every macOS size into Resources/AppIcon.icns, plus docs/icon.png for the README,
# the DEV-badged icon for local builds into Resources/AppIcon-Dev.icns, and the website's link preview
# (docs/social.png) and home screen icon (docs/apple-touch-icon.png).
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Usage: make_icns <variant> <output.icns>; leaves the iconset in $WORK/<variant>.iconset.
make_icns() {
    local iconset="$WORK/$1.iconset"
    mkdir -p "$iconset"
    swift scripts/make-icon.swift "$WORK/$1-1024.png" "$1"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$WORK/$1-1024.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" "$WORK/$1-1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$2"
}

make_icns halo-sparkle Resources/AppIcon.icns
make_icns dev Resources/AppIcon-Dev.icns
mkdir -p docs
cp "$WORK/halo-sparkle.iconset/icon_256x256@2x.png" docs/icon.png
swift scripts/make-web-images.swift "$WORK/halo-sparkle-1024.png" docs
echo "Wrote Resources/AppIcon.icns, Resources/AppIcon-Dev.icns, docs/icon.png, docs/social.png and docs/apple-touch-icon.png"
