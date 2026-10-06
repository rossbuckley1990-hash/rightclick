# MOAT-004 archival artifact policy

Two raw test logs generated during the frozen RED contained trailing whitespace
from compiler output.

They were not edited or normalized.

To allow Git's repository whitespace hygiene gate to remain enabled, the exact
raw log bytes are stored in deterministic gzip containers:

- `BASELINE_OPENAPI_TESTS.log.gz`
- `MOAT004_RED_TESTS.log.gz`

Decompressing those archives reproduces the exact original evidence bytes.

Original SHA-256 values:

- `BASELINE_OPENAPI_TESTS.log`:
  `e0664b432fba5da6c3ae358052443c5e396168191bf837b9085746bd243309f8`

- `MOAT004_RED_TESTS.log`:
  `00d84437230e87fa81d5daa249abfa75f32e5a0cf5313e1a808cdee31acbb1c8`

The original experiment manifest is preserved verbatim as:

`ORIGINAL_PRIVATE_MANIFEST.txt`

Its SHA-256 is:

`d84f925ce854f8bae1dffb6c48ebd071b43a0696c91bf1df60ccb6267cf209c1`

Compression is archival representation only. No experimental output was
corrected, sanitized, rewritten, or semantically changed.
