# RIGHTCLICK

## Your agent shouldn't need a new integration every time it gains a new ability.

**RIGHTCLICK is a safe dynamic capability runtime for AI.**

It discovers capability contracts exposed by the software and services around an agent, normalizes them into one live capability graph, and lets the agent inspect and use them through **seven generic operations**.

Install software.  
Start a service.  
Expose a compatible API.  
Connect another RIGHTCLICK runtime.

**The capability graph changes. The AI-facing interface does not.**

```text
environment changes
        ↓
RIGHTCLICK discovers a supported capability contract
        ↓
capability enters the live graph
        ↓
AI can inspect it
        ↓
RIGHTCLICK applies authority + safety rules
        ↓
AI can invoke it
        ↓
RIGHTCLICK distinguishes provider acceptance from verified outcome
```

> **Universal by reflection, not by a growing pile of provider-specific AI tools.**

Shared runtime · macOS / Linux / Windows targets · MCP · Apache-2.0

The published Homebrew release is currently macOS-only. See [portable runtime build instructions and adapter limits](docs/PORTABILITY.md) for the shared implementation and its release gates.

---

# Try it

## Install

```bash
brew install rossbuckley1990-hash/tap/rightclick
```

Check the runtime:

```bash
rightclick version
rightclick doctor
```

Ask what applies to some text:

```bash
rightclick actions "RightClick"
```

Try a file:

```bash
rightclick actions ~/Desktop/example.jpg
```

Try a URL:

```bash
rightclick actions "https://example.com"
```

See the providers contributing to the graph:

```bash
rightclick providers
```

You are **not** querying a static provider integration list.

RIGHTCLICK evaluates what the current environment can expose for the current object or task.

---

# Give the same capability runtime to your AI

For detected supported local clients:

```bash
rightclick setup --all --dry-run --json
rightclick setup --all --yes
```

Or configure one client explicitly.

### Cursor

```bash
rightclick setup --client cursor --dry-run --json
rightclick setup --client cursor --yes
```

### Claude Code

```bash
rightclick setup --client claude --dry-run --json
rightclick setup --client claude --yes
```

RIGHTCLICK uses Claude Code's native MCP registration instead of editing Claude configuration behind its back.

### Codex

```bash
rightclick setup --client codex --dry-run --json
rightclick setup --client codex --yes
```

RIGHTCLICK uses Codex's native MCP registration and fails closed on conflicting same-name registrations.

### ChatGPT

```bash
rightclick setup chatgpt --dry-run --json
rightclick setup chatgpt --yes
```

The persistent ChatGPT bridge includes runtime attestation and upgrade reconciliation rather than treating configuration as proof of a live connection.

### Any MCP client

Run RIGHTCLICK directly over stdio:

```bash
rightclick mcp
```

Equivalent MCP configuration:

```json
{
  "mcpServers": {
    "rightclick": {
      "command": "/opt/homebrew/bin/rightclick",
      "args": ["mcp"]
    }
  }
}
```

Use `which rightclick` if Homebrew is installed elsewhere.

RIGHTCLICK also supports authenticated local HTTP for clients that cannot launch a stdio process.

---

# The seven-operation contract

RIGHTCLICK keeps the model-facing surface deliberately small.

| Operation | Purpose |
|---|---|
| `context_runtime` | Identify the exact RIGHTCLICK runtime serving the AI |
| `context_inspect` | Parse and classify the current object/context |
| `context_actions` | Discover capabilities that apply now |
| `context_explain` | Inspect one capability before execution |
| `context_run` | Execute a discovered capability |
| `context_run_status` | Read execution and verification evidence |
| `context_providers` | Inspect providers contributing to the live graph |

A provider does **not** require a permanent top-level tool such as:

```text
github_create_issue
github_merge_branch
slack_send_message
foo_create_record
bar_transform_image
```

Supported provider operations are reflected into the same generic capability model and executed through the same `context_run`.

That is the architectural invariant.

---

# What can enter the capability graph?

RIGHTCLICK is not built around a list of brands.

It is built around **capability substrates** and **discovery sources**.

## Native macOS software

RIGHTCLICK can discover contextual capabilities ordinary applications already expose through supported macOS contracts, including:

