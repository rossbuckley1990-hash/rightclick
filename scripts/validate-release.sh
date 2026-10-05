#!/bin/sh
set -eu
APP="${1:-dist/RIGHTCLICK.app}"
codesign --verify --strict --verbose=4 "$APP"
DETAILS=$(codesign -dv --verbose=4 "$APP" 2>&1)
printf '%s\n' "$DETAILS" | rg 'Authority=Developer ID Application:' > /dev/null
printf '%s\n' "$DETAILS" | rg 'flags=.*runtime' > /dev/null
printf '%s\n' "$DETAILS" | rg '^Timestamp=' > /dev/null
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"
echo "Release validation passed."
