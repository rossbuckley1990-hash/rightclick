# RIGHTCLICK

> ## AI should discover what it can do from its environment.

**RIGHTCLICK is an environment-derived capability runtime for AI agents.**

Instead of requiring every ability to be manually exposed to an AI as another provider-specific tool or integration, RIGHTCLICK discovers compatible capabilities that software and services already expose, normalizes them behind one stable interface, applies authority and confirmation at execution time, and verifies what actually happened.

**MCP is the transport. Capability discovery is the product.**

---

## The problem

AI agents become useful by giving them tools.

Today that usually means explicitly wiring capabilities into the agent:

```text
AI
├── GitHub integration / MCP
├── Slack integration / MCP
├── Notion integration / MCP
├── filesystem integration / MCP
├── database integration / MCP
├── internal API integration / MCP
├── ...
```

Every new integration can introduce another lifecycle:

- discovery and configuration
- schemas and tool definitions
- authentication
- permissions
- deployment
- maintenance
- tool selection
- failure handling
- verification

As the number of systems grows, the AI-facing tool surface grows with it.

RIGHTCLICK explores a different architecture:

```text
                         AI
                          │
                 7 generic operations
                          │
                          ▼
                    RIGHTCLICK
                          │
                 capability runtime
                          │
          ┌───────────────┼────────────────┐
          ▼               ▼                ▼
     local software   network services   future sources
          │               │                │
          └──────── capability contracts ──┘
                          │
                          ▼
                    real outcomes
```

The agent does not need a new RIGHTCLICK tool every time a new compatible capability appears.

The environment changes.

**The capability graph changes with it.**

---

# The thesis

The unit of integration should not have to be:

> **one AI-specific integration for every application or service**

It can instead become:

> **software exposes a compatible capability contract → RIGHTCLICK reflects it → the AI can use it through the same runtime**

That means an ability can appear because software appeared, and disappear because the provider disappeared, without adding or removing an AI-facing tool.

The goal is:

```text
Software becomes available
        ↓
RIGHTCLICK discovers what it can do
        ↓
RIGHTCLICK reflects compatible capabilities
        ↓
AI gains those abilities
        ↓
authority + policy + confirmation are enforced
        ↓
capability executes
        ↓
outcome is verified where possible
```

This is what we mean by **environment-derived capability acquisition**.

---

# What RIGHTCLICK does

RIGHTCLICK separates five concerns that are commonly collapsed into a tool call:

### 1. Discover

Find capability contracts exposed by the current environment.

Current discovery surfaces include compatible macOS capability surfaces and supported Bonjour-advertised OpenAPI providers.

### 2. Normalize

Translate provider-specific capability descriptions into a common capability model.

The AI does not need a provider-specific MCP tool for every reflected operation.

### 3. Authorize

Determine whether the capability is available and whether the required authority exists.

Supported network authority can be resolved outside the AI-facing MCP arguments.

### 4. Execute safely

Apply support boundaries, confirmation policy and provider-specific execution at the runtime boundary.

Unsupported or ambiguous capability shapes abstain rather than being guessed.

### 5. Verify

Do not equate:

```text
provider accepted request
```

with:

```text
requested outcome happened
```

RIGHTCLICK can evaluate provider-independent postconditions and distinguish accepted execution from verified success, verified failure, or an outcome it cannot prove.

---

# A stable AI-facing surface

RIGHTCLICK currently exposes seven generic MCP tools:

| Tool | Purpose |
|---|---|
| `context_runtime` | Prove exactly which RIGHTCLICK runtime is serving the connection |
| `context_inspect` | Classify the object or context |
| `context_actions` | Discover capabilities that apply right now |
| `context_explain` | Inspect provider, support, effects and confirmation requirements |
| `context_run` | Execute a discovered capability |
| `context_run_status` | Read execution and verification evidence |
| `context_providers` | Inspect the currently reflected providers |

A newly reflected capability does **not** require a new MCP tool name.

For example, the same `context_run` interface can carry provider-independent structured arguments:

```json
{
  "item": "Create a high-priority record",
  "actionId": "Create Structured Record",
  "arguments": {
    "title": "RightClick learned structured JSON live",
    "priority": "high"
  },
  "confirmed": true
}
```

The capability schema comes from the reflected provider contract.

RIGHTCLICK remains the generic runtime.

---

# Capabilities are live, not static

RIGHTCLICK's capability graph is derived from the environment it can observe.

That means capability availability can change without changing the model-facing tool contract.

The v0.2 lineage demonstrated:

```text
provider absent
    ↓
capability absent

provider appears
    ↓
capability discovered

provider disappears
    ↓
capability removed
```

