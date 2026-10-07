import Foundation

/// Substrates normalize task snapshots here. The host owns state, deadlines,
/// authority revalidation, observation and receipts; callbacks never verify.
public struct RCIRDeferredLifecycle {
    public let initial: (ExecutionRecord) throws -> RCIRTaskEvent
    public let poll: () throws -> RCIRTaskEvent?
    public let timeoutMilliseconds: Int64
    public init(timeoutMilliseconds: Int64 = 30_000,
                initial: @escaping (ExecutionRecord) throws -> RCIRTaskEvent,
                poll: @escaping () throws -> RCIRTaskEvent?) {
        self.timeoutMilliseconds = timeoutMilliseconds; self.initial = initial; self.poll = poll
    }
}

/// All access to a retained task is serialized. Polls do not dispatch the original
/// mutation again, and duplicate state snapshots do not consume event budget.
final class RCIRDeferredSession {
    private let lock = NSLock()
    private var task: RCIRTask
    private var record: ExecutionRecord
    private let lifecycle: RCIRDeferredLifecycle?
    private let now: () -> Int64
    private let revalidate: () -> Bool
    private let authority: () -> Set<RCIRScope>
    private let signer: (any RCIRReceiptSigning)?
    private let boundary: String
    private let observe: (inout RCIRTask, inout ExecutionRecord) throws -> Void

    init(task: RCIRTask, record: ExecutionRecord, lifecycle: RCIRDeferredLifecycle?,
         now: @escaping () -> Int64, revalidate: @escaping () -> Bool,
         authority: @escaping () -> Set<RCIRScope>, signer: (any RCIRReceiptSigning)?, boundary: String,
         observe: @escaping (inout RCIRTask, inout ExecutionRecord) throws -> Void) throws {
        self.task = task; self.record = record; self.lifecycle = lifecycle
        self.now = now; self.revalidate = revalidate; self.authority = authority
        self.signer = signer; self.boundary = boundary; self.observe = observe
        try advance(lifecycle?.initial(record) ?? .accepted)
    }

    private var terminal: Bool { [.completed, .failed, .cancelled, .unknown].contains(task.phase) }

    private func advance(_ event: RCIRTaskEvent) throws {
        let duplicate: Bool
        switch event {
        case .accepted: duplicate = task.phase == .accepted
        case .working: duplicate = task.phase == .working
        case .inputRequired: duplicate = task.phase == .inputRequired
        default: duplicate = false
        }
        if !duplicate { try task.record(event, sequence: task.sequence + 1, now: now()) }
        if case let .completed(value) = event, case let .string(output) = value { record.output = output }
    }

    func status(refresh: Bool = true) -> ExecutionRecord {
        lock.lock(); defer { lock.unlock() }
        do {
            try task.checkDeadline(now: now())
            if refresh, !terminal {
                guard revalidate(), task.lease.scopes.isSubset(of: authority()) else {
                    try task.providerDisappeared(now: now())
                    return try snapshot()
                }
                if let update = try lifecycle?.poll() { try advance(update) }
            }
            if task.phase == .completed, task.outcome == .unverified, now() < task.deadline {
                // Missing observation is abstention, never an acknowledgement of
                // success. A later bounded status call may observe it independently.
                try? observe(&task, &record)
            }
            return try snapshot()
        } catch {
            if !terminal { try? task.providerDisappeared(now: now()) }
            record.message = "Remote task status is unknown; do not retry the original mutation blindly."
            return (try? snapshot()) ?? record
        }
    }

    private func snapshot() throws -> ExecutionRecord {
        switch task.phase {
        case .started, .accepted, .working, .cancelRequested:
            record.state = .started; record.message = "Admitted remote task is \(task.phase.rawValue); outcome remains unverified."
        case .inputRequired:
            record.state = .awaitingUser; record.message = "Remote task requires additional input."
        case .completed:
            record.state = task.outcome == .succeeded ? .succeeded : (task.outcome == .failed ? .failed : .accepted)
            record.message = task.outcome == .unverified ? "Remote task completed; independent outcome remains unverified." : "Independent observation determined the remote task outcome."
        case .failed: record.state = .failed; record.message = "Remote task reported failure; no semantic success is claimed."
        case .cancelled: record.state = .cancelled; record.message = "Remote task reported cancellation; prior external effects may remain."
        case .unknown: record.state = .unknown; record.message = "Remote task disappeared, exceeded its deadline or could not be observed; do not retry blindly."
        }
        record.evidence = OutcomeEvidence(type: "rcir_deferred_task", boundary: boundary,
                                         outcomeVerified: task.outcome == .succeeded)
        let payload = terminal ? try task.receiptData() : nil
        let signed = terminal ? try signer.map { try RCIRSignedReceipt.sign(task, using: $0) } : nil
        let envelope = try signed.map { try JSONDecoder().decode(RCIRReceiptEnvelope.self, from: $0.wireData()) }
        let page = try task.eventPage(limit: 256)
        record.rcir = RCIRExecutionEvidence(version: 1, taskID: task.id.uuidString,
            leaseID: task.lease.id.uuidString, generation: task.lease.binding.generation,
            leaseConsumed: true, phase: task.phase.rawValue, outcome: task.outcome.rawValue,
            receipt: payload?.base64EncodedString(), signedReceipt: envelope,
            observationBoundary: boundary, taskEvents: page.events.map { $0.base64EncodedString() })
        return record
    }
}
