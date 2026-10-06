# RIGHTCLICK

## Install software. Your AI learns what it can do.

**RIGHTCLICK lets AI agents discover and use capabilities from the software and services around them — without adding a new AI integration for every new ability.**

```text
Software appears
      ↓
RIGHTCLICK discovers what it can do
      ↓
The capability appears to the AI
      ↓
The AI can use it
```

**Same agent. Same 7 generic tools. New abilities at runtime.**

Apple Silicon · macOS 14+ · Homebrew · MCP · Apache-2.0

---

## See the idea in 20 seconds

This has already happened in live tests:

```text
Provider absent
    ↓
capability does not exist

Provider appears
    ↓
RIGHTCLICK discovers its contract
    ↓
new capability appears

AI invokes it through the same generic context_run
    ↓
RIGHTCLICK executes it

requested result is observed
    ↓
VERIFIED_SUCCESS

Provider disappears
    ↓
capability disappears
```

RIGHTCLICK did not add a new MCP tool.

The AI was not reprogrammed for that provider.

**The environment changed, so the AI became more capable.**

That is RIGHTCLICK.

---

# Try it now

## 1. Install

```bash
brew install rossbuckley1990-hash/tap/rightclick
```

Check it:

```bash
rightclick version
rightclick doctor
```

## 2. Ask RIGHTCLICK what your Mac can already do

Try text:

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

RIGHTCLICK inspects the item and returns the capabilities that apply **in your environment, right now**.

Not a static list.

Not every tool installed everywhere.

The actions that actually apply here.

## 3. Give those abilities to your AI

For the supported local MCP setup:

```bash
rightclick setup
```

Or explicitly configure Cursor:

```bash
rightclick setup --client cursor --yes
```

Then ask your agent:

```text
What can my Mac do with this text: RightClick?
```

Or:

```text
What can you do with ~/Desktop/example.jpg?
Explain the safest useful options before doing anything.
```

That is the basic experience.

**Install RIGHTCLICK → ask what is possible → use it.**

---

# Why this exists

Agents are getting dramatically smarter.

Their integration model is not.

Today, making an agent useful often means doing this:

```text
Agent
├── GitHub MCP
│   ├── create_issue
│   ├── update_issue
│   ├── create_pr
│   ├── review_pr
│   └── ...
│
├── Slack MCP
│   ├── send_message
│   ├── search_messages
│   ├── add_reaction
│   └── ...
│
├── Notion MCP
│   ├── create_page
│   ├── update_page
│   └── ...
│
├── Drive MCP
├── Jira MCP
├── database tools
├── filesystem tools
├── internal APIs
└── ...
```

Every system brings another integration lifecycle:

```text
discover API
    ↓
write integration
    ↓
define tools
    ↓
define schemas
    ↓
configure credentials
    ↓
attach tools to agent
    ↓
teach model when to use them
    ↓
maintain integration
    ↓
repeat
```

And every new tool can increase:

- context consumption
- tool-selection ambiguity
- configuration
- credential surface
- maintenance
- failure modes
- integration code
- agent complexity

The model gets smarter.

**The plumbing gets bigger.**

---

# RIGHTCLICK changes the abstraction

Instead of teaching the AI about every provider:

```text
AI
├── integration
├── integration
├── integration
├── integration
├── integration
└── integration
```

RIGHTCLICK puts a capability runtime between the AI and its environment:

```text
                         AI
                          │
                          │
                  7 generic tools
                          │
                          ▼
                 ┌────────────────┐
                 │   RIGHTCLICK   │
                 └───────┬────────┘
                         │
                 capability graph
                         │
       ┌─────────────────┼─────────────────┐
       │                 │                 │
       ▼                 ▼                 ▼
     Apps            Services            APIs
       │                 │                 │
       └──────── capability contracts ─────┘
```

Software exposes what it can do.

RIGHTCLICK reflects supported capabilities.

The AI discovers them when needed.

> **MCP is the transport. Capability acquisition is the product.**

---

# Why that matters

