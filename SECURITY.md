# Security

Discovery is not approval. RIGHTCLICK reflects contracts declared by installed software; that metadata is not a cryptographic claim that a provider is safe. External-share, destructive, financial, and unclassified actions require confirmation. Classification uses metadata heuristics, including text-return contracts; it does not inspect provider implementation or prove absence of side effects. A friendly title or returned-text contract is not proof of safety. Confirm sensitive operations and trust the installed provider. Action extensions fail safely as unsupported.

`NSPerformService` returning true means invocation was accepted. It does not prove completion or an external semantic result. Agents should distinguish discovery, applicability, payload construction, invocation, completion, and independent outcome verification.

## Remote access

The portable source candidate preserves the Mac listener and adds a Linux
loopback listener. Neither binds to a public interface. Linux HTTP mode requires
an explicitly injected `RIGHTCLICK_MCP_TOKEN`; stdio requires no listening port.
The optional Link library is absent from normal CLI startup. It never forwards
a public socket into localhost MCP. See [Link trust boundaries and limits](docs/PORTABLE-FABRIC.md#link-trust-boundaries).

Link pins caller grants and execution-node keys locally, signs the exact bounded
versioned request and result, binds the target and complete capability contract,
and durably reserves nonce/request/idempotency before effects. Confirmation comes
from a host-owned approval ticket, never from a remote `confirmed` flag. Policy,
credentials and observation stay on the execution node. A relay acknowledgment,
HTTP success or provider acceptance does not mean verified outcome.

An interrupted request returns unavailable or unknown. There is no automatic
cross-node fallback. A fresh authenticated retry with the same intent and
idempotency key returns the prior safe summary or unresolved unknown, without
invoking the provider again. Exact envelope replay is rejected. Journal loss,
clock rollback, untrusted storage and capacity exhaustion fail closed.

Streamable HTTP binds only to loopback and requires a bearer secret. Missing or invalid authentication returns 401. Requests with negative, invalid, or excessive Content-Length, unsupported transfer encoding, or an incomplete body are rejected. The small HTTP listener is intended for one user's Mac; it is not a general-purpose internet server.

`rightclick serve` stores its secret in `~/Library/Application Support/RIGHTCLICK/token` with owner-only permissions and prints it at startup. Protect captured terminal output. `rightclick auth rotate` prints a replacement secret; restart serving processes afterward. The current process keeps its existing credential until restart.

`--tunnel` explicitly starts a temporary Cloudflare development tunnel if available. Use authentication and an appropriate TLS boundary whenever deliberately exposing the service. No tunnel is required for local Cursor use. Do not commit or publish secrets, auth traces, or live private tunnel details.

## Local data and logs

Execution diagnostics can contain the exact input text or URL. They are written to stderr and, when permitted, `evidence/execution/share.log` relative to the working directory. MCP startup logs under `~/Library/Logs/RIGHTCLICK/` contain the executable path and hash. Treat logs as potentially private and review them before sharing. RIGHTCLICK does not isolate a provider from the permissions already held by its installed application.

Homebrew uninstall removes package files, not your Cursor configuration, logs, or token. Remove only the `rightclick` entry from `~/.cursor/mcp.json` when disconnecting; preserve other servers. Remove RIGHTCLICK's support/log directories only if you intend to delete their retained data.

## Reporting

Report security findings directly to the maintainer through your existing private contact, or use GitHub private vulnerability reporting when enabled on the public repository. Do not place credentials or sensitive payloads in public issue reports. Include the release version or source commit and the affected host platform.

## Reconciled substrate and task boundaries

Every substrate uses the same Core selection, local confirmation/policy and RCIR
admission machinery. Kafka acknowledgements and Kubernetes HTTP/process success
remain provider acceptance. Host-selected observations use separate scoped
observer authority. Kubeconfig, broker credentials, OAuth grants, native Keychain
secrets and provisioned receipt signing keys stay at the executing node. D-Bus
pins the live bus incarnation/unique owner and reviewed UID authority. WASM
requires integrity-bound component/tools/runtime snapshots and bounded execution;
a compiled descriptor does not demonstrate compatible execution.

The short threat model is request/contract/target substitution, replay or ambiguous
retry, stale or revoked provider authority, fabricated verification, and untrusted
storage. Link authenticates bounded versioned requests/results and durable owned
status context. Core compares the current full capability contract; the host
checks current graph/authority/policy immediately before an atomic lease start.
Lease expiry is sampled after external callbacks inside the admission lock.
MCP artifact acquisition rechecks the actual server contract and selected local
credential bytes at final admission. Server-side changes after that final check
cannot be made atomic by the supported MCP protocol and remain a limitation.

Provider-supplied RCIR fields do not prove local admission. Process-local host
and authenticated-node provenance bind exact invocation/action identity and are
excluded from JSON. Delegated verification checks exact original predicates for
success and failure; missing, contradictory or substituted evidence cannot become
verified merely because an outer Link result is signed. Inner receipt trust uses
independently provisioned issuers/keys/task/lease expectations. A receipt from a
second runtime's untrusted signing key is rejected. Version 1 receipts do not
independently claim a runtime or capability fingerprint; future receipt export
must add explicit binding rather than infer it from a transport signature.

Link delivery history cannot be recreated silently after deletion/corruption.
The RCIR journal additionally pins trusted ancestry and a durable identity anchor;
old initialized journals without that anchor need an operator-reviewed migration,
not an automatic empty-history reset. Owned status never retries a mutation.
An offline node or lost connection supplies uncertainty, never fabricated success.
The caller's routed-task map remains volatile; execution-node durability does not
imply caller-process restart recovery.
