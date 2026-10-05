#!/bin/sh
# Developer ID only. Notary credentials stay in the keychain.
set -eu
cd "$(dirname "$0")/.."
APP="${1:-dist/RIGHTCLICK.app}"
IDENTITY=$(security find-identity -p codesigning -v | awk -F'"' '/Developer ID Application/ { print $2; exit }')
if [ -z "$IDENTITY" ]; then
  echo "BLOCKED: no Developer ID Application identity. See docs/SIGNING.md." >&2
  exit 1
fi
if [ -z "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
  echo "BLOCKED: set NOTARY_KEYCHAIN_PROFILE to your stored notary credential." >&2
  exit 2
fi
test -f "$APP/Contents/MacOS/rightclick"
mkdir -p dist/notary
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=4 "$APP"
ditto -c -k --keepParent "$APP" dist/notary/rightclick-submission.zip
xcrun notarytool submit dist/notary/rightclick-submission.zip \
  --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait --output-format json > dist/notary/submission.json
python3 -c 'import json; d=json.load(open("dist/notary/submission.json")); print("Notary status:", d.get("status")); assert d.get("status") == "Accepted", "Notarisation not accepted; retain submission.json and inspect the notary log"'
xcrun stapler staple "$APP"
scripts/validate-release.sh "$APP"
echo "Developer ID, notarisation, stapling and Gatekeeper passed. Archive this exact bundle next."
