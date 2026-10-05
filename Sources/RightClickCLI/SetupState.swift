import CryptoKit
import Foundation
import RightClickCore
import RightClickMCP

struct RightClickSetupState: Codable, Equatable {
    static let currentSchemaVersion = 1
    static let currentBridgeConfigurationVersion = 1

    let setupSchemaVersion: Int
    let rightclickVersion: String

    let executablePath: String
    let executableSHA256: String

    let mcpSchemaVersion: Int
    let mcpToolSchemaSHA256: String

    let chatGPTTunnelID: String?

    let tunnelClientPath: String?
    let tunnelClientVersion: String?

    let bridgeConfigurationVersion: Int
}

enum RightClickSetupStateStore {
    static func defaultFile(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent(
                "Library/Application Support/RIGHTCLICK",
                isDirectory: true
            )
            .appendingPathComponent("setup-state.json")
    }

    static func make(
        executable: String,
        chatGPTTunnelID: String? = nil,
        tunnelClientPath: String? = nil,
        tunnelClientVersion: String? = nil
    ) throws -> RightClickSetupState {
        RightClickSetupState(
            setupSchemaVersion: RightClickSetupState.currentSchemaVersion,
            rightclickVersion: RightClickVersion.current,
            executablePath: executable,
            executableSHA256: try sha256File(executable),
            mcpSchemaVersion: RightClickMCPContract.schemaVersion,
            mcpToolSchemaSHA256: RightClickMCPContract.toolSchemaSHA256(),
            chatGPTTunnelID: chatGPTTunnelID,
            tunnelClientPath: tunnelClientPath,
            tunnelClientVersion: tunnelClientVersion,
            bridgeConfigurationVersion:
                RightClickSetupState.currentBridgeConfigurationVersion
        )
    }

    @discardableResult
    static func write(
        _ state: RightClickSetupState,
        to file: URL = defaultFile()
    ) throws -> URL {
        let directory = file.deletingLastPathComponent()

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        var data = try encoder.encode(state)
        data.append(0x0A)

        try data.write(
            to: file,
            options: .atomic
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )

        return file
    }

    static func read(
        from file: URL = defaultFile()
    ) throws -> RightClickSetupState {
        let data = try Data(contentsOf: file)

        return try JSONDecoder().decode(
            RightClickSetupState.self,
            from: data
        )
    }

    static func sha256File(_ path: String) throws -> String {
        let data = try Data(
            contentsOf: URL(fileURLWithPath: path)
        )

        let digest = SHA256.hash(data: data)

        return digest
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct RightClickSetupStateReconciliation {
    let success: Bool
    let message: String
    let previous: RightClickSetupState?
    let current: RightClickSetupState?

    var executableChanged: Bool {
        guard let previous, let current else {
            return false
        }

        return previous.executablePath != current.executablePath
            || previous.executableSHA256 != current.executableSHA256
            || previous.rightclickVersion != current.rightclickVersion
    }

    var toolContractChanged: Bool {
        guard let previous, let current else {
            return false
        }

        return previous.mcpSchemaVersion != current.mcpSchemaVersion
            || previous.mcpToolSchemaSHA256 != current.mcpToolSchemaSHA256
    }
}

extension RightClickSetupStateStore {
    static func reconcile(
        executable: String,
        at file: URL = defaultFile()
    ) -> RightClickSetupStateReconciliation {
        let fileManager = FileManager.default

        var previous: RightClickSetupState?

        if fileManager.fileExists(atPath: file.path) {
            do {
                previous = try read(from: file)
            } catch {
                return RightClickSetupStateReconciliation(
                    success: false,
                    message:
                        "Setup state was not changed because \(file.path) could not be decoded: \(error.localizedDescription)",
                    previous: nil,
                    current: nil
                )
            }
        }

        do {
            let current = try make(
                executable: executable,
                chatGPTTunnelID: previous?.chatGPTTunnelID,
                tunnelClientPath: previous?.tunnelClientPath,
                tunnelClientVersion: previous?.tunnelClientVersion
            )

            try write(
                current,
                to: file
            )

            let result = RightClickSetupStateReconciliation(
                success: true,
                message: "",
                previous: previous,
                current: current
            )

            var changes: [String] = []

            if previous == nil {
                changes.append("state created")
            } else {
                changes.append(
                    result.executableChanged
                        ? "RIGHTCLICK binary changed"
                        : "RIGHTCLICK binary unchanged"
                )

                changes.append(
                    result.toolContractChanged
                        ? "MCP tool contract changed"
                        : "MCP tool contract unchanged"
                )
            }

            return RightClickSetupStateReconciliation(
                success: true,
                message:
                    "Setup state reconciled: \(file.path) (\(changes.joined(separator: "; ")))",
                previous: previous,
                current: current
            )
        } catch {
            return RightClickSetupStateReconciliation(
                success: false,
                message:
                    "Setup state was not written: \(error.localizedDescription)",
                previous: previous,
                current: nil
            )
        }
    }
}
