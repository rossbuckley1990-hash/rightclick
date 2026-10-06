# MOAT-005 - Federated Capability Graph

RIGHTCLICK federation lets one authenticated RIGHTCLICK runtime reflect capabilities from another RIGHTCLICK runtime without adding provider-specific model-facing tools.

## Invariant

The AI-facing surface remains the existing seven operations:

- context_runtime
- context_inspect
- context_actions
- context_explain
- context_run
- context_run_status
- context_providers

A federated capability is an ordinary capability owned by an ordinary reflector.

## First proof boundary

The initial production slice is deliberately conservative:

- peers are explicitly configured;
- transport is RIGHTCLICK's existing authenticated HTTP MCP endpoint;
- peer endpoints must be loopback HTTP;
- bearer values are loaded from named environment variables, never embedded in peer configuration;
- the execution peer keeps provider authority local;
- every federated capability requires confirmation at the caller runtime;
- federated capabilities are not re-exported, preventing federation loops;
- asynchronous sharing-service capabilities are not federated in this first slice;
- peer failure fails closed by exposing no capabilities;
- caller-declared semantic verification is evaluated by the execution peer and returned as RIGHTCLICK evidence.

## Configuration

Runtime B:

    export RIGHTCLICK_MCP_TOKEN='...'
    rightclick mcp --http --port 8877

Runtime A:

    export RIGHTCLICK_FEDERATION_PEERS='[
      {
        "id": "claude",
        "name": "Claude RIGHTCLICK",
        "endpoint": "http://127.0.0.1:8877/mcp",
        "tokenEnvironment": "RIGHTCLICK_FEDERATION_CLAUDE_TOKEN"
      }
    ]'

    export RIGHTCLICK_FEDERATION_CLAUDE_TOKEN='...'
    rightclick mcp

The federation bearer authenticates runtime A to runtime B. It is not a provider credential. Credentials used by a provider behind B remain at B's execution boundary.

## Capability identity

A remote action is reflected locally as:

    federation:<peer-id>:<remote-capability-id>

Remote capabilities whose ids already start with federation: are discarded, preventing transitive loops in the first release.

## Verification boundary

Ordinary capabilities continue to use the caller runtime's OutcomeVerifier.

Federated capabilities implement CapabilityVerificationReflector. When the caller supplies a VerificationSpec, RIGHTCLICK delegates that explicit specification to runtime B. Runtime A will accept delegated verified success only when the returned execution has all of:

    state = succeeded
    verification.status = VERIFIED_SUCCESS
    evidence.outcomeVerified = true

A claimed success without that evidence is downgraded to accepted.

## Acceptance target

    OPENAI_TOP_LEVEL_TOOLS_ADDED=0
    ANTHROPIC_TOP_LEVEL_TOOLS_ADDED=0
    PROVIDER_SPECIFIC_RIGHTCLICK_BRANCHES=0

    PROVIDER_CREDENTIAL_EXPOSED_TO_CALLER=NO
    FEDERATION_TOKEN_EMBEDDED_IN_CONFIG=NO

    REMOTE_CAPABILITY_DISCOVERED=YES
    REMOTE_CAPABILITY_EXECUTED=YES
    REMOTE_VERIFICATION_DELEGATED=YES
    REMOTE_RESULT_INDEPENDENTLY_VERIFIED=YES

    CAPABILITY_APPEARED_LIVE=YES
    CAPABILITY_DISAPPEARED_LIVE=YES
    TRANSITIVE_FEDERATION=BLOCKED
    UNREACHABLE_PEER_FAILS_CLOSED=YES

## Intended live proof

1. Runtime B exposes a capability A cannot see directly.
2. Runtime A is configured with B as a peer.
3. ChatGPT connects only to A and calls context_actions.
4. The B-only capability appears without a new ChatGPT tool.
5. ChatGPT confirms and invokes it through context_run.
6. Runtime B resolves provider authority locally and executes.
7. Runtime B evaluates the caller-declared postcondition.
8. Runtime A receives verified evidence but never receives B's provider credential.
9. The capability is removed from B.
10. The same ChatGPT connection repeats context_actions and the capability is gone.

Claude, ChatGPT, Codex, Cursor, or another MCP client can occupy either client role. The federation layer is model-agnostic.
