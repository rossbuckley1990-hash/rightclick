# Finite typed component contracts

The existing WASM resolver now lowers one no-import component world into the
existing `CapabilityInterfaceReflector` and RCIR host. Direct function exports
remain supported. Named exported interfaces use exact qualified function names,
including their package version; invocation never relies on an ambiguous bare
function lookup.

The supported value subset is string, bool, s8/s16/s32/s64, u8/u16/u32, bounded
lists, closed records, transparent aliases to those types, and declared absence
of a result. Numeric domains use the common `CapabilitySchema.integerRange`
addition from GraphQL source `8de249b422fc3808ef27948b621f88b194c33b58`.
The attributed dependency commit can be dropped when that common change is
already integrated. Existing integer canonical bytes and value kinds are unchanged.

Non-string arguments use the existing `taggedNonStrings` Core compatibility
adapter. String arguments stay literal. WIT declarations, referenced definitions,
qualified export identity, actual WIT digest, and component/tools/runtime hashes
remain committed by the existing capability and invocation contracts. There is
no additional admission ledger, policy engine, task engine, observer, or signer.

Wasmtime components exchange WAVE values, which differ from JSON. The finite
schema-directed conversion preserves exact UTF-8 strings, including NUL and
Unicode escapes; checks integer bounds, bool identity, closed record fields and
list elements; rejects duplicate/missing/unknown fields, trailing values,
malformed UTF-8 and excessive depth/nodes/bytes. Unit writer output `()` lowers
to the existing host's declared no-output completion. It remains unverified in
the absence of an applicable host postcondition.

The existing private lifetime-managed component/tool/runtime snapshots,
source-freshness withdrawal, one-use admission, exact scope, sanitized child
environment, direct argv transport, fuel, memory, deadline and output bounds are
retained. Imports, cyclic or excessively expanded type graphs, resources,
variants/options/results/tuples/flags, char/floats, u64, async functions,
futures and streams abstain. The whole u64 domain does not fit the existing
Int64 value representation; it is never truncated, rounded, or disguised as a
string. Unsupported cases remain explicit acquisition gaps.

# Frozen real-component pressure

The frozen production baseline is PR49 source
`e09f0179f738189fb30b87c652a5433fba648054`; native macOS executable SHA-256 is
`d722c02b4f639e47f56dc848d69e3348ff73435774d35560ead517a7319a6208`.
It advertises only the seven public operations. The real component is absent,
then introduced; wasm-tools validates it and acquires its actual WIT, while the
baseline acquires none of its valid record/list/unit exports. The desired test
fails before any implementation change.

`examples/universal-descriptors/typed-record.component.wat` is a real no-import
component. Its record operation computes UTF-8 FNV-1a32 plus an exact signed
offset, returns a record with a u32 and bool, echoes a u8 list, and supplies a
unit operation. The immutable component SHA-256 is
`98dc973dfd0cf49bae3c50358abfe7badf58e819400c2dbaf9c1dfc18d5467c5`.
The frozen seven-operation harness SHA-256 is
`c3039aeaed0ddc6862c6fca6e7b3e31e98df8188c4272f1778623c5bbf83c208`.
It computes the expected record independently in Python, distinguishes accepted
from verified returned-value postconditions, checks wrong-result and typed-input
negatives, confirms policy denial and live withdrawal, and checks signed
receipts with an independently derived, separately pinned disposable public key.
Private signing seeds are deleted and never included in evidence.

The proof is an engineering pressure test, not the fresh-AI eleven-world run.
Returned-value verification establishes the declared deterministic result;
it does not establish an external filesystem or network effect. Native platform
proof, independent review, the complete eleven-world experiment, clean released
installation and release alignment remain required gates. No installed product,
main branch, release tag or Homebrew pin changes in this slice.

The pinned official toolchain is wasm-tools 1.261.0 and Wasmtime 49.0.2. Their
actual native binaries are hashed in evidence. Wasmtime's qualified invocation
syntax is specified in its [versioned CLI source](https://github.com/bytecodealliance/wasmtime/blob/v49.0.2/src/commands/run.rs).
The [WIT reference](https://component-model.bytecodealliance.org/design/wit.html)
defines native type domains, and the [official WAVE documentation](https://github.com/bytecodealliance/wasm-tools/tree/main/crates/wasm-wave)
defines component text values.
