# Restricted RIGHTCLICK client acceptance

`scripts/restricted-core-probe.py` brokers the seven RIGHTCLICK operations to a fresh ephemeral Codex app-server thread. It preserves one RIGHTCLICK process and one AI thread across an operator-authored phase plan. Provisioning, provider withdrawal and independent oracles run as fixed host commands outside the model's tools.

The supplied tool catalogue must contain exactly seven unique canonical names. The runner compares the native client's captured function schemas and descriptions with the actual MCP declarations, rejects unknown tool-bearing request fields, and checks the serving runtime's executable attestation against the launched bytes. The only schema equivalence is omitted object `properties` versus `{}` at schema-bearing positions; constraints and opaque defaults/examples remain exact.

The native Codex executable is resolved from the installed official npm layout or supplied directly with `--codex`. The requested entrypoint and native executable hashes are recorded separately. The runner launches the native executable directly and pins its bytes across preflight and actual runs, before forwarded model calls and at completion. Unknown launchers abstain. The locally inspected client was version 0.159.3; dynamic tools use its experimental app-server protocol. See the [official app-server documentation](https://developers.openai.com/codex/app-server/).

## Separate catalogue and actual gates

First capture the outgoing catalogue using the local no-inference endpoint:

```sh
python3 scripts/restricted-core-probe.py \
  --runtime /absolute/path/to/rightclick \
  --output /private/tmp/rightclick-catalogue
```

Then run the real AI session against the same runtime, native client, configuration, restricted model catalogue, instructions and declarations:

```sh
python3 scripts/restricted-core-probe.py --actual \
  --runtime /absolute/path/to/rightclick \
  --catalog-proof /private/tmp/rightclick-catalogue/summary.json \
  --plan /absolute/path/to/operator-plan.json \
  --output /private/tmp/rightclick-actual-session
```

Each output directory must be new. The runner preserves bounded transcripts and incomplete runs. It neither resends an uncertain RPC nor replays a phase. Host command failures and interrupted AI turns remain failures. A model could still choose a new repeated invocation after UNKNOWN; the instruction prohibits that, but these client controls do not prove semantic deduplication.

The catalogue capture is a separate local preflight. The actual production model request is **not intercepted**. Its summary says `PREFLIGHT_MATCHED_ACTUAL_REQUEST_NOT_INTERCEPTED`. Local proof files are trusted operator evidence, not signed attestations against same-principal file tampering. The model's observed calls and answers establish actual inference only when their thread and turn match the active session.

For a read-only client check, add `--discovery-only` to **both** commands. All seven declarations remain visible; the host denies `context_run` before runtime dispatch. The permission and instructions are included in proof matching. This mode cannot establish execution acceptance.

## Host phase plan

A plan is a closed version-1 object containing 1–16 phases. Each phase has `name` and `prompt`, plus optional `before` and `oracle` argv arrays. The operator selects fixed commands; model arguments never become shell commands. Successful oracle exit codes allow continuation and do not establish semantic acceptance on their own. Provider bootstrap, credentials, issuer grants and observer trust remain host responsibilities.

The runtime and client use bounded JSON frames and transcripts. Cleanup terminates the entire owned POSIX process group even when its leader already exited, with bounded TERM/grace/KILL/wait and stream closure independent of evidence-write failure. Host timeout cleanup follows the same rule. This runner requires POSIX pipe/process-group support; native Windows runtime evidence is separate.

## Preserved result

[The evidence manifest](../evidence/restricted-core-20261007/manifest.json) pins the original deficiencies, reviewed production source `f2acd72`, native executable bytes, controls and transcripts. Seventeen controls passed: four native-client identity/catalogue controls, four schema comparisons, three security/write-failure controls, three real owned-descendant cleanup controls, and three controlled notification-attribution checks. The notification checks use fake RPC events and claim no AI inference.

The actual read-only check used a fresh AI thread for two completed turns and the same RIGHTCLICK PID 66701. The AI called runtime/providers/inspect/actions, then runtime/providers/explain. Both independent per-turn session checks passed and no capability was dispatched. The serving bytes were the preserved GraphQL `6d7154d` runtime, version 0.2.2; this is separate from the current 0.2.3 convergence candidate and the installed Homebrew executable.

This is client plumbing evidence. `universalAcceptance` remains `NOT_EVALUATED`. Every eleven-world row remains RED until the same fresh restricted agent performs the required real execution, task/stream handling, independent outcome verification, signed receipts and live withdrawal/stale-authority proof. The final release additionally requires integrated native/portable/security checks and immutable release, tap and clean-install verification.
