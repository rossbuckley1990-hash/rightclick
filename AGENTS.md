# RIGHTCLICK MCP

RIGHTCLICK MCP exists to make macOS contextual capabilities available to AI agents.

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


## Runtime review inventory

Before stating that a substrate connector exists, is missing, or is available, report the exact main SHA, active candidate PR/head SHA and connected runtime attestation. Inspect active candidate source as well as main. Distinguish implementation present, merged into main, shipped/installed, and actually demonstrated live; each is a separate claim.

Use `docs/CANDIDATE-INVENTORY.md` for the acquisition-path map and refresh its snapshots from actual Git refs and `context_runtime`. Enumerate the candidate A2A, Kafka, Kubernetes, WASM and Linux D-Bus compiler paths when reviewing PR49. Keep native Windows acquisition, remaining native runtime/authority controls, streams and complete eleven-substrate acceptance RED until their real evidence passes. New compilers must enter the existing RCIR/Core7 engine, not provider-specific AI tools or a competing runtime.
