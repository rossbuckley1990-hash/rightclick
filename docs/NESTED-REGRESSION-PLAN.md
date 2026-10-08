# Nested execution regression gates

Protected baseline: `main` at `df6690d0fbd2030116736a15f2fd5dff46a21a19`.
Feature branch: `feature/nested-execution-fabric`. No merge, release, bottle,
installed-profile change or cloud provisioning is part of these local gates.
The user explicitly requires leaving `main` unchanged; that constraint takes
precedence over AGENTS.md's bottle-release alignment instruction.

The feature now extends the adopted portable candidate
`d496cf1b240bc97a52dbb5a5a76f378fd183b074`, which descends from protected main.
The original-main baseline and portable-base baseline are separate gates.
Main completed with **583 passed, 0 failed, 28 skipped (611 executed)**:
Core 415/0/28, ARD 5/0/0, CLI 155/0/0 and MCP 8/0/0.
`baseline-portable-macos.log` records the portable-base run; its final totals
must be read after completion, not inferred from static source inventory.

The original AI-facing operations are, in source registration order:

1. `context_runtime`
2. `context_inspect`
3. `context_actions`
4. `context_explain`
5. `context_run`
6. `context_run_status`
7. `context_providers`

`Sources/RightClickMCP/Server.swift` registers this surface.
`FederationTests.testModelFacingToolSurfaceRemainsSevenGenericOperations` and
`scripts/acceptance-mcp.py` independently require the same seven names.
Environment capabilities belong underneath those operations. Source equality
alone is insufficient: repeat `tools/list` against the built feature binary.

## Exact baseline and reviewable evidence

The lead owns the full baseline Swift test run. Its transcript is
`evidence/nested-execution-fabric/baseline-macos.log`.
Run `python3 evidence/nested-execution-fabric/regression-audit.py` after baseline
completion and again on the integrated branch. The audit writes only
`regression-audit.json`; it records test outcomes and skipped-test reasons,
compares original test files to both the protected main SHA and adopted portable
SHA, compares public tool names and the complete tool-registration definition,
and checks `main`. The 57 existing test-file migrations between main and the
portable candidate are inherited module imports/platform guards and must not be
misreported as newly introduced nested-engine drift. As of the initial adopted
candidate inspection, zero test files differ from the portable base.
Do not infer passing counts from method counts or from an incomplete log.

`regression-portable-base-inventory.json` records all 611 original test method
names retained in the portable candidate, with zero missing names and 775 total
static method names across its platform-specific source. Name retention proves
neither assertion equivalence nor runtime success; the main and portable macOS
baselines plus final integrated run establish those separately. The original
main's native tests are guarded/excluded only on Linux where native Services,
AppKit, Bonjour and Keychain are unavailable. The new nested feature must not
expand those exclusions.

## CI-equivalent matrix

| Gate | Checked-in command/contract | Scope and caveat |
| --- | --- | --- |
| Full macOS product | `swift test --force-resolved-versions` | `.github/workflows/tests.yml`, macOS 26; preserve baseline skips and original tests. |
| CLI release build | `scripts/build-cli.sh` | Reproducible release CLI; defer until the shared Swift build is idle. Does not install or publish. |
| Setup compatibility | `python3 scripts/acceptance-setup.py "$PWD/.build/release/rightclick"` | Temporary client homes, existing onboarding contracts. |
| Public MCP | `python3 scripts/acceptance-mcp.py "$PWD/.build/release/rightclick" <isolated-evidence-dir>` | Stdio and authenticated loopback HTTP, concrete executable hash, exact seven tools, provider discovery, confirmation, Unicode text postcondition, retained execution status and malformed HTTP framing. Requires macOS text converter. |
| Federation | `RIGHTCLICK_ACCEPTANCE_REF=df6690d0fbd2030116736a15f2fd5dff46a21a19 python3 scripts/acceptance-federation.py "$PWD/.build/release/rightclick" <isolated-evidence-dir>` | Two new local runtime processes and isolated homes; fixture acquisition reads the immutable public baseline GitHub ref. The unpushed feature SHA cannot be used for that URL. Requires network access; source stays unchanged. |
| Core entry boundary | `python3 scripts/acceptance-core-boundary.py <binary> <evidence-dir> <mcp-results.json>` | Compiles actual core separately, compares direct/CLI/MCP semantics. This existing harness does not provide RightClickARD/gRPC dependencies, so report compiler failures honestly; do not delete production sources to force acceptance. |
| Portable ABI | `bash scripts/test-capability-abi.sh` | Exact production CapabilityABI source, Foundation-only mini-package. CI Swift 6.2 Linux; Swift 5 language mode. Narrower than full runtime. |
| Portable RCIR | `bash scripts/test-rcir.sh` | Exact CapabilityABI/RCIR/signed-envelope foundation plus original tests and invocation-isolation regressions. CryptoKit tests are conditionally compiled; Linux does not thereby prove cryptographic runtime support. |
| Portable ARD | `swift build --product rightclick-ard-probe --force-resolved-versions`; `.build/debug/rightclick-ard-probe` | Only portable RightClickARD product. Full Package is macOS-only because Core links AppKit. CI separately runs `live-hf`, which is a live network acquisition and must be distinguished. |
| RCIR engine | `RCIR_DISPATCH_EVIDENCE=<dir> swift test --force-resolved-versions --filter RCIRProductionDispatchTests` | Real loopback HTTP effect/denial controls; requires macOS product build. |
| RCIR public production | `python3 scripts/acceptance-rcir-openapi.py <binary> <dir>` and `python3 scripts/acceptance-rcir-openapi-freshness.py <binary> <dir>` | Bonjour advertisement, local HTTP provider, independent signed-receipt verification and live schema drift; checked-in server binds all interfaces. Inspect and account for host prerequisites before execution. |
| Static final gate | `git diff --check` and regression audit | No unexplained original-test changes, no new tools, no ref drift. Check new fixtures/evidence for secret values without dumping host credentials. |

