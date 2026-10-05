import Darwin
import Foundation

struct RightClickCommandResult {
    let status: Int32
    let output: String
}

protocol RightClickCommandRunning {
    func run(
        executable: String,
        arguments: [String]
    ) -> RightClickCommandResult
}

struct SystemRightClickCommandRunner:
    RightClickCommandRunning
{
    func run(
        executable: String,
        arguments: [String]
    ) -> RightClickCommandResult {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(
            fileURLWithPath: executable
        )

        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return RightClickCommandResult(
                status: 127,
                output:
                    error.localizedDescription
            )
        }

        let data =
            pipe.fileHandleForReading
                .readDataToEndOfFile()

        return RightClickCommandResult(
            status:
                process.terminationStatus,
            output:
                String(
                    data: data,
                    encoding: .utf8
                ) ?? ""
        )
    }
}

struct RightClickChatGPTBridgeInstallResult {
    let success: Bool
    let message: String

    let profileFile: URL?
    let launchAgentFile: URL?

    let tunnelClientPath: String?
    let tunnelClientVersion: String?

    let state:
        RightClickSetupStateReconciliation?
}

enum RightClickChatGPTBridgeInstaller {
    static func prepare(
        tunnelID: String,
        rightclickExecutable: String,
        home: URL =
            FileManager.default
                .homeDirectoryForCurrentUser,
        environment: [String: String] =
            ProcessInfo.processInfo.environment,
        keyStore:
            any RightClickRuntimeKeyStore =
            SystemRightClickRuntimeKeyStore(),
        runtimeAPIKey: String? = nil
    ) -> RightClickChatGPTBridgeInstallResult {
        do {
            try RightClickChatGPTBridge
                .validateTunnelID(
                    tunnelID
                )
        } catch {
            return failure(
                error.localizedDescription
            )
        }

        let stateFile =
            RightClickSetupStateStore
                .defaultFile(
                    home: home
                )

        let previousState =
            try? RightClickSetupStateStore
                .read(
                    from: stateFile
                )

        guard let tunnelClient =
            RightClickBridgeRuntime
                .resolveTunnelClient(
                    environment:
                        environment,
                    state:
                        previousState
                )
        else {
            return failure(
                """
                tunnel-client was not found.

                Install OpenAI tunnel-client 0.0.15 or newer.
                """
            )
        }

        guard let version =
            RightClickBridgeRuntime
                .versionOutput(
                    tunnelClientPath:
                        tunnelClient
                ),
              RightClickChatGPTBridge
                .tunnelClientVersionIsSupported(
                    version
                )
        else {
            return failure(
                """
                tunnel-client is too old or could not be inspected.
                Required: 0.0.15 or newer.
                """
            )
        }

        if let runtimeAPIKey {
            do {
                try keyStore.save(
                    runtimeAPIKey
                )
            } catch {
                return failure(
                    error.localizedDescription
                )
            }
        } else if !keyStore.contains() {
            return failure(
                """
                No OpenAI runtime API key is stored.

                Store it with:
                rightclick bridge key set
                """
            )
        }

        let profile: URL
        let launchAgent: URL

        do {
            profile =
                try RightClickChatGPTBridge
                    .writeProfile(
                        tunnelID:
                            tunnelID,
                        rightclickExecutable:
                            rightclickExecutable,
                        home:
                            home
                    )

            launchAgent =
                try RightClickChatGPTBridge
                    .writeLaunchAgent(
                        rightclickExecutable:
                            rightclickExecutable,
                        home:
                            home
                    )
        } catch {
            return failure(
                "ChatGPT bridge files were not written: \(error.localizedDescription)"
            )
        }

        let state =
            RightClickSetupStateStore
                .reconcile(
                    executable:
                        rightclickExecutable,
                    at:
                        stateFile,
                    chatGPTTunnelID:
                        tunnelID,
                    tunnelClientPath:
                        tunnelClient,
                    tunnelClientVersion:
                        version
                )

        guard state.success else {
            return RightClickChatGPTBridgeInstallResult(
                success: false,
                message:
                    state.message,
                profileFile:
                    profile,
                launchAgentFile:
                    launchAgent,
                tunnelClientPath:
                    tunnelClient,
                tunnelClientVersion:
                    version,
                state:
                    state
            )
        }

        return RightClickChatGPTBridgeInstallResult(
            success: true,
            message:
                """
                ChatGPT bridge prepared.
                profile: \(profile.path)
                LaunchAgent: \(launchAgent.path)
                tunnel-client: \(version)
                """,
            profileFile:
                profile,
            launchAgentFile:
                launchAgent,
            tunnelClientPath:
                tunnelClient,
            tunnelClientVersion:
                version,
            state:
                state
        )
    }

    static func activate(
        home: URL =
            FileManager.default
                .homeDirectoryForCurrentUser,
        uid: uid_t = getuid(),
        runner:
            any RightClickCommandRunning =
            SystemRightClickCommandRunner()
    ) -> RightClickSetup.Check {
        let plist =
            RightClickChatGPTBridge
                .launchAgentFile(
                    home: home
                )

        guard FileManager.default
            .fileExists(
                atPath: plist.path
            )
        else {
            return .init(
                success: false,
                message:
                    "ChatGPT LaunchAgent is missing: \(plist.path)"
            )
        }

        let domain =
            "gui/\(uid)"

        let service =
            "\(domain)/\(RightClickChatGPTBridge.launchAgentLabel)"

        // Safe if the service was not already loaded.
        _ = runner.run(
            executable:
                "/bin/launchctl",
            arguments: [
                "bootout",
                domain,
                plist.path,
            ]
        )

        let bootstrap =
            runner.run(
                executable:
                    "/bin/launchctl",
                arguments: [
                    "bootstrap",
                    domain,
                    plist.path,
                ]
            )

        guard bootstrap.status == 0 else {
            return .init(
                success: false,
                message:
                    "launchctl bootstrap failed: \(bootstrap.output)"
            )
        }

        let enable =
            runner.run(
                executable:
                    "/bin/launchctl",
                arguments: [
                    "enable",
                    service,
                ]
            )

        guard enable.status == 0 else {
            return .init(
                success: false,
                message:
                    "launchctl enable failed: \(enable.output)"
            )
        }

        let kickstart =
            runner.run(
                executable:
                    "/bin/launchctl",
                arguments: [
                    "kickstart",
                    "-k",
                    service,
                ]
            )

        guard kickstart.status == 0 else {
            return .init(
                success: false,
                message:
                    "launchctl kickstart failed: \(kickstart.output)"
            )
        }

        return .init(
            success: true,
            message:
                "ChatGPT bridge loaded: \(RightClickChatGPTBridge.launchAgentLabel)"
        )
    }

    private static func failure(
        _ message: String
    ) -> RightClickChatGPTBridgeInstallResult {
        RightClickChatGPTBridgeInstallResult(
            success: false,
            message: message,
            profileFile: nil,
            launchAgentFile: nil,
            tunnelClientPath: nil,
            tunnelClientVersion: nil,
            state: nil
        )
    }
}