- Services
- sharing services
- Finder Action extension metadata

The original BBEdit experiment remains the simplest proof:

```text
before ordinary BBEdit installation
36 capabilities
0 third-party capabilities

after installation
41 capabilities
5 BBEdit capabilities

BBEdit-specific RIGHTCLICK acquisition code added
0
```

[See the BBEdit proof](docs/BBEDIT-PROOF.md).

## OpenAPI

RIGHTCLICK can reflect supported OpenAPI operations into generic capabilities.

The OpenAPI path includes work for:

- plain-text operations
- closed structured JSON object requests
- generic structured arguments
- path parameters
- zero-argument GET operations
- validated structured JSON responses
- provider appearance/removal
- separate specification and execution origins
- origin-bound bearer authority
- exact execution-origin credential binding
- real authenticated GitHub compatibility

Unsupported or ambiguous shapes abstain instead of being guessed into existence.

## GraphQL

RIGHTCLICK contains a generic GraphQL reflector.

A reflected GraphQL operation becomes an ordinary RIGHTCLICK capability rather than a GraphQL-specific AI tool.

The model-facing interface stays the same.

## gRPC reflection

The repository integration line includes generic gRPC capability reflection.

The design uses gRPC reflection/descriptors to derive supported capabilities rather than adding provider-specific gRPC tools.

Unsupported method/message shapes remain unavailable rather than silently widening execution.

## RIGHTCLICK federation

One RIGHTCLICK runtime can reflect capabilities exposed by another RIGHTCLICK runtime.

This allows the live graph to extend beyond one process or one machine while preserving the same capability semantics.

Federated provider acceptance is still not automatically semantic success.

## Universal capability artifact input

On the repository integration line, RIGHTCLICK can accept provider-neutral artifact descriptors through one generic environment contract:

```bash
export RIGHTCLICK_CAPABILITY_ARTIFACTS='[
  {
    "id": "orders-api",
    "kind": "openapi",
    "specificationURL": "https://api.example.com/openapi.json",
    "baseURL": "https://api.example.com"
  },
  {
    "id": "knowledge-graph",
    "kind": "graphql",
    "endpointURL": "https://graph.example.com/graphql"
  },
  {
    "id": "compute",
    "kind": "grpc",
    "endpointURL": "grpcs://compute.example.com:443"
  }
]'
```

Those three descriptors enter the same resolver registry and become ordinary RIGHTCLICK reflectors.

The agent still sees the same seven operations.

Security defaults remain conservative:

- remote HTTP artifacts must use HTTPS
- plaintext HTTP is loopback-only
- remote gRPC must use `grpcs://`
- plaintext `grpc://` is loopback-only
- OpenAPI and GraphQL may reference a locally configured authority scheme
- gRPC authority advertisements currently fail closed until generic metadata authority is implemented
- duplicate descriptor IDs or duplicate resulting reflector identities are rejected
- resolved artifacts are cached for a short bounded refresh window rather than reacquired for every agent query

This environment contract is an integration surface for the current repository code. The published Homebrew v0.2.1 release predates this universal artifact layer.

## ARD as an optional discovery source

RIGHTCLICK can consume supported ARD search results as another **source of capability artifacts**.

ARD does not define RIGHTCLICK's architecture.

The rule is:

```text
discovery source
      ↓
supported capability contract
      ↓
ordinary RIGHTCLICK reflector
      ↓
ordinary RIGHTCLICK capability
```

A discovered ARD OpenAPI artifact therefore enters the same execution, authority and verification runtime as an OpenAPI provider discovered another way.

That is intentional: **ARD is an input, not the product boundary.**

---

# The architecture

```text
                         AI / AGENT
                              │
                     seven generic operations
                              │
                              ▼
                    ┌───────────────────┐
                    │    RIGHTCLICK     │
                    │ capability runtime │
                    └─────────┬─────────┘
                              │
                       live capability graph
                              │
              ┌───────────────┼────────────────┐
              │               │                │
          fixed/local      dynamic          contextual
          reflectors       sources          sources
              │               │                │
              └───────────────┼────────────────┘
                              │
                         reflectors
                              │
          ┌──────────┬────────┼────────┬───────────┐
          ▼          ▼        ▼        ▼           ▼
       macOS      OpenAPI   GraphQL   gRPC     federation
          │          │        │        │           │
          └──────────┴────────┼────────┴───────────┘
                              ▼
                    normalized Capability
                              │
                  safety / confirmation
                              │
                       authority binding
                              │
                           execution
                              │
                          observation
                              │
                         verification
```

