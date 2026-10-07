# RIGHTCLICK 0.2.1

RIGHTCLICK's north star is simple:

Install software. Your AI learns what it can do.

v0.2.1 combines the current OpenAPI capability-reflection work with hardened local and ChatGPT onboarding.

## Dynamic capability acquisition

RIGHTCLICK can discover supported OpenAPI providers and reflect their operations behind the same generic MCP interface rather than adding provider-specific tools.

This release includes support demonstrated by the accepted regression suite for:

- plain-text OpenAPI operations
- supported structured JSON object operations
- supported GET path parameters
- provider removal and capability loss
- provider replacement with new capability identity
- explicit outcome verification
- origin-bound bearer authority

Unsupported or ambiguous contracts abstain rather than guessing.

## Authority and network safety

Generic bearer authority is bound to the discovered provider origin.

Secrets are not exposed through reflected capability metadata, missing authority fails before transport, and redirects cannot carry authority to a different origin.

The final live origin-authority acceptance produced zero requests at the forbidden cross-origin sink.

## ChatGPT onboarding and persistence

rightclick setup chatgpt now provides a bounded migration path for the persistent ChatGPT bridge.

The release includes:

- stable Homebrew persistence through /opt/homebrew/bin/rightclick
- transactional owned-file migration
- live runtime/process attestation
- Homebrew upgrade continuity
- setup-state SHA reconciliation after upgrade
- persistent tunnel identity
- fail-closed tunnel-profile integrity checks
- rejection of development and stale Cellar entrypoints

A redirected tunnel profile cannot silently cause the persistent ChatGPT tunnel to execute a foreign RIGHTCLICK binary.

## Acceptance

The integrated release code passed:

- 219 tests
- 0 skipped
- 0 failures
- 8/8 real live-fixture tests
- 7/7 generic bearer-authority tests
- three consecutive independent Bonjour lifecycle runs
- real OpenAPI execution
- exact acquisition byte-boundary tests
- five-second acquisition deadline
- zero forbidden cross-origin sink requests

Historical evidence from earlier releases remains preserved rather than rewritten.

## Install

    brew install rossbuckley1990-hash/tap/rightclick
    rightclick version

For a local supported MCP client:

    rightclick setup

For the persistent ChatGPT bridge:

    rightclick setup chatgpt --dry-run --json
    rightclick setup chatgpt --yes

## Limits

RIGHTCLICK does not claim that every installed application exposes a usable capability contract.

Provider acceptance is not automatically treated as verified real-world success, and unsupported contracts abstain.

Runtime deployment targets Apple Silicon and macOS 14 or later.

The final acceptance described above was performed on the proof Mac.
