#if canImport(Security)
import Foundation
import Security
import CryptoKit
import XCTest
@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders

/// A test-only URLProtocol bridge forwards the exact compiled bearer request to
/// a real private HTTPS provider, trusting only its generated certificate.
/// This proves production result handling, actual effects and secret confinement;
/// product TLS trust integration and issuer downscoping remain outside this proof.
final class OpenAPICredentialEchoTests: XCTestCase {
    private var directory: URL!, provider: Process!, base: URL!, secureBase: URL!
    private var token = "", scheme = "", host: RCIRExecutionHost!, key: Curve25519.Signing.PrivateKey!
    private var diagnostics: [[String: Any]] = []

    private final class Bridge: URLProtocol {
        static var loopback: URL!
        static var certificate: Data!
        private final class FixtureTrust: NSObject, URLSessionDelegate {
            func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
                guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                      let trust = challenge.protectionSpace.serverTrust,
                      let actual = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                      let first = actual.first, SecCertificateCopyData(first) as Data == Bridge.certificate,
                      let anchor = SecCertificateCreateWithData(nil, Bridge.certificate as CFData) else {
                    completionHandler(.cancelAuthenticationChallenge, nil); return
                }
                SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, true)
                guard SecTrustEvaluateWithError(trust, nil) else {
                    completionHandler(.cancelAuthenticationChallenge, nil); return
                }
                completionHandler(.useCredential, URLCredential(trust: trust))
            }
        }
        private var transfer: URLSessionDataTask?
        private var session: URLSession?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var forwarded = request
            forwarded.url = Self.loopback.appendingPathComponent(request.url!.path)
            // URLSession may represent the exact compiled body as a stream.
            if forwarded.httpBody == nil, let stream = forwarded.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
                forwarded.httpBody = bytes
            }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = []; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
            let session = URLSession(configuration: config, delegate: FixtureTrust(), delegateQueue: nil); self.session = session
            transfer = session.dataTask(with: forwarded) { data, response, error in
                defer { session.finishTasksAndInvalidate() }
                if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
                guard let real = response as? HTTPURLResponse,
                      let response = HTTPURLResponse(url: self.request.url!, statusCode: real.statusCode,
                        httpVersion: "HTTP/1.1", headerFields: real.allHeaderFields as? [String: String]) else { return }
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data ?? Data())
                self.client?.urlProtocolDidFinishLoading(self)
            }
            transfer!.resume()
        }
        override func stopLoading() { transfer?.cancel(); session?.invalidateAndCancel() }
    }
    private final class Source: CapabilityReflectorSource {
        let id = "private.credential-echo"
        let reflector: OpenAPIReflector
        init(_ reflector: OpenAPIReflector) { self.reflector = reflector }
        func reflectors() -> [any CapabilityReflector] { [reflector] }
    }
    override func setUpWithError() throws {
        directory = NativeHTTPFixture.temporaryDirectory.appendingPathComponent("rcir-credential-echo-" + UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(directory)
        token = "private-disposable-" + UUID().uuidString; scheme = "fixture-" + UUID().uuidString
        try NativeHTTPFixture.writePrivate(Data(token.utf8), to: directory.appendingPathComponent("credential.private"))
        let tlsConfig = directory.appendingPathComponent("tls.conf")
        try NativeHTTPFixture.writePrivate(Data("[req]\nprompt=no\ndistinguished_name=subject\nx509_extensions=v3\n[subject]\nCN=127.0.0.1\n[v3]\nsubjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage=serverAuth\n".utf8), to: tlsConfig)
        _ = try BoundedCapabilityProcess.run(executable: URL(fileURLWithPath: "/usr/bin/openssl"),
            arguments: ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-config", tlsConfig.path,
                "-keyout", directory.appendingPathComponent("tls-key.private").path,
                "-out", directory.appendingPathComponent("certificate.pem").path], timeout: 10, maximumBytes: 65_536)
        try NativeHTTPFixture.protect(directory.appendingPathComponent("tls-key.private"))
        _ = try BoundedCapabilityProcess.run(executable: URL(fileURLWithPath: "/usr/bin/openssl"),
            arguments: ["x509", "-in", directory.appendingPathComponent("certificate.pem").path, "-outform", "DER",
                "-out", directory.appendingPathComponent("certificate.der").path], timeout: 5, maximumBytes: 65_536)
        Bridge.certificate = try Data(contentsOf: directory.appendingPathComponent("certificate.der"))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        provider = Process(); provider.executableURL = try NativeHTTPFixture.python()
        provider.arguments = [root.appendingPathComponent("scripts/rcir-credential-echo-provider.py").path, directory.path]
        provider.standardOutput = FileHandle.nullDevice; provider.standardError = FileHandle.nullDevice
        try provider.run()
        let port = directory.appendingPathComponent("port")
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: port.path) { Thread.sleep(forTimeInterval: 0.01) }
        base = try XCTUnwrap(URL(string: "https://127.0.0.1:" + String(contentsOf: port, encoding: .utf8)))
        secureBase = base
        Bridge.loopback = base
        try OpenAPIAuthorityStore.setBearerToken(token, origin: secureBase.absoluteString, schemeName: scheme)
        host = RCIRExecutionHost()
        key = Curve25519.Signing.PrivateKey()
        let keyFile = directory.appendingPathComponent("signer.raw")
        try NativeHTTPFixture.writePrivate(key.rawRepresentation, to: keyFile)
        host.configuration = { .init(signingKeyFile: keyFile.path) }
    }
    override func tearDownWithError() throws {
        if let secureBase { try OpenAPIAuthorityStore.deleteBearerToken(origin: secureBase.absoluteString, schemeName: scheme) }
        if provider?.isRunning == true { provider.terminate(); provider.waitUntilExit() }
        if let path = ProcessInfo.processInfo.environment["RCIR_CREDENTIAL_ECHO_EVIDENCE"] {
            let out = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let evidence = try JSONSerialization.data(withJSONObject: ["test": name, "diagnostics": diagnostics,
                "effects": try effects()], options: [.prettyPrinted, .sortedKeys])
            try evidence.write(to: out.appendingPathComponent(name + ".json"))
        }
        if let directory { try NativeHTTPFixture.remove(directory) }
        Bridge.loopback = nil
        Bridge.certificate = nil
    }
    private func effects() throws -> [[String: Any]] {
        try FixtureLineFraming.objects(at: directory.appendingPathComponent("effects.jsonl"))
    }
    private func invoke(_ mode: String) throws -> ExecutionRecord {
        let property: [String: Any] = ["type": "string"]
        func schema(_ name: String) -> [String: Any] { ["type": "object", "additionalProperties": false,
            "required": [name], "properties": [name: property]] }
        let spec: [String: Any] = ["openapi": "3.0.3", "info": ["title": "Private echo pressure", "version": "1"],
            "components": ["securitySchemes": [scheme: ["type": "http", "scheme": "bearer"]]],
            "paths": ["/records": ["post": ["operationId": "echo", "summary": "Private echo write",
                "security": [[scheme: [String]()]],
                "requestBody": ["required": true, "content": ["application/json": ["schema": schema("mode")]]],
                "responses": ["200": ["description": "Accepted", "content": ["application/json": ["schema": schema("value")]]]]]]]]
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Bridge.self]
        let reflector = try OpenAPIReflector(specificationData: JSONSerialization.data(withJSONObject: spec),
            baseURL: secureBase, session: URLSession(configuration: config))
        let engine = CapabilityEngine(reflectorSources: [Source(reflector)], experience: nil, rcirHost: host)
        let capability = try XCTUnwrap(engine.capabilities(for: "private-fixture").capabilities.first)
        return try engine.begin(id: capability.id, item: "private-fixture", confirmed: true, arguments: ["mode": mode])
    }
    func testCredentialEchoCannotReachModelRecordEventsOrSignedReceipt() throws {
        for mode in ["raw", "bearer", "base64", "base64_unpadded", "base64url", "hex", "upperhex", "json_escape"] {
            let before = try effects().count
            let record = try invoke(mode)
            let encoded = try JSONEncoder().encode(record)
            let payload = record.rcir?.signedReceipt.flatMap { Data(base64Encoded: $0.payload) } ?? Data()
            let material = try CapabilitySensitiveMaterial([Data(token.utf8)])
            let recordClean = (try? material.requireAbsent(in: .bytes(encoded))) != nil
            let receiptClean = (try? material.requireAbsent(in: .bytes(payload))) != nil
            diagnostics.append(["mode": mode, "actualRequests": try effects().count - before, "recordClean": recordClean,
                "receiptClean": receiptClean, "outcome": record.rcir?.outcome ?? "missing",
                "outputWithheld": record.output == nil,
                "recordSHA256": SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()])
            XCTAssertEqual(try effects().count - before, 1)
            XCTAssertTrue(recordClean, "Credential echo reached model-visible record for " + mode)
            XCTAssertTrue(receiptClean, "Credential echo reached signed task evidence for " + mode)
            XCTAssertTrue(record.output == nil, "Contaminated provider output must be withheld for " + mode)
            XCTAssertEqual(record.state, .unknown)
            XCTAssertEqual(record.rcir?.outcome, "unknown")
            XCTAssertNotNil(record.rcir?.signedReceipt)
            if recordClean && receiptClean, let path = ProcessInfo.processInfo.environment["RCIR_CREDENTIAL_ECHO_EVIDENCE"],
               let envelope = record.rcir?.signedReceipt {
                let out = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                let receipt = try RCIRSignedReceipt(payload: Data(base64Encoded: envelope.payload)!,
                    signature: Data(base64Encoded: envelope.signature)!, publicKey: Data(base64Encoded: envelope.publicKey)!)
                try receipt.verify(trustedPublicKey: key.publicKey.rawRepresentation, using: RCIREd25519Verifier())
                try receipt.wireData().write(to: out.appendingPathComponent("clean-" + mode + "-receipt.json"))
                try key.publicKey.rawRepresentation.write(to: out.appendingPathComponent("trusted-public-key.raw"))
            }
        }
    }
    func testBenignCredentialBackedResultStillAcceptedWithSignedEvidence() throws {
        let record = try invoke("benign")
        XCTAssertEqual(record.state, .accepted, record.message)
        XCTAssertEqual(record.output, "{\"value\":\"disposable-result\"}")
        XCTAssertEqual(try effects().count, 1)
        let envelope = try XCTUnwrap(record.rcir?.signedReceipt)
        let receipt = try RCIRSignedReceipt(payload: Data(base64Encoded: envelope.payload)!,
            signature: Data(base64Encoded: envelope.signature)!, publicKey: Data(base64Encoded: envelope.publicKey)!)
        try receipt.verify(trustedPublicKey: key.publicKey.rawRepresentation, using: RCIREd25519Verifier())
    }
}
#endif
