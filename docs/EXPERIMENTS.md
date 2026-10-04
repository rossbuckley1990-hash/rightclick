# Experiments

Commands were run on macOS 26.4.1 (25E253) from `/Users/you/spawn/rightclick-mcp`. Raw JSON is in `evidence/`.

## RIGHTCLICK-000A — Sharing discovery

Question: does `NSSharingService.sharingServices(forItems:)` return different services for a JPEG, a PDF, and a URL?

Setup: `Sources/RightClickProbe`, fixtures written by the probe.

Command: `.build/debug/rightclick-probe --skip-service-execution --skip-private-runtime`

Raw result, titles from the deprecated API in `evidence/rightclick-000/share-exec.json`:

- JPEG: AirDrop, Mail, Messages, Notes, Add to Photos, Freeform, Simulator, Journal, Reminders
- PDF: AirDrop, Mail, Messages, Notes, Freeform, Simulator
- URL: Add to Reading List, AirDrop, Mail, Messages, Notes, Open in News, Freeform, Simulator, Journal, Reminders

`NSSharingServicePicker.standardShareMenuItem` was a single “Share…” item with no children. The picker delegate ran only after `show(relativeTo:of:preferredEdge:)` and included services with `canPerform == false`.

Interpretation: the context-filtered catalog comes from the deprecated API. PASS.

Support level: `PUBLIC_DEPRECATED`.

## RIGHTCLICK-000B — Sharing execution

Question: can a service chosen from that URL list be invoked?

The probe selected Add to Reading List only because it was in the discovered URL list, then called `perform(withItems:)`.

Delegate events: `willShareItems count=1`, `didShareItems count=1`.

Input: `https://example.com/rightclick-probe`.

Interpretation: macOS invoked the discovered service. PASS.

`perform(withItems:)` is public and not deprecated.

## RIGHTCLICK-000C — Services

Question: can installed services be found from documented metadata and invoked with `NSPerformService`?

Discovery source: `NSServices` in Info.plist files under `/System/Library/Services`, `/Applications`, `/System/Applications`, `~/Library/Services`, and related roots. 53 registrations in the probe, including:

```text
Convert Text to Full Width
provider: com.apple.ChineseTextConverterService
message: convertTextToFullWidth
send: public.rtf, public.utf8-plain-text
return: public.rtf, public.utf8-plain-text
```

Command result from `evidence/rightclick-000/service-exec.json`:

```text
NSPerformService("Convert Text to Full Width") == true
input: RightClick
output: ＲｉｇｈｔＣｌｉｃｋ
pasteboard changeCount: 1 -> 2
```

Interpretation: discovery and execution both use public API. PASS.

Support level: `PUBLIC_SUPPORTED`. There is no enumeration function; the scan reads a documented key.

## RIGHTCLICK-000D — Quick Actions

Question: which installed Action extensions plausibly apply to JPEG, PDF, and QuickTime, and can they be invoked?

`com.apple.ui-services` bundles found:

- Markup, `com.apple.MarkupUI.Markup`, predicate mentions `com.adobe.pdf` and `public.image`. Applicability: JPEG applies, PDF applies, QuickTime does not.
- ShareSheetUI, `TRUEPREDICATE`. Not treated as a content action.

`pluginkit -m -p com.apple.ui-services` listed the same two bundles.

Private runtime probe: `NSExtension` is present with `beginMatchingExtensionsWithAttributes:completion:`. Attributes key `NSExtensionPointName` = `com.apple.ui-services` returned Markup and ShareSheetUI. `NSExtensionPointIdentifier` returned zero. The class is not in the public SDK headers.

No public invocation was attempted, and the private request API was not called.

Discovery: PASS. Execution: FAIL. Support: public metadata for discovery, execution `UNAVAILABLE`.

## RIGHTCLICK-000 overall

PARTIAL. Sharing and Services work. Quick Action execution does not.

## RIGHTCLICK-004 — Dynamic acquisition

Question: if a new service bundle appears on disk, does the unchanged `rightclick-mcp` binary list it?

Before: `evidence/rightclick-004/before.json`, 36 actions, no RightClick Marker.

Installed, without rebuilding RIGHTCLICK:

```text
~/Library/Services/RightClick Marker.app
NSServices menu title: RightClick Marker
NSMessage: mark
bundle id: dev.rightclick.marker
```

After: `service:dev.rightclick.marker:mark` was the only new id.

Run:

```text
rightclick-mcp run --item acquire-baseline-token --action service:dev.rightclick.marker:mark
EXECUTED
output: RIGHTCLICK_MARKER:acquire-baseline-token
```

The provider log contained the same string. The app bundle was then deleted. A later capabilities call did not list it.

PASS.

## RIGHTCLICK-005 — Type differentiation

Command: `rightclick-mcp capabilities --json` on `fixtures/fixture.jpg`, `.pdf`, `.mov`, and `.txt`.

Types: `public.jpeg`, `com.adobe.pdf`, `com.apple.quicktime-movie`, `public.plain-text`.

Observed differences, not a hardcoded expectation list:

- Add to Photos: JPEG and MOV
- Markup: JPEG and PDF
- Set Desktop Picture: JPEG
- Encode Selected Video Files: MOV
- Convert Text to Full Width: TXT
- AirDrop: all four

Full matrix: `evidence/rightclick-005/matrix.md`. PASS.

## MCP checks

Stdio client: `initialize`, `tools/list` returned `context_inspect`, `context_actions`, `context_explain`, `context_run`. `context_run` of the full-width service returned `ＲｉｇｈｔＣｌｉｃｋ`. AirDrop without `confirmed` returned `CONFIRMATION_REQUIRED`.

Local HTTP on port 8765: missing bearer token returned 401. A valid token initialized a session and ran the same service.

Tunnel `https://<ephemeral-tunnel>.trycloudflare.com/mcp`: unauthenticated POST returned 401 from this server (`WWW-Authenticate: Bearer`). Authenticated `context_actions` for `fixtures/manual/fixture.jpg` returned Markup, Set Desktop Picture, Add to Photos, and AirDrop. Authenticated `context_run` of the full-width service returned `ＲｉｇｈｔＣｌｉｃｋ`.

Grok Bot was not called. RIGHTCLICK-007 stays BLOCKED on that point.

## Tests

`swift test --filter 'PolicyTests|EngineTests'`: 13 tests, 0 failures. The engine tests call live AppKit and `NSPerformService`.
