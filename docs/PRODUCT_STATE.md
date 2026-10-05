# Product state — v0.1.0

The capability engine is frozen at the generic behaviour of `980c05e895ef6108be76b32e17289ea85a9bdb17`. No provider-specific production code was added during reconstruction.

Services scan documented `NSServices` entries in installed bundles on each query. `refresh` requests `NSUpdateDynamicServices`. Applicability and supported payload construction share encoding rules. Generic invocation retains the pasteboard and an AppKit run loop for 10 seconds when no synchronous result is written.

Sharing uses deprecated context-filtered discovery and public invocation. The in-memory registry retains the service/delegate. `willShareItems` does not finish execution; `didShareItems` records success, `didFailToShareItems` records failure, and a 30-second deadline records unknown. Finder Action extensions are metadata-only and cannot be invoked.

The CLI and both MCP transports call the same engine. Six contextual tools expose discovery and policy without a tool per app. Streamable HTTP is stateless at the protocol transport layer but shares an in-memory execution store across requests. It binds to `127.0.0.1`, requires a bearer secret, rejects malformed/oversized request framing, and does not itself provide TLS. `serve --tunnel` is an explicit optional development exposure; no tunnel was created for final acceptance.

`setup` checks discovery and writes only the `rightclick` Cursor entry using the invoked executable's path. Status and interactive callbacks require the serving process to remain alive. A separate `rightclick status` process cannot retrieve a previous process's record.

BBEdit's historical acquisition is 36 → 41 with five new capabilities; final public-bottle exact semantic regression passes. Yojam acquisition passes, semantic execution remains a documented limitation. See the [completion report](V0.1_COMPLETION_REPORT.md) for test scope and distribution gates. v0.1 is published through Homebrew with an Apple Silicon Tahoe bottle and a verified free Command Line Tools source fallback. Actual public clean installation, installed setup, CLI, Cursor and both MCP transports passed. Paid signing is deferred.
