import Foundation
import XCTest
import RightClickProtocol
import RightClickCore
import RightClickProviders

/// Attacks enter the production broker, protected journal and signed validators.
/// The deterministic substrate provides faults, not an alternative adjudicator.
final class NestedAdversarialTests: XCTestCase {
    private final class Clock { var value: Int64 = 1_000_000 }

    private final class Fixture {
        let clock = Clock()
        let host: RCIREd25519Signer
        let provider: InMemoryEnvironmentProvider
        let cleanupDirectory: URL
        let directory: URL
        let manifest: EnvironmentRuntimeManifest
        let ceiling: EnvironmentSpec
        var coordinator: EnvironmentCoordinator!

        init() throws {
            host = try RCIREd25519Signer(rawPrivateKey: Data(repeating: 81, count: 32))
            cleanupDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("nested-adversarial-" + UUID().uuidString).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: cleanupDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            directory = cleanupDirectory.appendingPathComponent("journal")
            manifest = try .init(version: "test-v1", executableSHA256: String(repeating: "a", count: 64), architecture: "arm64")
            ceiling = try .init(profileID: "linux-small", lifetimeMilliseconds: 120_000,
                resources: .init(cpuCount: 2, memoryMiB: 512, maximumCostUnits: 10_000))
            let clock = self.clock
            provider = try .init(clock: { clock.value })
            coordinator = try reopen()
        }
        deinit { try? FileManager.default.removeItem(at: cleanupDirectory) }

