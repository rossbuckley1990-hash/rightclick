#if os(macOS) || os(Linux)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders

/// These calls use the production A2A/MCP compilers and admitted native HTTP
/// transport against a separate local server. Dummy ambient storage is owned
/// by each case and removed without clearing another caller's credentials.
final class PublicInvocationCredentialIsolationTests: XCTestCase {
    private var fixture: CredentialIsolationHTTPFixture!
    private var seededCookies: [HTTPCookie] = []
    private var seededCredentials: [(URLProtectionSpace, URLCredential)] = []

    override func setUpWithError() throws {
        fixture = try CredentialIsolationHTTPFixture()
        try seed(for: fixture)
    }

    override func tearDownWithError() throws {
        for cookie in seededCookies { HTTPCookieStorage.shared.deleteCookie(cookie) }
        for (space, credential) in seededCredentials { URLCredentialStorage.shared.remove(credential, for: space) }
        seededCookies.removeAll(); seededCredentials.removeAll()
        if let fixture { try fixture.close() }
    }

    private func seed(for selected: CredentialIsolationHTTPFixture) throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: selected.cookieName, .value: "owned-dummy-cookie"]))
        HTTPCookieStorage.shared.setCookie(cookie); seededCookies.append(cookie)
        let space = URLProtectionSpace(host: "127.0.0.1", port: try XCTUnwrap(selected.base.port),
            protocol: selected.base.scheme, realm: selected.realm, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let credential = URLCredential(user: CredentialIsolationHTTPFixture.dummyUser,
            password: CredentialIsolationHTTPFixture.dummyPassword, persistence: .forSession)
        URLCredentialStorage.shared.setDefaultCredential(credential, for: space)
        seededCredentials.append((space, credential))
        XCTAssertTrue((HTTPCookieStorage.shared.cookies(for: selected.base) ?? []).contains { $0.name == selected.cookieName })
        XCTAssertEqual(URLCredentialStorage.shared.defaultCredential(for: space)?.user, CredentialIsolationHTTPFixture.dummyUser)
    }

    private func isolatedRequests(_ rows: [[String: Any]], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(rows.isEmpty, file: file, line: line)
        for row in rows {
            XCTAssertEqual(row["cookiePresent"] as? Bool, false, file: file, line: line)
            XCTAssertEqual(row["ambientBasicMatched"] as? Bool, false, file: file, line: line)
            XCTAssertEqual(row["authorizationKind"] as? String, "none", file: file, line: line)
        }
        XCTAssertFalse((HTTPCookieStorage.shared.cookies ?? []).contains { $0.name == fixture.responseCookieName }, file: file, line: line)
    }

    private func mcp(_ endpoint: URL, scheme: String? = nil) throws -> (CapabilityEngine, Capability) {
        let reflector = try MCPCapabilityArtifactResolver().resolve(.init(id: "h6-" + UUID().uuidString,
            kind: "mcp", endpointURL: endpoint.absoluteString, authorityScheme: scheme))
        let engine = CapabilityEngine(reflectors: [reflector], experience: nil, rcirHost: RCIRExecutionHost())
        let capability = try XCTUnwrap(engine.capabilities(for: "owned credential isolation").capabilities.first)
        return (engine, capability)
    }

    func testDummyAmbientCookieAndBasicCredentialsAreActiveForTheSameRealOrigin() throws {
        // Positive control: these same-origin stores can influence a normal
        // native session. Public runtime calls must explicitly isolate them.
        let session = URLSession(configuration: .default)
        defer { session.invalidateAndCancel() }
        let done = DispatchSemaphore(value: 0), lock = NSLock()
        var status: Int?, failure: Error?
        let task = session.dataTask(with: fixture.base.appendingPathComponent("ambient-control")) { _, response, error in
            lock.lock(); status = (response as? HTTPURLResponse)?.statusCode; failure = error; lock.unlock(); done.signal()
        }
        task.resume()
        guard done.wait(timeout: .now() + 5) == .success else { task.cancel(); throw RightClickError("Owned ambient positive control timed out.") }
        lock.lock(); let actual = status, error = failure; lock.unlock()
        XCTAssertNil(error); XCTAssertEqual(actual, 200)
        let rows = try fixture.rows()
        XCTAssertTrue(rows.contains { $0["ambientCookieMatched"] as? Bool == true })
        XCTAssertTrue(rows.contains { $0["ambientBasicMatched"] as? Bool == true })
        XCTAssertTrue(try fixture.rows("effects.jsonl").isEmpty)
    }

    func testPublicA2ASendAndStatusNeverAcquireAmbientHTTPAuthority() throws {
        let reflector = try A2AReflector(agentCard: fixture.card(), source: fixture.base.appendingPathComponent("agent.json"))
        let engine = CapabilityEngine(reflectors: [reflector], experience: nil, rcirHost: RCIRExecutionHost())
        let capability = try XCTUnwrap(engine.capabilities(for: "owned credential isolation").capabilities.first)
        XCTAssertEqual(try engine.begin(id: capability.id, item: "owned credential isolation", confirmed: false,
            arguments: ["message": "owned dummy task"]).state, .awaitingUser)
        XCTAssertTrue(try fixture.rows().isEmpty)
        let initial = try engine.begin(id: capability.id, item: "owned credential isolation", confirmed: true,
            arguments: ["message": "owned dummy task"])
        XCTAssertEqual(initial.state, .started, initial.message)
        XCTAssertEqual(initial.rcir?.leaseConsumed, true); XCTAssertEqual(initial.rcir?.phase, "accepted")
        let final = engine.executionStatus(initial.executionId)
        XCTAssertEqual(final.state, .accepted, final.message)
        XCTAssertFalse(final.evidence.outcomeVerified)
        let rows = try fixture.rows(); isolatedRequests(rows)
        XCTAssertEqual(rows.filter { $0["rpc"] as? String == "message/send" }.count, 1)
        XCTAssertGreaterThanOrEqual(rows.filter { $0["rpc"] as? String == "tasks/get" }.count, 1)
        let effects = try fixture.rows("effects.jsonl")
        XCTAssertEqual(effects.count, 1); XCTAssertEqual(effects.first?["invocationPresent"] as? Bool, true)
    }

    func testPublicA2ABasicChallengeCannotResolveFromSharedCredentialStorageOrRetry() throws {
        let reflector = try A2AReflector(agentCard: fixture.card(endpoint: "/a2a-challenge"), source: fixture.base.appendingPathComponent("agent.json"))
        let engine = CapabilityEngine(reflectors: [reflector], experience: nil, rcirHost: RCIRExecutionHost())
        let capability = try XCTUnwrap(engine.capabilities(for: "owned credential isolation").capabilities.first)
        let result = try engine.begin(id: capability.id, item: "owned credential isolation", confirmed: true,
            arguments: ["message": "owned dummy task"])
        XCTAssertEqual(result.state, .unknown, result.message)
        XCTAssertEqual(result.rcir?.leaseConsumed, true)
        let rows = try fixture.rows(); isolatedRequests(rows)
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?["rpc"] as? String, "message/send")
        XCTAssertTrue(try fixture.rows("effects.jsonl").isEmpty)
    }

    func testNilAuthorityMCPInitializeListAndCallNeverAcquireAmbientHTTPAuthority() throws {
        let (engine, capability) = try mcp(fixture.base.appendingPathComponent("mcp"))
        let callsBefore = try fixture.rows().filter { $0["rpc"] as? String == "tools/call" }.count
        XCTAssertEqual(try engine.begin(id: capability.id, item: "owned credential isolation", confirmed: false,
            arguments: ["message": "owned literal input"]).state, .awaitingUser)
        XCTAssertEqual(try fixture.rows().filter { $0["rpc"] as? String == "tools/call" }.count, callsBefore)
        let result = try engine.begin(id: capability.id, item: "owned credential isolation", confirmed: true,
            arguments: ["message": "owned literal input"])
        XCTAssertEqual(result.state, .accepted, result.message); XCTAssertEqual(result.rcir?.leaseConsumed, true)
        XCTAssertFalse(result.evidence.outcomeVerified)
        let rows = try fixture.rows(); isolatedRequests(rows)
        for method in ["initialize", "notifications/initialized", "tools/list", "tools/call"] {
            XCTAssertTrue(rows.contains { $0["rpc"] as? String == method })
        }
        let calls = rows.filter { $0["rpc"] as? String == "tools/call" }
        XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls.first?["sessionPresent"] as? Bool, true)
        XCTAssertEqual(try fixture.rows("effects.jsonl").count, 1)
    }

    func testNilAuthorityMCPBasicChallengeCannotResolveFromSharedCredentialStorage() throws {
        XCTAssertThrowsError(try mcp(fixture.base.appendingPathComponent("mcp-challenge")))
        let rows = try fixture.rows(); isolatedRequests(rows)
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?["rpc"] as? String, "initialize")
        XCTAssertTrue(try fixture.rows("effects.jsonl").isEmpty)
    }

