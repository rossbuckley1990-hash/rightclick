# Security

Discovery is not approval. RIGHTCLICK reflects contracts declared by installed software; that metadata is not a cryptographic claim that a provider is safe. External-share, destructive, financial, and unclassified actions require confirmation. Classification uses metadata heuristics, including text-return contracts; it does not inspect provider implementation or prove absence of side effects. A friendly title or returned-text contract is not proof of safety. Confirm sensitive operations and trust the installed provider. Action extensions fail safely as unsupported.

`NSPerformService` returning true means invocation was accepted. It does not prove completion or an external semantic result. Agents should distinguish discovery, applicability, payload construction, invocation, completion, and independent outcome verification.

## Remote access

Streamable HTTP binds only to loopback and requires a bearer secret. Missing or invalid authentication returns 401. Requests with negative, invalid, or excessive Content-Length, unsupported transfer encoding, or an incomplete body are rejected. The small HTTP listener is intended for one user's Mac; it is not a general-purpose internet server.

`rightclick serve` stores its secret in `~/Library/Application Support/RIGHTCLICK/token` with owner-only permissions and prints it at startup. Protect captured terminal output. `rightclick auth rotate` prints a replacement secret; restart serving processes afterward. The current process keeps its existing credential until restart.

`--tunnel` explicitly starts a temporary Cloudflare development tunnel if available. Use authentication and an appropriate TLS boundary whenever deliberately exposing the service. No tunnel is required for local Cursor use. Do not commit or publish secrets, auth traces, or live private tunnel details.

## Local data and logs

Execution diagnostics can contain the exact input text or URL. They are written to stderr and, when permitted, `evidence/execution/share.log` relative to the working directory. MCP startup logs under `~/Library/Logs/RIGHTCLICK/` contain the executable path and hash. Treat logs as potentially private and review them before sharing. RIGHTCLICK does not isolate a provider from the permissions already held by its installed application.

Homebrew uninstall removes package files, not your Cursor configuration, logs, or token. Remove only the `rightclick` entry from `~/.cursor/mcp.json` when disconnecting; preserve other servers. Remove RIGHTCLICK's support/log directories only if you intend to delete their retained data.

## Reporting

Report security findings directly to the maintainer through your existing private contact, or use GitHub private vulnerability reporting when enabled on the public repository. Do not place credentials or sensitive payloads in public issue reports. Only 0.1.x is supported.

## Portable source candidates

Linux HTTP remains authenticated and loopback-only. Headless environment authority is explicit and origin/scheme bound; it is not secure storage against privileged local processes. Missing native observers must return unknown. The --isolated flag excludes implicit provider configuration; it does not sandbox providers or replace authorization. Consult the tagged release for released platform support; source/CI candidates are not installed product claims.
