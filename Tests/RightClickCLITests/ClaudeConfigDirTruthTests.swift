import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import RightClickCLI

final class ClaudeConfigDirTruthTests: XCTestCase {
    func testClaudeConfigurationSurfaceHonorsClaudeConfigDirOverride() throws {
        let fm = FileManager.default

        let root = fm.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(
                "rightclick-claude-config-truth-\(UUID().uuidString)"
            )

        let home = root.appendingPathComponent("home")
        let override = root.appendingPathComponent("isolated-claude")

        try fm.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )

        try fm.createDirectory(
            at: override,
            withIntermediateDirectories: true
        )

        defer {
            try? fm.removeItem(at: root)
        }

        let prior = getenv("CLAUDE_CONFIG_DIR")
            .map { String(cString: $0) }

        setenv("CLAUDE_CONFIG_DIR", override.path, 1)

        defer {
            if let prior {
                setenv("CLAUDE_CONFIG_DIR", prior, 1)
            } else {
                unsetenv("CLAUDE_CONFIG_DIR")
            }
        }

        let file = RightClickClaudeClientAdapter()
            .configurationFile(home: home)

        XCTAssertEqual(
            file.standardizedFileURL.path,
            override
                .appendingPathComponent(".claude.json")
                .standardizedFileURL
                .path
        )
    }
}
