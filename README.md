
Loading older messages…
give me the Best updated readme that people from Hacker news will love and understand straight away and be able to install it and use it and test it straight away

Worked for 42s
you write it as human as possible: The pain that made you build it.
You kept seeing agents accumulate MCP servers and provider-specific tools. Every new ability meant another integration, schema, auth path and maintenance surface.

The question you asked.
Why should the agent have to know every capability in advance? Why can't software describe what it can do and let the agent discover that at runtime?
What RIGHTCLICK does.
It keeps seven generic AI-facing operations while discovering capabilities from supported native software and OpenAPI services.
The surprising proof.
Installing BBEdit changed the capability graph with zero BBEdit-specific acquisition code. Then a remote provider could appear/disappear and its capability appeared/disappeared. Now RIGHTCLICK has also dynamically reflected a real GitHub API capability without GitHub-specific production code.
The client-agnostic part.
The same capability runtime is being wired into ChatGPT, Claude Code, Codex and Cursor, rather than rebuilding the product around each model.
The reliability difference.
RIGHTCLICK separates “the provider accepted my call” from “the requested outcome actually happened,” and can independently verify outcomes.
How to try it.
One Homebrew command, one setup command, then ask the AI what it can do.
Invite the technical attack.
Ask people to try it, expose things it cannot understand, challenge the abstraction, and tell you where it breaks.
…
I’d make it sound like a developer explaining something they built because an existing pattern started bothering them—not like a launch announcement. Something like this:

I built RIGHTCLICK because I kept running into the same thing with agents: every time I wanted to give one a new ability, I seemed to be adding another MCP server, another set of tools, another schema, another auth flow, and another thing that would need maintaining.

That started to feel backwards.

The models are getting better at reasoning about what to do, but we still tell them almost everything they are capable of doing up front.

So I started wondering: why does an agent need to know every capability in advance? Why can't the software around it describe what it can do, and let the agent discover those abilities when they're actually available?

That's what RIGHTCLICK is trying to do.

It exposes a small set of seven generic operations to the AI: inspect something, discover what actions apply, explain one, run it, check the result, inspect providers, and identify the runtime.

Behind that small interface, the capability graph can change.

The first experiment was almost stupidly simple. I installed BBEdit on a Mac and ran the exact same query before and after.

Before: 36 capabilities, none from third-party software.

After installing BBEdit: 41 capabilities, including five from BBEdit.

I hadn't added any BBEdit-specific acquisition code to RIGHTCLICK. The software appeared, RIGHTCLICK discovered what it exposed, and the AI gained those abilities.

That was the point where I thought there might actually be something here.

I've since pushed the same idea beyond native Mac software.

RIGHTCLICK can discover supported OpenAPI services, reflect their operations into the same capability layer, and remove them again when the provider disappears.

One of the latest tests went against the real GitHub API. RIGHTCLICK dynamically acquired an authenticated GitHub capability and ChatGPT invoked it through the same generic RIGHTCLICK tools. There is no GitHub-specific production tool in RIGHTCLICK for that operation.

Authentication is also kept out of the model-facing arguments where possible. In the bearer-auth path, the credential is resolved at the execution boundary and bound to the provider origin.

Another thing that bothered me with agents was how often "the API returned success" gets turned into "the task succeeded".

RIGHTCLICK deliberately separates those.

An invocation can be accepted without being considered verified. Where there is an observable postcondition, RIGHTCLICK can check what actually happened and report VERIFIED_SUCCESS or VERIFIED_FAILURE rather than assuming the provider response means the user's goal was achieved.

I've also been working on making the client side boring. The capability runtime shouldn't belong to one model or one app.

The current code has onboarding paths for Cursor, Claude Code and Codex, plus the ChatGPT bridge, all pointing at the same RIGHTCLICK capability runtime rather than having separate implementations of the product for each AI.

The idea I'm testing is basically:

software appears
→ RIGHTCLICK discovers what it can do
→ the capability becomes available to the agent
→ the agent uses it through the same small interface

You can try the current release with:

brew install rossbuckley1990-hash/tap/rightclick
rightclick actions "RightClick"
Then connect it to a supported AI client and ask something like:

What can my Mac do with this text: RightClick?
It's Apple Silicon/macOS 14+ at the moment and it's still early. I definitely don't think I've solved arbitrary software capability discovery, and there are plenty of OpenAPI shapes and other capability surfaces it doesn't understand yet.

That's actually one of the reasons I'm posting it here.

I'd really like people who work on agents, MCP, tool use, developer infrastructure, security or APIs to try to break the abstraction.

Give it software it doesn't understand. Point it at awkward APIs. Tell me where this model falls apart.

The thing I'm most interested in is whether this direction makes sense at all:

Should agents keep accumulating more and more predefined tools, or should they be able to discover what their environment can do?

That is the tone I’d use. It doesn't tell HN that RIGHTCLICK is revolutionary; it shows them the weird thing it does, explains why you built it, gives them enough technical detail to challenge it, and finishes on a question people will genuinely want to debate.

One important point: I would only post this after the Homebrew release contains the current main features. Otherwise the Claude/Codex/GitHub claims and the version somebody installs won't line up.

give me the Best updated readme that people from Hacker news will love and understand straight away and be able to install it and use it and test it straight away

Worked for 58s
This is the version I’d use as the launch-grade README. It gets to the point faster, gives HN readers something they can actually run almost immediately, then earns the bigger claim with real proofs.

RIGHTCLICK
Your agent shouldn't need a new integration every time it gains a new ability.
RIGHTCLICK lets AI agents discover capabilities from the software and services around them at runtime.

Install an app.
A service comes online.
An API exposes a compatible contract.

Your agent can discover the new ability without adding another provider-specific AI tool.

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
7 generic AI-facing operations. A capability graph that can change underneath them.

Apple Silicon · macOS 14+ · MCP · Homebrew · Apache-2.0

Try it in 30 seconds
Install
brew install rossbuckley1990-hash/tap/rightclick
Check that it's alive:

rightclick version
rightclick doctor
Now ask RIGHTCLICK what your machine can do with some text:

rightclick actions "RightClick"
Try a file:

rightclick actions ~/Desktop/example.jpg
Try a URL:

rightclick actions "https://example.com"
You are not querying a static list of integrations.

