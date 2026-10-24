#!/usr/bin/env bash
# Writes the Sparkle update feed for one release to stdout. The app reads it from the latest GitHub
# release (SUFeedURL), so the feed only needs that release's item.
# Usage: scripts/make-appcast.sh <zip> <version> <build-number> <download-url> <tag>
# Signs with the private key in SPARKLE_KEY_FILE if set, else the "blask-sync" key in the login Keychain.
# Release notes come from scripts/release-notes.sh: the tag's message, or the commits since the previous tag.
set -euo pipefail
cd "$(dirname "$0")/.."

ZIP="$1" VERSION="$2" BUILD="$3" URL="$4" TAG="$5"
SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"

if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
    SIGNATURE="$("$SIGN_UPDATE" --ed-key-file "$SPARKLE_KEY_FILE" "$ZIP")"
else
    SIGNATURE="$("$SIGN_UPDATE" --account blask-sync "$ZIP")"
fi

NOTES="$(scripts/release-notes.sh "$TAG" --html)"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"

cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Blask Sync</title>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES]]></description>
      <enclosure url="$URL" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
EOF
