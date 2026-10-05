import Foundation

enum RightClickOpenAIPlugin {
    static func install(
        executable: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> RightClickSetup.Check {
        let fileManager = FileManager.default
        let pluginRoot = home.appendingPathComponent("plugins/rightclick", isDirectory: true)
        let manifestDirectory = pluginRoot.appendingPathComponent(".codex-plugin", isDirectory: true)
        let skillDirectory = pluginRoot.appendingPathComponent("skills/rightclick", isDirectory: true)
        let binDirectory = pluginRoot.appendingPathComponent("bin", isDirectory: true)
        let marketplaceFile = home.appendingPathComponent(".agents/plugins/marketplace.json")

        do {
            let marketplace = try updatedMarketplace(at: marketplaceFile)

            try fileManager.createDirectory(
                at: manifestDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: skillDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: binDirectory,
                withIntermediateDirectories: true
            )

            try writeJSON(
                pluginManifest(),
                to: manifestDirectory.appendingPathComponent("plugin.json")
            )

            try writeJSON(
                mcpConfiguration(),
                to: pluginRoot.appendingPathComponent(".mcp.json")
            )

            try skillText.write(
                to: skillDirectory.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )

            let launcher = """
            #!/bin/zsh
            set -euo pipefail
            exec \(shellQuote(executable)) mcp

            """

            let launcherFile = binDirectory.appendingPathComponent("rightclick-mcp")
            try launcher.write(
                to: launcherFile,
                atomically: true,
                encoding: .utf8
            )

            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: launcherFile.path
            )

            try writeJSON(marketplace, to: marketplaceFile)

            return RightClickSetup.Check(
                success: true,
                message: """
                ChatGPT/Codex local plugin written:
                \(pluginRoot.path)

                Personal marketplace:
                \(marketplaceFile.path)

                Restart the desktop client after setup.
                """
            )
        } catch {
            return RightClickSetup.Check(
                success: false,
                message: "ChatGPT/Codex plugin was not written: \(error.localizedDescription)"
            )
        }
    }

    private static func pluginManifest() -> [String: Any] {
        [
            "name": "rightclick",
            "version": "0.2.0",
            "description": "Give AI the capabilities already exposed by software installed on this Mac.",
            "author": [
                "name": "Ross Buckley",
            ],
            "license": "Apache-2.0",
            "keywords": [
                "ai-agents",
                "macos",
                "mcp",
                "capabilities",
            ],
            "skills": "./skills/",
            "mcpServers": "./.mcp.json",
            "interface": [
                "displayName": "RIGHTCLICK",
                "shortDescription": "Use capabilities on this Mac",
                "longDescription": "Discover, inspect, explain and safely invoke capabilities exposed by software already installed on this Mac.",
                "developerName": "Ross Buckley",
                "category": "Productivity",
                "capabilities": [
                    "Interactive",
                ],
                "defaultPrompt": [
                    "What can my Mac do with this text: RightClick?",
                    "Show me the capabilities available for this file.",
                    "Use the safest supported capability and verify the result.",
                ],
            ],
        ]
    }

    private static func mcpConfiguration() -> [String: Any] {
        [
            "mcpServers": [
                "rightclick": [
                    "type": "stdio",
                    "command": "zsh",
                    "args": [
                        "./bin/rightclick-mcp",
                    ],
                    "cwd": ".",
                ],
            ],
        ]
    }

    private static func marketplaceEntry() -> [String: Any] {
        [
            "name": "rightclick",
            "source": [
                "source": "local",
                "path": "./plugins/rightclick",
            ],
            "policy": [
                "installation": "AVAILABLE",
                "authentication": "ON_INSTALL",
            ],
            "category": "Productivity",
        ]
    }

    private static func updatedMarketplace(at file: URL) throws -> [String: Any] {
        let fileManager = FileManager.default
        var root: [String: Any]

        if fileManager.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            let object = try JSONSerialization.jsonObject(with: data)

            guard let existing = object as? [String: Any] else {
                throw setupError(
                    "Personal plugin marketplace is not a JSON object. Existing file was not changed."
                )
            }

            root = existing
        } else {
            root = [:]
        }

        if root["name"] == nil {
            root["name"] = "personal"
        }

        if root["interface"] == nil {
            root["interface"] = [
                "displayName": "Personal",
            ]
        }

        var plugins: [Any]

        if let existingPlugins = root["plugins"] {
            guard let array = existingPlugins as? [Any] else {
                throw setupError(
                    "Personal plugin marketplace plugins field is not an array. Existing file was not changed."
                )
            }
            plugins = array
        } else {
            plugins = []
        }

        plugins.removeAll { value in
            guard let row = value as? [String: Any] else {
                return false
            }
            return row["name"] as? String == "rightclick"
        }

        plugins.append(marketplaceEntry())
        root["plugins"] = plugins

        return root
    }

    private static func writeJSON(_ object: [String: Any], to file: URL) throws {
        let fileManager = FileManager.default

        try fileManager.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        data.append(0x0A)

        try data.write(to: file, options: .atomic)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func setupError(_ message: String) -> NSError {
        NSError(
            domain: "RightClickSetup",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: message,
            ]
        )
    }

    private static let skillText = """
    ---
    name: rightclick
    description: Use RIGHTCLICK when the user wants to discover, inspect, explain, or safely invoke capabilities exposed by software already installed on their Mac.
    ---

    # RIGHTCLICK

    Use the live RIGHTCLICK MCP tools rather than a previous capability census.

    Expected tools:

    - context_inspect
    - context_actions
    - context_explain
    - context_run
    - context_run_status
    - context_providers

    Prefer live discovery before execution.

    Respect support levels and confirmation requirements returned by RIGHTCLICK.

    Never treat invocation acceptance alone as proof that the requested real-world outcome occurred.

    Verify outcomes independently whenever possible.

    If the available environment cannot satisfy the user's constraints, abstain instead of silently weakening them.
    """
}