RIGHTCLICK is inspecting the object and asking the current environment which capabilities actually apply.

Try:

rightclick providers
That shows the capability providers RIGHTCLICK can currently see.

Give the same abilities to your AI
RIGHTCLICK speaks MCP.

For supported local clients:

rightclick setup
Or select one explicitly.

Cursor
rightclick setup --client cursor --dry-run --json
rightclick setup --client cursor --yes
Claude Code
Available on current main:

rightclick setup --client claude --dry-run --json
rightclick setup --client claude --yes
RIGHTCLICK uses Claude Code's own native MCP registration rather than editing Claude's configuration behind its back.

Codex
Available on current main:

rightclick setup --client codex --dry-run --json
rightclick setup --client codex --yes
RIGHTCLICK uses Codex's native MCP registration and checks for conflicting registrations before allowing Codex to overwrite anything.

ChatGPT
RIGHTCLICK also has a persistent ChatGPT bridge path:

rightclick setup chatgpt --dry-run --json
The preview tells you what pairing or credential state is still required without changing anything.

Once the bridge prerequisites exist:

rightclick setup chatgpt --yes
Any MCP client
Run RIGHTCLICK directly over stdio:

rightclick mcp
Equivalent MCP configuration:

{
  "mcpServers": {
    "rightclick": {
      "command": "/opt/homebrew/bin/rightclick",
      "args": ["mcp"]
    }
  }
}
Use which rightclick if Homebrew lives somewhere else.

RIGHTCLICK also supports authenticated local HTTP for clients that cannot launch a stdio process.

Then ask your agent something simple
What can you do with this text: RightClick?
Or:

What can you do with ~/Desktop/photo.jpg?
Or:

Find the useful capabilities for this file.
Explain them before doing anything.
Or:

Do this, but don't tell me it worked unless you can verify the result.
The interesting part is where the answer comes from.

The agent did not need every possible capability hard-coded into its tool list first.

Why I built this
I kept running into the same thing with agents.

Every time I wanted to give one a new ability, I seemed to be adding another MCP server, another set of tools, another schema, another authentication path and another thing that would need maintaining.

You end up with something like:

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
Then each provider expands:

GitHub
├── create_issue
├── update_issue
├── create_pr
├── review_pr
├── merge_pr
├── get_commit
├── ...
The model gets smarter.

The plumbing gets bigger.

So I started asking a different question:

Why does the agent need to know every capability in advance?

Why can't software describe what it can do and let the agent discover those abilities when they are actually available?

That is the experiment behind RIGHTCLICK.

The idea
Instead of:

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
RIGHTCLICK is working toward:

new software / service
        ↓
exposes a compatible capability contract
        ↓
RIGHTCLICK discovers it
        ↓
capability enters the graph
        ↓
AI can use it
The model-facing interface does not need to grow every time this happens.

MCP is the transport. Capability acquisition is the product.

One small interface
RIGHTCLICK exposes seven generic MCP operations:

Tool	What it does
context_runtime	Proves exactly which RIGHTCLICK runtime the AI is talking to
context_inspect	Understands the current object or context
context_actions	Discovers capabilities that apply right now
context_explain	Explains one capability before it is used
context_run	Executes a discovered capability
context_run_status	Returns execution and verification evidence
context_providers	Shows the providers currently contributing capabilities
The point is what isn't required.

RIGHTCLICK does not need permanent top-level tools like:

github_get_user
github_create_issue
github_create_pr

foo_create_record
foo_read_record

bar_transform_image

provider_x_action_y
provider_x_action_z
for every capability it reflects.

A capability can be discovered at runtime and executed through the same generic interface.

For example:

{
  "item": "Create a high-priority record",
  "actionId": "Create Structured Record",
  "arguments": {
    "title": "RIGHTCLICK live",
    "priority": "high"
  },
  "confirmed": true
}
Same context_run.

Different capability.

The capability graph is alive
RIGHTCLICK does not assume that the world is static.

A provider can appear:

provider absent
      ↓
capability absent

provider appears
      ↓
RIGHTCLICK discovers it
      ↓
capability appears
And disappear again:

provider disappears
      ↓
capability disappears
That behaviour has been demonstrated with real dynamically discovered OpenAPI providers.

The model-facing tool contract did not change.

Reality changed, so the available abilities changed.

This started with a surprisingly simple experiment
I wanted to know whether installing normal software could make an AI more capable without writing an integration specifically for that application.

So I tested BBEdit.

Same Mac.

Same RIGHTCLICK.

Same query.

Before BBEdit:

36 capabilities
0 from third-party software
After an ordinary BBEdit installation:

41 capabilities
5 BBEdit capabilities
I had added zero BBEdit-specific acquisition code to RIGHTCLICK.

RIGHTCLICK found capabilities the application already exposed.

The generic executor then used one of them with the exact requested content.

The application appeared.

The capability graph changed.

See the BBEdit proof

Then it escaped the Mac
The more interesting question was whether the same idea could work for network software.

RIGHTCLICK now has a provider-independent capability reflection architecture.

The first network acquisition path uses:

Bonjour
   +
OpenAPI
A supported service can appear on the network:

service appears
      ↓
RIGHTCLICK acquires its OpenAPI contract
      ↓
supported operations are reflected
      ↓
AI can discover them
      ↓
AI can execute them
And when the service disappears:

capabilities disappear
Again:

no new model-facing tool needs to be added.

It now works against a real GitHub API capability
This was an important test because fixtures only prove so much.

The MOAT-004 work on current main expanded RIGHTCLICK's generic OpenAPI acquisition far enough to reflect a real authenticated GitHub operation.

The live path was:

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
The returned GitHub identity matched an independent authenticated control.

There is:

no GitHub-specific RIGHTCLICK production tool

no github_get_user MCP tool

no GitHub-specific model-facing interface

no GitHub-specific execution branch

GitHub was just another capability provider behind the generic runtime.

That is the direction.

See PR #9 — MOAT-004 integration

Structured APIs do not require structured top-level tools
RIGHTCLICK can reflect supported structured JSON operations.

The first structured OpenAPI proof started with two operations:

plain text operation     → RIGHTCLICK understood it

structured JSON operation → RIGHTCLICK could not expose it
A generic improvement was made to the runtime.

Same provider.

Same OpenAPI document.

