import Foundation
import RightClickHostFiles
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Native clients are trusted host programs, never an arbitrary code sandbox.
/// POSIX children start in a private process group before exec. Ordinary
/// descendants in that group are disposed before the retained PID is reaped.
final class RightClickClientChildProcess {
    let identifier: Int32
    let input: FileHandle?
    let output: FileHandle
    private var disposed = false
    private(set) var status: Int32 = 0
#if os(Windows)
    private let process: Process
#endif

    init(executable: String, arguments: [String], environment: [String: String]? = nil,
         inputPipe: Bool = false, mergeError: Bool = true) throws {
#if os(Windows)
        process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let outputPipe = Pipe(), stdinPipe = inputPipe ? Pipe() : nil
        output = outputPipe.fileHandleForReading
        input = stdinPipe?.fileHandleForWriting
        process.standardInput = stdinPipe.map { $0 as Any } ?? FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = mergeError ? outputPipe as Any : FileHandle.nullDevice as Any
        do { try process.run() } catch { throw RightClickOnboardingError("Could not launch the native client command.") }
        identifier = process.processIdentifier
        try? outputPipe.fileHandleForWriting.close()
        try? stdinPipe?.fileHandleForReading.close()
#else
        let argvStrings = [executable] + arguments
        guard argvStrings.count <= 1024,
              argvStrings.allSatisfy({ !$0.utf8.contains(0) && $0.utf8.count <= 65_536 }),
              environment?.allSatisfy({ !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }) != false else {
            throw RightClickOnboardingError("Native client arguments or environment are invalid.")
        }
        let ownedArguments = argvStrings.map { strdup($0) }
        let ownedEnvironment = environment?.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) }
        defer {
            ownedArguments.forEach { free($0) }
            ownedEnvironment?.forEach { free($0) }
        }
        guard ownedArguments.allSatisfy({ $0 != nil }), ownedEnvironment?.allSatisfy({ $0 != nil }) != false else {
            throw RightClickOnboardingError("Could not allocate bounded native client arguments.")
        }
        let argv = ownedArguments.map { $0.map { UnsafePointer<CChar>($0) } } + [nil]
        let envp = ownedEnvironment.map { $0.map { $0.map { UnsafePointer<CChar>($0) } } + [nil] }
        var child: Int32 = -1, inputFD: Int32 = -1, outputFD: Int32 = -1
        let result = executable.withCString { path in
            argv.withUnsafeBufferPointer { arguments in
                if envp != nil {
                    return envp!.withUnsafeBufferPointer { environment in
                        rc_host_spawn_client(path, arguments.baseAddress, environment.baseAddress,
                            inputPipe ? 1 : 0, mergeError ? 1 : 0, &child, &inputFD, &outputFD)
                    }
                }
                return rc_host_spawn_client(path, arguments.baseAddress, nil,
                    inputPipe ? 1 : 0, mergeError ? 1 : 0, &child, &inputFD, &outputFD)
            }
        }
        guard result == 0, child > 0, outputFD >= 0 else {
            throw RightClickOnboardingError("Could not launch the native client command.")
        }
        identifier = child
        input = inputFD >= 0 ? FileHandle(fileDescriptor: inputFD, closeOnDealloc: true) : nil
        output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
#if canImport(Darwin)
        if let input { _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) }
#endif
#endif
    }

    var isRunning: Bool {
        guard !disposed else { return false }
#if os(Windows)
        if process.isRunning { return true }
        status = process.terminationStatus
        return false
#else
        let result = rc_host_poll_client(identifier, &status)
        return result == 0
#endif
    }

    func dispose() {
        guard !disposed else { return }
#if os(Windows)
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        status = process.terminationStatus
#else
        _ = rc_host_poll_client(identifier, &status)
        _ = rc_host_dispose_client(identifier)
#endif
        disposed = true
        try? input?.close()
    }

    deinit { dispose(); try? output.close() }
}
