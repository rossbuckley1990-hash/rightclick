import Foundation
import RightClickCore
import RightClickMCP
import Security

enum RightClickSetup {
    struct Check {
        let success: Bool
        let message: String
    }

    static func succeeded(
        discovery: String,
        cursorWritten: Bool,
        openAIWritten: Bool = true,
        stateWritten: Bool = true,
        chatGPTBridgePrepared: Bool = true,
        selfTestPassed: Bool
    ) -> Bool {
        discovery == "PASS"
            && cursorWritten
            && openAIWritten
            && stateWritten
            && chatGPTBridgePrepared
            && selfTestPassed
    }

    static func run(
        args: [String] = [],
        json: Bool
    ) -> Int {
        let engine = CapabilityEngine()
        let report = engine.doctor()
        let rows = engine.providers()

        let executable =
            executablePath()

        let cursorResult =
            writeCursorConfig(
                executable:
                    executable
            )

        let openAIResult =
            RightClickOpenAIPlugin
                .install(
                    executable:
                        executable
                )

        let existingState =
            try? RightClickSetupStateStore
                .read()

        let tunnelID =
            requestedChatGPTTunnelID(
                args: args,
                existingState:
                    existingState
            )

        let stateResult:
            RightClickSetupStateReconciliation

        let bridgeCheck: Check

        if let tunnelID {
            let prepared =
                RightClickChatGPTBridgeInstaller
                    .prepare(
                        tunnelID:
                            tunnelID,
                        rightclickExecutable:
                            executable
                    )

            bridgeCheck = Check(
                success:
                    prepared.success,
                message:
                    prepared.message
            )

            if let preparedState =
                prepared.state
            {
                stateResult =
                    preparedState
            } else {
                stateResult =
                    RightClickSetupStateStore
                        .reconcile(
                            executable:
                                executable
                        )
            }
        } else {
            stateResult =
                RightClickSetupStateStore
                    .reconcile(
                        executable:
                            executable
                    )

            bridgeCheck = Check(
                success: true,
                message:
                    """
                    ChatGPT bridge not configured.
                    Pass --chatgpt-tunnel-id tunnel_<32 lowercase hex characters> to prepare it.
                    """
            )
        }

        let selfTest =
            harmlessSelfTest(engine)

        let success =
            succeeded(
                discovery:
                    report.servicesDiscovery,
                cursorWritten:
                    cursorResult.success,
                openAIWritten:
                    openAIResult.success,
                stateWritten:
                    stateResult.success,
                chatGPTBridgePrepared:
                    bridgeCheck.success,
                selfTestPassed:
                    selfTest.success
            )

        if json {
            let payload:
                [String: String] = [
                    "version":
                        RightClickVersion.current,

                    "macos":
                        report.macosVersion,

                    "services":
                        String(
                            report.serviceRegistrationCount
                        ),

                    "actionExtensions":
                        String(
                            report.actionExtensionCount
                        ),

                    "providers":
                        String(rows.count),

                    "cursor":
                        cursorResult.message,

                    "cursorStatus":
                        cursorResult.success
                        ? "PASS"
                        : "FAIL",

                    "openAI":
                        openAIResult.message,

                    "openAIStatus":
                        openAIResult.success
                        ? "PASS"
                        : "FAIL",

                    "setupState":
                        stateResult.message,

                    "setupStateStatus":
                        stateResult.success
                        ? "PASS"
                        : "FAIL",

                    "mcpToolSchemaSHA256":
                        stateResult.current?
                            .mcpToolSchemaSHA256
                        ?? "",

                    "chatGPTBridge":
                        bridgeCheck.message,

                    "chatGPTBridgeStatus":
                        tunnelID == nil
                        ? "NOT_CONFIGURED"
                        : (
                            bridgeCheck.success
                            ? "PREPARED"
                            : "FAIL"
                        ),

                    "chatGPTTunnelID":
                        stateResult.current?
                            .chatGPTTunnelID
                        ?? "",

                    "selfTest":
                        selfTest.message,

                    "selfTestStatus":
                        selfTest.success
                        ? "PASS"
                        : "FAIL",

                    "servicesDiscovery":
                        report.servicesDiscovery,

                    "mcpConnection":
                        tunnelID != nil
                            && bridgeCheck.success
                        ? "PREPARED_NOT_ACTIVATED"
                        : "NOT_VERIFIED",
                ]

            print(
                RightClickJSON.encode(
                    payload
                )
            )

            return success ? 0 : 1
        }

        let sharingNote =
            report.sharingDiscovery == "PASS"
            ? "ready"
            : report.sharingDiscovery

        let bridgeStatus: String

        if tunnelID == nil {
            bridgeStatus =
                "not configured"
        } else if bridgeCheck.success {
            bridgeStatus =
                "prepared; not activated"
        } else {
            bridgeStatus =
                "configuration failed"
        }

        print(
            """
            RIGHTCLICK

            Mac: \(sharingNote) (\(report.macosVersion))
            Services: \(report.serviceRegistrationCount) registrations
            Providers: \(rows.count)
            Action extensions: \(report.actionExtensionCount)
            Local MCP: \(cursorResult.success ? "configured" : "configuration failed")
            ChatGPT bridge: \(bridgeStatus)

            \(cursorResult.message)

            \(openAIResult.message)

            \(bridgeCheck.message)

            Setup state:
            \(stateResult.message)

            Test:
            "What can my Mac do with ~/Desktop/example.jpg?"

            Self-test: \(selfTest.message)
            """
        )

        return success ? 0 : 1
    }

