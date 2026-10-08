import Foundation
import XCTest
@testable import RightClickProtocol

final class CapabilityLeaseTests: XCTestCase {
    private let environmentA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let environmentB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let environmentC = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    private func key(_ byte: UInt8) throws -> RCIREd25519Signer {
        try .init(rawPrivateKey: Data(repeating: byte, count: 32))
    }
    private func limits(executions: Int64 = 8, children: Int64 = 2, descendants: Int64 = 4,
                        depth: Int64 = 2, cpu: Int64 = 2, memory: Int64 = 1024, cost: Int64 = 400) throws -> CapabilityLeaseLimits {
        try .init(maximumExecutions: executions, maximumChildren: children, maximumDescendants: descendants,
                  delegationDepth: depth, cpuCount: cpu, memoryMiB: memory, maximumCostUnits: cost)
    }
    private func lease(issuer: RCIREd25519Signer? = nil, subject: RCIREd25519Signer? = nil,
                       environment: UUID? = nil, runtime: String = "runtime:A", parent: CapabilityLease? = nil,
                       limits givenLimits: CapabilityLeaseLimits? = nil, capabilities: [String] = ["environment:execute", "environment:create-child"],
                       profiles: [String] = ["profile:challenge"], network: [String] = ["https://example.com"],
                       expiry: Int64 = 301_000) throws -> SignedCapabilityLease {
        let issuer = try issuer ?? key(1); let subject = try subject ?? key(2)
        let body = try CapabilityLease(leaseID: UUID(), issuerPublicKey: issuer.publicKey, subjectPublicKey: subject.publicKey,
                                      subjectRuntimeID: runtime, environmentID: environment ?? environmentA,
                                      parentLeaseID: parent?.leaseID, parentLeaseDigest: try parent?.digest(),
                                      issuingExecutionID: "execution:creation", capabilityIDs: capabilities, profileIDs: profiles,
                                      issuedAtMilliseconds: 1000, expiresAtMilliseconds: expiry,
                                      nonce: Data(repeating: 7, count: 32), limits: try givenLimits ?? limits(), networkAllowlist: network)
        return try .sign(body, using: issuer)
    }
    private func rootState(_ root: SignedCapabilityLease) throws -> CapabilityLeaseReservationState {
        var state = CapabilityLeaseReservationState()
        try state.registerRoot(root, trustedIssuerPublicKey: key(1).publicKey,
                               expectedSubjectPublicKey: key(2).publicKey, expectedSubjectRuntimeID: "runtime:A",
                               expectedEnvironmentID: environmentA, nowMilliseconds: 1000)
        return state
    }
    private func invocation(_ lease: CapabilityLease, id: UUID = UUID(), cost: Int64 = 10,
                            capability: String = "environment:execute", network: [String] = ["https://example.com"],
                            cpu: Int64 = 1, memory: Int64 = 512, digestByte: UInt8 = 1) throws -> CapabilityLeaseInvocation {
        try .init(reservationID: id, leaseID: lease.leaseID, requestDigest: Data(repeating: digestByte, count: 32),
                  capabilityID: capability, profileID: "profile:challenge", networkDestinations: network,
                  cpuCount: cpu, memoryMiB: memory, costUnits: cost)
    }
    private func reserve(_ invocation: CapabilityLeaseInvocation, state: inout CapabilityLeaseReservationState,
                         subject: RCIREd25519Signer? = nil, runtime: String = "runtime:A", environment: UUID? = nil,
                         now: Int64 = 1001) throws -> CapabilityLeaseReservation {
        try state.reserveExecution(invocation, authenticatedSubjectPublicKey: (subject ?? key(2)).publicKey,
                                   authenticatedRuntimeID: runtime, authenticatedEnvironmentID: environment ?? environmentA,
                                   trustedRootIssuerPublicKeys: [key(1).publicKey], nowMilliseconds: now)
    }
    private func allocate(_ child: SignedCapabilityLease, parent: CapabilityLease,
                          state: inout CapabilityLeaseReservationState, subject: RCIREd25519Signer? = nil,
                          runtime: String = "runtime:A", environment: UUID? = nil, now: Int64 = 1001) throws {
        try state.allocateDelegation(child, parentLeaseID: parent.leaseID,
                                     authenticatedSubjectPublicKey: (subject ?? key(2)).publicKey,
                                     authenticatedRuntimeID: runtime, authenticatedEnvironmentID: environment ?? environmentA,
                                     expectedChildSubjectPublicKey: child.body.subjectPublicKey,
                                     expectedChildRuntimeID: child.body.subjectRuntimeID,
                                     expectedChildEnvironmentID: child.body.environmentID,
                                     trustedRootIssuerPublicKeys: [key(1).publicKey], nowMilliseconds: now)
    }
    private func mutated(_ signed: SignedCapabilityLease, _ mutate: (inout [String: Any]) -> Void) throws -> SignedCapabilityLease {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(signed)) as! [String: Any]
        var body = object["body"] as! [String: Any]; mutate(&body); object["body"] = body
        return try JSONDecoder().decode(SignedCapabilityLease.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func assertLeaseError(_ expected: CapabilityLeaseError, _ operation: () throws -> Void,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? CapabilityLeaseError, expected, file: file, line: line)
        }
    }

    func testEd25519CanonicalLeaseAndSeparatelyPinnedIssuer() throws {
        let root = try lease()
        XCTAssertNoThrow(try root.verify(trustedIssuerPublicKey: key(1).publicKey, expectedSubjectPublicKey: key(2).publicKey,
                                        expectedSubjectRuntimeID: "runtime:A", expectedEnvironmentID: environmentA, nowMilliseconds: 1000))
        XCTAssertTrue(try root.body.canonicalData().starts(with: CapabilityLease.domain))
        XCTAssertEqual(try root.body.digest().count, 32)
        assertLeaseError(.untrustedIssuer) {
            try root.verifySignature(trustedIssuerPublicKey: key(8).publicKey)
        }
        let attacker = try lease(issuer: key(8))
        assertLeaseError(.untrustedIssuer) { try attacker.verifySignature(trustedIssuerPublicKey: key(1).publicKey) }
        XCTAssertThrowsError(try SignedCapabilityLease.sign(root.body, using: key(8)))
    }

    func testEverySignedFieldMutationIsRejected() throws {
        let parent = try lease()
        let signed = try lease(issuer: key(2), subject: key(3), environment: environmentB, runtime: "runtime:B", parent: parent.body,
                               limits: limits(executions: 2, children: 1, descendants: 1, depth: 1, cpu: 1, memory: 512, cost: 100))
        let changes: [(String, Any)] = [
            ("leaseID", UUID().uuidString), ("issuerPublicKey", try key(8).publicKey.base64EncodedString()),
            ("subjectPublicKey", try key(8).publicKey.base64EncodedString()), ("subjectRuntimeID", "runtime:evil"),
            ("environmentID", environmentC.uuidString), ("parentLeaseID", UUID().uuidString),
            ("parentLeaseDigest", Data(repeating: 9, count: 32).base64EncodedString()),
            ("issuingExecutionID", "execution:other"), ("capabilityIDs", ["environment:destroy"]),
            ("profileIDs", ["profile:other"]), ("issuedAtMilliseconds", 1001), ("expiresAtMilliseconds", 301001),
            ("nonce", Data(repeating: 9, count: 32).base64EncodedString()), ("networkAllowlist", ["https://other.example"])
        ]
        for (field, value) in changes {
            let altered = try mutated(signed) { $0[field] = value }
            XCTAssertThrowsError(try altered.verifySignature(trustedIssuerPublicKey: key(2).publicKey), field)
        }
        for field in ["maximumExecutions", "maximumChildren", "maximumDescendants", "delegationDepth", "cpuCount", "memoryMiB", "maximumCostUnits", "costUnit"] {
            let altered = try mutated(signed) {
                var quota = $0["limits"] as! [String: Any]
                quota[field] = field == "costUnit" ? "usd" : (quota[field] as! NSNumber).int64Value + 1
                $0["limits"] = quota
            }
            XCTAssertThrowsError(try altered.verifySignature(trustedIssuerPublicKey: key(2).publicKey), field)
        }
        var signature = signed.signature; signature[0] ^= 1
        assertLeaseError(.invalidSignature) {
            try SignedCapabilityLease(body: signed.body, signature: signature).verifySignature(trustedIssuerPublicKey: key(2).publicKey)
        }
    }

    func testStrictFiniteLimitsAndExactNetworkOrigins() throws {
        for bad in [-1, 4097, Int64.max] {
            XCTAssertThrowsError(try limits(executions: bad))
        }
        XCTAssertThrowsError(try limits(depth: 3)); XCTAssertThrowsError(try limits(cpu: 5))
        XCTAssertThrowsError(try limits(memory: 4097)); XCTAssertThrowsError(try limits(cost: 1_000_001))
        XCTAssertThrowsError(try limits(children: 1, descendants: 0))
        XCTAssertThrowsError(try limits(children: 1, descendants: 1, depth: 0))
        for origin in ["http://example.com", "https://EXAMPLE.com", "https://*.example.com", "https://example.com/",
                       "https://example.com:443", "https://user@example.com", "https://example.com?x=1", "https://example%2ecom"] {
            XCTAssertThrowsError(try lease(network: [origin]), origin)
        }
        XCTAssertThrowsError(try lease(capabilities: ["environment:*", "environment:execute"]))
        XCTAssertThrowsError(try lease(capabilities: ["environment:execute", "environment:execute"]))
        XCTAssertThrowsError(try lease(expiry: 3_601_001))
        let decoded = try mutated(lease()) { $0["capabilityIDs"] = ["environment:execute", "environment:create-child"] }
        XCTAssertThrowsError(try decoded.verifySignature(trustedIssuerPublicKey: key(1).publicKey))
    }

    func testBearerLeaseDoesNotAuthorizeOtherSubjectRuntimeOrEnvironment() throws {
        let signed = try lease(); let request = try invocation(signed.body)
        var state = try rootState(signed); let original = state
        assertLeaseError(.subjectMismatch) { _ = try reserve(request, state: &state, subject: key(8)) }
        assertLeaseError(.subjectMismatch) { _ = try reserve(request, state: &state, runtime: "runtime:other") }
        assertLeaseError(.environmentMismatch) { _ = try reserve(request, state: &state, environment: environmentB) }
        XCTAssertEqual(state, original)
    }

    func testExpiryFutureIssueAndClockRollbackFailClosed() throws {
        let root = try lease(); var state = try rootState(root)
        let first = try invocation(root.body)
        _ = try reserve(first, state: &state, now: 1100)
        let original = state
        assertLeaseError(.clockRollback) { _ = try reserve(invocation(root.body), state: &state, now: 1099) }
        assertLeaseError(.expired) { _ = try reserve(first, state: &state, now: 301000) }
        XCTAssertEqual(state, original)
        assertLeaseError(.futureIssued) {
            try root.verify(trustedIssuerPublicKey: key(1).publicKey, expectedSubjectPublicKey: key(2).publicKey,
                            expectedSubjectRuntimeID: "runtime:A", expectedEnvironmentID: environmentA, nowMilliseconds: 999)
        }
    }

    func testDelegationAttenuatesAndSiblingAllocationsAreDisjoint() throws {
        let root = try lease(limits: limits(executions: 6, children: 2, descendants: 4, cost: 200))
        var state = try rootState(root)
        let childLimits = try limits(executions: 4, children: 1, descendants: 1, depth: 1, cpu: 1, memory: 512, cost: 120)
        let child = try lease(issuer: key(2), subject: key(3), environment: environmentB, runtime: "runtime:B", parent: root.body,
                              limits: childLimits)
        try allocate(child, parent: root.body, state: &state)
        XCTAssertEqual(state.budget(for: root.body.leaseID)?.remainingExecutions, 2)
        XCTAssertEqual(state.budget(for: root.body.leaseID)?.remainingChildren, 1)
        XCTAssertEqual(state.budget(for: root.body.leaseID)?.remainingDescendants, 2)
        XCTAssertEqual(state.budget(for: root.body.leaseID)?.remainingCostUnits, 80)
        let sibling = try lease(issuer: key(2), subject: key(4), environment: environmentC, runtime: "runtime:C", parent: root.body,
                                limits: childLimits)
        let original = state
        assertLeaseError(.insufficientBudget) { try allocate(sibling, parent: root.body, state: &state) }
        XCTAssertEqual(state, original)
        try allocate(child, parent: root.body, state: &state)
        XCTAssertEqual(state, original)
        try state.validate(trustedRootIssuerPublicKeys: [key(1).publicKey])
    }

    func testDirectChildCountAndAllocatedDescendantCapacityCannotBeReused() throws {
        let root = try lease(limits: limits(children: 1, descendants: 2))
        var state = try rootState(root)
        let quota = try limits(executions: 1, children: 1, descendants: 1, depth: 1, cpu: 1, memory: 512, cost: 20)
        let child = try lease(issuer: key(2), subject: key(3), environment: environmentB, runtime: "runtime:B", parent: root.body, limits: quota)
        try allocate(child, parent: root.body, state: &state)
        let second = try lease(issuer: key(2), subject: key(4), environment: environmentC, runtime: "runtime:C", parent: root.body, limits: quota)
        assertLeaseError(.insufficientBudget) { try allocate(second, parent: root.body, state: &state) }
        let leaf = try lease(issuer: key(3), subject: key(4), environment: environmentC, runtime: "runtime:C", parent: child.body,
                             limits: limits(executions: 1, children: 0, descendants: 0, depth: 0, cpu: 1, memory: 512, cost: 10))
        try allocate(leaf, parent: child.body, state: &state, subject: key(3), runtime: "runtime:B", environment: environmentB)
        XCTAssertEqual(state.budget(for: root.body.leaseID)?.remainingDescendants, 0)
        XCTAssertEqual(state.budget(for: child.body.leaseID)?.remainingDescendants, 0)
        XCTAssertEqual(state.budget(for: leaf.body.leaseID)?.remainingExecutions, 1)
        let impossible = try lease(issuer: key(4), subject: key(5), runtime: "runtime:D", parent: leaf.body,
                                   limits: limits(executions: 0, children: 0, descendants: 0, depth: 0, cpu: 1, memory: 512, cost: 0))
        assertLeaseError(.authorityAmplification) {
            try allocate(impossible, parent: leaf.body, state: &state, subject: key(4), runtime: "runtime:C", environment: environmentC)
        }
        try state.validate(trustedRootIssuerPublicKeys: [key(1).publicKey])
    }

    func testSignedChildWideningAndWrongParentAreRejected() throws {
        let root = try lease(); var state = try rootState(root)
        let quota = try limits(executions: 2, children: 0, descendants: 0, depth: 0, cpu: 1, memory: 512, cost: 20)
        let widening = [
            try lease(issuer: key(2), subject: key(3), parent: root.body, limits: quota, capabilities: ["environment:destroy"]),
            try lease(issuer: key(2), subject: key(3), parent: root.body, limits: quota, profiles: ["profile:other"]),
            try lease(issuer: key(2), subject: key(3), parent: root.body, limits: quota, network: ["https://other.example"]),
            try lease(issuer: key(2), subject: key(3), parent: root.body, limits: quota, expiry: 301001),
            try lease(issuer: key(2), subject: key(3), parent: root.body, limits: limits(cpu: 3)),
            try lease(issuer: key(2), subject: key(3), parent: root.body, limits: limits(memory: 2048)),
            try lease(issuer: key(2), subject: key(3), parent: root.body, limits: limits(cost: 401)),
            try lease(issuer: key(2), subject: key(3), parent: root.body, limits: limits())
        ]
        let original = state
        for signed in widening { assertLeaseError(.authorityAmplification) { try allocate(signed, parent: root.body, state: &state) } }
        let unrelated = try lease()
        let wrongParent = try lease(issuer: key(2), subject: key(3), parent: unrelated.body, limits: quota)
        assertLeaseError(.parentMismatch) { try allocate(wrongParent, parent: root.body, state: &state) }
        XCTAssertEqual(state, original)
    }

    func testReservationCostExecutionAndIntentReplaySurviveCodableRecovery() throws {
        let root = try lease(limits: limits(executions: 2, cost: 15)); var state = try rootState(root)
        let request = try invocation(root.body, cost: 10)
        XCTAssertFalse(try reserve(request, state: &state).alreadyReserved)
        state = try JSONDecoder().decode(CapabilityLeaseReservationState.self, from: JSONEncoder().encode(state))
        try state.validate(trustedRootIssuerPublicKeys: [key(1).publicKey])
        XCTAssertTrue(try reserve(request, state: &state).alreadyReserved)
        XCTAssertEqual(state.budget(for: root.body.leaseID)?.remainingExecutions, 1)
        XCTAssertEqual(state.budget(for: root.body.leaseID)?.remainingCostUnits, 5)
        let original = state
        assertLeaseError(.reservationConflict) {
            _ = try reserve(invocation(root.body, id: request.reservationID, cost: 10, digestByte: 2), state: &state)
        }
        assertLeaseError(.insufficientBudget) { _ = try reserve(invocation(root.body, cost: 6), state: &state) }
        XCTAssertEqual(state, original)
        _ = try reserve(invocation(root.body, cost: 5), state: &state)
        assertLeaseError(.insufficientBudget) { _ = try reserve(invocation(root.body, cost: 0), state: &state) }
    }

    func testInvocationScopeAndShapeAreRecheckedAtAdmission() throws {
        let root = try lease(limits: limits(cpu: 1, memory: 512)); var state = try rootState(root); let original = state
        for request in [try invocation(root.body, capability: "environment:destroy"),
                        try invocation(root.body, network: ["https://other.example"]),
                        try invocation(root.body, cpu: 2), try invocation(root.body, memory: 1024)] {
            assertLeaseError(.authorityAmplification) { _ = try reserve(request, state: &state) }
        }
        XCTAssertEqual(state, original)
    }

    func testAncestorRevocationRejectsDescendantAndPriorReservationRetries() throws {
        let root = try lease(); var state = try rootState(root)
        let child = try lease(issuer: key(2), subject: key(3), environment: environmentB, runtime: "runtime:B", parent: root.body,
                              limits: limits(executions: 2, children: 0, descendants: 0, depth: 0, cpu: 1, memory: 512, cost: 20))
        try allocate(child, parent: root.body, state: &state)
        let request = try invocation(child.body)
        _ = try reserve(request, state: &state, subject: key(3), runtime: "runtime:B", environment: environmentB)
        try state.revoke(leaseID: root.body.leaseID)
        assertLeaseError(.revoked) {
            _ = try reserve(request, state: &state, subject: key(3), runtime: "runtime:B", environment: environmentB)
        }
        XCTAssertEqual(state.leaseCount, 2); XCTAssertEqual(state.reservationCount, 1)
        state = try JSONDecoder().decode(CapabilityLeaseReservationState.self, from: JSONEncoder().encode(state))
        assertLeaseError(.revoked) {
            _ = try reserve(invocation(child.body), state: &state, subject: key(3), runtime: "runtime:B", environment: environmentB)
        }
    }

    func testRecoveryRejectsTamperedBudgetsAndUnpinnedRoot() throws {
        let root = try lease(); var state = try rootState(root)
        _ = try reserve(invocation(root.body), state: &state)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        var budgets = json["budgets"] as! [String: Any]; var record = budgets[root.body.leaseID.uuidString] as! [String: Any]
        record["remainingExecutions"] = 8; budgets[root.body.leaseID.uuidString] = record; json["budgets"] = budgets
        let tampered = try JSONDecoder().decode(CapabilityLeaseReservationState.self, from: JSONSerialization.data(withJSONObject: json))
        assertLeaseError(.malformedState) { try tampered.validate(trustedRootIssuerPublicKeys: [key(1).publicKey]) }
        assertLeaseError(.untrustedIssuer) { try state.validate(trustedRootIssuerPublicKeys: [key(8).publicKey]) }
        let before = state
        assertLeaseError(.malformedState) {
            var candidate = tampered
            _ = try reserve(invocation(root.body), state: &candidate)
        }
        XCTAssertEqual(state, before)
    }
}
