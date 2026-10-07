# Portable runtime

RIGHTCLICK's capability engine and seven-operation MCP contract are shared across macOS, Linux and Windows. Host integrations contribute discovered capabilities; they do not define the runtime or the agent-facing interface.

## Build and connect

Install Swift 6.2 or later for your host. The project uses the same Swift package on all three systems.

```sh
swift build -c release --product rightclick --force-resolved-versions
```

Run `.build/release/rightclick mcp` on macOS/Linux, or `.build/release/rightclick.exe mcp` on Windows. Configure any MCP client with that executable and `args: ["mcp"]`. `rightclick setup` on Linux/Windows prints this manual registration without modifying client configuration.

For authenticated loopback HTTP on every host:

```sh
rightclick mcp --http --port 8765 --token <operator-provisioned-token>
```

The listener binds only to `127.0.0.1`. HTTP bearer authentication, MCP origin/host validation, request framing and bounded bodies still apply. The Windows stdio adapter uses native Foundation file handles rather than the MCP SDK's POSIX-only stdio implementation.

## Shared behavior and optional adapters

| Feature | macOS | Linux | Windows |
| --- | --- | --- | --- |
| Seven generic MCP operations, capability graph, policy, RCIR admission | Shared | Shared | Shared |
| Configured OpenAPI and GraphQL, ARD acquisition, federation | Shared | Shared | Shared |
| SHA-256 and Ed25519 receipts | CryptoKit | Swift Crypto | Swift Crypto |
| Configured gRPC reflection/transport | Available | Available | Unavailable: current gRPC TLS dependency requires POSIX |
| Native Services, sharing, Finder Action metadata | Available | Unavailable | Unavailable |
| Bonjour browsing | Available | Unavailable | Unavailable |
| Keychain authority persistence | Available | Unavailable | Unavailable |
| ImageIO metadata and macOS extended-attribute observation | Available | Abstains | Abstains |
| Protected RCIR configuration/signing-key files | Available | Available | Candidate handle-bound owner/ACL adapter; native validation pending |
| Bounded experience ledger | Memory or protected disk | Memory or protected disk | Memory; explicit disk requests fail closed |
| Native client registration and persistent ChatGPT bridge | Available | Manual MCP configuration | Manual MCP configuration |

Unavailable adapters never enter the capability graph as invokable actions. Missing observation support does not establish success. An unsupported secure store does not fall back to plaintext credentials; authenticated capabilities remain unavailable without an authority backend. The Windows candidate reads operator-selected configuration through a handle-bound owner and DACL adapter, rejecting null or unsupported DACLs, non-private grants, reparse points and redirected parent paths. Native Windows validation is still a release gate; the earlier explicit refusal is preserved in baseline evidence. The generic in-process RCIR admission boundary remains active.

Windows support means the shared runtime can execute its supported substrates; it does not claim macOS integration parity. Every release must pass the Windows build and real-provider acceptance job before a Windows support claim or binary is published.

## Host paths and identity

`context_runtime` includes the platform alongside exact executable path, resolved path, digest, process ID and transport. `doctor` exposes generic platform/version fields and reports missing native adapters as `UNAVAILABLE`; its historical `macosVersion`/`macosBuild` JSON fields remain for compatibility and are empty on other hosts.

State locations:

- macOS: `~/Library/Application Support/RIGHTCLICK`
- Linux: `$XDG_STATE_HOME/rightclick`, or `~/.local/state/rightclick`
- Windows: `%LOCALAPPDATA%/RIGHTCLICK`, or `~/AppData/Local/RIGHTCLICK`

Relative environment paths are rejected in favor of the standard per-user location. Linux/Windows logs reside beneath the same state directory. Wire content identifiers such as `public.plain-text` and `public.url` remain stable. Hosts without Apple's type registry use conservative extension hints for files; unknown extensions classify as ordinary data.

## Acceptance and distribution

`.github/workflows/portable-runtime.yml` builds and tests the integrated product on all three hosts. `scripts/acceptance-portable.py <binary>` then invokes a real disposable OpenAPI provider over stdio and authenticated HTTP, checks all seven operations, tests confirmation and argument gates, validates executable provenance and retained RCIR status, and keeps provider acceptance explicitly unverified. Platform-specific tests remain on their native host; portable policy, contract, reflection, acquisition, cryptographic and verification tests run on other hosts.

Homebrew is a distribution adapter. The currently published formula still pins an immutable macOS release. A source port or a green branch does not change that installed product. Publish a new immutable upstream release only after all three platform gates pass; update the tap to its verified source checksum and build a matching bottle through its reviewed publication workflow. Never remove the stable formula's macOS restriction while it still points to source that cannot build on other hosts.

Linux and Windows can build the same accepted source release independently of Homebrew. Binary packages and installers must also be tested on clean hosts with their required Swift runtime libraries before being advertised as self-contained.
