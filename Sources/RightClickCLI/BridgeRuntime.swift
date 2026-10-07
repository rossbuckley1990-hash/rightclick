import Darwin
import Foundation
import Dispatch
import Security

protocol RightClickRuntimeKeyStore {
    func save(_ value: String) throws
    func read() throws -> String
    func delete() throws
    func contains() -> Bool
}

enum RightClickRuntimeKeyStoreError: LocalizedError {
    case invalidKey
    case notFound
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "The OpenAI runtime API key is empty or malformed."

        case .notFound:
            return "No ChatGPT runtime API key is stored in the macOS Keychain."

        case .keychain(let status):
            if let message = SecCopyErrorMessageString(
                status,
                nil
            ) {
                return "macOS Keychain error: \(message)"
            }

            return "macOS Keychain error: \(status)"
        }
    }
}

struct SystemRightClickRuntimeKeyStore:
    RightClickRuntimeKeyStore
{
    private let service =
        RightClickChatGPTBridge.keychainService

    private let account = "runtime"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String:
                kSecClassGenericPassword,

            kSecAttrService as String:
                service,

            kSecAttrAccount as String:
                account,
        ]
    }

    func save(_ value: String) throws {
        try RightClickBridgeRuntime
            .validateRuntimeAPIKey(value)

        let data = Data(value.utf8)

        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw RightClickRuntimeKeyStoreError
                .keychain(updateStatus)
        }

        var addQuery = baseQuery

        addQuery[kSecValueData as String] =
            data

        let addStatus = SecItemAdd(
            addQuery as CFDictionary,
            nil
        )

        guard addStatus == errSecSuccess else {
            throw RightClickRuntimeKeyStoreError
                .keychain(addStatus)
        }
    }

    func read() throws -> String {
        var query = baseQuery

        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] =
            kSecMatchLimitOne

        var result: CFTypeRef?

        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )

        if status == errSecItemNotFound {
            throw RightClickRuntimeKeyStoreError
                .notFound
        }

        guard status == errSecSuccess else {
            throw RightClickRuntimeKeyStoreError
                .keychain(status)
        }

        guard
            let data = result as? Data,
            let value = String(
                data: data,
                encoding: .utf8
            )
        else {
            throw RightClickRuntimeKeyStoreError
                .invalidKey
        }

        try RightClickBridgeRuntime
            .validateRuntimeAPIKey(value)

        return value
    }

    func delete() throws {
        let status = SecItemDelete(
            baseQuery as CFDictionary
        )

        guard
            status == errSecSuccess
                || status == errSecItemNotFound
        else {
            throw RightClickRuntimeKeyStoreError
                .keychain(status)
        }
    }

    func contains() -> Bool {
        (try? read()) != nil
    }
}

struct RightClickBridgeChildConfiguration {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
}

enum RightClickBridgeRuntime {
    static let tunnelClientOverride =
        "RIGHTCLICK_TUNNEL_CLIENT"

    static func validateRuntimeAPIKey(
        _ value: String
    ) throws {
        guard !value.isEmpty else {
            throw RightClickRuntimeKeyStoreError
                .invalidKey
        }

        guard
            value.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) == value
        else {
            throw RightClickRuntimeKeyStoreError
                .invalidKey
        }

        let valid =
            value.unicodeScalars.allSatisfy {
                let scalar = $0.value

                return
                    (scalar >= 48 && scalar <= 57)
                    || (scalar >= 65 && scalar <= 90)
                    || (scalar >= 97 && scalar <= 122)
                    || scalar == 45
                    || scalar == 95
            }

