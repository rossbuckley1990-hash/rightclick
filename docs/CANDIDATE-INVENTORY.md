# Reviewer inventory: reconciled portable candidate

The active reconciliation branch is `feature/reconcile-portable-v023`, based on
PR #99 `6a18aaae3ae3a15b9f6c78f189adc695ae11585a`, incorporating the exact
PR #49 input `053b6202df504ff1a33682a39f2e72a959f65983`. Neither PR has been
merged or released by this task. Stable remains unchanged.

The current module map and source-by-source migration are in
[RECONCILIATION-DESIGN.md](RECONCILIATION-DESIGN.md) and
[reconciliation-migration.json](reconciliation-migration.json). The enforced
[substrate contract](substrate-contract.json) checks actual callable compiler and
runtime source registrations; source presence alone is not execution proof.
A2A/Kafka/Kubernetes/WASM and generic D-Bus compilation now live in Providers.
Native D-Bus discovery and host execution live in RightClickLinux. Native Mac
Services/sharing remain in RightClickMacOS. Shared ABI/authority/task/receipt
contracts live in Protocol, orchestrated by Core and its single RCIR host.

The following is retained historical evidence from 2026-10-07. Its older heads,
monolithic paths and test counts are not results for the reconciled tree.

## Historical reviewer snapshot

A reflector can be implemented in an active candidate while remaining absent from main and the installed runtime. Reviewers must inspect all three identities before describing availability. This table is an implementation inventory; it is not an eleven-substrate acceptance scorecard.

Delivery snapshot on 2026-10-07:

| Identity | Exact scope |
| --- | --- |
| Main | `33fc2c33f70445e47104c4e8abc0d91987ec2b4e`; reviewed documentation/evidence landed, with no direct A2A/Kafka/Kubernetes/WASM/D-Bus compiler files at this SHA |
| Active universal candidate | [PR49](https://github.com/rossbuckley1990-hash/rightclick/pull/49), `e09f0179f738189fb30b87c652a5433fba648054`; implemented candidate compilers and reconstructed bounded executable reuse below, draft and undergoing native checks |
| Attested installed/connected stable runtime | 0.2.2, executable SHA256 `d31419fafc96e08c4a2db9d1b389320acb2835c1a901597244249772d7ac489d`; Core7 was actually observed. Candidate source is not inferred from the version label |

Refresh these values for every review; they are snapshots. Read current main and PR head via GitHub/Git, inspect each file at the exact ref, and call the connected `context_runtime`. Record binary bytes and transport, then inspect current providers/capabilities. A file, descriptor, fixture, successful unit test or CI provisioned service does not prove a live operation.

| Substrate | Generic acquisition source in PR49 | Evidence boundary |
| --- | --- | --- |
| A2A | `Sources/RightClickCore/A2AReflector.swift` | Agent-card/task reflection into shared RCIR; retained engineering lifecycle evidence has exact byte scope. Fresh CI startup failure remains distinct from successful older proofs |
| Kafka | `Sources/RightClickCore/KafkaCapabilityArtifactResolver.swift` | Shared compiler and invocation-bound observation. Reconstructed generic executable reuse/data-free diagnostics have fresh source controls; six original diagnostic logs survived. Earlier matched pressure/receipt reports remain historical because their raw JSON/transcripts/manifests are unavailable after the local checkouts disappeared. Historical ready-to-unavailable cause and fresh live acceptance remain RED |
| Kubernetes | `Sources/RightClickCore/KubernetesCapabilityArtifactResolver.swift` | API contract compilation and independent scoped read-back; provisioned lab/RBAC does not alone establish native product or issuer brokerage acceptance |
| WASM | `Sources/RightClickCore/WASMCapabilityArtifactResolver.swift` | Shared descriptor/component boundary; actual component proof is distinct from skipped or missing fixture controls |
| Linux D-Bus | `Sources/RightClickCore/DBusSessionSource.swift`, `DBusIntrospection.swift`, `DBusCapabilityArtifactResolver.swift` | Direct bus metadata acquisition compiles into the existing engine; native bus tests/owner withdrawal have exact-source scope, not all Linux acceptance |

The existing Mac Services/sharing, REST/OpenAPI, GraphQL, supported unary gRPC and MCP/federation paths must also be inspected rather than replaced. The model-facing contract remains exactly `context_runtime`, `context_inspect`, `context_providers`, `context_actions`, `context_explain`, `context_run` and `context_run_status`.

Native Windows direct acquisition has not been demonstrated. Earlier protected-reference failures are retained. Exact-byte/ownership/collision/junction C controls pass; `e09f017` native CI passes nine protected-reference tests, then fails the full suite: 512 tests, 78 skips, 81 failures (68 unexpected). Interpreter lookup, protected fixture creation and other file/authority boundaries require actual repair. Empty SDDL from the selected PowerShell setup does not yet establish actual present-and-NULL DACL identity. Full native Windows release/Core7 and independent native acquisition evidence remain separately required.

Native Linux source `e09f017` passes 578 tests with 28 skips and no failures, builds release binary SHA256 `31c4f5c4fb863b3a12be9f3007913e4845d19a3f571ab680ccf8038ef4e39980`, and passes actual stdio/authenticated HTTP Core7 invocation/status/provenance controls. Those configured effects do not establish every direct Linux contract. The same head's portable Mac run executes 789 tests with 35 skips and one revoked-reference outcome assertion failure; two A2A CI acceptance jobs fail during provider fixture startup with the cause unproven. Recovered source `4533b619` has a fresh 14-control Mac gate (7 snapshot pool controls, 3 process diagnostics and 4 protected reference controls; no skips/failures), distinct from live provider acceptance.

Full native authority/policy, independent causality, production credential/signing trust, streaming, live graph mutation on every substrate, restricted fresh-agent eleven-row acceptance and fresh release/install gates remain independently required. No skipped control establishes GREEN.

Report each result as implementation present, merged, installed or actually demonstrated, citing the matching source/binary and evidence. Active draft implementations are real work; they are not shipped capabilities. All compilers continue through one product/runtime and shared RCIR. Do not add provider-specific AI tools to make a row appear complete.
