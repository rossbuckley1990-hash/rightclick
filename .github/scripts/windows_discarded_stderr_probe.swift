import Foundation
#if canImport(Darwin)
import Darwin
#endif

// CI-only paired control for an existing Foundation/BoundedCapabilityProcess
// boundary. No arguments, environment values, stdin or child bytes are printed.
final class CountedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var count = 0
    private let retain: Bool
    init(retain: Bool) { self.retain = retain }
    func append(_ next: Data) {
        lock.lock(); defer { lock.unlock() }
        count += next.count
        if retain { bytes.append(next.prefix(max(0, 64 - bytes.count))) }
    }
    func snapshot() -> (Data, Int) { lock.lock(); defer { lock.unlock() }; return (bytes, count) }
}

struct Control: Codable {
    let stderrMode: String
    let completed: Bool
    let terminationStatus: Int32?
    let stdoutBytes: Int
    let discardedStderrBytes: Int
    let stdoutDrainCompleted: Bool
    let stderrDrainCompleted: Bool
    let stdinPresent: Bool
    let stderrPresent: Bool
    let inputEchoMatches: Bool
}

func control(python: URL, pipedStderr: Bool) throws -> Control {
    let process = Process()
    process.executableURL = python
    process.arguments = ["-c", "import sys; sys.stdout.buffer.write(bytes([int(sys.stdin is not None),int(sys.stderr is not None)])); sys.stdout.buffer.flush(); sys.stderr.write('discarded-probe-byte'); sys.stderr.flush(); sys.stdout.buffer.write(sys.stdin.buffer.read()); sys.stdout.buffer.flush()"]
    let environment = ProcessInfo.processInfo.environment
    // Match the existing bounded process environment exactly, including its
    // current Windows dictionary lookup. Neither branch changes inheritance.
    process.environment = ["SystemRoot": environment["SystemRoot"] ?? "C:\\Windows",
        "TEMP": FileManager.default.temporaryDirectory.path, "TMP": FileManager.default.temporaryDirectory.path]
    let input = Pipe(), output = Pipe(), stderrPipe = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = pipedStderr ? stderrPipe : FileHandle.nullDevice
    let captured = CountedBytes(retain: true), discarded = CountedBytes(retain: false)
    let stdoutDrain = DispatchGroup(), stderrDrain = DispatchGroup()
    func drain(_ pipe: Pipe, into buffer: CountedBytes, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                let bytes = pipe.fileHandleForReading.readData(ofLength: 4096)
                if bytes.isEmpty { break }
                buffer.append(bytes)
            }
        }
    }
    drain(output, into: captured, group: stdoutDrain)
    if pipedStderr { drain(stderrPipe, into: discarded, group: stderrDrain) }
    do { try process.run() }
    catch {
        try? input.fileHandleForWriting.close(); try? output.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        throw error
    }
    try? input.fileHandleForReading.close()
#if canImport(Darwin)
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
#endif
    let expected = Data([11, 22, 33, 44])
    try? input.fileHandleForWriting.write(contentsOf: expected)
    try? input.fileHandleForWriting.close()
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.002) }
    let completed = !process.isRunning
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
    try? output.fileHandleForWriting.close(); try? stderrPipe.fileHandleForWriting.close()
    let outputDone = stdoutDrain.wait(timeout: .now() + 1) == .success
    let errorDone = stderrDrain.wait(timeout: .now() + 1) == .success
    let (bytes, count) = captured.snapshot()
    return Control(stderrMode: pipedStderr ? "owned-drained-pipe" : "null-device", completed: completed,
        terminationStatus: process.terminationStatus, stdoutBytes: count,
        discardedStderrBytes: discarded.snapshot().1, stdoutDrainCompleted: outputDone,
        stderrDrainCompleted: errorDone, stdinPresent: bytes.first == 1,
        stderrPresent: bytes.count >= 2 && bytes[1] == 1,
        inputEchoMatches: bytes == Data([1, 1]) + expected)
}

struct Report: Codable {
    let platform: String
    let productSourceChanged: Bool
    let rawChildBytesPersisted: Bool
    let maximumStdoutBytesRetainedInMemory: Int
    let argumentsOrEnvironmentRetained: Bool
    let controls: [Control]
    let nullStderrFailureReproduced: Bool
    let drainedPipeControlPassed: Bool
}

do {
    guard CommandLine.arguments.count == 2 else { exit(125) }
    let python = URL(fileURLWithPath: CommandLine.arguments[1])
    guard python.isFileURL, FileManager.default.isExecutableFile(atPath: python.path) else { exit(125) }
    let legacy = try control(python: python, pipedStderr: false)
    let pipe = try control(python: python, pipedStderr: true)
    let pipePassed = pipe.completed && pipe.terminationStatus == 0 && pipe.stdoutDrainCompleted && pipe.stderrDrainCompleted
        && pipe.stdinPresent && pipe.stderrPresent && pipe.inputEchoMatches && pipe.discardedStderrBytes > 0
#if os(Windows)
    let platform = "win32"
#else
    let platform = "local-non-Windows-control"
#endif
    let report = Report(platform: platform, productSourceChanged: false, rawChildBytesPersisted: false,
        maximumStdoutBytesRetainedInMemory: 64, argumentsOrEnvironmentRetained: false, controls: [legacy, pipe],
        nullStderrFailureReproduced: legacy.completed && legacy.terminationStatus != 0 && !legacy.inputEchoMatches,
        drainedPipeControlPassed: pipePassed)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let bytes = try encoder.encode(report)
    try bytes.write(to: URL(fileURLWithPath: "windows-discarded-stderr-probe.json"))
    print(String(decoding: bytes, as: UTF8.self))
    exit(pipePassed ? 0 : 1)
} catch {
    // Error descriptions may contain paths or child details. Retain only type.
    print("{\"state\":\"FAILED\",\"errorType\":\"\(String(describing: type(of: error)))\"}")
    exit(125)
}
