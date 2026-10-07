# Native D-Bus observer journal preservation

This evidence-only collector repair is based on frozen PR49 head `39b37afbcc288eb07c5fe341b506f35ebb77e361`. Product Sources remains `c7414e1dc9cf28c98262aa933e40166113f66ba8`.

The old observer journal overwrites the independently observed stored invocation with the current HTTP request marker. The actual native replay therefore has a new marker in its journal but an old marker in the signed observation; the runtime correctly reports failure. This is an existing collector defect, not an attributed runtime regression. The preserved RED includes exact owned rows, an unchanged complete signed envelope, and its separate public key pin. Raw originals stay private and unchanged.

The fixture now preserves `invocation` and records `requestInvocation` separately in the journal. The HTTP response and runtime verifier schema remain unchanged. Actual acceptance asserts current markers for both positive runs and the prior stored marker for replay. The isolated diagnostic workflow uses the existing Swift6.2 native Linux acceptance and separate concurrency.

Syntax and whitespace checks pass. Native RED-to-GREEN remains **PENDING** until actual CI acceptance produces exact source/binary hashes, all 13 tests without skips, and the seven-operation live proof. No runtime fix, source repackage, release, or publication is implied by this local preparation.

The six-field ledger preserves the current frozen-head portability and distribution evidence with explicit limits. A receipt signature authenticates runtime assertions; separate native observation is still required for external truth.
