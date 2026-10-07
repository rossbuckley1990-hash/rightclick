# RCIR execution ledger — 2026-10-07

This is a new engineering run implementing G0/G1 and the OpenAPI slice of G2 from the supplied mission. It does not establish G3–G11 or a released universal runtime. [Machine ledger](execution-ledger.json), [release readiness](RELEASE-READINESS.md), [operator contract](RCIR-PRODUCTION.md).

## Reconciliation and identities

- Isolated clone/branch: `feature/rcir-openapi-production-20261007`, base `1f2219eafb4514b08c6364cb0ec3bb8bf105cf80`. Existing checkouts, dirty work, and other PRs were not edited.
- The recovered foundation patch was inspected against main and the open PR list, then applied without duplicate files. The ABI was reused. The actual production compiler/engine/ARD wrapper were subsequently changed; the patch alone did not establish integration.
- Pack verification matched nine internal manifest entries. The original foundation zip and historical raw logs were not located. The recovered reports are reference claims; all evidence below is labelled a new run. Internal pack integrity is not independently authenticated provenance.
- [Open PR census](../evidence/rcir-production-20261007/open-prs.json), [baseline CI](../evidence/rcir-production-20261007/main-ci-baseline.json), [published release](../evidence/rcir-production-20261007/release-v022.json). PRs 35/37/38/39/40 contain separate contract-pinning, portability, procedure, preflight and documentation work. This branch does not overwrite or merge them. Main's advisory experience repair is preserved.
- Companion tap initially based on `b91da8e2c3d1907f8542b46225481bc58f44f819`, reconciled onto concurrent main `6dda63a486f5bfbaf1c9ec2246992b6493668984`. Preserve its new bottle block, formula blob `0f20d401c5e3ed085a863c57ca43e474767447bb`.
- Environment: Apple Silicon arm64, macOS 26.4.1 build 25E253, Swift 6.3.3, deployment macOS 14+. Exact implementation source manifest and debug/release binary hashes: [candidate identities](../evidence/rcir-production-20261007/candidate-identities.json), [source manifest](../evidence/rcir-production-20261007/implementation-source.sha256). Candidate binaries still report 0.2.2; they are development builds, not the published 0.2.2 bytes.

The actual connected RIGHTCLICK process was `/opt/homebrew/Cellar/rightclick/0.2.2/bin/rightclick`, SHA256 `d31419fafc96e08c4a2db9d1b389320acb2835c1a901597244249772d7ac489d`, PID 67552, stdio. Both available connector names identified this same old process. Its schema contains exactly the seven operations. A genuinely discovered GitHub `repos/get` capability requested confirmation. The user confirmed the exact repository read; the connected runtime then returned HTTP 200, accepted/unverified, execution `CB8ECEE6-B155-4C48-8194-ACFB5EA0528A`. [Actual connected route](../evidence/rcir-production-20261007/connected-engineering-route.json). This is agent use through RIGHTCLICK, not candidate RCIR acceptance or a new connection.

## Route census

| Existing route | Actual composition/compiler | This candidate's boundary | Evidence/remaining gate |
|---|---|---|---|
| Configured REST | `ConfiguredOpenAPISource` → `OpenAPIReflector` | Engine-owned RCIR | Existing configured/runtime regressions; G2 native effect controls |
| Bonjour REST | `BonjourOpenAPISource` → same compiler | Same RCIR | Frozen public MCP proof with real DNS-SD discovery |
| OpenAPI artifact | `ConfiguredCapabilityArtifactSource` / `CapabilityArtifactResolverRegistry` → same compiler | Same RCIR | Existing artifact suite; no alternate dispatcher |
| ARD OpenAPI | `ARDRegistrySource` → `ARDOpenAPIReflector` → same compiler | Same host and public acquisition owner | Existing ARD execution/verification regressions preserved |
| CLI / MCP / HTTP | `run` / `begin` in `CapabilityEngine` | Both require RCIR for OpenAPI | Native tests and public stdio proof; ordinary HTTP regression remains separate |
| Federated OpenAPI | `RightClickMCP/Federation.swift` → remote engine `begin` | Provider runtime's OpenAPI boundary | Existing two-runtime acceptance; federation itself remains G5 |
| macOS Services | `MacOSServiceReflector` / `NSPerformService` | Existing execution and verification | Preserved regression; common RCIR routing is G5 |
| Sharing | `MacOSSharingReflector` / public sharing service API | Existing confirmation/UI boundary | Discovery/invocation limits preserved; G5 |
| Action extensions | `MacOSActionExtensionReflector` / installed metadata | Explicit discovery-only | No private APIs or fabricated invocation |
| GraphQL | Bonjour/artifact → `GraphQLReflector` | Existing execution | Preserved tests; RCIR G5 |
| gRPC | Bonjour/artifact → `GRPCReflector` / actual reflection transport | Existing execution | Preserved tests; RCIR G5/G4 |
| Authority | `OpenAPIAuthorityStore`, OAuth/OIDC acquisition | Exact-origin token re-read before consume | Local lease containment; real issuer downscoping remains G3 |