#if os(macOS)
    func testExplicitLocallyProvisionedMCPBearerRemainsBoundToItsOwnedHTTPSOrigin() throws {
        let secured = try CredentialIsolationHTTPFixture(tls: true)
        defer { try? secured.close() }
        try seed(for: secured)
        CredentialIsolationTLSBridge.base = secured.base
        CredentialIsolationTLSBridge.certificate = try Data(contentsOf: secured.directory.appendingPathComponent("certificate.der"))
        XCTAssertTrue(URLProtocol.registerClass(CredentialIsolationTLSBridge.self))
        defer {
            URLProtocol.unregisterClass(CredentialIsolationTLSBridge.self)
            CredentialIsolationTLSBridge.base = nil; CredentialIsolationTLSBridge.certificate = nil
        }
        let scheme = "h6-owned-" + UUID().uuidString
        try OpenAPIAuthorityStore.setBearerToken(CredentialIsolationHTTPFixture.dummyBearer, origin: secured.base.absoluteString, schemeName: scheme)
        defer { _ = try? OpenAPIAuthorityStore.deleteBearerToken(origin: secured.base.absoluteString, schemeName: scheme) }
        XCTAssertThrowsError(try mcp(secured.base.appendingPathComponent("mcp-authorized"), scheme: scheme + "-other"))
        XCTAssertTrue(try secured.rows().isEmpty)
        let (engine, capability) = try mcp(secured.base.appendingPathComponent("mcp-authorized"), scheme: scheme)
        let result = try engine.begin(id: capability.id, item: "owned credential isolation", confirmed: true,
            arguments: ["message": "owned literal input"])
        XCTAssertEqual(result.state, .accepted, result.message); XCTAssertEqual(result.rcir?.leaseConsumed, true)
        let rows = try secured.rows()
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0["explicitBearerMatched"] as? Bool == true && $0["authorizationKind"] as? String == "Bearer" })
        XCTAssertTrue(rows.allSatisfy { $0["cookiePresent"] as? Bool == false && $0["ambientBasicMatched"] as? Bool == false })
        XCTAssertEqual(rows.filter { $0["rpc"] as? String == "tools/call" }.count, 1)
        XCTAssertEqual(try secured.rows("effects.jsonl").count, 1)
        XCTAssertFalse((HTTPCookieStorage.shared.cookies ?? []).contains { $0.name == secured.responseCookieName })
        try NativeHTTPFixture.writePrivate(Data((fixture.base.absoluteString + "/trap").utf8), to: secured.directory.appendingPathComponent("redirect-target"))
        XCTAssertThrowsError(try mcp(secured.base.appendingPathComponent("mcp-redirect"), scheme: scheme))
        XCTAssertTrue(try fixture.rows().isEmpty, "A bearer-bearing redirect must never reach the second real origin.")
    }
#endif
}
#endif
