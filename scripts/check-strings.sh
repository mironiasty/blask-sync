#!/usr/bin/env bash
# Fails if the String Catalogs are out of date with the code or a string is missing a translation.
# CI runs it on every pull request; scripts/update-strings.sh fixes the first, translating fixes the second.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/update-strings.sh > /dev/null
if ! git diff --quiet -- Resources/Localizable.xcstrings; then
    git diff --stat -- Resources/Localizable.xcstrings
    echo "Resources/Localizable.xcstrings is out of date: run scripts/update-strings.sh and commit the result." >&2
    exit 1
fi

python3 - Resources/Localizable.xcstrings Resources/InfoPlist.xcstrings <<'EOF'
import json, sys

LANGUAGES = ["pl", "de", "es", "fr"]
missing = 0
for path in sys.argv[1:]:
    with open(path) as file:
        strings = json.load(file)["strings"]
    for key, entry in strings.items():
        if entry.get("shouldTranslate") is False or entry.get("extractionState") == "stale":
            continue
        languages = [language for language in LANGUAGES if language not in entry.get("localizations", {})]
        if languages:
            missing += 1
            print(f"{path}: {key!r} has no {', '.join(languages)} translation", file=sys.stderr)
sys.exit(1 if missing else 0)
EOF
echo "String Catalogs are up to date and translated"
