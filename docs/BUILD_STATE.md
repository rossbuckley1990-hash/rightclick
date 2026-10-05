# Build and acceptance state

See the current [v0.1 gate](V0.1_COMPLETION_REPORT.md). Earlier numbered experiments and the [Apple-path report](V0.1_COMPLETION_REPORT_APPLE_PATH.md) preserve historical evidence and are not current distribution requirements.

The unchanged XCTest suite passes 33 tests with zero failures. Full Xcode is needed for XCTest, but it is free. Free Command Line Tools do not include XCTest; this does not prevent CLI source installation. The Homebrew formula explicitly selects those free tools for its release build when installed.

The protocol acceptance script exercises the concrete installed binary over stdio and authenticated loopback HTTP: initialize, all six tools, exact object inspection, discovery, safety confirmation, exact Apple full-width result/status, authentication failure, loopback binding and malformed framing rejection.

The published source asset is deterministic, contains the pinned build inputs/tests/fixtures/notices, and excludes build caches, personal configuration and raw execution evidence. The production formula pins its actual SHA256 and immutable GitHub Release URL. Standard Homebrew CI built and published the Apple Silicon Tahoe bottle. Both an actual public source build with free Command Line Tools and the exact default public bottle install passed; no paid Apple account or security bypass was needed.

The historical BBEdit installation proof remains 36→41 capabilities with five new BBEdit capabilities and no provider-specific production changes. Yojam's one control remains a documented semantic limitation. The capability engine is frozen.

Public repositories and releases are under `rossbuckley1990-hash`, as authorised by Ross. Final CLI, setup, Cursor, stdio, authenticated loopback HTTP and exact BBEdit output all passed using the Homebrew-installed bottle. Raw final evidence is under `evidence/v0.1-homebrew/final-installed/`. Acceptance was on macOS 26.4.1; older deployment targets remain unvalidated.
