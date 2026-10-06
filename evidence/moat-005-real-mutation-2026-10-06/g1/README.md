# MOAT-005 G1 — path parameters + JSON request body

## Frozen claim

RIGHTCLICK must generically support a mutating OpenAPI operation that
requires both:

1. a required string path parameter; and
2. a required closed JSON-object request body.

No provider-specific code is permitted.

## G1 fixture

The synthetic operation is:

    POST /records/{id}

Path arguments:

    id: string, required

JSON body:

    title: string, required
    body: string, required

Response:

    201 application/json
    {"status": string}

Every schema in the synthetic contract is already inside RIGHTCLICK's
existing strong closed-string-object subset.

Therefore the only new semantic capability under test is composition of
a path argument and JSON request body in one operation.

## Required reflected argument contract

The AI-facing capability must expose one closed structured argument
object containing:

    id
    title
    body

All three are required.

## Required execution behaviour

Given:

    id = alpha
    title = Hello
    body = World

RIGHTCLICK must send exactly:

    POST /records/alpha

with JSON:

    {"body":"World","title":"Hello"}

The path argument must not leak into the JSON body.

## Fail-closed requirements

Before transport:

- missing path fields fail
- missing body fields fail
- unknown fields fail
- path/body field-name collisions abstain rather than guessing

## Explicit G1 boundary

G1 does NOT need to reflect the real GitHub `issues/create` operation yet.

The frozen GitHub request schema additionally contains constructs outside
the current strong request-schema slice, including `oneOf`, arrays,
integers, nullable fields, and an object that does not declare
`additionalProperties: false`.

Those are later gates.

No real provider request is allowed in G1.
No credential is required in G1.