Then this capability appeared:

Create Structured Record
RIGHTCLICK:

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
No provider-specific tool was created.

MOAT-001 evidence

A 201 Created is not proof that anything was actually created
This became another design principle.

Agents often collapse these into one thing:

HTTP request succeeded
and:

the user's requested outcome happened
They are not the same.

For the durable-state test, RIGHTCLICK discovered:

POST /records
GET  /records/{id}
It created a record.

But the successful POST was not treated as proof of durable state.

Instead:

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
That independent read-back established the result.

MOAT-002 evidence

Provider success is not user success
RIGHTCLICK keeps execution and verification separate.

An operation can be:

accepted
without pretending that it was:

VERIFIED_SUCCESS
Where the requested result is observable, RIGHTCLICK can evaluate provider-independent postconditions.

Current verification primitives include things such as:

exact returned text

file existence

file readability

SHA-256 equality

SHA-256 change

file-size thresholds

image dimensions

extended-attribute presence or absence

metadata presence or absence

before/after observable state

That means RIGHTCLICK can return:

VERIFIED_SUCCESS
when the required state is actually observed.

Or:

VERIFIED_FAILURE
when a provider accepted the call but the requested result did not occur.

That distinction becomes increasingly important once agents start doing consequential work.

Authentication does not have to become model context
Some discovered capabilities require credentials.

That does not mean the model needs to receive the credential.

RIGHTCLICK's supported bearer-authority path works like this:

AI selects capability
        ↓
capability requires authority
        ↓
RIGHTCLICK identifies exact execution origin
        ↓
credential is resolved locally
        ↓
credential is injected at transport boundary
The bearer secret is not supplied through context_run.

Live testing demonstrated:

authority absent
→ unavailable before provider transport

authority present
→ capability executes

authority removed
→ unavailable again
The authority is bound to the exact execution origin.

Redirects cannot silently carry it somewhere else.

MOAT-003 evidence

One capability runtime, multiple AI clients
The runtime should not belong to one model.

That would just recreate the integration problem at another layer.

RIGHTCLICK now has a generic onboarding architecture with thin client adapters.

Current main supports:

Client	RIGHTCLICK integration
Cursor	MCP config adapter
Claude Code	Native Claude MCP registration
Codex	Native Codex MCP registration
ChatGPT	Persistent bridge path
Other MCP clients	stdio / authenticated HTTP
The important part is that these clients are not separate RIGHTCLICK products.

They connect to the same capability runtime.

ChatGPT ──────┐
Claude Code ──┤
Codex ────────┼──► RIGHTCLICK ───► capability graph
Cursor ───────┤
MCP client ───┘
Meanwhile the graph underneath RIGHTCLICK can keep changing.

Claude Code
Current main uses Claude Code's native MCP CLI.

RIGHTCLICK does not directly write Claude MCP JSON.

The registration flow is:

claude mcp add --scope user rightclick -- <rightclick> mcp
The implementation was tested using a real Claude Code installation.

RIGHTCLICK also checks Claude's own reported connection state instead of treating configuration as proof of connectivity.

See PR #11

Codex
Current main also uses Codex's own native MCP registration.

RIGHTCLICK does not edit config.toml directly.

The flow uses Codex's native commands:

codex mcp get
codex mcp add
codex mcp list
codex mcp remove
One interesting finding during the real-client test was that Codex permits a same-name MCP registration to be overwritten.

RIGHTCLICK therefore inspects the existing registration first and refuses a conflicting mutation before calling Codex.

The Codex adapter was tested against a real Codex CLI installation.

See PR #12

Why not just use MCP servers?
You should.

RIGHTCLICK is an MCP server.

MCP solves:

How does an AI communicate with external capabilities?

RIGHTCLICK is exploring a different question:

Where should those capabilities come from?

Today:

provider exists
      ↓
someone writes MCP server / integration
      ↓
provider-specific tools are exposed
      ↓
agent receives them
RIGHTCLICK's direction:

provider exists
      ↓
provider exposes a compatible contract
      ↓
RIGHTCLICK discovers it
      ↓
agent receives the capability
MCP can carry both models.

RIGHTCLICK changes the capability-acquisition layer above it.

Why not just build a giant tool registry?
A registry helps an agent search among tools someone has already integrated.

That is useful.

But it is a different problem.

A registry says:

Here are 10,000 tools.

Find the right one.
RIGHTCLICK says:

Look at the environment you're actually in.

What can it do right now?
These approaches can coexist.

RIGHTCLICK is interested in capabilities that are derived from the current environment, not only capabilities that were pre-enrolled into a global catalog.

Why agent developers should care
Fewer permanent model-facing tools
The generic interface stays small while capabilities can grow behind it.

Less provider-specific orchestration
Supported contracts are normalized before they reach the model.

Dynamic environments
Providers can appear and disappear while the agent is running.

Contextual discovery
The agent can ask what applies to this object or task instead of loading everything everywhere.

Authority below the model
Credentials do not necessarily have to become model arguments.

Better execution semantics
"Provider accepted it" and "user's goal happened" remain separate states.

Model/client independence
The capability runtime is being connected to ChatGPT, Claude Code, Codex, Cursor and generic MCP clients rather than rebuilt around each one.

Why software developers should care
Imagine shipping software and exposing a capability once.

Not:

build OpenAI adapter
build Claude adapter
build Cursor adapter
build Codex adapter
build another agent adapter
build custom MCP wrapper
...
But:

your software
      ↓
describes capability
      ↓
RIGHTCLICK reflects supported contract
      ↓
compatible AI clients can discover it
That is the longer-term model being tested.

Expose what your software can do.

Let the capability runtime deal with the AI boundary.

Why platform teams should care
Every integration tends to independently rebuild some mixture of:

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
RIGHTCLICK treats those as capability-runtime concerns.

That creates a place where the rules for acquiring and executing capabilities can evolve independently of the model using them.

How RIGHTCLICK works
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
The core capability engine is not built around a list of supported brands.

Reflectors translate supported capability substrates into one normalized model.

Capability sources determine which reflectors are present in the current environment.

Current OpenAPI work
The supported OpenAPI surface has been expanding generically rather than through provider special-cases.

Current main includes support demonstrated by the regression and live test programmes for things including:

plain-text operations

closed structured JSON object requests

