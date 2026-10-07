# Dispatch contract binding

RIGHTCLICK keeps the same seven tools, install commands and confirmation flow.
This safeguard runs automatically inside both `CapabilityEngine.run` and
`CapabilityEngine.begin`; there is no new setting or runtime dependency.

During an invocation the environment can change between capability discovery
and reflector selection. A replacement reflector with the same ID is not
sufficient: its applicable catalog must still declare the selected capability's
complete contract before the engine calls `begin`.

The engine rechecks only the selected reflector's catalog, normalizes ownership
as it does during discovery, and compares sorted JSON-encoded snapshot bytes.
This checks the ID, provider, inputs/outputs, safety, invocation mode, confirmation
requirement and all metadata, including endpoint/schema/authority fields. Missing,
conflicting or unreadable contracts return `unavailable` without dispatch.
Equivalent recreated reflectors and identical duplicates remain usable.

## Reuse decision

The design borrows the independently declared execution-edge constraint from
[Actenon Protocol, edge binding](https://github.com/Actenon/actenon-protocol/blob/main/protocol/13-edge-binding.md)
(reviewed document blob `43cb801771d0ce0a8a224a0eb2f7bc1b2f56b2e6`). It does **not** import
Actenon code, add an Actenon runtime dependency, implement its proof wire format,
or claim Actenon conformance. A new policy system, signing protocol, authority
CLI, economic ledger, scanner and shell guard are deliberately out of scope.

## Boundary and cost

This is a within-invocation contract revalidation, not a cryptographic approval,
a sandbox, binary attestation, or an atomic lock on a remote resource. It does
not bind a previous `context_explain` call to a later `context_run`, prove that a
provider's declaration is honest, or remove races inside a provider after the
check. Provider-specific concurrency controls still belong at that resource.

There is one additional catalog read for the selected reflector, not an extra
read of every provider. A remote/federated catalog may incur latency; no latency
benchmark or zero-overhead claim is made. Provider acceptance still does not
prove the intended consequence. No new token or credential is exposed.

`DispatchContractBindingTests` exercises both execution entry points, changed
routing/schema/authority, withdrawn or failing catalogs, duplicate declarations,
Unicode byte distinctions, ownership assignment, confirmation and delegated
verification. Run `swift test --filter DispatchContractBindingTests` on macOS,
then the full existing suite before release.
