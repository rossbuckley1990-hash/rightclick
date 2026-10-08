import Foundation
import XCTest
@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class RCIRProvisionedReceiptTrustTests: XCTestCase {
    private var directory: URL!
    private var file: URL!
    private var reference: String?
    private var now: Int64 = 104
    private let key = Data(repeating: 7, count: 32)
    private var objects: [[String: Any]] = []

    override func setUpWithError() throws {
        directory = NativeHTTPFixture.temporaryDirectory.appendingPathComponent("rcir-policy-loader-" + UUID().uuidString)
#if os(Windows)
        try NativeHTTPFixture.createPrivateDirectory(directory)
#else
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
#endif
        file = directory.appendingPathComponent("receipt-policy.json"); reference = file.path
        objects = [record()]
        try write(document())
    }
    override func tearDownWithError() throws { if let directory { try NativeHTTPFixture.remove(directory) } }
    private func record(keyID: String = "key:0", bytes: Data? = nil, before: Int64 = 100, after: Int64 = 1000,
                        retired: Int64? = nil, revoked: Bool = false) -> [String: Any] {
        ["keyID": keyID, "publicKey": (bytes ?? key).base64EncodedString(), "notBefore": before,
         "notAfter": after, "retiredAt": retired.map { $0 as Any } ?? NSNull(), "revoked": revoked]
    }
    private func document(issuer: String = "issuer:fixture", age: Int64 = 60_000) -> [String: Any] {
        ["version": 1, "issuerID": issuer, "maximumLiveAge": age, "keys": objects]
    }
    private func write(_ object: [String: Any]) throws { try write(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) }
    private func write(_ data: Data) throws {
        if FileManager.default.fileExists(atPath: file.path) {
            try NativeHTTPFixture.release(file); try FileManager.default.removeItem(at: file)
        }
#if os(Windows)
        try NativeHTTPFixture.writePrivate(data, to: file)
#else
        try data.write(to: file, options: .withoutOverwriting); try NativeHTTPFixture.protect(file)
#endif
    }
    private func loader() throws -> RCIRProvisionedReceiptTrust {
        try .init(path: file.path, currentReference: { [weak self] in self?.reference }, clock: { [weak self] in self?.now ?? 0 })
    }
    private func invalid(_ bytes: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try RCIRReceiptTrustDocument.read(bytes), file: file, line: line) {
            XCTAssertEqual($0 as? RCIRReceiptTrustError, .invalidPolicy, file: file, line: line)
        }
    }
    func testLegalProtectedPolicyMintsInspectableUnforgeableKeyRevision() throws {
        let actual = try loader(), token = try actual.authorization(for: key)
        XCTAssertEqual(token.issuerID, "issuer:fixture"); XCTAssertEqual(token.keyID, "key:0")
        XCTAssertEqual(token.publicKey, key); XCTAssertEqual(token.keyRevision, 1)
        XCTAssertNoThrow(try actual.revalidate(token))
        XCTAssertThrowsError(try actual.authorization(for: Data(repeating: 8, count: 32)))
    }
    func testRawDuplicatesAndEscapedAliasesCannotDisappearDuringParsing() throws {
        let json = String(data: try JSONSerialization.data(withJSONObject: document(), options: [.sortedKeys]), encoding: .utf8)!
        for pair in [
            ("\"version\":1", "\"version\":1,\"version\":1"),
            ("\"version\":1", "\"version\":1,\"vers\\u0069on\":1"),
            ("\"revoked\":false", "\"revoked\":false,\"revoked\":true"),
            ("\"revoked\":false", "\"revoked\":false,\"revo\\u006bed\":true"),
            ("\"keyID\":\"key:0\"", "\"keyID\":\"key:0\",\"key\\u0049D\":\"key:0\""),
        ] {
            let bad = json.replacingOccurrences(of: pair.0, with: pair.1)
            XCTAssertNotEqual(bad, json); invalid(Data(bad.utf8))
        }
    }
    func testClosedSchemaMissingFieldsAndUnsupportedVersionDeny() throws {
        for field in ["version", "issuerID", "maximumLiveAge", "keys"] {
            var bad = document(); bad.removeValue(forKey: field)
            invalid(try JSONSerialization.data(withJSONObject: bad))
        }
        var bad = document(); bad["version"] = 2; invalid(try JSONSerialization.data(withJSONObject: bad))
        bad = document(); bad["providerTrust"] = true; invalid(try JSONSerialization.data(withJSONObject: bad))
        for field in ["keyID", "publicKey", "notBefore", "notAfter", "retiredAt", "revoked"] {
            var entry = record(); entry.removeValue(forKey: field)
            bad = document(); bad["keys"] = [entry]; invalid(try JSONSerialization.data(withJSONObject: bad))
        }
        var entry = record(); entry["embeddedTrust"] = true
        bad = document(); bad["keys"] = [entry]; invalid(try JSONSerialization.data(withJSONObject: bad))
    }
    func testIntegerBooleanAndNullKindsRemainDistinct() throws {
        for (field, value) in [("version", true as Any), ("maximumLiveAge", false), ("maximumLiveAge", 1.5), ("version", "1")] {
            var bad = document(); bad[field] = value; invalid(try JSONSerialization.data(withJSONObject: bad))
        }
        for (field, value) in [("notBefore", true as Any), ("notAfter", 1000.5), ("retiredAt", false), ("revoked", 1)] {
            var entry = record(); entry[field] = value
            var bad = document(); bad["keys"] = [entry]; invalid(try JSONSerialization.data(withJSONObject: bad))
        }
        let json = String(data: try JSONSerialization.data(withJSONObject: document()), encoding: .utf8)!
        for number in ["01", "-1", "+1", "1e0", "9223372036854775808"] {
            let bad = json.replacingOccurrences(of: "\"version\":1", with: "\"version\":" + number)
            XCTAssertNotEqual(bad, json); invalid(Data(bad.utf8))
        }
    }
    func testCanonicalPublicLocatorAndDuplicateRecordBounds() throws {
        for encoded in ["", key.base64EncodedString() + "\n", Data(repeating: 7, count: 31).base64EncodedString(),
                        key.base64EncodedString().replacingOccurrences(of: "=", with: ""), String(repeating: "*", count: 44)] {
            var entry = record(); entry["publicKey"] = encoded
            var bad = document(); bad["keys"] = [entry]; invalid(try JSONSerialization.data(withJSONObject: bad))
        }
        for records in [[record(), record()], [record(), record(keyID: "key:1")],
                        [record(), record(bytes: Data(repeating: 8, count: 32))], [], Array(repeating: record(), count: 65)] {
            var bad = document(); bad["keys"] = records; invalid(try JSONSerialization.data(withJSONObject: bad))
        }
    }
    func testIdentityIntervalsFreshnessAndRawSyntaxBounds() throws {
        for issuer in ["", "*", String(repeating: "i", count: 513), "synthetic\nissuer"] {
            invalid(try JSONSerialization.data(withJSONObject: document(issuer: issuer)))
        }
        for age in [Int64(0), 86_400_001] { invalid(try JSONSerialization.data(withJSONObject: document(age: age))) }
        for entry in [record(keyID: "*"), record(before: 1000), record(retired: 99), record(retired: 1001)] {
            var bad = document(); bad["keys"] = [entry]; invalid(try JSONSerialization.data(withJSONObject: bad))
        }
        let legal = try JSONSerialization.data(withJSONObject: document())
        for bytes in [Data(), Data([0xff]), legal + Data("null".utf8), Data(repeating: 32, count: 131_073),
                      Data(String(repeating: "[", count: 8).utf8), Data("{\"version\":\"\\q\"}".utf8)] { invalid(bytes) }
    }
    func testDeletedWeakenedAndMalformedSourceDenyWithStaticErrors() throws {
        let actual = try loader(), token = try actual.authorization(for: key)
        try NativeHTTPFixture.release(file); try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try actual.revalidate(token)) { XCTAssertEqual($0 as? RCIRError, .authorityDenied) }
        try write(Data("synthetic-sensitive-policy-error".utf8))
        XCTAssertThrowsError(try actual.revalidate(token)) {
            XCTAssertEqual($0 as? RCIRReceiptTrustError, .invalidPolicy)
            XCTAssertFalse(String(describing: $0).contains("synthetic-sensitive"))
        }
        try write(document())
