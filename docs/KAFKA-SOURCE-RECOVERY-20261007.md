# Kafka source recovery after mirror replacement

The shared mirrored project checkouts disappeared unexpectedly at approximately
18:06 UTC on 2026-10-07. No agent intentionally removed these checkouts.

This checkout restores the original retained base commit
`b1e4db936ba2a5adc41ef0aa70d1b2b7fd0bf5c3` and replays sixteen task-owned source
write patches in their recorded chronological order. The three production files,
three test files and original evidence narrative are reconstructed source.
The replay never executes historical shell/JavaScript instructions; it applies
only the exact whitelisted source patches as data.

`evidence/kafka-source-recovery-20261007/manifest.json` records the reconstructed
file hashes, patch hashes and surviving command output evidence. The original
`b0154d0`, `44080f1`, `b6a8641` and `eb8e218` commit objects and RED/GREEN raw
manifests have not yet been recovered. Consequently this restoration does not
claim hash equality against an unavailable original manifest, a new test run,
or retention of the deleted raw transcripts. Prior scoped GREENs in
`KAFKA-ACQUISITION-STABILITY-20261007.md` are historical results recorded before
replacement, with surviving command summaries; they are not fresh acceptance
of recovered bytes. The original ready-then-unavailable cause remains unproven.

The semantic delta remains narrow: data-free bounded process measurements and
an immutable executable-only pool with full current-byte validation, fixed
entry/byte/retention budgets and final return/dispatch checks. Credentials,
signers, policies and provider metadata are not cached. No provider restarts,
timeout widening, extra public tools or credential mutations were performed.

Integrate the recovered source delta only after review against current platform
guards, then rerun the meaningful controls against the exact recovered candidate.
Do not discard the original missing-evidence condition when new evidence passes.
