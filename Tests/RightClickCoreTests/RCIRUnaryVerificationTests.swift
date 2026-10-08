import Foundation
import XCTest
@testable import RightClickProtocol
@testable import RightClickProviders
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class RCIRUnaryVerificationTests: XCTestCase {
    private func verifyFile(predicate: VerificationPredicateType, mutate: Bool, observerBase: String? = nil) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rcir-unary-before-" + UUID().uuidString)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("observed.txt"), keyFile = directory.appendingPathComponent("receipt.key")
        try Data("original bytes".utf8).write(to: file)
        let privateKey = Curve25519.Signing.PrivateKey()
        try privateKey.rawRepresentation.write(to: keyFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        let host = RCIRExecutionHost(); host.now = { 100 }
        var configuration = RCIRHostConfiguration(); configuration.signingKeyFile = keyFile.path
        let id = UUID().uuidString
        let abi = CapabilityContract(capabilityID: "fixture:unary-before", reflectorID: "reflector:unary-before",
            providerID: "provider:unary-before", arguments: .string, result: .string,
            declaration: .string("Admission-bound unary file postcondition"))
        let capability = Capability(id: abi.capabilityID, title: "Unary file verification", source: .system,
            reflectorID: abi.reflectorID, safety: .localWrite, invocation: .direct,
            supportLevel: .experimental, requiresConfirmation: false)
        if let observerBase {
            configuration.observers = [capability.id: .init(urlTemplate: observerBase + "/observe/{expected}", expectedArgument: "expected")]
        }
        host.configuration = { configuration }
        let scope = RCIRScope("urn:fixture:unary-before", .execute)
        var starts = 0
        let record = try host.execute(abi: abi, discovery: abi, arguments: .string("one invocation"),
            scope: scope, capability: capability, executionID: id,
            argumentStrings: observerBase == nil ? nil : ["expected": "wanted"],
            item: ContentParser.parse(file.path), verification: .init(predicates: [.init(type: predicate, reference: "before")]),
            expectedOutput: nil, target: XCTUnwrap(URL(string: observerBase.map { $0 + "/invoke" } ?? "https://example.invalid/unary-before")),
            authority: { [scope] }, revalidate: { true }, currentContract: { true }, dispatch: { _, admitStart in
                var writeFailure: Error?
                try admitStart {
                    starts += 1
                    if mutate {
                        do { try Data("provider changed bytes".utf8).write(to: file) }
                        catch { writeFailure = error }
                    }
                }
                if let writeFailure { throw writeFailure }
                return .init(executionId: id, actionId: capability.id, state: .accepted,
                    message: "The provider completed its one admitted invocation.", output: "provider response")
            }, resultValue: { _ in .string("provider response") })
        let matched = predicate == .fileSHA256Equals ? !mutate : mutate
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(record.state, matched ? .succeeded : .failed)
        XCTAssertEqual(record.lifecycle?.verification, matched ? .verifiedSuccess : .verifiedFailure)
        XCTAssertEqual(record.verification?.status, matched ? .verifiedSuccess : .verifiedFailure)
        XCTAssertEqual(record.lifecycle?.providerAcceptance, .accepted,
            "Provider acceptance remains accepted even when the required semantic postcondition fails")
        XCTAssertEqual(record.lifecycle?.observationBoundary, .externalState)
        XCTAssertEqual(record.evidence.observationBoundary, .externalState)
        XCTAssertEqual(record.evidence.outcomeVerified, matched)
        XCTAssertEqual(record.rcir?.outcome, matched ? "succeeded" : "failed")
        XCTAssertEqual(record.lifecycle?.terminal, true)
        XCTAssertNotNil(record.rcir?.receipt)
        let envelope = try XCTUnwrap(record.rcir?.signedReceipt)
        let payload = try XCTUnwrap(Data(base64Encoded: envelope.payload))
        let signature = try XCTUnwrap(Data(base64Encoded: envelope.signature))
        XCTAssertEqual(Data(base64Encoded: envelope.publicKey), privateKey.publicKey.rawRepresentation)
        XCTAssertTrue(privateKey.publicKey.isValidSignature(signature, for: payload),
            "The final semantic evidence must retain its admitted receipt signer")
        XCTAssertEqual(payload, Data(base64Encoded: try XCTUnwrap(record.rcir).receipt))
        let headerCount = Data("RIGHTCLICK-VALUE-1\0".utf8).count
        var semanticField = Data(try CapabilityValue.string("semanticOutcome").canonicalData().dropFirst(headerCount))
        semanticField.append(try CapabilityValue.string(matched ? "succeeded" : "failed").canonicalData().dropFirst(headerCount))
        XCTAssertNotNil(payload.range(of: semanticField),
            "The signed receipt must attest the same independently adjudicated semantic outcome")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), mutate ? "provider changed bytes" : "original bytes")
    }

    func testPreservationPredicateDetectsProviderMutationInsteadOfSigningFalseSuccess() throws {
        try verifyFile(predicate: .fileSHA256Equals, mutate: true)
    }

    func testPreservationPredicateVerifiesUnchangedAdmissionTimeBytes() throws {
        try verifyFile(predicate: .fileSHA256Equals, mutate: false)
    }

    func testChangePredicateVerifiesMutationAgainstAdmissionTimeBytes() throws {
        try verifyFile(predicate: .fileSHA256Differs, mutate: true)
    }

    func testChangePredicateDetectsUnchangedAdmissionTimeBytes() throws {
        try verifyFile(predicate: .fileSHA256Differs, mutate: false)
    }

    func testMatchingHostReadbackCannotHideUnaryFileMutationFromItsAdmittedBaseline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rcir-unary-readback-before-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("scripts/rcir-observer-gate-test-provider.py").path, "--state-dir", directory.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
        }
        let portURL = directory.appendingPathComponent("port"), deadline = Date().addingTimeInterval(3)
        var port: UInt16?
        repeat {
            port = (try? String(contentsOf: portURL, encoding: .utf8)).flatMap(UInt16.init)
            if port == nil || port == 0 { Thread.sleep(forTimeInterval: 0.01) }
        } while (port == nil || port == 0) && Date() < deadline
        let validPort = try XCTUnwrap(port, "The disposable independent observer must publish a valid port")
        XCTAssertGreaterThan(validPort, 0)
        try Data().write(to: directory.appendingPathComponent("release"))
        let base = "http://127.0.0.1:" + String(validPort)
        // A matching external readback does not satisfy a contradictory required
        // preservation predicate. A change predicate must use the same baseline.
        try verifyFile(predicate: .fileSHA256Equals, mutate: true, observerBase: base)
        try verifyFile(predicate: .fileSHA256Differs, mutate: true, observerBase: base)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("observer-finished").path))
    }
}
