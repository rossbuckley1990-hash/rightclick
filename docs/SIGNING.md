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

## Public release

1. Enroll in the Apple Developer Program.
2. Create a Developer ID Application certificate.
3. Sign the release binary:

```bash
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: <Team Name> (<TEAMID>)" \
  rightclick
```

4. Zip the signed binary.
5. Submit the zip for notarization:

```bash
xcrun notarytool submit rightclick.zip --apple-id <apple-id> --team-id <TEAMID> --wait
xcrun stapler staple rightclick
```

6. Verify:

```bash
spctl --assess --type execute -v rightclick
codesign --verify --verbose=4 rightclick
```

Without that certificate and a successful notarization ticket, do not distribute the binary as a public download.