generic structured arguments

required string path parameters

zero-argument GET operations

bounded larger OpenAPI documents

separate specification and execution origins

literal OpenAPI server binding

validated structured JSON responses

read-only JSON syntax fallback where semantic schema claims are unavailable

provider appearance and removal

capability identity changes

operation-level bearer authority

externally advertised bearer authority

exact execution-origin credential binding

real authenticated GitHub compatibility

Unsupported shapes are not silently converted into capabilities.

The goal is not provider-specific exceptions.

The goal is to keep widening the generic language of capabilities.

Safety should mostly be invisible
The product should feel simple:

ask what is possible
      ↓
pick an ability
      ↓
use it
But underneath that, RIGHTCLICK tries to be conservative about consequential things.

It can:

require explicit confirmation

distinguish support from unsupported execution

keep credentials outside model-facing arguments

bind authority to an exact execution origin

fail closed on conflicting client registrations

preserve unrelated client configuration

distinguish configured from connected

identify the exact runtime binary serving the AI

retain execution evidence

verify observable outcomes

The principle is:

Discover aggressively. Execute safely. Verify relentlessly.

CLI
You can use RIGHTCLICK without an AI client.

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
Add:

--json
for machine-readable output where supported.

Test capability discovery yourself
The simplest test is:

rightclick actions "RightClick"
Then:

rightclick providers
Install or expose software that contributes a supported capability.

Run the same query again.

The interesting property to watch is not merely that RIGHTCLICK has lots of tools.

It is whether:

environment changes
        ↓
capability graph changes
without changing the AI-facing interface.

Stable release vs current main
The latest published Homebrew release is currently v0.2.1:

brew install rossbuckley1990-hash/tap/rightclick
The repository's current main is ahead of that release and additionally contains:

MOAT-004 real GitHub-compatible acquisition work

the generic multi-client onboarding engine

native Claude Code onboarding

native Codex onboarding

To test the newest main before it is promoted to Homebrew:

git clone https://github.com/rossbuckley1990-hash/rightclick.git
cd rightclick

swift test
swift build -c release

.build/release/rightclick version
.build/release/rightclick doctor
Then configure a supported local client using that executable, or run:

.build/release/rightclick mcp
directly.

For a public launch, the intention is to promote the current main capability set into the next Homebrew release so brew install and this README describe the same product.

Requirements
Current runtime target:

Apple Silicon
macOS 14+
RIGHTCLICK does not require disabling macOS security.

Not every application exposes a capability contract RIGHTCLICK can use today.

Not every OpenAPI shape is currently supported.

That is expected.

The interesting work is expanding the generic capability language without turning RIGHTCLICK into another pile of provider-specific integrations.

Evidence, not screenshots
A lot of RIGHTCLICK development has been done as explicit RED → GREEN capability gates because the core claim is easy to overstate.

The repository preserves evidence for the important milestones:

BBEdit — capability acquisition without provider-specific code

MOAT-001 — structured OpenAPI capability acquisition

MOAT-002 — durable state + independent read-back

MOAT-003 — generic bearer authority

MOAT-004 — real GitHub-compatible acquisition

Generic onboarding engine

Claude Code adapter

Codex adapter

Security

Release process

The latest Codex integration regression passed:

288 tests
25 skipped
0 failures
The skipped tests are environment-gated tests rather than hidden failures.

What I want people to challenge
RIGHTCLICK is still early.

If you work on:

AI agents

MCP

tool use

developer tools

operating systems

agent security

OpenAPI

local-first software

AI infrastructure

capability systems

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

Should agents keep accumulating predefined tools, or should they be able to discover what their environment can do?

Start here
Stable release:

brew install rossbuckley1990-hash/tap/rightclick

rightclick doctor
rightclick actions "RightClick"
rightclick providers
Then connect it to your AI and ask:

What can you do here?
If that question can eventually replace a meaningful amount of integration plumbing, RIGHTCLICK is onto something.

The north star
An agent enters a new environment.

It does not arrive knowing every tool it will ever need.

Instead:

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
A new application appears.

The agent gains an ability.

A service comes online.

The agent gains an ability.

An API exposes a compatible contract.

The agent gains an ability.

No rebuild of the agent.

No provider-specific top-level tool required.

No assumption that a successful HTTP call means the job is done.

Software appears. Your AI learns what it can do.
Apache-2.0

One thing I would not leave like this for the actual HN launch: the “Stable release vs current main” section. Before posting HN, I’d promote the current main into the next Homebrew release, then collapse that entire section into a two-line install command.

That will make the launch much stronger because everything impressive in the README will be available from brew install immediately.

i need the below to be 4000 characters, not currently 4194: I built RIGHTCLICK because I kept running into the same thing with agents: every time I wanted to give one a new ability, I seemed to be adding another MCP server, another set of tools, another schema, another auth flow, and another thing that would need maintaining.

That started to feel backwards.

The models are getting better at reasoning about what to do, but we still tell them almost everything they are capable of doing up front.

So I started wondering: why does an agent need to know every capability in advance? Why can't the software around it describe what it can do, and let the agent discover those abilities when they're actually available?

That's what RIGHTCLICK is trying to do.

It exposes a small set of seven generic operations to the AI: inspect something, discover what actions apply, explain one, run it, check the result, inspect providers, and identify the runtime.

Behind that small interface, the capability graph can change.

The first experiment was almost stupidly simple. I installed BBEdit on a Mac and ran the exact same query before and after.

Before: 36 capabilities, none from third-party software.

After installing BBEdit: 41 capabilities, including five from BBEdit.

I hadn't added any BBEdit-specific acquisition code to RIGHTCLICK. The software appeared, RIGHTCLICK discovered what it exposed, and the AI gained those abilities.

That was the point where I thought there might actually be something here.

I've since pushed the same idea beyond native Mac software.

RIGHTCLICK can discover supported OpenAPI services, reflect their operations into the same capability layer, and remove them again when the provider disappears.

One of the latest tests went against the real GitHub API. RIGHTCLICK dynamically acquired an authenticated GitHub capability and ChatGPT invoked it through the same generic RIGHTCLICK tools. There is no GitHub-specific production tool in RIGHTCLICK for that operation.

Authentication is also kept out of the model-facing arguments where possible. In the bearer-auth path, the credential is resolved at the execution boundary and bound to the provider origin.

