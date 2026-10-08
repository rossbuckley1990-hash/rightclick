import Foundation
#if os(Windows)
import WinSDK
#endif

enum ProbeError: Error { case nativeDeviceUnavailable, unexpectedDeviceType }
final class ProbeBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ next: Data) { lock.lock(); bytes.append(next.prefix(max(0, 64 - bytes.count))); lock.unlock() }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return bytes }
}
struct NullControl: Codable {
    let mode: String
    let deviceFileTypeCharacter: Bool
    let parentCompleted: Bool
    let parentExitCode: Int32
    let stdoutDrainCompleted: Bool
    let stdinPresent: Bool
    let stderrPresent: Bool
    let exactInputEcho: Bool
    let descendantSpawnedMarkerObserved: Bool
    let stdoutBytes: Int
    let stderrBytesWriteValidated: Int
    let ownedDeviceCloseMilliseconds: Double
    let elapsedMilliseconds: Double
    let boundedReturn: Bool
    let rawChildBytesPersisted: Bool
}

func control(python: URL, mode: String) throws -> NullControl {
#if os(Windows)
    let began = ProcessInfo.processInfo.systemUptime
    // Fixed documented Win32 device namespace, opened for writing only without
    // O_CREAT. Check the native device type before any child can write bytes.
    guard let stderr = FileHandle(forWritingAtPath: "\\\\.\\NUL") else { throw ProbeError.nativeDeviceUnavailable }
    guard GetFileType(stderr._handle) == FILE_TYPE_CHAR else {
        try? stderr.close(); throw ProbeError.unexpectedDeviceType
    }
    let descendant = mode.contains("descendant"), deadline = mode.hasPrefix("deadline")
    let large = mode == "large-stderr", repeatCount = large ? 131072 : 1
    var program = "import subprocess,sys,time; sys.stdout.buffer.write(bytes([int(sys.stdin is not None),int(sys.stderr is not None)])); sys.stdout.buffer.flush(); "
    if descendant {
        program += "subprocess.Popen([sys.executable,'-c','import time; time.sleep(5)'],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=sys.stderr,close_fds=True); sys.stdout.buffer.write(b'x'); sys.stdout.buffer.flush(); "
    }
    program += "p=b'discarded-probe-byte'*" + String(repeatCount) + "; assert sys.stderr.buffer.write(p)==len(p); sys.stderr.flush(); sys.stdout.buffer.write(sys.stdin.buffer.read()); sys.stdout.buffer.flush(); "
    if deadline { program += "time.sleep(10)" }
    let process = Process(), input = Pipe(), output = Pipe()
    process.executableURL = python; process.arguments = ["-c", program]
    let environment = ProcessInfo.processInfo.environment
    process.environment = ["SystemRoot": environment["SystemRoot"] ?? "C:\\Windows",
        "TEMP": FileManager.default.temporaryDirectory.path, "TMP": FileManager.default.temporaryDirectory.path]
    process.standardInput = input; process.standardOutput = output; process.standardError = stderr
    let bytes = ProbeBytes(), reader = DispatchGroup()
    reader.enter()
    DispatchQueue.global(qos: .utility).async {
        defer { reader.leave() }
        while let chunk = try? output.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty { bytes.append(chunk) }
    }
    do { try process.run() }
    catch { try? output.fileHandleForWriting.close(); try? input.fileHandleForWriting.close(); try? stderr.close(); throw error }
    try? input.fileHandleForReading.close()
    let expected = Data([11, 22, 33, 44])
    try? input.fileHandleForWriting.write(contentsOf: expected); try? input.fileHandleForWriting.close()
    let bound = ProcessInfo.processInfo.systemUptime + (deadline ? 0.5 : 2)
    while process.isRunning, ProcessInfo.processInfo.systemUptime < bound { Thread.sleep(forTimeInterval: 0.002) }
    let completed = !process.isRunning
    if process.isRunning { process.terminate() }
    process.waitUntilExit(); try? output.fileHandleForWriting.close()
    let drained = reader.wait(timeout: .now() + 1) == .success
    let closeBegan = ProcessInfo.processInfo.systemUptime
    try? stderr.close()
    let closeMs = (ProcessInfo.processInfo.systemUptime - closeBegan) * 1000
    let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1000
    let result = bytes.snapshot(), prefix = descendant ? Data([1, 1, 120]) : Data([1, 1])
    let echo = result == prefix + expected
    return NullControl(mode: mode, deviceFileTypeCharacter: true, parentCompleted: completed,
        parentExitCode: process.terminationStatus, stdoutDrainCompleted: drained,
        stdinPresent: result.first == 1, stderrPresent: result.count >= 2 && result[1] == 1,
        exactInputEcho: echo, descendantSpawnedMarkerObserved: descendant && result.count >= 3 && result[2] == 120,
        stdoutBytes: result.count, stderrBytesWriteValidated: echo ? 20 * repeatCount : 0,
        ownedDeviceCloseMilliseconds: closeMs, elapsedMilliseconds: elapsed,
        boundedReturn: elapsed < 2500 && closeMs < 500, rawChildBytesPersisted: false)
#else
    throw ProbeError.nativeDeviceUnavailable
#endif
}

struct NullReport: Codable {
    let platform: String
    let controls: [NullControl]
    let ownedNullDeviceControlsPassed: Bool
    let maximumStdoutBytesRetainedInMemory: Int
    let productionFullSuiteClaimed: Bool
    let argumentsOrEnvironmentRetained: Bool
}
do {
#if !os(Windows)
    exit(125)
#else
    guard CommandLine.arguments.count == 2 else { exit(125) }
    let python = URL(fileURLWithPath: CommandLine.arguments[1])
    guard FileManager.default.isExecutableFile(atPath: python.path) else { exit(125) }
    let modes = ["stdio", "large-stderr", "retained-descendant", "deadline-with-descendant"]
    let controls = try modes.map { try control(python: python, mode: $0) }
    let passed = controls.allSatisfy {
        $0.deviceFileTypeCharacter && $0.stdoutDrainCompleted && $0.stdinPresent && $0.stderrPresent
            && $0.exactInputEcho && $0.stderrBytesWriteValidated > 0 && $0.boundedReturn
            && ($0.mode.contains("descendant") ? $0.descendantSpawnedMarkerObserved : true)
            && ($0.mode.hasPrefix("deadline") ? !$0.parentCompleted : $0.parentCompleted && $0.parentExitCode == 0)
    }
    let report = NullReport(platform: "win32", controls: controls, ownedNullDeviceControlsPassed: passed,
        maximumStdoutBytesRetainedInMemory: 64, productionFullSuiteClaimed: false, argumentsOrEnvironmentRetained: false)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    try data.write(to: URL(fileURLWithPath: "windows-owned-null-probe.json"))
    print(String(decoding: data, as: UTF8.self)); exit(passed ? 0 : 1)
#endif
} catch {
    print("{\"state\":\"FAILED\",\"errorType\":\"\(String(describing: type(of: error)))\"}")
    exit(125)
}
