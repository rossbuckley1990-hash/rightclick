import Foundation
import RightClickProtocol

/// Narrow host-adapter seam over the existing immutable snapshot and bounded
/// process executor. No shell, authority source, or snapshot path is exported.
public final class CapabilityExecutableProcess {
    private let snapshot: CapabilityArtifactSnapshot
    public init(executable: URL, maximumExecutableBytes: Int) throws {
        snapshot = try CapabilityArtifactSnapshot(source: executable,
            maximum: maximumExecutableBytes, executable: true)
    }
    public var sourceSHA256: String { snapshot.sha256 }
    public var isCurrent: Bool { snapshot.sourceStillMatches() }
    public func run(arguments: [String], timeout: TimeInterval,
                    maximumOutputBytes: Int, input: Data? = nil,
                    admitStart: ((_ start: () -> Void) throws -> Void)? = nil) throws -> Data {
        guard isCurrent else { throw RCIRError.staleBinding }
        let result = try BoundedCapabilityProcess.run(executable: snapshot.file,
            arguments: arguments, timeout: timeout, maximumBytes: maximumOutputBytes,
            input: input, admitStart: admitStart)
        guard isCurrent else { throw RCIRError.staleBinding }
        return result
    }
}
