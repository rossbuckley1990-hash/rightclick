# Versioned Core advertisement and legacy identity compatibility

Only the existing seven-operation Core Profile is currently advertised. No
Agency or Delegation operation is exposed by this increment.

`context_runtime` now includes `agentABIProfiles`, containing `id: core`,
`version: 1` and the exact seven canonical operation names. This is metadata in
the existing runtime operation; it does not add a negotiation tool. The actual
stdio `tools/list` definitions were independently compared with that advertised
profile and matched exactly.

## RUNTIME-IDENTITY-COMPATIBILITY: RED→GREEN

- **Exposing substrate:** RIGHTCLICK federation / legacy Core clients. The actual
  installed v0.2.2 runtime identity has seven fields and no platform declaration.
- **Generic deficiency:** the portable candidate's synthesized decoder required
  its newly added platform field. An unchanged valid legacy identity failed
  decoding, despite the intended Core compatibility. The new runtime also had
  no versioned profile advertisement for future profile-aware clients.
- **Reusable primitive:** backward-compatible identity decoding preserves
  required provenance fields and leaves omitted remote platform as `unknown`.
  An absent profile remains absent rather than guessing that the remote
  advertised it. The current host advertises the versioned Core contract.
- **Thinnest provider layer:** zero new substrate code. Federation and client
  attestation share the same runtime identity boundary; old consumers continue
  to ignore additive JSON fields.
- **GREEN evidence:** exact captured installed identity, frozen two-test RED with
  two failures, then 12 runtime/federation/MCP compatibility tests with zero
  failures. An actual stdio process advertised the same seven operations as its
  live catalogue, executable SHA-256
  `2e0a3f1aff4e7606cdbda82c76ab36d22fd7b2c225272b28d85447ae7a66aa71`.
  Evidence is in `evidence/runtime-profile-compatibility-20261007/`.
- **Transfer:** future universal Agency/Delegation profiles can be versioned in
  the same operation while retaining Core. No future operation is justified or
  accepted merely by being listed in the goal; it still needs its own proof.

Profile declarations are descriptive metadata, not execution authority or trust.
Native Windows/Linux profile parity, final combined source regression and
installed release acceptance remain separate gates.
