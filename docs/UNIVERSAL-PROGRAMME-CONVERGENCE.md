# Universal-runtime convergence

The revised master objective is the eleven-world runtime through exactly seven
canonical AI operations. Additional capability-language compilers are deferred
until its restricted-agent acceptance is GREEN.

The existing convergence branch `feature/universal-async-proof-20261007` (PR #49)
remains the integration target. `feature/universal-programme-core-20261007` is an
isolated validation/staging branch based on its audited source
`2dd7bd2fafbbaa994812d1bc904730b74aa74816`; it introduces no second architecture.
The baseline audit used main `28de3d8396fc7f144e6734eb6923cdc7219d5c5d`.
The subsequent ref refresh recorded main
`d953f1a34675a65cf47abd67c4d678069b6536b5` and convergence head
`38b27e45e9f566588b398ace20ca3ed07a529da3`. The latter adds native Windows
reference repairs. The baseline results below still identify the exact frozen
`2dd7bd2` candidate; they do not validate the newer source. Refresh identities
before subsequent integration. Existing active worktrees and their uncommitted
changes remain owned by their original workstreams.

## Convergence decisions and ownership

The repository snapshots in `evidence/universal-programme-20261007/` retain
open-PR and branch identities. Those snapshots are historical audits, not a
claim that the queues remain unchanged. PR #49's owner coordinates its integration
and native CI. Focused work is stacked on that branch for review.

| Existing work | Decision | Remaining boundary |
| --- | --- | --- |
| PR #49 portable/common runtime | Retain as the sole convergence target | Native repairs, full generic lifecycle and final acceptance remain incomplete |
| PRs #37, #51 and #52 portable variants | Preserve unique tests and useful intent; do not add another permanent runtime | Compare each change with the existing host before integration |
| PR #35 reviewed contract pins | Preserve caller-held binding intent and controls using the existing contract type and canonicalizer | Optional fingerprints do not grant authority or reject identical reincarnations |
| ABI002a wrapper prototype | Preserve as historical comparison | Do not layer a second engine around the existing common host |
| PR #44 receipt verifier | Already incorporated into the convergence candidate | Production trust policy and independent observations still require review |
| Native Windows repair | Owned by the convergence team; newer head includes it | Direct Windows acquisition and native end-to-end proof remain RED |
| gRPC streams and Kafka acquisition | Owned by the convergence team | Retain frozen pressure controls; share the existing lifecycle |
| Contract binding and crash journal | Focused changes owned by this workstream | Public boundary and crash/recovery controls must pass before integration |
| Setup, doctor and provider connections | Owned by the adoption workstream | Validate rollback, authority isolation and serving-runtime identity |
| Additional capability languages | Deferred | The eleven-world restricted-agent prerequisite must pass first |

## Shared interfaces and order

Retain `CapabilityValue`, `CapabilitySchema`, `CapabilityContract`, `RCIRContract`,
`RCIRAdmission`, `RCIRExecutionHost` and the existing source/resolver/reflector
composition. Do not merge competing canonicalizers, wrapper engines or task
engines. Provider layers acquire declarations and supply transport; the common
host owns policy, authority, execution, observations and receipts.

1. Audit current main, every open PR and relevant local/remote branch overlap.
2. Complete shared typed contract bindings and crash/uncertainty persistence.
3. Converge existing native Windows/Linux and substrate paths, preserving REDs.
4. Finish native acquisition, structured GraphQL/protobuf types, real streaming,
   Kafka consumer/subscription and dynamic Kubernetes CRD/watch boundaries.
5. Independently perform the same-session, seven-operation, eleven-world proof
   and adversarial controls. Implementation agents cannot promote their own rows.
6. Pass reviewed main/platform/security/release/distribution/clean-install gates.
7. Expand capability-description frontends through the accepted shared ABI.

The current workstream seams are caller-held discovery fingerprints in the
existing Engine/MCP boundary, and a host-owned durable invocation journal. The
journal must write a durable dispatch intent before final fresh admission and
enqueue, fail closed on persistence failure, and recover uncertain invocations
as UNKNOWN without replay. It stores identity/digests/status, not credentials or
invocation payloads. Supported native storage backends must be explicit.

## Completion matrix and evidence gate

[`universal-substrate-scorecard.json`](universal-substrate-scorecard.json) tracks
all eleven worlds and all ten required dimensions. Its source references and
supporting evidence are hash-pinned. Every row is currently RED at the programme
acceptance boundary. Genuine engineering proofs are supporting evidence, never
substitutes for the restricted AI experiment.

Run `python3 scripts/check-universal-scorecard.py` to validate the structure and
evidence hashes. Run it with `--require-green` as an acceptance prerequisite
before universal release or capability-language expansion; it must fail while
any row remains RED. The separate release checklist remains mandatory. CI's
structure check intentionally permits an honest RED inventory. Its success does
not mean universal acceptance passed.

A GREEN acceptance manifest must identify a fresh restricted AI, its actual
seven-operation model-visible catalogue, one live session, exact source and
serving-binary digest, a pinned runtime attestation and matching binary bytes,
and per-world real acceptance, independent observations, receipt verification,
withdrawal and stale-binding denial evidence. Each typed proof report must bind
its world, role, session, source and binary and pin its supporting artifacts.
GREEN stages must link to those matching proof roles. Required A2A, gRPC, Kafka
and Kubernetes task/stream evidence cannot be marked inapplicable. Evidence
references cannot escape the repository or silently change bytes. Protected
reads use POSIX directory handles and refuse symlink and hard-link aliases.
Distinct proof artifacts are compared by opened file identity, including on
case-insensitive macOS filesystems. The structural gate runs on macOS/Linux;
native Windows evidence is assessed there rather than using an unsafe file-open
fallback. This validator
checks structure and declared provenance consistency; independent reviewers must
still assess the observations, signatures, authority boundaries and real effects.
Consistent report fields cannot establish that an AI was restricted, that a
binary was built from its claimed source, or that an external effect occurred.
The positive fixture in the gate's tests is explicitly synthetic and establishes
only complete structural input. It is never programme acceptance evidence.

## Baseline result

The audited candidate's full native regression passed 775 tests with 31 explicit
environment-dependent skips and zero failures. Raw output and exact source are
retained in `evidence/universal-programme-20261007/`. The immutable copied debug
binary has SHA-256
`80f5e7875f84deaeeeb04ced3f5d2d7137ad046a0a8af8a91887532253f1100a`.
Skipped real-provider gates establish no substrate GREEN. This source build is
separate from installed Stable 0.2.2 and the actual connected runtime.

The unchanged gRPC pressure test from `6795dc594ae07185edc62e6c3b9a329b97ea7173`
was replayed on that frozen candidate against a real reflection-enabled gRPC
server. Its independent native control received three messages. RIGHTCLICK
returned `unsupported` without task evidence, producing two expected assertion
failures. This is an engineering RED, not a restricted-agent acceptance run.

The gate's first nine tests were written with its initial implementation. A
separate reviewer then froze nineteen adversarial tests before the fixes: the
pre-fix run produced 31 subtest failures and one error. Its exact source was
reconstructed afterward from the transcript, matched the previously logged hash,
and reproduced that RED. The reconstruction manifest records that chronology;
it is not a contemporaneously retained source commit. Six additional frozen
controls found eight path-alias/number-overflow failures; another frozen native
Mac control found case-insensitive artifact reuse. Two post-fix controls check
actual file-open replacement and hard-link rejection. All 37 tests passed after
the fixes. These tests validate evidence structure and denial behavior, not real
substrate effects.

No release, tap update, installed upgrade, or final eleven-world success is
claimed by this convergence increment.