        guard valid else {
            throw RightClickRuntimeKeyStoreError
                .invalidKey
        }
    }

    static func resolveTunnelClient(
        environment: [String: String] =
            ProcessInfo.processInfo.environment,
        state: RightClickSetupState? = nil,
        rightclickExecutablePath: String =
            RightClickSetup.executablePath(),
        fallbackPaths: [String] = [
            "/opt/homebrew/bin/tunnel-client",
            "/usr/local/bin/tunnel-client",
        ]
    ) -> String? {
        var candidates: [String] = []

        if let override =
            environment[tunnelClientOverride],
           !override.isEmpty
        {
            candidates.append(override)
        }

        candidates.append(
            contentsOf:
                bundledTunnelClientCandidates(
                    rightclickExecutablePath:
                        rightclickExecutablePath
                )
        )

        if let stored =
            state?.tunnelClientPath,
           !stored.isEmpty
        {
            candidates.append(stored)
        }

        candidates.append(
            contentsOf: fallbackPaths
        )

        var seen = Set<String>()

        for candidate in candidates {
            guard seen.insert(candidate).inserted else {
                continue
            }

            if FileManager.default
                .isExecutableFile(
                    atPath: candidate
                )
            {
                return candidate
            }
        }

        return nil
    }

    static func bundledTunnelClientCandidates(
        rightclickExecutablePath: String
    ) -> [String] {
        let executable = URL(
            fileURLWithPath:
                rightclickExecutablePath
        )

        var candidates: [String] = []

        // Homebrew's stable bin symlink:
        // /opt/homebrew/bin/rightclick
        //   -> /opt/homebrew/opt/rightclick/libexec/tunnel-client
        let parent =
            executable
                .deletingLastPathComponent()

        if parent.lastPathComponent == "bin" {
            let prefix =
                parent
                    .deletingLastPathComponent()

            candidates.append(
                prefix
                    .appendingPathComponent(
                        "opt/rightclick/libexec/tunnel-client"
                    )
                    .path
            )
        }

        // Direct Cellar execution:
        // .../Cellar/rightclick/<version>/bin/rightclick
        //   -> .../<version>/libexec/tunnel-client
        let resolved =
            executable
                .resolvingSymlinksInPath()

        let versionRoot =
            resolved
                .deletingLastPathComponent()
                .deletingLastPathComponent()

        candidates.append(
            versionRoot
                .appendingPathComponent(
                    "libexec/tunnel-client"
                )
                .path
        )

        return Array(
            NSOrderedSet(
                array: candidates
            )
        ) as? [String]
            ?? candidates
    }

    static func childConfiguration(
        tunnelClientPath: String,
        profileFile: URL,
        runtimeAPIKey: String,
        baseEnvironment: [String: String] =
            ProcessInfo.processInfo.environment
    ) throws -> RightClickBridgeChildConfiguration {
        try validateRuntimeAPIKey(
            runtimeAPIKey
        )

        var environment =
            baseEnvironment

        environment[
            "CONTROL_PLANE_API_KEY"
        ] = runtimeAPIKey

        return RightClickBridgeChildConfiguration(
            executablePath:
                tunnelClientPath,

            arguments: [
                "run",
                "--profile-file",
                profileFile.path,
            ],

            environment: environment
        )
    }

    static func versionOutput(
        tunnelClientPath: String
    ) -> String? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(
            fileURLWithPath:
                tunnelClientPath
        )

        process.arguments = [
            "--version",
        ]

        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data =
            pipe.fileHandleForReading
                .readDataToEndOfFile()

        return String(
            data: data,
            encoding: .utf8
        )?
        .trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }

    static func forwardTermination(
        to process: Process
    ) {
        guard process.isRunning else {
            return
        }

        process.terminate()
    }

    enum StableProfileIntegrityError:
        LocalizedError
    {
        case commandMissing(
            profile: String
        )

        case commandMismatch(
            expected: String,
            found: String
        )

        case changedDuringValidation(
            profile: String
        )

        var errorDescription: String? {
            switch self {
            case .commandMissing(
                let profile
            ):
                return """
                ChatGPT tunnel profile does not declare an MCP command.

                profile: \(profile)
                """

            case .commandMismatch(
                let expected,
                let found
            ):
                return """
                ChatGPT tunnel profile MCP command does not match the trusted RIGHTCLICK entrypoint.

                expected: \(expected)
                found: \(found)
                """

            case .changedDuringValidation(
                let profile
            ):
                return """
                ChatGPT tunnel profile changed while RIGHTCLICK was validating it.

                profile: \(profile)
                """
            }
        }
    }

    struct StableProfileAttestation:
        Equatable
    {
        let executable: String
        let expectedCommand: String
        let profileSHA256: String
    }

    static func attestStableProfile(
        profileFile: URL,

        invokedExecutable: String =
            RightClickSetup.executablePath(),

        layouts:
            [RightClickStableEntrypoint.Layout] =
            RightClickStableEntrypoint
                .productionLayouts,

        fileManager:
            FileManager = .default
    ) throws -> StableProfileAttestation {
        let stable =
            try RightClickStableEntrypoint
                .resolve(
                    invokedExecutable:
                        invokedExecutable,
                    layouts:
                        layouts,
                    fileManager:
                        fileManager
                )

        let expected =
            "\(stable) mcp"

        guard
            let commandBefore =
                try RightClickChatGPTOnboarding
                    .profileCommand(
                        profileFile
                    )
        else {
            throw StableProfileIntegrityError
                .commandMissing(
                    profile:
                        profileFile.path
                )
        }

        guard commandBefore == expected else {
            throw StableProfileIntegrityError
                .commandMismatch(
                    expected:
                        expected,
                    found:
                        commandBefore
                )
        }

        let firstSHA =
            try RightClickSetupStateStore
                .sha256File(
                    profileFile.path
                )

        guard
            let commandAfter =
                try RightClickChatGPTOnboarding
                    .profileCommand(
                        profileFile
                    )
        else {
            throw StableProfileIntegrityError
                .changedDuringValidation(
                    profile:
                        profileFile.path
                )
        }

        let secondSHA =
            try RightClickSetupStateStore
                .sha256File(
                    profileFile.path
                )

        guard
            commandAfter == expected,
            firstSHA == secondSHA
        else {
            throw StableProfileIntegrityError
                .changedDuringValidation(
                    profile:
                        profileFile.path
                )
        }

        return StableProfileAttestation(
            executable:
                stable,
            expectedCommand:
                expected,
            profileSHA256:
                secondSHA
        )
    }

    enum StableSetupStateReconciliationError:
        LocalizedError
    {
        case executableMismatch(
            expected: String,
            found: String
        )

        var errorDescription: String? {
            switch self {
            case .executableMismatch(
                let expected,
                let found
            ):
                return """
                Setup state belongs to a different RIGHTCLICK executable.

                expected: \(expected)
                found: \(found)
                """
            }
        }
    }

    @discardableResult
    static func reconcileStableSetupStateIfNeeded(
        invokedExecutable: String =
            RightClickSetup.executablePath(),

        stateFile: URL =
            RightClickSetupStateStore.defaultFile(),

        layouts:
            [RightClickStableEntrypoint.Layout] =
            RightClickStableEntrypoint
                .productionLayouts,

        fileManager:
            FileManager = .default
    ) throws -> Bool {
        let stable =
            try RightClickStableEntrypoint
                .resolve(
                    invokedExecutable:
                        invokedExecutable,
                    layouts:
                        layouts,
                    fileManager:
                        fileManager
                )

        guard
            fileManager
                .fileExists(
                    atPath:
                        stateFile.path
                )
        else {
            // Bridge startup must never invent pairing state.
            return false
        }

        let previous =
            try RightClickSetupStateStore
                .read(
                    from:
                        stateFile
                )

        guard
            previous.executablePath
                == stable
        else {
            throw StableSetupStateReconciliationError
                .executableMismatch(
                    expected:
                        stable,
                    found:
                        previous.executablePath
                )
        }

        let current =
            try RightClickSetupStateStore
                .make(
                    executable:
                        stable,
                    chatGPTTunnelID:
                        previous
                            .chatGPTTunnelID,
                    tunnelClientPath:
                        previous
                            .tunnelClientPath,
                    tunnelClientVersion:
                        previous
                            .tunnelClientVersion
                )

        guard current != previous else {
            // No rewrite on an ordinary restart.
            return false
        }

        try RightClickSetupStateStore
            .write(
                current,
                to:
                    stateFile
            )

        return true
    }

    static func runDaemon(
        keyStore: any RightClickRuntimeKeyStore =
            SystemRightClickRuntimeKeyStore()
    ) -> Int {
        let profile =
            RightClickChatGPTBridge
                .profileFile()

        guard FileManager.default
            .fileExists(
                atPath: profile.path
            )
        else {
            fputs(
                """
                RIGHTCLICK bridge profile is missing:
                \(profile.path)

                Run `rightclick setup` first.

                """,
                stderr
            )

            return 1
        }

        let profileAttestation:
            StableProfileAttestation

        do {
            profileAttestation =
                try attestStableProfile(
                    profileFile:
                        profile
                )
        } catch {
            fputs(
                """
                RIGHTCLICK refused to start the ChatGPT tunnel.

                \(error.localizedDescription)

                Run `rightclick setup chatgpt --yes` to repair the owned profile.

                """,
                stderr
            )

            return 78
        }

        let rightclickExecutable =
            profileAttestation
                .executable

        let initialProfileSHA =
            profileAttestation
                .profileSHA256

        let state =
            try? RightClickSetupStateStore
                .read()

        guard let tunnelClient =
            resolveTunnelClient(
                state: state
            )
        else {
            fputs(
                """
                tunnel-client was not found.

                RIGHTCLICK requires OpenAI tunnel-client 0.0.15 or newer.

                """,
                stderr
            )

            return 1
        }

        guard
            let version =
                versionOutput(
                    tunnelClientPath:
                        tunnelClient
                ),
            RightClickChatGPTBridge
                .tunnelClientVersionIsSupported(
                    version
                )
        else {
            fputs(
                """
                tunnel-client is missing or too old.

                Required: 0.0.15 or newer
                Found: \(versionOutput(tunnelClientPath: tunnelClient) ?? "unknown")

                """,
                stderr
            )

            return 1
        }

        let runtimeKey: String

        do {
            runtimeKey = try keyStore.read()
        } catch {
            fputs(
                "\(error.localizedDescription)\n",
                stderr
            )

            return 1
        }

        let configuration:
            RightClickBridgeChildConfiguration

        do {
            configuration =
                try childConfiguration(
                    tunnelClientPath:
                        tunnelClient,
                    profileFile:
                        profile,
                    runtimeAPIKey:
                        runtimeKey
                )
        } catch {
            fputs(
                "\(error.localizedDescription)\n",
                stderr
            )

            return 1
        }

        let process = Process()

        process.executableURL = URL(
            fileURLWithPath:
                configuration
                    .executablePath
        )

        process.arguments =
            configuration.arguments

        process.environment =
            configuration.environment

        process.standardOutput =
            FileHandle.standardOutput

        process.standardError =
            FileHandle.standardError

        let initialSHA =
            try? RightClickSetupStateStore
                .sha256File(
                    rightclickExecutable
                )

        // launchd terminates the RIGHTCLICK wrapper, not its child.
        // Convert SIGTERM/SIGINT into explicit child termination so
        // tunnel-client cannot survive as an orphan.
        Darwin.signal(
            SIGTERM,
            SIG_IGN
        )

        Darwin.signal(
            SIGINT,
            SIG_IGN
        )

        let terminationRequested =
            DispatchSemaphore(
                value: 0
            )

        let signalQueue =
            DispatchQueue(
                label:
                    "ai.rightclick.chatgpt-bridge.signals"
            )

        let termSource =
            DispatchSource
                .makeSignalSource(
                    signal: SIGTERM,
                    queue: signalQueue
                )

        let intSource =
            DispatchSource
                .makeSignalSource(
                    signal: SIGINT,
                    queue: signalQueue
                )

        termSource.setEventHandler {
            terminationRequested.signal()

            forwardTermination(
                to: process
            )
        }

        intSource.setEventHandler {
            terminationRequested.signal()

            forwardTermination(
                to: process
            )
        }

        termSource.resume()
        intSource.resume()

        defer {
            termSource.cancel()
            intSource.cancel()

            Darwin.signal(
                SIGTERM,
                SIG_DFL
            )

            Darwin.signal(
                SIGINT,
                SIG_DFL
            )
        }

        do {
            let preLaunch =
                try attestStableProfile(
                    profileFile:
                        profile
                )

            guard
                preLaunch.executable
                    == rightclickExecutable,
                preLaunch.profileSHA256
                    == initialProfileSHA
            else {
                throw StableProfileIntegrityError
                    .changedDuringValidation(
                        profile:
                            profile.path
                    )
            }
        } catch {
            fputs(
                """
                RIGHTCLICK refused to launch tunnel-client because the profile changed before launch.

                \(error.localizedDescription)

                """,
                stderr
            )

            return 78
        }

        do {
            try process.run()
        } catch {
            fputs(
                "Failed to start tunnel-client: \(error.localizedDescription)\n",
                stderr
            )

            return 1
        }

        // Cover the narrow race where termination arrives after the
        // wrapper installs its signal sources but before Process.run().
        if terminationRequested.wait(
            timeout: .now()
        ) == .success {
            forwardTermination(
                to: process
            )
        }

        // A Homebrew upgrade retargets the stable executable
        // while keeping the persisted path constant.
        //
        // Reconcile only after the new wrapper has successfully
        // started tunnel-client, never during planning/install.
        do {
            let changed =
                try reconcileStableSetupStateIfNeeded()

            if changed {
                fputs(
                    """
                    RIGHTCLICK setup state reconciled to the installed Homebrew release.

                    """,
                    stderr
                )
            }
        } catch {
            // Service continuity wins here. A stale state remains
            // visible to setup/diagnostics rather than being
            // silently replaced when ownership is uncertain.
            fputs(
                """
                RIGHTCLICK could not reconcile setup state after restart:
                \(error.localizedDescription)

                """,
                stderr
            )
        }

        while process.isRunning {
            Thread.sleep(
                forTimeInterval: 2
            )

            guard let currentProfileSHA =
                try? RightClickSetupStateStore
                    .sha256File(
                        profile.path
                    )
            else {
                fputs(
                    """
                    RIGHTCLICK tunnel profile became unreadable.
                    Stopping the ChatGPT tunnel before it can continue with unverified configuration.

                    """,
                    stderr
                )

                process.terminate()
                process.waitUntilExit()

                return 75
            }

            if currentProfileSHA
                != initialProfileSHA
            {
                fputs(
                    """
                    RIGHTCLICK tunnel profile changed on disk.
                    Restarting through the trusted bridge so the profile can be re-attested.

                    """,
                    stderr
                )

                process.terminate()
                process.waitUntilExit()

                return 75
            }

            guard let initialSHA else {
                continue
            }

            guard let currentSHA =
                try? RightClickSetupStateStore
                    .sha256File(
                        rightclickExecutable
                    )
            else {
                continue
            }

            if currentSHA != initialSHA {
                fputs(
                    """
                    RIGHTCLICK binary changed on disk.
                    Restarting ChatGPT bridge with the new release.

                    """,
                    stderr
                )

                process.terminate()
                process.waitUntilExit()

                // launchd KeepAlive will start
                // the stable RIGHTCLICK entry point again.
                return 75
            }
        }

        process.waitUntilExit()

        return Int(
            process.terminationStatus
        )
    }
}

