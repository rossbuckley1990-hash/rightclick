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
