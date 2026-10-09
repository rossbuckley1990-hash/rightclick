import RightClickProtocol
import Foundation

/// A discovery snapshot is evidence from one bounded acquisition window,
/// rather than a permanent claim that its providers remain available.
/// Callers hold their source's reload lock while accessing this value.
struct CapabilitySnapshotFreshness {
    private let lifetime: TimeInterval
    private var acquiredAt: TimeInterval?

    init(lifetime: TimeInterval = 5) {
        // Invalid host configuration must not create an immortal snapshot.
        self.lifetime = lifetime.isFinite ? max(0, min(lifetime, 300)) : 0
    }

    func isFresh(at now: TimeInterval) -> Bool {
        guard now.isFinite, let acquiredAt, acquiredAt.isFinite else { return false }
        let age = now - acquiredAt
        return age >= 0 && age < lifetime
    }

    mutating func recordAcquisition(at now: TimeInterval) {
        acquiredAt = now.isFinite ? now : nil
    }

    mutating func invalidate() {
        acquiredAt = nil
    }
}
