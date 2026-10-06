# MOAT-005 G4 — real mutation JSON response fallback

## Frozen input

This gate combines:

- G2's proven generic multiple-path routing;
- G3's frozen real GitHub `issues/create` request schema;
- GitHub's exact frozen `201 application/json` response declaration.

The response declaration is taken from the same official frozen GitHub
OpenAPI contract used throughout MOAT-005.

## Problem

RIGHTCLICK already supports JSON-syntax-only response validation for GET
operations when the provider declares JSON but its response schema lies
outside RIGHTCLICK's strong structural subset.

Mutating JSON operations currently require a fully supported closed JSON
response schema.

That means a legitimate mutation can remain invisible solely because its
success response is richer than RIGHTCLICK's current structural response
validator.

## G4 required semantic

For a non-GET operation with:

- a supported request contract;
- an application/json 2xx response;
- a declared non-empty JSON response schema that RIGHTCLICK cannot
  structurally validate;

RIGHTCLICK may reflect the operation with:

    resultValidation = json_syntax_only

It must NOT claim schema-level response verification.

Execution must:

1. require a 2xx HTTP status;
2. require Content-Type application/json;
3. require syntactically valid JSON;
4. return the canonical JSON;
5. keep outcomeVerified=false.

Malformed JSON must fail as provider_contract_failure.

## Safety interpretation

This does not weaken semantic verification.

HTTP 2xx + valid JSON proves transport/provider acceptance only.

The later MOAT-005 live gate will independently read the resulting
provider state and verify the exact requested mutation.

## Boundary

No live provider request.
No GitHub credential.
No issue creation.
No GitHub-specific production code.
