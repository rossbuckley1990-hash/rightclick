# MOAT-005 G2 — multiple required path parameters

## Frozen claim

RIGHTCLICK must generically support more than one required string
path parameter in the same OpenAPI operation.

G1 proved:

- one required path parameter
- plus a required closed JSON body
- one combined AI-facing structured argument contract
- partitioning between URL path and JSON body
- unknown-field rejection
- path/body collision abstention

G2 changes only one dimension:

    one path parameter -> multiple path parameters

## Synthetic operation

    POST /groups/{group}/records/{record}

Required path parameters:

    group: string
    record: string

Required JSON body:

    title: string
    body: string

Expected combined arguments:

    group
    record
    title
    body

Given:

    group = engineering
    record = alpha
    title = Hello
    body = World

RIGHTCLICK must send:

    POST /groups/engineering/records/alpha

with JSON body:

    {"body":"World","title":"Hello"}

Path arguments must not appear in the JSON body.

## Fail-closed requirements

Before transport:

- missing either required path argument fails
- unknown arguments fail
- duplicate parameter names abstain
- unresolved or mismatched path placeholders abstain
- path/body name collisions abstain

## Boundary

No GitHub-specific production code.
No real provider request.
No credential.
No GitHub issue creation.
