# MOAT-005 G3 — safe narrowing of a real mutation request schema

## Frozen source

The request schema in the G3 fixture is derived from the frozen official
GitHub `issues/create` operation.

Only two already-proven dimensions are normalized:

- path routing uses G2's strong required-string `owner` + `repo` subset;
- response handling uses an existing closed JSON response.

The request body schema is the deep-resolved real GitHub request schema.

## Problem

The real request object is richer than RIGHTCLICK's original strong
closed-string-object slice.

Notably:

- `title` is required and expressed with `oneOf`;
- `body` is a string;
- some optional fields are arrays;
- some optional fields are integers or other unions;
- the object does not declare `additionalProperties: false`.

## Required G3 semantic

RIGHTCLICK may safely expose a STRICTER input contract than the provider
accepts.

It may project the real request schema to a closed subset when:

1. every provider-required property can be represented safely;
2. unsupported OPTIONAL properties are omitted from the AI-facing schema;
3. a property union may be narrowed to one unambiguous supported string
   branch;
4. RIGHTCLICK's exposed schema always has `additionalProperties: false`;
5. unknown or omitted unsupported fields cannot pass through transport.

For `issues/create`, G3 must expose at minimum:

- owner — required string path argument
- repo — required string path argument
- title — required string request field
- body — optional string request field

Arrays and integer-only optional fields must not become loosely typed
arguments.

## Safety interpretation

This is narrowing, not weakening.

Every request RIGHTCLICK accepts must remain valid under the provider
contract. RIGHTCLICK is not required to expose every input shape the
provider accepts.

## Boundary

G3 does NOT yet require the real GitHub response schema to be supported.

No real provider request.
No GitHub credential.
No issue creation.
