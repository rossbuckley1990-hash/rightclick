import CryptoKit
import Foundation
import XCTest
@testable import RightClickCore

final class RCIRInvocationBindingTests: XCTestCase {
    private let observerID = "host:independent-resource-observer"
    private let oldMarker = "11111111-1111-4111-8111-111111111111"

    private func task(path: [String] = ["invocationID"]) throws -> RCIRTask {
        let check = RCIRVerificationContract(observerID: observerID,
            schema: .object(properties: ["value": .string], required: ["value"]), expected: .object(["value": .string("same-value")]),
            projection: .init(schema: .object(properties: ["value": .string, "invocationID": .string, "uid": .string],
                required: ["value", "invocationID", "uid"]), fields: ["value": ["value"]]), invocationBindingPath: path)
        let abi = CapabilityContract(capabilityID: "controlled-resource", reflectorID: "controlled-reflector", providerID: "controlled-provider",
            arguments: .string, result: .string, declaration: .string("controlled-interface"))
        let scope = RCIRScope("namespace/disposable", .write)
        let admission = RCIRAdmission()
        let binding = try admission.publish(.init(abi: abi, scopes: [scope], verification: check), authenticatedPrincipal: "controlled-writer")
        let policy = RCIRPolicy(revision: "controlled-policy", principals: ["controlled-writer"], scopes: [scope])
        let lease = try admission.issue(binding, arguments: .string("same-value"), authority: [scope], policy: policy, now: 1_000)
        try admission.consume(lease, arguments: .string("same-value"), authority: [scope], policy: policy, now: 1_000)
        var task = try RCIRTask(lease: lease, startedAt: 1_000, deadline: 31_000)
        // A provider's claimed marker must never choose the verifier's expected marker.
        try task.record(.completed(.string(oldMarker)), sequence: 1, now: 1_001)
        return task
    }

    private func observation(marker: String) -> CapabilityValue {
        .object(["value": .string("same-value"), "invocationID": .string(marker), "uid": .string("independent-assigned-uid")])
    }

    func testMatchingOldMarkerIsRetainedInSignedFailureInsteadOfVerifyingCurrentInvocation() throws {
        var task = try task()
        try task.verify(observerID: observerID, now: 1_002) { _, _ in observation(marker: oldMarker) }
        XCTAssertEqual(task.outcome, .failed)
        let payload = try task.receiptData()
        XCTAssertNotNil(payload.range(of: try observation(marker: oldMarker).canonicalData()))
        let key = Curve25519.Signing.PrivateKey()
        let signer = try RCIREd25519Signer(rawPrivateKey: key.rawRepresentation)
        let receipt = try RCIRSignedReceipt.sign(task, using: signer)
        try receipt.verify(trustedPublicKey: key.publicKey.rawRepresentation, using: RCIREd25519Verifier())
    }

    func testOnlyHostTaskIdentityCanVerifyMatchingObservation() throws {
        var task = try task()
        let marker = try RCIRInvocationBinding(taskID: task.id.uuidString).id
        try task.verify(observerID: observerID, now: 1_002) { _, _ in observation(marker: marker) }
        XCTAssertEqual(task.outcome, .succeeded)
        XCTAssertNotNil(try task.receiptData().range(of: try observation(marker: marker).canonicalData()))
    }

    func testInvocationBindingRejectsNoncanonicalIdentityAndUnboundedOrWildcardPaths() throws {
        for marker in ["provider-claimed", UUID().uuidString.lowercased(), oldMarker + "\n"] {
            XCTAssertThrowsError(try RCIRInvocationBinding(taskID: marker))
        }
        for path in [[], ["*"], [""], ["marker\n"], Array(repeating: "marker", count: 33)] {
            XCTAssertThrowsError(try task(path: path))
        }
    }
}
