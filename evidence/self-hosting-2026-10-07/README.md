# RIGHTCLICK self-hosting proof — GitHub branch composition

Date: 2026-10-07 (Europe/London)

## Claim

RIGHTCLICK used a dynamically reflected GitHub OpenAPI capability to modify the RIGHTCLICK repository itself without a GitHub-specific AI-facing tool.

The AI-facing operation remained `context_run`.

The discovered capability was:

```text
Merge a branch
```

Its reflected contract came from the generic GitHub OpenAPI provider and required structured arguments:

```text
owner
repo
base
head
commit_message
```

Authority was resolved by RIGHTCLICK below the model-facing capability contract and bound to:

```text
https://api.github.com
```

## Execution

RIGHTCLICK invoked:

```text
POST https://api.github.com/repos/rossbuckley1990-hash/rightclick/merges
```

to compose:

```text
head: moat-005-live-federation-proof
base: feature/grpc-capability-reflection
```

GitHub returned `201`, which RIGHTCLICK correctly reported only as provider acceptance.

RIGHTCLICK did **not** claim semantic success from the HTTP status.

## Independent verification

A separate repository read then observed:

```text
feature/grpc-capability-reflection
head = fee4d5efee2131ecb0eb9cccb19250752f51e25e
```

and a branch comparison established:

```text
moat-005-live-federation-proof
    is an ancestor of
feature/grpc-capability-reflection
```

The merge commit has both expected parents:

```text
5f37e64b3294f50ddca0a42dff745f40125697bc
f87875de7c20fc1dc7ca8b4d71b9f2cbd8ff6b1f
```

## Why this matters

This is a self-hosting example of the RIGHTCLICK architecture:

```text
provider exposes a compatible contract
        ↓
RIGHTCLICK reflects the operation
        ↓
the AI discovers one generic capability
        ↓
authority is resolved outside model arguments
        ↓
context_run executes it
        ↓
provider acceptance remains unverified
        ↓
independent observation establishes the state change
```

There is no `github_merge_branch` top-level MCP tool in RIGHTCLICK.

GitHub is one capability provider behind the same generic runtime.
