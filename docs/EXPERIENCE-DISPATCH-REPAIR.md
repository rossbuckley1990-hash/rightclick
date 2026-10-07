# Experience / dispatch integration repair

## Reproduced upstream RED

At main `05ace2fec149c62c7cfb24f41fafde863b377ff5`, macOS CI run 37594306485 executed 485 tests, skipped 26, and failed two existing CapabilityExperienceTests. A repeated invocation returned unavailable before reaching the expected acceptance or authority-rejection boundary.

## Cause and smallest repair

Discovery strips provider-supplied experience.* keys, then optionally attaches engine-owned advice from the local ledger. The independently reacquired provider contract does not include that advice. Comparing the decorated discovery object with the raw provider declaration therefore mistakes remembered observations for execution-contract drift.

Normalize only the already-reserved experience.* namespace on both contract snapshots before their sorted-JSON byte comparison. All other fields remain bound, including schema, endpoint, authority origin/scheme, safety, invocation and engine-assigned ownership. Do not remove the revalidation step or relax confirmation.

## Validation boundary

Retain every existing test and assertion. Add repeated run/begin controls and a provider-forged-advice control. Existing dispatch-contract drift, removal, revoked-authority, confirmation and fresh-verification tests remain required. Full native CI and acceptance must pass at the exact repair head before merge. This file records the repair design, not an unexecuted claim of green. No released tag or installed runtime is changed by this PR.
