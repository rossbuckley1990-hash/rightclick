# Provider discovery examples

These candidate helpers generate optional metadata for an existing OpenAPI JSON declaration, GraphQL introspection endpoint, or MCP JSON-response endpoint. They require no RIGHTCLICK library and make no network request. Serve their output as `application/json` at your existing service's `/.well-known/rightclick` route:

```json
{"schemaVersion":1,"links":[{"kind":"openapi","url":"/openapi.json"}]}
```

The operator can then run `rightclick connect https://service.example --json`. The current connector validates the manifest, acquires the declaration from that selected origin, and persists its reference after discovery succeeds. A manifest adds no AI operation and selects no credential or local executable.

Each helper emits exactly one link. It accepts only a root-relative ASCII path up to 4096 bytes, with no query, fragment, percent escape, directory traversal or separate authority. Paths are conservative by design; use `/openapi.json`, `/graphql` or `/mcp`, or another safe existing declaration path. The service must already implement that standard.

```sh
python3 examples/provider-discovery/python/manifest.py openapi /openapi.json
go run examples/provider-discovery/go/main.go graphql /graphql
```

TypeScript exports a function for your existing application. Compile with your TypeScript toolchain or import the source in that application:

```typescript
import { discoveryJSON } from "./typescript/manifest.js";
const responseBody = discoveryJSON("mcp", "/mcp");
// Return responseBody from /.well-known/rightclick as application/json.
```

These examples cover the current one-link manifest profile. They provide no server, authentication adapter, package-install proof, execution verification or portable release attestation. A2A, ARD and federation links are not acquired by this connector. gRPC reflection requires an explicitly selected `rightclick connect grpcs://host:port` endpoint and cannot be selected through this HTTPS manifest. YAML OpenAPI declarations, multiple links and SSE-only MCP responses are also outside the current acquisition profile.

Keep declaration endpoints current: a successful connection establishes discovery, while execution and independent effect verification remain separate runtime operations.
