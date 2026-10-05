# Contributing

RIGHTCLICK v0.1's capability engine is frozen. Accept release-critical fixes; defer platforms, new capability families, provider-specific integrations, Accessibility/AppleScript automation, devices, and network discovery.

RIGHTCLICK asks the environment which actions apply to an object. Preserve generic discovery and shared applicability/payload rules. Do not replace them with a hard-coded action catalogue. Services use documented `NSServices` metadata and `NSPerformService`. Sharing uses the deprecated context-filtered discovery API honestly. Action extensions remain unsupported for invocation; no private `NSExtension` calls belong in production.

Before proposing a change, reproduce the problem, add a meaningful failing regression where appropriate, make the smallest generic repair, and run `swift test`. Do not weaken assertions or skip a failing regression to obtain green. Run `scripts/acceptance-mcp.py <absolute-binary> <evidence-directory>` for transport changes, and the relevant independent semantic control for execution changes. Never infer outcome verification from an accepted provider invocation.

Build with `scripts/build-release.sh`; archive a development rehearsal with `scripts/package-local.sh`. Public archives require the validated Apple distribution pipeline in [docs/RELEASE.md](docs/RELEASE.md). Preserve evidence, keep credentials out of the tree, and describe exactly what a check proves.

Contributions use Apache-2.0. The distributable retains notices for pinned dependencies under `packaging/ThirdPartyLicenses/`.