Another thing that bothered me with agents was how often "the API returned success" gets turned into "the task succeeded".

RIGHTCLICK deliberately separates those.

An invocation can be accepted without being considered verified. Where there is an observable postcondition, RIGHTCLICK can check what actually happened and report VERIFIED_SUCCESS or VERIFIED_FAILURE rather than assuming the provider response means the user's goal was achieved.

I've also been working on making the client side boring. The capability runtime shouldn't belong to one model or one app.

The current code has onboarding paths for Cursor, Claude Code and Codex, plus the ChatGPT bridge, all pointing at the same RIGHTCLICK capability runtime rather than having separate implementations of the product for each AI.

The idea I'm testing is basically:

software appears  
→ RIGHTCLICK discovers what it can do  
→ the capability becomes available to the agent  
→ the agent uses it through the same small interface

You can try the current release with:

    brew install rossbuckley1990-hash/tap/rightclick
    rightclick actions "RightClick"

Then connect it to a supported AI client and ask something like:

    What can my Mac do with this text: RightClick?

It's Apple Silicon/macOS 14+ at the moment and it's still early. I definitely don't think I've solved arbitrary software capability discovery, and there are plenty of OpenAPI shapes and other capability surfaces it doesn't understand yet.

That's actually one of the reasons I'm posting it here.

I'd really like people who work on agents, MCP, tool use, developer infrastructure, security or APIs to try to break the abstraction.

Give it software it doesn't understand. Point it at awkward APIs. Tell me where this model falls apart.

The thing I'm most interested in is whether this direction makes sense at all:

Should agents keep accumulating more and more predefined tools, or should they be able to discover what their environment can do?
…
I’ve tightened it without losing the human tone or the important technical points. This version is 3,887 characters, so safely under the 4,000-character limit.

I built RIGHTCLICK because I kept running into the same thing with agents: every time I wanted to give one a new ability, I ended up adding another MCP server, another set of tools, another schema, another auth flow, and another thing to maintain.

That started to feel backwards.

The models are getting better at reasoning about what to do, but we still tell them almost everything they can do up front.

So I started wondering: why does an agent need to know every capability in advance? Why can't the software around it describe what it can do, and let the agent discover those abilities when they're actually available?

That's what RIGHTCLICK is trying to do.

It exposes seven generic operations to the AI: inspect something, discover what actions apply, explain one, run it, check the result, inspect providers, and identify the runtime.

Behind that small interface, the capability graph can change.

The first experiment was almost stupidly simple. I installed BBEdit on a Mac and ran the exact same query before and after.

Before: 36 capabilities, none from third-party software.

After: 41 capabilities, including five from BBEdit.

I hadn't added any BBEdit-specific acquisition code. The software appeared, RIGHTCLICK discovered what it exposed, and the AI gained those abilities.

That was the point where I thought there might actually be something here.

I've since pushed the same idea beyond native Mac software.

RIGHTCLICK can discover supported OpenAPI services, reflect their operations into the same capability layer, and remove them again when the provider disappears.

One of the latest tests used the real GitHub API. RIGHTCLICK dynamically acquired an authenticated GitHub capability and ChatGPT invoked it through the same generic RIGHTCLICK tools. There is no GitHub-specific production tool for that operation.

Authentication is also kept out of model-facing arguments where possible. In the bearer-auth path, the credential is resolved at the execution boundary and bound to the provider origin.

Another thing that bothered me was how often "the API returned success" becomes "the task succeeded".

RIGHTCLICK deliberately separates those.

An invocation can be accepted without being considered verified. Where there is an observable postcondition, RIGHTCLICK can check what actually happened and report VERIFIED_SUCCESS or VERIFIED_FAILURE instead of assuming the provider response means the user's goal was achieved.

I've also been working on making the client side boring. The capability runtime shouldn't belong to one model or one app.

The current code has onboarding paths for Cursor, Claude Code and Codex, plus the ChatGPT bridge, all pointing at the same RIGHTCLICK capability runtime instead of separate versions of the product for each AI.

The idea I'm testing is basically:

software appears
→ RIGHTCLICK discovers what it can do
→ the capability becomes available to the agent
→ the agent uses it through the same small interface

You can try it with:

brew install rossbuckley1990-hash/tap/rightclick
rightclick actions "RightClick"
Then connect it to a supported AI client and ask:

What can my Mac do with this text: RightClick?
It's Apple Silicon/macOS 14+ for now and still early. I definitely haven't solved arbitrary software capability discovery, and there are plenty of OpenAPI shapes and capability surfaces it doesn't understand yet.

That's one reason I'm posting it here.

I'd really like people who work on agents, MCP, tool use, developer infrastructure, security or APIs to try to break the abstraction.

Give it software it doesn't understand. Point it at awkward APIs. Tell me where this model falls apart.

The thing I'm most interested in is whether this direction makes sense at all:

Should agents keep accumulating predefined tools, or should they be able to discover what their environment can do?

I think this version is actually better than the 4,194-character one: less repetition, more natural, and the core idea lands faster.

Review the repos current status and all of the demos and proofs and ways to startup and update the README

Worked for 7m 6s

I completed the repo audit against the current code, releases, Homebrew tap, startup paths, demos, proofs and the post-release work on main.

The biggest finding is that RIGHTCLICK has moved substantially beyond the story the existing README tells. The stable release is now v0.2.2, and the Homebrew formula is correctly pinned to v0.2.2 with an Apple Silicon bottle. Stable v0.2.2 includes native macOS reflection, OpenAPI, GraphQL, gRPC, universal capability artifacts, ARD acquisition, RIGHTCLICK federation and OAuth/OIDC authority support — all behind the same seven-operation AI interface.

Current main is then ahead of v0.2.2 again. It contains the typed Capability ABI foundation, RCIR production admission/lease/receipt machinery, invocation isolation, live contract revalidation, bounded discovery freshness and stale-provider invalidation. Crucially, I kept the README truthful: the full eleven-substrate restricted-agent proof is still not complete, so the README does not imply that Windows, Linux, A2A, Kafka, Kubernetes and WASM have all passed the final universal-runtime experiment yet.

