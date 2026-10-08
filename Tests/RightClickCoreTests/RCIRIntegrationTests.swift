@testable import RightClickProtocol
@testable import RightClickProviders
#if os(macOS)
@testable import RightClickMacOS
@testable import RightClickMacOSHost
#endif
import Foundation
import XCTest
@testable import RightClickCore
#if canImport(CryptoKit) || canImport(Crypto)
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#endif

final class RCIRIntegrationTests: XCTestCase {
    #if canImport(RightClickProviders)
    func testOwnerSynchronizationPreservesExactUTF8WithdrawalIdentity() throws {
        let host = RCIRExecutionHost()
        let composed = "reflector:\u{00e9}", decomposed = "reflector:e\u{0301}"
        XCTAssertEqual(composed, decomposed) // Swift String equality normalizes Unicode.
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        for (index, owner) in [composed, decomposed].enumerated() {
            let abi = CapabilityContract(capabilityID: "action:\(index)", reflectorID: owner, providerID: "provider:\(index)",
                arguments: .null, result: .unit, declaration: .string("exact bytes"))
            _ = try host.admission.publish(RCIRContract(abi: abi, scopes: []), authenticatedPrincipal: "principal:\(index)")
        }
        XCTAssertEqual(host.admission.discover().count, 2)
        host.synchronize(ownerBytes: Set([Data(composed.utf8)]))
        XCTAssertEqual(host.admission.discover().map { Data($0.contract.abi.reflectorID.utf8) }, [Data(composed.utf8)])
    }