The important boundaries are explicit.

### Sources discover reflectors

A discovery source may change as the environment changes.

It does not grant authority, invoke capabilities, or establish semantic success.

### Reflectors normalize capability substrates

OpenAPI, GraphQL, gRPC, native macOS contracts and federated peers all compile into RIGHTCLICK's capability model.

### The engine owns routing and policy

A provider cannot choose another provider's execution route by spoofing metadata.

Duplicate reflector identities fail closed.

### Verification sits above provider acceptance

A successful transport response is not automatically the user's requested outcome.

---

# Discover aggressively. Execute safely. Verify relentlessly.

Dynamic discovery without a control boundary is not enough.

RIGHTCLICK separates:

```text
CAPABILITY EXISTS
CAPABILITY APPLIES
CAPABILITY CAN EXECUTE
AUTHORITY IS AVAILABLE
USER CONFIRMATION IS REQUIRED
PROVIDER ACCEPTED THE REQUEST
REQUESTED OUTCOME WAS VERIFIED
```

These are different states.

## Confirmation

Consequential or unknown actions can require explicit confirmation before invocation.

## Authority below the model

Supported credentials can be resolved locally and injected at the execution boundary.

The bearer secret does not need to become a `context_run` argument.

Authority can be bound to the exact execution origin.

Redirects do not silently inherit that authority.

## Verification

RIGHTCLICK supports provider-independent postconditions such as:

- exact returned text
- file existence/readability
- SHA-256 equality/change
- file-size thresholds
- image dimensions
- extended-attribute presence/absence
- metadata presence/absence
- before/after observable state

Durable remote-state tests also demonstrate the principle of **independent read-back**:

```text
POST accepted
     ↓
not yet semantic success
     ↓
separate discovered GET
     ↓
persisted state observed
     ↓
VERIFIED
```

---

# RIGHTCLICK can use RIGHTCLICK's own architecture

RIGHTCLICK development includes a self-hosting proof where the normal GitHub integration available to the AI could not perform the required repository mutation.

RIGHTCLICK reflected GitHub's API generically and exposed:

```text
Merge a branch
```

through the same `context_run` interface.

RIGHTCLICK executed the reflected operation with origin-bound authority, correctly reported GitHub's `201` only as provider acceptance, and a separate repository read verified the resulting branch state.

[See the self-hosting proof](evidence/self-hosting-2026-10-07/README.md).

No `github_merge_branch` top-level RIGHTCLICK tool was added.

---

# Why this is not just MCP

RIGHTCLICK speaks MCP.

MCP answers:

> How does an AI communicate with an external capability?

RIGHTCLICK is working on another layer:

> How does an AI acquire the capabilities that exist in its current environment without loading a bespoke integration for every provider?

These layers complement each other.

```text
provider-specific integration model

provider
  ↓
someone builds an AI integration
  ↓
provider-specific tools
  ↓
agent


RIGHTCLICK model

provider
  ↓
compatible capability contract
  ↓
RIGHTCLICK reflector
  ↓
live capability graph
  ↓
same seven AI-facing operations
```

---

# Why not just use a registry?

Registries are useful.

They answer questions such as:

```text
What packages, servers or agents have been published?
```

RIGHTCLICK's core question is different:

```text
What can this environment safely do right now?
```

A registry can therefore become one discovery source among many.

So can:

- installed software
- Bonjour
- configured providers
- ARD
- MCP registries
- A2A Agent Cards
- enterprise service catalogs
- federated RIGHTCLICK runtimes
- future capability substrates

The source can expand without expanding the model-facing tool list.

---

# The universal design rule

A new capability family belongs in RIGHTCLICK only if it can preserve these invariants:

