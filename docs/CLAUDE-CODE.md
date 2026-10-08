# Claude Code plugin

RIGHTCLICK can be loaded as a Claude Code plugin without adding Claude-specific AI-facing tools.

## Requirements

- macOS
- Claude Code with plugin support
- RIGHTCLICK installed and available on `PATH`

Install the current stable RIGHTCLICK release:

```sh
brew install rossbuckley1990-hash/tap/rightclick
rightclick version
```

## Plugin wiring

The repository root contains:

- `.claude-plugin/plugin.json` - Claude Code plugin metadata.
- `.mcp.json` - starts the installed `rightclick` executable as the stdio MCP server.
- `skills/rightclick/SKILL.md` - RIGHTCLICK operating guidance already carried by the repository.

The plugin deliberately does not create provider-specific Claude tools. Claude connects to the same seven generic RIGHTCLICK MCP operations and discovers environment-derived capabilities through the runtime.

## Local verification

From a checkout of this repository:

```sh
claude --plugin-dir .
```

Then verify the runtime in Claude through the generic surface:

1. `context_runtime` - confirm the executable, version, SHA-256 and stdio transport.
2. `context_inspect` - classify the object before capability selection.
3. `context_providers` - observe the providers reflected from the current environment.
4. `context_actions` - ask which capabilities apply to an object.
5. `context_explain` - inspect authority, safety and support metadata before execution.
6. `context_run` - execute only after any required confirmation.
7. `context_run_status` - inspect asynchronous or consequential execution state.

Provider acceptance is not semantic success. Where a postcondition can be observed, verify the intended outcome rather than treating an HTTP 2xx or provider callback as proof.
