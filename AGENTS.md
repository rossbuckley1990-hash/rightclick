# RIGHTCLICK MCP

RIGHTCLICK MCP exposes environment-derived contextual capabilities through one portable runtime on macOS, Linux and Windows. Native OS integrations are optional host adapters.

Its core primitive is asking supported capability substrates what actions apply to a specific object. Keep the engine, policy, contracts and agent-facing interface independent of native host adapters.

Do not replace contextual discovery with hard-coded actions.

Do not use UI automation to pretend unsupported capabilities are directly invokable.

Preserve evidence and label unsupported or private mechanisms honestly.

## Capability rules

- Discover sharing services with `NSSharingService.sharingServices(forItems:)`. That API is deprecated, and on this Mac it is still the call that returns a context-filtered catalog. Say so.
- Invoke sharing services with `perform(withItems:)` only after discovery, and only when the safety policy allows it.
- Discover Services from the documented `NSServices` Info.plist key. Invoke them with `NSPerformService`.
- Discover Finder Action extensions from `NSExtension` metadata in installed appex bundles. Do not mark them invokable. `NSExtension` is not in the public SDK.
- Do not call private `NSExtension` methods from the product. The feasibility probe may record them as experimental.
- External, destructive, and unknown capabilities return `CONFIRMATION_REQUIRED` until the caller passes confirmation.
- Never disable SIP, inject code into Finder, patch system processes, modify protected databases, or bypass code signing.

## Bottle alignment

The Homebrew bottle is the installed product agents must keep aligned with `main`.

Before finishing substrate work, run:

    python3 scripts/detect-bottle-alignment.py --compare

If it exits `1`, follow `docs/BOTTLE-ALIGNMENT.md` and `docs/RELEASE.md` to cut the next immutable release. Never force-move an existing release tag.


## Portability

- Require integrated builds and real-provider transport acceptance on macOS, Linux and Windows before claiming a portable release.
- OS-specific discovery belongs behind host availability guards; never fabricate native actions on another host.
- Unsupported credential storage and observation adapters abstain. Preserve authority checks; never substitute plaintext storage or unchecked host configuration reads.
- Homebrew is one distribution adapter, not a runtime dependency. Preserve the stable formula pin until a new immutable release is accepted.
