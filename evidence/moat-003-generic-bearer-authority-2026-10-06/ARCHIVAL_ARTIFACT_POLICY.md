# Archival artifact policy

Some frozen experiment artifacts in this evidence bundle contain trailing
whitespace inherited from the exact captured patch or terminal output.

Those bytes are intentionally preserved.

A generic `git diff --check` over the evidence bundle therefore reports
whitespace in archival `.patch` and `.log` files. This is not a production
source-code defect and the archival files must not be rewritten merely to
satisfy repository whitespace style checks.

The production commit was checked independently with `git show --check`.

The frozen preregistered-test patch and implementation patch retain their
original SHA-256 identities. Original private evidence hashes are also
preserved in the public evidence bundle.
