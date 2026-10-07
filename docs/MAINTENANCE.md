# Repository maintenance gates

Maintenance is evidence-gated, not merge-every-green automation. Apply this policy to RIGHTCLICK and its Homebrew tap while preserving unrelated active work.

## Before merging

Review the full relevant diff and unresolved review threads. Re-read the current base and exact head. Require the applicable native, portable and integration checks to complete successfully at the reviewed candidate; missing, skipped, cancelled or obsolete checks are not passes. Re-test after integration changes. Use expected-head protection, normal branch protections and independent remote read-back. Do not force-push, weaken tests, merge intentional RED experiments, or replace a concurrent maintainer's work.

## Before publishing

Freeze a reviewed release commit. Run the complete relevant suite, CLI/package build and MCP/core/federation acceptance against the actual candidate. Preserve immutable tags. Download the published source asset and hash its bytes before advancing the tap. Preserve dependency/resource pins and required notices. A version label or HTTP 2xx is not release acceptance.

The tap's standard reviewed-head brew pr-pull path publishes binary bottles. Independently check the bottle release, platform metadata, downloaded hashes and actual installed/extracted-binary behaviour. Do not attach old bottle checksums to a new version or call a source tarball a prebuilt bottle. Keep pairing state separate from installation and attest the connected runtime after a deliberate runtime upgrade.

## Documentation and evidence

Keep READMEs, agent guidance, stable version claims and the tap coherent. Label illustrations, historical experiments, raw live recordings, portable components and unshipped features separately. Preserve failures and raw evidence rather than editing an experiment into apparent success. Media captions must not claim more than their underlying records establish.

Scheduled checks are periodic observations, not a continuous uptime guarantee. Report substantive regressions, release drift, failed fresh installations and blockers; avoid repetitive unchanged-state notifications. An unavailable runner or credential is a blocker to state explicitly, not a reason to bypass a gate.
