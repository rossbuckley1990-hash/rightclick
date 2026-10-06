# MOAT-005 G5 — full frozen GitHub contract compatibility

G1 through G4 proved generic primitives using focused fixtures.

G5 removes those fixture boundaries.

RIGHTCLICK must consume the complete pinned official GitHub REST API
description through its normal OpenAPI acquisition path and dynamically
discover the real `issues/create` operation.

No provider invocation is permitted.

## Required capability

Operation:

    issues/create

Title:

    Create an issue

Method/path:

    POST /repos/{owner}/{repo}/issues

The AI-facing argument schema must be closed and contain exactly:

Required:

    owner
    repo
    title

Optional:

    body

Unsupported optional provider fields must remain absent.

## Authority

The contract itself does not declare the bearer policy required for this
experiment.

G5 therefore supplies RIGHTCLICK's generic external, origin-bound bearer
authority configuration:

    scheme: MOAT005G5Bearer
    origin: https://api.github.com

No credential is installed or used by this gate.

## Response

The real GitHub 201 response is richer than RIGHTCLICK's structural
response model.

The operation must therefore expose:

    resultValidation = json_syntax_only

and must not expose a structural `resultSchema`.

## Meaning

A G5 GREEN proves the generic changes from G1-G4 compose against the
untouched full official provider contract.

It does not prove a live mutation.

No call to api.github.com is permitted.
