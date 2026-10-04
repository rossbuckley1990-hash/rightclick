# Signing

This describes the release procedure. Ad-hoc signing is not Developer ID signing and it is not notarization.

## What was checked on the development Mac

Checked 2026-10-04 on macOS 26.4.1 (25E253), Apple Silicon:

```text
codesign -dv --verbose=4 .build/release/rightclick
Signature=adhoc
flags=0x20002(adhoc,linker-signed)
TeamIdentifier=not set
Info.plist=not bound

security find-identity -p codesigning -v
0 valid identities found
```

unsigned binary runs locally: YES
ad-hoc signing possible: YES (the linker already applied an ad-hoc signature)
Developer ID available: NO
notarization available: NO

`spctl --assess --type execute -v .build/release/rightclick` returned `rejected`. Gatekeeper will not treat this binary as a public download.

Public distribution is unavailable on this machine until a Developer ID Application certificate exists.

## Local engineering run

An unsigned or ad-hoc signed binary can run on the same Mac that built it. Gatekeeper will block that binary when a different person downloads it.

Ad-hoc sign, if useful for local identification only:

```bash
codesign --force --sign - .build/release/rightclick
```

This signature is not trusted by Gatekeeper on other Macs.

Checked again on 2026-10-05. `security find-identity -p codesigning -v` still reports `0 valid identities found`. `spctl --assess --type execute` still returns `rejected` for the release binary.

## What Ross does once

1. Enrol in the Apple Developer Program at https://developer.apple.com/programs/.
2. On the developer account, create a Developer ID Application certificate. Request it from this Mac with Keychain Access, Certificate Assistant, Request a Certificate From a Certificate Authority, then upload the request and download the certificate.
3. Double-click the downloaded certificate so it lands in the login keychain. Confirm it with:

```bash
security find-identity -p codesigning -v
```

The matching line must contain `Developer ID Application:`.
4. Store a notary credential in the keychain. An app-specific password is created at https://account.apple.com.

```bash
xcrun notarytool store-credentials RIGHTCLICK_NOTARY \
  --apple-id <apple-id> \
  --team-id <TEAMID> \
  --password <app-specific-password>
```

## Deterministic release sequence

`scripts/sign-release.sh` stops if no Developer ID Application identity exists. It does not ad-hoc sign.

```bash
scripts/make-release-archive.sh
NOTARY_KEYCHAIN_PROFILE=RIGHTCLICK_NOTARY scripts/sign-release.sh .build/release/rightclick
```

That script runs:

```text
release build is produced separately by scripts/make-release-archive.sh or scripts/build-release.sh
→ codesign --options runtime --timestamp
→ codesign --verify --strict
→ zip the signed binary
→ xcrun notarytool submit --wait
→ xcrun stapler staple
→ spctl --assess --type execute
```

`stapler` accepts app bundles, disk images, and installer packages. If it refuses a naked executable, the script exits and does not treat the binary as stapled. Gatekeeper is not bypassed.
