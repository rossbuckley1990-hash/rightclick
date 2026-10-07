# GraphQL typed execution

GraphQL introspection now lowers supported operations into the existing common
capability contract. The seven AI operations, execution host, authority scope,
confirmation requirements, freshness checks and receipt signer remain shared.

The compiler records closed input objects, lists, enums, nullable values,
booleans, strings, exact signed 32-bit integers and finite numbers. An additive
`CapabilitySchema.integerRange` expresses narrower integer domains without a
new value kind or changing existing integer canonical bytes. Required fields
respect GraphQL defaults; omitted defaults remain part of the pinned provider
declaration and are applied by the provider.

One bounded traversal builds both the query selection and its result schema.
Selected object fields must exist and have the declared types. A whole-valued
GraphQL Float remains a number in the signed completion event. Unknown custom
scalars and recursive inputs abstain. Object selections retain the existing
three-level and sixteen-field limits; abstract types return only `__typename`.
This is a conservative compiler subset, not full GraphQL or subscription support.

`argumentsSchema` continues to describe the public text compatibility boundary.
`typedArgumentsSchema` and `typedResultSchema` explain the structural contracts;
`argumentSchema` and `resultSchema` retain their canonical bytes in base64.
Scalar text and JSON-encoded list/input-object text are converted and validated
before common admission. Nested numeric booleans, overflowing integers,
undeclared fields, invalid enums and null at non-null positions fail before
provider transport. This conversion is explicit compiler behavior.
For top-level nullable String/ID, `null` denotes null and a leading backslash
forces literal text after removing that one escape. Thus `\null` supplies the
literal string `null`, and `\\text` supplies a string beginning with a backslash.
Non-null String/ID remains literal text. Existing callers passing a leading
backslash to a nullable String/ID must now prefix a second backslash; explanation
metadata advertises this compatibility rule. Nested JSON strings remain literal.

The existing `RCIRUnaryInvocation` has one typed admission implementation. Its
text-only wrapper delegates to it, so other existing unary compilers keep their
exact string contracts. GraphQL supplies typed arguments and selected response
data to that same path. A schema-invalid provider response after dispatch becomes
`UNKNOWN`, with no observation-based promotion and no automatic retry.

Provider completion remains `accepted/unverified`. A host-selected independent
observer can verify a requested state. The simple HTTP readback used here does
not establish current mutation causality; an invocation-bound observer is still
required for that stronger claim. A valid signature authenticates receipt bytes
under the separately provisioned public key, not the provider's truthfulness.

## Frozen evidence

The original real HTTP pressure harness was frozen at `9e19644` before product
changes. It uses official `graphql-core==3.3.0`, randomly named operations,
independent native GraphQL execution, external filesystem state, HTTP readback,
and only the seven RIGHTCLICK operations for runtime actions. The driver is
deterministic engineering infrastructure, not a fresh restricted AI.

| Source / binary | Controls | Result |
| --- | --- | --- |
| Baseline `2dd7bd2`, binary SHA256 `80f5e7875f84deaeeeb04ced3f5d2d7137ad046a0a8af8a91887532253f1100a` | Original 21 | 12 pass, 9 fail |
| Candidate `8de249b`, binary SHA256 `6289eca7251610d555cd5168608e437ed0625fded252d49207a09e5c16ad020e` | Identical original 21 | 21 pass |
| Candidate `8de249b` | Full native macOS suite | 777 tests, 31 explicit skips, zero failures |
| Final `6564f59`, binary SHA256 `3f798561ec1e285c52ed0d7ffe21ac1aa2b53c42d99886d2f8bc2006ef324644` | Frozen 27-control superset | 27 pass |
| Final `6564f59` | Full native macOS suite | 777 tests, 31 explicit skips, zero failures |

The nine baseline failures cover custom-scalar abstention, typed input/result
schemas and receipt values, numeric-boolean pretransport denial, integer range
pretransport denial, malformed result uncertainty and whole Float typing.
The eight focused native tests include the existing six GraphQL tests plus two
post-implementation generic integer-range controls; those two tests are not
misrepresented as preregistered RED tests.

Six additional nullable-string controls were frozen at `7851090` and run against
the preserved `8de249b` executable before the escape correction: 24 of 27 controls
passed and exactly three literal-string escape cases failed. All original 21
controls remained unchanged in meaning. The new source supplies an explicit,
lossless nullable-string escape rather than conflating literal `null` and null.

The scalar domains follow the [GraphQL September 2025 specification](https://spec.graphql.org/September2025/).
The real provider uses the [official GraphQL-core reference port](https://github.com/graphql-python/graphql-core).

Evidence under `evidence/graphql-typed-20261007` pins raw transcripts, schema,
external effects, readbacks, public signing key, receipts, native logs, binary
provenance and artifact hashes. Private signing material is ephemeral and absent
from the evidence. Full Git bundles, source archives and executable copies are
also retained outside the project mirror.

The published Homebrew comparison remains RED: its installed product lacks the
candidate's existing MCP, WASM and Kafka acquisition kinds. The GraphQL world
and release gates remain RED until the same-session fresh-AI eleven-world proof,
reviewed convergence, platform checks and release/clean-install gates pass.
