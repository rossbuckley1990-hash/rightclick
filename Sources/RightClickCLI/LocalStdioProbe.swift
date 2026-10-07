import Foundation
import RightClickCore
import RightClickMCP
import RightClickHostFiles
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Independent local transport acceptance. It starts the selected executable,
/// completes the MCP lifecycle and binds its reply to that child's PID and
/// measured bytes. This is never evidence that an AI client connected.
enum RightClickStdioProbe {
    private final class Responses: @unchecked Sendable {
        private let lock = NSCondition()
        private var pending = Data()
        private var responses: [Int: [String: Any]] = [:]
        private var seen = Set<Int>()
        private var failed = false
        private var received = 0

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.broadcast(); lock.unlock() }
            guard !failed, chunk.count <= 1_048_576 - received else { failed = true; return }
            received += chunk.count
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let frame = Data(pending[..<newline])
                pending = Data(pending[(newline + 1)...])
                if frame.isEmpty { continue }
                guard (try? RightClickJSONConfigBackend.rejectDuplicateJSONKeys(frame)) != nil else {
                    failed = true; return
                }
                guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
                      object["jsonrpc"] as? String == "2.0" else { failed = true; return }
                // Server notifications carry no response ID.
                if object["id"] == nil, object["method"] is String { continue }
                guard let id = object["id"] as? Int, [1, 2, 3].contains(id), seen.insert(id).inserted else {
                    failed = true; return
                }
                responses[id] = object
            }
        }

        func finish() { lock.lock(); failed = true; lock.broadcast(); lock.unlock() }

        func result(id: Int, deadline: UInt64, process: RightClickClientChildProcess) throws -> [String: Any] {
            lock.lock(); defer { lock.unlock() }
            while responses[id] == nil {
                guard !failed, process.isRunning, DispatchTime.now().uptimeNanoseconds < deadline else {
                    throw RightClickOnboardingError("The local MCP probe timed out, exited, or returned invalid bounded output.")
                }
                _ = lock.wait(until: Date().addingTimeInterval(0.020))
            }
            guard !failed, let response = responses.removeValue(forKey: id), response["error"] == nil,
                  let result = response["result"] as? [String: Any] else {
                throw RightClickOnboardingError("The local MCP probe returned a protocol error.")
            }
            return result
        }
    }

    static func run(executable: String, timeout: TimeInterval = 5) throws -> String {
        guard RuntimePlatform.isAbsolutePath(executable),
              !executable.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              FileManager.default.isExecutableFile(atPath: executable),
              timeout.isFinite, timeout > 0, timeout <= 30 else {
            throw RightClickOnboardingError("The local MCP probe needs an absolute executable and a bounded timeout.")
        }
        let expectedHash = try RightClickClientOwnershipStore.digest(executable)
        let expectedPath = URL(fileURLWithPath: executable).standardizedFileURL.path
        let expectedRealPath = URL(fileURLWithPath: executable).resolvingSymlinksInPath().standardizedFileURL.path
        // A local handshake does not need credentials or configured providers.
        let environment = ProcessInfo.processInfo.environment
#if os(Windows)
        let childEnvironment = ["SystemRoot": environment["SystemRoot"] ?? "C:\\Windows",
            "TEMP": FileManager.default.temporaryDirectory.path, "TMP": FileManager.default.temporaryDirectory.path,
            "USERPROFILE": FileManager.default.homeDirectoryForCurrentUser.path]
#elseif os(macOS)
        // Preserve an explicit home spelling without Foundation's system-alias
        // normalization. Darwin Foundation needs its own home override too.
        let selectedHome = environment["HOME"].flatMap { home in
            RuntimePlatform.isAbsolutePath(home)
                && !home.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                ? home : nil
        } ?? FileManager.default.homeDirectoryForCurrentUser.path
        let childEnvironment = ["PATH": "/usr/bin:/bin", "HOME": selectedHome,
            "CFFIXED_USER_HOME": selectedHome, "TMPDIR": FileManager.default.temporaryDirectory.path]
#else
        let childEnvironment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "TMPDIR": FileManager.default.temporaryDirectory.path]
