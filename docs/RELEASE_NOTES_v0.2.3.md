# RIGHTCLICK 0.2.3 candidate

The next runtime candidate preserves the seven canonical RIGHTCLICK operations while extending the capability graph through the existing engine and RCIR execution model. The installed Stable runtime and public Homebrew formula remain 0.2.2 until the new release passes its distribution gates.

## Candidate changes

- Agent-card acquisition for A2A, configured Kafka topic and Kubernetes resource contracts, acquired MCP tool schemas, component-model WASM interfaces, and Linux D-Bus introspection enter the shared capability model. Their presence in source is distinct from live availability and complete acceptance.
- Invocation contracts, retained task lifecycles, policy decisions and signed receipts preserve the distinction between provider acceptance and verified outcome. `context_run` adds an optional `contractSHA256`; existing required arguments and the other six operation schemas remain compatible in the measured release comparison.
- Existing OpenAPI execution rejects undeclared inputs and detected credential-bearing responses before retaining output or signed evidence. Valid declared request bodies and paths retain their previous behavior.
- Existing protobuf wire decoding rejects overflowing varints and hostile field lengths before arithmetic or allocation. Valid full-width varints remain supported by the decoder.
- Mac Service input uses Unicode-safe ASCII RTF. Returned provider observations retain exact text and UTF-16 bytes; the runtime no longer guesses and rewrites valid UTF-8-looking literals. All three real Apple text-converter regression cases pass on the separately identified native host.
- A bounded typed native host-context primitive supports fixture acquisition of the authoritative Windows ProgramData location. It uses the existing process helper and retains default production resolver environment behavior; it adds no model-facing tool or direct Windows discovery reflector.
- The Claude Code client starts `rightclick mcp`, with the launcher and active package metadata aligned to runtime 0.2.3. Live client loading has a separate verification boundary.
- Disposable HTTP fixtures bind real numeric loopback sockets without reverse DNS, publish complete readiness markers atomically, and bound failure diagnostics. The source archive includes the tracked fixture and script closure required by its tests.

## Compatibility evidence

Matched 0.2.2 and candidate checks preserve measured Mac Services, REST request/response behavior, native unary gRPC, GraphQL query/mutation behavior, the public seven-operation surface, confirmation gates and retained status. Each proof records its own source and executable hashes. Candidate receipts and contract pins are additional controls; their absence in the previous release is not classified as a loss of previous capability.

Conflicting macOS Services identities are quarantined instead of being presented as executable. The measured removed Script Editor identity was already unsupported in 0.2.2; the comparison found no loss of an executable action among the measured rows.

## Acceptance boundary

This file describes an unpublished candidate. Complete tests, fresh native platform CI, deterministic packaging, published-asset identity, Homebrew installation and connected-runtime upgrade verification remain required before publication. Final accepted source and artifact hashes must accompany the release.

The full eleven-substrate restricted-agent proof, caller-specific authority brokerage, all async/streaming controls and cross-substrate live graph mutation remain separately required. This candidate does not establish that the universal-runtime goal is complete. Plugin package versions are independent identities; use `context_runtime` to identify the serving runtime.

Existing release tags and assets remain unchanged. The tap must move to 0.2.3 only after the new immutable source asset is independently downloaded and verified, with a matching new bottle and a fresh installation check.