I also reviewed the startup paths and incorporated all of them: direct CLI use; setup --all; individual Cursor, Claude Code and Codex onboarding; the persistent ChatGPT bridge; generic MCP over stdio; authenticated loopback HTTP MCP; configured OpenAPI providers; origin-bound bearer authority; generic OpenAPI/GraphQL/gRPC capability artifacts; RIGHTCLICK federation; and building/testing current main.

The replacement README now includes the real proof map rather than only the old BBEdit story:

BBEdit dynamic acquisition
RIGHTCLICK-000 native discovery/execution
RIGHTCLICK-004 live capability appearance/removal
RIGHTCLICK-005 contextual type differentiation
live OpenAPI gain/loss
MOAT-001 structured JSON acquisition
MOAT-002 durable state + independent read-back
MOAT-003 generic bearer authority
MOAT-004 real authenticated GitHub acquisition
MOAT-005 / RIGHTCLICK self-hosting through a reflected GitHub mutation
ARD acquisition
RIGHTCLICK federation
Capability ABI-001
RCIR production
RCIR invocation isolation
the explicit eleven-substrate universal-runtime acceptance scorecard
I also found two stale supporting docs worth correcting next: docs/DEMO.md still says public Homebrew installation is blocked, which is false now, and docs/PRODUCT_STATE.md still describes v0.2.1.

Updated README
I attempted to push this directly to main, first through GitHub's normal Contents API and then through the lower-level Git refs path. Both writes were rejected by the connected GitHub App with 403 — Resource not accessible by integration. So I have not claimed it was updated remotely when it wasn't.

The new README is designed so someone arriving from Hacker News sees, in order:

what RIGHTCLICK is → install command → instant test → connect their AI → why the current tool model hurts → seven-operation architecture → what v0.2.2 actually ships → live demos → self-hosting proof → deeper substrates → current-main R&D → explicit truth boundaries → north star.

That is now much closer to the actual product you have built than the current GitHub README. 


RIGHTCLICK_README_CURRENT_2026-10-07.md
Document



RIGHTCLICK
Stop wiring every new ability into your agent.
RIGHTCLICK is a dynamic capability runtime for AI.

It discovers supported capability contracts from the software and services around an agent, reflects them into one live capability graph, and exposes them through seven generic AI-facing operations.

Install an app. Start a service. Expose a compatible API. Connect another RIGHTCLICK runtime.

The capability graph changes. The AI-facing interface does not.

environment changes
        ↓
RIGHTCLICK discovers a supported capability contract
        ↓
capability enters the live graph
        ↓
the agent can inspect and explain it
        ↓
RIGHTCLICK applies authority + safety policy
        ↓
the agent invokes it through the same context_run
        ↓
RIGHTCLICK distinguishes provider acceptance from verified outcome
MCP is the transport. Capability acquisition is the product.

Stable: v0.2.2 · Apple Silicon · macOS 14+ · Homebrew · MCP · Apache-2.0

Try it in 30 seconds
1. Install
brew install rossbuckley1990-hash/tap/rightclick
Already installed?

brew update
brew upgrade rightclick
Check the exact runtime:

rightclick version
rightclick doctor
2. Ask what your environment can do
Text:

rightclick actions "RightClick"
A file:

rightclick actions ~/Desktop/example.jpg
A URL:

rightclick actions "https://example.com"
See the providers currently contributing capabilities:

rightclick providers
This is not a static catalog of every integration RIGHTCLICK knows about.

It is a query against the capability graph that exists in your environment now.

Give the same runtime to your AI
Preview every detected supported local client without changing anything:

rightclick setup --all --dry-run --json
Then connect all detected clients:

rightclick setup --all --yes
Or choose one.

Cursor
rightclick setup --client cursor --dry-run --json
rightclick setup --client cursor --yes
Claude Code
rightclick setup --client claude --dry-run --json
rightclick setup --client claude --yes
RIGHTCLICK uses Claude Code's native user-scope MCP registration.

Codex
rightclick setup --client codex --dry-run --json
rightclick setup --client codex --yes
RIGHTCLICK uses Codex's native MCP registration and refuses conflicting same-name registrations before mutation.

ChatGPT
Preview the persistent bridge:

rightclick setup chatgpt --dry-run --json
When its pairing/credential prerequisites are satisfied:

rightclick setup chatgpt --yes
The ChatGPT path uses a stable Homebrew entrypoint, persistent tunnel identity, runtime/process attestation and upgrade reconciliation rather than treating a config file as proof of a live connection.

Any MCP client over stdio
rightclick mcp
Equivalent configuration:

{
  "mcpServers": {
    "rightclick": {
      "command": "/opt/homebrew/bin/rightclick",
      "args": ["mcp"]
    }
  }
}
Use which rightclick if Homebrew is installed elsewhere.

Authenticated local HTTP MCP
export RIGHTCLICK_MCP_TOKEN='replace-with-a-random-secret'
rightclick mcp --http --port 8765
The endpoint is:

http://127.0.0.1:8765/mcp
HTTP MCP requires a bearer token and stays on loopback.

Then ask the agent
Try something deliberately simple:

What can you do with this text: RightClick?
Or:

What can you do with ~/Desktop/photo.jpg?
Explain the useful capabilities before doing anything.
Or:

Do this, but do not tell me it succeeded unless you can verify the requested result.
Or inspect the graph itself:

Which capability providers can you see right now?
The interesting part is that the answer is derived from the environment rather than a provider list hard-coded into the prompt.

Why RIGHTCLICK exists
Every time I wanted to give an agent another ability, I seemed to be adding another MCP server, another tool set, another schema, another auth flow and another thing to maintain.

That started to feel backwards.

Models are getting better at reasoning about what to do, but we still tend to tell them almost everything they are capable of doing up front.

RIGHTCLICK asks a different question:

Why should an agent need to know every capability in advance?

Instead of:

new software
    ↓
build AI integration
    ↓
define provider-specific tools
    ↓
wire schemas + credentials
    ↓
attach them to the agent
    ↓
maintain them forever
RIGHTCLICK is working toward:

software or service appears
        ↓
it exposes a supported capability contract
        ↓
RIGHTCLICK reflects it
        ↓
capability enters the graph
        ↓
the same agent interface can use it
The integration boundary moves from every provider × every AI client toward a reusable capability runtime.

Seven operations, not a tool per provider
RIGHTCLICK exposes exactly these generic MCP operations:

