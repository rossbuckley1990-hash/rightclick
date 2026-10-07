# RIGHTCLICK MCP

RIGHTCLICK is an environment-derived capability runtime for AI agents. macOS is a native host adapter, not the definition of the runtime.

Its core primitive is asking the operating system what actions are applicable to a specific object.

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


## Portable host boundary

Preserve the shared Core/MCP implementations. Native features must be explicitly unavailable where their public APIs do not exist. Keep all native tests; run portable-runtime acceptance for transport/host changes. Do not count Linux containers as native Windows proof. Configuration isolation is not a sandbox.
