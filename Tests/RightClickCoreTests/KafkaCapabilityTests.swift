#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import RightClickCore

final class KafkaCapabilityTests: XCTestCase {
    private func environment() throws -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RIGHTCLICK_KAFKA_CLIENT"] != nil,
              environment["RIGHTCLICK_KAFKA_PUBLISHER_CONFIG"] != nil,
              environment["RIGHTCLICK_KAFKA_OBSERVER_CONFIG"] != nil else {
            throw XCTSkip("Genuine scoped Kafka broker not provisioned; no Kafka GREEN claimed.")
        }
        return environment
    }
    func testRealScopedKafkaHasUnverifiedACKThenIndependentArgumentBoundConsumerReceipt() throws {
        let env = try environment()
        let descriptor = CapabilityArtifactDescriptor(id: "controlled", kind: "kafka", endpointURL: "kafka://127.0.0.1:19092")
        let item = try ContentParser.parse("controlled Kafka record")
        var publisherOnly = env; publisherOnly.removeValue(forKey: "RIGHTCLICK_KAFKA_OBSERVER_CONFIG")
        let unobserved = try KafkaCapabilityArtifactResolver(environment: publisherOnly).resolve(descriptor)
        let ackCapability = try XCTUnwrap(try unobserved.capabilities(for: item).first { $0.id.hasSuffix(":publish.rightclick.proof") })
        let nonce = "unverified-" + UUID().uuidString
        let ack = try (unobserved as! RCIRExecutionReflector).admittedBegin(capability: ackCapability,
            admissionOwner: ackCapability, item: item, executionID: nonce, arguments: ["key": nonce, "payload": nonce],
            verification: nil, expectedOutput: nil, host: RCIRExecutionHost(), revalidate: { true })
        XCTAssertEqual(ack.state, .accepted); XCTAssertFalse(ack.evidence.outcomeVerified); XCTAssertEqual(ack.rcir?.outcome, "unverified")
        let observed = try KafkaCapabilityArtifactResolver(environment: env).resolve(descriptor)
        let capability = try XCTUnwrap(try observed.capabilities(for: item).first { $0.id.hasSuffix(":publish.rightclick.proof") })
        XCTAssertNotEqual(capability.metadata["providerPrincipal"], capability.metadata["observerPrincipal"])
        let key = Curve25519.Signing.PrivateKey()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyFile = directory.appendingPathComponent("signer.raw")
        try key.rawRepresentation.write(to: keyFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        let host = RCIRExecutionHost(); host.configuration = { RCIRHostConfiguration(signingKeyFile: keyFile.path) }
        let challenge = "verified-" + UUID().uuidString
        let payload = "UTF-8 exact payload\nsecond line\n" + challenge
        let result = try (observed as! RCIRExecutionReflector).admittedBegin(capability: capability,
            admissionOwner: capability, item: item, executionID: challenge, arguments: ["key": challenge, "payload": payload],
            verification: nil, expectedOutput: nil, host: host, revalidate: { true })
        XCTAssertEqual(result.state, .succeeded); XCTAssertTrue(result.evidence.outcomeVerified)
        XCTAssertEqual(result.rcir?.outcome, "succeeded")
        let envelope = try XCTUnwrap(result.rcir?.signedReceipt)
        let receipt = try RCIRSignedReceipt(payload: XCTUnwrap(Data(base64Encoded: envelope.payload)),
            signature: XCTUnwrap(Data(base64Encoded: envelope.signature)), publicKey: XCTUnwrap(Data(base64Encoded: envelope.publicKey)))
        try receipt.verify(trustedPublicKey: key.publicKey.rawRepresentation, using: RCIREd25519Verifier())
        if let path = env["RIGHTCLICK_KAFKA_TEST_EVIDENCE"] {
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try JSONEncoder().encode(result).write(to: output.appendingPathComponent("verified-record.json"))
            try JSONEncoder().encode(envelope).write(to: output.appendingPathComponent("verified-receipt.json"))
            try key.publicKey.rawRepresentation.write(to: output.appendingPathComponent("trusted-public-key.raw"))
        }
    }
    func testObserverCannotReuseWriterPrincipalAndCredentials() throws {
        var env = try environment()
        env["RIGHTCLICK_KAFKA_OBSERVER_CONFIG"] = env["RIGHTCLICK_KAFKA_PUBLISHER_CONFIG"]
        XCTAssertThrowsError(try KafkaCapabilityArtifactResolver(environment: env)
            .resolve(.init(id: "same-principal", kind: "kafka", endpointURL: "kafka://127.0.0.1:19092")))
    }
}
