# Real elapsed time across protected signer validation

The frozen native control waited through the actual thirty-second lease expiry
inside a final host configuration callback, retaining the same unrevoked signer
and issuer policy. It returned UNKNOWN instead of rejecting expired admission:
one test, one expected assertion failure, zero unexpected failures, 30.682 s.

| Substrate | Generic deficiency measured | Shared repair | Provider layer | GREEN evidence | Reuse |
| --- | --- | --- | --- | --- | --- |
| A2A held task | Consumption used an earlier time after protected validation outlasted the lease; runtime claimed consumption and post-admission uncertainty | Sample the trusted non-mutating host clock after protected/configuration callbacks, immediately before existing lease consumption | None; existing transport and fixture | Same actual elapsed-time control must reject before admission, with zero provider journals | Every reflector using the common host/lease boundary |

The frozen fixture recorded **zero requests, effects, observations and polls**.
The independent decoder matches the canonical task, lease and expiry to the
captured lease. The actual signature verifies against the separate public pin;
its signed claim is UNKNOWN, without outcome observation or verification.
The key policy remains active at that receipt's replay observation time. The
fixture wait summary and public policy write history are unsigned test evidence.

This does not prove an expired external write. Why the transport failed before
the fixture received a request is unproven. UNKNOWN is honest after a possible
dispatch; the intended repair rejects the expired lease before consuming or
calling the transport start gate. Signed UNKNOWN is not signed success.

`clock-red/` preserves the raw synthetic artifacts once; the native log is
losslessly compressed. The manifest records frozen root source, source/artifact
hashes and limited private-PEM/obvious-bearer/common-GitHub-token pattern review
over the raw and decoded public evidence. No pattern matched; this is not a
comprehensive secrecy proof. No private signing-key bytes are archived.

The prior eleven-case proof is intermediate for this time placement invariant.
Final twelve-case acceptance requires a fresh native run and independent audit.
Full platform/profile/issuer-broker proof, restart/distributed trust persistence,
trusted timestamp attestation and the overall goal remain RED.

The fresh repaired root source `b63256f2` passes 109 targeted native tests, zero
failures and zero skips, including all twelve production controls and three
closed-config controls. This directory retains the exact twelve-case raw
fixture once (`final12-green/`) and the lossless 109-test log; the manifest
matches the repaired source bytes to that root commit. A later root evidence
import adds no runtime byte changes. Complete Mac testing after this clock
placement repair was still running when archived.

Independent twelve-case audit PASS: seven provider effects with separate
readbacks, seven denied executions without corresponding provider requests,
three actual signatures verified against separate pins, and four structurally
valid unsigned runtime assertions with authenticity not established. The actual
elapsed-time control now returns rejection with no request, effect, observation
or receipt. The callback really waits to expiry while its key remains active;
the result does not rely on a revoked or expired signing key.

Eight altered-artifact controls are rejected, including a false elapsed-wait
marker. This exercises the auditor's rejection behavior without authenticating
unsigned fixture logs. The original frozen clock failure remains preserved and
the possible expired external write remains **NOT DEMONSTRATED**.
