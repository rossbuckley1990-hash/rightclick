# Clodfarm x RIGHTCLICK experiment

## Hypothesis

A Clodfarm-style Claude Code session can use RIGHTCLICK as its execution plane through MCP while RIGHTCLICK keeps exactly seven generic agent-facing operations:

- context_runtime
- context_inspect
- context_actions
- context_explain
- context_run
- context_run_status
- context_providers

No Clodfarm-specific RIGHTCLICK tool, provider, or action is introduced.

## Scope

This branch is experimental only. It must not be merged, tagged, released, or used as production configuration on the basis of this experiment alone.

The experiment uses the public repository matank001/clodfarm as the current compatibility fixture and checks the MCP/plugin surface described by that repository. The active protocol probe is intentionally independent of Clodfarm implementation details beyond the fact that a Claude Code session can consume MCP servers.

## Architecture

Clodfarm-style Claude Code session
-> MCP stdio
-> RIGHTCLICK
-> seven generic context_* operations
-> dynamically reflected providers/capabilities
-> explicit execution state and evidence boundary

## What is live vs simulated

Live:
- current public Clodfarm source is cloned by CI
- RIGHTCLICK is built from this branch
- a real RIGHTCLICK process is started over stdio
- MCP initialize, tools/list, and tools/call are executed against that process
- context_runtime, context_providers, context_actions, context_explain, context_run, and context_run_status are exercised when applicable

Protocol-level simulation:
- the Python client represents the MCP behavior of a Clodfarm-hosted Claude Code session
- no live Anthropic account, Clodfarm account, or farm worker is required
- provider availability inside CI may differ from a user's Mac

## Evidence rules

A provider 2xx response is not treated as semantic success.
The probe records RIGHTCLICK's returned state and execution evidence exactly.
Rejected, failed, unavailable, or unknown outcomes are valid experiment evidence when the MCP path itself succeeds.

## Commands

```bash
swift build
python3 experiments/clodfarm-rightclick/mcp_probe.py .build/debug/rightclick
```

CI additionally clones:

```bash
git clone --depth=1 https://github.com/matank001/clodfarm.git
```

and checks for the current Clodfarm MCP/plugin integration markers before running the RIGHTCLICK probe.

## Success criterion

The hypothesis is supported if a Clodfarm-style MCP client can initialize RIGHTCLICK, observe exactly the seven generic tools, use the discovery/explain path, invoke context_run, and read the resulting state without requiring any Clodfarm-specific RIGHTCLICK capability.

The hypothesis is falsified if Clodfarm's current MCP integration requires a provider-specific tool contract that cannot address RIGHTCLICK's standard MCP server surface.

## Current result

Pending CI execution on feature/clodfarm-rightclick-experiment.
