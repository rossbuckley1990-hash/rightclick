import Darwin
import Foundation

/// Operator-owned credential/configuration reference. Reads are bounded and
/// refuse symlinks, other owners and group/world-readable files. The bytes must
/// never enter capability metadata, logs, receipts or agent-visible arguments.
enum CapabilityProtectedReference {
    static func read(_ path: String, maximum: Int = 65_536) throws -> Data {
        guard path.hasPrefix("/"), (1...1_048_576).contains(maximum) else { throw RCIRError.authorityDenied }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw RCIRError.authorityDenied }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_size >= 0, info.st_size <= maximum else { throw RCIRError.authorityDenied }
        var bytes = [UInt8](repeating: 0, count: maximum + 1); var count = 0
        while count < bytes.count {
            let remaining = bytes.count - count
            let next = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: count), remaining) }
            guard next >= 0 else { throw RCIRError.authorityDenied }
            if next == 0 { break }; count += next
        }
        guard count <= maximum else { throw RCIRError.invalidLimit }
        return Data(bytes.prefix(count))
    }
}
