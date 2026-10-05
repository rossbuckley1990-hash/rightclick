# Build and acceptance state

See the current [v0.1 gate](V0.1_COMPLETION_REPORT.md). Earlier numbered experiments and the [Apple-path report](V0.1_COMPLETION_REPORT_APPLE_PATH.md) preserve historical evidence and are not current distribution requirements.

The unchanged XCTest suite passes 33 tests with zero failures. Full Xcode is needed for XCTest, but it is free. Free Command Line Tools do not include XCTest; this does not prevent CLI source installation. The Homebrew formula explicitly selects those free tools for its release build when installed.

The protocol acceptance script exercises the concrete installed binary over stdio and authenticated loopback HTTP: initialize, all six tools, exact object inspection, discovery, safety confirmation, exact Apple full-width result/status, authentication failure, loopback binding and malformed framing rejection.

The primary source asset is deterministic, contains the pinned build inputs/tests/fixtures/notices, and excludes build caches, personal configuration and raw execution evidence. The production formula pins its actual SHA256 and immutable GitHub Release URL. The prepared tap includes standard Homebrew bottle workflows. Source installation is a sufficient v0.1 path; no paid Apple account or security bypass is needed.

The historical BBEdit installation proof remains 36→41 capabilities with five new BBEdit capabilities and no provider-specific production changes. Yojam's one control remains a documented semantic limitation. The capability engine is frozen.

Pre-publication local source-cache acceptance does not prove a public download. That final gate requires the authorised public repositories and release asset, with the publishing namespace confirmed by Ross.
