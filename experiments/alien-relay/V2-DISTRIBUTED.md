# RIGHTCLICK Distributed Alien Network v2 (experimental)

This experiment is a three-runner cloud proof, not a production release or a
claim that the full RIGHTCLICK runtime runs natively on Windows.

**Ubuntu issuer A -> separate Windows executor B -> independent Ubuntu verifier C**.

The parent obtains a fresh Ed25519 key, signs an immutable parent receipt and
a single-use, 45-minute **platform.inspect** lease scoped to the Windows child.
The private issuer key never leaves A. GitHub Actions transfers only public
evidence and signed delegation artifacts. B verifies the signature, run and
commit binding, audience, expiry, operation and budgets *before execution*.
It enumerates the Windows PowerShell Get-* provider contracts, picks an
available read-only operating system capability, executes it, and independently
checks Windows identity using Python. B signs the result digest with a new
ephemeral child key. C verifies both signatures, the parent and lease hashes,
result digest, allowed scope, per-hop budgets and all denial tests.

The experimental Python delegator is
`experiments/alien-relay/v2_distributed.py`.
The machine-readable policy is
`skills/rightclick/procedures/distributed-capability-delegation.v2.json`.
The cloud workflow is
`.github/workflows/distributed-alien-network-v2.yml`.

## Evidentiary bar

Success requires all three separate GitHub-hosted jobs to run successfully,
a concrete Windows capability selected from runtime discovery, a real
read-only Windows invocation, a separately measured Windows postcondition,
seven fail-closed negative controls, and an independent verifier producing
`verified-receipt-chain.json` with `verified_success: true`.
A workflow green badge without this artifact is insufficient.

Negative tests cover forged lease data, scope escalation, audience confusion,
expiration, admission-time revocation, replay and **simulated** disappearance.
They don't establish production-grade live remote revocation or physical
removal of a Windows provider.

The parent key is rooted in the GitHub Actions issuer artifact rather than a
pre-pinned enterprise identity. The child is a portable experiment executor,
not native Windows RIGHTCLICK Core7, and discovery is constrained to a safe
PowerShell cmdlet family. Do not describe it as a general self-propagating
agent network or production-ready cryptographic authority service.

## Operational boundaries

Exactly seven RIGHTCLICK AI-facing operations remain unchanged. The
agent-facing RIGHTCLICK surface and the experiment's internal executable are
distinct: GitHub Actions invokes Python scripts as remotely delegated work;
no new top-level AI tool has been exposed.

Only this isolated branch is used. The workflow has `contents: read` and does
not request secrets, repository writes, new permissions, releases, merges or
deployment environments. Retry/depth/fanout limits are explicit.

Run locally where Python + cryptography is available:

```bash
python3 experiments/alien-relay/v2_distributed.py selftest --output-dir v2-selftest
```

Read GitHub Actions run IDs and three uploaded artifacts; independently verify
the Git SHA and signed receipt chain before claiming success.