    #endif
    func task() throws -> RCIRTask {
        let abi = CapabilityContract(capabilityID: "fixture:act", reflectorID: "r:fixture", providerID: "fixture",
                                     arguments: .object(properties: ["target": .string], required: ["target"]),
                                     result: .integer, declaration: .string("fixture"))
        let contract = RCIRContract(abi: abi, scopes: [], task: .init(shape: .serverStream, element: .integer),
                                    verification: .init(observerID: "observer:host", schema: .integer, expected: .integer(7)))
        let admission = RCIRAdmission()
        let binding = try admission.publish(contract, authenticatedPrincipal: "principal:fixture")
        let policy = RCIRPolicy(revision: "1", principals: ["principal:fixture"], scopes: [])
        let lease = try admission.issue(binding, arguments: .object(["target": .string("urn:target:42")]),
                                        authority: [], policy: policy, now: 100)
        try admission.consume(lease, arguments: lease.arguments, authority: [], policy: policy, now: 101)
        return try RCIRTask(lease: lease, startedAt: 101, deadline: 1000)
    }
    func finished() throws -> RCIRTask {
        var t = try task()
        try t.record(.completed(.integer(7)), sequence: 1, now: 102)
        return t
    }
    func testObserverReceivesExactArgumentsAndBinding() throws {
        struct Observer: RCIRObserver {
            let observerID = "observer:host"
            func observe(_ request: RCIRObservationRequest) throws -> CapabilityValue {
                XCTAssertEqual(try request.arguments.canonicalData(),
                               try CapabilityValue.object(["target": .string("urn:target:42")]).canonicalData())
                XCTAssertEqual(request.binding.contract.abi.capabilityID, "fixture:act")
                return .integer(7)
            }
        }
        var t = try finished()
        try t.verify(using: Observer(), now: 103)
        XCTAssertEqual(t.outcome, .succeeded)
    }
    func testEventPagesHaveBoundedStableCursors() throws {
        var t = try task()
        try t.record(.working, sequence: 1, now: 102)
        try t.record(.chunk(.integer(1)), sequence: 2, now: 103)
        try t.record(.chunk(.integer(2)), sequence: 3, now: 104)
        let first = try t.eventPage(limit: 2)
        XCTAssertEqual(first.events.count, 2); XCTAssertEqual(first.nextCursor, 2)
        XCTAssertTrue(first.hasMore); XCTAssertFalse(first.terminal)
        let second = try t.eventPage(after: first.nextCursor, limit: 2)
        XCTAssertEqual(second.events.count, 1); XCTAssertEqual(second.nextCursor, 3)
        XCTAssertFalse(second.hasMore)
        XCTAssertEqual(first.events + second.events, try t.eventPage().events)
    }
    func testPagesRejectInvalidCursorsAndLimits() throws {
        let t = try task()
        XCTAssertThrowsError(try t.eventPage(after: -1))
        XCTAssertThrowsError(try t.eventPage(after: Int64.max))
        XCTAssertThrowsError(try t.eventPage(limit: 0))
        XCTAssertThrowsError(try t.eventPage(limit: 257))
    }
    func testEmptyTerminalPageIsDistinguishableFromLiveIdle() throws {
        let t = try finished()
        let page = try t.eventPage(after: 1)
        XCTAssertTrue(page.events.isEmpty); XCTAssertTrue(page.terminal); XCTAssertFalse(page.hasMore)
        XCTAssertFalse(try task().eventPage().terminal)
    }
    func testEnvelopeRejectsNonReceiptPayload() {
        XCTAssertThrowsError(try RCIRSignedReceipt(payload: Data("hash-is-not-a-signature".utf8),
                                                   signature: Data(repeating: 0, count: 64), publicKey: Data(repeating: 0, count: 32)))
    }
    func testEnvelopeRejectsWrongSignatureAndKeyLengths() throws {
        let payload = try finished().receiptData()
        XCTAssertThrowsError(try RCIRSignedReceipt(payload: payload, signature: Data(), publicKey: Data(repeating: 0, count: 32)))
        XCTAssertThrowsError(try RCIRSignedReceipt(payload: payload, signature: Data(repeating: 0, count: 64), publicKey: Data()))
    }
    func testEmbeddedKeyCannotEstablishTrust() throws {
        struct Verifier: RCIRReceiptVerifying {
            func verify(signature: Data, payload: Data, publicKey: Data) throws -> Bool {
                XCTFail("Untrusted key must be rejected before backend invocation"); return true
            }
        }
        let receipt = try RCIRSignedReceipt(payload: finished().receiptData(), signature: Data(repeating: 0, count: 64),
                                            publicKey: Data(repeating: 1, count: 32))
        XCTAssertThrowsError(try receipt.verify(trustedPublicKey: Data(repeating: 2, count: 32), using: Verifier()))
    }
    func testBackendSignatureRejectionIsNotIgnored() throws {
        struct Verifier: RCIRReceiptVerifying {
            func verify(signature: Data, payload: Data, publicKey: Data) throws -> Bool { false }
        }
        let receipt = try RCIRSignedReceipt(payload: finished().receiptData(), signature: Data(repeating: 0, count: 64),
                                            publicKey: Data(repeating: 1, count: 32))
        XCTAssertThrowsError(try receipt.verify(trustedPublicKey: receipt.publicKey, using: Verifier()))
    }
    func testWireTransportPreservesExactPayload() throws {
        let payload = try finished().receiptData()
        let receipt = try RCIRSignedReceipt(payload: payload, signature: Data(repeating: 0, count: 64),
                                            publicKey: Data(repeating: 1, count: 32))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: receipt.wireData()) as? [String: Any])
        XCTAssertEqual(json["algorithm"] as? String, "Ed25519")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(json["payload"] as? String)), payload)
    }
    func testUnsignedFixtureIsExplicitlyNotCryptographicEvidence() throws {
        let t = try finished()
        XCTAssertEqual(t.outcome, .unverified)
        XCTAssertTrue(try t.receiptData().starts(with: Data("RIGHTCLICK-RCIR-RECEIPT-1\0".utf8)))
    }
    #if canImport(CryptoKit) || canImport(Crypto)
    func testRealCryptoKitSignatureAndPinnedKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signer = try RCIREd25519Signer(rawPrivateKey: key.rawRepresentation)
        let receipt = try RCIRSignedReceipt.sign(finished(), using: signer)
        XCTAssertNoThrow(try receipt.verify(trustedPublicKey: signer.publicKey, using: RCIREd25519Verifier()))
        XCTAssertThrowsError(try receipt.verify(trustedPublicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
                                               using: RCIREd25519Verifier()))
    }
    func testRealCryptoKitSignatureDetectsPayloadTampering() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signer = try RCIREd25519Signer(rawPrivateKey: key.rawRepresentation)
        let original = try RCIRSignedReceipt.sign(finished(), using: signer)
        var payload = original.payload; payload[payload.count - 1] ^= 1
        let altered = try RCIRSignedReceipt(payload: payload, signature: original.signature, publicKey: original.publicKey)
        XCTAssertThrowsError(try altered.verify(trustedPublicKey: signer.publicKey, using: RCIREd25519Verifier()))
    }
    #endif
}
