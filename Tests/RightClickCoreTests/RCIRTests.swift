import Foundation
import XCTest
@testable import RightClickCore

final class RCIRTests: XCTestCase {
    let read = RCIRScope("urn:test:document:1", .read)
    let write = RCIRScope("urn:test:document:1", .write)
    var authority: Set<RCIRScope> { [read, write] }
    var policy: RCIRPolicy { .init(revision: "p1", principals: ["principal:fixture"], scopes: authority) }
    func contract(scopes: Set<RCIRScope>? = nil, task: RCIRTaskModel = .init(),
                  verification: RCIRVerificationContract? = nil, provider: String = "fixture",
                  arguments: CapabilitySchema? = .object(properties: ["n": .integer], required: ["n"])) -> RCIRContract {
        .init(abi: .init(capabilityID: "fixture:act", reflectorID: "reflector:test", providerID: provider,
                        arguments: arguments, result: .integer, declaration: .string("test declaration")),
              scopes: scopes, task: task, verification: verification)
    }
    var args: CapabilityValue { .object(["n": .integer(1)]) }
    var verifier: RCIRVerificationContract { .init(observerID: "observer:external", schema: .integer, expected: .integer(2)) }
    func fixture(_ c: RCIRContract? = nil) throws -> (RCIRAdmission, RCIRBinding, RCIRLease) {
        let admission = RCIRAdmission()
        let binding = try admission.publish(c ?? contract(scopes: [read]), authenticatedPrincipal: "principal:fixture")
        let lease = try admission.issue(binding, arguments: args, authority: authority, policy: policy, now: 100)
        return (admission, binding, lease)
    }
    func task(_ c: RCIRContract? = nil, deadline: Int64 = 1000) throws -> RCIRTask {
        let (_, _, lease) = try fixture(c)
        return try RCIRTask(lease: lease, startedAt: 101, deadline: deadline)
    }
    func testExistingABIStillDistinguishesIntegerNumberAndString() throws {
        XCTAssertNotEqual(try CapabilityValue.integer(1).canonicalData(), try CapabilityValue.number(1).canonicalData())
        XCTAssertThrowsError(try CapabilitySchema.integer.validate(.string("1")))
    }
    func testScopesUseExactUTF8() {
        XCTAssertNotEqual(RCIRScope("urn:é", .read), RCIRScope("urn:e\u{301}", .read))
    }
    func testContractBindsEffects() throws {
        XCTAssertNotEqual(try contract(scopes: [read]).canonicalData(), try contract(scopes: [write]).canonicalData())
    }
    func testContractBindsTaskShape() throws {
        XCTAssertNotEqual(try contract(scopes: [read]).canonicalData(), try contract(scopes: [read], task: .init(shape: .deferred)).canonicalData())
    }
    func testContractBindsVerification() throws {
        XCTAssertNotEqual(try contract(scopes: [read]).canonicalData(), try contract(scopes: [read], verification: verifier).canonicalData())
    }
    func testContractRejectsUnboundedStream() {
        XCTAssertThrowsError(try contract(scopes: [read], task: .init(shape: .serverStream)).canonicalData())
        XCTAssertThrowsError(try contract(scopes: [read], task: .init(maxEvents: 4097)).canonicalData())
        XCTAssertThrowsError(try contract(scopes: [read], task: .init(maxBytes: 0)).canonicalData())
    }
    func testInvalidScopeFailsClosed() {
        XCTAssertThrowsError(try contract(scopes: [.init("", .read)]).canonicalData())
        XCTAssertThrowsError(try contract(scopes: [.init("urn:*", .read)]).canonicalData())
    }
    func testSamePublicationDoesNotInvalidateBinding() throws {
        let (a, b, _) = try fixture()
        let again = try a.publish(contract(scopes: [read]), authenticatedPrincipal: "principal:fixture")
        XCTAssertEqual(b.generation, again.generation)
        XCTAssertEqual(b.bytes, again.bytes)
    }
    func testPrincipalBoundToSnapshot() throws {
        let a = RCIRAdmission()
        let b = try a.publish(contract(scopes: [read]), authenticatedPrincipal: "principal:fixture")
        let other = try a.publish(contract(scopes: [read]), authenticatedPrincipal: "principal:other")
        XCTAssertNotEqual(b.bytes, other.bytes)
    }
    func testLeastAuthorityIsExactRequiredSubset() throws {
        let (_, _, lease) = try fixture()
        XCTAssertEqual(lease.scopes, [read])
    }
    func testMissingAuthorityRejected() throws {
        let (a, b, _) = try fixture()
        XCTAssertThrowsError(try a.issue(b, arguments: args, authority: [], policy: policy, now: 100))
    }
    func testUnknownEffectsRejected() {
        XCTAssertThrowsError(try fixture(contract()))
        XCTAssertThrowsError(try fixture(contract(scopes: [.init("urn:x", .unknown)])))
    }
    func testPureOperationNeedsNoAuthority() throws {
        let a = RCIRAdmission()
        let b = try a.publish(contract(scopes: []), authenticatedPrincipal: "principal:fixture")
        let lease = try a.issue(b, arguments: args, authority: [], policy: policy, now: 100)
        XCTAssertEqual(lease.scopes, [])
    }
    func testUnknownArgumentSchemaRejected() {
        XCTAssertThrowsError(try fixture(contract(scopes: [read], arguments: nil)))
    }
    func testIncorrectTypedArgumentsRejected() throws {
        let (a, b, _) = try fixture()
        XCTAssertThrowsError(try a.issue(b, arguments: .object(["n": .string("1")]), authority: authority, policy: policy, now: 100))
        XCTAssertThrowsError(try a.issue(b, arguments: .object(["n": .integer(1), "extra": .boolean(true)]), authority: authority, policy: policy, now: 100))
    }
    func testPolicyDenyOverridesAuthority() throws {
        let (a, b, _) = try fixture()
        let deny = RCIRPolicy(revision: "deny", principals: [], scopes: authority)
        XCTAssertThrowsError(try a.issue(b, arguments: args, authority: authority, policy: deny, now: 100))
        let denyScope = RCIRPolicy(revision: "deny", principals: ["principal:fixture"], scopes: [])
        XCTAssertThrowsError(try a.issue(b, arguments: args, authority: authority, policy: denyScope, now: 100))
    }
    func testUnsupportedClientAndDuplexStreamsAbstain() {
        for shape: RCIRTaskShape in [.clientStream, .duplex] {
            XCTAssertThrowsError(try fixture(contract(scopes: [read], task: .init(shape: shape, element: .integer))))
        }
    }
    func testRemovedProviderDisappearsAndOldBindingRejected() throws {
        let (a, b, lease) = try fixture()
        a.withdraw(providerID: "fixture")
        XCTAssertTrue(a.discover().isEmpty)
        XCTAssertThrowsError(try a.issue(b, arguments: args, authority: authority, policy: policy, now: 101))
        XCTAssertThrowsError(try a.consume(lease, arguments: args, authority: authority, policy: policy, now: 101))
    }
    func testReappearanceCannotResurrectOldLease() throws {
        let (a, b, lease) = try fixture()
        a.withdraw(providerID: "fixture")
        let replacement = try a.publish(contract(scopes: [read]), authenticatedPrincipal: "principal:fixture")
        XCTAssertNotEqual(b.generation, replacement.generation)
        XCTAssertThrowsError(try a.consume(lease, arguments: args, authority: authority, policy: policy, now: 101))
    }
    func testChangedContractInvalidatesLease() throws {
        let (a, _, lease) = try fixture()
        _ = try a.publish(contract(scopes: [write]), authenticatedPrincipal: "principal:fixture")
        XCTAssertThrowsError(try a.consume(lease, arguments: args, authority: authority, policy: policy, now: 101))
    }
    func testLeaseConsumesOnce() throws {
        let (a, _, lease) = try fixture()
        XCTAssertNoThrow(try a.consume(lease, arguments: args, authority: authority, policy: policy, now: 101))
        XCTAssertThrowsError(try a.consume(lease, arguments: args, authority: authority, policy: policy, now: 101))
    }
    func testLeaseCannotCrossAdmissionInstances() throws {
        let (_, _, lease) = try fixture()
        let (other, _, _) = try fixture()
        XCTAssertThrowsError(try other.consume(lease, arguments: args, authority: authority, policy: policy, now: 101))
    }
    func testLeaseExpiryBoundary() throws {
        let (a, _, lease) = try fixture()
        XCTAssertThrowsError(try a.consume(lease, arguments: args, authority: authority, policy: policy, now: lease.expiresAt))
    }
    func testLeaseInvalidTimesAndTTLRejected() throws {
        let (a, b, _) = try fixture()
        for ttl: Int64 in [0, -1, 60_001, Int64.max] {
            XCTAssertThrowsError(try a.issue(b, arguments: args, authority: authority, policy: policy, now: 100, ttl: ttl))
        }
        XCTAssertThrowsError(try a.issue(b, arguments: args, authority: authority, policy: policy, now: -1))
        XCTAssertThrowsError(try a.issue(b, arguments: args, authority: authority, policy: policy, now: Int64.max))
    }
    func testArgumentTamperingRejected() throws {
        let (a, _, lease) = try fixture()
        XCTAssertThrowsError(try a.consume(lease, arguments: .object(["n": .integer(2)]), authority: authority, policy: policy, now: 101))
    }
    func testPolicyChangeAndAuthorityRevocationRejected() throws {
        let (a, _, lease) = try fixture()
        let changed = RCIRPolicy(revision: "p2", principals: ["principal:fixture"], scopes: authority)
        XCTAssertThrowsError(try a.consume(lease, arguments: args, authority: authority, policy: changed, now: 101))
        XCTAssertThrowsError(try a.consume(lease, arguments: args, authority: [], policy: policy, now: 101))
    }
    func testAcceptanceAndCompletionAreNotSemanticSuccess() throws {
        var t = try task()
        try t.record(.accepted, sequence: 1, now: 102)
        XCTAssertEqual(t.outcome, .unverified)
        try t.record(.completed(.integer(2)), sequence: 2, now: 103)
        XCTAssertEqual(t.phase, .completed); XCTAssertEqual(t.outcome, .unverified)
    }
    func testTerminalTaskCannotBeReopened() throws {
        var t = try task()
        try t.record(.completed(.integer(2)), sequence: 1, now: 102)
        XCTAssertThrowsError(try t.record(.working, sequence: 2, now: 103))
    }
    func testStreamSequenceReplayAndGapRejected() throws {
        var t = try task(contract(scopes: [read], task: .init(shape: .serverStream, element: .integer)))
        try t.record(.working, sequence: 1, now: 102)
        try t.record(.chunk(.integer(2)), sequence: 2, now: 103)
        XCTAssertThrowsError(try t.record(.chunk(.integer(2)), sequence: 2, now: 104))
        XCTAssertThrowsError(try t.record(.chunk(.integer(3)), sequence: 4, now: 104))
        XCTAssertEqual(t.sequence, 2)
    }
    func testStreamElementAndUnaryChunkValidation() throws {
        var t = try task(contract(scopes: [read], task: .init(shape: .serverStream, element: .integer)))
        try t.record(.working, sequence: 1, now: 102)
        XCTAssertThrowsError(try t.record(.chunk(.string("2")), sequence: 2, now: 103))
        XCTAssertEqual(t.sequence, 1)
        var unary = try task()
        XCTAssertThrowsError(try unary.record(.chunk(.integer(2)), sequence: 1, now: 102))
    }
    func testBufferOverflowNeverSilentlyDropsEvents() throws {
        var t = try task(contract(scopes: [read], task: .init(shape: .serverStream, element: .integer, maxEvents: 2)))
        try t.record(.working, sequence: 1, now: 102)
        try t.record(.chunk(.integer(1)), sequence: 2, now: 103)
        XCTAssertThrowsError(try t.record(.chunk(.integer(2)), sequence: 3, now: 104))
        XCTAssertEqual(t.eventCount, 2)
    }
    func testByteBudgetEnforcedBeforeMutation() throws {
        var t = try task(contract(scopes: [read], task: .init(shape: .serverStream, element: .string, maxBytes: 512)))
        try t.record(.working, sequence: 1, now: 102)
        XCTAssertThrowsError(try t.record(.chunk(.string(String(repeating: "x", count: 1024))), sequence: 2, now: 103))
        XCTAssertEqual(t.sequence, 1)
    }
    func testResultShapeCheckedWithoutPromotion() throws {
        var t = try task()
        XCTAssertThrowsError(try t.record(.completed(.string("2")), sequence: 1, now: 102))
        XCTAssertEqual(t.phase, .started); XCTAssertEqual(t.outcome, .unverified)
    }
    func testCancellationRequestIsNotAcknowledgement() throws {
        var t = try task(contract(scopes: [read], task: .init(shape: .deferred, cancellable: true)))
        try t.requestCancellation(now: 102)
        XCTAssertEqual(t.phase, .cancelRequested); XCTAssertEqual(t.outcome, .unverified)
        try t.record(.cancelled, sequence: 1, now: 103)
        XCTAssertEqual(t.phase, .cancelled)
    }
    func testUnsupportedCancellationRejected() throws {
        var t = try task()
        XCTAssertThrowsError(try t.requestCancellation(now: 102))
    }
    func testDeadlineProducesUnknownNotSuccessOrRetry() throws {
        var t = try task(deadline: 200)
        try t.checkDeadline(now: 200)
        XCTAssertEqual(t.phase, .unknown); XCTAssertEqual(t.outcome, .unknown)
        XCTAssertThrowsError(try t.record(.completed(.integer(2)), sequence: 1, now: 201))
    }
    func testProviderLossDuringWorkIsUnknown() throws {
        var t = try task()
        try t.record(.accepted, sequence: 1, now: 102)
        try t.providerDisappeared(now: 103)
        XCTAssertEqual(t.phase, .unknown); XCTAssertEqual(t.outcome, .unknown)
    }
    func testClockRegressionRejected() throws {
        var t = try task()
        try t.record(.accepted, sequence: 1, now: 105)
        XCTAssertThrowsError(try t.record(.working, sequence: 2, now: 104))
    }
    func testTaskDeadlineMustBeFiniteAndForward() throws {
        let (_, _, lease) = try fixture()
        XCTAssertThrowsError(try RCIRTask(lease: lease, startedAt: 101, deadline: 100))
        XCTAssertThrowsError(try RCIRTask(lease: lease, startedAt: 101, deadline: Int64.max))
    }
    func testVerifierCannotRunBeforeProviderCompletion() throws {
        var t = try task(contract(scopes: [read], verification: verifier))
        var called = false
        XCTAssertThrowsError(try t.verify(observerID: verifier.observerID, now: 102) { _, _ in called = true; return .integer(2) })
        XCTAssertFalse(called)
    }
    func testOnlyBoundIndependentObserverCanVerify() throws {
        var t = try task(contract(scopes: [read], verification: verifier))
        try t.record(.completed(.integer(2)), sequence: 1, now: 102)
        XCTAssertThrowsError(try t.verify(observerID: "provider:response", now: 103) { _, _ in .integer(2) })
        XCTAssertEqual(t.outcome, .unverified)
        let expectedTaskID = t.id
        try t.verify(observerID: verifier.observerID, now: 103) { taskID, binding in
            XCTAssertEqual(taskID, expectedTaskID)
            XCTAssertEqual(binding.contract.abi.providerID, "fixture")
            return .integer(2)
        }
        XCTAssertEqual(t.outcome, .succeeded)
    }
    func testExternalMismatchIsSemanticFailure() throws {
        var t = try task(contract(scopes: [read], verification: verifier))
        try t.record(.completed(.integer(2)), sequence: 1, now: 102)
        try t.verify(observerID: verifier.observerID, now: 103) { _, _ in .integer(99) }
        XCTAssertEqual(t.outcome, .failed)
    }
    func testObserverTransportFailureDoesNotBecomeSuccess() throws {
        var t = try task(contract(scopes: [read], verification: verifier))
        try t.record(.completed(.integer(2)), sequence: 1, now: 102)
        XCTAssertThrowsError(try t.verify(observerID: verifier.observerID, now: 103) { _, _ in throw RCIRError.unavailable })
        XCTAssertEqual(t.outcome, .unverified)
    }
    func testMissingVerificationContractCannotSucceed() throws {
        var t = try task()
        try t.record(.completed(.integer(2)), sequence: 1, now: 102)
        XCTAssertThrowsError(try t.verify(observerID: verifier.observerID, now: 103) { _, _ in .integer(2) })
        XCTAssertEqual(t.outcome, .unverified)
    }
    func testReceiptBindsObservedOutcomeAndHasDomainSeparator() throws {
        var t = try task(contract(scopes: [read], verification: verifier))
        try t.record(.completed(.integer(2)), sequence: 1, now: 102)
        let before = try t.receiptData()
        try t.verify(observerID: verifier.observerID, now: 103) { _, _ in .integer(2) }
        let after = try t.receiptData()
        XCTAssertNotEqual(before, after)
        XCTAssertTrue(after.starts(with: Data("RIGHTCLICK-RCIR-RECEIPT-1\0".utf8)))
    }
    func testCannotIssueFinalReceiptForRunningTask() throws {
        let t = try task()
        XCTAssertThrowsError(try t.receiptData())
    }
}
