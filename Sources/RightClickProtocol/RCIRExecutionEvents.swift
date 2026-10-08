import Foundation

public struct RCIRExecutionEvent: Codable, Sendable {
    public let sequence: Int64
    public let time: Int64
    public let kind: String
    public let value: CapabilityValue
    public init(sequence: Int64, time: Int64, kind: String, value: CapabilityValue) {
        self.sequence = sequence; self.time = time; self.kind = kind; self.value = value
    }
    public func canonicalData() throws -> Data {
        try CapabilityValue.object(["sequence": .integer(sequence), "time": .integer(time),
                                    "kind": .string(kind), "value": value]).canonicalData()
    }
}

public struct RCIRExecutionEventPage: Codable, Sendable {
    public let events: [RCIRExecutionEvent]
    public let nextCursor: Int64
    public let hasMore: Bool
    public let terminal: Bool
    public init(events: [RCIRExecutionEvent], nextCursor: Int64, hasMore: Bool, terminal: Bool) {
        self.events = events; self.nextCursor = nextCursor; self.hasMore = hasMore; self.terminal = terminal
    }
}

/// A shared, bounded cursor implementation. Retained histories never discard or
/// renumber events; an old cursor may intentionally reread the same history.
public func rcirExecutionEventPage(_ events: [RCIRExecutionEvent], after cursor: Int64,
                                   limit: Int, maximumBytes: Int, terminal: Bool) throws -> RCIRExecutionEventPage {
    guard cursor >= 0, cursor <= Int64(events.count) else { throw RCIRError.invalidSequence }
    guard (1...256).contains(limit), (1...262_144).contains(maximumBytes) else { throw RCIRError.invalidLimit }
    var result: [RCIRExecutionEvent] = []
    var bytes = 0
    var end = Int(cursor)
    while end < events.count, result.count < limit {
        let count = try events[end].canonicalData().count
        guard count <= maximumBytes else { throw RCIRError.invalidLimit }
        if count > maximumBytes - bytes { break }
        result.append(events[end]); bytes += count; end += 1
    }
    return .init(events: result, nextCursor: Int64(end), hasMore: end < events.count, terminal: terminal)
}
