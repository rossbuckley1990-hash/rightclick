# Reviewer inventory: reconciled source and serving runtime

A source file establishes implementation presence. A release asset, installed
binary and an observed execution establish different facts. Record each identity
before describing a capability as available. This inventory is not the eleven
substrate acceptance scorecard.

Reconciliation snapshot on 2026-10-08, after the first exact-source CI wave exposed portable build and owned fixture failures; the reviewed repair candidate awaits fresh CI and public distribution gates:

| Identity | Exact scope |
| --- | --- |
| Remote main | `381a87b53dbd0046f1acef1984587199da0e630c`; the direct A2A, Kafka, Kubernetes, WASM and D-Bus compiler files below are absent at this SHA |
| Remote universal candidate | [PR49](https://github.com/rossbuckley1990-hash/rightclick/pull/49), `045d4940f52d39768d2c691e04b659716e08f128`; the reviewed portable composition is published. Its first native CI wave exposed the stale Linux process callsite, Swift 6.2 manifest inference and protected-reference fixture parent aliases |
| Remote portable candidate | [PR99](https://github.com/rossbuckley1990-hash/rightclick/pull/99), `6a18aaae3ae3a15b9f6c78f189adc695ae11585a`; extracts the existing engine into portable modules, with macOS adapters and Linux composition |
| Reviewed repair composition | `76a3852e52d28540cccbf7ff32a00965c0b5b0a5`, Sources `1122145c99f43fefa859643632c839b7156e0bfa`, Tests `2371a0d45ef2f4c4d14dc555cd065b839f9d2dd2`; retains the frozen403 foundation, all profile/process/authority repairs and 045 ancestry. The typed manifest, one thin Linux initializer label and ten owned producer parent resolutions are independently reviewed. Fresh native and provider CI remains required |
| Earlier composed Mac proof | `fe10f424e5584cd3e2c6a5cf1fcc9eacdb0ecc48`, Sources `6c624ad4503999360938fa0c8c083010f9fad7c0`, same Tests tree; actual complete Mac run 1107 = 1076 PASS, 31 SKIP, zero FAIL. This is a preserved source-bound result, not a claim that the newly composed manifest/Linux/script bytes were tested |
| Installed and connected stable runtime | v0.2.2, serving PID `67552`, executable SHA256 `d31419fafc96e08c4a2db9d1b389320acb2835c1a901597244249772d7ac489d`, stdio; observed through `context_runtime` on 2026-10-08. This does not attest to candidate source |

These remote and process values are snapshots. Refresh main, both PR heads,
release/tap state and the actual connected `context_runtime` during each review.
A version label or plugin metadata does not identify the serving executable.

## Implemented acquisition in the reconciled source

| Substrate | Direct source path | Composition and evidence boundary |
| --- | --- | --- |
| A2A | `Sources/RightClickProviders/A2AReflector.swift` | Configured agent-card discovery enters `RightClickCore/CapabilityRuntimeDefaults.swift` and the existing RCIR lifecycle. Actual 252 lifecycle/receipt proof is historical until repeated against the final composed build |
| Kafka | `Sources/RightClickProviders/KafkaCapabilityArtifactResolver.swift` | Shared artifact resolver and bounded executable acquisition; a provisioned topic or prior test does not establish final product authority, receipts or graph mutation |
| Kubernetes | `Sources/RightClickProviders/KubernetesCapabilityArtifactResolver.swift` | Shared discovery/compiler and independently scoped read-back; lab/RBAC readiness alone is not runtime acceptance |
| WASM | `Sources/RightClickProviders/WASMCapabilityArtifactResolver.swift` | Shared descriptor/component boundary. The packaged `examples/universal-descriptors` fixtures must be exercised by the final native binary |
| MCP descriptors | `Sources/RightClickProviders/MCPCapabilityArtifactResolver.swift` | Generic descriptor reflection and the same Core7 dispatcher; federation remains in `RightClickMCP` |
| Linux D-Bus | `Sources/RightClickLinux/DBusSessionSource.swift`, `RightClickProviders/DBusIntrospection.swift`, `RightClickProviders/DBusCapabilityArtifactResolver.swift` | Linux bus acquisition compiles into the existing engine; native UID policy, separate signature verification and owner withdrawal must retain exact build scope |

The existing native Mac Services/sharing, REST/OpenAPI, GraphQL and supported
unary gRPC paths remain part of the same composition. Native Apple acquisition
lives in `RightClickMacOS`, portable providers in `RightClickProviders`, shared
contracts in `RightClickProtocol`, and the original engine in `RightClickCore`.
The Link library is an embedding foundation; it does not provide a shipped
internet relay or automated enrollment.

The model-facing profile remains exactly `context_runtime`, `context_inspect`,
`context_providers`, `context_actions`, `context_explain`, `context_run` and
`context_run_status`. No provider-specific AI operations are added.

## Proof scope before publication

The previous 252/DFD candidate has a full native Mac result of 1005 tests
(970 passed, 35 skipped, zero failed), a Linux x86_64 result of 779 tests
(751 passed, 28 skipped, zero failed), and separate actual D-Bus, A2A and MCP/WASM
proofs. Their source, artifacts and independent audits are retained. They do not
attest to the reconciled source. The fresh fe10 Mac run independently passed1107
cases (1076 passed,31 skipped,zero failed), preserving all970 previous252 passes.
Four previously skipped native NS008 cases actually passed. The current result is
source-bound by444 unchanged physical Git inputs and frozen executable SHA256
`d35b4ece7ea1893142a067f96dc595162578cc749e232f18f9e1e13c9066b5b4`.
The independent full Mac audit is SHA256
`713504c4c5e3201476629c6c15984fcebd45392a6ab5927d012e310cf7e50961`.
Fresh native Linux x86_64/arm64 and provider lifecycle, authority, verification
and receipt gates remain pending. Valid-trust HTTPS bearer/redirect acceptance
remains RED; the new invalid-certificate negative is a separate passing control.


The first 045 CI failures are retained: native Linux builds failed before tests at
the obsolete `CapabilityExecutableProcess(source:)` initializer label, and Swift
6.2 ARD gates failed while type-checking the manifest. The reviewed fixes preserve
the shared API and original product/dependency/target expressions. The protected
reference backend correctly rejected owned fixture files beneath lexical temporary
aliases. Four unchanged-binary controls (A2A, OpenAPI, live schema refresh and
portable Core7) each measured fail → pass → fail when only the producer-owned
parent was resolved before provisioning. Untrusted authority references and every
other assertion remain unchanged. These controlled positives do not establish
fresh native Linux, current CI or installed distribution acceptance.

Windows is not a supported v0.2.3 release host. Actual protected-reference and
native environment-boundary controls have been run, and authority failures were
repaired. The 252 full Windows run still had six compiler acquisition failures;
the measured SDK dependency and remaining full-runtime/direct-reflection proofs
remain explicit engineering work. Unsupported release scope does not turn these
failures or the Windows goal row GREEN.

Source method retention includes1127 distinct names from both PR99 and252, with
three intentional mappings: conflicting policy identities are quarantined rather
than resolved by first arrival; Windows SDK acquisition uses measured explicit
bounded system search; and the former default five-second specification test
retains its assertions with an explicitly selected five-second budget while the
host specification default becomes a finite30seconds. Ordinary HTTP reads remain
5seconds and invocations remain bounded by10seconds. Source mapping does not
imply unchanged assertions or execution: the SDK mapping remains Windows source
scope. Actual Mac case retention is separately recorded with its executed-name
mapping. [Historical proof paths](HISTORICAL-PROOF-INDEX.md) retain their original
source dates and do not attest to this release.

The packaged kind detector inventories 21 implementation kinds. Zero missing
kinds proves source/package alignment, not all eleven substrates or a live provider
graph. Final source archive, immutable public assets, trusted bottle provenance,
fresh installation, pairing preservation and a new serving PID/accepted executable
remain release gates. Skipped or missing controls remain RED.

## Historical 2026-10-07 inventory

The following original snapshot is retained for comparison. Its identities,
paths and test counts describe that earlier candidate and are not current claims.

# Reviewer inventory: source, candidate and connected runtime

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
