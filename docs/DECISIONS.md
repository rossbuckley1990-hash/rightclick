# Decisions

## The product asks macOS, then filters

RIGHTCLICK does not ship a catalog of Mail, AirDrop, or Markup. Each `capabilities` call classifies the object and asks the applicable system surfaces.

## Sharing discovery stays on the deprecated API

`NSSharingService.sharingServices(forItems:)` is marked deprecated in macOS 13. The replacement, `NSSharingServicePicker.standardShareMenuItem`, returns one “Share…” item and does not enumerate services.

On macOS 26.4.1 the deprecated call still returns a context-filtered list. `perform(withItems:)` is not deprecated. The picker delegate’s proposed list is only produced by showing the picker, and it includes services whose `canPerform(withItems:)` is false. The product therefore uses the deprecated discovery call, labels the support level `public_deprecated`, and invokes with `perform(withItems:)`.

Public `NSSharingService.Name` constants are used only to attach a stable identifier to a service that was already returned.

## Services come from documented Info.plist metadata

There is no public API that enumerates the Services menu. Registrations live in the documented `NSServices` key of application, `.service`, and `.workflow` bundles. Reading those plists is public metadata, not a private database. Invocation is `NSPerformService` plus `NSUpdateDynamicServices`.

## Action extensions are discovered and not invoked

Installed `.appex` bundles with `NSExtensionPointIdentifier` `com.apple.ui-services` are scanned for `NSExtensionActivationRule` and Finder preview attributes. `ShareSheetUI` uses `TRUEPREDICATE` and is treated as share-sheet infrastructure, not a content action.

`NSExtension` is absent from the public SDK. A feasibility probe found the class at runtime and matched Markup and ShareSheetUI through `beginMatchingExtensionsWithAttributes:`. That call is undocumented. The product does not use it, and it does not call `beginExtensionRequestWithInputItems:`. Markup is reported as discovered and `unsupported`.

## One engine, two transports

The CLI and both MCP transports call `CapabilityEngine`. The MCP surface is six contextual tools: `context_inspect`, `context_actions`, `context_explain`, `context_run`, `context_run_status`, and `context_providers`. There is no static tool per Mac action.

The MCP implementation uses the official Swift SDK 0.12.1 (`swift-sdk`), including `StdioTransport` and `StatelessHTTPServerTransport` (Streamable HTTP). HTTP requests require a bearer token. Origin checks are disabled for the development tunnel because the public Host header is not localhost; the bearer token is the access control.

## Safety

`read` actions and reversible local transforms that return pasteboard data run when the tool is called. `external_share`, `destructive`, and `unknown` return `CONFIRMATION_REQUIRED` until `confirmed` / `--yes` is set. Desktop-picture changes require confirmation even though they are local.

## Language split

AppKit code is compiled in Swift 5 language mode so it can touch AppKit without a MainActor rewrite. The same types are called from the MCP target. Handlers hop to the main thread because sharing and Services need the main run loop.

## Freeze and outcome evidence

The v0.1 engine retains the BBEdit-proven generic behaviour. The bounded Yojam AppKit control did not verify an outcome, so an inherited speculative lifecycle rewrite was preserved as evidence and removed from production. The legacy Services `succeeded` state denotes accepted invocation; independent results remain a separate evidentiary stage. See YOJAM-LIMITATION.md. Release-critical transport fixes restrict the listener to loopback and reject malformed request framing.