This is fundamentally different from permanently attaching a static catalog of provider-specific tools to an agent.

---

# Authority stays at the execution boundary

Current `main` also demonstrates generic HTTP bearer authority for a supported OpenAPI security slice.

The AI does not provide the bearer secret through `context_run`.

Instead, RIGHTCLICK can:

```text
reflected capability
        ↓
security requirement
        ↓
exact provider origin
        ↓
origin-bound authority lookup
        ↓
credential injected at transport boundary
```

The MOAT-003 implementation uses a macOS Keychain generic-password item bound to the exact canonical origin and security scheme.

Observed states included:

```text
authority absent
→ capability execution unavailable before provider transport

authority present
→ authorized provider execution

authority removed
→ unavailable again before provider transport
```

No bearer secret was supplied through MCP.

This is deliberately a narrow supported authentication slice, not a claim of arbitrary OpenAPI authentication.

---

# Provider acceptance is not success

One of RIGHTCLICK's core rules is:

> **A tool call completing is not proof that the user's requested outcome occurred.**

RIGHTCLICK execution records distinguish states including:

```text
started
awaiting_user
unsupported
unavailable
rejected
accepted
succeeded
failed
cancelled
unknown
```

Semantic verification can additionally evaluate observable postconditions such as:

- exact returned text
- file existence
- file hashes
- file size
- image dimensions
- metadata presence or absence
- extended attributes
- before/after state

This allows RIGHTCLICK to report when a provider accepted an operation but the requested result was not actually observed.

---

# What has been demonstrated

## Native capability acquisition

The original proof used an ordinary BBEdit installation.

For the same text fixture:

```text
before BBEdit:
36 capabilities
0 third-party

after BBEdit:
41 capabilities
5 BBEdit capabilities
```

No BBEdit-specific acquisition implementation was added to RIGHTCLICK.

The generic executor then invoked BBEdit's exposed Service with the exact fixture.

[BBEdit proof](docs/BBEDIT-PROOF.md)

---

## Semantic verification

RIGHTCLICK subsequently demonstrated the difference between invocation acceptance and actual outcome.

Real controls included transformations where the requested result was independently observed and a negative control where the provider accepted the operation but the expected state did not change.

The runtime preserved that distinction instead of reporting a false success.

---

## v0.2.0 — environment-derived network capabilities

The public v0.2.0 release added a provider-independent capability reflector/source architecture.

The first network acquisition path uses Bonjour + OpenAPI to:

```text
discover provider
      ↓
acquire supported contract
      ↓
reflect operations
      ↓
bind capability identity
      ↓
expose capability to AI
      ↓
execute through generic runtime
      ↓
remove capability when provider disappears
```

It also introduced `context_runtime`, allowing an AI to prove the exact product version, binary path, SHA-256, PID and transport serving its MCP connection.

The seven-tool contract is acceptance-tested over stdio and authenticated HTTP.

---

## MOAT-001 — structured capabilities

**PASS**

RIGHTCLICK acquired a previously unavailable typed JSON operation from remote software without adding a provider-specific tool.

The runtime:

- discovered the operation
- reflected its argument schema
- accepted generic structured arguments
- validated them before transport
- serialized the request
- executed the remote POST
- validated the returned JSON
- verified the exact returned result

The seven MCP tool names remained unchanged.

[MOAT-001 evidence](evidence/moat-001-structured-openapi-2026-10-06/README.md)

---

## MOAT-002 — durable state + independent read-back

**PASS**

RIGHTCLICK then acquired another previously unavailable capability:

```text
GET /records/{id}
```

using the same generic `arguments` envelope.

RIGHTCLICK:

1. created durable state through a dynamically discovered POST;
2. received the generated record ID;
3. invoked a separately discovered GET capability;
4. independently observed the persisted state;
5. verified that the read-back matched.

The POST's HTTP acceptance was deliberately **not** counted as semantic proof.

The separate read operation established the outcome.

[MOAT-002 evidence](evidence/moat-002-durable-readback-2026-10-06/README.md)

---

## MOAT-003 — generic bearer authority

**PASS**

Current `main` demonstrates a supported operation-level OpenAPI HTTP bearer requirement without adding provider-specific auth logic to the AI-facing interface.

The bearer authority is:

- resolved outside MCP arguments;
- bound to the exact canonical origin;
- stored in macOS Keychain;
- injected only at the HTTP transport boundary.

Removing the authority made the capability unavailable again before provider transport.

[MOAT-003 evidence](evidence/moat-003-generic-bearer-authority-2026-10-06/README.md)

---

