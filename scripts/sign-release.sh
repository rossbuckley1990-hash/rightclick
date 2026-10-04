#!/bin/sh
# Sign, notarise, and Gatekeeper-check the release binary.
# Exits immediately when no Developer ID Application identity is installed.
# Does not ad-hoc sign and does not weaken Gatekeeper.
set -eu
cd "$(dirname "$0")/.."

BINARY="${1:-.build/release/rightclick}"
IDENTITY=$(security find-identity -p codesigning -v | awk -F'"' '/Developer ID Application/ { print $2; exit }')
if [ -z "${IDENTITY}" ]; then
  echo "No Developer ID Application identity is installed." >&2
  echo "Install one, then re-run scripts/sign-release.sh. See docs/SIGNING.md." >&2
  exit 1
fi

echo "Signing with: ${IDENTITY}"
codesign --force --options runtime --timestamp --sign "${IDENTITY}" "${BINARY}"
codesign --verify --strict --verbose=4 "${BINARY}"

ZIP="dist/rightclick-0.1.0-arm64.zip"
mkdir -p dist
ditto -c -k --keepParent "${BINARY}" "${ZIP}"

if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
  xcrun notarytool submit "${ZIP}" --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" --wait
elif [ -n "${APPLE_ID:-}" ] && [ -n "${TEAM_ID:-}" ] && [ -n "${APP_PASSWORD:-}" ]; then
  xcrun notarytool submit "${ZIP}" --apple-id "${APPLE_ID}" --team-id "${TEAM_ID}" --password "${APP_PASSWORD}" --wait
else
  echo "Signature verified. Notarisation was not submitted." >&2
  echo "Set NOTARY_KEYCHAIN_PROFILE, or APPLE_ID, TEAM_ID, and APP_PASSWORD, then re-run." >&2
  exit 2
fi

# Stapler accepts app bundles, disk images, and installer packages.
# A naked executable may be rejected. That rejection is recorded; Gatekeeper is not bypassed.
if ! xcrun stapler staple "${BINARY}"; then
  echo "stapler did not attach a ticket to the naked executable." >&2
  echo "The notarisation ticket, if accepted, remains online. Do not treat this binary as stapled." >&2
  exit 3
fi

spctl --assess --type execute -v "${BINARY}"
echo "Gatekeeper assessment passed."
