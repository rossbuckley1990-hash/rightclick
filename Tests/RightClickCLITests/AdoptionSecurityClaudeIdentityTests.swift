import Foundation
import XCTest
@testable import RightClickCLI

final class AdoptionSecurityClaudeIdentityTests: XCTestCase {
    private func fixture(_ body: (URL, String, URL, URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("rightclick-adoption-claude-identity-\(UUID().uuidString)")
        let client = home.appendingPathComponent(".local/bin/claude")
        let inspection = home.appendingPathComponent("inspection.txt")
        let health = home.appendingPathComponent("health.txt")
        try FileManager.default.createDirectory(at: client.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let script = """
        #!/bin/sh
        if [ "$1" = '--version' ]; then echo '2.1.288 (Claude Code)'; exit 0; fi
        if [ "$1" = 'mcp' ] && [ "$2" = 'get' ]; then cat '\(inspection.path)'; exit 0; fi
        if [ "$1" = 'mcp' ] && [ "$2" = 'list' ]; then cat '\(health.path)'; exit 0; fi
        exit 20
        """
        try Data(script.utf8).write(to: client)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: client.path)
        try body(home, home.appendingPathComponent("rightclick").path, inspection, health)
    }

    private func inspection(command: String, arguments: String = "mcp") -> String {
        "rightclick:\n  Scope: User config (available in all your projects)\n  Type: stdio\n  Command: \(command)\n  Args: \(arguments)\n"
    }

    func testClaudeRejectsCommandWithExpectedPathOnlyAsPrefix() throws {
        try fixture { home, binary, text, _ in
            try Data(inspection(command: binary + "-foreign").utf8).write(to: text)
            let recipe = try RightClickConnectionRecipe.stdio(command: binary, arguments: ["mcp"])
            XCTAssertThrowsError(try RightClickClaudeClientAdapter().planConfiguration(
                home: home, recipe: recipe, disconnect: false))
        }
    }

    func testClaudeRejectsAdditionalArgumentsAfterMCPPrefix() throws {
        try fixture { home, binary, text, _ in
            try Data(inspection(command: binary, arguments: "mcp --http").utf8).write(to: text)
            let recipe = try RightClickConnectionRecipe.stdio(command: binary, arguments: ["mcp"])
            XCTAssertThrowsError(try RightClickClaudeClientAdapter().planConfiguration(
                home: home, recipe: recipe, disconnect: false))
        }
    }

    func testClaudeRejectsDuplicateCommandAuthorityFields() throws {
        try fixture { home, binary, text, _ in
            let output = inspection(command: binary) + "  Command: /foreign/rightclick\n"
            try Data(output.utf8).write(to: text)
            let recipe = try RightClickConnectionRecipe.stdio(command: binary, arguments: ["mcp"])
            XCTAssertThrowsError(try RightClickClaudeClientAdapter().planConfiguration(
                home: home, recipe: recipe, disconnect: false))
        }
    }

    func testClaudeCannotReportConnectedFromNotConnectedHealthText() throws {
        try fixture { home, binary, text, health in
            try Data(inspection(command: binary).utf8).write(to: text)
            try Data("rightclick: \(binary) mcp - Not Connected\n".utf8).write(to: health)
            let plan = try RightClickOnboardingEngine.plan(adapter: RightClickClaudeClientAdapter(),
                home: home, executable: binary)
            XCTAssertFalse(plan.mutation.changed)
            XCTAssertThrowsError(try RightClickOnboardingEngine.apply(plan),
                "A substring inside a negative health state cannot establish a live client connection.")
        }
    }
}
