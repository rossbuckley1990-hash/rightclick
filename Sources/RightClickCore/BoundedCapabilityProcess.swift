#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Generic host-selected executable boundary. Arguments are passed directly,
/// never through a shell. Discovery data cannot select an executable or grant
/// inherited environment, filesystem or network access to a guest.
enum BoundedCapabilityProcess {
    final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private var exceeded = false
        func append(_ next: Data, maximum: Int) {
            lock.lock(); defer { lock.unlock() }
            if next.count > maximum - bytes.count { exceeded = true }
            else if !exceeded { bytes.append(next) }
        }
        func snapshot() -> (Data, Bool) { lock.lock(); defer { lock.unlock() }; return (bytes, exceeded) }
    }
    static func run(executable: URL, arguments: [String], timeout: TimeInterval = 5,
                    maximumBytes: Int = 1_048_576,
                    input: Data? = nil,
                    admitStart: ((_ start: () -> Void) throws -> Void)? = nil) throws -> Data {
        guard executable.isFileURL, RuntimePlatform.isAbsolutePath(executable.path),
              FileManager.default.isExecutableFile(atPath: executable.path),
              timeout.isFinite, timeout > 0, timeout <= 10,
              (1...1_048_576).contains(maximumBytes) else { throw RCIRError.invalidLimit }
        guard (input?.count ?? 0) <= 1_048_576 else { throw RCIRError.invalidLimit }
        let process = Process(); process.executableURL = executable; process.arguments = arguments
#if os(Windows)
        let environment = ProcessInfo.processInfo.environment
        process.environment = ["SystemRoot": environment["SystemRoot"] ?? "C:\\Windows",
            "TEMP": FileManager.default.temporaryDirectory.path, "TMP": FileManager.default.temporaryDirectory.path]
#else
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.temporaryDirectory.path]
#endif
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        let inputPipe = input.map { _ in Pipe() }
        if let inputPipe {
            process.standardInput = inputPipe
            // Suppress SIGPIPE on this descriptor without modifying process-
            // wide signal policy if a bounded child exits before reading stdin.
            #if canImport(Darwin)
            _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
#endif
        } else { process.standardInput = FileHandle.nullDevice }
        let buffer = Buffer(); let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { reader.leave() }
            while true {
                let chunk = pipe.fileHandleForReading.readData(ofLength: 4096)
                if chunk.isEmpty { break }
                buffer.append(chunk, maximum: maximumBytes)
            }
        }
        var startError: Error?
        let start = { do { try process.run() } catch { startError = error } }
        do {
            if let admitStart { try admitStart(start) } else { start() }
            if let startError { throw startError }
        } catch {
            try? pipe.fileHandleForWriting.close()
            try? inputPipe?.fileHandleForReading.close()
            try? inputPipe?.fileHandleForWriting.close()
            throw error
        }
        if let inputPipe, let input {
            try? inputPipe.fileHandleForReading.close()
            // Write only after the admitted child starts. A reader that never
            // consumes stdin cannot block the caller's monotonic timeout loop.
            DispatchQueue.global(qos: .utility).async {
                defer { try? inputPipe.fileHandleForWriting.close() }
                try? inputPipe.fileHandleForWriting.write(contentsOf: input)
            }
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        while process.isRunning {
            if DispatchTime.now().uptimeNanoseconds >= deadline || buffer.snapshot().1 {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.020)
#if os(Windows)
                if process.isRunning { process.terminate() }
#else
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
#endif
                process.waitUntilExit(); try? pipe.fileHandleForWriting.close()
                throw RCIRError.invalidLimit
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        process.waitUntilExit(); try? pipe.fileHandleForWriting.close()
        guard reader.wait(timeout: .now() + 1) == .success else { throw RCIRError.unavailable }
        let (bytes, exceeded) = buffer.snapshot()
        guard !exceeded, process.terminationStatus == 0 else { throw RCIRError.unavailable }
        return bytes
    }
}