1. **It widens the universe of discoverable capabilities.**
2. **It does not require a provider-specific AI-facing tool.**
3. **It preserves or strengthens safety.**
4. **It compiles into the same generic capability runtime.**
5. **Unsupported or ambiguous contracts fail closed.**
6. **Provider acceptance is not mislabeled as verified user success.**

The long-term objective is not to manually integrate every product.

It is to make the provider protocol increasingly irrelevant to the agent.

---

# CLI

RIGHTCLICK can also be used without an AI client.

```bash
rightclick doctor

rightclick inspect "some text"
rightclick inspect ~/Desktop/file.pdf

rightclick actions "some text"
rightclick actions ~/Desktop/photo.jpg

rightclick providers

rightclick explain <capability-id> <item>

rightclick run <capability-id> <item>

rightclick status <execution-id>

rightclick version
```

Add `--json` where supported for machine-readable output.

---

# Published release vs repository main

The latest published Homebrew release is **v0.2.1**:

```bash
brew install rossbuckley1990-hash/tap/rightclick
```

The repository can move ahead of the published formula while new substrate work is being integrated.

To build the repository version:

```bash
git clone https://github.com/rossbuckley1990-hash/rightclick.git
cd rightclick

swift test --force-resolved-versions
swift build -c release

.build/release/rightclick version
.build/release/rightclick doctor
.build/release/rightclick mcp
```

The README distinguishes released behaviour from repository behaviour rather than pretending every merged capability is already in the Homebrew release.

---

# Requirements

Current runtime target:

```text
Apple Silicon
macOS 14+
```

RIGHTCLICK does not require disabling macOS security.

Not every application exposes a capability contract RIGHTCLICK can use.

Not every API schema shape is supported.

That is expected.

The engineering goal is to widen the **generic language of capabilities** without turning RIGHTCLICK into a catalog of special cases.

---

# Evidence

Important evidence is preserved in the repository because the central claims are easy to overstate.

- [BBEdit — capability acquisition without provider-specific code](docs/BBEDIT-PROOF.md)
- [v0.1 scalability and blind-discovery evidence](evidence/v0.1-scalability-blind/README.md)
- [MOAT-001 — structured OpenAPI capability acquisition](evidence/moat-001-structured-openapi-2026-10-06/README.md)
- [MOAT-002 — durable state + independent read-back](evidence/moat-002-durable-readback-2026-10-06/README.md)
- [MOAT-003 — generic bearer authority](evidence/moat-003-generic-bearer-authority-2026-10-06/README.md)
- [MOAT-004 — real GitHub-compatible acquisition](https://github.com/rossbuckley1990-hash/rightclick/pull/9)
- [Self-hosting through a reflected GitHub capability](evidence/self-hosting-2026-10-07/README.md)
- [Security](SECURITY.md)
- [Release process](docs/RELEASE.md)

---

# Contributing

The most valuable contributions are generic.

Good:

```text
"this capability substrate can be reflected safely"
"this schema shape can be normalized generically"
"this authority boundary is too weak"
"this provider acceptance is being confused with semantic success"
"this discovery source should enter the existing graph"
```

Less useful:

```text
"add a permanent top-level tool for provider X"
```

Before adding a substrate or discovery source, ask:

> Can this teach RIGHTCLICK a new class of capability without teaching every AI client a new provider-specific interface?

If yes, it is probably pointing in the right direction.

---

# North star

An agent enters an environment.

It does not arrive with every tool it will ever need.

Instead:

```text
it observes the environment
        ↓
software and services expose capability contracts
        ↓
RIGHTCLICK discovers supported contracts
        ↓
reflectors normalize them
        ↓
capabilities become available
        ↓
authority and safety policy are applied
        ↓
the agent acts
        ↓
the result is verified where observable
```

A new application appears.

**The agent gains an ability.**

A service comes online.

**The agent gains an ability.**

A compatible API appears.

**The agent gains an ability.**

Another RIGHTCLICK runtime becomes reachable.

**The graph gets larger.**

No rebuild of the agent.

No provider-specific top-level AI tool required.

No assumption that transport success means the job is done.

> ## Software appears. Your AI learns what it can safely do.

---

Apache-2.0
