import Foundation
import RightClickCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Only host-selected paths are executable. No client config bytes or child
/// output are copied into a setup error, where credentials could reach an AI.
enum RightClickClientHost {
    static var interactive: Bool {
#if os(Windows)
        // JSON and unattended setup always require --yes. The portable Windows
        // path does not depend on a particular terminal's console handles.
        return false
#else
        return isatty(STDIN_FILENO) != 0
#endif
    }

    static func executable(named name: String, home: URL,
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
#if os(Windows)
        let filename = name + ".exe"
        let fixed = [home.appendingPathComponent(".local/bin/" + filename).path,
                     home.appendingPathComponent("AppData/Local/Programs/" + name + "/" + filename).path]
#else
        let filename = name
        let fixed = [home.appendingPathComponent(".local/bin/" + filename).path,
                     "/opt/homebrew/bin/" + filename, "/usr/local/bin/" + filename]
#endif
        let search = (environment["PATH"] ?? "")
            .split(separator: RuntimePlatform.pathSeparator).map(String.init)
            .filter { RuntimePlatform.isAbsolutePath($0) }
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(filename).path }
        var seen = Set<String>()
        return (fixed + search).first {
            seen.insert($0).inserted && FileManager.default.isExecutableFile(atPath: $0)
        }.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }
}

/// A bounded native client boundary, preserving the user's environment so
/// native clients can locate their own configuration. Arguments never use a
/// shell, stdin is closed, and output is drained while the process is running.
enum RightClickClientProcess {
    struct Result {
        let status: Int32
        let output: String
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private var exceeded = false
        func append(_ chunk: Data, limit: Int) {
            lock.lock(); defer { lock.unlock() }
            if chunk.count > limit - bytes.count { exceeded = true }
            else if !exceeded { bytes.append(chunk) }
        }
        func snapshot() -> (Data, Bool) {
            lock.lock(); defer { lock.unlock() }
            return (bytes, exceeded)
        }
    }

    static func run(executable: String, arguments: [String], timeout: TimeInterval = 5,
                    maximumBytes: Int = 1_048_576) throws -> Result {
        guard RuntimePlatform.isAbsolutePath(executable),
              !executable.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              FileManager.default.isExecutableFile(atPath: executable),
              timeout.isFinite, timeout > 0, timeout <= 30,
              (1...1_048_576).contains(maximumBytes) else {
            throw RightClickOnboardingError("Native client executable or process limits are invalid.")
        }
        let child = try RightClickClientChildProcess(executable: executable, arguments: arguments)
        defer { child.dispose() }
        let buffer = Buffer(), reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { reader.leave() }
            while true {
                let chunk = child.output.readData(ofLength: 4096)
                if chunk.isEmpty { break }
                buffer.append(chunk, limit: maximumBytes)
            }
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        var failed = false
        while child.isRunning {
            if DispatchTime.now().uptimeNanoseconds >= deadline || buffer.snapshot().1 {
                failed = true
                break
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        child.dispose()
        guard !failed, reader.wait(timeout: .now() + 1) == .success else {
            try? child.output.close()
            throw RightClickOnboardingError("Native client command exceeded its time or output limit.")
        }
        let (bytes, exceeded) = buffer.snapshot()
        guard !exceeded else {
            throw RightClickOnboardingError("Native client command exceeded its output limit.")
        }
        return Result(status: child.status, output: String(decoding: bytes, as: UTF8.self))
    }
}

struct RightClickGenericClientAdapter: RightClickClientAdapter {
    let file: URL
    let id = "generic"
    let displayName = "Generic MCP"
    let setupNotice = "The selected JSON file uses the common mcpServers stdio convention. "
        + "Select a file your MCP client actually reads. Client connection requires that client's own verification."
    func detected(home: URL, applications: URL) -> Bool { false }
    func configurationFile(home: URL) -> URL { file }
    func connectionRecipe(executable: String) throws -> RightClickConnectionRecipe {
        try .stdio(command: executable, arguments: ["mcp"])
    }
    func planConfiguration(home: URL, recipe: RightClickConnectionRecipe,
                           disconnect: Bool) throws -> RightClickOnboardingMutation {
        var legacy = recipe.jsonMCPEntry
        legacy.removeValue(forKey: "type")
        return .json(try RightClickJSONConfigBackend.plan(file: file, containerKey: "mcpServers",
            entryKey: "rightclick", desiredEntry: recipe.jsonMCPEntry,
            acceptedExistingEntries: [legacy], disconnect: disconnect))
    }
    func nextMessage(disconnect: Bool) -> String {
        disconnect ? "Reload the client to use the updated configuration."
            : "Reload the client using this file and verify RIGHTCLICK in that client's MCP settings."
    }
}
