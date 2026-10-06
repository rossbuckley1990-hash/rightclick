# MOAT-003 — Generic HTTP Bearer Authority

Base commit:

`b9361d3f19abab7bc7916a08f81687a52cb3f2b9`

Product commit:

`5ec291f0e9b85d10511989bc8f70cf3b2274d6de`

## Claim

RIGHTCLICK can interpret a supported operation-level OpenAPI HTTP bearer
security requirement, reflect a generic authority requirement, resolve the
credential outside the AI-facing MCP interface from an exact origin-bound
macOS Keychain item, and inject the credential only at the HTTP transport
boundary.

The same running RIGHTCLICK candidate was observed in three states:

1. exact authority absent → UNAVAILABLE before provider transport;
2. exact authority present → provider request succeeded and returned result was verified;
3. authority removed → UNAVAILABLE again before provider transport.

No bearer secret was supplied through MCP.

## Supported slice

This evidence does not claim arbitrary OpenAPI authentication.

Supported in this milestone:

- operation-level `security`;
- exactly one security requirement alternative;
- exactly one security scheme in that requirement;
- OpenAPI security scheme type `http`;
- HTTP scheme `bearer`;
- empty scopes;
- exact canonical origin binding;
- macOS Keychain generic-password lookup.

Keychain service:

`ai.rightclick.openapi-authority`

Account shape:

`http-bearer|<canonical-origin>|<security-scheme-name>`

Unsupported authentication shapes abstain rather than guess.

Root-level inherited security is not implemented in this milestone unless the
operation explicitly supplies `security: []`, which remains a public override.

## Verification boundary

The live authorized call verified the exact provider-returned JSON result.

That verifies the returned-result postcondition only. It is not a claim of an
independently observed durable external side effect.

## MCP surface

The AI-facing MCP interface remains the same seven generic tools.

No provider-specific MCP tool was added.

## Public evidence sanitisation

The temporary provider URL, temporary provider hostname, temporary account
label, and claim URL are removed from this public bundle.

The original private artifact hashes are retained so the sanitised public
evidence can be related to the locally frozen experiment without publishing
temporary provider identity material.

The real bearer secret is not included.
