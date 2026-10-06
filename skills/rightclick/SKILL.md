---
name: rightclick
description: Discover, inspect, authorize, execute, and verify environment-derived capabilities through RIGHTCLICK. Use when an agent needs to learn what the current macOS environment or reflected OpenAPI/GraphQL providers can do at runtime instead of relying on a fixed provider-specific tool list.
---

# RIGHTCLICK

RIGHTCLICK is an environment-derived capability runtime for AI agents.

Use it when the useful question is not only "which preconfigured tool should I call?" but "what can this environment do right now?"

## When to use RIGHTCLICK

Use RIGHTCLICK when:

- the user asks what can be done with a file, URL, or text in the current environment;
- installed software may contribute useful capabilities;
- local or network providers may appear or disappear at runtime;
- an OpenAPI or GraphQL provider may expose a capability without a provider-specific AI integration;
- the user wants execution evidence rather than an assumption that a provider response means the task succeeded;
- the task should stay behind a small generic capability interface rather than accumulating provider-specific top-level tools.

## Preconditions

RIGHTCLICK currently targets Apple Silicon macOS 14+.

Stable install:

```bash
brew install rossbuckley1990-hash/tap/rightclick
```

For supported local AI clients:

```bash
rightclick setup
```

RIGHTCLICK can also run as an MCP server directly:

```bash
rightclick mcp
```

If the RIGHTCLICK MCP tools are already available in the current session, do not reinstall or create a substitute integration.

## Operating contract

RIGHTCLICK exposes seven generic operations:

- `context_runtime`
- `context_inspect`
- `context_actions`
- `context_explain`
- `context_run`
- `context_run_status`
- `context_providers`

Follow this sequence.

### 1. Identify the runtime

Call `context_runtime` when execution identity matters. Treat its executable path, resolved path, SHA-256, PID, version, and transport as the runtime attestation for the current connection.

### 2. Inspect the exact object or task

Call `context_inspect` on the exact file path, URL, or text supplied by the user when classification is useful.

### 3. Discover live capabilities

Call `context_actions` on the exact object or task.

The returned list is the current capability graph. Do not invent actions that were not returned. A capability may appear or disappear when the environment changes.

Use `context_providers` when the user needs to know which providers are currently contributing capabilities.

### 4. Explain before consequential execution

Call `context_explain` for the selected capability before executing a consequential or unfamiliar action.

Pay attention to provider, substrate, argument schema, safety classification, confirmation requirements, authority requirements, and the result-validation boundary.

### 5. Respect confirmation

Never set `confirmed: true` merely because an action is available. Only confirm when the user has explicitly authorized that consequential action.

### 6. Execute only the reflected contract

Call `context_run` using the exact discovered capability ID or title and only arguments allowed by the reflected schema.

Do not add undeclared fields, guess provider-specific arguments, expose credentials in model-facing arguments, or replace RIGHTCLICK with a provider-specific substitute when the user explicitly asked to use RIGHTCLICK.

### 7. Distinguish acceptance from success

A successful API call, HTTP 2xx response, sharing callback, or provider acknowledgement is not automatically proof that the user's intended outcome occurred.

Treat `accepted` as provider acceptance only. Use `context_run_status` and provider-independent verification predicates when an observable postcondition can establish the result.

Prefer independently observed state such as exact returned text, file existence/readability, SHA-256 equality or change, file size, image dimensions, metadata or xattr state, or a separate read-back capability for durable remote state.

Report `VERIFIED_SUCCESS` only when the required postcondition was actually observed.

## Core principle

```
environment changes
      ↓
RIGHTCLICK acquires supported capability contracts
      ↓
capability graph changes
      ↓
the same generic AI interface discovers the new ability
      ↓
authority is resolved
      ↓
the agent acts
      ↓
the result is verified where observable
```

MCP is the transport. Capability acquisition is the product.

## Project

https://github.com/rossbuckley1990-hash/rightclick

RIGHTCLICK is Apache-2.0 and includes public evidence for dynamic capability gain/loss, structured OpenAPI reflection, durable read-back verification, origin-bound bearer authority, real GitHub API compatibility, GraphQL reflection on current main, and multi-client onboarding.
