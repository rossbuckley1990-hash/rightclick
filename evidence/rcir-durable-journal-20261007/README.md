# Protected journal crash boundary

Validated source: `13d7210be00dd8d4fde654a5b90a213c24b5a182`. This is a scoped private macOS/Linux journal proof, not universal-runtime or release readiness.

The unchanged frozen acceptance script uses exactly seven public operations with a real isolated A2A provider. An independent nonce-bound effect is witnessed; RIGHTCLICK receives SIGKILL before observation, restarts as another process, and recovers the original task/execution as UNKNOWN. Four repeated status calls remain stable. There is exactly one provider mutation, zero restored polling, and no raw invocation/provider payload in journal storage.

- `red/`: exact source `2dd7bd2` and executable SHA `80f5e787…` lose the invocation identity after restart. The earlier setup error is retained separately.
- `green-macos/`, `green-linux/`: final source, exact serving executable paths/SHA/PIDs, complete seven-operation transcripts and independent effect/request traces.
- `final-13d7210/`: full macOS 797 tests / 31 skips / zero failures; native Linux 585 / 24 / zero. Journal controls are 22 macOS and 21 Linux; the Darwin ACL control is platform-specific.
- `observer-focused-13d7210/`, `observer-full-green-13d7210/`: disposable effects, observer requests and negative authority/redirect controls retained for the intermittent existing macOS observer fixture failures.
- `intermediate-*`: failures and superseded proofs retained honestly, including missing observer rows and the pre-existing Linux D-Bus defaults test expectation. No observer assertion or production safety check was weakened.

`manifest.json` binds source, platform/compiler/image, binary hashes, recovery provenance and open gates. `artifacts-sha256.json` binds retained artifacts. The archive recovery commit explicitly records that original unpublished local Git objects were lost; exact tracked file bytes were compared with the immutable archive. The local three-line Linux defaults correction is blob-identical to upstream `5349c733` and can be omitted during convergence.

UNKNOWN identities cannot expire or be evicted to admit new mutations. Recovered historical success has no fresh verified-success claim. Default execution remains volatile; Windows durable storage, receipt archival, supervised reconciliation, resumable sessions, power-loss proof and the eleven-world/release/clean-install gates remain required. The read-only package alignment comparison remains RED for Kafka/MCP/WASM taxonomy.
