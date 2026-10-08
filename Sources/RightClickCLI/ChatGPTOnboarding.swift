import Darwin
import Foundation

enum RightClickChatGPTOnboarding {
    struct SetupError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }

    struct Options {
        var dryRun = false
        var yes = false
        var json = false
        var help = false

        init(_ args: [String]) throws {
            guard args.first == "chatgpt" else {
                throw SetupError(
                    "Use `rightclick setup chatgpt`."
                )
            }

            var seen = Set<String>()

            for arg in args.dropFirst() {
                guard seen.insert(arg).inserted else {
                    throw SetupError(
                        "Repeated option: \(arg)"
                    )
                }

                switch arg {
                case "--dry-run":
                    dryRun = true

                case "--yes":
                    yes = true

                case "--json":
                    json = true

                case "--help", "-h":
                    help = true

                default:
                    throw SetupError(
                        "Unknown ChatGPT setup option: \(arg)"
                    )
                }
            }
        }
    }

    static let usage = """
    rightclick setup chatgpt [--dry-run] [--yes] [--json]

    ChatGPT setup persists only the supported Homebrew stable entrypoint.

    Development builds, temporary paths and stale Cellar binaries are
    rejected rather than written into the ChatGPT bridge configuration.
    """

    static func profileCommand(
        _ file: URL
    ) throws -> String? {
        guard FileManager.default
            .fileExists(atPath: file.path)
        else {
            return nil
        }

        let text = try String(
            contentsOf: file,
            encoding: .utf8
        )

        return RightClickChatGPTBridgeProfile.command(in: text)
    }

    static func launchAgentArguments(
        _ file: URL
    ) throws -> [String]? {
        guard FileManager.default
            .fileExists(atPath: file.path)
        else {
            return nil
        }

        let data = try Data(contentsOf: file)

        let object =
            try PropertyListSerialization
                .propertyList(
                    from: data,
                    options: [],
                    format: nil
                )

        guard
            let dictionary =
                object as? [String: Any]
        else {
            throw SetupError(
                "ChatGPT LaunchAgent root is not a dictionary."
            )
        }

        return dictionary[
            "ProgramArguments"
        ] as? [String]
    }

    static func plan(
        home: URL =
            FileManager.default
                .homeDirectoryForCurrentUser,

        executable: String,

        persistentExecutable: String? = nil,

        keyStore:
            any RightClickRuntimeKeyStore =
            SystemRightClickRuntimeKeyStore(),

        runner:
            any RightClickCommandRunning =
            SystemRightClickCommandRunner(),

        uid: uid_t = getuid()
    ) throws -> [String: String] {
        guard FileManager.default
            .isExecutableFile(
                atPath: executable
            )
        else {
            throw SetupError(
                "RIGHTCLICK executable is missing or not executable: \(executable)"
            )
        }

        let desiredExecutable: String

        if let persistentExecutable {
            desiredExecutable =
                persistentExecutable
        } else {
            do {
                desiredExecutable =
                    try RightClickStableEntrypoint
                        .resolve(
                            invokedExecutable:
                                executable
                        )
            } catch {
                return [
                    "client":
                        "chatgpt",

                    "status":
                        "DEVELOPMENT_ENTRYPOINT_REJECTED",

                    "configurationChanged":
                        "false",

                    "invokedExecutable":
                        executable,

                    "mcpConnection":
                        "NOT_VERIFIED",

                    "outcomeVerification":
                        "NOT_RUN",

                    "next":
                        "Install and run RIGHTCLICK from its supported Homebrew stable entrypoint before configuring ChatGPT.",

                    "error":
                        error.localizedDescription,
                ]
            }
        }

        guard FileManager.default
            .isExecutableFile(
                atPath:
                    desiredExecutable
            )
        else {
            throw SetupError(
                "Persistent RIGHTCLICK executable is missing or not executable: \(desiredExecutable)"
            )
        }

        let stateFile =
            RightClickSetupStateStore
                .defaultFile(home: home)

        let profileFile =
            RightClickChatGPTBridge
                .profileFile(home: home)

        let launchAgentFile =
            RightClickChatGPTBridge
                .launchAgentFile(home: home)

        let desiredSHA =
            try RightClickSetupStateStore
                .sha256File(desiredExecutable)

        var payload: [String: String] = [
            "client":
                "chatgpt",

            "mode":
                "preview",

            "desiredExecutable":
                desiredExecutable,

            "desiredExecutableSHA256":
                desiredSHA,

            "profile":
                profileFile.path,

            "launchAgent":
                launchAgentFile.path,

            "setupState":
                stateFile.path,

            "configurationChanged":
                "false",

            "mcpConnection":
                "NOT_ATTESTED_BY_THIS_PREVIEW",

            "outcomeVerification":
                "NOT_RUN",
        ]

        guard FileManager.default
            .fileExists(
                atPath: stateFile.path
            )
        else {
            payload["status"] =
                "PAIRING_REQUIRED"

            payload["next"] =
                "No saved ChatGPT tunnel identity was found."

            return payload
        }

        let state: RightClickSetupState

        do {
            state =
                try RightClickSetupStateStore
                    .read(from: stateFile)
        } catch {
            throw SetupError(
                "Existing setup state could not be decoded: \(error.localizedDescription)"
            )
        }

        guard
            let tunnelID =
                state.chatGPTTunnelID,
            !tunnelID.isEmpty
        else {
            payload["status"] =
                "PAIRING_REQUIRED"

            payload["next"] =
                "A ChatGPT tunnel must be paired before local bridge setup."

            return payload
        }

        payload["tunnelIDPresent"] =
            "true"

        let keyStored =
            keyStore.contains()

        payload["keychainCredentialStored"] =
            keyStored ? "true" : "false"

        guard keyStored else {
            payload["status"] =
                "KEY_REQUIRED"

            payload["next"] =
                "Store the ChatGPT runtime credential before activating the bridge."

            return payload
        }

        guard
            let tunnelClient =
                RightClickBridgeRuntime
                    .resolveTunnelClient(
                        state: state,
                        rightclickExecutablePath:
                            desiredExecutable
                    )
        else {
            payload["status"] =
                "TUNNEL_CLIENT_MISSING"

            return payload
        }

        payload["tunnelClient"] =
            tunnelClient

        guard
            let tunnelVersion =
                RightClickBridgeRuntime
                    .versionOutput(
                        tunnelClientPath:
                            tunnelClient
                    )
        else {
            payload["status"] =
                "TUNNEL_CLIENT_UNREADABLE"

            return payload
        }

        payload["tunnelClientVersion"] =
            tunnelVersion

        guard
            RightClickChatGPTBridge
                .tunnelClientVersionIsSupported(
                    tunnelVersion
                )
        else {
            payload["status"] =
                "TUNNEL_CLIENT_UNSUPPORTED"

            return payload
        }

        let currentProfileCommand =
            try profileCommand(
                profileFile
            )

        let desiredProfileCommand =
            "\(desiredExecutable) mcp"

        payload["profileTarget"] =
            currentProfileCommand
            ?? "MISSING"

        payload["desiredProfileTarget"] =
            desiredProfileCommand

        let profileAligned =
            currentProfileCommand
            == desiredProfileCommand

        payload["profileAligned"] =
            profileAligned
            ? "true"
            : "false"

        let currentLaunchArguments =
            try launchAgentArguments(
                launchAgentFile
            )

        let desiredLaunchArguments = [
            desiredExecutable,
            "bridge",
            "run",
        ]

        payload["launchAgentTarget"] =
            currentLaunchArguments?
                .joined(separator: " ")
            ?? "MISSING"

        payload["desiredLaunchAgentTarget"] =
            desiredLaunchArguments
                .joined(separator: " ")

        let launchAgentAligned =
            currentLaunchArguments
            == desiredLaunchArguments

        payload["launchAgentAligned"] =
            launchAgentAligned
            ? "true"
            : "false"

        let desiredState =
            try RightClickSetupStateStore
                .make(
                    executable:
                        desiredExecutable,

                    chatGPTTunnelID:
                        tunnelID,

                    tunnelClientPath:
                        tunnelClient,

                    tunnelClientVersion:
                        tunnelVersion
                )

        let stateAligned =
            state == desiredState

        payload["stateExecutable"] =
            state.executablePath

        payload["stateExecutableSHA256"] =
            state.executableSHA256

        payload["stateAligned"] =
            stateAligned
            ? "true"
            : "false"

        let bridgeStatus =
            RightClickChatGPTBridgeInstaller
                .status(
                    uid: uid,
                    runner: runner
                )

        payload["bridgeRunning"] =
            bridgeStatus.success
            ? "true"
            : "false"

        let aligned =
            profileAligned
            && launchAgentAligned
            && stateAligned
            && bridgeStatus.success

        payload["allAligned"] =
            aligned ? "true" : "false"

        payload["migrationRequired"] =
            aligned ? "false" : "true"

        payload["status"] =
            aligned
            ? "ALIGNED"
            : "DRIFT_DETECTED"

        payload["next"] =
            aligned
            ? "No local ChatGPT bridge migration is required."
            : "Migration required. Review the plan, then run `rightclick setup chatgpt --yes`."

        return payload
    }

    static func run(
        args: [String],

        executable: String,

        persistentExecutable: String? = nil,

        home: URL =
            FileManager.default
                .homeDirectoryForCurrentUser,

        keyStore:
            any RightClickRuntimeKeyStore =
            SystemRightClickRuntimeKeyStore(),

        runner:
            any RightClickCommandRunning =
            SystemRightClickCommandRunner()
    ) -> Int {
        let json =
            args.contains("--json")

        func emit(
            _ payload: [String: String]
        ) {
            if json,
               let data =
                try? JSONSerialization
                    .data(
                        withJSONObject:
                            payload,
                        options:
                            [.sortedKeys]
                    ),
               let text =
                String(
                    data: data,
                    encoding: .utf8
                )
            {
                print(text)
                return
            }

            for key in payload.keys.sorted() {
                print(
                    "\(key): \(payload[key]!)"
                )
            }
        }

        do {
            let options =
                try Options(args)

            if options.help {
                emit([
                    "help": usage,
                ])

                return 0
            }

            if options.dryRun {
                let payload =
                    try plan(
                        home: home,
                        executable:
                            executable,
                        persistentExecutable:
                            persistentExecutable,
                        keyStore:
                            keyStore,
                        runner:
                            runner
                    )

                emit(payload)

                return 0
            }

            if !options.yes {
                var payload =
                    try plan(
                        home: home,
                        executable:
                            executable,
                        persistentExecutable:
                            persistentExecutable,
                        keyStore:
                            keyStore,
                        runner:
                            runner
                    )

                if payload["status"]
                    == "ALIGNED"
                {
                    emit(payload)
                    return 0
                }

                if payload["status"]
                    == "DRIFT_DETECTED"
                {
                    payload["status"] =
                        "CONSENT_REQUIRED"

                    payload["next"] =
                        "Review the migration plan, then run `rightclick setup chatgpt --yes`."

                    emit(payload)
                    return 3
                }

                // Pairing, credential, installation and other
                // blocking states are not consent problems.
                emit(payload)
                return 1
            }

            let payload =
                try applyMigration(
                    home: home,
                    executable:
                        executable,
                    keyStore:
                        keyStore,
                    runner:
                        runner
                )

            emit(payload)

            switch payload["status"] {
            case "APPLIED", "ALIGNED":
                return 0

            default:
                return 1
            }
        } catch {
            emit([
                "status":
                    "FAILED",

                "error":
                    String(
                        describing: error
                    ),

                "configurationChanged":
                    "false",

                "mcpConnection":
                    "NOT_VERIFIED",

                "outcomeVerification":
                    "NOT_RUN",
            ])

            return 1
        }
    }
}
