# MOAT-001 — Structured OpenAPI Capability Acquisition

## Result

**PASS**, subject to the claim boundaries below.

MOAT-001 demonstrates that RIGHTCLICK can discover and invoke a typed
`application/json` operation from remote software for which no
provider-specific RIGHTCLICK integration or tool was written.

## Preregistered RED

The frozen OpenAPI document contains two operations:

- `MOAT001 Control Echo`: `text/plain -> text/plain`
- `Create Structured Record`: `application/json -> application/json`

The old RIGHTCLICK runtime discovered the provider and reflected the
plain-text control operation while abstaining from the structured JSON
operation.

Old runtime:

- version: `0.2.0`
- PID: `43135`
- SHA-256:
  `60aba8cc28e40fb2e16637e380381fe2a98b844c2c435a136515a3f1382feb17`

OpenAPI SHA-256:

`20bff38cdf5eb285e91029bf5186b28727f0c1206245081b7bec8ea37da8988e`

The remote JSON operation independently returned HTTP `201`, proving
that the operation itself was functional while RIGHTCLICK abstained.

## Preregistered GREEN contract

Before implementation, tests required:

- a closed JSON object request schema;
- explicitly named properties;
- required string fields;
- string enums;
- `additionalProperties: false`;
- generic structured arguments;
- JSON serialization;
- validation before transport;
- canonical structured JSON responses;
- continued abstention for arbitrary unsupported JSON objects.

The preregistered test patches are preserved in this evidence directory.

## Generic implementation

Implementation commit:

`51eceef09f501ecd4b43afcaa7d6862915d8c6fb`

The implementation adds a provider-independent structured argument
envelope to the existing `context_run` capability interface.

The seven RIGHTCLICK tool names remain unchanged.

No provider-specific `Create Structured Record`, GitHub, Slack, or
other operation tool was added.

The generic `context_run` input schema did change to add:

```json
{
  "arguments": {
    "type": "object",
    "additionalProperties": {
      "type": "string"
    }
  }
}
```

The direct MCP `tools/list` result from the GREEN binary is preserved
as `DIRECT_MCP_TOOLS_LIST.json`.

## Same-endpoint causal gate

A single live remote endpoint was observed immediately before and after
changing only the RIGHTCLICK runtime.

The OpenAPI bytes were identical across the gate:

`20bff38cdf5eb285e91029bf5186b28727f0c1206245081b7bec8ea37da8988e`

### Old runtime

- `MOAT001 Control Echo`: PRESENT
- `Create Structured Record`: ABSENT

### GREEN runtime

- `MOAT001 Control Echo`: PRESENT
- `Create Structured Record`: PRESENT
- generic `arguments` support: PRESENT

GREEN runtime:

- version: `0.2.0`
- PID: `58860`
- SHA-256:
  `741540be89d4dc1f1f751cd5d568e55403910d516381c2bc762b11b72a144abd`

## Live structured invocation

Natural-language intent:

`Create a high-priority record titled RightClick learned structured JSON live`

RIGHTCLICK reflected the required schema and the AI supplied:

```json
{
  "title": "RightClick learned structured JSON live",
  "priority": "high"
}
```

RIGHTCLICK then performed the reflected remote operation.

Observed provider boundary:

- HTTP method: `POST`
- path: `/records`
- provider status: `201`

Canonical returned JSON:

```json
{
  "id": "moat001-red-record",
  "priority": "high",
  "title": "RightClick learned structured JSON live"
}
```

Execution ID:

`CE8729EA-6B78-4EBE-B85D-FF808B6BD836`

Verification:

- status: `VERIFIED_SUCCESS`
- `outcomeVerified: true`
- predicate: exact returned JSON text

## Test result

Final full suite:

- **137 executed**
- **8 skipped**
- **0 failures**

The skipped tests are environment-gated acceptance tests.

## Exact claim supported

> RIGHTCLICK discovered a typed JSON capability from previously
> unsupported remote software, exposed its argument schema through its
> generic capability interface, accepted structured arguments through
> the generic context_run tool, serialized and executed the remote
> request, validated the structured JSON response, and verified the
> exact returned result without a provider-specific tool or integration.

## Claim boundaries

- The remote fixture returns a record-shaped result with a fixed ID.
- The fixture does not persist the record.
- There is no independent GET/read-back operation in MOAT-001.
- Therefore MOAT-001 does **not** establish durable remote state.
- `VERIFIED_SUCCESS` here verifies the exact validated provider return,
  not independent persisted state.
- The seven tool names stayed constant, but `context_run` gained a
  generic `arguments` field.
- A fresh ChatGPT connection was required before the updated MCP tool
  schema was visible.
- No credentials, Cloudflare claim tokens, tunnel secrets, or unrelated
  process command lines are included in this evidence.

## Next milestone

**MOAT-002 — Durable structured state and independent read-back
verification.**
