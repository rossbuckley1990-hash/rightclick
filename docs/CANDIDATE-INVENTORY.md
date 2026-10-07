# Reviewer inventory: source, candidate and connected runtime

A reflector can be implemented in an active candidate while remaining absent from main and the installed runtime. Reviewers must inspect all three identities before describing availability. This table is an implementation inventory; it is not an eleven-substrate acceptance scorecard.

Delivery snapshot on 2026-10-07:

| Identity | Exact scope |
| --- | --- |
| Main | `d953f1a34675a65cf47abd67c4d678069b6536b5`; no direct A2A/Kafka/Kubernetes/WASM/D-Bus compiler files at this SHA |
| Active universal candidate | [PR49](https://github.com/rossbuckley1990-hash/rightclick/pull/49), `38b27e45e9f566588b398ace20ca3ed07a529da3`; implemented candidate compilers below, draft and undergoing native checks |
| Attested installed/connected stable runtime | 0.2.2, executable SHA256 `d31419fafc96e08c4a2db9d1b389320acb2835c1a901597244249772d7ac489d`; Core7 was actually observed. Candidate source is not inferred from the version label |

Refresh these values for every review; they are snapshots. Read current main and PR head via GitHub/Git, inspect each file at the exact ref, and call the connected `context_runtime`. Record binary bytes and transport, then inspect current providers/capabilities. A file, descriptor, fixture, successful unit test or CI provisioned service does not prove a live operation.

| Substrate | Generic acquisition source in PR49 | Evidence boundary |
| --- | --- | --- |
| A2A | `Sources/RightClickCore/A2AReflector.swift` | Agent-card/task reflection into shared RCIR; retained engineering lifecycle evidence has exact byte scope. Fresh CI startup failure remains distinct from successful older proofs |
| Kafka | `Sources/RightClickCore/KafkaCapabilityArtifactResolver.swift` | Shared artifact/compiler and invocation-bound observation; isolated real effect evidence exists, concurrent acquisition stability remains unresolved |
| Kubernetes | `Sources/RightClickCore/KubernetesCapabilityArtifactResolver.swift` | API contract compilation and independent scoped read-back; provisioned lab/RBAC does not alone establish native product or issuer brokerage acceptance |
| WASM | `Sources/RightClickCore/WASMCapabilityArtifactResolver.swift` | Shared descriptor/component boundary; actual component proof is distinct from skipped or missing fixture controls |
| Linux D-Bus | `Sources/RightClickCore/DBusSessionSource.swift`, `DBusIntrospection.swift`, `DBusCapabilityArtifactResolver.swift` | Direct bus metadata acquisition compiles into the existing engine; native bus tests/owner withdrawal have exact-source scope, not all Linux acceptance |

The existing Mac Services/sharing, REST/OpenAPI, GraphQL, supported unary gRPC and MCP/federation paths must also be inspected rather than replaced. The model-facing contract remains exactly `context_runtime`, `context_inspect`, `context_providers`, `context_actions`, `context_explain`, `context_run` and `context_run_status`.

Native Windows direct acquisition has not been demonstrated. Earlier native Windows protected-reference controls failed; the strict creation/path repair is undergoing actual native verification. Native Linux builds and configured Core7 effects do not establish all direct Linux contracts. Full native authority/policy, independent causality, production credential/signing trust, streaming, live graph mutation on every substrate, restricted fresh-agent eleven-row acceptance and fresh release/install gates remain independently required. No skipped control establishes GREEN.

Report each result as implementation present, merged, installed or actually demonstrated, citing the matching source/binary and evidence. Active draft implementations are real work; they are not shipped capabilities. All compilers continue through one product/runtime and shared RCIR. Do not add provider-specific AI tools to make a row appear complete.
