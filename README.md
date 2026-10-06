                              # RIGHTCLICK

## Your agent shouldn't need a new integration every time it gains a new ability.

**RIGHTCLICK lets AI agents discover capabilities from the software and services around them at runtime.**

Install an app.  
A service comes online.  
An API exposes a compatible contract.

**Your agent can discover the new ability without adding another provider-specific AI tool.**

```text
Software / service appears
          ↓
RIGHTCLICK discovers what it can do
          ↓
capability appears
          ↓
AI can inspect it
          ↓
AI can use it
          ↓
RIGHTCLICK verifies what happened
```

**7 generic AI-facing operations. A capability graph that can change underneath them.**

Apple Silicon · macOS 14+ · MCP · Homebrew · Apache-2.0

---

# Try it in 30 seconds

## Install

```bash
brew install rossbuckley1990-hash/tap/rightclick
```

Check that it's alive:

```bash
rightclick version
rightclick doctor
```

Now ask RIGHTCLICK what your machine can do with some text:

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

You are not querying a static list of integrations.

RIGHTCLICK is inspecting the object and asking the **current environment** which capabilities actually apply.

Try:

```bash
rightclick providers
```

That shows the capability providers RIGHTCLICK can currently see.

---

# Give the same abilities to your AI

RIGHTCLICK speaks MCP.

For supported local clients:

```bash
rightclick setup
```

Or select one explicitly.

### Cursor

```bash
rightclick setup --client cursor --dry-run --json
rightclick setup --client cursor --yes
```

### Claude Code

Available on current `main`:

```bash
rightclick setup --client claude --dry-run --json
rightclick setup --client claude --yes
```

RIGHTCLICK uses Claude Code's own native MCP registration rather than editing Claude's configuration behind its back.

### Codex

Available on current `main`:

```bash
rightclick setup --client codex --dry-run --json
rightclick setup --client codex --yes
```

RIGHTCLICK uses Codex's native MCP registration and checks for conflicting registrations before allowing Codex to overwrite anything.

### ChatGPT

RIGHTCLICK also has a persistent ChatGPT bridge path:

```bash
rightclick setup chatgpt --dry-run --json
```

The preview tells you what pairing or credential state is still required without changing anything.

Once the bridge prerequisites exist:

```bash
rightclick setup chatgpt --yes
```

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

Use `which rightclick` if Homebrew lives somewhere else.

RIGHTCLICK also supports authenticated local HTTP for clients that cannot launch a stdio process.

---

# Then ask your agent something simple

```text
What can you do with this text: RightClick?
```

Or:

```text
What can you do with ~/Desktop/photo.jpg?
```

Or:

```text
Find the useful capabilities for this file.
Explain them before doing anything.
```

Or:

```text
Do this, but don't tell me it worked unless you can verify the result.
```

The interesting part is where the answer comes from.

**The agent did not need every possible capability hard-coded into its tool list first.**

---

# Why I built this

I kept running into the same thing with agents.

Every time I wanted to give one a new ability, I seemed to be adding another MCP server, another set of tools, another schema, another authentication path and another thing that would need maintaining.

You end up with something like:

```text
Agent
├── GitHub tools
├── Slack tools
├── Notion tools
├── Drive tools
├── Jira tools
├── database tools
├── browser tools
├── filesystem tools
├── internal API tools
└── ...
```

Then each provider expands:

```text
GitHub
├── create_issue
├── update_issue
├── create_pr
├── review_pr
├── merge_pr
├── get_commit
├── ...
```

The model gets smarter.

**The plumbing gets bigger.**

So I started asking a different question:

> Why does the agent need to know every capability in advance?

Why can't software describe what it can do and let the agent discover those abilities when they are actually available?

That is the experiment behind RIGHTCLICK.

---

# The idea

Instead of:

```text
new software
     ↓
build AI integration
     ↓
define tools
     ↓
define schemas
     ↓
wire authentication
     ↓
configure agent
     ↓
maintain forever
```

RIGHTCLICK is working toward:

```text
new software / service
        ↓
exposes a compatible capability contract
        ↓
RIGHTCLICK discovers it
        ↓
capability enters the graph
        ↓
AI can use it
```

The model-facing interface does not need to grow every time this happens.

> **MCP is the transport. Capability acquisition is the product.**

---

# One small interface

RIGHTCLICK exposes seven generic MCP operations:

