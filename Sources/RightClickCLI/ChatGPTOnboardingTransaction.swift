import Darwin
import Foundation

extension RightClickChatGPTOnboarding {
    struct FileSnapshot {
        let file: URL
        let existed: Bool
        let data: Data?
        let permissions: NSNumber?
    }

    static func snapshotFile(
        _ file: URL
    ) throws -> FileSnapshot {
        try RightClickLocalOnboarding
            .inspectPath(file)

        let fm =
            FileManager.default

        guard fm.fileExists(
            atPath: file.path
        ) else {
            return FileSnapshot(
                file: file,
                existed: false,
                data: nil,
                permissions: nil
            )
        }

        let attributes =
            try fm.attributesOfItem(
                atPath: file.path
            )

        guard
            attributes[.type]
                as? FileAttributeType
                == .typeRegular
        else {
            throw SetupError(
                "Unexpected file type while preparing ChatGPT migration: \(file.path)"
            )
        }

        return FileSnapshot(
            file: file,
            existed: true,
            data:
                try Data(
                    contentsOf: file
                ),
            permissions:
                attributes[
                    .posixPermissions
                ] as? NSNumber
        )
    }

    static func restoreSnapshot(
        _ snapshot: FileSnapshot
    ) throws {
        let fm =
            FileManager.default

        if !snapshot.existed {
            if fm.fileExists(
                atPath:
                    snapshot.file.path
            ) {
                try fm.removeItem(
                    at: snapshot.file
                )
            }

            return
        }

        guard let data =
            snapshot.data
        else {
            throw SetupError(
                "Rollback snapshot is missing data: \(snapshot.file.path)"
            )
        }

        try fm.createDirectory(
            at:
                snapshot.file
                    .deletingLastPathComponent(),
            withIntermediateDirectories:
                true
        )

        try data.write(
            to: snapshot.file,
            options: .atomic
        )

        if let permissions =
            snapshot.permissions
        {
            try fm.setAttributes(
                [
                    .posixPermissions:
                        permissions
                ],
                ofItemAtPath:
                    snapshot.file.path
            )
        }
    }

    static func makeBackupDirectory(
        home: URL
    ) throws -> URL {
        let directory =
            home
                .appendingPathComponent(
                    "Library/Application Support/RIGHTCLICK/backups",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "chatgpt-\(UUID().uuidString)",
                    isDirectory: true
                )

        try FileManager.default
            .createDirectory(
                at: directory,
                withIntermediateDirectories:
                    true
            )

        try FileManager.default
            .setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath:
                    directory.path
            )

