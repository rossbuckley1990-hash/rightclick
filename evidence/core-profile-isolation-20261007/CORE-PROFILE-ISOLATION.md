# Core-profile acceptance client isolation

This evidence proves outgoing catalogue isolation and a separate fresh AI discovery run. It does not prove complete G13, semantic execution, authority attenuation, or eleven-substrate acceptance.

## Meaningful RED

The exposing substrate was MCP/federation through the Codex acceptance host. The first captured inference request contained 20 tools: the seven RIGHTCLICK operations plus inherited resource helpers, question helper, six collaboration tools, and three Node REPL tools. Those extra engineering tools violated the acceptance boundary even though RIGHTCLICK itself advertised only seven.

The generic deficiency was in the acceptance client boundary, not a missing RIGHTCLICK substrate compiler. Counting only the runtime's MCP tools did not establish what the model could actually use.

Further preserved captures showed 14 tools after disabling global MCP servers and 8 after disabling model-catalogue collaboration support. Removing parent attachment environment keys alone did not remove collaboration tools. Setting the question-tool switch only on the app-server process also left the eighth tool present.

## Reusable primitive and thinnest layer

The reusable primitive is a fresh, ephemeral, read-only acceptance client with an explicit Core-profile catalogue and thread-scoped tool switches. It acquires the seven tool schemas from the live RIGHTCLICK MCP server, declares those as dynamic functions, forwards their calls to the same server, and rejects unexpected server requests or operation names. It does not invent seven substitute implementations.

The provider layer is standard MCP stdio forwarding. No substrate-specific model tool is introduced. The mechanism transfers to every substrate discovered by RIGHTCLICK because the model-facing catalogue remains the same.

The supported `thread/start` override which removed the final question helper is:

```json
{"config":{"tools":{"experimental_request_user_input":{"enabled":false},"update_plan":{"enabled":false}}}}
```

The host retains permission and sandbox restriction environment keys. It removes parent app-tool attachment/session identity keys, disables engineering tools and all currently configured MCP servers for the model, and uses `environments: []`, `ephemeral: true`, no runtime workspace roots, and a read-only network-disabled model sandbox. It does not inspect credentials or modify the user's persistent configuration.

## GREEN evidence

`catalogue-progression.json` names every captured tool and binds the raw outgoing catalogue by SHA-256. The final local capture has exactly these seven functions:

- context_runtime
- context_providers
- context_inspect
- context_actions
- context_explain
- context_run
- context_run_status

This capture used a local inference fixture that deliberately returned a capture-complete error. No model inference occurred in that run; it proves the outgoing request catalogue, not intelligence or provider execution.

The separate `actual-read-only-seven` run used native Codex sign-in and the official OpenAI provider. A fresh gpt-6.1-sol model called context_runtime, context_providers, context_inspect, and context_actions and completed. Its transcript contains real model-selected calls and actual RIGHTCLICK responses. It accurately declined to claim an exact capability count when the returned catalogue was truncated. No capability was executed.

The Codex 0.159.3 executable SHA-256 was `4d210f7c5a18fd0386434df23b5bdbb8c0e7257d3e8a2b30b0769c8bbe99a878`. RIGHTCLICK's actual context_runtime attested executable SHA-256 `eaa0580f2755a3bbea28fd224870952a9b7a9c8666c460fc9575b2d5c44fc979`.

The actual production inference request's catalogue was not directly intercepted. The direct outgoing-catalogue capture and the real inference run use the same client, dynamic catalogue, thread-scoped tool settings, and restrictions; the inference provider differs. This distinction is retained explicitly rather than claiming that a local fixture was the final AI acceptance experiment.

Raw evidence is compressed losslessly with original and archive SHA-256 values in `compression-manifest.json`. Local paths and provider metadata in the raw runtime transcript should undergo the programme's normal privacy review before external publication.

## Reproduction

Run `restricted-core-probe.py` with `--runtime <absolute candidate executable> --catalog-source <public native model catalogue JSON> --run-name <new unique evidence directory>` to capture the outgoing catalogue without inference. Add `--actual` for a real AI run using the existing native client authentication. An optional `--prompt-file` supplies a task to the restricted model; provider credentials must never be put in that prompt. The driver keeps exactly seven operation names and forwards calls to RIGHTCLICK.

The driver's current default is a read-only discovery prompt. Full substrate effects, independent verification, signed receipts, graph mutations, provider generation and stale-authority invalidation remain for the subsequent G13/G17 experiment.

The supported configuration was checked against the exact official Codex source tag [rust-v0.159.3 configuration schema](https://github.com/openai/codex/blob/rust-v0.159.3/codex-rs/core/config.schema.json) and [tool registration](https://github.com/openai/codex/blob/rust-v0.159.3/codex-rs/core/src/tools/spec_plan.rs).
