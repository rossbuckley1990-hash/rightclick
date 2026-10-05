# RIGHTCLICK 0.1.0

## Install an app. Your AI learns what it can do.

RIGHTCLICK reflects compatible native capabilities from installed macOS software into a contextual capability layer. An AI can inspect an object, discover applicable capabilities, inspect policy and invoke supported actions. Six MCP tools transport these requests to the same engine used by the CLI.

Ordinary BBEdit installation changed the same plain-text query from 36 capabilities (0 third-party) to 41 (5 BBEdit capabilities), with zero provider-specific acquisition changes. Generic invocation created a BBEdit document with the exact requested text. The v0.1 semantic regression independently verified the exact new document.

Services discovery uses documented `NSServices` metadata. Generic payload construction supports declared text, URL and file representations and shares compatibility rules with applicability. Providers that asynchronously consume pasteboard input receive a retained pasteboard/run loop when no synchronous result is written. Sharing discovery uses the deprecated context-filtered API honestly; invocation uses public APIs. Finder Action extension metadata is discovery-only.

stdio and authenticated Streamable HTTP expose initialization, contextual discovery, confirmation and execution status. The HTTP listener is restricted to loopback and rejects malformed/oversized request framing.

## Limits and release status

Not every app exposes a compatible contract. Accepted invocation does not establish semantic completion. Yojam acquisition and generic payload/invocation pass, but its expected browser result remains a documented limitation after one bounded standalone control. Interactive actions may require a person. Status is in memory and is lost on restart.

0.1.0 targets Apple Silicon/macOS 14+. The capability engine is frozen. The development package and local Homebrew rehearsal pass; public distribution remains blocked on Developer ID, notarisation, Gatekeeper acceptance, authorised asset/tap publication and fresh-machine acceptance. No public launch is claimed by these prepared notes.