#if os(Windows)
        let command = Process(); command.executableURL = URL(fileURLWithPath: (ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows") + "\\System32\\icacls.exe")
        command.arguments = [file.path, "/grant", "*S-1-1-0:(R)"]; try command.run(); command.waitUntilExit()
        XCTAssertEqual(command.terminationStatus, 0)
        defer { try? NativeHTTPFixture.protect(file) }
#else
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
#endif
        XCTAssertThrowsError(try actual.revalidate(token)) { XCTAssertEqual($0 as? RCIRError, .authorityDenied) }
    }
    func testSourceWithdrawalThenLegalRestorationRecoversWithoutLosingHistory() throws {
        let actual = try loader(), token = try actual.authorization(for: key)
        reference = nil
        XCTAssertThrowsError(try actual.revalidate(token)) { XCTAssertEqual($0 as? RCIRError, .authorityDenied) }
        reference = file.path; XCTAssertNoThrow(try actual.revalidate(token))
        objects[0]["revoked"] = true; try write(document())
        XCTAssertThrowsError(try actual.revalidate(token)) { XCTAssertEqual($0 as? RCIRReceiptTrustError, .keyRevoked) }
        reference = nil; XCTAssertThrowsError(try actual.authorization(for: key))
        reference = file.path
        XCTAssertThrowsError(try actual.authorization(for: key)) { XCTAssertEqual($0 as? RCIRReceiptTrustError, .keyRevoked) }
        objects[0]["revoked"] = false; try write(document())
        XCTAssertThrowsError(try actual.authorization(for: key)) { XCTAssertEqual($0 as? RCIRReceiptTrustError, .invalidPolicy) }
        objects[0]["revoked"] = true; try write(document())
        XCTAssertThrowsError(try actual.authorization(for: key)) { XCTAssertEqual($0 as? RCIRReceiptTrustError, .keyRevoked) }
    }
    func testProtectedFileRollbackCannotResurrectRevocation() throws {
        let actual = try loader(), token = try actual.authorization(for: key)
        let before = try Data(contentsOf: file)
        objects[0]["revoked"] = true; try write(document())
        XCTAssertThrowsError(try actual.revalidate(token)) { XCTAssertEqual($0 as? RCIRReceiptTrustError, .keyRevoked) }
        try write(before)
        XCTAssertThrowsError(try actual.authorization(for: key)) { XCTAssertEqual($0 as? RCIRReceiptTrustError, .invalidPolicy) }
        objects[0]["revoked"] = true; try write(document())
        XCTAssertThrowsError(try actual.revalidate(token)) { XCTAssertEqual($0 as? RCIRReceiptTrustError, .keyRevoked) }
    }
    func testUnrelatedAdditionPreservesTokenButRetirementChangesKeyRevision() throws {
        let actual = try loader(), token = try actual.authorization(for: key)
        objects.append(record(keyID: "key:1", bytes: Data(repeating: 8, count: 32)))
        try write(document()); XCTAssertNoThrow(try actual.revalidate(token))
        XCTAssertNoThrow(try actual.authorization(for: Data(repeating: 8, count: 32)))
        objects[0]["retiredAt"] = 500; try write(document())
        XCTAssertThrowsError(try actual.revalidate(token)) { XCTAssertEqual($0 as? RCIRReceiptTrustError, .changedPolicy) }
        XCTAssertEqual(try actual.authorization(for: key).keyRevision, 2)
        now = 500; XCTAssertThrowsError(try actual.authorization(for: key)) { XCTAssertEqual($0 as? RCIRReceiptTrustError, .keyNotActive) }
        now = 104; XCTAssertThrowsError(try actual.authorization(for: key)) { XCTAssertEqual($0 as? RCIRReceiptTrustError, .keyNotActive) }
    }
    func testPolicyIdentityPreventsCrossLoaderTokenReuse() throws {
        let first = try loader(), second = try loader(), token = try first.authorization(for: key)
        XCTAssertThrowsError(try second.revalidate(token)) { XCTAssertEqual($0 as? RCIRReceiptTrustError, .changedPolicy) }
    }
    func testRealSigningCallbackRevocationWithholdsUsableAuthorization() throws {
        let signer = try RCIREd25519Signer(rawPrivateKey: Curve25519.Signing.PrivateKey().rawRepresentation)
        objects = [record(bytes: signer.publicKey)]; try write(document())
        let actual = try loader(), token = try actual.authorization(for: signer.publicKey)
        var callbackRan = false
        func callback() throws -> Data {
            let signature = try signer.sign(Data("actual synthetic callback payload".utf8))
            callbackRan = true; objects[0]["revoked"] = true; try write(document())
            return signature
        }
        try actual.revalidate(token); let signature = try callback()
        XCTAssertTrue(callbackRan); XCTAssertEqual(signature.count, 64)
        XCTAssertThrowsError(try actual.revalidate(token)) { XCTAssertEqual($0 as? RCIRReceiptTrustError, .keyRevoked) }
    }
    func testRejectedMultiKeyUpdateIsTransactionalAndDoesNotChangeEarlierKey() throws {
        let actual = try loader(), token = try actual.authorization(for: key)
        let initial = document()
        objects[0]["revoked"] = true
        objects.append(record(keyID: "key:1", bytes: Data(repeating: 8, count: 32), after: 2000))
        // Duplicate original key ID invalidates the entire batch after its first
        // candidate revocation; the first candidate must not be committed.
        objects.append(record(keyID: "key:0", bytes: Data(repeating: 9, count: 32)))
        try write(document()); XCTAssertThrowsError(try actual.revalidate(token))
        try write(initial); XCTAssertNoThrow(try actual.revalidate(token))
        XCTAssertThrowsError(try actual.authorization(for: Data(repeating: 8, count: 32)))
    }
}