Operation	Purpose
context_runtime	Identify the exact RIGHTCLICK process, executable, SHA-256, PID and transport
context_inspect	Parse/classify a file, URL or text
context_actions	Discover capabilities that apply now
context_explain	Inspect one capability, its provider, effects, support and policy
context_run	Execute a discovered capability
context_run_status	Read retained execution and verification evidence
context_providers	Inspect providers contributing to the graph
The architectural invariant is what is not required:

github_merge_branch
github_get_user
slack_send_message
some_vendor_create_record
another_vendor_transform_file
...
A supported provider operation can instead become an ordinary RIGHTCLICK capability and still execute through context_run.

What stable v0.2.2 can reflect
v0.2.2 deliberately expands capability substrates, not brand-specific AI tools.

Substrate / source	Stable v0.2.2 status
Native macOS	Services, sharing services and Finder Action metadata
OpenAPI	Bonjour + configured providers, supported structured operations and authority
GraphQL	Generic GraphQL reflection, including Bonjour/artifact acquisition
gRPC	Generic reflection/descriptors for supported message/method shapes
Capability artifacts	Provider-neutral OpenAPI, GraphQL and gRPC artifact resolution
ARD	ARD registry results can feed capability artifacts into the same runtime
RIGHTCLICK federation	One runtime can reflect capabilities from another authenticated RIGHTCLICK runtime
Authority	Origin-bound bearer support plus OAuth/OIDC authority support
AI clients	Cursor, Claude Code, Codex, ChatGPT bridge and generic MCP clients
These are supported slices, not a claim that every OpenAPI document, GraphQL schema, gRPC service or application is automatically executable.

Unsupported or ambiguous contracts fail closed instead of being guessed into existence.

The v0.2.2 release passed 411 tests, with 26 explicit environment-gated skips and 0 failures, and its published source/bottle path is pinned in the Homebrew tap.

The first proof was just installing BBEdit
The simplest RIGHTCLICK experiment is still one of the best.

Same Mac. Same RIGHTCLICK build. Same text query.

before BBEdit
36 capabilities
0 third-party

after ordinary BBEdit installation
41 capabilities
5 BBEdit capabilities

BBEdit-specific acquisition code added
0
RIGHTCLICK reflected capabilities BBEdit already exposed through its normal macOS Services contract.

The generic executor then transferred the exact requested text into a new BBEdit document.

BBEdit proof · launch demo script

Want to replay the idea? Run the same rightclick actions query before and after installing a compatible app, then rightclick refresh and compare the returned graph. Use your actual counts; the preserved 36 → 41 result is historical evidence, not a promised count for every Mac.

Add your own supported OpenAPI provider
You do not need to rebuild RIGHTCLICK to configure a supported HTTPS OpenAPI provider.

rightclick provider add \
  --id orders-api \
  --spec-url https://api.example.com/openapi.json \
  --base-url https://api.example.com
Inspect configured providers:

rightclick provider list
Remove it:

rightclick provider remove --id orders-api
If a reflected operation needs a supported bearer scheme, store the credential outside model-facing arguments:

printf '%s\n' "$API_TOKEN" | \
  rightclick authority set \
    --origin https://api.example.com \
    --scheme bearerAuth
Check or delete it:

rightclick authority status --origin https://api.example.com --scheme bearerAuth
rightclick authority delete --origin https://api.example.com --scheme bearerAuth
Credentials are resolved at the execution boundary and bound to the canonical provider origin.

Feed capability artifacts from the environment
v0.2.2 includes one provider-neutral artifact envelope for supported OpenAPI, GraphQL and gRPC contracts.

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

rightclick mcp
All three descriptors enter the same resolver registry and capability graph.

Security defaults are intentionally conservative: remote HTTP artifacts require HTTPS; plaintext HTTP/gRPC are loopback-only; remote gRPC requires grpcs://; duplicate identities fail closed.

Federate RIGHTCLICK runtimes
One authenticated RIGHTCLICK runtime can reflect capabilities from another without exposing the remote provider's credential to the caller.

Runtime B:

export RIGHTCLICK_MCP_TOKEN='runtime-b-secret'
rightclick mcp --http --port 8877
Runtime A:

export RIGHTCLICK_FEDERATION_PEERS='[
  {
    "id": "runtime-b",
    "name": "Remote RIGHTCLICK",
    "endpoint": "http://127.0.0.1:8877/mcp",
    "tokenEnvironment": "RIGHTCLICK_FEDERATION_B_TOKEN"
  }
]'

export RIGHTCLICK_FEDERATION_B_TOKEN='runtime-b-secret'
rightclick mcp
Runtime A can now reflect supported capabilities from B behind the same seven operations.

The first federation slice is deliberately bounded: peers are explicitly configured, loopback HTTP is required, transitive federation is blocked, and remote provider credentials stay at the execution peer.

Full federation contract and proof

Provider acceptance is not user success
RIGHTCLICK deliberately separates:

provider accepted the request
from:

the user's requested outcome happened
An HTTP 2xx, API acknowledgement or sharing callback is not automatically semantic success.

Where an observable postcondition exists, RIGHTCLICK can evaluate provider-independent verification such as:

exact returned text
file existence/readability
SHA-256 equality/change
file-size thresholds
image dimensions
extended-attribute presence/absence
metadata presence/absence
before/after observable state
separate read-back of durable remote state
A run can therefore remain accepted/unverified rather than being mislabeled as success.

It can become VERIFIED_SUCCESS only when the required observation is actually established, or VERIFIED_FAILURE when the observed state contradicts the requested result.

