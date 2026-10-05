# Apple distribution gate

This Mac reports **0 valid code-signing identities**. The development executable is linker ad-hoc signed; Gatekeeper rejects it. No notarisation credential was supplied. Public Developer ID, notarisation and Gatekeeper acceptance are BLOCKED. No insecure distribution workaround was used.

Ross must install a Developer ID Application certificate with its private key and store a valid notarisation profile in the keychain. Use `xcrun notarytool store-credentials RIGHTCLICK_NOTARY` interactively. Never commit passwords or certificates/private keys. See [the exact release sequence](RELEASE.md).

The prepared pipeline signs `dist/RIGHTCLICK.app`, enabling hardened runtime and a secure timestamp. It verifies the signature, submits an app-bundle ZIP, checks explicit `Accepted` status, staples and validates the app, and requires Gatekeeper acceptance before making the public archive. It refuses to archive an unvalidated public artifact. A naked executable is not passed to stapler.

The pipeline is prepared and preflight failures are verified; successful Apple signing/notarisation cannot be tested until the account credentials exist. After notarisation, extraction/validation of the final archive is also required. Apple's [notarisation workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) explains supported containers and packaging after stapling.

Unsigned builds and archives can be checked for deterministic bytes on the same compiler/SDK. Developer ID timestamps and notarisation change final bytes; record the actual final signed hashes. Do not reuse the development SHA256 as the public release hash.
