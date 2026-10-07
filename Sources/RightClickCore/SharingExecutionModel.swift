import Foundation

/// Terminal rules for an asynchronous NSSharingService execution.
/// Returning from perform(withItems:) is not a result.
public struct SharingExecutionModel: Equatable, Sendable {
    public var state: ExecutionState
    public var events: [String]
    public static let deadline: TimeInterval = 30

    public init() {
        state = .started
        events = ["execution created"]
    }

    public var isTerminal: Bool {
        switch state {
        case .accepted, .unsupported, .unavailable, .rejected, .succeeded, .failed, .cancelled, .unknown:
            return true
        case .started, .awaitingUser:
            return false
        }
    }

    public var message: String {
        switch state {
        case .started:
            return "Sharing is in progress."
        case .awaitingUser:
            return "Sharing is waiting for the user."
        case .accepted:
            return "Provider reported sharing completion; external outcome is unverified."
        case .succeeded:
            return "An independent outcome postcondition was verified."
        case .unsupported: return "Unsupported invocation."
        case .unavailable: return "Provider unavailable."
        case .rejected: return "Provider rejected the request."
        case .failed:
            return "didFailToShareItems"
        case .cancelled:
            return "cancelled"
        case .unknown:
            return "No terminal sharing callback before the deadline."
        }
    }

    public mutating func serviceRetained() {
        events.append("service retained")
    }

    public mutating func delegateRetained() {
        events.append("delegate retained")
    }

    public mutating func performEntered() {
        guard !isTerminal else { return }
        events.append("perform called")
    }

    public mutating func willShareItems(count: Int, main: Bool) {
        guard !isTerminal else { return }
        events.append("willShareItems count=\(count) main=\(main)")
    }

    public mutating func performReturned() {
        guard !isTerminal else { return }
        events.append("perform returned")
        events.append("execution still pending")
    }

    public mutating func noteAwaitingUser() {
        guard state == .started else { return }
        state = .awaitingUser
    }

    public mutating func didShareItems(count: Int, main: Bool) {
        guard !isTerminal else { return }
        events.append("didShareItems count=\(count) main=\(main)")
        state = .accepted
        events.append("session released")
    }

    public mutating func didFailToShareItems(_ error: String, main: Bool) {
        guard !isTerminal else { return }
        events.append("didFailToShareItems \(error) main=\(main)")
        state = .failed
        events.append("session released")
    }

    public mutating func cancel() {
        guard !isTerminal else { return }
        events.append("explicit cancellation")
        state = .cancelled
        events.append("session released")
    }

    public mutating func deadlineExpired() {
        guard state == .started || state == .awaitingUser else { return }
        events.append("deadline expired")
        state = .unknown
        events.append("session released")
    }
}