Proofs: what has actually been demonstrated
Proof	What it establishes
RIGHTCLICK-000
Native macOS sharing/services discovery and supported execution boundaries
RIGHTCLICK-004
A previously unseen installed Service appears, executes, then disappears without rebuilding RIGHTCLICK
RIGHTCLICK-005
Capability applicability changes with JPEG/PDF/MOV/TXT context
BBEdit
Ordinary third-party installation adds usable capabilities with zero BBEdit-specific acquisition code
Live OpenAPI gain/loss
Remote provider appears, executes and disappears live
MOAT-001
Previously unsupported structured JSON operation becomes usable generically
MOAT-002
Durable remote state is independently read back instead of inferred from POST acceptance
MOAT-003
Origin-bound bearer authority stays outside MCP arguments
Real GitHub acquisition / MOAT-004	Generic OpenAPI reflection reaches a real authenticated GitHub capability without GitHub-specific production tools
MOAT-005 / self-hosting
RIGHTCLICK uses a reflected GitHub capability to modify the RIGHTCLICK repo, then independently verifies the state
ARD acquisition
ARD can act as a discovery source feeding the same artifact/reflection runtime
Federation
A RIGHTCLICK runtime can reflect and invoke a capability owned by another runtime
Capability ABI-001
Provider-independent typed value/schema/canonical-contract foundation on current main
RCIR production
Current-main OpenAPI admission/lease/receipt boundary with real transport controls
Invocation isolation
Separate invocation bindings remain isolated while provider graph identity stays stable
Universal runtime acceptance
Explicit scorecard for the eleven-substrate north star and what is still not proven
The evidence directories preserve raw receipts/logs where the claim needs more than a prose summary.

RIGHTCLICK can use RIGHTCLICK to improve itself
The self-hosting proof is a useful demonstration of the architecture.

RIGHTCLICK dynamically reflected a GitHub OpenAPI capability:

Merge a branch
The AI invoked it through the same context_run interface.

Authority was resolved below the model-facing contract and bound to https://api.github.com.

GitHub returned 201, which RIGHTCLICK correctly treated only as provider acceptance.

A separate repository read then verified the resulting branch state.

There is no github_merge_branch top-level RIGHTCLICK tool.

Read the self-hosting proof.

Stable v0.2.2 vs current main
The Homebrew tap installs v0.2.2.

brew install rossbuckley1990-hash/tap/rightclick
rightclick version
Current main has moved beyond that release with post-v0.2.2 runtime work including:

Capability ABI-001 typed contract foundations
RCIR production OpenAPI admission and receipt machinery
invocation-bound leases isolated from provider-generation identity
live OpenAPI contract revalidation before dispatch
bounded discovery snapshot freshness and stale-provider invalidation
stronger external-observation and signed-receipt proof routes
Those changes are development bytes until a later immutable release is published. A version string alone must not be used to infer that the installed v0.2.2 bottle contains post-release main changes.

Most importantly, the full eleven-substrate north-star proof is not complete.

The current acceptance scorecard explicitly does not claim that a seven-operation-only agent has already traversed all of:

Mac application
Windows machine
Linux service
REST API
GraphQL API
gRPC service
MCP server
A2A agent
Kafka topic
Kubernetes cluster
WASM component
Some substrate support exists today; the single restricted-agent, all-eleven acceptance run remains a work in progress.

Universal runtime acceptance scorecard

Build and test current main
git clone https://github.com/rossbuckley1990-hash/rightclick.git
cd rightclick

swift test --force-resolved-versions
swift build -c release

.build/release/rightclick version
.build/release/rightclick doctor
.build/release/rightclick mcp
Useful acceptance/proof commands for contributors:

python3 scripts/acceptance-mcp.py .build/debug/rightclick
python3 scripts/acceptance-setup.py .build/debug/rightclick
python3 scripts/acceptance-federation.py .build/debug/rightclick
bash scripts/test-capability-abi.sh
bash scripts/test-rcir.sh
The RCIR public proof and freshness proof are documented in RCIR-PRODUCTION.md.

Architecture
                              AI / AGENT
                                   │
                         seven generic operations
                                   │
                                   ▼
                         ┌─────────────────┐
                         │   RIGHTCLICK    │
                         │ capability graph│
                         └────────┬────────┘
                                  │
                    discovery sources / artifacts
                                  │
       ┌──────────┬──────────┬────┼─────┬──────────┬──────────┐
       ▼          ▼          ▼          ▼          ▼          ▼
     macOS     OpenAPI    GraphQL     gRPC       ARD     federation
       │          │          │          │          │          │
       └──────────┴──────────┴──────────┴──────────┴──────────┘
                                  │
                             Capability
                                  │
                       policy / confirmation
                                  │
                         authority resolution
                                  │
                              execution
                                  │
                             observation
                                  │
                            verification
Sources discover.

Reflectors normalize.

The engine owns routing and policy.

Authority is resolved below the model where supported.

Verification sits above provider acknowledgement.

That separation is the point.

What RIGHTCLICK is not claiming
RIGHTCLICK is early infrastructure.

It does not claim:

every installed application exposes a usable contract
every right-click menu item is discoverable/invokable
arbitrary OpenAPI/GraphQL/gRPC support
every auth scheme is implemented
provider acceptance proves semantic success
current main is automatically present in the published Homebrew bottle
the complete eleven-substrate universal-runtime experiment has already passed
The product goal is not to hide unsupported boundaries.

It is to make the supported path feel simple while widening the generic capability language underneath it.

Discover aggressively. Execute safely. Verify relentlessly.

Contributing
The most useful contributions make RIGHTCLICK understand a class of capabilities, not one provider.

Good questions:

Can this new substrate compile into the existing capability model?
Can a schema shape be supported generically?
Does this authority boundary prevent credential leakage or confused-deputy behaviour?
Can a result be independently observed rather than inferred from a transport response?
Can a new discovery source feed the existing artifact/resolver graph?
Does provider withdrawal invalidate stale authority and execution bindings?
If a change requires a permanent provider-specific top-level AI tool, it is probably working against the core idea.

See CONTRIBUTING.md, SECURITY.md and the build programme.

North star
An agent enters a new environment.

It does not arrive with every tool it will ever need.

environment appears
        ↓
software and services expose supported capability contracts
        ↓
RIGHTCLICK discovers and normalizes them
        ↓
capabilities enter the graph
        ↓
authority and policy are applied
        ↓
the agent acts through the same small interface
        ↓
the outcome is verified where observable
A new application appears.

The agent gains an ability.

A service comes online.

The agent gains an ability.

A compatible API appears.

The agent gains an ability.

Another RIGHTCLICK runtime becomes reachable.

The graph gets larger.

No rebuild of the agent.

No provider-specific top-level AI tool required.

No assumption that transport success means the job is done.

Software appears. Your AI learns what it can safely do.
Apache-2.0

⋮⋮⋮⋮⋮⋮⋮⋮⋮⋮⋮⋮
