# Portable runtime: one engine, host adapters

Candidate based on 05ace2fec149c62c7cfb24f41fafde863b377ff5. No 100-fold improvement, universal provider compatibility, native Windows success or production readiness is claimed without the corresponding evidence.

## Architecture

Local/configured/ARD discovery -> shared artifact resolver -> existing CapabilityEngine -> origin-bound authority and confirmation -> protocol-native execution -> existing outcome verifier -> the same seven MCP tools.

The Core and MCP implementations are shared. AppKit catalogs, Bonjour, Keychain OAuth and ImageIO are native host adapters, excluded when unavailable. Native implementation source remains in the Core tree behind explicit build boundaries to preserve source compatibility; this is not a second runtime or a new discovery protocol. ABI-001 and the current-main dispatch binding remain intact.

Linux compiles the full rightclick executable, OpenAPI, GraphQL and the bounded gRPC subset. Native Windows gets a bounded stdio transport adapter; JSON-RPC remains in the existing MCP SDK. Windows gRPC and HTTP-listener support are not enabled. Native Windows support is a CI/acceptance gate, not inferred from Linux results. macOS retains all existing native suites and functionality.

## Source-build quick start

Install the platform Swift 6.2 toolchain first. Build prerequisites and build time are not concealed.

```sh
swift build --product rightclick --force-resolved-versions
.build/debug/rightclick platform --json
.build/debug/rightclick connect
.build/debug/rightclick mcp
```

Use rightclick.exe on Windows. `connect` prints MCP client JSON using the executable path. It does not change client files, fetch schemas, read secrets or invoke a provider. Clients that accept the common mcpServers format can consume it; client-specific import/setup remains that client's responsibility.

```sh
rightclick connect --openapi https://example.test/openapi.json --base-url https://example.test
rightclick connect --graphql https://example.test/graphql
rightclick connect --grpc grpcs://example.test:443
```

The example endpoints are illustrative. The generated configuration reuses RIGHTCLICK_CAPABILITY_ARTIFACTS. Invalid, duplicate or ambiguous options fail rather than being guessed.

## Headless authority

No plaintext imitation of Keychain is introduced. Operators may explicitly opt into RIGHTCLICK_AUTHORITY_BINDINGS, a bounded JSON array of closed origin/schemeName/tokenEnvironment objects. Each entry references a separately injected environment variable. Bindings are exact-origin, exact-scheme; duplicates and malformed configuration fail closed. Explicit configuration never falls back to another credential source. Environment variables are not an enclave and are visible to sufficiently privileged local processes; use the host's secret injection facility and never put credentials in prompts or source control.

macOS keeps Keychain by default. Unavailable native credential mutation returns an explicit unsupported error. Provider descriptions cannot grant authority.

## Host semantics

macOS keeps Application Support/Logs locations. Linux uses absolute XDG_CONFIG_HOME/XDG_STATE_HOME or standard home fallbacks. Windows path logic uses APPDATA/LOCALAPPDATA. Reporting a compiled feature is not runtime attestation or proof of provider availability.

Text, file existence/readability, byte size and SHA-256 observation remain portable. Missing ImageIO/xattr observers return unknown, not proof that metadata is absent. A successful HTTP response remains acceptance, not evidence of arbitrary external side effects.

## Configuration isolation and transport

`rightclick mcp --isolated` excludes desktop providers, user registries, experience persistence, federation and ARD, admitting only explicitly configured generic artifacts. This is configuration isolation, NOT a security sandbox or authorization bypass. Normal startup preserves existing discovery.

Stdio terminates on EOF instead of a year-long wait. Desktop execution preserves macOS main-thread scheduling. Headless execution serializes shared engine calls without requiring AppKit. The Linux HTTP adapter uses NIO, binds only 127.0.0.1, bounds framing and connection lifetime, and reuses the existing authentication/dispatcher. JSON-only HTTP is not a claim of generic streaming support.

## Acceptance and distribution

All native suites remain enabled. Compatible existing Core suites and explicit host-boundary regressions run on Linux; native Windows has its own runner and real stdio proof. Excluded native-only tests are not counted as portable passes.

```sh
swift test --force-resolved-versions
python3 scripts/acceptance-portable.py .build/debug/rightclick --http
```

The acceptance starts a real local provider and real subprocess, tests seven tools, confirmation refusing transport, acceptance without verification, correct and incorrect postconditions, independent fixture readback, modern/legacy discovery, EOF, HTTP authentication and malformed framing. It does not establish full MCP-2026 conformance, generic causal verification or provider implementation safety.

Dockerfile is a non-root DEVELOPMENT image using the same executable and retained licenses. It is not yet a published/minimized production image. Docker/WSL are Linux execution routes, not native Windows proof. No Homebrew bottle, immutable release tag or installed runtime is changed by this feature.