The table above records original-main CI. The adopted portable candidate adds
`.github/workflows/portable-fabric.yml`, with stronger full-product gates:

| Portable-base gate | Exact local equivalent | Evidence scope |
| --- | --- | --- |
| macOS arm64 | `swift test --force-resolved-versions --jobs 4`; `python3 scripts/acceptance-portable-fabric.py .build/debug/rightclick`; `python3 scripts/acceptance-bilateral-fabric.py .build/debug/rightclick-fabric-proof --output-dir <dir>` | Actual provider, seven operations, independently observed outcome; two isolated local processes, not cross-machine/cloud proof. |
| Linux x86_64 | Swift `6.3.3-noble`, assert `uname -m` is `x86_64`; build `RightClickProtocol`, `RightClickCore`, `RightClickMCP`; full available `swift test --force-resolved-versions --jobs 4` | Native CI uses `ubuntu-24.04`. Original-main macOS-only exclusions remain explicit. |
| Linux arm64 | Same gates, assert `uname -m` is `aarch64` | Native CI uses `ubuntu-24.04-arm`; native/emulated local status must be labelled accurately. |
| Linux public binary | `swift build -c release --product rightclick --force-resolved-versions --jobs 4`; portable/bilateral acceptance scripts above; `git diff --exit-code -- Package.resolved` | Record binary SHA, source SHA, toolchain, lockfile SHA, architecture, exact runtime counts and receipt/effect transcripts. |

The portable candidate already adds established `swift-crypto` 5.0.0 on Linux
and separates portable protocol/provider/core modules from native macOS modules.
Prefer its actual complete package gates over the proposed narrow mini-package
for the integrated feature. Preserve the mini-package gates as existing ABI/RCIR
foundation regressions. Its public tool names still match the same seven, while
its inherited `context_run_status` schema adds cursor/limit/cancel support.
Treat that definition change as inherited baseline, with no new nested-feature
schema expansion expected.

Existing experimental alien-relay, distributed Windows and proof-lab workflows
are separate live or provisioned-substrate demonstrations. They are not required
for the default deterministic nested environment test and were not invoked.
The packaging/bottle workflow is not reproduced because it would require
distribution work the user expressly excluded.

## Linux x86_64 and arm64 execution plan

This host is Darwin arm64 with Apple Swift 6.3.3. Docker CLI is present at
`/usr/local/bin/docker`, but the read-only daemon query returned permission denied
for the Docker socket. Neither Linux architecture has been executed by this
regression investigation. Counts must remain `unexecuted`, with no fabricated
zero-failure claim.

When Docker or independent Linux runners become available, run the existing ABI
and RCIR scripts on both `linux/amd64` and `linux/arm64` using Swift 6.2. Each
architecture requires a fresh scratch path and a separately archived log with
`uname -m`, `swift --version`, exact source hashes, platform/image digest and test
summary. Mount the feature checkout read-only, allow only a dedicated scratch
directory and disposable container filesystem to be written, and do not pass
host credentials or Docker socket through to the workload. Never share `.build`
between host and containers or between architectures. An emulated amd64 result
must be labelled emulated; it cannot establish native performance or timing.

For the adopted portable full product, use Swift `6.3.3-noble` to match its new
workflow; keep the older Swift 6.2 Foundation gates distinct. Docker availability
is being rechecked by the lead with appropriate socket access; this document's
permission-denied observation is an investigation result, not a permanent
claim that the Docker daemon is unusable.

For the new portable nested engine, follow the repository's exact-source
mini-package convention: copy actual new Foundation-compatible production files
and actual new tests, with required ABI/RCIR sources, into a scratch package.
Avoid duplicate toy implementations or replacing Ed25519 verification with a
checksum. If a portable cryptographic dependency is needed, use the declared,
locked dependency and test real signing, pinned-key verification and mutation
rejection on both Linux architectures. The mini-package's narrower scope must
remain explicit; it does not prove the full macOS MCP product works on Linux.

## Behaviour that must remain covered

Keep the existing `PolicyTests`, `SharingExecutionTests`, `OutcomeVerifierTests`,
`VerificationIntegrationTests`, `DispatchContractBindingTests`, authority tests,
provider acquisition tests, CLI setup/profile tests and `FederationTests` intact.
They protect confirmation, accepted-versus-verified outcome semantics, identity
binding, credential isolation, dynamic provider discovery and installed-client
compatibility. Fake nested-provider success supplements these gates; it cannot
replace them or establish live-cloud success.

Run the full integrated macOS suite after feature freeze, then focused new
adversarial/nested tests and practical acceptance scripts. Preserve separate
passed/failed/skipped counts and reasons for every unexecuted platform or live
gate. Resolve new failures or document a baseline-equivalent external prerequisite
before calling the branch a merge candidate.
