# Portable bilateral contract — frozen v1

Base: PR #99 `6a18aaae3ae3a15b9f6c78f189adc695ae11585a`.
Semantic reference: local bilateral checkpoint `738905589b2bfa2b3e92dbfc43ad88a597e1aec9`.
Root owns interface changes and integration; specialists must stop and report
if this contract needs revision. No additional model-facing operation.

## Shared Protocol representation

`ExecutionRecord` and `RunResult` retain their compatible fields and add optional
`result: CapabilityValue`, `rcirEvents: [RCIRExecutionEvent]?`,
`rcirEventPage: RCIRExecutionEventPage?`, and `lifecycle: ExecutionLifecycle?`.
The old canonical RCIR event bytes remain the receipt source. Typed events have
`sequence: Int64`, `time: Int64`, `kind: String`, `value: CapabilityValue`.
Pages have events, nextCursor, hasMore, terminal. Values use existing ABI types.

`ExecutionLifecycle` is Codable/Sendable with public initializer and fields:

- version: Int (1)
- executionID: String (owning execution identity; caller's record can have a local alias)
- originatingRequestID: String (local execution ID or original signed Link run request UUID)
- runtimeID: String (host-owned opaque ownership, `local` for unnetworked host)
- taskID: String (RCIR task UUID)
- generation: Int64 (admitted contract generation)
- taskShape: RCIRTaskShape
- phase: RCIRTaskPhase
- semanticOutcome: RCIRSemanticOutcome
- sequence: Int64 (highest accepted event sequence)
- terminal: Bool
- providerAcceptance: ExecutionProviderAcceptance (`notInvoked`, `accepted`, `rejected`, `unknown`)
- verification: OutcomeVerificationStatus
- observationBoundary: OutcomeObservationBoundary
- evidenceID: String? (terminal task/evidence identity)
- receiptAvailable: Bool
- signedReceiptAvailable: Bool

RCIRTaskShape, RCIRTaskPhase, RCIRSemanticOutcome gain Codable. Their existing
cases remain, including deferred, inputRequired, cancelRequested and unknown.
Provider acceptance, lifecycle completion and semantic success remain separate.
Only an admission-bound host observer/postcondition can adjudicate verification.

Cursor means the last consumed sequence in this execution. Zero starts history;
pages contain contiguous sequences strictly after it. Negative/ahead cursor,
invalid count or byte budget fail closed. Accepted old cursors may reread retained
history. No dropping events/renumbering to hide overflow. Count <=256 per page;
page byte budget <=262144 locally and <=16384 on Link. Task limits <=1024 events
and <=262144 canonical event bytes. Overflow or lost provider after dispatch
terminalizes UNKNOWN, preserving retained events and evidence. Terminal flag is
snapshot terminality independent of hasMore; terminal history remains pageable.

## Host and Core ownership

Providers owns admission and active task serialization. Register AFTER successful
consume/admission and BEFORE provider start/callback. One terminal publication
path atomically retains terminal record, typed result/events, lifecycle and receipt
even before any initial ExecutionRecord exists. Later put merges that retained
terminal snapshot and cannot reopen it. No gap: retain before removing active.
Capture signer and host observation policy at admission. Never sign live receipts.
If completion needs host verification, retain it as a pending copy and keep the
prior live snapshot visible until bounded adjudication publishes terminal state.
Observer I/O runs outside admission/registry locks. Detected disappearance or
deadline wins UNKNOWN; a late successful observer cannot reopen that publication.
Local loss detection occurs on owner withdrawal/catalog refresh or task deadline;
catalog TTL expiry alone never invalidates a captured remote execution owner.
Post-dispatch uncertainty never authorizes retry. Deadline/disappearance/budget
failure cannot leave an orphaned active entry. Cancellation is host controlled.

The host reserves at most 1,024 execution identities per process, across unary and
deferred shapes, without evicting dispatched identities. A pre-effect admission
failure may release its reservation. Cross-restart consequential idempotency is
the durable Link ledger's responsibility, not an in-memory local UUID cache.
ExecutionStore.putTerminal retains full local event history atomically;
putTerminalSnapshot retains authenticated remote terminal metadata without
pretending a bounded remote page contains the complete history. Both defeat late
initial-record overwrite. Fresh pages cannot alter terminal evidence or result.

Protocol owns the portable ExecutionStore (existing placement), typed models,
and `CapabilityExecutionStatusReflector: CapabilityReflector`:

```
func executionStatus(executionID: String, cursor: Int64, limit: Int,
                     maximumBytes: Int) async throws -> ExecutionRecord?
```

Core retains the status reflector before begin and offers local synchronous page
status plus asynchronous status refresh through that interface. It awaits network
outside its engine lock; route stays bound to the original reflector/runtime.
MCP context_run_status accepts optional cursor, limit, maximumBytes and calls this
generic refresh. No transport terminology or new operations enters MCP.

## Link binding and privacy

Link uses the existing signed envelope and `.status` operation. Status request
must bind original caller, run request UUID, run idempotency UUID, target runtime
and device, capability ID/digest, execution ID, cursor/count/byte budget. Fresh
poll envelope has its own request UUID, nonce and expiry. Signed response binds
the poll plus original run identity and lifecycle snapshot. Validate identity,
generation, contiguous sequence, cursor bounds, terminal immutability and coherent
acceptance/verification before updating caller status. Relay metadata is untrusted.

Consequential ledger retains original binding and initial live snapshot durably;
fresh same-intent retries reuse its execution. Restart with unresolved/live
reservation becomes UNKNOWN, never dispatches. Terminal update is monotonic and
immutable. Runtime, actions and status use a separate durable, bounded window of
observation envelope identities. Its 2,048 request/nonce digests may expire only
after their original signed envelopes cannot validate. Runs and retries check
both that window and permanent consequential identities before admission. The
observation window never evicts or resets consequential history or grants run
authority; harmless discovery cannot exhaust permanent execution reservations.
Ledger format v2 preserves all validated v1 history on upgrade, including old
observations previously recorded as permanent. Downgrades do not reset a ledger.

Lifecycle metadata and its requested page are captured from the same immutable
host/store snapshot. A callback cannot mix a newer sequence or terminal page
with an older lifecycle/result. Captured execution owners survive authenticated
same-client re-enrollment after temporary disconnection. Explicit removal still
invalidates the enrollment generation and cannot revive those owners.

Default remote projection redacts event values, raw results, receipts, diagnostics
and private observations. Explicit host-owned capability export policy may permit
typed public result/event values for the portable proof provider. That policy is
never supplied by a remote caller. Safe signed evidence identity/availability and
semantic summary are visible; full canonical receipt stays on execution node.
Credentials, consent and observations always remain there.
Exported values must fit both canonical and JSON encoding budgets of 8 KiB;
otherwise that value is redacted without altering target history. Initial remote
pages obey the same 16 KiB ceiling as polls.

## Specialist scopes

A: Protocol/Providers and ported RCIRDeferredExecutionTests.swift; shared models
exactly above, host races, signer preservation, bounded retention and observers.
B: Link and new RemoteLifecycleTests.swift; status authentication/ledger/routing,
then optional small encrypted outbound transport. Root owns Package/CLI changes.
C: separate adversarial tests and acceptance scripts, no production edits without
delegation; continuous security review. Root: Core/MCP, integration, commits,
matrix and real process composition. No overlapping edits or specialist commits.
