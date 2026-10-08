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

final class RCIRReceiptTrustTests: XCTestCase {
    private func fixture() throws -> (RCIRSignedReceipt, RCIREd25519Signer, RCIRReceiptTrustRequest) {
        let abi = CapabilityContract(capabilityID:"fixture:receipt",reflectorID:"reflector:fixture",providerID:"fixture",
            arguments:.integer,result:.integer,declaration:.string("signed assertion test"))
        let contract = RCIRContract(abi:abi,scopes:[],verification:.init(observerID:"observer:fixture",schema:.integer,expected:.integer(7)))
        let admission = RCIRAdmission(), policy = RCIRPolicy(revision:"1",principals:["principal:fixture"],scopes:[])
        let binding = try admission.publish(contract,authenticatedPrincipal:"principal:fixture")
        let lease = try admission.issue(binding,arguments:.integer(1),authority:[],policy:policy,now:100)
        try admission.consume(lease,arguments:.integer(1),authority:[],policy:policy,now:101)
        var task = try RCIRTask(lease:lease,startedAt:101,deadline:1000)
        try task.record(.completed(.integer(7)),sequence:1,now:102)
        try task.verify(observerID:"observer:fixture",now:103) { _,_ in .integer(7) }
        let signer = try RCIREd25519Signer(rawPrivateKey:Curve25519.Signing.PrivateKey().rawRepresentation)
        let receipt = try RCIRSignedReceipt.sign(task,using:signer)
        return (receipt,signer,try .init(issuerID:"issuer:fixture",taskID:task.id,leaseID:lease.id,outcome:.succeeded,mode:.live))
    }
    private func policy(_ receipt: RCIRSignedReceipt, before: Int64 = 100, after: Int64 = 1000,
                        retired: Int64? = nil, age: Int64 = 60_000, clock: @escaping () -> Int64 = { 104 }) throws -> RCIRReceiptTrustPolicy {
        try .init(issuerID:"issuer:fixture",records:[.init(keyID:"key:fixture",publicKey:receipt.publicKey,
            notBefore:before,notAfter:after,retiredAt:retired)],maximumLiveAge:age,clock:clock)
    }
    private func historical(_ request: RCIRReceiptTrustRequest) throws -> RCIRReceiptTrustRequest {
        try .init(issuerID:request.issuerID,taskID:request.taskID,leaseID:request.leaseID,outcome:request.outcome,mode:.historical)
    }
    private struct CallbackVerifier: RCIRReceiptVerifying {
        let callback: () throws -> Void
        func verify(signature: Data,payload: Data,publicKey: Data) throws -> Bool {
            let valid = try RCIREd25519Verifier().verify(signature:signature,payload:payload,publicKey:publicKey)
            try callback(); return valid
        }
    }
    func testLegalReceiptReturnsExplicitIssuerKeyAndClaimsWithoutChangingWire() throws {
        let (receipt,_,request) = try fixture(), trust = try policy(receipt)
        let result = try trust.verify(receipt,expecting:request,using:RCIREd25519Verifier())
        XCTAssertEqual(result.issuerID,request.issuerID); XCTAssertEqual(result.keyID,"key:fixture")
        XCTAssertEqual(result.claims.taskID,request.taskID); XCTAssertEqual(result.claims.leaseID,request.leaseID)
        XCTAssertEqual(result.claims.startedAt,101); XCTAssertEqual(result.claims.lastObservationTime,103)
        XCTAssertFalse(result.claims.hasAuthorityAncestry)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with:receipt.wireData()) as? [String: Any])
        XCTAssertEqual(Set(wire.keys),["version","algorithm","payload","signature","publicKey"])
        XCTAssertEqual(wire["version"] as? Int,1)
    }
    func testHistoricalRetirementAndExpiryRequireDeclaredInterval() throws {
        let (receipt,_,request) = try fixture()
        for trust in [try policy(receipt,retired:104,clock:{500}),try policy(receipt,after:104,clock:{500})] {
            XCTAssertThrowsError(try trust.verify(receipt,expecting:request,using:RCIREd25519Verifier()))
            XCTAssertNoThrow(try trust.verify(receipt,expecting:historical(request),using:RCIREd25519Verifier()))
        }
        for trust in [try policy(receipt,before:102),try policy(receipt,after:103),try policy(receipt,retired:103)] {
            XCTAssertThrowsError(try trust.verify(receipt,expecting:historical(request),using:RCIREd25519Verifier()))
        }
    }
    func testRevocationRejectsBothModesIncludingBackdatedReceipt() throws {
        let (receipt,_,request) = try fixture(), trust = try policy(receipt)
        try trust.revoke(keyID:"key:fixture")
        for r in [request,try historical(request)] {
            XCTAssertThrowsError(try trust.verify(receipt,expecting:r,using:RCIREd25519Verifier())) { XCTAssertEqual($0 as? RCIRReceiptTrustError,.keyRevoked) }
        }
        XCTAssertThrowsError(try trust.register(.init(keyID:"key:fixture",publicKey:receipt.publicKey,notBefore:0,notAfter:2000)))
    }
    func testActualCryptographicCallbackRevocationCannotAccept() throws {
        let (receipt,_,request) = try fixture(), trust = try policy(receipt)
        var callbackRan = false
        let backend = CallbackVerifier { callbackRan = true; try trust.revoke(keyID:"key:fixture") }
        XCTAssertThrowsError(try trust.verify(receipt,expecting:request,using:backend)) { XCTAssertEqual($0 as? RCIRReceiptTrustError,.keyRevoked) }
        XCTAssertTrue(callbackRan)
    }
    func testActualCryptographicCallbackRetirementCannotAccept() throws {
        let (receipt,_,request) = try fixture(), trust = try policy(receipt)
        let backend = CallbackVerifier { try trust.retire(keyID:"key:fixture",at:104) }
        XCTAssertThrowsError(try trust.verify(receipt,expecting:request,using:backend)) { XCTAssertEqual($0 as? RCIRReceiptTrustError,.keyNotActive) }
    }
    func testActualCryptographicCallbackExpiryCannotAccept() throws {
        let (receipt,_,request) = try fixture()
        let expiry = Int64(Date().timeIntervalSince1970 * 1000) + 20
        let actual = try RCIRReceiptTrustPolicy(issuerID:"issuer:fixture",records:[.init(keyID:"key:fixture",publicKey:receipt.publicKey,notBefore:100,notAfter:expiry)],maximumLiveAge:86_400_000)
        let backend = CallbackVerifier { Thread.sleep(forTimeInterval:0.04) }
        XCTAssertThrowsError(try actual.verify(receipt,expecting:request,using:backend)) { XCTAssertEqual($0 as? RCIRReceiptTrustError,.keyNotActive) }
    }
    func testBackendErrorIsStaticAndDoesNotExposeSyntheticContext() throws {
        struct SensitiveError: Error, CustomStringConvertible { var description: String { "synthetic-sensitive-verifier-context" } }
        let (receipt,_,request) = try fixture(), trust = try policy(receipt)
        XCTAssertThrowsError(try trust.verify(receipt,expecting:request,using:CallbackVerifier { throw SensitiveError() })) {
            XCTAssertEqual($0 as? RCIRReceiptError,.invalidSignature)
            XCTAssertFalse(String(describing:$0).contains("synthetic-sensitive"))
        }
    }
    func testClockRollbackCannotResurrectExpiredLiveKey() throws {
        let (receipt,_,request) = try fixture(); var now: Int64 = 1000
        let trust = try policy(receipt,clock:{now})
        XCTAssertThrowsError(try trust.verify(receipt,expecting:request,using:RCIREd25519Verifier()))
        now = 104
        XCTAssertThrowsError(try trust.verify(receipt,expecting:request,using:RCIREd25519Verifier()))
        XCTAssertNoThrow(try trust.verify(receipt,expecting:historical(request),using:RCIREd25519Verifier()))
    }
    func testLiveFreshnessAndFutureAssertionsFailHistoricalIsExplicit() throws {
        let (receipt,_,request) = try fixture(), old = try policy(receipt,age:1,clock:{105})
        XCTAssertThrowsError(try old.verify(receipt,expecting:request,using:RCIREd25519Verifier())) { XCTAssertEqual($0 as? RCIRReceiptTrustError,.receiptTooOld) }
        XCTAssertNoThrow(try old.verify(receipt,expecting:historical(request),using:RCIREd25519Verifier()))
        let future = try policy(receipt,clock:{102})
        XCTAssertThrowsError(try future.verify(receipt,expecting:historical(request),using:RCIREd25519Verifier()))
    }
    func testIssuerMatchingUsesExactUTF8AndTaskLeaseOutcomeAreBound() throws {
        let (receipt,_,request) = try fixture(), trust = try policy(receipt)
        for r in [try RCIRReceiptTrustRequest(issuerID:"other",taskID:request.taskID,leaseID:request.leaseID,mode:.live),
                  try .init(issuerID:request.issuerID,taskID:UUID(),leaseID:request.leaseID,mode:.live),
                  try .init(issuerID:request.issuerID,taskID:request.taskID,leaseID:UUID(),mode:.live),
                  try .init(issuerID:request.issuerID,taskID:request.taskID,leaseID:request.leaseID,outcome:.failed,mode:.live)] {
            XCTAssertThrowsError(try trust.verify(receipt,expecting:r,using:RCIREd25519Verifier()))
        }
        let unicode = try RCIRReceiptTrustPolicy(issuerID:"issuér",records:[.init(keyID:"clé",publicKey:receipt.publicKey,notBefore:100,notAfter:1000)],clock:{104})
        let equivalent = try RCIRReceiptTrustRequest(issuerID:"issue\u{301}r",taskID:request.taskID,leaseID:request.leaseID,mode:.live)
        XCTAssertThrowsError(try unicode.verify(receipt,expecting:equivalent,using:RCIREd25519Verifier()))
        XCTAssertThrowsError(try unicode.revoke(keyID:"cle\u{301}"))
    }
    func testUntrustedLocatorAndTamperingRejectBeforeClaimsAcceptance() throws {
        let (receipt,_,request) = try fixture(), trust = try policy(receipt)
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let substituted = try RCIRSignedReceipt(payload:receipt.payload,signature:receipt.signature,publicKey:other)
        var called = false
        XCTAssertThrowsError(try trust.verify(substituted,expecting:request,using:CallbackVerifier { called = true }))
        XCTAssertFalse(called)
        var bytes = receipt.signature; bytes[0] ^= 1
        XCTAssertThrowsError(try trust.verify(.init(payload:receipt.payload,signature:bytes,publicKey:receipt.publicKey),expecting:request,using:RCIREd25519Verifier()))
    }
    func testSignatureValidMalformedCanonicalAndUnknownFieldsReject() throws {
        let (receipt,signer,request) = try fixture(), trust = try policy(receipt)
        let domain = Data("RIGHTCLICK-RCIR-RECEIPT-1\0".utf8), value = Data("RIGHTCLICK-VALUE-1\0".utf8)
        let offset = domain.count + value.count
        XCTAssertEqual(Data(receipt.payload[offset..<(offset + 4)]),Data("o14:".utf8))
        var unknown = receipt.payload
        unknown.replaceSubrange(offset..<(offset + 4),with:Data("o15:".utf8)); unknown.append(Data("s1:zn".utf8))
        var noncanonical = receipt.payload
        noncanonical.replaceSubrange(offset..<(offset + 4),with:Data("o014:".utf8))
        var trailing = receipt.payload; trailing.append(110)
        for payload in [unknown,noncanonical,trailing,domain + value + Data("o0:".utf8)] {
            let signed = try RCIRSignedReceipt(payload:payload,signature:signer.sign(payload),publicKey:signer.publicKey)
            XCTAssertNoThrow(try signed.verify(trustedPublicKey:signer.publicKey,using:RCIREd25519Verifier()))
            XCTAssertThrowsError(try trust.verify(signed,expecting:request,using:RCIREd25519Verifier())) { XCTAssertEqual($0 as? RCIRReceiptTrustError,.malformedReceipt) }
        }
    }
    func testBoundedExplicitRecordsAndIrreversibleRetirement() throws {
        let (receipt,_,_) = try fixture(), trust = try policy(receipt)
        for i in 1..<RCIRReceiptTrustPolicy.maximumRecords {
            var publicKey = Data(repeating:0,count:32); publicKey[0] = UInt8(i)
            try trust.register(.init(keyID:"key:\(i)",publicKey:publicKey,notBefore:0,notAfter:1000))
        }
        XCTAssertThrowsError(try trust.register(.init(keyID:"overflow",publicKey:Data(repeating:255,count:32),notBefore:0,notAfter:1000)))
        try trust.retire(keyID:"key:fixture",at:500)
        XCTAssertThrowsError(try trust.retire(keyID:"key:fixture",at:501))
        XCTAssertThrowsError(try RCIRReceiptKeyRecord(keyID:String(repeating:"k",count:513),publicKey:receipt.publicKey,notBefore:0,notAfter:1000))
        XCTAssertThrowsError(try RCIRReceiptKeyRecord(keyID:"key",publicKey:receipt.publicKey,notBefore:1,notAfter:1))
        XCTAssertThrowsError(try RCIRReceiptTrustPolicy(issuerID:"issuer",records:[],clock:{104}))
    }
}