enum RightClickBridgeCLI {
    static func run(
        _ args: [String],
        keyStore: any RightClickRuntimeKeyStore =
            SystemRightClickRuntimeKeyStore(),
        input: () -> String? = {
            readSecretFromTerminal()
        }
    ) -> Int {
        switch args {
        case ["run"]:
            return RightClickBridgeRuntime
                .runDaemon(
                    keyStore: keyStore
                )

        case ["activate"]:
            let result =
                RightClickChatGPTBridgeInstaller
                    .activate()

            if result.success {
                print(result.message)
                return 0
            }

            fputs(
                "\(result.message)\n",
                stderr
            )

            return 1

        case ["status"]:
            let result =
                RightClickChatGPTBridgeInstaller
                    .status()

            print(result.message)

            return result.success ? 0 : 1

        case ["deactivate"]:
            let result =
                RightClickChatGPTBridgeInstaller
                    .deactivate()

            if result.success {
                print(result.message)
                return 0
            }

            fputs(
                "\(result.message)\n",
                stderr
            )

            return 1

        case ["key", "set"]:
            guard
                let value = input(),
                !value.isEmpty
            else {
                fputs(
                    "No runtime API key was provided on stdin.\n",
                    stderr
                )

                return 2
            }

            do {
                try keyStore.save(value)

                print(
                    "ChatGPT runtime API key stored in macOS Keychain."
                )

                return 0
            } catch {
                fputs(
                    "\(error.localizedDescription)\n",
                    stderr
                )

                return 1
            }

        case ["key", "status"]:
            if keyStore.contains() {
                print(
                    "ChatGPT runtime API key: STORED"
                )

                return 0
            }

            print(
                "ChatGPT runtime API key: NOT STORED"
            )

            return 1

        case ["key", "delete"]:
            do {
                try keyStore.delete()

                print(
                    "ChatGPT runtime API key deleted."
                )

                return 0
            } catch {
                fputs(
                    "\(error.localizedDescription)\n",
                    stderr
                )

                return 1
            }

        default:
            fputs(
                """
                usage:
                  rightclick bridge run
                  rightclick bridge activate
                  rightclick bridge status
                  rightclick bridge deactivate
                  rightclick bridge key set
                  rightclick bridge key status
                  rightclick bridge key delete

                """,
                stderr
            )

            return 2
        }
    }
}


extension RightClickBridgeCLI {
    static func readSecretFromTerminal() -> String? {
        fputs(
            "OpenAI runtime API key: ",
            stderr
        )
        fflush(stderr)

        let descriptor = fileno(stdin)
        var original = termios()

        guard tcgetattr(
            descriptor,
            &original
        ) == 0 else {
            return readLine(
                strippingNewline: true
            )
        }

        var hidden = original
        hidden.c_lflag &= ~tcflag_t(ECHO)

        guard tcsetattr(
            descriptor,
            TCSAFLUSH,
            &hidden
        ) == 0 else {
            return readLine(
                strippingNewline: true
            )
        }

        defer {
            var restored = original

            _ = tcsetattr(
                descriptor,
                TCSAFLUSH,
                &restored
            )

            fputs("\n", stderr)
            fflush(stderr)
        }

        return readLine(
            strippingNewline: true
        )
    }
}
