import Foundation
import XCTest
@testable import RightClickProtocol
@testable import RightClickProviders
@testable import RightClickLink

/// Receipt issuer trust remains separately provisioned from transport identity.
/// v1 receipt claims do not independently attest a runtime or contract fingerprint.
final class ReceiptRuntimeIsolationReconciliationTests: XCTestCase {
    func testValidReceiptFromAnotherRuntimeCannotUseThisRuntimePinnedReceiptKey() throws {
        let nodeA = try RemoteNodeIdentity(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 81, count: 32)))
        let nodeB = try RemoteNodeIdentity(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 82, count: 32)))
        let receiptSignerA = try RCIREd25519Signer(rawPrivateKey: Data(repeating: 83, count: 32))
        let receiptSignerB = try RCIREd25519Signer(rawPrivateKey: Data(repeating: 84, count: 32))
        XCTAssertNotEqual(nodeA.runtimeID, nodeB.runtimeID)
        XCTAssertNotEqual(receiptSignerA.publicKey, receiptSignerB.publicKey)

        let abi = CapabilityContract(capabilityID: "fixture:receipt", reflectorID: "reflector:fixture",
            providerID: "fixture", arguments: .integer, result: .integer,
            declaration: .string("Separate runtime trust control"))
        let contract = RCIRContract(abi: abi, scopes: [], verification: .init(observerID: "observer:fixture", schema: .integer, expected: .integer(7)))
        let admission = RCIRAdmission()
        let binding = try admission.publish(contract, authenticatedPrincipal: "principal:fixture")
        let policy = RCIRPolicy(revision: "1", principals: ["principal:fixture"], scopes: [])
        let lease = try admission.issue(binding, arguments: .integer(1), authority: [], policy: policy, now: 100)
        try admission.consume(lease, arguments: .integer(1), authority: [], policy: policy, now: 101)
        var task = try RCIRTask(lease: lease, startedAt: 101, deadline: 1000)
        try task.record(.completed(.integer(7)), sequence: 1, now: 102)
        try task.verify(observerID: "observer:fixture", now: 103) { _, _ in .integer(7) }
        let receiptA = try RCIRSignedReceipt.sign(task, using: receiptSignerA)
        try receiptA.verify(trustedPublicKey: receiptSignerA.publicKey, using: RCIREd25519Verifier())

        let issuerA = "receipt-issuer:" + nodeA.runtimeID
        let issuerB = "receipt-issuer:" + nodeB.runtimeID
        let trustA = try RCIRReceiptTrustPolicy(issuerID: issuerA, records: [.init(keyID: "key:a",
            publicKey: receiptSignerA.publicKey, notBefore: 100, notAfter: 1000)], clock: { 104 })
        let trustB = try RCIRReceiptTrustPolicy(issuerID: issuerB, records: [.init(keyID: "key:b",
            publicKey: receiptSignerB.publicKey, notBefore: 100, notAfter: 1000)], clock: { 104 })
        let expectedA = try RCIRReceiptTrustRequest(issuerID: issuerA, taskID: task.id, leaseID: lease.id, outcome: .succeeded, mode: .live)
        XCTAssertNoThrow(try trustA.verify(receiptA, expecting: expectedA, using: RCIREd25519Verifier()))
        let expectedB = try RCIRReceiptTrustRequest(issuerID: issuerB, taskID: task.id, leaseID: lease.id, outcome: .succeeded, mode: .live)
        XCTAssertThrowsError(try trustB.verify(receiptA, expecting: expectedB, using: RCIREd25519Verifier())) {
            XCTAssertEqual($0 as? RCIRReceiptTrustError, .untrustedKey)
        }
        // Even a valid transport node signature cannot establish a receipt key.
        let outerSignature = try nodeB.sign(Data("authenticated transport assertion".utf8))
        XCTAssertEqual(outerSignature.count, 64)
        XCTAssertThrowsError(try trustB.verify(receiptA, expecting: expectedB, using: RCIREd25519Verifier()))
    }
}
