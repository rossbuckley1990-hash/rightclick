import Darwin
import Foundation

/// Operator-owned credential/configuration reference. Reads are bounded and
/// refuse symlinks, other owners and group/world-readable files. The bytes must
/// never enter capability metadata, logs, receipts or agent-visible arguments.
enum CapabilityProtectedReference {
    static func read(_ path: String, maximum: Int = 65_536) throws -> Data {
        guard path.hasPrefix("/"), (1...1_048_576).contains(maximum) else { throw RCIRError.authorityDenied }
        return try CapabilityArtifactSnapshot.read(source: URL(fileURLWithPath: path), maximum: maximum, protected: true)
    }
}
