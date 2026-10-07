import CryptoKit
import Foundation
import XCTest
@testable import RightClickCore

final class RCIRHTTPJSONObservationTests: XCTestCase {
    private var directory: URL!
    private var processes: [Process] = []
    private var provider: URL!
    private var observer: URL!
    private var host: RCIRExecutionHost!
    private var reflector: OpenAPIReflector!
    private var engine: CapabilityEngine!
    private var config = RCIRHostConfiguration()
    private var capability: Capability!
    private var reader: URL!
    private var writer: URL!
    private var item = "disposable HTTP JSON pressure"
    private var legacy = false

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("http-json-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reader = directory.appendingPathComponent("observer.token"); writer = directory.appendingPathComponent("writer.token")
        for file in [reader!, writer!] {
            try Data(UUID().uuidString.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for role in ["provider", "observer", "trap"] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [root.appendingPathComponent("scripts/rcir-http-json-fixture.py").path, directory.path, role]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); processes.append(process)
            let port = directory.appendingPathComponent(role + "-port")
            for _ in 0..<300 { if FileManager.default.fileExists(atPath: port.path) { break }; Thread.sleep(forTimeInterval: 0.01) }
            let address = URL(string: "http://127.0.0.1:" + (try String(contentsOf: port, encoding: .utf8)))!
            if role == "provider" { provider = address }; if role == "observer" { observer = address }
        }
        let schema: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["id", "value"],
            "properties": ["id": ["type": "string"], "value": ["type": "string"]]]
        let content: [String: Any] = ["application/json": ["schema": schema]]
        let spec: [String: Any] = ["openapi": "3.0.3", "info": ["title": "Actual HTTP JSON fixture", "version": "1"],
            "paths": ["/records": ["post": ["operationId": "write", "requestBody": ["required": true, "content": content],
                "responses": ["200": ["description": "Stored", "content": content]]]]]]
        reflector = try OpenAPIReflector(specificationData: JSONSerialization.data(withJSONObject: spec), baseURL: provider)
        host = RCIRExecutionHost(); host.configuration = { self.config }
        engine = CapabilityEngine(reflectors: [reflector], experience: nil, rcirHost: host)
        capability = try XCTUnwrap(engine.capabilities(for: item).capabilities.first)
        legacy = ProcessInfo.processInfo.environment["RIGHTCLICK_HTTP_JSON_LEGACY_RED"] == "1"
        try configure()
    }
    override func tearDownWithError() throws {
        if let output = ProcessInfo.processInfo.environment["RIGHTCLICK_HTTP_JSON_EVIDENCE"] {
            let out = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let label = name.replacingOccurrences(of: "/", with: "_")
            let data = try JSONSerialization.data(withJSONObject: ["test": name, "contract": legacy ? "legacy-raw-text" : "structured-projection", "effects": rows("effects.jsonl"), "observations": rows("observations.jsonl"), "redirectTrap": rows("trap.jsonl")], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: out.appendingPathComponent(label + ".json"))
        }
        for process in processes where process.isRunning { process.terminate(); process.waitUntilExit() }
        processes.removeAll(); if let directory { try? FileManager.default.removeItem(at: directory) }
        engine = nil; host = nil
    }
    private func rows(_ filename: String) -> [[String: Any]] {
        let text = (try? String(contentsOf: directory.appendingPathComponent(filename), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }
    private func configure(reference: URL? = nil, path: String = "/observations/{id}", pin: URL? = nil) throws {
        if legacy {
            config.observers = [capability.id: .init(urlTemplate: observer.absoluteString + "/public-json/{id}", expectedArgument: "id", trustedOrigin: observer.absoluteString)]
            return
        }
        let properties = Dictionary(uniqueKeysWithValues: ["challenge", "result", "machine", "observation", "observerPrincipal", "platform", "principal"].map { ($0, ["type": "string"]) }).merging(["uid": ["type": "null"]]) { _, value in value }
        let schema: [String: Any] = ["type": "object", "properties": properties, "required": Array(properties.keys), "additionalProperties": false]
        let json = RCIRJSONObservationConfiguration(schemaJSON: String(decoding: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), as: UTF8.self),
            fields: ["challenge": .init(path: ["challenge"], argument: "id"), "result": .init(path: ["result"], expectedOutput: true)])
        config.observers = [capability.id: .init(urlTemplate: observer.absoluteString + path, trustedOrigin: (pin ?? observer).absoluteString,
            credentialFile: (reference ?? reader).path, jsonObservation: json)]
    }
    private func invoke(_ id: String = UUID().uuidString, value: String = "actual independent file") throws -> ExecutionRecord {
        let digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return try engine.begin(id: capability.id, item: item, confirmed: true, arguments: ["id": id, "value": value], expectedOutput: legacy ? nil : digest)
    }

    func testPrintableJSONSegmentEncodesOnceWithoutTraversalOrAuthorityChange() throws {
        let value = "{\"challenge\":\"fresh-nonce\",\"value\":\"printable text\"}"
        let resolved = try RCIRObserverPath.interpolate(observer.absoluteString + "/observations/{message}", arguments: ["message": value])
        let parts = try XCTUnwrap(URLComponents(string: resolved))
        XCTAssertEqual(parts.path, "/observations/" + value)
        XCTAssertNil(parts.query); XCTAssertNil(parts.fragment); XCTAssertNil(parts.user); XCTAssertNil(parts.password)
        XCTAssertEqual(parts.host, observer.host)
        for denied in [".", "..", "../outside", "a/b", "a\\b", "%2e%2e", "a%252fb", "a\nb", "a\0b"] {
            XCTAssertThrowsError(try RCIRObserverPath.interpolate(observer.absoluteString + "/observations/{message}", arguments: ["message": denied]))
        }
    }
    func testRealJSONObservationRetainsFullMetadataAndMatchesIndependentDigest() throws {
        let result = try invoke()
        XCTAssertEqual(result.state, .succeeded, result.message)
        XCTAssertEqual(result.rcir?.outcome, "succeeded"); XCTAssertTrue(result.evidence.outcomeVerified)
        let receipt = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(result.rcir?.receipt)))
        XCTAssertNotNil(receipt.range(of: Data("fixture-readonly".utf8)))
        XCTAssertNotNil(receipt.range(of: Data("independent-file-sha256".utf8)))
        XCTAssertEqual(rows("effects.jsonl").count, 1); XCTAssertEqual(rows("observations.jsonl").count, 1)
    }
    func testWriterCredentialCannotActAsReadonlyObserver() throws {
        try configure(reference: writer)
        let result = try invoke()
        XCTAssertEqual(result.state, .accepted, result.message); XCTAssertEqual(result.rcir?.outcome, "unverified", result.message)
        XCTAssertEqual(rows("observations.jsonl").first?["credentialRole"] as? String, "none-or-wrong")
    }
    func testRedirectNeverSendsObserverCredentialToAnotherOrigin() throws {
        let result = try invoke("redirect")
        XCTAssertEqual(result.state, .accepted, result.message); XCTAssertEqual(result.rcir?.outcome, "unverified", result.message)
        XCTAssertEqual(rows("observations.jsonl").count, 1); XCTAssertTrue(rows("trap.jsonl").isEmpty)
    }
    func testAmbientCookiesCannotEnterObservationOrPersistResponseCookie() throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "rightclick-ambient-" + UUID().uuidString, .value: "unrelated-authority"]))
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
        let result = try invoke()
        XCTAssertEqual(result.state, .succeeded)
        XCTAssertEqual(rows("observations.jsonl").first?["cookiePresent"] as? Bool, false)
        XCTAssertFalse((HTTPCookieStorage.shared.cookies ?? []).contains { $0.name == "rightclick-injected" })
    }
    func testDefaultCredentialStorageCannotSupplyObserverAuthority() throws {
        let space = URLProtectionSpace(host: observer.host!, port: observer.port!, protocol: "http",
            realm: "rightclick-observer-fixture", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let credential = URLCredential(user: "ambient-unrelated", password: "not-authorized", persistence: .forSession)
        URLCredentialStorage.shared.setDefaultCredential(credential, for: space)
        defer { URLCredentialStorage.shared.remove(credential, for: space) }
        try configure(reference: writer)
        let result = try invoke()
        XCTAssertEqual(result.rcir?.outcome, "unverified")
        XCTAssertFalse(rows("observations.jsonl").isEmpty)
        XCTAssertTrue(rows("observations.jsonl").allSatisfy { $0["authorizationKind"] as? String == "Bearer" })
        XCTAssertFalse(rows("observations.jsonl").contains { $0["authorizationKind"] as? String == "Basic" })
    }
    func testAmbiguousProjectionOrMissingCallerDigestFailsBeforeMutation() throws {
        let original = try XCTUnwrap(config.observers?[capability.id])
        let missing = try engine.begin(id: capability.id, item: item, confirmed: true, arguments: ["id": "never-dispatched", "value": "actual"])
        XCTAssertEqual(missing.state, .rejected); XCTAssertTrue(rows("effects.jsonl").isEmpty)
        var malformed = original
        malformed.jsonObservation = .init(schemaJSON: original.jsonObservation!.schemaJSON,
            fields: ["challenge": .init(path: ["challenge"], argument: "id", expectedOutput: true)])
        config.observers = [capability.id: malformed]
        let ambiguous = try invoke(); XCTAssertEqual(ambiguous.state, .rejected); XCTAssertTrue(rows("effects.jsonl").isEmpty)
    }
    func testMismatchMissingAndUndeclaredObservationFieldsNeverSucceed() throws {
        XCTAssertEqual(try invoke(value: "mismatch").rcir?.outcome, "failed")
        XCTAssertEqual(try invoke(value: "missing").rcir?.outcome, "unverified")
        XCTAssertEqual(try invoke("extra").rcir?.outcome, "unverified")
    }
    func testPinnedOriginAndRevokedReferenceAbstainWithoutObserverRead() throws {
        try configure(pin: provider)
        let denied = try invoke(); XCTAssertEqual(denied.state, .rejected); XCTAssertTrue(rows("effects.jsonl").isEmpty)
        try configure()
        host.beforeConsume = { _ in try FileManager.default.removeItem(at: self.reader) }
        let unverified = try invoke(); XCTAssertEqual(unverified.rcir?.outcome, "unverified")
        XCTAssertTrue(rows("observations.jsonl").isEmpty)
    }
}
