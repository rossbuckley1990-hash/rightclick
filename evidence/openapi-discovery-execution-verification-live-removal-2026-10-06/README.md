# OpenAPI discovery, execution, verification, and live removal — 2026-10-06

## Result

**PASS**

This experiment demonstrated that RIGHTCLICK v0.2.0 RC1 could discover a Bonjour-advertised OpenAPI provider without a provider-specific MCP server or ChatGPT tool definition, reflect its operations into the existing RIGHTCLICK capability surface, execute a reflected operation, verify the declared returned-text outcome, and remove the provider and its capabilities after the provider disappeared.

The experiment ran inside one ongoing ChatGPT conversation.

## Runtime attestation

The RIGHTCLICK process serving the successful capability evaluation reported:

- product: `RIGHTCLICK`
- version: `0.2.0`
- executable path: `/opt/homebrew/opt/rightclick-rc1/bin/rightclick`
- executable real path: `/opt/homebrew/Cellar/rightclick-rc1/0.2.0/bin/rightclick`
- executable SHA-256: `32fda24a7d46aa0193230582872026e8d75058fc37f2165b35a8730f9151c66e`
- transport: `stdio`

## Provider

A disposable local provider advertised:

- Bonjour service type: `_rightclick._tcp.`
- instance: `RIGHTCLICK WTF DEMO`
- `kind=openapi`
- `scheme=http`
- `spec=/openapi.json`
- `base=/`

Bonjour browse and resolve both observed the provider. The advertised host was reachable over HTTP and served the OpenAPI document.

RIGHTCLICK reflected the provider as:

`RIGHTCLICK — Software ChatGPT Has Never Seen`

with three capabilities:

1. `Overwrite This File Using A Capability Learned Live`
2. `Prove This AI Learned A New Ability Live`
3. `Transform This Through Newly Discovered Software`

No provider-specific MCP server was added. No new ChatGPT tool definition or plugin was added for this provider.

## Safety observation

RIGHTCLICK classified `Overwrite This File Using A Capability Learned Live` as:

- safety: `destructive`
- requiresConfirmation: `true`
- supportLevel: `experimental`

The user explicitly confirmed the overwrite, but the ChatGPT tool layer blocked the invocation before it reached RIGHTCLICK. This experiment therefore makes no claim that the overwrite executed.

## Executed reflected capability

The user explicitly confirmed `Transform This Through Newly Discovered Software`.

RIGHTCLICK invoked:

`HTTP POST http://rosss-macbook-air.local.:50100/transform`

Provider response: `200`

Execution state: `succeeded`

Execution ID:

`B0209C9B-C9E9-4730-BDAC-2C361BF87156`

Returned text:

`NEW SOFTWARE SAYS: DETRATS TAHC EHT RETFA YTILIBA WEN A DENRAEL TSUJ IA SIHT`

A caller-declared `text_equals` predicate was evaluated against that returned text.

Verification result:

- status: `VERIFIED_SUCCESS`
- predicate evaluated: `true`
- predicate passed: `true`
- outcomeVerified: `true`

This verifies the exact returned-text outcome. It does not claim an independently observed external side effect.

## Live removal

Before provider termination, both `context_providers` and `context_actions` contained the provider and all three reflected capabilities.

The disposable HTTP provider and Bonjour advertiser were then terminated without restarting ChatGPT or the serving RC1 process.

The same live RC1 session was queried again.

After termination:

- provider present: `false`
- overwrite capability present: `false`
- prove capability present: `false`
- transform capability present: `false`

This demonstrates live capability removal when the discovered provider leaves the environment.

## Exact claim supported by this run

> In an ongoing ChatGPT conversation, RIGHTCLICK v0.2.0 RC1 discovered a Bonjour-advertised OpenAPI provider, reflected three provider operations into its fixed capability interface, executed one reflected operation with a verified returned-text postcondition, and removed the provider and all three capabilities after the provider was terminated.

## Claim boundary

During setup, the production ChatGPT bridge was found to still target the older `/opt/homebrew/bin/rightclick`. The bridge profile was corrected to the sealed RC1 executable before the successful OpenAPI capability evaluation.

Therefore this run does not claim that one unchanged RIGHTCLICK process observed the provider's initial arrival. It does prove discovery by the sealed RC1 runtime, successful reflected execution and verification, and live disappearance from that same RC1 session after provider termination.

No credentials, API keys, tunnel secrets, or unrelated process command lines are preserved in this evidence.