| Traditional agent integration | RIGHTCLICK |
|---|---|
| Add another provider integration | Discover supported capabilities from the environment |
| Add more model-facing tools | Keep a small generic runtime |
| Tool catalog is mostly static | Capability graph can change at runtime |
| Agent needs provider-specific surface | Capability is normalized before reaching the AI |
| Credentials often become integration plumbing | Authority can stay at the execution boundary |
| HTTP/API success can look like task success | RIGHTCLICK can separately verify outcomes |
| Provider disappears but integration remains | Reflected capability can disappear with it |
| Build the AI around its integrations | Let the environment describe what the AI can do |

RIGHTCLICK is not trying to win by having the biggest integration catalog.

**It is trying to make the integration catalog less necessary.**

---

# One small interface. A changing world behind it.

RIGHTCLICK exposes seven generic MCP tools:

| Tool | Purpose |
|---|---|
| `context_runtime` | Prove exactly which RIGHTCLICK process the AI is talking to |
| `context_inspect` | Understand the current object or context |
| `context_actions` | Discover what can be done right now |
| `context_explain` | Understand a capability before using it |
| `context_run` | Execute a discovered capability |
| `context_run_status` | Inspect execution and verification evidence |
| `context_providers` | See which capability providers currently exist |

The key idea is what **isn't** here.

There is no requirement for:

```text
github_create_issue
github_update_issue
github_create_pr
slack_send_message
slack_search
record_create
record_read
image_optimizer_x
provider_y_action_z
...
```

to become permanent top-level RIGHTCLICK tools.

A capability can instead be discovered and described at runtime.

For example:

```json
{
  "item": "Create a high-priority record",
  "actionId": "Create Structured Record",
  "arguments": {
    "title": "RIGHTCLICK live",
    "priority": "high"
  },
  "confirmed": true
}
```

Same `context_run`.

Different capability.

---

# Capabilities are live

RIGHTCLICK does not assume the environment is static.

```text
10:00
provider unavailable
→ capability absent

10:01
provider appears
→ capability discovered

10:02
AI can use it

10:10
provider disappears
→ capability removed
```

This has been demonstrated with remote OpenAPI providers.

No model-facing tool was added or removed.

**RIGHTCLICK changed its capability graph because reality changed.**

---

# This isn't theoretical

## Proof 1 — install an ordinary app, gain abilities

The original experiment used BBEdit.

Same Mac.

Same RIGHTCLICK.

Same text query.

Before BBEdit:

```text
36 capabilities
0 from third-party software
```

After ordinary BBEdit installation:

```text
41 capabilities
5 BBEdit capabilities
```

No BBEdit-specific capability acquisition code was added to RIGHTCLICK.

The generic executor then invoked BBEdit's exposed Service with the exact requested content.

**The application arrived. The capability graph changed.**

[See the BBEdit proof](docs/BBEDIT-PROOF.md)

---

## Proof 2 — discover a remote ability RIGHTCLICK did not previously understand

A remote service exposed two operations.

The old RIGHTCLICK runtime understood the plain-text operation.

It could not expose the structured JSON operation.

A generic improvement was made to RIGHTCLICK's capability reflection.

Same provider.

Same OpenAPI contract.

Now this appeared:

```text
Create Structured Record
```

RIGHTCLICK then:

```text
discovered operation
        ↓
reflected its argument contract
        ↓
AI supplied generic arguments
        ↓
RIGHTCLICK validated them
        ↓
serialized the request
        ↓
executed the remote operation
        ↓
validated the result
        ↓
VERIFIED_SUCCESS
```

No provider-specific MCP tool was created.

[MOAT-001 evidence](evidence/moat-001-structured-openapi-2026-10-06/README.md)

---

## Proof 3 — create state, then independently prove it exists

Returning `201 Created` is not enough.

So RIGHTCLICK went further.

A provider exposed:

```text
POST /records

GET /records/{id}
```

RIGHTCLICK dynamically discovered both supported capabilities.

It created a remote record.

