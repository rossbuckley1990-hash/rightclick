import Darwin
import Foundation

/// Captures authorized local bytes once and holds a private, read-only launch
/// incarnation for the full reflector/invocation lifetime. Provider-controlled
/// source path replacement cannot change the descriptor or bytes executed.
/// This is containment against mutable acquisition paths, not protection from
/// an already-compromised host owner or kernel.
final class CapabilityArtifactSnapshot {
    let source: URL
    let file: URL
    let sha256: String
    private let directory: URL
    private let maximum: Int
    private let protected: Bool

    init(source: URL, maximum: Int, executable: Bool = false, protected: Bool = false) throws {
        let bytes = try Self.read(source: source, maximum: maximum, protected: protected)
        self.source = source; self.maximum = maximum; self.protected = protected
        sha256 = CapabilityJSON.digest(bytes)
        var template = Array((FileManager.default.temporaryDirectory.path + "/rightclick-artifact.XXXXXXXX").utf8CString)
        let path: String? = template.withUnsafeMutableBufferPointer { buffer in
            guard let result = mkdtemp(buffer.baseAddress!) else { return nil }
            return String(cString: result)
        }
        guard let path else { throw RCIRError.unavailable }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        file = directory.appendingPathComponent(executable ? "executable" : "artifact")
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { try? FileManager.default.removeItem(at: directory); throw RCIRError.unavailable }
        do {
            try bytes.withUnsafeBytes { buffer in
                var count = 0
                while count < bytes.count {
                    let next = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: count), bytes.count - count)
                    guard next > 0 else { throw RCIRError.unavailable }; count += next
                }
            }
            guard fchmod(descriptor, executable ? 0o500 : 0o400) == 0 else { throw RCIRError.unavailable }
            close(descriptor)
        } catch {
            close(descriptor); try? FileManager.default.removeItem(at: directory); throw error
        }
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func sourceStillMatches() -> Bool {
        guard let bytes = try? Self.read(source: source, maximum: maximum, protected: protected) else { return false }
        return CapabilityJSON.digest(bytes) == sha256
    }
    static func read(source: URL, maximum: Int, protected: Bool = false) throws -> Data {
        guard source.isFileURL, source.path.hasPrefix("/"), (1...268_435_456).contains(maximum) else { throw RCIRError.invalidLimit }
        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw RCIRError.unavailable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximum else { throw RCIRError.invalidLimit }
        if protected {
            guard info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw RCIRError.authorityDenied }
        }
        var result = Data(); var chunk = [UInt8](repeating: 0, count: min(65_536, maximum + 1))
        while true {
            let limit = min(chunk.count, maximum + 1 - result.count)
            guard limit > 0 else { throw RCIRError.invalidLimit }
            let next = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, limit) }
            guard next >= 0 else { throw RCIRError.unavailable }
            if next == 0 { break }
            result.append(contentsOf: chunk.prefix(next))
            guard result.count <= maximum else { throw RCIRError.invalidLimit }
        }
        return result
    }
}
