# Optional future Apple distribution

**DEFERRED UNTIL USER DEMAND JUSTIFIES PAID APPLE DISTRIBUTION**

Developer ID, notarisation, standalone signed downloads, app bundles, DMG, PKG, App Store and consumer installers are outside the v0.1 critical path. A paid Apple Developer account is not required for normal Homebrew source installation or standard Homebrew bottles. Do not remove quarantine, disable Gatekeeper or weaken macOS security.

The existing `build-release.sh`, `sign-release.sh`, `validate-release.sh`, `make-release-archive.sh`, `deterministic-archive.py` and `package-local.sh` scripts remain available for this future path. `fill-homebrew-formula.sh` now writes only under `packaging/deferred-apple/`; it cannot overwrite the primary source formula.

The preserved pipeline requires a real Developer ID identity and stored notarisation credentials, enables hardened runtime and a timestamp, verifies the signature, requires notarisation Accepted, staples the app and validates Gatekeeper. It never falls back to ad-hoc signing for that distribution path. Its preflight failure is verified; successful account-dependent signing was not tested.

Historical artifact hashes and signing observations remain in the [superseded report](V0.1_COMPLETION_REPORT_APPLE_PATH.md) and raw evidence. They are not current v0.1 launch gates.