But it did **not** treat the POST response as proof that persistent state existed.

Instead:

```text
Create record
     ↓
receive ID
     ↓
discover Read Durable Record
     ↓
GET /records/{id}
     ↓
observe persisted state independently
     ↓
VERIFIED_SUCCESS
```

The read capability itself had previously been unavailable to RIGHTCLICK.

It was acquired generically.

[MOAT-002 evidence](evidence/moat-002-durable-readback-2026-10-06/README.md)

---

## Proof 4 — capabilities can require authority without giving secrets to the model

Some capabilities require credentials.

That does not mean the credential should be put into model arguments.

RIGHTCLICK can keep authority at the execution boundary.

For the supported HTTP bearer flow:

```text
AI selects capability
        ↓
RIGHTCLICK sees authority requirement
        ↓
exact provider origin is identified
        ↓
credential resolved from macOS Keychain
        ↓
credential injected at HTTP boundary
```

Observed live behaviour:

```text
No authority
→ unavailable before provider request

Authority exists
→ capability executes

Authority removed
→ unavailable again
```

The bearer secret was not supplied through MCP.

[MOAT-003 evidence](evidence/moat-003-generic-bearer-authority-2026-10-06/README.md)

---

# A tool call succeeding does not mean the task succeeded

This matters once agents do real work.

These are not the same:

```text
API accepted request
```

```text
Provider returned success
```

```text
The thing the user asked for actually happened
```

RIGHTCLICK keeps that distinction explicit.

It can evaluate provider-independent postconditions after execution.

Current verification primitives include things like:

- exact returned text
- file existence
- file readability
- SHA-256 equality or change
- file-size thresholds
- image dimensions
- extended-attribute presence or absence
- metadata presence or absence
- before/after observable state

So an execution can be:

```text
accepted
```

without pretending it was:

```text
VERIFIED_SUCCESS
```

And if the requested state can be observed and is wrong:

```text
VERIFIED_FAILURE
```

That is important infrastructure for agents that are expected to act reliably.

---

# What can RIGHTCLICK discover today?

RIGHTCLICK's current capability sources include supported slices of:

### Native macOS software

- macOS Services
- Sharing Services
- Finder Action extension metadata

This lets compatible installed software contribute abilities without a RIGHTCLICK integration written specifically for that app.

### Network services

RIGHTCLICK can discover supported providers advertised through:

```text
Bonjour
   +
OpenAPI
```

Supported operations are reflected into the same capability runtime used for local software.

That work currently includes demonstrated support for:

- plain-text operations
- supported structured JSON object operations
- supported GET path parameters
- provider appearance and removal
- capability identity changes
- generic structured arguments
- origin-bound HTTP bearer authority
- validated provider responses
- outcome verification

RIGHTCLICK deliberately expands these supported shapes generically rather than adding special cases for individual providers.

---

# Use RIGHTCLICK your way

## CLI

You can use RIGHTCLICK without an AI at all.

```bash
rightclick doctor
rightclick inspect <item>
rightclick actions <item>
rightclick explain <action-id> <item>
rightclick run <action-id> <item>
rightclick status <execution-id>
rightclick providers
rightclick version
```

Machine-readable output is available with:

```bash
--json
```

---

## Cursor

Setup can safely add RIGHTCLICK to Cursor's MCP configuration:

```bash
rightclick setup
```

Or explicitly:

```bash
rightclick setup --client cursor --yes
```

Preview first without changing anything:

```bash
rightclick setup --client cursor --dry-run --json
```

RIGHTCLICK preserves unrelated configuration and refuses to silently replace a conflicting RIGHTCLICK entry.

Then ask Cursor:

```text
What can my Mac do with this?
```

---

## ChatGPT

RIGHTCLICK also has a persistent ChatGPT bridge path.

Preview the current state first:

```bash
rightclick setup chatgpt --dry-run --json
```

When the required pairing and credential state exists:

```bash
rightclick setup chatgpt --yes
```

The setup path checks the persistent executable, binary identity, tunnel configuration and bridge state rather than silently pointing ChatGPT at an arbitrary development binary.

