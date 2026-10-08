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