        func reopen() throws -> EnvironmentCoordinator {
            let clock = self.clock, host = self.host
            return try .init(provider: provider, journalDirectory: directory,
                hostRuntimeID: "runtime:" + ExecutionEvidenceDigest.sha256(host.publicKey),
                trustedRootIssuerPublicKeys: [host.publicKey], profiles: ["linux-small": manifest],
                profileCeilings: ["linux-small": ceiling], operatorPublicKey: host.publicKey,
                maximumEnvironments: 8, maximumTotalCostUnits: 100_000,
                enrollmentVerifier: { _, _, _, observation, response in
                    // Core's injected host enrollment boundary authenticates the
                    // real provider-held key. Core still enforces its exact pins.
                    // Link's production verifier has its own direct attack suite.
                    let runtime = try XCTUnwrap(observation.runtime)
                    let claim = try SignedChildRuntimeClaim.decode(response).verify(trustedPublicKey: runtime.publicKey)
                    let certificate = try ChildRuntimeEnrollmentCertificate(claim: claim, issuerPublicKey: host.publicKey,
                        environmentObservedAtMilliseconds: observation.observedAtMilliseconds,
                        runtimeObservedAtMilliseconds: runtime.observedAtMilliseconds, verifiedAtMilliseconds: clock.value,
                        environmentObservationBoundary: observation.observationBoundary,
                        runtimeObservationBoundary: runtime.observationBoundary)
                    return try .sign(certificate, using: host)
                }, now: { clock.value })
        }
        func root(executionID: String = UUID().uuidString, byte: UInt8 = 1) throws -> EnvironmentAdmissionContext {
            try coordinator.rootAdmission(executionID: executionID, requestDigest: Data(repeating: byte, count: 32))
        }
        func spec(lifetime: Int64 = 120_000, cpu: Int = 1, memory: Int = 256, cost: Int64 = 100) throws -> EnvironmentSpec {
            try .init(profileID: "linux-small", lifetimeMilliseconds: lifetime,
                resources: .init(cpuCount: cpu, memoryMiB: memory, maximumCostUnits: cost))
        }
        func create(lifetime: Int64 = 120_000, admission: EnvironmentAdmissionContext? = nil) throws -> EnvironmentRecord {
            try coordinator.create(spec: spec(lifetime: lifetime), correlationID: UUID().uuidString,
                admission: admission ?? root(), confirmed: true)
        }
        func bootstrap(_ record: EnvironmentRecord) throws -> EnvironmentRecord {
            try coordinator.bootstrap(environmentID: record.environmentID, admission: root(), confirmed: true)
        }
        func claim(_ record: EnvironmentRecord) throws -> SignedChildRuntimeClaim {
            let handle = try XCTUnwrap(coordinator.record(environmentID: record.environmentID)?.handle)
            let runtime = try XCTUnwrap(provider.observe(correlationID: handle.correlationID).runtime)
            let challenge = try XCTUnwrap(coordinator.enrollmentChallenge(environmentID: record.environmentID))
            return try provider.signedRuntimeClaim(.init(enrollmentID: challenge.enrollmentID, handle: handle,
                manifest: manifest, publicKey: runtime.publicKey, challenge: challenge.challenge,
                issuedAtMilliseconds: clock.value, expiresAtMilliseconds: challenge.expiresAtMilliseconds))
        }
        func enroll(_ record: EnvironmentRecord) throws -> EnvironmentRecord {
            try coordinator.enroll(environmentID: record.environmentID, response: claim(record).wireData())
        }
        func ready(lifetime: Int64 = 120_000, admission: EnvironmentAdmissionContext? = nil) throws -> EnvironmentRecord {
            try enroll(bootstrap(create(lifetime: lifetime, admission: admission)))
        }
        func limits(executions: Int64 = 16, children: Int64 = 1, descendants: Int64 = 2, depth: Int64 = 2,
                    cpu: Int64 = 2, memory: Int64 = 512, cost: Int64 = 2_000) throws -> CapabilityLeaseLimits {
            try .init(maximumExecutions: executions, maximumChildren: children, maximumDescendants: descendants,
                delegationDepth: depth, cpuCount: cpu, memoryMiB: memory, maximumCostUnits: cost)
        }
        func grant(_ record: EnvironmentRecord, capabilities: [String] = ["environment:execute", "environment:create-child", "environment:destroy"],
                   limits: CapabilityLeaseLimits? = nil, expiry: Int64? = nil, install: Bool = true) throws -> SignedCapabilityLease {
            let runtime = try XCTUnwrap(record.runtime)
            let body = try CapabilityLease(leaseID: UUID(), issuerPublicKey: host.publicKey,
                subjectPublicKey: runtime.publicKey, subjectRuntimeID: runtime.runtimeID,
                environmentID: XCTUnwrap(UUID(uuidString: record.environmentID)), issuingExecutionID: record.intent.creationExecutionID,
                capabilityIDs: capabilities, profileIDs: ["linux-small"], issuedAtMilliseconds: clock.value,
                expiresAtMilliseconds: expiry ?? record.intent.expiresAtMilliseconds, nonce: Data(repeating: 12, count: 32),
                limits: limits ?? self.limits(), networkAllowlist: [])
            let signed = try SignedCapabilityLease.sign(body, using: host)
            if install { try coordinator.installSignedLease(signed) }
            return signed
        }
        func child(_ record: EnvironmentRecord, lease: SignedCapabilityLease,
                   executionID: String = UUID().uuidString, byte: UInt8 = 2) throws -> EnvironmentAdmissionContext {
            let runtime = try XCTUnwrap(record.runtime)
            return try coordinator.authenticatedAdmission(executionID: executionID, requestDigest: Data(repeating: byte, count: 32),
                subjectPublicKey: runtime.publicKey, runtimeID: runtime.runtimeID, environmentID: record.environmentID, leaseID: lease.body.leaseID)
        }
        func execute(_ record: EnvironmentRecord, lease: SignedCapabilityLease, challenge: String = "fresh-random-challenge",
                     admission: EnvironmentAdmissionContext? = nil) throws -> ExecutionRecord {
            try coordinator.executeChallenge(environmentID: record.environmentID, challenge: challenge,
                admission: admission ?? child(record, lease: lease), confirmed: true)
        }
        func proof(_ execution: ExecutionRecord, reportedValue: String = "fresh-random-challenge", sequence: Int64 = 1) throws -> SignedExecutionProof {
            let expectation = try coordinator.proofExpectation(executionID: execution.executionId)
            let proof = try ExecutionProof(binding: expectation.binding, challengeNonce: expectation.challengeNonce,
                issuedAtMilliseconds: clock.value, observedAtMilliseconds: clock.value,
                expiresAtMilliseconds: expectation.deadlineMilliseconds, sequence: sequence,
                predicateID: expectation.predicateID, providerAccepted: true, reportedOutcome: .succeeded,
                reportedValue: .string(reportedValue), reportBoundary: "Signed simulated child assertion; not independent evidence.")
            return try provider.signedExecutionProof(proof)
        }
        func delegation(_ child: EnvironmentRecord, parent: EnvironmentRecord, lease: SignedCapabilityLease,
                        limits: CapabilityLeaseLimits, expiry: Int64? = nil,
                        capabilities: [String]? = nil) throws -> SignedCapabilityLease {
            let runtime = try XCTUnwrap(child.runtime), parentRuntime = try XCTUnwrap(parent.runtime)
            let body = try CapabilityLease(leaseID: UUID(), issuerPublicKey: parentRuntime.publicKey,
                subjectPublicKey: runtime.publicKey, subjectRuntimeID: runtime.runtimeID,
                environmentID: XCTUnwrap(UUID(uuidString: child.environmentID)), parentLeaseID: lease.body.leaseID,
                parentLeaseDigest: lease.body.digest(), issuingExecutionID: child.intent.creationExecutionID,
                capabilityIDs: capabilities ?? lease.body.capabilityIDs, profileIDs: ["linux-small"],
                issuedAtMilliseconds: clock.value, expiresAtMilliseconds: expiry ?? child.intent.expiresAtMilliseconds,
                nonce: Data(repeating: 13, count: 32), limits: limits, networkAllowlist: [])
            return try provider.signedCapabilityLease(body, issuerEnvironmentID: parent.environmentID)
        }
        func nested() throws -> (EnvironmentRecord, SignedCapabilityLease, EnvironmentRecord, SignedCapabilityLease) {
            let a = try ready(), leaseA = try grant(a)
            let b = try ready(lifetime: 60_000, admission: child(a, lease: leaseA))
            let leaseB = try delegation(b, parent: a, lease: leaseA,
                limits: limits(executions: 8, children: 1, descendants: 1, depth: 1, cpu: 1, memory: 256, cost: 500))
            try coordinator.delegateSignedLease(leaseB, parentLeaseID: leaseA.body.leaseID, admission: child(a, lease: leaseA))
            return (a, leaseA, b, leaseB)
        }
        var effectCount: Int { provider.operationLog.count }
    }

