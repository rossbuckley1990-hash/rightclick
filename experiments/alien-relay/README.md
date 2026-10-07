# RIGHTCLICK Alien Relay

This experiment asks whether an AI with only RIGHTCLICK's seven generic operations can discover a remote infrastructure capability at runtime, materialize remote compute, and obtain machine-readable evidence from that compute without adding provider-specific AI tools.

## Safety boundary

- Experiment branch only.
- No merge is performed automatically.
- No release is created.
- No repository/org permissions, secrets, environments, or production settings are changed.
- Failures are recorded as evidence; they are not rewritten as success.

## Proof flow

1. RIGHTCLICK discovers the GitHub REST/OpenAPI capability surface dynamically.
2. RIGHTCLICK creates this isolated branch from an observed `main` SHA.
3. RIGHTCLICK writes this experiment and its cloud workflow using the generic reflected OpenAPI capability.
4. GitHub Actions starts a fresh Ubuntu runner in the cloud.
5. The runner checks out the branch, attempts `swift build` and `swift test`, and captures toolchain/runtime evidence.
6. The runner emits `rightclick-alien-proof.json`.
7. The artifact can be read back and compared with repository state.

## What this can prove

A fixed seven-operation AI-facing interface can discover and safely operate a previously unseen remote infrastructure surface, cause a different operating system in the cloud to execute repository-defined work, and preserve evidence of the result.

## What this does not prove

Provider acceptance is not semantic success. The experiment is only successful if the remote workflow actually runs and the resulting artifact is observed. Any missing command, build failure, test failure, or unavailable runtime identity must remain visible in the evidence.
