# Effortless adoption candidate — 2026-10-07

This increment is stacked on the universal runtime candidate, not a released
product claim. The installed 0.2.2 runtime, accepted main, this source and its
built executable remain separate evidence boundaries. The full eleven-world
restricted-agent experiment and immutable cross-platform distribution gates
remain open.

## Commands

`rightclick setup` detects the existing supported local clients. Cursor, Claude
Code and Codex use the same local transaction on macOS, Linux and Windows source
paths. Claude Code and Codex use their native registration commands; Cursor uses
its existing JSON registration. For a generic JSON MCP client, select an absolute
configuration path:

    rightclick setup --client generic --config /absolute/path/mcp.json --yes

Setup preserves unrelated configuration, refuses conflicts and unsafe links,
backs up changes privately, and records only its owned connection recipe and
executable hash. It runs an actual child MCP lifecycle before and after the
transaction: initialize, exact seven-operation schema, context_runtime, matching
PID/path/hash/profile. This proves that selected executable's local transport.
An AI client's own handshake remains NOT_OBSERVED unless its adapter observes it.
A later configuration edit belongs to that client and is never overwritten by
rollback. Native commands that mutate and then fail are re-inspected before
conditional cleanup; conflicting later registrations are preserved. Rollback
status distinguishes restoration from residual unknown changes.

    rightclick doctor --fix --dry-run --json
    rightclick doctor --fix --json

Repair accepts only recipes in the private ownership ledger, re-inspects current
registration, verifies the selected runtime, and rolls back its own changes on
failure. It does not adopt a same-name registration merely because it exists.
The existing macOS ChatGPT setup/bridge flow is retained; it has separate live
attestation. Windows process-group/job disposal and real Windows/Linux client
integration still require native acceptance; source compilation is not that proof.

    rightclick connect https://provider.example
    rightclick connect https://provider.example/openapi.json
    rightclick connect https://provider.example/graphql
    rightclick connect https://provider.example/mcp
    rightclick connect grpcs://provider.example:443

Connect acquires a declaration, compiles it through the existing resolver, and
requires discoverable capabilities before atomically persisting a bounded
provider descriptor. The default runtime reloads that protected registry, so
additions/removals change an existing process's graph. Connection references
contain no credentials or executables. Redirects and cross-origin declaration
links are rejected; credential-bearing URL userinfo/query/fragment are rejected
without echo. Public discovery uses explicit credential-free ephemeral sessions.
MCP's existing origin-bound operator bearer references still apply at invocation.

The supported connection slice is OpenAPI JSON, public GraphQL introspection or
linked JSON schema, the existing MCP HTTP JSON profile, and supported gRPC
reflection. An optional minimal `/.well-known/rightclick` can contain one
same-origin link to an existing declaration. YAML, executable manifests,
ARD/A2A/federation orchestration, ambiguous multiple links, and Windows durable
registry transactions are explicitly unavailable in this increment. The
existing broader runtime adapters are not removed by that CLI limitation.
Legacy GraphQLHTTP's completion-body bound is a separate audit follow-up; this
connected discovery path uses incremental transport bounds.

    rightclick status --json
    rightclick status <execution-id> --json

Status without an ID reports the serving binary, channel/build facts, detected
client/registration state, actual acquired providers/capability count, and
supported artifact kinds. A supported adapter is not an acquired provider, and
provider acquisition does not prove provider execution health. Missing build
provenance is `unverified`. `scripts/build-cli.sh` embeds development source
facts; it cannot infer Stable/Edge acceptance from an environment, local tag or
branch name. Stable/Edge promotion remains a release gate. Startup file-byte
measurement survives later launcher symlink changes; it does not hash loaded
process memory. Legacy remote identities do not inherit local platform/build
facts when they omit those fields.

    rightclick sandbox --json
    rightclick sandbox --mcp

Sandbox supplies a disposable, declared local provider fixture through the same
RCIR engine and exactly seven MCP operations. It exposes only that fixture,
requires confirmation, writes a bounded challenge inside its private directory,
and independently reads back the exact invocation-bound effect. The demo checks
provider withdrawal and signs the canonical receipt using a fresh ephemeral key.
It imports no installed policy, observers or production signing references. The
key establishes only local sandbox evidence, not managed production trust. This
is a capability-scoped fixture environment, not a general OS sandbox or the
required eleven-world acceptance. Normal fixture lifetime removes its directory;
crash recovery/expiry cleanup remains an open sandbox lifecycle gate.

## Evidence and remaining release gates

Raw exposing failures and integrated checks are retained beneath
`evidence/adoption-20261007/`; each binary acceptance states its concrete hash and
scope. The original rollback, borrowed/persisted cookie, partial native mutation,
client identity and sandbox host-config failures are retained separately from
build/configuration failures. Independent review and full regressions must pass
on the exact submitted source. No tag or tap pin moves while the broader runtime,
platform, restricted-agent, distribution or reconnect gate remains RED.