        return directory
    }

    @discardableResult
    static func preserveSnapshot(
        _ snapshot: FileSnapshot,
        in directory: URL
    ) throws -> URL? {
        guard
            snapshot.existed,
            let data = snapshot.data
        else {
            return nil
        }

        let output =
            directory.appendingPathComponent(
                snapshot.file
                    .lastPathComponent
                    + ".before"
            )

        try data.write(
            to: output,
            options: .atomic
        )

        try FileManager.default
            .setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath:
                    output.path
            )

        return output
    }

    static func applyMigration(
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
        let before =
            try plan(
                home: home,
                executable:
                    executable,
                persistentExecutable:
                    persistentExecutable,
                keyStore:
                    keyStore,
                runner:
                    runner,
                uid:
                    uid
            )

        if before["status"]
            == "ALIGNED"
        {
            return before
        }

        guard
            before["status"]
                == "DRIFT_DETECTED"
        else {
            return before
        }


        guard
            let persistenceExecutable =
                before[
                    "desiredExecutable"
                ]
        else {
            return [
                "status":
                    "FAILED",

                "configurationChanged":
                    "false",

                "error":
                    "Desired stable RIGHTCLICK entrypoint was unavailable.",
            ]
        }

        let stateFile =
            RightClickSetupStateStore
                .defaultFile(home: home)

        let profileFile =
            RightClickChatGPTBridge
                .profileFile(home: home)

        let launchAgentFile =
            RightClickChatGPTBridge
                .launchAgentFile(
                    home: home
                )

        let oldState =
            try RightClickSetupStateStore
                .read(from: stateFile)

        guard
            let tunnelID =
                oldState.chatGPTTunnelID
        else {
            throw SetupError(
                "Saved ChatGPT tunnel identity disappeared before migration."
            )
        }

        let snapshots = [
            try snapshotFile(
                profileFile
            ),
            try snapshotFile(
                launchAgentFile
            ),
            try snapshotFile(
                stateFile
            ),
        ]

        let backupDirectory =
            try makeBackupDirectory(
                home: home
            )

        for snapshot in snapshots {
            _ = try preserveSnapshot(
                snapshot,
                in:
                    backupDirectory
            )
        }

        let wasRunning =
            before["bridgeRunning"]
            == "true"

        func rollback()
            -> (Bool, String)
        {
            do {
                for snapshot
                    in snapshots
                {
                    try restoreSnapshot(
                        snapshot
                    )
                }

                if wasRunning {
                    let activation =
                        RightClickChatGPTBridgeInstaller
                            .activate(
                                home: home,
                                uid: uid,
                                runner:
                                    runner
                            )

                    guard
                        activation.success
                    else {
                        return (
                            false,
                            activation.message
                        )
                    }
                }

                return (
                    true,
                    "Previous ChatGPT bridge configuration restored."
                )
            } catch {
                return (
                    false,
                    error.localizedDescription
                )
            }
        }

        let prepared =
            RightClickChatGPTBridgeInstaller
                .prepare(
                    tunnelID:
                        tunnelID,
                    rightclickExecutable:
                        persistenceExecutable,
                    home: home,
                    keyStore:
                        keyStore
                )

        guard prepared.success else {
            let rolledBack =
                rollback()

            return [
                "status":
                    rolledBack.0
                    ? "FAILED_ROLLED_BACK"
                    : "FAILED_ROLLBACK_INCOMPLETE",

                "configurationChanged":
                    "false",

                "backupDirectory":
                    backupDirectory.path,

                "error":
                    prepared.message,

                "rollback":
                    rolledBack.1,
            ]
        }

        let activated =
            RightClickChatGPTBridgeInstaller
                .activate(
                    home: home,
                    uid: uid,
                    runner:
                        runner
                )

        guard activated.success else {
            let rolledBack =
                rollback()

            return [
                "status":
                    rolledBack.0
                    ? "FAILED_ROLLED_BACK"
                    : "FAILED_ROLLBACK_INCOMPLETE",

                "configurationChanged":
                    "false",

                "backupDirectory":
                    backupDirectory.path,

                "error":
                    activated.message,

                "rollback":
                    rolledBack.1,
            ]
        }

        let after =
            try plan(
                home: home,
                executable:
                    executable,
                persistentExecutable:
                    persistentExecutable,
                keyStore:
                    keyStore,
                runner:
                    runner,
                uid:
                    uid
            )

        guard
            after["status"]
                == "ALIGNED"
        else {
            let rolledBack =
                rollback()

            return [
                "status":
                    rolledBack.0
                    ? "FAILED_ROLLED_BACK"
                    : "FAILED_ROLLBACK_INCOMPLETE",

                "configurationChanged":
                    "false",

                "backupDirectory":
                    backupDirectory.path,

                "error":
                    "Post-migration configuration attestation failed.",

                "rollback":
                    rolledBack.1,
            ]
        }

        guard
            let selectedTunnelClient =
                after["tunnelClient"]
        else {
            let rolledBack =
                rollback()

            return [
                "status":
                    rolledBack.0
                    ? "FAILED_ROLLED_BACK"
                    : "FAILED_ROLLBACK_INCOMPLETE",

                "configurationChanged":
                    "false",

                "backupDirectory":
                    backupDirectory.path,

                "error":
                    "Post-migration tunnel-client identity was unavailable.",

                "rollback":
                    rolledBack.1,
            ]
        }

        let attestation =
            waitForLiveAttestation(
                home: home,
                executable:
                    persistenceExecutable,
                tunnelClient:
                    selectedTunnelClient,
                uid: uid,
                runner:
                    runner
            )

        guard attestation.success else {
            let rolledBack =
                rollback()

            var failure =
                attestation.values

            failure["status"] =
                rolledBack.0
                ? "FAILED_ROLLED_BACK"
                : "FAILED_ROLLBACK_INCOMPLETE"

            failure["configurationChanged"] =
                "false"

            failure["backupDirectory"] =
                backupDirectory.path

            failure["rollback"] =
                rolledBack.1

            return failure
        }

        var result =
            after

        for (
            key,
            value
        ) in attestation.values {
            result[key] =
                value
        }

        result["status"] =
            "APPLIED"

        result["configurationChanged"] =
            "true"

        result["backupDirectory"] =
            backupDirectory.path

        result["rollback"] =
            "AVAILABLE"

        result["mcpConnection"] =
            "LIVE_RUNTIME_ATTESTED"

        result["next"] =
            "RIGHTCLICK ChatGPT bridge is aligned and live."

        return result
    }
}