Client composition is unchanged: `setup` covers Cursor, Claude Code, Codex and the persistent ChatGPT bridge, plus generic stdio and authenticated HTTP MCP. Existing onboarding/bridge tests pass. Temporary configuration acceptance is distinct from connecting every real client. Current-version official-client audit, fresh upgrade/reconnect and measured first-use experience remain G9/G10. The published README contains older version claims; the overlapping docs PR is preserved and final released-claim reconciliation remains G11.

## Acceptance and fresh evidence

| New run | Result | Exact evidence |
|---|---|---|
| Baseline native with reconciled foundation | 550 tests, 26 skips, zero failures; exit 0 | `baseline-native.log.gz` |
| Foundation native, real CryptoKit | 63 tests (61 portable assertions + 2 backend tests), zero failures | `foundation-native-final.log`; completion logged, process exit handle lost at interruption |
| Frozen public production RED on pre-change executable | FAIL, exit 1: actual POST effect, missing mandatory RCIR evidence | `red/`, `red.log`; executable saved before production changes |
| Transport-boundary race RED | FAIL, exit 1: provider removed before enqueue still received one request | `race-red.log`, `race-red-effects/` |
| Final complete native suite | 574 tests, 26 skips, zero failures; exit 0 | `final-native.log.gz`, `final-native-effects/`; 24 real HTTP production controls |
| Final debug and release public MCP proof | Original seven plus ten-control freshness suite each PASS; success/failure signatures independently checked with OpenSSL | `final-public-debug/`, `final-public-release/`, `final-freshness-debug/`, `final-freshness-release/`; all exit 0 |
| Release-mode build | PASS, exit 0; no version/pin/tag mutation | `final-release-build.log.gz`, `.exit`, candidate identities |
| Existing setup / stdio / authenticated HTTP acceptance | PASS, exit 0 on final release bytes | `final-setup.log`, `final-mcp/` and corresponding `.exit` |
| Neutral-core direct/CLI/MCP equivalence | PASS, exit 0 with unchanged assertions in disposable configuration | `final-core/`, `final-clean-profile.json`; original configured-catalog failure retained in `core-release.log` |
| Tap probe and distribution unit tests | 38 PASS, exit 0; includes the unchanged 17 probe tests | Companion tap `schema-probe-green-final.log`; exact-head 21 probe fixtures and brew test-bot PASS |
| Installed seven-operation probe | PASS, exit 0, actual old 0.2.2 bytes; zero provider actions | Companion tap `installed-smoke.json` |
| Existing bottle taxonomy check | PASS, 14 kind IDs, exit 0 | `final-bottle-alignment.json`; compares published source archive, not binary bottle bytes or RCIR |

Paths above are relative to `evidence/rcir-production-20261007/` unless specified. The unchanged public test is retained in `preregistration/`; it has the same SHA256 as `scripts/acceptance-rcir-openapi.py`. It exercises confirmation and policy denial, undeclared arguments, a valid independently observed write, a separately authorised new lease, provider-success/wrong-state signed failure, and missing-observation unverified. Actual append-only effect/observation logs and MCP transcripts are retained, not synthetic PASS matrices. Raw MCP transcripts and bulky catalogue/log snapshots are losslessly compressed as `transcript.json.gz`; `compressed-evidence.json` pins both byte representations. Decode with `gzip -dc <path>` before inspecting JSON.

