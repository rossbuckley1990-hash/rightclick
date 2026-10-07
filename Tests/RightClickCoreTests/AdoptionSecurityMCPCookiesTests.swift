import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import RightClickCore

final class AdoptionSecurityMCPCookiesTests: XCTestCase {
    func testDescriptorAcquisitionCannotBorrowAmbientCookiesOrPersistProviderCookies() throws {
#if os(Windows)
        throw XCTSkip("This local HTTP fixture uses a POSIX Python entrypoint; Windows acceptance is separately required.")
#else
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("rightclick-adoption-mcp-cookie-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let injectedName = "rightclick-adoption-injected-" + UUID().uuidString
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("scripts/acceptance-adoption-mcp-fixture.py").path,
                             directory.path, injectedName]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let portFile = directory.appendingPathComponent("port")
        let deadline = Date().addingTimeInterval(4)
        while !fm.fileExists(atPath: portFile.path) && process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let port = try String(contentsOf: portFile, encoding: .utf8)
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp"))
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "127.0.0.1", .path: "/", .name: "rightclick-adoption-ambient-" + UUID().uuidString,
            .value: "unrelated-authority",
        ]))
        HTTPCookieStorage.shared.setCookie(cookie)
        defer {
            HTTPCookieStorage.shared.deleteCookie(cookie)
            for stored in HTTPCookieStorage.shared.cookies ?? [] where stored.name == injectedName {
                HTTPCookieStorage.shared.deleteCookie(stored)
            }
        }
        let reflector = try MCPCapabilityArtifactResolver().resolve(
            .init(id: "independent-cookie-challenge", kind: "mcp", endpointURL: endpoint.absoluteString)
        )
        let capabilities = try reflector.capabilities(for: ContentItem(
            kind: "text", display: "adoption cookie challenge", text: "adoption cookie challenge",
            typeIdentifier: "public.plain-text"
        ))
        XCTAssertEqual(capabilities.count, 1, "The real MCP exchange must succeed before checking authority isolation.")
        let requests = try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(requests.compactMap { $0["method"] as? String },
                       ["initialize", "notifications/initialized", "tools/list"])
        XCTAssertTrue(requests.allSatisfy { $0["cookiePresent"] as? Bool == false },
            "An MCP declaration is not permission to borrow ambient cookies.")
        XCTAssertTrue(requests.allSatisfy { $0["authorizationPresent"] as? Bool == false })
        XCTAssertFalse((HTTPCookieStorage.shared.cookies ?? []).contains { $0.name == injectedName },
            "Public acquisition must not persist a provider response cookie as future authority.")
#endif
    }
}
