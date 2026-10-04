# RIGHTCLICK MCP

## If you can right-click it, your AI can do it.

```text
photo.jpg
    ↓
RIGHTCLICK
    ↓
What can this Mac do with it?
    ↓
Markup
Set Desktop Picture
Add to Photos
AirDrop
Mail
...
```

RIGHTCLICK exposes contextual macOS capabilities from supported system capability surfaces. It asks the operating system what applies to a specific object, then lets an agent invoke the actions that have a real API.

It does not claim parity with every Finder context-menu item. On this Mac, sharing services and the Services menu can be discovered and invoked. Finder Action extensions such as Markup can be discovered from extension metadata and cannot be invoked directly.

## What this Mac actually returns

A JPEG, a PDF, a movie, and a text file do not get the same list. Sharing discovery uses `NSSharingService.sharingServices(forItems:)`, which Apple marks deprecated and which still returns the filtered catalog here. Services come from the documented `NSServices` Info.plist key and run through `NSPerformService`. Action extensions come from `NSExtension` metadata. Their invocation field stays `unsupported`.

External sharing, destructive actions, and anything unclassified return `CONFIRMATION_REQUIRED` instead of running.

## Build

```bash
swift build
swift test
```

The binary is `.build/debug/rightclick-mcp`.

```bash
rightclick-mcp doctor
rightclick-mcp inspect fixtures/fixture.jpg
rightclick-mcp capabilities fixtures/fixture.jpg
rightclick-mcp capabilities "https://example.com"
rightclick-mcp describe service:com.apple.ChineseTextConverterService:convertTextToFullWidth "RightClick"
rightclick-mcp run service:com.apple.ChineseTextConverterService:convertTextToFullWidth "RightClick"
rightclick-mcp providers
rightclick-mcp mcp
```

`run` accepts `--yes` when an action requires confirmation. Add `--json` for machine-readable output.

## MCP

Stdio, for Cursor:

```json
{
  "mcpServers": {
    "rightclick": {
      "command": "/Users/ross/spawn/rightclick-mcp/.build/debug/rightclick-mcp",
      "args": ["mcp"]
    }
  }
}
```

That configuration is in `.cursor/mcp.json`. Tools:

- `context_inspect`
- `context_actions`
- `context_explain`
- `context_run`

Streamable HTTP uses the same tools:

```bash
rightclick-mcp mcp --http --port 8765 --token "$RIGHTCLICK_MCP_TOKEN"
```

Send `Authorization: Bearer <token>`, `Content-Type: application/json`, and `Accept: application/json, text/event-stream`.

## Evidence

`docs/EXPERIMENTS.md` records what was run. `docs/DECISIONS.md` records why the deprecated sharing API is still the discovery path. `docs/BUILD_STATE.md` is the current gate table.
