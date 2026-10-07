# Product state — v0.2.1

RIGHTCLICK reflects capabilities from software and services already present in the environment instead of requiring a bespoke MCP server for every provider.

The runtime currently combines generic macOS capability reflection with dynamically discovered OpenAPI providers.

The same capability engine backs the CLI and seven MCP tools:

    context_inspect
    context_actions
    context_explain
    context_run
    context_run_status
    context_providers
    context_runtime

Dynamic OpenAPI support includes plain-text operations, supported structured JSON object operations and supported GET path-parameter operations. Unsupported or ambiguous schemas abstain rather than guessing.

OpenAPI authority is generic and origin-bound. Supported bearer requirements are resolved without exposing the secret through capability metadata, and authority is not forwarded across origin boundaries.

Invocation acceptance is not treated as semantic success. Where an explicit verification specification exists, RIGHTCLICK can distinguish verified success, verified failure, accepted-but-unverified execution and unavailable capabilities.

Bonjour-discovered OpenAPI providers can appear, disappear and reappear with a new capability identity. Stale capability IDs become unavailable.

Local onboarding preserves unrelated MCP configuration and requires explicit consent for mutation.

ChatGPT onboarding uses the stable Homebrew executable, transactional owned-file migration, live process attestation, persistent tunnel identity and fail-closed tunnel-profile integrity checks.

Homebrew upgrade continuity is tied to /opt/homebrew/bin/rightclick, not a versioned Cellar or development path. A changed stable binary causes bridge restart and setup-state SHA reconciliation without changing the persistent tunnel identity.

The final v0.2.1 code acceptance ran 219 tests with 0 skipped and 0 failures under live fixtures.

The release remains bounded to the environments and provider contracts actually tested; it does not claim universal software compatibility.
