#!/usr/bin/env bash
# Prints a release's notes: the body of its annotated tag (everything after the first line), or the
# commit subjects since the previous tag when the tag has none. Markdown by default; --html gives the
# HTML that Sparkle shows in the update window, converting the Markdown the notes use: "#" headings,
# "- " bullets, paragraphs, **bold**, `code` and bare links.
# Create the tag with --cleanup=whitespace, or git drops "#" heading lines as comments.
# Usage: scripts/release-notes.sh <tag> [--html]
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="$1"
NOTES="$(git tag -l --format='%(contents:body)' "$TAG" | sed -e '/-----BEGIN PGP SIGNATURE-----/,$d')"
if [[ -z "${NOTES//[[:space:]]/}" ]]; then
    PREVIOUS="$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)"
    NOTES="$(git log --no-merges --format='- %s' ${PREVIOUS:+"$PREVIOUS.."}"$TAG")"
fi

if [[ "${2:-}" != --html ]]; then
    printf '%s\n' "$NOTES"
    exit 0
fi

printf '%s\n' "$NOTES" | sed -E \
    -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
    -e 's/\*\*([^*]+)\*\*/<b>\1<\/b>/g' \
    -e 's/`([^`]+)`/<code>\1<\/code>/g' \
    -e 's#(https?://[^ <)]+[^ <).,])#<a href="\1">\1</a>#g' | awk '
    /^[-*] / { if (!list) { print "<ul>"; list = 1 } sub(/^[-*] /, ""); print "<li>" $0 "</li>"; next }
    { if (list) { print "</ul>"; list = 0 } }
    /^[[:space:]]*$/ { next }
    /^#+ / { sub(/^#+ /, ""); print "<h3>" $0 "</h3>"; next }
    { print "<p>" $0 "</p>" }
    END { if (list) print "</ul>" }
'
