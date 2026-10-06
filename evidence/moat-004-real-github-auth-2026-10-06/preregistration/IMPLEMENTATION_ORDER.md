# MOAT-004 GREEN implementation order

The implementation must proceed in this order.

## G1 — bounded large OpenAPI acquisition

Permit a larger bound only for OpenAPI specification acquisition.

The generic HTTP document default must remain 1 MiB.

Target OpenAPI cap: 16 MiB.

No other compatibility changes.

## G2 — split specification and execution origins

Add a generic absolute-HTTPS advertisement mode:

- `spec-url`
- `base-url`

Both values must be present together.

Legacy relative advertisements remain unchanged.

Specification acquisition remains pinned to the specification origin.
Execution remains pinned to the base origin.

If a supported literal `servers` declaration exists in the contract, it must
agree with the advertised execution base.

## G3 — zero-argument GET

Support GET operations with:

- no path template;
- no path-level parameters;
- absent or empty operation parameters;
- no request body.

Execution sends no body and no Content-Type header.

## G4 — read-only JSON syntax fallback

For GET only:

If the response is declared `application/json` but its schema is outside
RIGHTCLICK's narrow strong schema validator, RIGHTCLICK may reflect the
operation with `json_syntax_only` result validation.

The provider must still return valid JSON.

Mutating operations do not gain this fallback.

## G5 — generic external bearer authority

Permit a discovery-side generic HTTP bearer requirement when the OpenAPI
contract leaves security unspecified.

The bearer secret remains in the existing exact-origin Keychain boundary.

Contract-declared supported security takes precedence.
Explicit `security: []` remains public.
Unsupported declared security remains unsupported.

## G6 — frozen GitHub compatibility test

Run the exact official frozen GitHub contract through the generic implementation.

The target capability must appear as:

`Get the authenticated user`

No GitHub-specific production condition is allowed.

## G7 — actual ChatGPT live gate

Through the ordinary seven-tool RIGHTCLICK connection:

1. discover the real GitHub capability;
2. explain its generic authority metadata;
3. execute `GET /user`;
4. observe the correct authenticated user;
5. prove the bearer credential never crossed MCP.

No release or merge until this gate succeeds.
