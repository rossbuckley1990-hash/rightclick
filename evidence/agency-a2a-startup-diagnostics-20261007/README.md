# A2A child-startup diagnosis

Original published source: `e09f0179f738189fb30b87c652a5433fba648054`.
Both original Mac CI runs timed out waiting for the first agent port after ten
seconds, and runner cleanup found both Python children still alive. Child stderr
was discarded; the cleanup block started after startup. The original CI cause
is **UNPROVEN**, and its acceptance remains RED pending an actual CI rerun.

Original logs are retained losslessly for runs
[37666853033](https://github.com/rossbuckley1990-hash/rightclick/actions/runs/37666853033)
and [37666846914](https://github.com/rossbuckley1990-hash/rightclick/actions/runs/37666846914).
Exact e09 fixture launch succeeds locally in 95–207 ms under three available
interpreters when loopback access is available. The initial local sandbox
denied socket binding; that local constraint is not attributed to CI.

| RED | Substrate exposing it | Generic deficiency established | Reusable primitive | Thin provider layer | Evidence | Reuse |
| --- | --- | --- | --- | --- | --- | --- |
| Actual CI first-port timeout | A2A proof bootstrap on Mac CI | Runtime deficiency not established; failure precedes runtime launch, and the harness loses child diagnostics | Bounded child/readiness diagnostics, private stderr and one private slow-start stack | Existing fixture arguments and port-marker names | Original CI logs; cause remains unproven pending rerun | Other disposable fixture startup gates |
| Actual early exit ignored, sibling orphaned | A2A acceptance entry point with disposable fault child | Harness waits ten seconds after exit 7; cleanup misses failures before the old try block | Same bounded process group checks child exit and cleans every registered child on context exit | None beyond fixture label and marker | Frozen old harness: 10019 ms timeout, exit 7, live sibling. Fixed entry point: child_exited/7 in 162 ms, both reaped | REST/gRPC/MCP and other fixture processes can reuse the helper |

`scripts/fixture_startup.py` preserves the ten-second startup maximum. It uses
the parent interpreter, checks child exit, reads a bounded regular port marker,
drains stderr to avoid pipe deadlock and retains at most 65536 raw stderr bytes.
It privately captures one stack after five seconds if startup is still blocked.
Public JSON contains labels, readiness/exit/cleanup facts, distinct startup and
lifetime measurements, byte counts, hashes and truncation facts; no child
arguments, stderr body or stack. Raw bytes stay in a separate temporary directory
with POSIX owner-only modes, outside uploaded/model evidence. Windows retains
bounded memory without claiming private-file ACL proof. Descendant/process-tree
lifecycle and hostile same-owner tampering are not demonstrated here.

Eight real subprocess controls pass: early exit plus sibling cleanup, private
error retention, alive timeout, marker readiness, invalid/symlink marker denial,
stderr flood, maximum timeout/exited marker denial, and actual delayed private
stack. The entry-point RED→GREEN control also passes through the actual
acceptance script. No semantic acceptance assertion or timeout was weakened.

The full unchanged A2A semantic acceptance passes locally using exact e09
fixture bytes, this helper patch, and the **disclosed unpublished b632 receipt
candidate**, SHA256
`eab48f21d55108123c5911cfb0cacf4bab6b963973052eef616dcf920f5bacca`.
That binary is not published e09. Seven operations remain seven, no
provider-specific tools are added, confirmation/policy deny before mutation,
accepted remains pending, status does not replay, independent observation
matches actual effects, and live agent removal changes the capability graph.
An independent decoder/Ed25519 verifier matches all three signed outcomes
(succeeded, failed, unverified), their bound messages, task IDs and separate
effect/readback journals.

Candidate evidence is minimized: unrelated provider graph and raw transcript
remain private; original byte hashes are recorded. Public receipts, own journals,
tool surface and startup metadata are retained. Limited private-PEM/obvious-bearer/
common-GitHub-token pattern review found no matches in selected artifacts/logs
or decoded receipts. This is not a comprehensive privacy proof. No raw child
stderr, private stack or signing key is archived.

This is engineering acceptance, not the fresh restricted AI eleven-substrate
proof. Installed RIGHTCLICK Stable runtime discovery was used separately;
procedural-memory retrieval remains not demonstrated. Original CI root cause,
authenticated issuer delegation, final cross-platform/profile proof and the
overall programme remain RED. The PR agent is the sole publisher.
