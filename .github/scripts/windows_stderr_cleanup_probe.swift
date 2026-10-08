import Foundation

// CI-only pressure on the proposed stderr reader/closure path. A descendant
// holds only stderr after its parent exits; the owned outer Job cleans it up.
final class ReadCount: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    func append(_ count: Int) { lock.lock(); bytes += count; lock.unlock() }
    func snapshot() -> Int { lock.lock(); defer { lock.unlock() }; return bytes }
}

struct CleanupControl: Codable {
    let path: String
    let parentCompleted: Bool
    let parentExitCode: Int32
    let groupCompletedBeforeClose: Bool
    let closeReaderMilliseconds: Double
    let elapsedMilliseconds: Double
    let stdoutBytes: Int
    let descendantSpawnedMarkerObserved: Bool
    let boundedReturn: Bool
    let descendantHoldSeconds: Int
    let rawChildBytesPersisted: Bool
}

func control(python: URL, deadlinePath: Bool) throws -> CleanupControl {
    let began = ProcessInfo.processInfo.systemUptime
    let process = Process(), stdoutPipe = Pipe(), stderrPipe = Pipe(), inputPipe = Pipe()
    process.executableURL = python
    // Python restricts inherited handles to its selected stdio: only stderr
    // refers to our pipe, while descendant stdin/stdout are independently NUL.
    process.arguments = ["-c", "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c','import time; time.sleep(5)'],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=sys.stderr,close_fds=True); sys.stdout.buffer.write(b'x'); sys.stdout.buffer.flush(); " + (deadlinePath ? "time.sleep(10)" : "pass")]
    let environment = ProcessInfo.processInfo.environment
    process.environment = ["SystemRoot": environment["SystemRoot"] ?? "C:\\Windows",
        "TEMP": FileManager.default.temporaryDirectory.path, "TMP": FileManager.default.temporaryDirectory.path]
    process.standardInput = inputPipe; process.standardOutput = stdoutPipe; process.standardError = stderrPipe
    let reader = DispatchGroup(), count = ReadCount()
    reader.enter()
    DispatchQueue.global(qos: .utility).async {
        defer { reader.leave() }
        while let bytes = try? stdoutPipe.fileHandleForReading.read(upToCount: 4096), !bytes.isEmpty { count.append(bytes.count) }
    }
    reader.enter()
    DispatchQueue.global(qos: .utility).async {
        defer { try? stderrPipe.fileHandleForReading.close(); reader.leave() }
        // Match the proposed production drain: no handler/serial handle queue.
        while let bytes = try? stderrPipe.fileHandleForReading.read(upToCount: 4096), !bytes.isEmpty {}
    }
    do { try process.run() }
    catch {
        try? inputPipe.fileHandleForWriting.close(); try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close(); try? stderrPipe.fileHandleForReading.close()
        throw error
    }
    try? inputPipe.fileHandleForReading.close(); try? inputPipe.fileHandleForWriting.close()
    // Wait until the parent has spawned the descendant and emitted its marker.
    // On Windows the stdout read completes at parent exit (or termination).
    let deadline = ProcessInfo.processInfo.systemUptime + (deadlinePath ? 0.5 : 2)
    while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.002) }
    let parentCompleted = !process.isRunning
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
    try? stdoutPipe.fileHandleForWriting.close(); try? stderrPipe.fileHandleForWriting.close()
    let groupCompleted = deadlinePath ? false : reader.wait(timeout: .now() + 1) == .success
    let closeBegan = ProcessInfo.processInfo.systemUptime
    try? stderrPipe.fileHandleForReading.close()
    let closeMs = (ProcessInfo.processInfo.systemUptime - closeBegan) * 1000
    let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1000
    let stdoutBytes = count.snapshot()
    return CleanupControl(path: deadlinePath ? "deadline" : "output-drain-deadline", parentCompleted: parentCompleted,
        parentExitCode: process.terminationStatus, groupCompletedBeforeClose: groupCompleted,
        closeReaderMilliseconds: closeMs, elapsedMilliseconds: elapsed, stdoutBytes: stdoutBytes, descendantSpawnedMarkerObserved: stdoutBytes == 1,
        boundedReturn: closeMs < 500 && elapsed < 2500, descendantHoldSeconds: 5, rawChildBytesPersisted: false)
}

struct CleanupReport: Codable {
    let platform: String
    let controls: [CleanupControl]
    let proposedClosurePathPassed: Bool
    let productionFullSuiteClaimed: Bool
    let argumentsOrEnvironmentRetained: Bool
}

do {
#if !os(Windows)
    // Windows CloseHandle behavior must be measured on the native host.
    exit(125)
#else
    guard CommandLine.arguments.count == 2 else { exit(125) }
    let python = URL(fileURLWithPath: CommandLine.arguments[1])
    guard FileManager.default.isExecutableFile(atPath: python.path) else { exit(125) }
    let normal = try control(python: python, deadlinePath: false)
    let deadline = try control(python: python, deadlinePath: true)
    let passed = normal.parentCompleted && normal.parentExitCode == 0 && !normal.groupCompletedBeforeClose
        && normal.stdoutBytes == 1 && normal.boundedReturn && !deadline.parentCompleted && deadline.stdoutBytes == 1 && deadline.boundedReturn
    let report = CleanupReport(platform: "win32", controls: [normal, deadline], proposedClosurePathPassed: passed,
        productionFullSuiteClaimed: false, argumentsOrEnvironmentRetained: false)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let bytes = try encoder.encode(report)
    try bytes.write(to: URL(fileURLWithPath: "windows-stderr-cleanup-probe.json"))
    print(String(decoding: bytes, as: UTF8.self)); exit(passed ? 0 : 1)
#endif
} catch {
    print("{\"state\":\"FAILED\",\"errorType\":\"\(String(describing: type(of: error)))\"}")
    exit(125)
}