| Tool | What it does |
|---|---|
| `context_runtime` | Proves exactly which RIGHTCLICK runtime the AI is talking to |
| `context_inspect` | Understands the current object or context |
| `context_actions` | Discovers capabilities that apply right now |
| `context_explain` | Explains one capability before it is used |
| `context_run` | Executes a discovered capability |
| `context_run_status` | Returns execution and verification evidence |
| `context_providers` | Shows the providers currently contributing capabilities |

The point is what **isn't** required.

RIGHTCLICK does not need permanent top-level tools like:

```text
github_get_user
github_create_issue
github_create_pr

foo_create_record
foo_read_record

bar_transform_image

provider_x_action_y
provider_x_action_z
```

for every capability it reflects.

A capability can be discovered at runtime and executed through the same generic interface.

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

# The capability graph is alive

RIGHTCLICK does not assume that the world is static.

A provider can appear:

```text
provider absent
      ↓
capability absent

provider appears
      ↓
RIGHTCLICK discovers it
      ↓
capability appears
```

And disappear again:

```text
provider disappears
      ↓
capability disappears
```

That behaviour has been demonstrated with real dynamically discovered OpenAPI providers.

The model-facing tool contract did not change.

**Reality changed, so the available abilities changed.**

---

# This started with a surprisingly simple experiment

I wanted to know whether installing normal software could make an AI more capable without writing an integration specifically for that application.

So I tested BBEdit.

Same Mac.

Same RIGHTCLICK.

Same query.

Before BBEdit:

```text
36 capabilities
0 from third-party software
```

After an ordinary BBEdit installation:

```text
41 capabilities
5 BBEdit capabilities
```

I had added **zero BBEdit-specific acquisition code** to RIGHTCLICK.

RIGHTCLICK found capabilities the application already exposed.

The generic executor then used one of them with the exact requested content.

The application appeared.

**The capability graph changed.**

[See the BBEdit proof](docs/BBEDIT-PROOF.md)

---

# Then it escaped the Mac

The more interesting question was whether the same idea could work for network software.

RIGHTCLICK now has a provider-independent capability reflection architecture.

The first network acquisition path uses:

```text
Bonjour
   +
OpenAPI
```

A supported service can appear on the network:

```text
service appears
      ↓
RIGHTCLICK acquires its OpenAPI contract
      ↓
supported operations are reflected
      ↓
AI can discover them
      ↓
AI can execute them
```

And when the service disappears:

```text
capabilities disappear
```

Again:

**no new model-facing tool needs to be added.**

---

# It now works against a real GitHub API capability

This was an important test because fixtures only prove so much.

The MOAT-004 work on current `main` expanded RIGHTCLICK's generic OpenAPI acquisition far enough to reflect a real authenticated GitHub operation.

The live path was:

```text
ChatGPT
   ↓
7 generic RIGHTCLICK tools
   ↓
dynamically reflected capability
   ↓
origin-bound local authority
   ↓
real GitHub API
   ↓
GET https://api.github.com/user
```

The returned GitHub identity matched an independent authenticated control.

There is:

- no GitHub-specific RIGHTCLICK production tool
- no `github_get_user` MCP tool
- no GitHub-specific model-facing interface
- no GitHub-specific execution branch

GitHub was just another capability provider behind the generic runtime.

That is the direction.

