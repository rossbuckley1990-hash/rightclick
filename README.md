# RIGHTCLICK

## Install an app. Your AI learns what it can do.

RIGHTCLICK discovers contextual capabilities exposed by software already installed on macOS and makes the applicable ones available to MCP clients.

```text
Installed software
       ↓
native macOS capability metadata
       ↓
RIGHTCLICK
       ↓
contextual capability graph
       ↓
MCP
       ↓
AI
```

```text
install app
→ capabilities appear

remove app
→ capabilities disappear
```

## The BBEdit experiment

An ordinary copy of BBEdit 16.0.3 was installed after a frozen baseline. RIGHTCLICK was not changed.

```text
BEFORE BBEdit

36 text capabilities
0 third-party

install ordinary BBEdit 16.0.3

AFTER

41 capabilities
5 new third-party
```

The five new capabilities, read from BBEdit's own macOS Services metadata:

- New BBEdit Document with Selection
- New Note in BBEdit
- Open File in BBEdit
- Search Here in BBEdit
- Append Selection to BBEdit Scratchpad

```text
BBEdit-specific RIGHTCLICK code:
NONE
```

BBEdit is not an MCP server. BBEdit was not built for RIGHTCLICK. RIGHTCLICK derived those capabilities from normal `NSServices` metadata. The generic Services executor then transferred selected text into a new BBEdit document. The chronology is in `docs/BBEDIT-PROOF.md`.

## Ask what this computer can do

RIGHTCLICK does not publish hundreds of static MCP tools. The model asks:

> What can this computer do with this thing?

The MCP surface is six tools:

- `context_inspect`
- `context_actions`
- `context_run`
- `context_run_status`
- `context_explain`
- `context_providers`

`context_actions` returns only the capabilities macOS currently exposes for that object. `context_run` invokes one of those discovered capabilities.

## What v0.1 does

Proven on the development Mac:

- macOS Services discovery
- generic Services invocation
- Sharing Service discovery, and execution where the public API reports a terminal result
- Action Extension discovery
- contextual filtering by the object you pass in
- local stdio MCP
- remote Streamable HTTP MCP
- confirmation and safety metadata

Limits:

- Action Extensions are discovered. They are not generically executable. `NSExtension` is not in the public SDK.
- Not every Mac application exposes Services, sharing services, or Action Extensions.
- A provider accepting an invocation is not the same as a verified semantic outcome. `NSPerformService` returning true means the service was accepted.
- Some capabilities are interactive and need a person at the Mac.
- Sharing discovery uses `NSSharingService.sharingServices(forItems:)`, which is deprecated and is still the call that returns a context-filtered catalog here.
- Remote tunnel examples are for development and testing. Do not publish a tunnel without the bearer token.
- A publicly signed and notarised download is not available yet. There is no Developer ID signature in this tree.

RIGHTCLICK is not screen clicking, not a fixed catalogue of automations, and not a claim that every Finder menu item can be invoked.

## Quickstart

Build from source:

```bash
git clone <repo>
cd rightclick
swift build -c release --product rightclick
.build/release/rightclick doctor
```

Cursor. `rightclick setup` merges only the `rightclick` entry in `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "rightclick": {
      "command": "/Users/you/src/rightclick/.build/release/rightclick",
      "args": ["mcp"]
    }
  }
}
```

Other commands:

```bash
.build/release/rightclick actions ~/Desktop/photo.jpg
.build/release/rightclick run <action-id> <item> --yes
.build/release/rightclick providers
.build/release/rightclick refresh
.build/release/rightclick serve
```

`rightclick mcp` speaks MCP over stdio. `rightclick serve` listens for Streamable HTTP on `127.0.0.1`. Add `--json` for machine-readable output.

External shares, destructive actions, financial actions, and anything unclassified return confirmation instead of running.

## Later

A public Homebrew install is not available yet. The intended command, once a real archive and tap exist, is:

```bash
brew install <tap>/rightclick
```

`packaging/homebrew/rightclick.rb` is an unpublished template. It is not a working install. See `SECURITY.md` and `docs/SIGNING.md`.
