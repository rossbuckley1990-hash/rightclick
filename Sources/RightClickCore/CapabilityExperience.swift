import RightClickProviders
import RightClickProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Learns observations about freshly discovered contracts, never permissions.
/// History is advisory and cannot add capabilities, change routing or skip gates.
public final class CapabilityExperience: @unchecked Sendable {
    private let ledger: CapabilityExperienceLedger
    private let namespace: String

    public init(ledger: CapabilityExperienceLedger, namespace: String) {
        self.ledger = ledger
        self.namespace = namespace
    }

    /// Explicit opt-in. No disk access or user-profile edits by default. Multi-user
    /// hosts must provide separate directories/namespaces at their trusted boundary.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> CapabilityExperience? {
        guard let path = environment["RIGHTCLICK_EXPERIENCE_DIRECTORY"], path.hasPrefix("/"),
              path.utf8.count <= 4096,
              let namespace = environment["RIGHTCLICK_EXPERIENCE_NAMESPACE"],
              !namespace.isEmpty, namespace.utf8.count <= 256,
              let ledger = try? CapabilityExperienceLedger(directory: URL(fileURLWithPath: path)) else { return nil }
        return CapabilityExperience(ledger: ledger, namespace: namespace)
    }

    /// The fresh contract is authoritative. Raw payloads and credentials never
    /// enter this key. A fingerprint is not proof of unchanged provider code.
    public func contractKey(for capability: Capability) -> String? {
        let clean = Self.withoutExperience(capability)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(clean), data.count <= 262_144 else { return nil }
        let material = Data("RIGHTCLICK-EXPERIENCE-v1\n".utf8)
            + Data(namespace.utf8) + Data([0]) + data
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    /// A single bounded ledger read for the entire live graph. No retrieval can
    /// resurrect a capability that is absent from this fresh discovery result.
    public func annotate(_ capabilities: [Capability], now: Date = Date()) -> [Capability] {
        let entries = try? ledger.entries(now: now)
        let grouped = Dictionary(grouping: entries ?? [], by: \.contractKey)
        return capabilities.map { capability in
            var result = Self.withoutExperience(capability)
            guard entries != nil else {
                result.metadata["experience.status"] = "unavailable"
                return result
            }
            guard let key = contractKey(for: result), let observations = grouped[key], !observations.isEmpty else { return result }
            result.metadata["experience.status"] = "advisory_only"
            result.metadata["experience.observations"] = String(observations.count)
            result.metadata["experience.acceptedUnverified"] = String(observations.filter { $0.outcome == .acceptedUnverified }.count)
            result.metadata["experience.predicatesVerified"] = String(observations.filter { $0.outcome == .predicatesVerified }.count)
            result.metadata["experience.failed"] = String(observations.filter { $0.outcome == .failed }.count)
            result.metadata["experience.unknown"] = String(observations.filter { $0.outcome == .unknown }.count)
            result.metadata["experience.freshAuthorityRequired"] = "true"
            result.metadata["experience.freshVerificationRequired"] = "true"
            return result
        }
    }

    /// Call only with the engine-selected fresh capability and engine-final result.
    /// The API intentionally has no input/output text, arguments or approval flag.
    public func observe(capability: Capability, executionID: String, result: RunResult,
                        now: Date = Date()) {
        guard result.actionID == capability.id, let id = UUID(uuidString: executionID),
              let key = contractKey(for: capability) else { return }
        let outcome: CapabilityExperienceOutcome
        switch result.status {
        case .accepted: outcome = .acceptedUnverified
        case .verified:
            // A Boolean or an empty verification claim cannot teach success.
            guard result.evidence.outcomeVerified,
                  let verification = result.verification,
                  verification.status == .verifiedSuccess,
                  !verification.predicates.isEmpty,
                  verification.predicates.allSatisfy({ $0.evaluated && $0.passed }) else {
                try? ledger.record(executionID: id, contractKey: key, outcome: .acceptedUnverified, now: now)
                return
            }
            outcome = .predicatesVerified
        case .failed: outcome = .failed
        case .unknown: outcome = .unknown
        case .confirmationRequired, .unsupported, .unavailable, .rejected: return
        }
        // Storage problems remove advice, not safety checks or the underlying result.
        try? ledger.record(executionID: id, contractKey: key, outcome: outcome, now: now)
    }

    public static func withoutExperience(_ capability: Capability) -> Capability {
        CapabilityDispatchContract.withoutExperience(capability)
    }
}
