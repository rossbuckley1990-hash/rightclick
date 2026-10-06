# MOAT-002 — Durable Remote State + Independent Read-Back

## Result

**PASS**, subject to the claim boundaries below.

MOAT-002 demonstrates that RIGHTCLICK can acquire a previously unavailable
OpenAPI GET capability with a required string path parameter without adding
a provider-specific tool or changing its seven-tool MCP contract.

It then uses that separately discovered GET capability to independently
observe durable remote state created through a dynamically discovered POST.

## Base

Frozen base commit:

`0d4d88a09c9d9214aa36b06152ae649555aa1f35`

MOAT-002 product commit:

`b4d5d8f00faf6d6a830a1d749fede4ad85a093ec`

## Frozen remote contract

OpenAPI SHA-256:

`e58eea412ca836a2c3c6aef0cfdc7f142296abf7d84d931d9b16d71efea9277d`

The provider exposes:

- `POST /records` — Create Durable Record
- `GET /records/{id}` — Read Durable Record

The provider uses Durable Object storage.

Before RIGHTCLICK product changes, direct provider tests established:

- create returned HTTP 201;
- an independent GET returned HTTP 200;
- a delayed GET returned HTTP 200;
- read-back matched the created record.

## RED

The pre-MOAT-002 runtime was:

`741540be89d4dc1f1f751cd5d568e55403910d516381c2bc762b11b72a144abd`

Against the same provider and same OpenAPI bytes:

- Create Durable Record: **PRESENT**
- Read Durable Record: **ABSENT**

The source boundary supported POST, PUT, and PATCH, and abstained from
paths containing placeholders.

## Preregistered GREEN contract

Preregistered test patch SHA-256:

`72ce3b0299f882daa8e0cbee5ef0189e13490f19a0795f430756278df6f6292c`

GREEN required RIGHTCLICK to:

- reflect `GET /records/{id}`;
- accept exactly one required string path parameter;
- expose `id` through the existing generic `arguments` object;
- percent-encode the argument as path-segment data;
- send GET without a request body;
- omit Content-Type when no request body exists;
- keep Accept application/json;
- validate the closed JSON response;
- reject missing or unknown arguments before transport;
- abstain on unsupported parameter shapes;
- add no provider-specific implementation;
- add no MCP tool names;
- make no change to the `context_run` schema.

Three new tests failed before implementation, while the unsupported-shape
abstention test already passed.

## Implementation

First generic implementation patch SHA-256:

`684ee5c9c9013869edd9dbf5be8d5ab5517ecd2436740998974d37afa27369dc`

That implementation exposed a representation-only mismatch: Foundation
escaped `/` inside canonical JSON text.

The preregistered test was not changed.

A generic serializer correction used
JSONSerialization.WritingOptions.withoutEscapingSlashes.

Final implementation patch SHA-256:

`4a4634884e2d6ac1a7bf303d6f4b164b7e716b34dc0c4c4e2da485a6675a61fa`

Final test result:

- 14 OpenAPIReflector tests passed;
- 141 total tests executed;
- 8 environment-gated tests skipped;
- 0 failures.

## MCP interface invariance

Release candidate SHA-256:

`8fd520a251108a1ac93bdb898b74de429fbf86b5e445b3669d41b7bf3beeae0f`

The candidate and MOAT-001 exposed the same:

- seven MCP tool names;
- canonical tool schemas;
- generic `context_run.arguments` object.

No provider-specific MCP tool was added.

## Same-provider capability gain

Against one unchanged live provider and byte-identical OpenAPI
specification:

### Old runtime

- Create Durable Record: PRESENT
- Read Durable Record: ABSENT

### New runtime

- Create Durable Record: PRESENT
- Read Durable Record: PRESENT

Only the RIGHTCLICK runtime changed during that causal gate.

The original temporary hostname later expired before the final execution
gate. That transport failure was preserved rather than hidden.

The exact fixture and byte-identical OpenAPI contract were then redeployed
to a fresh temporary hostname. No RIGHTCLICK source or MCP schema change
was made for that redeployment.

## Final live execution

RIGHTCLICK created:

    {
      "id": "6a4c11b3-7813-4e58-9683-1c4341a89af5",
      "priority": "high",
      "title": "RightClick MOAT-002 live gate"
    }

Create execution:

`E013275F-7375-403B-99E1-913C3F922D66`

Observed create boundary:

- POST /records
- HTTP 201
- state: accepted
- outcomeVerified: false

The POST response was deliberately not treated as semantic proof.

RIGHTCLICK then invoked the separately discovered:

`GET /records/{id}`

using the returned UUID.

Read execution:

`F2933431-269F-46BE-BA9E-BD65CB9CE604`

Observed read boundary:

- HTTP 200
- state: succeeded
- verification: VERIFIED_SUCCESS
- outcomeVerified: true

The GET result exactly matched the record returned by the POST.

A further delayed read during evidence freezing also returned the same
persisted record.

## Exact supported claim

> RIGHTCLICK gained a previously unavailable remote ability while its
> AI-facing seven-tool MCP interface remained unchanged. It created durable
> remote state through one dynamically discovered capability and independently
> observed that persisted state through a separately discovered GET capability,
> using the same generic arguments envelope and provider-independent
> verification machinery.

## Claim boundaries

- GET support in this milestone is intentionally narrow.
- It supports exactly one required string path parameter.
- Optional path parameters are not claimed.
- Non-string path parameters are not claimed.
- Query parameter support is not claimed.
- Arbitrary OpenAPI support is not claimed.
- Provider HTTP acceptance alone was not counted as semantic success.
- Persistent state was established through a separate GET observation.

## Evidence structure

This directory preserves:

- RED provider and RIGHTCLICK boundary evidence;
- preregistered failing tests;
- first implementation failure;
- serializer correction;
- final implementation patch;
- test and release receipts;
- unchanged MCP tools/list;
- same-provider capability-gain receipt;
- final provider source and frozen contract;
- live create and independent read-back receipts;
- delayed persisted-state read-back.
