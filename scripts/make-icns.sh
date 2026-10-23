#!/usr/bin/env bash
# Renders the app icon at every macOS size into Resources/AppIcon.icns, plus docs/icon.png for the README.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

swift scripts/make-icon.swift "$WORK/icon-1024.png" halo-sparkle
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
mkdir -p docs
cp "$ICONSET/icon_256x256@2x.png" docs/icon.png
echo "Wrote Resources/AppIcon.icns and docs/icon.png"
