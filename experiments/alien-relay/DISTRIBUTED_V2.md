# RIGHTCLICK Distributed Alien Network v2 — experimental protocol proof

## Question

Can one remote execution environment delegate a narrower, time-limited read-only
capability to another operating system, then obtain independently verifiable
cryptographic evidence of that second environment discovering an external AI
capability, without adding provider-specific AI-facing tools?

## Chain

1. **Ubuntu parent job:** issue ephemeral Ed25519 signed delegation, bound to the
   exact GitHub run and repository, Windows child audience, single HTTPS origin,
   POST /search, `image generation` query, one request, 25-second timeout,
   maximum 500 KB response, 20-minute validity.
2. **Windows child job:** verify the parent's signature and authority constraints;
   prove forbidden endpoint, revocation, expiry, replay, and empty registry are
   rejected *before* any out-of-scope network action. Query the Hugging Face ARD
   service using generic JSON-over-HTTPS and dynamically select a returned AI
   capability from its live machine-readable response. Sign a receipt with a
   fresh independent Ed25519 key, and retain the raw JSON response.
3. **Independent Ubuntu verifier job:** verify the signatures and hash links,
   check runtime identities as **observations**, enforce no widened scope, parse
   the external JSON response again, check exact artifact byte digest, and
   emit `verdict.json` (success only if all gates pass).

No secrets, deployments, repository permissions or releases are modified. Every
job is ephemeral, with `contents: read` and a small timeout.

## Reproducibility

Runs automatically on pushes to `experiment/distributed-alien-network-v2-20261007`:

`/.github/workflows/distributed-alien-network.yml`

Unit tests (requires `cryptography`):

```bash
python -m unittest discover -s experiments/alien-relay -p 'test_*.py' -v
```

Artifacts are retained for seven days: delegation, signed receipt, raw provider
response and independently computed final verdict. All failed attempts stay
visible. *HTTP acceptance is not a verified result.*

## What remains unproven

This is **not yet** proof of a native RIGHTCLICK runtime on Windows. The
experiment uses a portable Python protocol harness and the familiar seven
operation names as an interface budget; it does not execute those seven MCP
operations in the Windows child. The external **registry bootstrap** is seeded,
but the **AI skill** selected from it is learned at runtime.

Signatures are cryptographically sound but key identity is not anchored to a
hardware or cloud provider attestation; GitHub Actions provides the workflow
identity observation. Revocation is shown within a running process, not a
cross-organisation live revocation registry. Exact independent byte read-back
is tested, but there is no independent second live read from Hugging Face.

Only promote this to a universal-runtime v2 claim when a real RIGHTCLICK
Windows/Linux adapter is executing, public keys have trusted origin binding,
and an independent remote host attests the full chain.