If something is missing, setup reports the required state instead of partially pretending the connection is ready.

---

## Any MCP client over stdio

RIGHTCLICK can run directly as an MCP server:

```bash
rightclick mcp
```

The equivalent configuration is:

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

If your Homebrew prefix is different, use:

```bash
which rightclick
```

for the command path.

---

## Authenticated local HTTP

RIGHTCLICK also supports authenticated MCP over loopback HTTP:

```bash
rightclick serve --port 8765
```

This gives clients that cannot spawn a stdio process another way to connect to the same capability engine.

---

# Give your AI these prompts

After connecting RIGHTCLICK, try:

### Discover

```text
What can my Mac do with this text: RightClick?
```

### Files

```text
What can you do with ~/Desktop/photo.jpg?
```

### Explain before acting

```text
Find the useful capabilities for this file.
Explain the safest three and don't execute anything yet.
```

### Act

```text
Use the best available capability to do this.
```

### Require verification

```text
Do this, but don't tell me it succeeded unless you can verify the requested result.
```

### Inspect the environment

```text
What capability providers can you see right now?
```

That last question is especially important.

The answer is not hard-coded into the agent.

It comes from **your environment**.

---

# Why not just use MCP servers?

Use them.

RIGHTCLICK itself speaks MCP.

MCP solves an enormously important problem:

> **How does an AI communicate with external tools and systems?**

RIGHTCLICK is attacking a different layer:

> **Where do those capabilities come from, and does every new ability need another AI-specific tool integration?**

Today:

```text
software
    ↓
someone builds MCP integration
    ↓
tools are attached to model
    ↓
AI gets capability
```

RIGHTCLICK's direction:

```text
software
    ↓
software exposes compatible capability contract
    ↓
RIGHTCLICK discovers it
    ↓
AI gets capability
```

MCP can carry both.

RIGHTCLICK changes the layer above it.

---

# Why not just search a giant tool registry?

Tool search helps an AI choose from a large set of tools.

RIGHTCLICK asks whether all of those abilities needed to become pre-built AI tools in the first place.

A registry says:

```text
Here are 10,000 tools somebody integrated.
Find one.
```

RIGHTCLICK says:

```text
Look at the environment you're actually in.
What can it do right now?
```

Those approaches can coexist.

They solve different problems.

---

# Why agent builders should care

### Smaller stable AI interface

RIGHTCLICK keeps its top-level MCP surface deliberately small.

### Contextual capability discovery

The AI asks what applies to the object or task instead of carrying every possible provider operation everywhere.

### Dynamic environments

Capabilities can appear and disappear while the agent is running.

### Less provider-specific agent code

The runtime reflects supported capability contracts generically.

### Better trust boundaries

Authority, confirmation and execution policy can sit below the model.

### Better outcome semantics

Provider acceptance is not silently converted into “task complete.”

---

# Why software developers should care

Imagine shipping an application or service and not having to build:

```text
OpenAI integration
Claude integration
Cursor integration
agent framework integration
custom MCP wrapper
another AI adapter
...
```

for every capability you expose.

The longer-term model is:

```text
Your software exposes what it can do
            ↓
RIGHTCLICK discovers it
            ↓
compatible agents can use it
```

**Expose the capability once.**

Let the runtime handle the AI boundary.

That is the direction RIGHTCLICK is testing.

---

# Why platform teams should care

The capability layer is also a natural place to centralize things that become messy when every integration implements them separately:

```text
discovery
applicability
schemas
authority
confirmation
execution
verification
runtime identity
evidence
```

RIGHTCLICK already separates those concerns.

The result is a model where **capability acquisition** and **safe capability use** can evolve independently of the model.

---

# Architecture

