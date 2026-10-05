import Foundation

enum RightClickChatGPTBridgeError: LocalizedError {
    case invalidTunnelID(String)

    var errorDescription: String? {
        switch self {
        case .invalidTunnelID(let value):
            return "Invalid OpenAI tunnel ID: \(value)"
        }
    }
}

enum RightClickChatGPTBridge {
    static let configurationVersion = 1
    static let profileName = "rightclick"
    static let launchAgentLabel = "ai.rightclick.chatgpt-bridge"

    static let keychainService =
        "ai.rightclick.chatgpt-runtime-key"

    static let minimumTunnelClientVersion =
        (major: 0, minor: 0, patch: 15)

    static func profileFile(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent(
                ".config/tunnel-client",
                isDirectory: true
            )
            .appendingPathComponent("\(profileName).yaml")
    }

    static func launchAgentFile(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent(
                "Library/LaunchAgents",
                isDirectory: true
            )
            .appendingPathComponent(
                "\(launchAgentLabel).plist"
            )
    }

    static func healthURLFile(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent(
                "Library/Application Support/RIGHTCLICK",
                isDirectory: true
            )
            .appendingPathComponent(
                "tunnel-health.url"
            )
    }

    static func tunnelLogFile(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent(
                "Library/Logs/RIGHTCLICK",
                isDirectory: true
            )
            .appendingPathComponent(
                "tunnel-client.log"
            )
    }

    static func bridgeStdoutFile(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent(
                "Library/Logs/RIGHTCLICK",
                isDirectory: true
            )
            .appendingPathComponent(
                "bridge.stdout.log"
            )
    }

    static func bridgeStderrFile(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent(
                "Library/Logs/RIGHTCLICK",
                isDirectory: true
            )
            .appendingPathComponent(
                "bridge.stderr.log"
            )
    }

    static func profileYAML(
        tunnelID: String,
        rightclickExecutable: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> String {
        try validateTunnelID(tunnelID)

        let command =
            "\(rightclickExecutable) mcp"

        return """
        config_version: 1
        control_plane:
          base_url: "https://api.openai.com"
          tunnel_id: \(yamlQuoted(tunnelID))
          api_key: "env:CONTROL_PLANE_API_KEY"
        health:
          listen_addr: "127.0.0.1:0"
          url_file: \(yamlQuoted(healthURLFile(home: home).path))
        admin_ui:
          open_browser: false
        log:
          level: info
          format: json
          file: \(yamlQuoted(tunnelLogFile(home: home).path))
        mcp:
          commands:
            - channel: main
              command: \(yamlQuoted(command))

        """
    }

    static func launchAgentPlist(
        rightclickExecutable: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> Data {
        let payload: [String: Any] = [
            "Label": launchAgentLabel,

            "ProgramArguments": [
                rightclickExecutable,
                "bridge",
                "run",
            ],

            "RunAtLoad": true,
            "KeepAlive": true,

            "ProcessType": "Background",
            "ThrottleInterval": 5,

            "StandardOutPath":
                bridgeStdoutFile(home: home).path,

            "StandardErrorPath":
                bridgeStderrFile(home: home).path,
        ]

        return try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .xml,
            options: 0
        )
    }

    static func writeProfile(
        tunnelID: String,
        rightclickExecutable: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        let file = profileFile(home: home)

        let data = Data(
            try profileYAML(
                tunnelID: tunnelID,
                rightclickExecutable: rightclickExecutable,
                home: home
            ).utf8
        )

        try writeOwnedFile(
            data,
            to: file,
            permissions: 0o600
        )

        return file
    }

    static func writeLaunchAgent(
        rightclickExecutable: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        let file = launchAgentFile(home: home)

        let data = try launchAgentPlist(
            rightclickExecutable: rightclickExecutable,
            home: home
        )

        try writeOwnedFile(
            data,
            to: file,
            permissions: 0o644
        )

        return file
    }

    static func tunnelClientVersionIsSupported(
        _ output: String
    ) -> Bool {
        guard
            let token = output
                .split(whereSeparator: \.isWhitespace)
                .first
        else {
            return false
        }

        var raw = String(token)

        if raw.hasPrefix("v") {
            raw.removeFirst()
        }

        raw = raw
            .split(separator: "+", maxSplits: 1)
            .first
            .map(String.init)
            ?? raw

        let pieces = raw.split(separator: ".")

        guard pieces.count >= 3 else {
            return false
        }

        guard
            let major = Int(pieces[0]),
            let minor = Int(pieces[1]),
            let patch = Int(pieces[2])
        else {
            return false
        }

        let candidate = (
            major: major,
            minor: minor,
            patch: patch
        )

        let minimum = minimumTunnelClientVersion

        if candidate.major != minimum.major {
            return candidate.major > minimum.major
        }

        if candidate.minor != minimum.minor {
            return candidate.minor > minimum.minor
        }

        return candidate.patch >= minimum.patch
    }

    static func validateTunnelID(
        _ value: String
    ) throws {
        let prefix = "tunnel_"

        guard value.hasPrefix(prefix) else {
            throw RightClickChatGPTBridgeError
                .invalidTunnelID(value)
        }

        let suffix = String(
            value.dropFirst(prefix.count)
        )

        guard suffix.count == 32 else {
            throw RightClickChatGPTBridgeError
                .invalidTunnelID(value)
        }

        let valid = suffix.unicodeScalars.allSatisfy {
            let value = $0.value

            return (value >= 48 && value <= 57)
                || (value >= 97 && value <= 102)
        }

        guard valid else {
            throw RightClickChatGPTBridgeError
                .invalidTunnelID(value)
        }
    }

    private static func yamlQuoted(
        _ value: String
    ) -> String {
        let escaped = value
            .replacingOccurrences(
                of: "\\",
                with: "\\\\"
            )
            .replacingOccurrences(
                of: "\"",
                with: "\\\""
            )
            .replacingOccurrences(
                of: "\n",
                with: "\\n"
            )
            .replacingOccurrences(
                of: "\r",
                with: "\\r"
            )
            .replacingOccurrences(
                of: "\t",
                with: "\\t"
            )

        return "\"\(escaped)\""
    }

    private static func writeOwnedFile(
        _ data: Data,
        to file: URL,
        permissions: Int
    ) throws {
        let directory =
            file.deletingLastPathComponent()

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        try data.write(
            to: file,
            options: .atomic
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: file.path
        )
    }
}