#endif
        let process = try RightClickClientChildProcess(executable: executable, arguments: ["mcp"],
            environment: childEnvironment, inputPipe: true, mergeError: false)
        guard let input = process.input else { process.dispose(); throw RightClickOnboardingError("Could not open local MCP probe input.") }
        let responses = Responses(), reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { responses.finish(); reader.leave() }
            while true {
                // Interactive MCP replies may be smaller than a full chunk.
                // readData(ofLength:) can wait for that length or EOF, while
                // the server is waiting for our next lifecycle request.
                let data = process.output.availableData
                if data.isEmpty { break }
                responses.append(data)
            }
        }
        defer {
            process.dispose()
            _ = reader.wait(timeout: .now() + 1)
            try? process.output.close()
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
            data.append(10)
            // A single small request fits in the pipe even when a failed child
            // stops reading. Linux contains SIGPIPE only on this calling thread.
#if os(Linux)
            let status = data.withUnsafeBytes { bytes in
                rc_host_write_pipe(input.fileDescriptor,
                    bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
            guard status == 0 else { throw RightClickOnboardingError("The local MCP probe input closed unexpectedly.") }
#else
            do { try input.write(contentsOf: data) }
            catch { throw RightClickOnboardingError("The local MCP probe input closed unexpectedly.") }
#endif
        }
        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-11-25", "capabilities": [:],
            "clientInfo": ["name": "rightclick-setup-probe", "version": RightClickVersion.current]]])
        let initialization = try responses.result(id: 1, deadline: deadline, process: process)
        guard initialization["protocolVersion"] as? String == "2025-11-25",
              let server = initialization["serverInfo"] as? [String: Any],
              server["name"] as? String == "rightclick", server["version"] as? String == RightClickVersion.current else {
            throw RightClickOnboardingError("The selected executable returned a different MCP server or version.")
        }
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try send(["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]])
        let list = try responses.result(id: 2, deadline: deadline, process: process)
        let expectedNames = Set(RightClickAgentABIProfile.core.operations)
        guard let tools = list["tools"] as? [[String: Any]], tools.count == 7,
              Set(tools.compactMap { $0["name"] as? String }) == expectedNames,
              tools.allSatisfy({ ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" }),
              let toolsJSON = try? JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys, .withoutEscapingSlashes]),
              RightClickMCPContract.matchesToolSchema(toolsJSON),
              list["nextCursor"] == nil else {
            throw RightClickOnboardingError("The selected executable does not expose the exact complete Core7 MCP contract.")
        }
        try send(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": [
            "name": "context_runtime", "arguments": [:]]])
        let call = try responses.result(id: 3, deadline: deadline, process: process)
        guard call["isError"] as? Bool != true,
              let content = call["content"] as? [[String: Any]], content.count == 1,
              content[0]["type"] as? String == "text", let text = content[0]["text"] as? String,
              let bytes = text.data(using: .utf8),
              (try? RightClickJSONConfigBackend.rejectDuplicateJSONKeys(bytes)) != nil,
              let identity = try? JSONDecoder().decode(RightClickRuntimeIdentity.self, from: bytes),
              identity.product == "RIGHTCLICK", identity.version == RightClickVersion.current,
              identity.transport == "stdio", identity.pid == Int(process.identifier),
              identity.executablePath == expectedPath, identity.executableRealPath == expectedRealPath,
              identity.executableSHA256 == expectedHash,
              try RightClickClientOwnershipStore.digest(executable) == expectedHash,
              identity.agentABIProfiles?.contains(where: {
                  $0.id == "core" && $0.version == RightClickAgentABIProfile.core.version
                      && $0.operations.count == 7 && Set($0.operations) == expectedNames
              }) == true else {
            throw RightClickOnboardingError("The local MCP runtime identity does not match the launched process, binary or Core7 profile.")
        }
        return "VERIFIED: local stdio initialize, exact Core7, context_runtime PID/path/SHA256; AI client handshake NOT_OBSERVED"
    }
}