```text
                              AI
                               │
                               │ MCP
                               ▼
                  ┌────────────────────────┐
                  │       RIGHTCLICK       │
                  │                        │
                  │ inspect                │
                  │ discover               │
                  │ explain                │
                  │ authorize              │
                  │ confirm                │
                  │ execute                │
                  │ verify                 │
                  └───────────┬────────────┘
                              │
                    normalized capability
                           graph
                              │
            ┌─────────────────┼─────────────────┐
            │                 │                 │
            ▼                 ▼                 ▼
       macOS software    local services    remote services
            │                 │                 │
       Services          capability        Bonjour
       Sharing           sources              +
       Actions                                OpenAPI
            │                 │                 │
            └─────────────────┼─────────────────┘
                              │
                              ▼
                     real-world abilities
```

RIGHTCLICK's core capability engine is not built around a list of specific applications.

Reflectors translate supported substrates into a normalized capability model.

Sources can change the available reflectors as the environment changes.

---

# The important safety property

RIGHTCLICK should feel like magic.

But the magic should come from **discovery**, not from guessing.

When RIGHTCLICK understands a supported capability contract, the experience should be effortless.

When it does not, it should not fabricate one.

When an action needs confirmation, it can require it.

When a capability needs authority, credentials can remain outside model arguments.

When an operation is accepted, RIGHTCLICK does not automatically pretend the requested outcome occurred.

The engineering principle is:

> **Discover aggressively. Execute safely. Verify relentlessly.**

---

# Current scope

RIGHTCLICK is early infrastructure.

Today it targets:

```text
Apple Silicon
macOS 14+
```

It does not currently claim that every installed application exposes a usable capability contract.

It does not claim arbitrary OpenAPI compatibility or every possible authentication scheme.

Those aren't permanent philosophical limits.

They are the **currently implemented capability shapes**.

The direction is to keep widening those shapes generically.

---

# The north star

The future RIGHTCLICK is working toward looks like this:

```text
An AI enters a new environment
           ↓
it does not arrive with every integration prewired
           ↓
RIGHTCLICK discovers what exists
           ↓
software describes what it can do
           ↓
useful capabilities appear
           ↓
authority is resolved
           ↓
the AI acts
           ↓
the result is verified
```

A new application is installed.

**The AI becomes more capable.**

A service comes online.

**The AI becomes more capable.**

A machine exposes a new capability.

**The AI becomes more capable.**

The agent should not need to be rebuilt every time the world around it changes.

> ## Make AI automatically gain reliable, safe abilities from the software and environment already around it.

---

# Evidence, not vibes

The project keeps evidence for the claims above in the repository:

- [BBEdit — capability acquisition without provider-specific code](docs/BBEDIT-PROOF.md)
- [MOAT-001 — structured OpenAPI capability acquisition](evidence/moat-001-structured-openapi-2026-10-06/README.md)
- [MOAT-002 — durable state + independent read-back](evidence/moat-002-durable-readback-2026-10-06/README.md)
- [MOAT-003 — generic bearer authority](evidence/moat-003-generic-bearer-authority-2026-10-06/README.md)
- [Security](SECURITY.md)
- [Release process](docs/RELEASE.md)
- [Contributing](CONTRIBUTING.md)

The test and evidence lineage is intentionally kept alongside the implementation.

---

# Build from source

```bash
git clone git@github.com:rossbuckley1990-hash/rightclick.git
cd rightclick

swift test
scripts/build-cli.sh
.build/release/rightclick version
.build/release/rightclick doctor
```

---

# Help build the capability layer for agents

If you work on:

- AI agents
- MCP
- tool runtimes
- operating systems
- developer tools
- agent security
- capability discovery
- application integrations
- OpenAPI
- agent infrastructure

this is the problem RIGHTCLICK is exploring.

Try it.

Break it.

Expose a capability it cannot understand yet.

Open an issue.

Build another reflector.

Improve the verification layer.

---

## If this future makes sense to you

**Install RIGHTCLICK and see what your own machine can teach your AI.**

```bash
brew install rossbuckley1990-hash/tap/rightclick
rightclick actions "RightClick"
```

And if you think agents should **discover abilities instead of accumulating integrations**, star the repo and share what you make with it.

---

Apache-2.0
