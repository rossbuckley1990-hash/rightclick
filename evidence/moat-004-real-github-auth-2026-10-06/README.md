# MOAT-004 — Real GitHub Authenticated Capability

## Goal

Determine whether RIGHTCLICK can acquire and execute a useful authenticated
capability from a real third-party OpenAPI contract without GitHub-specific
production code.

Target:

- provider: GitHub REST API
- operation: `GET /user`
- operationId: `users/get-authenticated`
- summary: `Get the authenticated user`

## Frozen RED

RIGHTCLICK main:

`84bebb44a198e19d7d1eba00e80c175974e14756`

GitHub's official OpenAPI contract was frozen independently by upstream commit,
Git blob SHA, byte count and SHA-256.

Authenticated GitHub control succeeded without printing the token.

The current RIGHTCLICK runtime did not reflect the target capability.

## Confirmed incompatibilities

1. The official OpenAPI JSON is 12,901,084 bytes while the current generic
   acquisition boundary is 1 MiB.

2. The official contract is hosted separately from the execution origin
   `https://api.github.com`.

3. `GET /user` takes zero capability arguments. Current RIGHTCLICK GET support
   requires exactly one required string path argument.

4. GitHub's successful response schema uses `oneOf`, local `$ref` values and a
   discriminator. Current RIGHTCLICK only supports its narrow closed inline
   JSON object response slice.

5. GitHub does not declare the endpoint's bearer authority through OpenAPI
   `security` / `securitySchemes`. Authentication is documented separately.

## Claim boundary

This RED does not prove that arbitrary third-party APIs are unsupported.

It proves that this exact, frozen, real GitHub contract is outside the generic
compatibility slice implemented by the frozen RIGHTCLICK main commit.

No production source was modified to obtain the RED.

## Next phase

The GREEN phase must close these boundaries generically.

It must not:

- contain GitHub-specific production branches or operation IDs;
- expose bearer credentials through MCP;
- disable origin pinning;
- allow redirects to expand authority;
- turn unsupported mutating schemas into permissive execution;
- change the seven-tool MCP surface merely to support GitHub.
