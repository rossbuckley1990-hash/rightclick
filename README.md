# RIGHTCLICK

## Install an app. Your AI learns what it can do.

RIGHTCLICK reflects capabilities that software already exposes on your Mac. Give an AI a file, text, or a URL; it can ask which capabilities apply, inspect their safety and support, and invoke supported ones with confirmation where required. MCP carries those requests between your AI and RIGHTCLICK.

The v0.1 proof is ordinary BBEdit installation: the same text query changed from **36 capabilities, 0 third-party** to **41 capabilities, 5 BBEdit capabilities**, with **zero BBEdit-specific RIGHTCLICK changes**. Its “New BBEdit Document with Selection” Service received the exact fixture through the generic executor. See [the evidence](docs/BBEDIT-PROOF.md).

Not every installed app exposes compatible native capabilities. RIGHTCLICK does not claim universal app compatibility or access to every right-click menu item.

### Install

v0.1.0 targets Apple Silicon and macOS 14 or later. Homebrew is the primary distribution path; no paid Apple Developer account is required. The [0.1.0 release](https://github.com/rossbuckley1990-hash/rightclick/releases/tag/v0.1.0) and [tap](https://github.com/rossbuckley1990-hash/homebrew-tap) are public:

```bash
brew install rossbuckley1990-hash/tap/rightclick
rightclick setup
```

The published Apple Silicon Tahoe bottle avoids compilation on a matching Mac. Source fallback needs Swift 6.2 or later from the free Apple Command Line Tools. Older Command Line Tools cannot compile the pinned dependencies. Update them through Software Update when a compatible version is available. Runtime deployment targets macOS 14; acceptance was performed on macOS 26.4.1, and older macOS versions have not been independently validated. Do not disable macOS security.

For contributors, a local source checkout supports:

```bash
swift test
scripts/build-cli.sh
.build/release/rightclick version
.build/release/rightclick doctor
.build/release/rightclick setup
```

`setup` checks discovery and merges only the `rightclick` entry into `~/.cursor/mcp.json`, using the executable you ran. Enable RIGHTCLICK in Cursor's MCP settings if required, then start a new chat and ask “What can my Mac do with this text: RightClick?” Other MCP clients can launch the Homebrew-installed executable with argument `mcp`.

```bash
rightclick actions "RightClick third party capability test"
rightclick actions fixtures/fixture.jpg
rightclick providers
rightclick run --yes service:com.barebones.bbedit:openSelectionService "RIGHTCLICK demo fixture"
```

Inspect the discovered action before confirming a run. Installed software and system preferences determine which actions appear; counts are observations from the proof Mac, not fixed product expectations.

### Capability Reflection

```text
environment
    ↓
existing capability contracts
    ↓
generic reflection
    ↓
normalized contextual capability graph
    ↓
policy / permissions
    ↓
AI
    ↓
execution
    ↓
outcome verification
```

v0.1 tests this architecture using macOS Services, sharing services, and Finder Action extension metadata. The CLI and six MCP tools use the same engine: `context_inspect`, `context_actions`, `context_explain`, `context_run`, `context_run_status`, and `context_providers`.

Services come from documented `NSServices` metadata and run through `NSPerformService`. Sharing discovery uses the deprecated `NSSharingService.sharingServices(forItems:)`; it still returns a context-filtered catalog on the proof Mac. Sharing invocation uses public `perform(withItems:)`. Finder Action extensions are discovered from metadata and marked unsupported for invocation because `NSExtension` is absent from the public SDK.

### Evidence and limits

- BBEdit acquisition and exact semantic execution pass.
- Yojam acquisition, applicability, payload construction, and invocation pass. Its semantic result remains a [documented limitation](docs/YOJAM-LIMITATION.md); the one standalone AppKit control did not verify a browser result.
- `NSPerformService == true` means invocation was accepted. The legacy execution state `succeeded` does **not** prove an external outcome. Verify returned data or an independent provider result before claiming completion.
- External, destructive, financial, and unclassified actions require confirmation. Interactive actions may need someone at the Mac.
- Execution status is retained in the serving process; it is lost on restart and is unavailable to a separate CLI process.
- Authenticated Streamable HTTP works on loopback. `rightclick serve` prints a bearer secret; keep it private. Development tunnels are optional and require explicit, deliberate exposure.

The capability engine is frozen for v0.1. New platforms and capability families are outside this release. [Completion evidence](docs/V0.1_COMPLETION_REPORT.md), [release procedure](docs/RELEASE.md), [security](SECURITY.md), [contributing](CONTRIBUTING.md), and [Apache-2.0 licence](LICENSE).
