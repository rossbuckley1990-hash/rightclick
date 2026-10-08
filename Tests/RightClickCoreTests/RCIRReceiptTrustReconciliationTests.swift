import Foundation
import XCTest
@testable import RightClickCore

final class RCIRReceiptTrustReconciliationTests: XCTestCase {
    private let k0 = Data(repeating: 0, count: 32), k1 = Data(repeating: 1, count: 32), k2 = Data(repeating: 2, count: 32)
    private func record(_ key: Data, id: String, before: Int64 = 100, after: Int64 = 1000,
                        retired: Int64? = nil, revoked: Bool = false) throws -> RCIRReceiptKeyRecord {
        try .init(keyID: id, publicKey: key, notBefore: before, notAfter: after, retiredAt: retired, revoked: revoked)
    }
    private func initial() throws -> [RCIRReceiptKeyRecord] { [try record(k0, id: "k0"), try record(k1, id: "k1")] }
    private func policy(_ records: [RCIRReceiptKeyRecord]? = nil) throws -> RCIRReceiptTrustPolicy {
        try .init(issuerID: "issuer", records: records ?? initial(), clock: { 104 })
    }
    func testRetiredAndRevokedTombstonesCannotBeOmittedOrRestored() throws {
        let trust = try policy()
        try trust.revoke(keyID: "k0"); try trust.retire(keyID: "k1", at: 500)
        for records in [
            [try record(k1, id: "k1", retired: 500)],
            [try record(k0, id: "k0", revoked: true)],
            try initial(),
            [try record(k0, id: "k0", revoked: true), try record(k1, id: "k1", retired: 501)],
        ] {
            XCTAssertThrowsError(try trust.reconcile(issuerID: "issuer", records: records, maximumLiveAge: 60_000))
            XCTAssertThrowsError(try trust.authorization(for: k0)) { XCTAssertEqual($0 as? RCIRReceiptTrustError, .keyRevoked) }
        }
        XCTAssertEqual(try trust.authorization(for: k1).keyRevision, 2)
    }
    func testKeyIDsLocatorsAndOriginalIntervalsCannotBeReassignedOrWidened() throws {
        let trust = try policy(), token = try trust.authorization(for: k0)
        for records in [
            [try record(k0, id: "other"), try record(k1, id: "k1")],
            [try record(k2, id: "k0"), try record(k1, id: "k1")],
            [try record(k0, id: "k0", before: 99), try record(k1, id: "k1")],
            [try record(k0, id: "k0", after: 1001), try record(k1, id: "k1")],
            [try record(k0, id: "k0", before: 101), try record(k1, id: "k1")],
            [try record(k0, id: "k0", after: 999), try record(k1, id: "k1")],
        ] {
            XCTAssertThrowsError(try trust.reconcile(issuerID: "issuer", records: records, maximumLiveAge: 60_000))
            XCTAssertNoThrow(try trust.revalidate(token))
        }
    }
    func testInvalidLaterRecordDoesNotCommitEarlierCandidateRevocationOrAddition() throws {
        let trust = try policy(), token = try trust.authorization(for: k0)
        let candidate = [try record(k0, id: "k0", revoked: true), try record(k2, id: "k2"),
                         try record(k1, id: "k1", after: 2000)]
        XCTAssertThrowsError(try trust.reconcile(issuerID: "issuer", records: candidate, maximumLiveAge: 60_000))
        XCTAssertNoThrow(try trust.revalidate(token))
        XCTAssertThrowsError(try trust.authorization(for: k2)) { XCTAssertEqual($0 as? RCIRReceiptTrustError, .untrustedKey) }
    }
    func testUnchangedReorderedSnapshotAndUnrelatedAdditionPreserveKeyRevision() throws {
        let trust = try policy(), token = try trust.authorization(for: k0)
        try trust.reconcile(issuerID: "issuer", records: [try record(k1, id: "k1"), try record(k0, id: "k0")], maximumLiveAge: 60_000)
        XCTAssertNoThrow(try trust.revalidate(token))
        try trust.reconcile(issuerID: "issuer", records: [try record(k0, id: "k0"), try record(k1, id: "k1"), try record(k2, id: "k2")], maximumLiveAge: 60_000)
        XCTAssertNoThrow(try trust.revalidate(token)); XCTAssertEqual(try trust.authorization(for: k0).keyRevision, 1)
        XCTAssertNoThrow(try trust.authorization(for: k2))
    }
    func testEarlierRetirementInvalidatesOnlyAffectedToken() throws {
        let trust = try policy(), first = try trust.authorization(for: k0), second = try trust.authorization(for: k1)
        try trust.reconcile(issuerID: "issuer", records: [try record(k0, id: "k0", retired: 500), try record(k1, id: "k1")], maximumLiveAge: 60_000)
        XCTAssertThrowsError(try trust.revalidate(first)) { XCTAssertEqual($0 as? RCIRReceiptTrustError, .changedPolicy) }
        XCTAssertNoThrow(try trust.revalidate(second)); XCTAssertEqual(try trust.authorization(for: k0).keyRevision, 2)
        try trust.reconcile(issuerID: "issuer", records: [try record(k0, id: "k0", retired: 400), try record(k1, id: "k1")], maximumLiveAge: 60_000)
        XCTAssertEqual(try trust.authorization(for: k0).keyRevision, 3)
    }
    func testIssuerFreshnessAndDuplicateRecordsCannotMutateRetainedPolicy() throws {
        let trust = try policy(), token = try trust.authorization(for: k0)
        XCTAssertThrowsError(try trust.reconcile(issuerID: "other", records: initial(), maximumLiveAge: 60_000))
        XCTAssertThrowsError(try trust.reconcile(issuerID: "issuer", records: initial(), maximumLiveAge: 60_001))
        for records in [[], [try record(k0, id: "k0"), try record(k0, id: "other")],
                        [try record(k0, id: "k0"), try record(k2, id: "k0")]] {
            XCTAssertThrowsError(try trust.reconcile(issuerID: "issuer", records: records, maximumLiveAge: 60_000))
            XCTAssertNoThrow(try trust.revalidate(token))
        }
    }
    func testSigningAuthorizationUsesHalfOpenIntervalAndMonotonicClock() throws {
        var now: Int64 = 100
        let trust = try RCIRReceiptTrustPolicy(issuerID: "issuer", records: [record(k0, id: "k0")], clock: { now })
        let token = try trust.authorization(for: k0); now = 1000
        XCTAssertThrowsError(try trust.revalidate(token)) { XCTAssertEqual($0 as? RCIRReceiptTrustError, .keyNotActive) }
        now = 104
        XCTAssertThrowsError(try trust.authorization(for: k0)) { XCTAssertEqual($0 as? RCIRReceiptTrustError, .keyNotActive) }
        let future = try RCIRReceiptTrustPolicy(issuerID: "issuer", records: [record(k0, id: "k0")], clock: { 99 })
        XCTAssertThrowsError(try future.authorization(for: k0))
    }
    func testSharedRawValidatorRejectsHostReferenceDuplicatesAndAllowsOrdinaryJSONKinds() throws {
        let legal = #"{"version":1,"observers":{"fixture":{"headers":{"number":"-1.2e+3"},"predicate":{"value":1.25}}},"signingKeyFile":"synthetic/path","receiptTrustPolicyFile":"synthetic/policy","nullable":null,"boolean":true}"#
        XCTAssertNoThrow(try RCIRReceiptTrustJSON.validateUniqueKeys(Data(legal.utf8)))
        for json in [
            #"{"signingKeyFile":"first","signingKeyFile":"second"}"#,
            #"{"signingKeyFile":"first","signing\u004beyFile":"second"}"#,
            #"{"receiptTrustPolicyFile":"first","receiptTrustPolicy\u0046ile":"second"}"#,
            #"{"observer":{"token":"first","to\u006ben":"second"}}"#,
            #"{"number":01}"#, #"{"number":1.}"#, #"{"number":1e}"#, #"{"number":-}"#,
            #"{"string":"\q"}"#, #"{"array":[1,]}"#, #"{"extra":true}false"#,
        ] { XCTAssertThrowsError(try RCIRReceiptTrustJSON.validateUniqueKeys(Data(json.utf8))) }
        // This primitive is not the host schema decoder.
        XCTAssertNoThrow(try RCIRReceiptTrustJSON.validateUniqueKeys(Data(#"{"unknownField":-1.2e+3}"#.utf8)))
        XCTAssertNoThrow(try RCIRReceiptTrustJSON.validateUniqueKeys(Data(("[" + String(repeating: "0,", count: 64) + "0]").utf8)))
    }
}
