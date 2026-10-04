# RIGHTCLICK

## Give your AI the capabilities already installed on your Mac.

Install an app. Your AI learns what it can do.

```text
Install an app.
      ↓
macOS gains capabilities.
      ↓
RIGHTCLICK discovers them.
      ↓
Your AI can use them.
```

RIGHTCLICK is not a catalogue of hard-coded Mac automations. It discovers compatible contextual capabilities exposed by installed software and makes them available to MCP clients.

```text
You:
What can my Mac do with test.jpg?

AI:
I found 12 contextual actions, including Add to Photos, AirDrop, Mail, Markup,
and RIGHTCLICK Test — Create Sidecar.

You:
Run Create Sidecar.

AI:
Done.
```

That sidecar case is the RIGHTCLICK-004 experiment: an independent macOS Service was installed, RIGHTCLICK listed it without any provider-specific code, local and remote execution wrote `test.jpg.rightclick-test.txt`, and removing the provider removed the action. See `docs/PROOF.md`. The result is for the Services mechanism that was tested, not a claim about every Mac app.

## What RIGHTCLICK is not

- not screen clicking
- not generic Accessibility automation
- not a static tool list
- not an App Store replacement
- not evidence that every Finder menu item can be invoked

## Use

```bash
swift build -c release --product rightclick
```

The binary is `.build/release/rightclick`. A Homebrew formula template is in `packaging/homebrew/rightclick.rb`. It is not published.

```bash
rightclick doctor
rightclick setup
rightclick actions ~/Desktop/photo.jpg
rightclick run <action-id> <item> --yes
rightclick providers
rightclick refresh
rightclick serve
```

`rightclick mcp` speaks MCP over stdio. `rightclick serve` listens for Streamable HTTP. Add `--json` to machine-readable commands.

External shares, destructive actions, financial actions, and anything unclassified return confirmation instead of running. `NSPerformService` returning true means the service was accepted. A sharing action stays in progress until `didShareItems`, `didFailToShareItems`, or the deadline.

## Cursor

`rightclick setup` writes or updates the `rightclick` entry in `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "rightclick": {
      "command": "/path/to/rightclick",
      "args": ["mcp"]
    }
  }
}
```

Tools: `context_inspect`, `context_actions`, `context_run`, `context_run_status`, `context_explain`, `context_providers`.
