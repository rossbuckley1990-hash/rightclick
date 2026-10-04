# RIGHTCLICK 0.1.0

Install an app. Your AI learns what it can do.

RIGHTCLICK discovers contextual capabilities that installed macOS software already exposes, and offers the ones that apply to an object through six MCP tools.

## What works

- macOS Services discovery and generic invocation
- Sharing Service discovery, and execution where the public API reports a terminal result
- Action Extension discovery
- Contextual filtering
- Local stdio MCP and remote Streamable HTTP MCP
- Confirmation for external-share, destructive, financial, and unclassified actions

## Proof

On the development Mac, plain text had 36 capabilities and no third-party capabilities. After an ordinary install of BBEdit 16.0.3, and with no BBEdit-specific RIGHTCLICK code, the same query returned 41 capabilities, including five from BBEdit. New BBEdit Document with Selection transferred an exact fixture string into BBEdit.

Some Services read their pasteboard after `NSPerformService` returns. RIGHTCLICK keeps that pasteboard and an AppKit run loop for 10 seconds when the service does not write a synchronous result.

## Limits

- Action Extensions are not generically executable.
- Not every installed app exposes a capability RIGHTCLICK can see.
- `NSPerformService` returning true means the service was accepted, which is not by itself a verified semantic outcome.
- This artefact is arm64. It is not a notarised download. Gatekeeper rejects the ad-hoc development binary.

## Install

Build from source until the signed Homebrew asset is published:

```bash
git clone <repo>
cd rightclick
swift build -c release --product rightclick
```

The intended later command is `brew install ross-buckley/tap/rightclick`.
