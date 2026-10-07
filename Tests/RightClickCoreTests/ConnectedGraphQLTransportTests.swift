import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import RightClickCore

final class ConnectedGraphQLTransportTests: XCTestCase {
    func testConnectedGraphQLIntrospectionAndInvocationExcludeAmbientAuthorityAndRejectDeclaredOversizeEarly() throws {
#if os(Windows)
        throw XCTSkip("Native Windows protected connection registry acceptance remains required.")
#else
        guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw RightClickError("The fixture temporary directory could not be canonicalized.")
        }
        defer { free(path) }
        let directory = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            .appendingPathComponent("connected-graphql-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let injectedName = "connected-graphql-injected-" + UUID().uuidString
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("scripts/acceptance-connect-graphql-fixture.py").path, directory.path, injectedName]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let portFile = directory.appendingPathComponent("port")
        let deadline = Date().addingTimeInterval(4)
        while !FileManager.default.fileExists(atPath: portFile.path) && process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let port = try String(contentsOf: portFile, encoding: .utf8)
        let endpoint = "http://127.0.0.1:\(port)/graphql"
        let ambient = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/",
            .name: "connected-graphql-ambient-" + UUID().uuidString, .value: "unrelated-authority"]))
        HTTPCookieStorage.shared.setCookie(ambient)
        defer {
            HTTPCookieStorage.shared.deleteCookie(ambient)
            for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.name == injectedName { HTTPCookieStorage.shared.deleteCookie(cookie) }
        }
        let registry = ConnectedProviderAcquisition.registry()
        let reflector = try registry.resolve(CapabilityArtifactDescriptor(id: "live-graphql", kind: "graphql", endpointURL: endpoint))
        let item = ContentItem(kind: "text", display: "GraphQL authority acceptance", text: "GraphQL authority acceptance", typeIdentifier: "public.plain-text")
        let capability = try XCTUnwrap(try reflector.capabilities(for: item).first)
        let execution = try reflector.begin(capability: capability, item: item, executionID: UUID().uuidString)
        XCTAssertEqual(execution.state, .accepted)
        let requests = try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?["operation"] as? String, "RightClickIntrospection")
        XCTAssertTrue(requests.allSatisfy { $0["cookiePresent"] as? Bool == false })
        XCTAssertTrue(requests.allSatisfy { $0["authorizationPresent"] as? Bool == false })
        XCTAssertFalse((HTTPCookieStorage.shared.cookies ?? []).contains { $0.name == injectedName })
        let start = Date()
        XCTAssertThrowsError(try registry.resolve(CapabilityArtifactDescriptor(id: "oversize-graphql", kind: "graphql",
            endpointURL: "http://127.0.0.1:\(port)/oversize")))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5,
            "Declared oversize must be rejected at response headers before the stalled full body completes.")
#endif
    }
}