# Why this matters

RIGHTCLICK is not trying to become the biggest collection of integrations.

It is exploring whether the integration layer itself can become more generic.

Instead of:

```text
new software
    ↓
build AI integration
    ↓
define tools
    ↓
wire auth
    ↓
deploy
    ↓
configure agent
```

the target architecture is:

```text
new compatible software becomes available
    ↓
RIGHTCLICK discovers its capability contract
    ↓
capabilities enter the graph
    ↓
AI can reason about and use them
```

This does not eliminate every integration problem.

It changes **where integration happens**.

Software can expose a machine-readable capability contract once. RIGHTCLICK can then translate supported parts of that contract into the AI's capability runtime.

---

# RIGHTCLICK is not claiming magic

The project deliberately has narrow truth boundaries.

RIGHTCLICK does **not** currently claim:

- universal compatibility with installed applications;
- access to every macOS right-click menu item;
- arbitrary OpenAPI support;
- arbitrary HTTP authentication;
- arbitrary parameter or schema shapes;
- that provider acceptance proves semantic completion;
- that every capability can be independently verified;
- that unsupported contracts should be guessed.

The current OpenAPI implementation intentionally supports bounded shapes and abstains outside those boundaries.

MOAT-002 GET support, for example, demonstrated exactly one required string path parameter. MOAT-003 demonstrated a specific operation-level HTTP bearer configuration.

Those boundaries are part of the product philosophy.

**Unknown should remain unknown.**

---

# Architecture

```text
                           AI
                            │
                            │ MCP
                            ▼
              ┌─────────────────────────┐
              │       RIGHTCLICK        │
              │                         │
              │  inspect                │
              │  discover               │
              │  explain                │
              │  authorize              │
              │  execute                │
              │  verify                 │
              └────────────┬────────────┘
                           │
                 normalized capability
                       runtime
                           │
          ┌────────────────┼─────────────────┐
          │                │                 │
          ▼                ▼                 ▼
    macOS Services     Sharing         reflector sources
    Action metadata                      │
                                        ▼
                                Bonjour / OpenAPI
                                        │
                              ┌─────────┴─────────┐
                              ▼                   ▼
                         local service       remote service
```

The core capability engine does not need to know which concrete discovery mechanisms are present.

Discovery sources and reflectors feed the same normalized runtime.

---

# Install

The current v0.2 release line installs through Homebrew. This branch prepares **RIGHTCLICK 0.2.1** without rewriting the historical v0.2.0 evidence below.

```bash
brew install rossbuckley1990-hash/tap/rightclick

# Local supported MCP client
rightclick setup

# Persistent ChatGPT bridge
rightclick setup chatgpt --dry-run --json
rightclick setup chatgpt --yes
```

Useful checks:

```bash
rightclick version
rightclick doctor
rightclick providers
rightclick actions "RightClick"
```

For MCP clients, RIGHTCLICK supports stdio and authenticated loopback HTTP.

The current public release targets Apple Silicon and macOS 14 or later.

Acceptance has been performed on newer macOS versions; older supported macOS versions have not all been independently validated.

Do not disable macOS security to run RIGHTCLICK.

---

# The north star

RIGHTCLICK succeeds if installing, exposing or connecting compatible software can make an AI more capable **without writing another AI-specific capability integration for every ability**.

The long-term experience is:

```text
give the AI an environment
        ↓
the environment describes what is possible
        ↓
RIGHTCLICK discovers the useful abilities
        ↓
the AI gains those abilities
        ↓
RIGHTCLICK constrains their use
        ↓
the result is verified where possible
```

Not:

> build a larger pile of MCP servers.

Not:

> automate every right-click menu.

Not:

> give an agent unrestricted access to a computer.

The goal is:

> **Make AI automatically gain reliable, safe abilities from the software and environment already around it.**

---

# Status

RIGHTCLICK is early-stage infrastructure.

The architecture has moved beyond the original native macOS proof into environment-derived network capability acquisition, structured execution, durable read-back and generic bearer authority.

The evidence in this repository is intentionally preserved alongside the implementation so claims can be inspected rather than inferred from marketing language.

See:

- [Security](SECURITY.md)
- [Contributing](CONTRIBUTING.md)
- [MOAT-001](evidence/moat-001-structured-openapi-2026-10-06/README.md)
- [MOAT-002](evidence/moat-002-durable-readback-2026-10-06/README.md)
- [MOAT-003](evidence/moat-003-generic-bearer-authority-2026-10-06/README.md)
- [v0.1 completion evidence](docs/V0.1_COMPLETION_REPORT.md)

Apache-2.0.