[See PR #9 — MOAT-004 integration](https://github.com/rossbuckley1990-hash/rightclick/pull/9)

---

# Structured APIs do not require structured top-level tools

RIGHTCLICK can reflect supported structured JSON operations.

The first structured OpenAPI proof started with two operations:

```text
plain text operation     → RIGHTCLICK understood it

structured JSON operation → RIGHTCLICK could not expose it
```

A generic improvement was made to the runtime.

Same provider.

Same OpenAPI document.

Then this capability appeared:

```text
Create Structured Record
```

RIGHTCLICK:

```text
discovered it
     ↓
reflected its arguments
     ↓
accepted generic structured values
     ↓
validated them
     ↓
serialized the request
     ↓
executed the operation
     ↓
validated the response
     ↓
VERIFIED_SUCCESS
```

No provider-specific tool was created.

[MOAT-001 evidence](evidence/moat-001-structured-openapi-2026-10-06/README.md)

---

# A `201 Created` is not proof that anything was actually created

This became another design principle.

Agents often collapse these into one thing:

```text
HTTP request succeeded
```

and:

```text
the user's requested outcome happened
```

They are not the same.

For the durable-state test, RIGHTCLICK discovered:

```text
POST /records
GET  /records/{id}
```

It created a record.

But the successful POST was **not** treated as proof of durable state.

Instead:

```text
POST accepted
     ↓
record ID returned
     ↓
separate reflected GET capability
     ↓
GET /records/{id}
     ↓
persisted state observed independently
     ↓
VERIFIED_SUCCESS
```

That independent read-back established the result.

[MOAT-002 evidence](evidence/moat-002-durable-readback-2026-10-06/README.md)

---

# Provider success is not user success

RIGHTCLICK keeps execution and verification separate.

An operation can be:

```text
accepted
```

without pretending that it was:

```text
VERIFIED_SUCCESS
```

Where the requested result is observable, RIGHTCLICK can evaluate provider-independent postconditions.

Current verification primitives include things such as:

- exact returned text
- file existence
- file readability
- SHA-256 equality
- SHA-256 change
- file-size thresholds
- image dimensions
- extended-attribute presence or absence
- metadata presence or absence
- before/after observable state

That means RIGHTCLICK can return:

```text
VERIFIED_SUCCESS
```

when the required state is actually observed.

Or:

```text
VERIFIED_FAILURE
```

when a provider accepted the call but the requested result did not occur.

That distinction becomes increasingly important once agents start doing consequential work.

---

# Authentication does not have to become model context

Some discovered capabilities require credentials.

That does not mean the model needs to receive the credential.

RIGHTCLICK's supported bearer-authority path works like this:

```text
AI selects capability
        ↓
capability requires authority
        ↓
RIGHTCLICK identifies exact execution origin
        ↓
credential is resolved locally
        ↓
credential is injected at transport boundary
```

The bearer secret is not supplied through `context_run`.

Live testing demonstrated:

```text
authority absent
→ unavailable before provider transport

authority present
→ capability executes

authority removed
→ unavailable again
```

The authority is bound to the exact execution origin.

Redirects cannot silently carry it somewhere else.

[MOAT-003 evidence](evidence/moat-003-generic-bearer-authority-2026-10-06/README.md)

---

# One capability runtime, multiple AI clients

The runtime should not belong to one model.

That would just recreate the integration problem at another layer.

RIGHTCLICK now has a generic onboarding architecture with thin client adapters.

Current `main` supports:

| Client | RIGHTCLICK integration |
|---|---|
| Cursor | MCP config adapter |
| Claude Code | Native Claude MCP registration |
| Codex | Native Codex MCP registration |
| ChatGPT | Persistent bridge path |
| Other MCP clients | stdio / authenticated HTTP |

The important part is that these clients are **not separate RIGHTCLICK products**.

They connect to the same capability runtime.

```text
ChatGPT ──────┐
Claude Code ──┤
Codex ────────┼──► RIGHTCLICK ───► capability graph
Cursor ───────┤
MCP client ───┘
```

Meanwhile the graph underneath RIGHTCLICK can keep changing.

---

# Claude Code

Current `main` uses Claude Code's native MCP CLI.

RIGHTCLICK does not directly write Claude MCP JSON.

The registration flow is:

```text
claude mcp add --scope user rightclick -- <rightclick> mcp
```

The implementation was tested using a real Claude Code installation.

RIGHTCLICK also checks Claude's own reported connection state instead of treating configuration as proof of connectivity.

[See PR #11](https://github.com/rossbuckley1990-hash/rightclick/pull/11)

---

# Codex

Current `main` also uses Codex's own native MCP registration.

RIGHTCLICK does not edit `config.toml` directly.

The flow uses Codex's native commands:

```text
codex mcp get
codex mcp add
codex mcp list
codex mcp remove
```

One interesting finding during the real-client test was that Codex permits a same-name MCP registration to be overwritten.

RIGHTCLICK therefore inspects the existing registration first and refuses a conflicting mutation before calling Codex.

The Codex adapter was tested against a real Codex CLI installation.

[See PR #12](https://github.com/rossbuckley1990-hash/rightclick/pull/12)

---

# Why not just use MCP servers?

You should.

RIGHTCLICK is an MCP server.

MCP solves:

> **How does an AI communicate with external capabilities?**

RIGHTCLICK is exploring a different question:

> **Where should those capabilities come from?**

Today:

```text
provider exists
      ↓
someone writes MCP server / integration
      ↓
provider-specific tools are exposed
      ↓
agent receives them
```

RIGHTCLICK's direction:

```text
provider exists
      ↓
provider exposes a compatible contract
      ↓
RIGHTCLICK discovers it
      ↓
agent receives the capability
```

MCP can carry both models.

RIGHTCLICK changes the capability-acquisition layer above it.

---

# Why not just build a giant tool registry?

A registry helps an agent search among tools someone has already integrated.

That is useful.

But it is a different problem.

A registry says:

```text
Here are 10,000 tools.

Find the right one.
```

RIGHTCLICK says:

```text
Look at the environment you're actually in.

What can it do right now?
```

These approaches can coexist.

RIGHTCLICK is interested in capabilities that are **derived from the current environment**, not only capabilities that were pre-enrolled into a global catalog.

---

# Why agent developers should care

### Fewer permanent model-facing tools

The generic interface stays small while capabilities can grow behind it.

### Less provider-specific orchestration

Supported contracts are normalized before they reach the model.

### Dynamic environments

Providers can appear and disappear while the agent is running.

### Contextual discovery

The agent can ask what applies to this object or task instead of loading everything everywhere.

### Authority below the model

Credentials do not necessarily have to become model arguments.

### Better execution semantics

"Provider accepted it" and "user's goal happened" remain separate states.

### Model/client independence

The capability runtime is being connected to ChatGPT, Claude Code, Codex, Cursor and generic MCP clients rather than rebuilt around each one.

---

# Why software developers should care

Imagine shipping software and exposing a capability once.

Not:

```text
build OpenAI adapter
build Claude adapter
build Cursor adapter
build Codex adapter
build another agent adapter
build custom MCP wrapper
...
```

But:

```text
your software
      ↓
describes capability
      ↓
RIGHTCLICK reflects supported contract
      ↓
compatible AI clients can discover it
```

That is the longer-term model being tested.

**Expose what your software can do.**

Let the capability runtime deal with the AI boundary.

---

# Why platform teams should care

Every integration tends to independently rebuild some mixture of:

```text
discovery
schema translation
applicability
authentication
authorization
confirmation
execution
result handling
verification
runtime identity
audit evidence
```

RIGHTCLICK treats those as capability-runtime concerns.

That creates a place where the rules for acquiring and executing capabilities can evolve independently of the model using them.

---

# How RIGHTCLICK works

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
                    capability graph
                            │
          ┌─────────────────┼──────────────────┐
          │                 │                  │
          ▼                 ▼                  ▼
    native software    local services     remote services
          │                 │                  │
     macOS Services       future           Bonjour
     Sharing             sources              +
     Action metadata                         OpenAPI
          │                 │                  │
          └─────────────────┼──────────────────┘
                            │
                            ▼
                     real-world abilities
```

The core capability engine is not built around a list of supported brands.

Reflectors translate supported capability substrates into one normalized model.

Capability sources determine which reflectors are present in the current environment.

---

# Current OpenAPI work

The supported OpenAPI surface has been expanding generically rather than through provider special-cases.

Current `main` includes support demonstrated by the regression and live test programmes for things including:

- plain-text operations
- closed structured JSON object requests
- generic structured arguments
- required string path parameters
- zero-argument GET operations
- bounded larger OpenAPI documents
- separate specification and execution origins
- literal OpenAPI server binding
- validated structured JSON responses
- read-only JSON syntax fallback where semantic schema claims are unavailable
- provider appearance and removal
- capability identity changes
- operation-level bearer authority
- externally advertised bearer authority
- exact execution-origin credential binding
- real authenticated GitHub compatibility

Unsupported shapes are not silently converted into capabilities.

The goal is not provider-specific exceptions.

The goal is to keep widening the **generic language of capabilities**.

---

# Safety should mostly be invisible

The product should feel simple:

```text
ask what is possible
      ↓
pick an ability
      ↓
use it
```

But underneath that, RIGHTCLICK tries to be conservative about consequential things.

It can:

- require explicit confirmation
- distinguish support from unsupported execution
- keep credentials outside model-facing arguments
- bind authority to an exact execution origin
- fail closed on conflicting client registrations
- preserve unrelated client configuration
- distinguish configured from connected
- identify the exact runtime binary serving the AI
- retain execution evidence
- verify observable outcomes

The principle is:

> **Discover aggressively. Execute safely. Verify relentlessly.**

---

# CLI

You can use RIGHTCLICK without an AI client.

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

Add:

```bash
--json
```

for machine-readable output where supported.

---

# Test capability discovery yourself

The simplest test is:

```bash
rightclick actions "RightClick"
```

Then:

```bash
rightclick providers
```

Install or expose software that contributes a supported capability.

Run the same query again.

The interesting property to watch is not merely that RIGHTCLICK has lots of tools.

It is whether:

```text
environment changes
        ↓
capability graph changes
```

without changing the AI-facing interface.

---

# Stable release vs current main

The latest published Homebrew release is currently **v0.2.1**:

```bash
brew install rossbuckley1990-hash/tap/rightclick
```

The repository's current `main` is ahead of that release and additionally contains:

- MOAT-004 real GitHub-compatible acquisition work
- the generic multi-client onboarding engine
- native Claude Code onboarding
- native Codex onboarding

To test the newest `main` before it is promoted to Homebrew:

```bash
git clone https://github.com/rossbuckley1990-hash/rightclick.git
cd rightclick

swift test
swift build -c release

.build/release/rightclick version
.build/release/rightclick doctor
```

Then configure a supported local client using that executable, or run:

```bash
.build/release/rightclick mcp
```

directly.

**For a public launch, the intention is to promote the current `main` capability set into the next Homebrew release so `brew install` and this README describe the same product.**

---

# Requirements

Current runtime target:

```text
Apple Silicon
macOS 14+
```

RIGHTCLICK does not require disabling macOS security.

Not every application exposes a capability contract RIGHTCLICK can use today.

Not every OpenAPI shape is currently supported.

That is expected.

The interesting work is expanding the generic capability language without turning RIGHTCLICK into another pile of provider-specific integrations.

---

# Evidence, not screenshots

A lot of RIGHTCLICK development has been done as explicit RED → GREEN capability gates because the core claim is easy to overstate.

The repository preserves evidence for the important milestones:

- [BBEdit — capability acquisition without provider-specific code](docs/BBEDIT-PROOF.md)
- [MOAT-001 — structured OpenAPI capability acquisition](evidence/moat-001-structured-openapi-2026-10-06/README.md)
- [MOAT-002 — durable state + independent read-back](evidence/moat-002-durable-readback-2026-10-06/README.md)
- [MOAT-003 — generic bearer authority](evidence/moat-003-generic-bearer-authority-2026-10-06/README.md)
- [MOAT-004 — real GitHub-compatible acquisition](https://github.com/rossbuckley1990-hash/rightclick/pull/9)
- [Generic onboarding engine](https://github.com/rossbuckley1990-hash/rightclick/pull/10)
- [Claude Code adapter](https://github.com/rossbuckley1990-hash/rightclick/pull/11)
- [Codex adapter](https://github.com/rossbuckley1990-hash/rightclick/pull/12)
- [Security](SECURITY.md)
- [Release process](docs/RELEASE.md)

The latest Codex integration regression passed:

```text
288 tests
25 skipped
0 failures
```

The skipped tests are environment-gated tests rather than hidden failures.

---

# What I want people to challenge

RIGHTCLICK is still early.

If you work on:

- AI agents
- MCP
- tool use
- developer tools
- operating systems
- agent security
- OpenAPI
- local-first software
- AI infrastructure
- capability systems

I would genuinely like you to try to break the idea.

Expose a service RIGHTCLICK cannot understand.

Give it an awkward OpenAPI document.

Install software with unusual capability metadata.

Try the client onboarding.

Find a case where it reflects too much.

Find a case where it reflects too little.

Find somewhere the abstraction stops making sense.

Open an issue.

The interesting question is bigger than this implementation:

> **Should agents keep accumulating predefined tools, or should they be able to discover what their environment can do?**

---

# Start here

Stable release:

```bash
brew install rossbuckley1990-hash/tap/rightclick

rightclick doctor
rightclick actions "RightClick"
rightclick providers
```

Then connect it to your AI and ask:

```text
What can you do here?
```

If that question can eventually replace a meaningful amount of integration plumbing, RIGHTCLICK is onto something.

---

## The north star

An agent enters a new environment.

It does not arrive knowing every tool it will ever need.

Instead:

```text
it observes the environment
        ↓
software describes what is possible
        ↓
RIGHTCLICK discovers supported capabilities
        ↓
the capabilities become available
        ↓
authority is resolved
        ↓
the agent acts
        ↓
the result is verified
```

A new application appears.

**The agent gains an ability.**

A service comes online.

**The agent gains an ability.**

An API exposes a compatible contract.

**The agent gains an ability.**

No rebuild of the agent.

No provider-specific top-level tool required.

No assumption that a successful HTTP call means the job is done.

> ## Software appears. Your AI learns what it can do.

---

Apache-2.0
