import Foundation
import RightClickProtocol

extension RemoteExecutionSummary {
    /// Signatures authenticate the node's assertion. Consumers also require a
    /// coherent assertion before it can affect the local execution lifecycle.
    func validate() throws {
        guard completedAtMilliseconds > 0, (1...16).contains(lifecycle.count),
              Set(lifecycle).count == lifecycle.count, capabilities.count <= 128,
              Set(capabilities.map(\.id)).count == capabilities.count,
              evidenceExecutionID.map({ UUID(uuidString: $0)?.uuidString == $0 }) ?? true,
              capabilities.allSatisfy({ RemoteWire.isIdentifier($0.id) && RemoteWire.isDigest($0.contractDigest) &&
                  !$0.title.isEmpty && $0.title.utf8.count <= 512 && $0.title.rangeOfCharacter(from: .controlCharacters) == nil })
        else { throw RemoteLinkError.inconsistentResult }
        guard Array(lifecycle.prefix(3)) == [.requested, .authorized, .delivered] else { throw RemoteLinkError.inconsistentResult }
        let tail = Array(lifecycle.dropFirst(3))
        let coherentLifecycle: Bool
        switch state {
        case nil: coherentLifecycle = tail == [.discovered] || (error != nil && tail == [.unknown])
        case .succeeded: coherentLifecycle = tail == [.executing, .providerAccepted, .verified]
        case .accepted: coherentLifecycle = tail == [.executing, .providerAccepted, .unverified]
        case .awaitingUser: coherentLifecycle = tail == [.executing, .awaitingUser]
        case .unknown: coherentLifecycle = tail == [.unknown] || tail == [.executing, .unknown]
        case .unavailable, .unsupported, .rejected:
            coherentLifecycle = tail == [.executing, .providerRejected] || (error != nil && tail == [.unknown])
        case .failed:
            coherentLifecycle = providerAcceptance == .accepted ? tail == [.executing, .providerAccepted, .unverified] : tail == [.executing, .providerRejected]
        case .started, .cancelled: coherentLifecycle = false
        }
        guard coherentLifecycle else { throw RemoteLinkError.inconsistentResult }
        if let runtime {
            guard runtime.version == 1, RemoteWire.isIdentifier(runtime.runtimeID), RemoteWire.isIdentifier(runtime.deviceID),
                  runtime.architecture == "arm64" || runtime.architecture == "x86_64" || runtime.architecture == "other",
                  Set(runtime.operations).isSubset(of: [.runtime, .actions, .run]) else { throw RemoteLinkError.inconsistentResult }
        }
        if verification == .verifiedSuccess {
            guard state == .succeeded, providerAcceptance == .accepted, policy == .evaluated,
                  observationBoundary != .none, evidenceExecutionID != nil, error == nil,
                  lifecycle.last == .verified else { throw RemoteLinkError.inconsistentResult }
        } else if state == .succeeded { throw RemoteLinkError.inconsistentResult }
        if verification == .verifiedFailure {
            guard state == .failed, providerAcceptance == .accepted, policy == .evaluated,
                  observationBoundary != .none, evidenceExecutionID != nil else { throw RemoteLinkError.inconsistentResult }
        }
        if policy == .denied || policy == .confirmationRequired || policy == .notEvaluated {
            guard providerAcceptance == .notInvoked, verification == .unverified, observationBoundary == .none,
                  state != .succeeded && state != .accepted && state != .started else { throw RemoteLinkError.inconsistentResult }
        }
        if state == .awaitingUser {
            guard policy == .confirmationRequired, lifecycle.last == .awaitingUser else { throw RemoteLinkError.inconsistentResult }
        }
        if state == .accepted {
            guard providerAcceptance == .accepted, policy == .evaluated,
                  verification == .unverified || verification == .abstained else { throw RemoteLinkError.inconsistentResult }
        }
        if state == nil {
            guard lifecycle.last == .discovered || error != nil,
                  providerAcceptance == .notInvoked else { throw RemoteLinkError.inconsistentResult }
        } else {
            guard capabilities.isEmpty, runtime == nil else { throw RemoteLinkError.inconsistentResult }
        }
    }
}
