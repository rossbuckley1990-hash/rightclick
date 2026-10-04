# Product state

## Discovery engine

Services:
Scans `NSServices` in installed `.app`, `.service`, and `.workflow` bundles. `rightclick refresh` calls `NSUpdateDynamicServices`. The next query reads the bundles again. No in-process cache of the catalog.

Sharing:
`NSSharingService.sharingServices(forItems:)`. Deprecated since macOS 13. It is still the call that returns a context-filtered list on the development Mac. Support level on each sharing capability is `public_deprecated`.

Action extensions:
Reads `NSExtension` metadata for `com.apple.ui-services` from installed appex bundles. `TRUEPREDICATE` extensions are not listed as content actions. Invocation is `unsupported`.

## Execution engine

Services:
`NSPerformService` with the discovered menu title. A true return is stored as `succeeded` and means the service was accepted. RIGHTCLICK does not invent a further outcome.

Sharing:
The service object and delegate stay retained by an in-memory registry. `perform(withItems:)` runs on the main thread. `willShareItems` does not finish the execution. `didShareItems` is `succeeded`. `didFailToShareItems` is `failed`. No callback within 30 seconds is `unknown`.

Extensions:
Not executed.

## MCP

stdio:
`rightclick mcp`. Tools: `context_inspect`, `context_actions`, `context_run`, `context_run_status`, `context_explain`, `context_providers`.

remote:
`rightclick serve` listens on `127.0.0.1:8765/mcp` unless `--port` is set. Bearer token is created in `~/Library/Application Support/RIGHTCLICK/token` and printed once at startup. `--tunnel` starts `cloudflared` when that binary is installed. `rightclick auth rotate` replaces the token; the running server keeps the old token until restart.

## Setup

`rightclick setup` runs a doctor-style check, writes or updates only the `rightclick` key in `~/.cursor/mcp.json`, and inspects a plain-text probe. It does not execute a capability.

## CLI

Binary name: `rightclick`. Legacy command names `capabilities` and `mcp` still work.

## Packaging

`scripts/build-release.sh` builds the release binary. `packaging/homebrew/rightclick.rb` is an unpublished formula template. No Developer ID signature. Built for Apple Silicon on the development Mac. Intel is not produced here.

## Tests

`swift test` covers policy, sharing lifecycle, temp-bundle service install/removal, type filtering, duplicate ids, stale service ids, and live AppKit discovery. MCP stdio and HTTP are not covered by XCTest. They were exercised by manual clients during development.

## Known limitations

- Sharing discovery depends on a deprecated API.
- Action extensions are not invokable.
- `NSPerformService` true is not proof that a workflow changed the requested file or setting. Set Desktop Picture returned true and left the wallpaper unchanged.
- Service acquisition was proven for `NSServices`, not for every kind of installed app.
- Execution status is in memory inside the serving process. `rightclick status` in another process does not see it.
- Cursor must be restarted before it loads a newly written MCP config. This session did not observe Cursor call the tools.
- The HTTP server is one machine, one user, and the bearer token is a shared secret.
