import Foundation
import XCTest
@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders

/// Pure Foundation structure/bounds coverage. No synthetic signature backend is
/// accepted, and these tests do not claim cryptographic or provider evidence.
final class RCIRReceiptTrustStructureTests: XCTestCase {
    private func task() throws -> RCIRTask {
        let contract = RCIRContract(abi:.init(capabilityID:"fixture:receipt",reflectorID:"reflector:fixture",providerID:"fixture",
            arguments:.integer,result:.integer,declaration:.string("structure control")),scopes:[])
        let admission = RCIRAdmission(), policy = RCIRPolicy(revision:"1",principals:["principal:fixture"],scopes:[])
        let binding = try admission.publish(contract,authenticatedPrincipal:"principal:fixture")
        let lease = try admission.issue(binding,arguments:.integer(7),authority:[],policy:policy,now:100)
        try admission.consume(lease,arguments:.integer(7),authority:[],policy:policy,now:101)
        return try .init(lease:lease,startedAt:101,deadline:1000)
    }
    func testActualTaskReceiptExtractionPreservesUnverifiedAndUnknown() throws {
        var completed = try task(); try completed.record(.completed(.integer(7)),sequence:1,now:102)
        let claims = try RCIRReceiptClaims.read(completed.receiptData())
        XCTAssertEqual(claims.phase,.completed); XCTAssertEqual(claims.outcome,.unverified)
        var unknown = try task(); try unknown.providerDisappeared(now:102)
        let loss = try RCIRReceiptClaims.read(unknown.receiptData())
        XCTAssertEqual(loss.phase,.unknown); XCTAssertEqual(loss.outcome,.unknown)
        XCTAssertEqual(loss.taskID,unknown.id)
    }
    func testActualDeadlineUnknownMayBeLaterThanDeadline() throws {
        var timedOut = try task(); try timedOut.checkDeadline(now:2000)
        let claims = try RCIRReceiptClaims.read(timedOut.receiptData())
        XCTAssertEqual(claims.finishedAt,2000); XCTAssertEqual(claims.outcome,.unknown)
        XCTAssertEqual(claims.lastObservationTime,2000)
    }
    func testUntrustedFramingDepthCollectionAndByteLimitsFailClosed() {
        let prefix = Data("RIGHTCLICK-RCIR-RECEIPT-1\0RIGHTCLICK-VALUE-1\0".utf8)
        let depth = String(repeating:"a1:",count:34) + "n"
        for bytes in [prefix + Data(depth.utf8),prefix + Data("a4097:".utf8),prefix + Data("x999999999:".utf8),
                      prefix + Data("o0:n".utf8),prefix + Data(repeating:110,count:1_048_576)] {
            XCTAssertThrowsError(try RCIRReceiptClaims.read(bytes)) { XCTAssertEqual($0 as? RCIRReceiptTrustError,.malformedReceipt) }
        }
    }
    func testTrustProvisioningRejectsAmbiguousOrUnboundedRecords() throws {
        let key = Data(repeating:1,count:32)
        let record = try RCIRReceiptKeyRecord(keyID:"one",publicKey:key,notBefore:100,notAfter:200)
        XCTAssertThrowsError(try RCIRReceiptTrustPolicy(issuerID:"issuer",records:[record,record]))
        for name in ["","*","line\nsecret",String(repeating:"k",count:513)] {
            XCTAssertThrowsError(try RCIRReceiptKeyRecord(keyID:name,publicKey:key,notBefore:100,notAfter:200))
        }
        XCTAssertThrowsError(try RCIRReceiptKeyRecord(keyID:"key",publicKey:Data(),notBefore:100,notAfter:200))
        XCTAssertThrowsError(try RCIRReceiptKeyRecord(keyID:"key",publicKey:key,notBefore:100,notAfter:200,retiredAt:201))
    }
}