Native integration uses the actual compiler, engine and HTTP transport with a separate provider process. Internal fault seams inject expired/premature/spent leases, policy revocation, changed arguments, competing consumers, removed/reappeared providers, endpoint/schema drift and missing authority. The seams are absent from MCP schemas and operator configuration. Each no-effect control preserves the provider log; one consumed lease yields one request. A provider removed after dispatch remains unknown without retry. Both host observation and caller postcondition must pass when supplied.

The first public harness attempt omitted required advertisement metadata and is preserved under `red-setup-invalid/`; it is a setup failure, not meaningful RED. Intermediate native compile/setup/regression failures in numbered logs are retained and are not relabelled historical RED or PASS. The 26 native skips require explicitly provisioned live-service fixtures/environment; they remain skips. A new disposable live OpenAPI proof does not silently satisfy those older gates.

## Lifecycle and continuation

G0 census and G1 native foundation reconciliation are implemented and locally validated. The OpenAPI G2 path and mandatory effect controls are implemented and locally/live validated. Earlier PR42 head `fc4eb128a814e799ca545d250dd487729a42185d` passed all six remote checks, including Linux 61/macOS 63 foundation tests. Raw CI logs/artifacts are retained. Subsequent review found real schema-cache and body-boundary regressions; new-head CI is required. No runtime merge is claimed in this snapshot. The companion [tap PR8](https://github.com/rossbuckley1990-hash/homebrew-tap/pull/8) merged normally at exact reviewed source `79a05ff7c666d6df7d3b1d63113f6bf6aed0d412` as `ad42e817f27ab6eb2634b13759e2a2ea3a3ada3f`, after both checks passed; no pins changed. Linux foundation CI is separate from native tests and from a Linux runtime product.

No candidate artifact has been published or fresh-installed. The current connector has not reconnected to it. No new immutable version or checksum has been selected. No restricted eleven-substrate agent run occurred. G3 still needs a real issuer/provider restricted-credential pair, trusted observer credentials, signer rotation/revocation and minimised public receipts. G4 still needs principal-owned task transport, real asynchronous streams/backpressure and durable recovery. G5 needs remaining existing execution routes. G6–G11 remain separate unfinished gates.

Next: refresh [runtime PR42](https://github.com/rossbuckley1990-hash/rightclick/pull/42) with the reviewed source fixes, inspect all check conclusions for its exact head, preserve CI links/artifacts, address real failures without changing frozen acceptance, review and merge only eligible scope. Continue with the actual G3 authority prerequisite before adding substrates. At any session boundary refresh this ledger and readiness report; no invisible background completion is promised.

## Fresh-contract review controls

The actual long-lived public runtime retained its cached OpenAPI compiler after the provider changed `/openapi.json`. `cache-drift-red/` proves a stale write reached the real effect log (exit 1), against pre-fix release SHA256 `8f6240a2870fad415a5905aba7411e19e7a51a58bad92b6ebec0da8b2c69d890`. The additional frozen ten-control script preserves all original seven assertions. URL-backed contracts now re-fetch bounded current bytes before consumption and after dispatch; failed/changed reads withdraw the generation. Sources reacquire without reusing authority. `final-freshness-{debug,release}/` prove zero stale writes, a new discovered contract, a separately authorised verified write, and unchanged seven-tool schema fingerprint. Operator observer configuration is updated for the new contract by the disclosed workbench. This is not a restricted proof-agent run.

The first freshness GREEN attempt correctly rejected the stale write but remained unverified because a hyphenated observer ID was percent-encoded. The raw failed attempt is retained. URI-unreserved path IDs now round-trip; traversal, double-encoding, query and fragment IDs deny admission with zero provider effects. A separate real 80,000-byte body control failed when arguments were duplicated into the 64 KiB declaration (`body-bound-red.log`, exit 1). The compiler now commits the exact body digest while the lease binds all typed arguments; unchanged size limits and explicit unsupported bounds are documented. No tests were weakened.

Missing prerequisite for G3: authorised disposable issuer/provider URLs and the approved credential-provisioning route. The user has been asked without requesting secret values. Existing GitHub bearer availability and local lease containment do not establish issuer downscoping. No issuer/provider pair or historical evidence was fabricated.
