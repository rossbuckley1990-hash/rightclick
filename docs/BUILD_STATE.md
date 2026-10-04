# Build state

macOS 26.4.1 (25E253), Xcode 26.6, Swift 6.3.3.

## RIGHTCLICK-000 — PARTIAL

Sharing and Services are discovered from macOS and have been invoked. Finder Action extensions are discovered and are not directly invokable.

| Surface | Discovery | Execution | Support |
| --- | --- | --- | --- |
| Sharing | PASS | PASS | `public_deprecated` discovery, public `perform(withItems:)` |
| Services | PASS | PASS | `public_supported` |
| Quick Actions | PASS | FAIL | public Info.plist discovery, execution unavailable |

Evidence: `evidence/rightclick-000/share-exec.json`, `evidence/rightclick-000/service-exec.json`, `evidence/rightclick-000/private-runtime.json`.

## RIGHTCLICK-001 — PASS

`Capability` in `Sources/RightClickCore/Capability.swift`.

## RIGHTCLICK-002 — PASS

`rightclick-mcp` implements doctor, inspect, capabilities, describe, run, providers, and mcp.

## RIGHTCLICK-003 — PASS

Stdio MCP tools call the same engine. A local Streamable HTTP server on port 8765 enforced a bearer token and executed Convert Text to Full Width.

## RIGHTCLICK-004 — PASS

Installing `RightClick Marker.app` into `~/Library/Services` made `RightClick Marker` appear on the next capabilities call with no RIGHTCLICK source change. `NSPerformService` returned `RIGHTCLICK_MARKER:acquire-baseline-token`. The test bundle was removed afterward.

## RIGHTCLICK-005 — PASS

`evidence/rightclick-005/matrix.md`. JPEG, PDF, QuickTime, and plain text produce different capability sets from the same binary.

## RIGHTCLICK-006 — BLOCKED

`.cursor/mcp.json` points Cursor at the local stdio server. This session’s agent did not receive those tools, so a Cursor agent did not call `context_actions`. A protocol client did: it listed the four tools, inspected `fixtures/sample.jpg`, and executed the full-width text service.

## RIGHTCLICK-007 — BLOCKED

Streamable HTTP with bearer authentication is running for this session:

- Local: `http://127.0.0.1:8765/mcp`
- Tunnel: `https://<ephemeral-tunnel>.trycloudflare.com/mcp`

A protocol client, not Grok Bot, called `context_actions` on `fixtures/manual/fixture.jpg` through that tunnel and then `context_run` for Convert Text to Full Width. The pasteboard result was `ＲｉｇｈｔＣｌｉｃｋ`. Unauthenticated calls received HTTP 401.

`grok` is not on `PATH`, and this session has no Grok Bot client. Remote PASS is not claimed. The quick tunnel is a development process and stops when that process stops.

## Not used in the product

Private `NSExtension` methods, UI automation, SIP changes, Finder injection, and hardcoded action lists.
