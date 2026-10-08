# Portable fabric engineering report

> Historical PR #99 report. Its source identities, native results and next-step
> recommendations apply only to that portable-fabric candidate, not the combined
> PR #49/#99 integration. Current reconciliation evidence and remaining gates are
> tracked in [the reconciliation design](RECONCILIATION-DESIGN.md),
> [the substrate contract](substrate-contract.json) and
> [draft PR #102](https://github.com/rossbuckley1990-hash/rightclick/pull/102).
> A real TLS Link implementation is not recommended until capability
> reconciliation is proven.

## 1. Result

RIGHTCLICK now builds and runs directly on Linux x86_64 and arm64, as well as
macOS arm64, from this source candidate. Native Linux containers exercised the
actual release executable, seven-operation MCP, real HTTP provider, local policy,
RCIR admission and independent readback. Windows and Intel Mac execution are
not claimed. No release, Homebrew update or PR merge is part of this task.

Baseline: `df6690d0fbd2030116736a15f2fd5dff46a21a19`.
Branch: `feature/portable-fabric-foundation`.
Final runtime source: `990163d94f1a2154ea9d7d88599bc1586baf4ae5`, including
current main `381a87b53dbd0046f1acef1984587199da0e630c`.
The [PR #99 checks](https://github.com/rossbuckley1990-hash/rightclick/pull/99/checks)
rerun the complete native matrix and original repository CI gates.

## 2. Architecture before

RightClickCore combined the generic engine/providers with AppKit Services,
Sharing, Action Extension metadata, Bonjour, Keychain, image inspection and
native startup. MCP used Apple's Network framework and a Mac main-thread bridge.
Apple Silicon was principally the distribution assumption; generic contracts,
policy, provider execution and much verification were already portable.

## 3. Architecture after

The original engine was extracted rather than replaced. Protocol contains shared
models, contracts and host interfaces. Providers retain the existing OpenAPI,
GraphQL, gRPC and ARD implementations. Core retains graph/discovery, dispatch,
policy coordination, verification and evidence. Mac features live in MacOS and
MacOSHost adapters. Conditional package composition preserves native defaults
and Core re-exports for source compatibility.

MCP retains `context_runtime`, `context_inspect`, `context_actions`,
`context_providers`, `context_explain`, `context_run` and `context_run_status`.
The tool definitions are unchanged. Linux adds a bounded NIO loopback listener
and portable CLI composition. Both MCP transports call the same engine.

Opt-in Link supplies signed requests/results, durable host admission, explicit
runtime enrollment and a remote graph source. Routing enters normal Core
dispatch and target `CapabilityEngine.begin`; it never invokes a provider
directly. OS/architecture requirements express compatibility, not authority.

## 4. Significant files and modules

| Files | Purpose |
| --- | --- |
| `Package.swift` | Portable products and dependency boundaries; native targets only on Mac; existing transitive swift-crypto becomes a directly pinned Linux dependency |
| `Sources/RightClickProtocol/{Capability,CapabilityABI,CapabilityReflector,CapabilityReflectorSource,ContentItem,PlatformHost,RCIR,RCIRExecutionEvidence,RCIRSignedReceipt,RuntimeReports,SafetyPolicy,Verification}.swift` | Existing shared models moved out of native Core; host interface, runtime requirements and explicit observation boundary |
| `Sources/RightClickCore/{CapabilityEngine,CapabilityRuntimeDefaults,NativeRuntimeDefaults,Exports,CapabilityExperience}.swift` | Original orchestration, compatibility composition, contract-bound admission, shared executor and runtime routing hook |
| `Sources/RightClickProviders/` | Original generic reflectors, acquisition/compiler, authority, RCIR host and verification code moved intact; FoundationNetworking/Crypto portability and host calls |
| `Sources/RightClickProviders/{ContentParser,PlatformHostDefaults,RuntimeEnvironmentAuthority,OriginPinnedHTTP}.swift` | Portable input/host composition, exact-origin injected authority, explicit bounded-completion delegate witness |
| `Sources/RightClickMacOS/` | Original Services, Sharing, Action Extension discovery, Bonjour and Unicode/RTF handling; runtime requirements added to native declarations |
| `Sources/RightClickMacOSHost/{MacOSHost,MacOSSecretStore,KeychainLinkSigner}.swift` | Original native observations/Keychain custody; optional device-local signing identity |
| `Sources/RightClickMCP/{Server,HTTPListener,HTTPListenerNIO,Federation}.swift` | Same tool dispatcher and Mac loopback behavior; Linux loopback/framing/backpressure; optional graph source composition |
| `Sources/RightClickCLI/PortableMain.swift` | Linux entry point using existing engine; existing Mac entry point and onboarding unchanged |
| `Sources/RightClickLink/{RemoteProtocol,RemoteNodeIdentity,RemoteLocalApproval,RemoteReplayLedger}.swift` | Bounded versioned signed envelopes, key-derived node identity, exact host approval tickets and protected durable journal |
| `Sources/RightClickLink/{RemoteExecutionDispatcher,RemoteResultValidation,RemoteLinkTransport,RemoteRuntimeRegistry}.swift` | Local admission/execution reuse, coherent lifecycle validation, replaceable simulated outbound transport and enrolled graph routing |
| `Tests/RightClickLinkTests/` | 72 Mac / 70 Linux protocol, dispatch, ledger, routing and adversarial tests; actual OpenAPI/RCIR/readback integrations |
| `Tests/RightClickCoreTests/` | Platform guards/imports preserve native assertions; Linux authority and truthful unavailable observations; one new real acquisition completion regression |
| `Tests/RightClickCoreTests/RCIRProductionDispatchTests.swift` | Existing competing-consumer harness lifetime correction; permit/replay/effect assertions retained |
| `.github/workflows/{portable-fabric,capability-abi,rcir-foundation,rightclick-architecture-inspect}.yml` | Native two-architecture Linux and Mac proof; moved-source paths in existing gates |
| `scripts/{acceptance-portable-fabric,acceptance-core-boundary,detect-bottle-alignment,package-source,test-capability-abi,test-rcir,prove-rcir-receipt}` | Actual portable startup proof and migrated component/package harness paths |
| `README.md`, `SECURITY.md`, `docs/PORTABLE-FABRIC.md` | Candidate positioning, setup, architecture, threat model and deployment boundaries |

Most existing test edits are module imports/platform guards. Native tests remain
in the Mac suite; they are not falsely counted as Linux passes. The original
experience ledger source and tests end exactly unchanged from the baseline.
`Package.resolved`, Mac installation code and published distribution files are unchanged.

## 5. macOS compatibility

Clean baseline: 611 tests, 583 passed, 28 explicit environment skips, zero
failures. Final integrated local full suite: 687 tests, 658 passed, 29 explicit
skips, zero failures, 75.309 seconds. All 611 original identities/results remain;
73 task-added tests pass. Newer main adds three native cases, including one
additional opt-in skip. All three installed native text-service tests also pass
when explicitly enabled, in 17.653 seconds.

Main advanced during the task. Its PR95 deliberately corrects six existing
Unicode boundary expectations and the live half-width expected string to preserve
raw provider bytes, rather than guess a different observation. Those upstream
assertions were retained exactly during conflict resolution. This is an upstream
verification correction, not a portability regression or a rewritten green test.

Final release setup, stdio/HTTP MCP, malformed framing and 401 authentication,
native full-width conversion/verification, existing two-runtime federation,
Core/CLI/stdio/HTTP equivalence and all ten RCIR freshness/security controls pass.
The Homebrew substrate comparison remains 14/14 aligned with published v0.2.2.

An isolated local CLI inspection comparison produced identical JSON over ten
samples per binary: baseline median 45.304 ms, candidate 45.747 ms. This small
startup check found no material slowdown with Link unused; it is not a throughput
benchmark or a general performance guarantee.

## 6. Linux support

Native Ubuntu 24.04 x86_64 and arm64 runners used `swift:6.3.3-noble`, without
emulation. Each compiled Protocol, Core and MCP separately, ran its entire
available suite, built a release binary, validated the lockfile and exercised
stdio and authenticated HTTP MCP with an actual disposable provider.

The completed portable-source validation run is
[37782046957](https://github.com/rossbuckley1990-hash/rightclick/actions/runs/37782046957)
at `3a0a4d3e73a8f8ab2350f3f4b0d4ac302229adeb`: 419 tests on each Linux
architecture, 416 passed, three external-fixture skips, zero failures. Mac CI:
684 tests, 656 passed, 28 skips, zero failures. It includes the final listener
concurrency hardening, ledger cleanup and HTTP framing/authentication controls.
The later main integration changes only the Mac adapter/native tests and Claude
plugin; portable Protocol/Core/Providers/MCP/Link/package sources are identical.
PR checks repeat the full matrix for the integrated head.

Reference native release SHA256:

```text
x86_64: 61ffba572cd46432f5bcafdb646c5fd24e1bd7669206110f0de6ede3ce0907f9
arm64:  66d2a55a05a88c4b94dffec7bc8f15aca51a5ae6016a65366cfb328e9be35d44
lock:   72d81370ea6786ea62a18ba88badc67df086271eb779a2ded9e4d95abfd116f6
```

Linux skips require separately provisioned live gRPC, exact frozen GitHub or
OpenAPI fixtures. The startup integration supplies its own real HTTP provider
and independently passes; these skips are not substituted for integration proof.

## 7. Distributed runtime proof

The deterministic graph demonstration prints:

```text
FABRIC DEMO: synthetic Linux local API + enrolled Mac capability -> one graph -> existing generic MCP -> authenticated target -> independent VERIFIED; Mac effects=1, Linux effects=0
LINK DEMO: fresh authenticated retry, same idempotency key -> reused VERIFIED; effects=1
LEDGER EVIDENCE: 16 simultaneous independent-instance races; exactly one admission per intent
LEDGER EVIDENCE: durable reservation -> restart -> UNKNOWN; retry cannot win execution
```

This uses actual MCP `context_run`/`context_run_status`, the normal engine,
contextual remote graph source, authenticated target dispatcher and independent
verification. OS identities/capability are explicitly synthetic; it is not a
real cross-machine deployment. Separate integrations invoke the actual OpenAPI
provider over HTTP, consume exactly one RCIR lease, perform a separate host GET,
receive a signed verified result and retry with an effect count still equal to one.

## 8. Security

Ed25519 domain-separated signatures bind canonical versioned requests/results,
caller, target runtime/device, full capability contract, arguments, postconditions,
UUID request/idempotency identifiers, 32-byte nonce and bounded expiry. Keys are
pinned independently of relay metadata. Current contract, caller grant, expiry,
host approval and RCIR policy are rechecked at admission.

Durable atomic reservations precede effects. Exact replays and nonce reuse fail;
fresh same-intent retries return cached evidence or unresolved unknown. Concurrent
delivery and restart cannot acquire another execution reservation. Journal loss,
unsafe ancestors, ACL grants, symlinks, replacement, rollback clock and full
storage deny execution. There is no eviction/reset or cross-node fallback.

Provider credentials, policy, approval and raw observations stay on the execution
node. Remote requests cannot contain a confirmation bypass flag. Host approval
tickets bind exact reviewed bytes. Remote v1 inputs are text/web URLs and never
probe target filenames. Summaries expose safe states and opaque evidence IDs,
not provider credentials, raw results or private diagnostics.

Acceptance and verification are separate. Independent external readback and
returned-value checks carry distinct evidence boundaries. Contradictory lifecycle
or verification assertions fail integrity validation. A signed node assertion
authenticates its author; it cannot prove a compromised node is honest.

MCP remains `127.0.0.1` only. Normal CLI startup does not import/start Link,
provision an identity, allocate a journal or establish a remote connection.

## 9. Exact checks

| Command/check | Result |
| --- | --- |
| `swift package clean`; `swift test --force-resolved-versions` before change | 611 total / 583 pass / 28 skip / 0 failures; clean build 136.17 s |
| `swift build --target RightClickProtocol` / `RightClickCore` / `RightClickMCP` with `--force-resolved-versions --jobs 4` | Clean extracted-module builds pass; native Linux CI uses same commands |
| `swift test --jobs 4 --force-resolved-versions` after fixes, review and main integration | Mac 687 total / 658 pass / 29 skip / 0 failures; all original identities/results retained, upstream assertion corrections documented |
| `RIGHTCLICK_LIVE_UNICODE_SERVICE=1 swift test --filter NativeServiceUnicodeLiveAcceptanceTests` | Three actual installed Services / 0 skips / 0 failures, including exact literal output preservation |
| Native Linux `swift test --force-resolved-versions --jobs 4` | Each architecture 419 total / 416 pass / 3 skip / 0 failures |
| `scripts/build-cli.sh` | Mac release build passes; integrated rebuild 22.47 s after earlier clean release 116.07 s |
| Linux `swift build -c release --product rightclick --force-resolved-versions --jobs 4` | Both native release builds pass, version 0.2.2 |
| `python3 scripts/acceptance-portable-fabric.py .build/release/rightclick` | Actual stdio + HTTP seven operations, provider, policy, consumed lease, independent readback and retained evidence pass; final version adds framing/invalid credential controls |
| `acceptance-setup.py`, `acceptance-mcp.py`, `acceptance-federation.py`, `acceptance-core-boundary.py` with final release | All pass; setup isolation, loopback/auth/framing/native evidence, live gain/loss, exact direct/MCP equivalence |
| `acceptance-rcir-openapi-freshness.py` with final release | All ten original controls pass |
| `bash scripts/test-capability-abi.sh` | 33 tests / 0 failures |
| `bash scripts/test-rcir.sh` | 71 tests / 0 failures |
| `python3 scripts/acceptance-experience.py` | 24 tests / 0 failures; original exact-source ledger/tests preserved |
| `scripts/prove-rcir-receipt.sh` with bundled Python | Swift-produced success/mismatch receipts verified independently by Python/OpenSSL; 11 negative controls rejected; fixture scope only |
| `swift package dump-package`; staged `python3 scripts/package-source.py` twice | Valid manifest; reproducible archive includes all modules, no checkout/build cache; no working-tree formula/distribution edits |
| `python3 scripts/detect-bottle-alignment.py --compare --json` | 14/14 substrate kinds aligned; immutable published bottle unchanged |
| `git diff --check`; Python AST parse; source/private-path/credential-marker scan | Pass; 21 Python scripts parse; lockfile unchanged; no generated artifacts committed |

No lint/formatter gate is configured. Compiler warnings were inspected and are
not concealed: native deprecated APIs, the existing MCP SDK text initializer,
two unhandled fixtures, Swift 6 migration diagnostics and release DWARF prefix
mapping remain. Targets retain the repository's Swift 5 language mode. The new
Keychain deprecation and Linux NIO handler-context captures were corrected.

Completed portable-source CI retained 50 repeated warning occurrences/six unique
categories on each Linux architecture (down from 82/nine before NIO hardening),
and 61/13 on Mac. These aggregate module, suite and release logs; they are not
unique defect counts. No compiler errors occurred.

Two legacy scripts fail identically before/after and are outside current CI:
`acceptance-chatgpt-mcp.py` expects six tools despite the authoritative seven;
`acceptance-setup-failures.py` extracts Setup without its current supporting types.
Their expectations/stubs were not altered to create green results. No previously
passing gate regressed. The standalone ABI minimum and Core harness composition
were updated to match actual source contracts, preserving their assertions.

## 10. Independent review and fixes

Seven specialist roles investigated architecture, portability, security and the
baseline, then independently challenged code, attempted adversarial failures and
reviewed product/setup experience. The coordinator integrated production edits.

HIGH findings fixed and covered by regressions: NFC/NFD contract-byte substitution;
writable-parent replay-history reset; Mac ACL write/delete history reset; held
enrollment responses resurrecting a removed runtime. MEDIUM fixes cover shared
engine serialization, policy-denial projection, contradictory lifecycle/verification
evidence, remote file/privacy and reentrant parsing. Real provider/readback tests
replaced reliance on mock-only assertions. DX review corrected source executable
commands, Linux flags/paths and unsupported deployment claims.

Native Linux CI found an inherited URLSession completion witness problem; an
explicit base witness/subclass override and real acquisition regression fixed it.
A Mac repeat exposed an existing concurrency-test closure lifetime race. Its
synchronous concurrent harness retains permit/replay/effect assertions; elapsed
checking is not an interruptible deadlock timeout. Final read-only code and
adversarial reviews found no unresolved CRITICAL/HIGH issue.

## 11. Known limitations

Link is an optional embedding library with a deterministic simulated outbound
relay. No network relay, deployed TLS Link, pairing/enrollment CLI or local approval
UI exists yet. Linux identity provisioning is injected by the host operator.
Mac signing uses a device-local non-syncing Keychain software key retained in
process memory, not Secure Enclave. Full owner/admin storage rollback is outside
the journal threat model; hardware anti-rollback is deferred.

The journal admits at most 1,024 envelopes and fails closed at capacity. Production
retention/identity epoch policy is deferred. Requests awaiting approval are cached;
later approval needs a new host-reviewed request. Async remote status/subscriptions,
remote file inputs and multi-hop routing are deferred. Runtime requirements
currently cover OS and architecture; software/device/credential readiness remains
with discovery and local authority rather than new requirement fields.

Windows needs package/dependency composition, Crypto selection, WinSDK/protected
storage equivalents to POSIX/ACL admission, portable process/network checks and
its own adapter/CI. Its protocol identity is represented without claiming a build.
Intel Mac generic source is architecture-neutral but no Intel runtime was tested.

## 12. Installation

Published Mac installation remains `brew install rossbuckley1990-hash/tap/rightclick`. To exercise this
candidate on supported Mac/Linux hosts with Swift 6.2+:

```sh
git clone https://github.com/rossbuckley1990-hash/rightclick
cd rightclick
git checkout feature/portable-fabric-foundation
swift build -c release --product rightclick --force-resolved-versions --jobs 4
.build/release/rightclick doctor --json
.build/release/rightclick mcp
```

An MCP client uses an absolute executable path and `args: ["mcp"]`. Linux
`serve` is also a stdio alias; Mac `serve` keeps existing HTTP setup behavior.
HTTP uses an injected `RIGHTCLICK_MCP_TOKEN` and `mcp --http --port 8765`.
Linux provider secrets use exact HTTPS-origin/scheme environment bindings
described in [portable setup](PORTABLE-FABRIC.md#start-a-portable-runtime).

The official `swift:6.3.3-noble` container builds and starts this source in CI.
No new prebuilt Linux package/container image or Windows distribution is published.

## 13. Original cloud scenario

A cloud Linux agent can now build and run RIGHTCLICK directly for implemented
portable providers through the same seven operations. It does not need a Mac
for those capabilities. Enrolled compatible-node routing is proven through one
graph and the normal MCP/engine path. Accessing a real Mac's Xcode/apps over the
internet still requires the deployable outbound transport and enrollment flow;
the simulation does not claim that deployment exists.

## 14. Smallest next step

Implement one authenticated TLS outbound host session and caller transport,
operator-controlled key pairing/grants and reconnect delivery semantics around
the existing dispatcher/ledger. Test two actual hosts while keeping MCP on
loopback. Follow with host approval continuation, remote status and explicitly
designed journal retention before a production relay release.