    private func mutate<T: Codable>(_ value: T, path: [String], replacement: Any) throws -> T {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        func update(_ object: inout [String: Any], _ path: ArraySlice<String>) throws {
            let key = try XCTUnwrap(path.first)
            if path.count == 1 { object[key] = replacement; return }
            var child = try XCTUnwrap(object[key] as? [String: Any]); try update(&child, path.dropFirst()); object[key] = child
        }
        try update(&object, path[...])
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testForgedLeaseCannotInstallOrCauseAnyProviderEffect() throws {
        let f = try Fixture(), a = try f.ready(), signed = try f.grant(a, install: false)
        let forged = try SignedCapabilityLease(body: signed.body, signature: Data(repeating: 0, count: 64))
        let effects = f.effectCount
        XCTAssertThrowsError(try f.coordinator.installSignedLease(forged))
        XCTAssertThrowsError(try f.child(a, lease: forged))
        XCTAssertEqual(f.effectCount, effects)
        XCTAssertEqual(try f.coordinator.record(environmentID: a.environmentID)?.leaseIDs.count, 0)
    }

    func testExpiredAndRevokedLeasesRejectAlreadyAuthenticatedAdmission() throws {
        let f = try Fixture(), a = try f.ready(), lease = try f.grant(a, expiry: f.clock.value + 1_000)
        let admitted = try f.child(a, lease: lease), effects = f.effectCount
        f.clock.value += 1_000
        XCTAssertThrowsError(try f.execute(a, lease: lease, admission: admitted))
        XCTAssertEqual(f.effectCount, effects)
        let cleanup = try f.coordinator.destroy(environmentID: a.environmentID, admission: f.root(), confirmed: true)
        XCTAssertEqual(cleanup.state, .destroyed)
        let afterCleanup = f.effectCount
        XCTAssertThrowsError(try f.execute(a, lease: lease, admission: admitted))
        XCTAssertThrowsError(try f.child(a, lease: lease))
        XCTAssertEqual(f.effectCount, afterCleanup)
    }

    func testSignedScopeCostAndResourceCeilingsDenyBeforeDispatch() throws {
        let f = try Fixture(), a = try f.ready()
        let lease = try f.grant(a, capabilities: ["environment:execute"],
            limits: f.limits(children: 0, descendants: 0, depth: 0, cpu: 1, memory: 256, cost: 100))
        let effects = f.effectCount
        XCTAssertThrowsError(try f.create(lifetime: 30_000, admission: f.child(a, lease: lease)))
        XCTAssertThrowsError(try f.coordinator.destroy(environmentID: a.environmentID, admission: f.child(a, lease: lease), confirmed: true))
        XCTAssertEqual(f.effectCount, effects)
        XCTAssertEqual(try f.coordinator.records().count, 1)
        // A scope that permits creation still cannot exceed its reserved spend.
        let f2 = try Fixture()
        let a2 = try f2.enroll(f2.bootstrap(f2.coordinator.create(spec: f2.spec(cost: 50),
            correlationID: UUID().uuidString, admission: f2.root(), confirmed: true)))
        let lease2 = try f2.grant(a2, limits: f2.limits(cpu: 1, memory: 256, cost: 50))
        for spec in [try f2.spec(lifetime: 30_000, cost: 51), try f2.spec(lifetime: 30_000, cpu: 2, cost: 1),
                     try f2.spec(lifetime: 30_000, memory: 512, cost: 1)] {
            let before = f2.effectCount
            XCTAssertThrowsError(try f2.coordinator.create(spec: spec, correlationID: UUID().uuidString,
                admission: f2.child(a2, lease: lease2), confirmed: true))
            XCTAssertEqual(f2.effectCount, before)
        }
    }

    func testExecutionReplayAcrossBrokerRestartHasExactlyOneEffect() throws {
        let f = try Fixture(), a = try f.ready(), lease = try f.grant(a)
        let id = UUID().uuidString, admission = try f.child(a, lease: lease, executionID: id)
        let first = try f.execute(a, lease: lease, admission: admission)
        XCTAssertEqual(first.state, .accepted)
        f.coordinator = try f.reopen()
        let retry = try f.child(a, lease: lease, executionID: id)
        _ = try f.execute(a, lease: lease, admission: retry)
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("challenge:") }.count, 1)
        XCTAssertThrowsError(try f.execute(a, lease: lease, challenge: "different-challenge", admission: retry))
        let changedRequest = try f.child(a, lease: lease, executionID: id, byte: 9)
        XCTAssertThrowsError(try f.execute(a, lease: lease, admission: changedRequest))
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("challenge:") }.count, 1)
    }

    func testClockRollbackDeniesAdmissionAndDiscoveryAcrossRestart() throws {
        let f = try Fixture(), a = try f.ready(), lease = try f.grant(a)
        f.clock.value += 500
        _ = try f.execute(a, lease: lease)
        let effects = f.effectCount
        f.clock.value -= 1
        XCTAssertThrowsError(try f.child(a, lease: lease))
        XCTAssertFalse(try f.coordinator.canDiscover(capabilityID: "environment:execute", environmentID: a.environmentID,
            subjectPublicKey: XCTUnwrap(a.runtime).publicKey, runtimeID: XCTUnwrap(a.runtime).runtimeID, leaseID: lease.body.leaseID))
        f.coordinator = try f.reopen()
        XCTAssertThrowsError(try f.child(a, lease: lease))
        XCTAssertThrowsError(try f.create())
        XCTAssertEqual(f.effectCount, effects)
    }

    func testDiscoveryWithdrawsConsumedChildBudgetAndRevokedWorkloadAuthority() throws {
        let f = try Fixture(), a = try f.ready(), lease = try f.grant(a), runtime = try XCTUnwrap(a.runtime)
        func discover(_ capability: String) throws -> Bool {
            try f.coordinator.canDiscover(capabilityID: capability, environmentID: a.environmentID,
                subjectPublicKey: runtime.publicKey, runtimeID: runtime.runtimeID, leaseID: lease.body.leaseID)
        }
        XCTAssertTrue(try discover("environment:create-child"))
        _ = try f.create(lifetime: 30_000, admission: f.child(a, lease: lease))
        XCTAssertFalse(try discover("environment:create-child"))
        XCTAssertTrue(try discover("environment:execute"))
        f.provider.configureFaults { $0.partitioned = true }
        _ = try f.coordinator.destroy(environmentID: a.environmentID, admission: f.root(), confirmed: true)
        XCTAssertFalse(try discover("environment:execute"))
        XCTAssertFalse(try discover("environment:create-child"))
    }

    func testProviderAcceptanceAndSignedChildSuccessCannotHideFalsePostcondition() throws {
        let f = try Fixture(), a = try f.ready(), lease = try f.grant(a)
        f.provider.configureFaults { $0.observedChallengeOverride = "false-postcondition" }
        let execution = try f.execute(a, lease: lease), proof = try f.proof(execution)
        XCTAssertEqual(execution.state, .accepted)
        let certificate = try f.coordinator.adjudicateProof(proof, hostSigner: f.host)
        XCTAssertEqual(certificate.verification.outcome, .failed)
        XCTAssertEqual(try f.coordinator.executionRecord(execution.executionId)?.state, .failed)
        XCTAssertNotEqual(certificate.verification.observedValueDigest, certificate.verification.expectedValueDigest)
    }

    func testChildLieAndMissingExternalEffectNeverBecomeSemanticSuccess() throws {
        let f = try Fixture(), a = try f.ready(), lease = try f.grant(a)
        f.provider.configureFaults { $0.suppressChallengeEffect = true; $0.reportedChallengeOverride = "I-did-it" }
        let execution = try f.execute(a, lease: lease), proof = try f.proof(execution, reportedValue: "I-did-it")
        let certificate = try f.coordinator.adjudicateProof(proof, hostSigner: f.host)
        XCTAssertEqual(certificate.verification.outcome, .unknown)
        XCTAssertEqual(try f.coordinator.executionRecord(execution.executionId)?.state, .unknown)
        let lie = ExecutionRecord(executionId: execution.executionId, actionId: "environment:execute", state: .succeeded,
            message: "Child claims success.")
        XCTAssertThrowsError(try f.coordinator.storeExecutionRecord(lie))
        XCTAssertNotEqual(try f.coordinator.executionRecord(execution.executionId)?.state, .succeeded)
    }

    func testModifiedSignedEvidenceAndReorderedSequenceDoNotConsumeValidProof() throws {
        let f = try Fixture(), a = try f.ready(), lease = try f.grant(a), execution = try f.execute(a, lease: lease)
        let original = try f.proof(execution)
        let modified = try mutate(original, path: ["proof", "reportBoundary"], replacement: "forged report")
        XCTAssertThrowsError(try f.coordinator.adjudicateProof(modified, hostSigner: f.host))
        XCTAssertThrowsError(try f.coordinator.adjudicateProof(f.proof(execution, sequence: 2), hostSigner: f.host))
        XCTAssertNil(try f.coordinator.evidence(executionID: execution.executionId).0)
        XCTAssertEqual(try f.coordinator.adjudicateProof(original, hostSigner: f.host).verification.outcome, .succeeded)
        XCTAssertThrowsError(try f.coordinator.adjudicateProof(original, hostSigner: f.host))
        f.coordinator = try f.reopen()
        XCTAssertThrowsError(try f.coordinator.adjudicateProof(original, hostSigner: f.host))
    }

    func testStaleProofCannotUsePreviouslyObservableChallenge() throws {
        let f = try Fixture(), a = try f.ready(), lease = try f.grant(a, expiry: f.clock.value + 1_000)
        let execution = try f.execute(a, lease: lease), proof = try f.proof(execution)
        f.clock.value += 1_000
        XCTAssertThrowsError(try f.coordinator.adjudicateProof(proof, hostSigner: f.host))
        XCTAssertEqual(try f.coordinator.verifyChallenge(executionID: execution.executionId).state, .unknown)
        XCTAssertNil(try f.coordinator.evidence(executionID: execution.executionId).1)
    }

    func testExecutionPartitionPreservesUnknownAndRecoveryDoesNotRedispatch() throws {
        let f = try Fixture(), a = try f.ready(), lease = try f.grant(a)
        f.provider.configureFaults { $0.partitionAfterChallengeAcceptanceOnce = true }
        let execution = try f.execute(a, lease: lease)
        XCTAssertEqual(execution.state, .accepted)
        XCTAssertEqual(try f.coordinator.verifyChallenge(executionID: execution.executionId).state, .unknown)
        f.provider.configureFaults { $0.partitioned = false }
        f.coordinator = try f.reopen()
        _ = try f.coordinator.observe(environmentID: a.environmentID)
        let retry = try f.child(a, lease: lease, executionID: execution.executionId)
        XCTAssertEqual(try f.execute(a, lease: lease, admission: retry).state, .unknown)
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("challenge:") }.count, 1)
        XCTAssertEqual(try f.coordinator.verifyChallenge(executionID: execution.executionId).state, .succeeded)
    }

    func testPartitionBeforeDispatchWithdrawsRuntimeAuthorityWithoutEffects() throws {
        let f = try Fixture(), a = try f.ready(), lease = try f.grant(a)
        let admission = try f.child(a, lease: lease)
        f.provider.configureFaults { $0.partitioned = true }
        XCTAssertThrowsError(try f.execute(a, lease: lease, admission: admission))
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("challenge:") }.count, 0)
        XCTAssertEqual(try f.coordinator.record(environmentID: a.environmentID)?.state, .unknown)
    }

    func testCreatePartitionDoesNotBecomeAbsentOrRetryAnUncertainEffect() throws {
        let f = try Fixture(), correlation = UUID().uuidString, id = UUID().uuidString
        f.provider.configureFaults { $0.partitioned = true }
        let uncertain = try f.coordinator.create(spec: f.spec(), correlationID: correlation,
            admission: f.root(executionID: id), confirmed: true)
        XCTAssertEqual(uncertain.state, .unknown)
        XCTAssertEqual(uncertain.observation?.presence, .unknown)
        f.provider.configureFaults { $0.partitioned = false }
        f.coordinator = try f.reopen()
        let retry = try f.coordinator.create(spec: f.spec(), correlationID: correlation,
            admission: f.root(executionID: id), confirmed: true)
        XCTAssertEqual(retry.state, .unknown)
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("create:") }.count, 0)
    }

    func testLostCreateAcceptanceAndRestartRetainOneCorrelatedResource() throws {
        let f = try Fixture(), correlation = UUID().uuidString, id = UUID().uuidString
        f.provider.configureFaults { $0.createAcceptedThenCrashOnce = true }
        let created = try f.coordinator.create(spec: f.spec(), correlationID: correlation,
            admission: f.root(executionID: id), confirmed: true)
        XCTAssertEqual(created.acceptance?.acceptance, .unknown)
        XCTAssertEqual(created.observation?.presence, .present)
        f.coordinator = try f.reopen()
        let retry = try f.coordinator.create(spec: f.spec(), correlationID: correlation,
            admission: f.root(executionID: id), confirmed: true)
        XCTAssertEqual(retry.environmentID, created.environmentID)
        XCTAssertEqual(retry.handle?.providerResourceID, created.handle?.providerResourceID)
        XCTAssertEqual(try f.provider.list().count, 1)
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("create:") }.count, 1)
        XCTAssertThrowsError(try f.coordinator.create(spec: f.spec(cost: 101), correlationID: correlation,
            admission: f.root(executionID: id), confirmed: true))
        XCTAssertThrowsError(try f.coordinator.create(spec: f.spec(), correlationID: correlation,
            admission: f.root(), confirmed: true))
    }

    func testTeardownPartitionRevokesAuthorityAndDoesNotFalselyConfirmAbsence() throws {
        let f = try Fixture(), a = try f.ready(), lease = try f.grant(a)
        let admitted = try f.child(a, lease: lease)
        f.provider.configureFaults { $0.partitioned = true }
        let pending = try f.coordinator.destroy(environmentID: a.environmentID, admission: f.root(), confirmed: true)
        XCTAssertEqual(pending.state, .unknown)
        XCTAssertEqual(pending.observation?.presence, .unknown)
        XCTAssertTrue(pending.revoked)
        XCTAssertNil(pending.runtime)
        let effects = f.effectCount
        XCTAssertThrowsError(try f.execute(a, lease: lease, admission: admitted))
        XCTAssertEqual(f.effectCount, effects)
        f.coordinator = try f.reopen()
        f.provider.configureFaults { $0.partitioned = false }
        _ = try f.coordinator.reconcile()
        XCTAssertEqual(try f.coordinator.record(environmentID: a.environmentID)?.state, .destroyed)
        XCTAssertEqual(f.provider.activeRuntimeCount, 0)
    }

    func testAcceptedDeletionOfStillObservableResourceRemainsUnverified() throws {
        let f = try Fixture(), a = try f.ready()
        f.provider.configureFaults { $0.deleteAcceptedStillPresent = true }
        let executionID = UUID().uuidString
        let pending = try f.coordinator.destroy(environmentID: a.environmentID,
            admission: f.root(executionID: executionID), confirmed: true)
        XCTAssertEqual(pending.acceptance?.acceptance, .accepted)
        XCTAssertEqual(pending.observation?.presence, .present)
        XCTAssertNotEqual(pending.state, .destroyed)
        XCTAssertNotEqual(try f.coordinator.executionRecord(executionID)?.state, .succeeded)
        f.provider.configureFaults { $0.deleteAcceptedStillPresent = false }
        _ = try f.coordinator.reconcile()
        XCTAssertEqual(try f.coordinator.record(environmentID: a.environmentID)?.state, .destroyed)
        let before = f.effectCount
        _ = try f.coordinator.destroy(environmentID: a.environmentID, admission: f.root(), confirmed: true)
        XCTAssertEqual(f.effectCount, before)
    }

    func testPartiallyEnrolledRuntimeAndWrongSHAHaveNoWorkloadAuthority() throws {
        let f = try Fixture(), a = try f.bootstrap(f.create())
        XCTAssertEqual(a.state, .bootstrapping)
        XCTAssertNil(a.runtime)
        let effects = f.effectCount
        // Construct a correctly signed but unenrolled subject grant without
        // using the fixture's assertion that only enrolled records have runtime.
        let candidate = try XCTUnwrap(f.provider.observe(correlationID: a.intent.correlationID).runtime)
        let body = try CapabilityLease(leaseID: UUID(), issuerPublicKey: f.host.publicKey,
            subjectPublicKey: candidate.publicKey, subjectRuntimeID: candidate.runtimeID,
            environmentID: XCTUnwrap(UUID(uuidString: a.environmentID)), issuingExecutionID: a.intent.creationExecutionID,
            capabilityIDs: ["environment:execute"], profileIDs: ["linux-small"], issuedAtMilliseconds: f.clock.value,
            expiresAtMilliseconds: a.intent.expiresAtMilliseconds, nonce: Data(repeating: 12, count: 32),
            limits: f.limits(), networkAllowlist: [])
        XCTAssertThrowsError(try f.coordinator.installSignedLease(SignedCapabilityLease.sign(body, using: f.host)))
        XCTAssertThrowsError(try f.coordinator.executeChallenge(environmentID: a.environmentID, challenge: "nonce",
            admission: f.root(), confirmed: true))
        XCTAssertEqual(f.effectCount, effects)
        let claim = try f.claim(a)
        f.provider.configureFaults { $0.runtimeManifestOverride = try? .init(version: "test-v1",
            executableSHA256: String(repeating: "b", count: 64), architecture: "arm64") }
        XCTAssertThrowsError(try f.coordinator.enroll(environmentID: a.environmentID, response: claim.wireData()))
        XCTAssertNil(try f.coordinator.record(environmentID: a.environmentID)?.runtime)
        f.provider.configureFaults { $0.runtimeManifestOverride = nil }
        XCTAssertEqual(try f.coordinator.enroll(environmentID: a.environmentID, response: claim.wireData()).state, .ready)
        XCTAssertThrowsError(try f.coordinator.enroll(environmentID: a.environmentID, response: claim.wireData()))
    }

    func testMalformedOrWrongEnvironmentEnrollmentCannotActivateRuntime() throws {
        let f = try Fixture(), a = try f.bootstrap(f.create()), claim = try f.claim(a)
        let changed = try mutate(claim, path: ["claim", "handle", "correlationID"], replacement: UUID().uuidString)
        let changedParent = try mutate(claim, path: ["claim", "handle", "lineage", "parentExecutionID"], replacement: UUID().uuidString)
        for response in [try changed.wireData(), try changedParent.wireData(), Data("{\"confirmed\":true}".utf8), Data(repeating: 123, count: 131_073)] {
            XCTAssertThrowsError(try f.coordinator.enroll(environmentID: a.environmentID, response: response))
            XCTAssertNil(try f.coordinator.record(environmentID: a.environmentID)?.runtime)
        }
        XCTAssertEqual(try f.enroll(a).state, .ready)
    }

    func testChildCannotTargetAnotherEnvironmentOrBypassConfirmation() throws {
        let f = try Fixture(), a = try f.ready(), lease = try f.grant(a), other = try f.ready()
        let effects = f.effectCount
        XCTAssertThrowsError(try f.coordinator.executeChallenge(environmentID: other.environmentID, challenge: "nonce",
            admission: f.child(a, lease: lease), confirmed: true))
        XCTAssertThrowsError(try f.coordinator.destroy(environmentID: other.environmentID,
            admission: f.child(a, lease: lease), confirmed: true))
        XCTAssertThrowsError(try f.coordinator.create(spec: f.spec(lifetime: 30_000), correlationID: UUID().uuidString,
            admission: f.child(a, lease: lease), confirmed: false))
        XCTAssertThrowsError(try f.coordinator.executeChallenge(environmentID: a.environmentID, challenge: "nonce",
            admission: f.child(a, lease: lease), confirmed: false))
        XCTAssertThrowsError(try f.coordinator.destroy(environmentID: a.environmentID,
            admission: f.child(a, lease: lease), confirmed: false))
        XCTAssertEqual(f.effectCount, effects)
        XCTAssertFalse(try f.coordinator.record(environmentID: a.environmentID)!.revoked)
    }

    func testChildrenCannotIncreaseDelegatedScopeExpiryCostResourcesOrDepth() throws {
        let f = try Fixture(), a = try f.ready(), parent = try f.grant(a)
        let b = try f.ready(lifetime: 60_000, admission: f.child(a, lease: parent))
        let ordinary = try f.limits(executions: 4, children: 0, descendants: 0, depth: 0, cpu: 1, memory: 256, cost: 100)
        let attacks = [
            try f.delegation(b, parent: a, lease: parent, limits: ordinary, capabilities: ["environment:admin"]),
            try f.delegation(b, parent: a, lease: parent, limits: f.limits(cpu: 3)),
            try f.delegation(b, parent: a, lease: parent, limits: f.limits(memory: 1_024)),
            try f.delegation(b, parent: a, lease: parent, limits: f.limits(cost: 2_001)),
            try f.delegation(b, parent: a, lease: parent, limits: f.limits())
        ]
        let effects = f.effectCount
        // The node's typed issuer rejects an expiry beyond its own or B's TTL.
        // The lease validator's separately signed expiry-widening attack is in
        // CapabilityLeaseTests.testSignedChildWideningAndWrongParentAreRejected.
        XCTAssertThrowsError(try f.delegation(b, parent: a, lease: parent, limits: ordinary,
            expiry: a.intent.expiresAtMilliseconds + 1))
        for attack in attacks {
            XCTAssertThrowsError(try f.coordinator.delegateSignedLease(attack, parentLeaseID: parent.body.leaseID,
                admission: f.child(a, lease: parent)))
        }
        XCTAssertEqual(f.effectCount, effects)
        XCTAssertEqual(try f.coordinator.record(environmentID: b.environmentID)?.leaseIDs.count, 0)
    }

    func testExcessChildCountAndMaximumEnvironmentDepthRejectWithoutEffect() throws {
        let f = try Fixture()
        let (a, leaseA, b, leaseB) = try f.nested()
        let count = f.effectCount
        XCTAssertThrowsError(try f.create(lifetime: 30_000, admission: f.child(a, lease: leaseA)))
        XCTAssertEqual(f.effectCount, count)
        let c = try f.ready(lifetime: 30_000, admission: f.child(b, lease: leaseB))
        XCTAssertEqual(c.lineage.depth, EnvironmentLimits.maximumDepth)
        let leaf = try f.delegation(c, parent: b, lease: leaseB,
            limits: f.limits(executions: 2, children: 0, descendants: 0, depth: 0, cpu: 1, memory: 256, cost: 100))
        try f.coordinator.delegateSignedLease(leaf, parentLeaseID: leaseB.body.leaseID, admission: f.child(b, lease: leaseB))
        let before = f.effectCount
        XCTAssertThrowsError(try f.create(lifetime: 10_000, admission: f.child(c, lease: leaf)))
        XCTAssertEqual(f.effectCount, before)
        XCTAssertEqual(try f.coordinator.records().count, 3)
    }

    func testInterruptedRecursiveTeardownRecoversDeepestFirstAndRetainsLedger() throws {
        let f = try Fixture(), (a, _, b, leaseB) = try f.nested()
        let c = try f.ready(lifetime: 30_000, admission: f.child(b, lease: leaseB))
        f.provider.configureFaults { $0.deleteAcceptedStillPresent = true }
        let pending = try f.coordinator.destroy(environmentID: a.environmentID, admission: f.root(), confirmed: true)
        XCTAssertNotEqual(pending.state, .destroyed)
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("destroy:") }, ["destroy:" + c.environmentID])
        for record in try f.coordinator.records() { XCTAssertTrue(record.revoked); XCTAssertNil(record.runtime) }
        XCTAssertThrowsError(try f.child(b, lease: leaseB))
        f.coordinator = try f.reopen()
        f.provider.configureFaults { $0.deleteAcceptedStillPresent = false }
        _ = try f.coordinator.reconcile()
        let destructions = f.provider.operationLog.filter { $0.hasPrefix("destroy:") }
        XCTAssertEqual(Array(destructions.suffix(3)), ["destroy:" + c.environmentID, "destroy:" + b.environmentID, "destroy:" + a.environmentID])
        for record in try f.coordinator.records() {
            XCTAssertEqual(record.state, .destroyed); XCTAssertEqual(record.observation?.presence, .absent)
            XCTAssertNotNil(try f.coordinator.executionRecord(record.intent.creationExecutionID))
        }
        XCTAssertEqual(f.provider.activeRuntimeCount, 0)
        let effects = f.effectCount
        _ = try f.coordinator.reconcile()
        XCTAssertEqual(f.effectCount, effects)
    }

    func testCrossEnvironmentExecutionEvidenceAndDependencyReplayRejectAcrossRestart() throws {
        let f = try Fixture(), a = try f.ready(), lease = try f.grant(a)
        let execution = try f.execute(a, lease: lease), proof = try f.proof(execution)
        let certificate = try f.coordinator.adjudicateProof(proof, hostSigner: f.host)
        let dependency = try ExecutionDependency(executionID: execution.executionId, environmentID: a.environmentID,
            requestDigest: proof.proof.binding.requestDigest, proofDigest: proof.proof.digest,
            predicateID: proof.proof.predicateID, observerID: f.coordinator.hostRuntimeID,
            maximumAgeMilliseconds: 30_000, oneUse: true)
        let consumer = UUID().uuidString, request = String(repeating: "e", count: 64)
        func validate(_ dependency: ExecutionDependency, consumer: String, request: String) throws -> ValidatedExecutionDependency {
            try ExecutionDependencyValidator.validate(dependency, proof: proof, certificate: certificate,
                trustedChildPublicKey: XCTUnwrap(a.runtime).publicKey, trustedHostPublicKey: f.host.publicKey,
                consumingExecutionID: consumer, consumingRequestDigest: request, nowMilliseconds: f.clock.value,
                using: RCIREd25519Verifier(), reservationStore: f.coordinator)
        }
        _ = try validate(dependency, consumer: consumer, request: request)
        f.coordinator = try f.reopen()
        XCTAssertNoThrow(try validate(dependency, consumer: consumer, request: request))
        XCTAssertThrowsError(try validate(dependency, consumer: UUID().uuidString, request: request))
        XCTAssertThrowsError(try validate(dependency, consumer: consumer, request: String(repeating: "f", count: 64)))
        let another = try f.ready()
        let crossEnvironment = try mutate(dependency, path: ["environmentID"], replacement: another.environmentID)
        let crossExecution = try mutate(dependency, path: ["executionID"], replacement: UUID().uuidString)
        XCTAssertThrowsError(try validate(crossEnvironment, consumer: consumer, request: request))
        XCTAssertThrowsError(try validate(crossExecution, consumer: consumer, request: request))
        let anotherLease = try f.grant(another), anotherExecution = try f.execute(another, lease: anotherLease)
        let swapped = try mutate(proof, path: ["proof", "binding", "executionID"], replacement: anotherExecution.executionId)
        XCTAssertThrowsError(try f.coordinator.adjudicateProof(swapped, hostSigner: f.host))
        XCTAssertNil(try f.coordinator.evidence(executionID: anotherExecution.executionId).1)
    }
}
