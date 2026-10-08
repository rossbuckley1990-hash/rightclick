import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
#if os(Linux)
import Glibc
#endif
@testable import RightClickProtocol
@testable import RightClickProviders
@testable import RightClickCore

final class MCPAdmissionPositiveAndCredentialTests: XCTestCase {
    /// Test-only bridge to the real private HTTPS provider. Python validates
    /// host/expiry/chain and the exact owned leaf before sending any credential.
    /// Production redirect/admission/size/deadline handling still wraps this
    /// URLSession template; no product TLS trust policy is changed.
    private final class TLSBridge: URLProtocol {
        struct Configuration {
            let certificate: URL
            let python: URL
            let helper: URL
        }
        private static let lock = NSLock()
        private static var configurations: [String: Configuration] = [:]
        static func register(origin: String, configuration: Configuration) {
            lock.lock(); defer { lock.unlock() }
            configurations[origin] = configuration
        }
        static func unregister(origin: String) {
            lock.lock(); defer { lock.unlock() }
            configurations.removeValue(forKey: origin)
        }
        private static func configuration(for request: URLRequest) -> Configuration? {
            guard let url = request.url, url.scheme == "https",
                  let origin = try? GraphQLHTTP.canonicalOrigin(url) else { return nil }
            lock.lock(); defer { lock.unlock() }
            return configurations[origin]
        }
        override class func canInit(with request: URLRequest) -> Bool { configuration(for: request) != nil }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                guard let configuration = Self.configuration(for: request), let url = request.url else {
                    throw RCIRError.authorityDenied
                }
                var body = request.httpBody ?? Data()
                if request.httpBody == nil, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count < 0 { throw CapabilityABIError.invalidWire }
                        if count == 0 { break }
                        guard body.count + count <= 1_048_576 else { throw RCIRError.invalidLimit }
                        body.append(contentsOf: buffer.prefix(count))
                    }
                }
                let input = try JSONSerialization.data(withJSONObject: ["url": url.absoluteString,
                    "method": request.httpMethod ?? "POST", "headers": request.allHTTPHeaderFields ?? [:],
                    "body": body.base64EncodedString()])
                let bytes = try BoundedCapabilityProcess.run(executable: configuration.python,
                    arguments: [configuration.helper.path, configuration.certificate.path],
                    timeout: 3, maximumBytes: 1_048_576, input: input)
                guard let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      let status = result["status"] as? Int,
                      let headers = result["headers"] as? [String: String],
                      let encoded = result["body"] as? String, let data = Data(base64Encoded: encoded),
                      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                    throw CapabilityABIError.invalidWire
                }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        // The isolated child is bounded to three seconds, inside the existing
        // five-second exchange deadline, and does not follow redirects.
        override func stopLoading() {}
    }
    private final class Fixture {
        let directory: URL, process: Process, endpoint: String
        private var session: URLSession?
        init(tls: Bool = false) throws {
            let directory = NativeHTTPFixture.temporaryDirectory.appendingPathComponent("mcp-authority-race-" + UUID().uuidString)
            self.directory = directory
            try NativeHTTPFixture.createPrivateDirectory(directory)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let process = Process(); self.process = process
            var initialized = false
            defer {
                if !initialized {
                    if process.isRunning { process.terminate(); process.waitUntilExit() }
                    try? NativeHTTPFixture.remove(directory)
                }
            }
            if tls {
                let tlsConfig = directory.appendingPathComponent("tls.conf")
                try NativeHTTPFixture.writePrivate(Data("[req]\nprompt=no\ndistinguished_name=subject\nx509_extensions=v3\n[subject]\nCN=127.0.0.1\n[v3]\nsubjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage=serverAuth\n".utf8), to: tlsConfig)
                _ = try BoundedCapabilityProcess.run(executable: URL(fileURLWithPath: "/usr/bin/openssl"),
                    arguments: ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-config", tlsConfig.path,
                        "-keyout", directory.appendingPathComponent("tls-key.private").path,
                        "-out", directory.appendingPathComponent("certificate.pem").path], timeout: 10, maximumBytes: 65_536)
                try NativeHTTPFixture.protect(directory.appendingPathComponent("tls-key.private"))
            }
            process.executableURL = try NativeHTTPFixture.python()
            process.arguments = [root.appendingPathComponent("Tests/Fixtures/mcp-admission-race.py").path, directory.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            let port = try NativeHTTPFixture.waitForPort(directory.appendingPathComponent("port"), process: process)
            endpoint = (tls ? "https" : "http") + "://127.0.0.1:\(port)/mcp"
            if tls {
                TLSBridge.register(origin: try GraphQLHTTP.canonicalOrigin(URL(string: endpoint)!),
                    configuration: .init(certificate: directory.appendingPathComponent("certificate.pem"),
                        python: try NativeHTTPFixture.python(), helper: root.appendingPathComponent("Tests/Fixtures/mcp-pinned-tls-client.py")))
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [TLSBridge.self]
                session = URLSession(configuration: configuration)
            }
            initialized = true
        }
        func close() {
            session?.invalidateAndCancel()
            if let url = URL(string: endpoint), let origin = try? GraphQLHTTP.canonicalOrigin(url) {
                TLSBridge.unregister(origin: origin)
            }
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? NativeHTTPFixture.remove(directory)
        }
        var transport: URLSession { session ?? .shared }
        var effects: Int {
            ((try? String(contentsOf: directory.appendingPathComponent("effects.jsonl"), encoding: .utf8)) ?? "").split(separator: "\n").count
        }
        func engine(scheme: String? = nil) throws -> (CapabilityEngine, RCIRExecutionHost) {
            let reflector = try MCPCapabilityArtifactResolver(session: session ?? .shared).resolve(.init(id: "credential-race", kind: "mcp", endpointURL: endpoint, authorityScheme: scheme))
            let host = RCIRExecutionHost(); host.configuration = { RCIRHostConfiguration() }; host.invocationJournal = { nil }
            return (.init(reflectors: [reflector], experience: nil, rcirHost: host), host)
        }
    }
    func testUnchangedMCPContractExecutesOneAdmittedEffectWithoutFabricatedVerification() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let (engine, _) = try fixture.engine()
        let capability = try XCTUnwrap(engine.capabilities(for: "effect").capabilities.first)
        let result = try engine.begin(id: capability.id, item: "effect", confirmed: true, arguments: ["challenge": "positive"])
        XCTAssertEqual(result.state, .accepted, result.message)
        XCTAssertTrue(result.rcir?.leaseConsumed == true)
        XCTAssertFalse(result.evidence.outcomeVerified)
        XCTAssertEqual(fixture.effects, 1)
    }
    func testNetworkDeadlineBeginsAtAdmittedEnqueue() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let request = try mutationRequest(fixture)
        let (_, response) = try OriginPinnedHTTP.exchange(request, deadline: 0.25, credentialIsolated: true,
            admitStart: { start in Thread.sleep(forTimeInterval: 0.75); start() })
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(fixture.effects, 1)
    }
    func testRepeatedAdmittedTransportStartSendsOneHTTPSMutation() throws {
        let fixture = try Fixture(tls: true); defer { fixture.close() }
        let request = try mutationRequest(fixture)
        _ = try OriginPinnedHTTP.exchange(request, template: fixture.transport, credentialIsolated: true,
            admitStart: { start in start(); start() })
        XCTAssertEqual(fixture.effects, 1, "Repeated enqueue callback must reuse the same admitted network task")
    }
    func testWithheldTransportStartSendsNoHTTPSMutation() throws {
        let fixture = try Fixture(tls: true); defer { fixture.close() }
        let request = try mutationRequest(fixture)
        XCTAssertThrowsError(try OriginPinnedHTTP.exchange(request, template: fixture.transport,
            credentialIsolated: true, admitStart: { _ in }))
        XCTAssertEqual(fixture.effects, 0)
    }
    private func mutationRequest(_ fixture: Fixture) throws -> URLRequest {
        var request = URLRequest(url: try XCTUnwrap(URL(string: fixture.endpoint)))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1,
            "method": "tools/call", "params": ["name": "mutation", "arguments": ["challenge": "transport-start-control"]]])
        return request
    }
    func testMCPTokenRotationInsideFinalAdmissionDoesNotUsePreparedOldCredential() throws {
        try credentialChange(remove: false)
    }
    func testMCPTokenDeletionInsideFinalAdmissionDoesNotUsePreparedOldCredential() throws {
        try credentialChange(remove: true)
    }
    func testUnchangedHTTPSMCPAuthorityProducesOneActualAdmittedEffect() throws {
        try credentialChange(remove: false, positive: true)
    }
    private func credentialChange(remove: Bool, positive: Bool = false) throws {
        let fixture = try Fixture(tls: true); defer { fixture.close() }
        let origin = try GraphQLHTTP.canonicalOrigin(URL(string: fixture.endpoint)!)
        // Configuration mistakes must fail, never masquerade as unavailable
        // Keychain. The same production HTTPS rule applies on Linux.
        XCTAssertEqual(try OpenAPIAuthorityStore.canonicalBearerOrigin(origin), origin)
        let scheme = "mcp-reconciliation-" + UUID().uuidString
        let initialToken = "test-only-original-" + UUID().uuidString
        let replacementToken = "test-only-replacement-" + UUID().uuidString
        #if os(macOS)
        // Unique loopback origin/scheme, synthetic values only; never alter an
        // existing provider credential. Do not treat an unavailable Keychain as proof.
        do { try OpenAPIAuthorityStore.setBearerToken(initialToken, origin: origin, schemeName: scheme) }
        catch OpenAPIAuthorityStoreError.keychain(_) { throw XCTSkip("Native Keychain unavailable; MCP credential-rotation proof not established") }
        defer { _ = try? OpenAPIAuthorityStore.deleteBearerToken(origin: origin, schemeName: scheme) }
        let rotate: () throws -> Void = {
            if remove { _ = try OpenAPIAuthorityStore.deleteBearerToken(origin: origin, schemeName: scheme) }
            else { try OpenAPIAuthorityStore.setBearerToken(replacementToken, origin: origin, schemeName: scheme) }
        }
        #elseif os(Linux)
        let key = "RIGHTCLICK_MCP_RECONCILIATION_TOKEN_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let oldBindings = ProcessInfo.processInfo.environment[RuntimeEnvironmentAuthority.environmentKey]
        let bindings = try JSONSerialization.data(withJSONObject: [["origin": origin, "schemeName": scheme, "tokenEnvironment": key]])
        XCTAssertEqual(setenv(RuntimeEnvironmentAuthority.environmentKey, String(decoding: bindings, as: UTF8.self), 1), 0)
        XCTAssertEqual(setenv(key, initialToken, 1), 0)
        defer {
            unsetenv(key)
            if let oldBindings { setenv(RuntimeEnvironmentAuthority.environmentKey, oldBindings, 1) }
            else { unsetenv(RuntimeEnvironmentAuthority.environmentKey) }
        }
        let rotate: () throws -> Void = {
            if remove { XCTAssertEqual(unsetenv(key), 0) }
            else { XCTAssertEqual(setenv(key, replacementToken, 1), 0) }
        }
        #else
        throw XCTSkip("No native credential authority fixture on this host")
        #endif
        #if os(macOS) || os(Linux)
        try NativeHTTPFixture.writePrivate(Data(initialToken.utf8), to: fixture.directory.appendingPathComponent("expected-token.private"))
        let (engine, host) = try fixture.engine(scheme: scheme)
        let capability = try XCTUnwrap(engine.capabilities(for: "effect").capabilities.first)
        if positive {
            let result = try engine.begin(id: capability.id, item: "effect", confirmed: true, arguments: ["challenge": "positive-authority"])
            XCTAssertEqual(result.state, .accepted, result.message)
            XCTAssertTrue(result.rcir?.leaseConsumed == true)
            XCTAssertFalse(result.evidence.outcomeVerified)
            XCTAssertEqual(fixture.effects, 1)
            return
        }
        host.beforeStart = { _, admit, enqueue in
            try rotate()
            try withoutActuallyEscaping(admit) { permit in
                try withoutActuallyEscaping(enqueue) { start in try permit(start) }
            }
        }
        let result = try engine.begin(id: capability.id, item: "effect", confirmed: true, arguments: ["challenge": "no-stale-token"])
        XCTAssertEqual(result.state, .rejected)
        XCTAssertFalse(result.rcir?.leaseConsumed ?? false)
        XCTAssertEqual(fixture.effects, 0)
        #endif
    }
}
