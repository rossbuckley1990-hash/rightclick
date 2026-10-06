# Contributing

RIGHTCLICK v0.2.1's generic capability architecture is release-frozen. Accept narrowly scoped release-critical fixes; defer provider-specific integrations, speculative automation, and new capability families that are not backed by preregistered evidence and regression coverage.

RIGHTCLICK asks the environment which actions apply to an object. Preserve generic discovery and shared applicability/payload rules. Do not replace them with a hard-coded action catalogue. Services use documented `NSServices` metadata and `NSPerformService`. Sharing uses the deprecated context-filtered discovery API honestly. Action extensions remain unsupported for invocation; no private `NSExtension` calls belong in production.

Before proposing a change, reproduce the problem, add a meaningful failing regression where appropriate, make the smallest generic repair, and run `swift test`. Do not weaken assertions or skip a failing regression to obtain green. Run `scripts/acceptance-mcp.py <absolute-binary> <evidence-directory>` for transport changes, and the relevant independent semantic control for execution changes. Never infer outcome verification from an accepted provider invocation.

Free Apple Command Line Tools with Swift 6.2 or later build the CLI. Running the existing XCTest suite requires full Xcode (also free); Command Line Tools do not include XCTest. Build the CLI with `scripts/build-cli.sh`; prepare the deterministic source asset and Homebrew formula with `python3 scripts/package-source.py`. [docs/RELEASE.md](docs/RELEASE.md) describes the package-manager release. The optional app-bundle signing pipeline is deferred; see [docs/SIGNING.md](docs/SIGNING.md). Preserve evidence, keep credentials out of the tree, and describe exactly what a check proves.

Contributions use Apache-2.0. The distributable retains notices for pinned dependencies under `packaging/ThirdPartyLicenses/`.
