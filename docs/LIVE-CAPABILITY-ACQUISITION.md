# Live capability contract acquisition

Candidate fix based on `daf07d04ee11be59e3f499f370f0bba5df9998ad`.
This is source code, not evidence that the installed 0.2.2 process has changed.

## Contract

`LiveCapabilityArtifactSource` is an ordinary source and reflector. It adds no
MCP operation and no protocol executor. It reuses `CapabilityArtifactResolverRegistry`.
The default runtime now uses it for environment descriptors and confirmed,
session-scoped acquisition. Existing Bonjour, configured OpenAPI and ARD sources
remain composed. The old configured-artifact class remains available to callers.

Discover an endpoint with `context_actions`, explain the returned acquisition
action with `context_explain`, then use `context_run` after confirmation. For an
HTTPS GraphQL endpoint supply `arguments: {"kind":"graphql","id":"countries"}`.
HTTPS is not assumed to be GraphQL. A grpc/grpcs URL infers only gRPC. An OpenAPI
specification URL requires `kind: openapi` and its explicit `baseURL`.

Alternatively, pass a typed descriptor as the item:

```json
{"id":"countries","kind":"graphql","endpointURL":"https://countries.trevorblades.com/"}
```

This document's examples are instructions for the candidate, not execution receipts.
Discover and explain actions again in the connected candidate before invoking them.

Acquisition updates the same source instance. Read `context_providers` and
`context_actions` again without restarting the process. Use a plain-text query
context to discover existing protocol actions; inspect their detailed metadata
through `context_explain`, not the reduced action view. Invoke a supported read-only
operation separately and independently verify its returned data.

For diagnostic inspection, pass `rightclick:acquisition` to `context_actions`,
then run the discovered `Inspect capability acquisition status` action. The same
item exposes a confirmed `Forget capability contract` action accepting an `id`.
Forgetting changes only session state; it does not modify a remote provider or
persistent startup configuration.

## Safety and failures

Discovery of a new endpoint does not fetch it. Acquisition requires confirmation.
Concrete resolvers retain TLS, loopback, origin, authority and schema restrictions.
Live URLs reject embedded credentials, query strings and fragments. The optional
`authorityScheme` is a stored-credential reference, never a credential value.

Descriptors are bounded to 64 session entries. Unknown arguments and fields,
rebindings and duplicate identities fail closed. Failed refreshes withdraw stale
snapshots. Diagnostics include `invalid_configuration`, `invalid_descriptor`,
`unsupported_kind`, `identity_conflict`, `no_capabilities` and `resolution_failed`.
The last code does not pretend to distinguish a wrapped network, authority or
schema error; arbitrary resolver error text is not exposed because it can contain
secrets or untrusted provider text. Other discovery sources are unchanged.

Acquisition returns accepted/failed and never claims a verified remote outcome.
Session acquisition is not persisted across process restarts.

## Validation boundary

27 fixture tests passed in debug and release on Linux Swift 6.2.1. The portable
harness compiles the production source with explicit test-only model and registry
adapters; it does not build the full product or exercise real protocol resolvers.
Two additional macOS-only engine tests cover confirmation denial and same-engine
graph growth plus retained receipts. They have been added but not run here.

Before merge/deployment, run the full native suite, MCP ABI acceptance, existing
substrate regressions and `python3 scripts/detect-bottle-alignment.py --compare`.
Then rebuild/reconnect the candidate and attest its executable hash. Prove real
GraphQL/gRPC acquisition, invocation and independent verification through the
seven operations in that connection. No GitHub Actions experiment was added.