    static func requestedChatGPTTunnelID(
        args: [String],
        existingState:
            RightClickSetupState?
    ) -> String? {
        if let explicit =
            argumentValue(
                args,
                "--chatgpt-tunnel-id"
            )
        {
            return explicit
        }

        return existingState?
            .chatGPTTunnelID
    }

    static func argumentValue(
        _ args: [String],
        _ name: String
    ) -> String? {
        guard
            let index =
                args.firstIndex(
                    of: name
                ),
            index + 1 < args.count
        else {
            return nil
        }

        return args[index + 1]
    }

    static func writeCursorConfig(
        executable: String,
        at file: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/mcp.json")
    ) -> Check {
        let directory = file.deletingLastPathComponent()
        let entry: [String: Any] = [
            "command": executable,
            "args": ["mcp"],
        ]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var root: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                if let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    root = existing
                } else {
                    return Check(success: false, message: "Cursor configuration was not changed because \(file.path) is not a JSON object.")
                }
            }
            var servers: [String: Any] = [:]
            if let present = root["mcpServers"] {
                guard let existing = present as? [String: Any] else {
                    return Check(success: false, message: "Cursor configuration was not changed because mcpServers is not a JSON object.")
                }
                servers = existing
            }
            servers["rightclick"] = entry
            root["mcpServers"] = servers
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file)
            return Check(success: true, message: "Cursor configuration written:\n\(file.path)")
        } catch {
            return Check(success: false, message: "Cursor configuration was not written: \(error.localizedDescription)")
        }
    }

    private static func harmlessSelfTest(_ engine: CapabilityEngine) -> Check {
        let probe = "RIGHTCLICK setup probe"
        do {
            let item = try engine.inspect(probe)
            return Check(success: item.typeIdentifier == "public.plain-text", message: "inspect text → \(item.typeIdentifier ?? "unknown")")
        } catch {
            return Check(success: false, message: "inspect failed: \(error.localizedDescription)")
        }
    }

    static func executablePath() -> String {
        let raw = CommandLine.arguments[0]
        if raw.hasPrefix("/") { return raw }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if !raw.contains("/") {
            let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
            for component in path.split(separator: ":", omittingEmptySubsequences: false) {
                let base = component.isEmpty ? directory : URL(fileURLWithPath: String(component), relativeTo: directory)
                let candidate = base.appendingPathComponent(raw).standardizedFileURL.path
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
                   !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
            // A launcher may provide an argv[0] that is absent from PATH.
            if let executable = Bundle.main.executableURL { return executable.path }
        }
        return directory.appendingPathComponent(raw).standardizedFileURL.path
    }
}

enum RightClickAuth {
    static func run(_ positional: [String]) -> Int {
        guard positional.first == "rotate" else {
            fputs("usage: rightclick auth rotate\n", stderr)
            return 2
        }
        do {
            try RightClickPaths.ensureSupportDirectory()
            let token = randomToken()
            try token.write(to: RightClickPaths.tokenFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: RightClickPaths.tokenFile.path)
            print("Token rotated. Restart rightclick serve to use it.")
            print(token)
            return 0
        } catch {
            fputs("\(error)\n", stderr)
            return 1
        }
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum RightClickServe {
    static func run(_ args: [String]) -> Int {
        let port = UInt16(flag(args, "--port") ?? "") ?? 8765
        let tunnel = args.contains("--tunnel")
        let token = loadOrCreateToken()
        print("""
        RIGHTCLICK Remote MCP

        Local:
        http://127.0.0.1:\(port)/mcp

        Authentication:
        Bearer \(token)
        """)
        if tunnel {
            startTunnel(port: port)
        } else {
            print("""

            Remote exposure:
            not enabled
            """)
        }
        setenv("RIGHTCLICK_MCP_TOKEN", token, 1)
        return RightClickMCPMain.run(["--http", "--port", String(port)])
    }

    private static func loadOrCreateToken() -> String {
        if let existing = try? String(contentsOf: RightClickPaths.tokenFile, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let token = RightClickAuth.randomToken()
        try? RightClickPaths.ensureSupportDirectory()
        try? token.write(to: RightClickPaths.tokenFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: RightClickPaths.tokenFile.path)
        return token
    }

    private static func startTunnel(port: UInt16) {
        let candidates = ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            print("\nRemote exposure:\ncloudflared is not installed")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["tunnel", "--url", "http://127.0.0.1:\(port)", "--no-autoupdate"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            if let match = text.range(of: #"https://[A-Za-z0-9-]+\.trycloudflare\.com"#, options: .regularExpression) {
                print("\nRemote:\n\(text[match])/mcp")
            }
        }
        do {
            try process.run()
        } catch {
            print("\nRemote exposure:\ncloudflared failed to start")
        }
    }

    private static func flag(_ args: [String], _ name: String) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
