# MOAT-004 G1 artifact policy

The G1 causal ordering is preserved in Git history:

1. frozen RED/preregistration: `5e76581df0dc625f63a9a4f93631fcc7f63b4bda`
2. preregistered G1 test commit: `a503c63991c7d06531ee5a68ce5c0d0f8e30120e`
3. G1 implementation commit: created only after the tests were red and then green

The original `G1-001-preregistered-tests.patch` is intentionally preserved.
It is empty because it was produced with `git diff -- <untracked-file>`,
which does not include untracked files.

The test-first commit itself is authoritative evidence that the tests existed
before implementation.

A corrected patch is therefore archived as:

`G1-001C-preregistered-tests.patch.gz`

It is derived directly from:

`5e76581df0dc625f63a9a4f93631fcc7f63b4bda..a503c63991c7d06531ee5a68ce5c0d0f8e30120e`

The raw implementation patch contained whitespace-bearing unified-diff context
lines. It was not edited or normalized. Its exact bytes are archived as:

`G1-003-implementation.patch.gz`

Raw implementation patch SHA-256:

`a4f3ec0bc172aa9be625f31f95a57d9d9ef296d96d883db4d408485cc0a0d3a2`

No prior commit was amended, squashed, rebased, or rewritten.
