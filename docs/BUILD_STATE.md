# Build and acceptance state

Current state is maintained in [V0.1_COMPLETION_REPORT.md](V0.1_COMPLETION_REPORT.md). Earlier numbered experiments are historical records in [EXPERIMENTS.md](EXPERIMENTS.md), not claims that their development servers remain running.

The full XCTest suite has 33 passing tests and no failures or skipped regressions. The release-specific protocol acceptance script exercises a concrete binary over stdio and authenticated Streamable HTTP: initialization, all six tools, contextual discovery, safety confirmation, exact Apple full-width conversion, execution status across requests, and authentication failure. It also checks actual loopback binding and malformed request rejection.

Local Homebrew acceptance uses an archived app bundle installed under the real Homebrew prefix. Version, doctor, actions, providers, setup, installed binary hash, MCP, and uninstall are recorded under `evidence/v0.1-final/`. This rehearsal does not establish public distribution or another Mac's Gatekeeper acceptance.

The ordinary BBEdit install proof remains in `evidence/rightclick-008/`. The single bounded Yojam control and its unresolved outcome remain in `evidence/v0.1-final/yojam/`. The inherited uncommitted lifecycle experiment was preserved before restoring the committed engine.

The public signing, notarisation, Gatekeeper, release asset, tap, and fresh-machine acceptance gates remain blocked. No public launch is claimed.
