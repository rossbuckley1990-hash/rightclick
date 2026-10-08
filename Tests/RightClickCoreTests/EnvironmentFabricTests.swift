import Foundation
import XCTest
@testable import RightClickCore
import RightClickProtocol
import RightClickProviders

final class EnvironmentFabricTests: XCTestCase {
    final class Clock { var time: Int64 = 1_000_000 }
    final class RuntimeObservationProxy: EnvironmentProvider {
        let underlying: InMemoryEnvironmentProvider
        var replacementKey: Data?
        var omitRuntime = false
        init(_ underlying: InMemoryEnvironmentProvider) { self.underlying = underlying }
        var id: String { underlying.id }
        var support: EnvironmentProviderSupport { underlying.support }
        func create(_ intent: EnvironmentCreateIntent) throws -> EnvironmentProviderAcceptance { try underlying.create(intent) }
        func observe(correlationID: String) throws -> EnvironmentObservation {
            let observation = try underlying.observe(correlationID: correlationID)
            guard observation.presence == .present, let runtime = observation.runtime else { return observation }
            let changed = omitRuntime ? nil : try EnvironmentRuntimeObservation(manifest: runtime.manifest,
                publicKey: replacementKey ?? runtime.publicKey, observedAtMilliseconds: runtime.observedAtMilliseconds,
                observationBoundary: runtime.observationBoundary)
            return try .init(environmentID: observation.environmentID, correlationID: observation.correlationID,
                providerResourceID: observation.providerResourceID, presence: .present, state: observation.state,
                observedAtMilliseconds: observation.observedAtMilliseconds, runtime: changed, observationBoundary: observation.observationBoundary)
        }
        func list() throws -> [EnvironmentObservation] { try underlying.list() }
        func bootstrap(_ handle: EnvironmentHandle, manifest: EnvironmentRuntimeManifest) throws -> EnvironmentProviderAcceptance { try underlying.bootstrap(handle, manifest: manifest) }
        func executeChallenge(_ handle: EnvironmentHandle, executionID: String, challenge: String) throws -> EnvironmentProviderAcceptance { try underlying.executeChallenge(handle, executionID: executionID, challenge: challenge) }
        func observeChallenge(_ handle: EnvironmentHandle, executionID: String) throws -> String? { try underlying.observeChallenge(handle, executionID: executionID) }
        func stop(_ handle: EnvironmentHandle, idempotencyKey: String) throws -> EnvironmentProviderAcceptance { try underlying.stop(handle, idempotencyKey: idempotencyKey) }
        func destroy(_ handle: EnvironmentHandle, idempotencyKey: String) throws -> EnvironmentProviderAcceptance { try underlying.destroy(handle, idempotencyKey: idempotencyKey) }
    }
    /// An adapter barrier stages completion of the original accepted operation.
    /// Core dispatches create once; release completes that same immutable intent.
    final class DelayedCreationProvider: EnvironmentProvider {
        let underlying: InMemoryEnvironmentProvider
        private var pending: EnvironmentCreateIntent?
        private var acceptedIntent: EnvironmentCreateIntent?
        private(set) var createDispatchCount = 0
        var observedResourceIDOverride: String?
        var omitAcceptedResourceID = false
        init(_ underlying: InMemoryEnvironmentProvider) { self.underlying = underlying }
        var id: String { underlying.id }
        var support: EnvironmentProviderSupport { underlying.support }
        private func resourceID(_ intent: EnvironmentCreateIntent) -> String { "mem-" + intent.correlationID.lowercased() }
        func create(_ intent: EnvironmentCreateIntent) throws -> EnvironmentProviderAcceptance {
            guard acceptedIntent == nil else { throw EnvironmentError.idempotencyConflict }
            acceptedIntent = intent; pending = intent; createDispatchCount += 1
            return try .init(acceptance: omitAcceptedResourceID ? .unknown : .accepted,
                providerResourceID: omitAcceptedResourceID ? nil : resourceID(intent), message: "Original accepted create completion held at adapter barrier.")
        }
        func releaseAcceptedCreate() throws {
            guard let intent = pending else { throw EnvironmentError.invalidState }
            // Complete the one original queued provider operation, never a retry.
            _ = try underlying.create(intent)
            pending = nil
        }
        func observe(correlationID: String) throws -> EnvironmentObservation {
            if let intent = pending, intent.correlationID == correlationID {
                return try .init(environmentID: intent.environmentID, correlationID: correlationID,
                    providerResourceID: resourceID(intent), presence: .absent, state: .destroyed,
                    observedAtMilliseconds: intent.createdAtMilliseconds, observationBoundary: "delayed-adapter-exact-resource-observer")
            }
            let observation = try underlying.observe(correlationID: correlationID)
            guard let changed = observedResourceIDOverride, observation.presence == .present else { return observation }
            return try .init(environmentID: observation.environmentID, correlationID: observation.correlationID,
                providerResourceID: changed, presence: .present, state: observation.state,
                observedAtMilliseconds: observation.observedAtMilliseconds, runtime: observation.runtime,
                observationBoundary: observation.observationBoundary)
        }
        func list() throws -> [EnvironmentObservation] {
            if let intent = pending { return [try observe(correlationID: intent.correlationID)] }
            return try underlying.list()
        }
        func bootstrap(_ handle: EnvironmentHandle, manifest: EnvironmentRuntimeManifest) throws -> EnvironmentProviderAcceptance { try underlying.bootstrap(handle, manifest: manifest) }
        func executeChallenge(_ handle: EnvironmentHandle, executionID: String, challenge: String) throws -> EnvironmentProviderAcceptance { try underlying.executeChallenge(handle, executionID: executionID, challenge: challenge) }
        func observeChallenge(_ handle: EnvironmentHandle, executionID: String) throws -> String? { try underlying.observeChallenge(handle, executionID: executionID) }
        func stop(_ handle: EnvironmentHandle, idempotencyKey: String) throws -> EnvironmentProviderAcceptance { try underlying.stop(handle, idempotencyKey: idempotencyKey) }
        func destroy(_ handle: EnvironmentHandle, idempotencyKey: String) throws -> EnvironmentProviderAcceptance { try underlying.destroy(handle, idempotencyKey: idempotencyKey) }
    }
    struct Fixture {
        let clock: Clock
        let provider: InMemoryEnvironmentProvider
        let parent: RCIREd25519Signer
        let path: URL
        let manifest: EnvironmentRuntimeManifest
        let spec: EnvironmentSpec
        let coordinator: EnvironmentCoordinator
    }
    private func fixture(maximumEnvironments: Int = 2, providerTransform: ((InMemoryEnvironmentProvider) -> any EnvironmentProvider)? = nil) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let provider = try InMemoryEnvironmentProvider(clock: { clock.time })
        let parent = try RCIREd25519Signer(rawPrivateKey: Data(repeating: 1, count: 32))
        let manifest = try EnvironmentRuntimeManifest(version: "test-1", executableSHA256: String(repeating: "a", count: 64), architecture: "arm64")
        let spec = try EnvironmentSpec(profileID: "challenge", lifetimeMilliseconds: 300_000,
            resources: .init(cpuCount: 1, memoryMiB: 512, maximumCostUnits: 10_000))
        let path = root.appendingPathComponent("journal")
        let coordinator = try makeCoordinator(providerTransform?(provider) ?? provider, parent, clock, path, manifest, spec, maximumEnvironments)
        return Fixture(clock: clock, provider: provider, parent: parent, path: path, manifest: manifest, spec: spec, coordinator: coordinator)
    }
    private func makeCoordinator(_ provider: any EnvironmentProvider, _ parent: RCIREd25519Signer,
                                 _ clock: Clock, _ path: URL, _ manifest: EnvironmentRuntimeManifest,
                                 _ spec: EnvironmentSpec, _ maximumEnvironments: Int = 2) throws -> EnvironmentCoordinator {
        try EnvironmentCoordinator(provider: provider, journalDirectory: path,
            hostRuntimeID: "runtime:" + ExecutionEvidenceDigest.sha256(parent.publicKey), trustedRootIssuerPublicKeys: [parent.publicKey],
            profiles: ["challenge": manifest], profileCeilings: ["challenge": spec], operatorPublicKey: parent.publicKey,
            maximumEnvironments: maximumEnvironments, enrollmentVerifier: { handle, expected, challenge, observation, bytes in
                guard let independent = observation.runtime, independent.manifest == expected else { throw EnvironmentFabricError.invalidRuntime }
                let signed = try SignedChildRuntimeClaim.decode(bytes)
                let claim = try signed.verify(trustedPublicKey: independent.publicKey)
                guard claim.handle == handle, claim.manifest == expected, claim.enrollmentID == challenge.enrollmentID,
                      claim.challenge == challenge.challenge else { throw EnvironmentFabricError.invalidRuntime }
                let certificate = try ChildRuntimeEnrollmentCertificate(claim: claim, issuerPublicKey: parent.publicKey,
                    environmentObservedAtMilliseconds: observation.observedAtMilliseconds,
                    runtimeObservedAtMilliseconds: independent.observedAtMilliseconds, verifiedAtMilliseconds: clock.time,
                    environmentObservationBoundary: observation.observationBoundary, runtimeObservationBoundary: independent.observationBoundary)
                return try .sign(certificate, using: parent)
            }, now: { clock.time })
    }
    private func root(_ coordinator: EnvironmentCoordinator, byte: UInt8 = 2) throws -> EnvironmentAdmissionContext {
        try coordinator.rootAdmission(executionID: UUID().uuidString, requestDigest: Data(repeating: byte, count: 32))
    }
    private func create(_ fixture: Fixture) throws -> EnvironmentRecord {
        try fixture.coordinator.create(spec: fixture.spec, correlationID: UUID().uuidString, admission: root(fixture.coordinator), confirmed: true)
    }
    private func enroll(_ fixture: Fixture, _ record: EnvironmentRecord) throws -> EnvironmentRecord {
        let latest = try XCTUnwrap(fixture.coordinator.record(environmentID: record.environmentID))
        let bootstrapped = latest.enrollmentChallenge == nil ?
            try fixture.coordinator.bootstrap(environmentID: record.environmentID, admission: root(fixture.coordinator), confirmed: true) : latest
        let challenge = try XCTUnwrap(bootstrapped.enrollmentChallenge)
        let observed = try fixture.provider.observe(correlationID: record.intent.correlationID)
        let observedRuntime = try XCTUnwrap(observed.runtime)
        let claim = try ChildRuntimeClaim(enrollmentID: challenge.enrollmentID, handle: XCTUnwrap(record.handle),
            manifest: fixture.manifest, publicKey: observedRuntime.publicKey, challenge: challenge.challenge,
            issuedAtMilliseconds: fixture.clock.time, expiresAtMilliseconds: challenge.expiresAtMilliseconds)
        let response = try fixture.provider.signedRuntimeClaim(claim).wireData()
        return try fixture.coordinator.enroll(environmentID: record.environmentID, response: response)
    }
    private func installLease(_ fixture: Fixture, _ record: EnvironmentRecord, children: Int64 = 1,
                              descendants: Int64 = 1, depth: Int64 = 1) throws -> SignedCapabilityLease {
        let runtime = try XCTUnwrap(record.runtime)
        let limits = try CapabilityLeaseLimits(maximumExecutions: 12, maximumChildren: children,
            maximumDescendants: descendants, delegationDepth: depth, cpuCount: 1, memoryMiB: 512, maximumCostUnits: 100_000)
        let body = try CapabilityLease(leaseID: UUID(), issuerPublicKey: fixture.parent.publicKey,
            subjectPublicKey: runtime.publicKey, subjectRuntimeID: runtime.runtimeID, environmentID: UUID(uuidString: record.environmentID)!,
            issuingExecutionID: record.intent.creationExecutionID,
            capabilityIDs: ["environment:create-child", "environment:execute", "environment:bootstrap", "environment:destroy", "environment:observe"],
            profileIDs: ["challenge"], issuedAtMilliseconds: fixture.clock.time,
            expiresAtMilliseconds: record.intent.expiresAtMilliseconds, nonce: Data(repeating: 7, count: 32), limits: limits, networkAllowlist: [])
        let signed = try SignedCapabilityLease.sign(body, using: fixture.parent)
        try fixture.coordinator.installSignedLease(signed)
        return signed
    }
    private func child(_ fixture: Fixture, _ record: EnvironmentRecord, _ lease: SignedCapabilityLease) throws -> EnvironmentAdmissionContext {
        let runtime = try XCTUnwrap(record.runtime)
        return try fixture.coordinator.authenticatedAdmission(executionID: UUID().uuidString, requestDigest: Data(repeating: 3, count: 32),
            subjectPublicKey: runtime.publicKey, runtimeID: runtime.runtimeID, environmentID: record.environmentID, leaseID: lease.body.leaseID)
    }
    private func delegate(_ fixture: Fixture, parent: EnvironmentRecord, childRecord: EnvironmentRecord,
                          parentLease: SignedCapabilityLease, memoryMiB: Int64 = 512) throws -> SignedCapabilityLease {
        let runtime = try XCTUnwrap(childRecord.runtime)
        let body = try CapabilityLease(leaseID: UUID(), issuerPublicKey: parent.runtime!.publicKey,
            subjectPublicKey: runtime.publicKey, subjectRuntimeID: runtime.runtimeID,
            environmentID: UUID(uuidString: childRecord.environmentID)!, parentLeaseID: parentLease.body.leaseID,
            parentLeaseDigest: parentLease.body.digest(), issuingExecutionID: childRecord.intent.creationExecutionID,
            capabilityIDs: ["environment:execute", "environment:destroy", "environment:observe"], profileIDs: ["challenge"],
            issuedAtMilliseconds: fixture.clock.time, expiresAtMilliseconds: childRecord.intent.expiresAtMilliseconds,
            nonce: Data(repeating: 9, count: 32),
            limits: .init(maximumExecutions: 3, maximumChildren: 0, maximumDescendants: 0, delegationDepth: 0,
                cpuCount: 1, memoryMiB: memoryMiB, maximumCostUnits: 10_000), networkAllowlist: [])
        let signed = try fixture.provider.signedCapabilityLease(body, issuerEnvironmentID: parent.environmentID)
        try fixture.coordinator.delegateSignedLease(signed, parentLeaseID: parentLease.body.leaseID,
            admission: child(fixture, parent, parentLease))
        return signed
    }
    private func reportedProof(_ fixture: Fixture, executionID: String, value: String) throws -> SignedExecutionProof {
        let expected = try fixture.coordinator.proofExpectation(executionID: executionID)
        let proof = try ExecutionProof(binding: expected.binding, challengeNonce: expected.challengeNonce,
            issuedAtMilliseconds: fixture.clock.time, observedAtMilliseconds: fixture.clock.time,
            expiresAtMilliseconds: expected.deadlineMilliseconds, sequence: 1, predicateID: expected.predicateID,
            providerAccepted: true, reportedOutcome: .succeeded, reportedValue: .string(value), reportBoundary: "simulated-child-assertion")
        return try fixture.provider.signedExecutionProof(proof)
    }
    private func dependency(_ fixture: Fixture, executionID: String, proof: SignedExecutionProof, oneUse: Bool = true) throws -> ExecutionDependency {
        try .init(executionID: executionID, environmentID: proof.proof.binding.environmentID,
            requestDigest: proof.proof.binding.requestDigest, proofDigest: proof.proof.digest,
            predicateID: proof.proof.predicateID, observerID: fixture.coordinator.hostRuntimeID,
            maximumAgeMilliseconds: 60_000, oneUse: oneUse)
    }

    func testCreateFlushesIntentAndRecoversAcceptedThenCrashWithoutDuplicate() throws {
        let f = try fixture()
        f.provider.configureFaults { $0.createAcceptedThenCrashOnce = true }
        let admission = try root(f.coordinator), correlation = UUID().uuidString
        let first = try f.coordinator.create(spec: f.spec, correlationID: correlation, admission: admission, confirmed: true)
        XCTAssertNotNil(first.handle)
        XCTAssertEqual(first.acceptance?.acceptance, .unknown)
        let recovered = try makeCoordinator(f.provider, f.parent, f.clock, f.path, f.manifest, f.spec)
        let retried = try recovered.rootAdmission(executionID: admission.executionID, requestDigest: admission.requestDigest)
        let second = try recovered.create(spec: f.spec, correlationID: correlation, admission: retried, confirmed: true)
        XCTAssertEqual(first.environmentID, second.environmentID)
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("create:") }.count, 1)
        XCTAssertEqual(try recovered.executionRecord(admission.executionID)?.state, .succeeded)
    }

    func testConfirmationAndOpaqueCallerAreEnforcedBeforeCreate() throws {
        let f = try fixture()
        XCTAssertThrowsError(try f.coordinator.create(spec: f.spec, correlationID: UUID().uuidString,
            admission: root(f.coordinator), confirmed: false)) { XCTAssertEqual($0 as? EnvironmentFabricError, .confirmationRequired) }
        XCTAssertTrue(f.provider.operationLog.isEmpty)
        let other = try fixture()
        XCTAssertThrowsError(try f.coordinator.create(spec: f.spec, correlationID: UUID().uuidString,
            admission: root(other.coordinator), confirmed: true))
        XCTAssertTrue(f.provider.operationLog.isEmpty)
    }

    func testBootstrapDoesNotEnrollFromProviderAcceptance() throws {
        let f = try fixture()
        let created = try create(f)
        let bootstrapped = try f.coordinator.bootstrap(environmentID: created.environmentID, admission: root(f.coordinator), confirmed: true)
        XCTAssertEqual(bootstrapped.state, .bootstrapping)
        XCTAssertNil(bootstrapped.runtime)
        XCTAssertFalse(try f.coordinator.canDiscover(capabilityID: "environment:execute", environmentID: created.environmentID))
        let enrolled = try enroll(f, created)
        XCTAssertEqual(enrolled.state, .ready)
        XCTAssertNotNil(enrolled.enrollmentCertificate)
        XCTAssertTrue(enrolled.enrollmentConsumed)
        XCTAssertThrowsError(try f.coordinator.enroll(environmentID: created.environmentID, response: Data()))
    }

    func testWrongManifestAndPartiallyEnrolledRuntimeHaveNoAuthority() throws {
        let f = try fixture()
        let record = try create(f)
        _ = try f.coordinator.bootstrap(environmentID: record.environmentID, admission: root(f.coordinator), confirmed: true)
        f.provider.configureFaults { $0.runtimeManifestOverride = try! .init(version: "wrong", executableSHA256: String(repeating: "b", count: 64), architecture: "arm64") }
        XCTAssertThrowsError(try enroll(f, record))
        XCTAssertNil(try f.coordinator.record(environmentID: record.environmentID)?.runtime)
        XCTAssertThrowsError(try f.coordinator.executeChallenge(environmentID: record.environmentID, challenge: "nonce", admission: root(f.coordinator), confirmed: true))
    }

    func testLeaseSubjectCannotSpoofEnvironmentAndChildBudgetIsConsumedBeforeDispatch() throws {
        let f = try fixture(maximumEnvironments: 3)
        let a = try enroll(f, create(f)), lease = try installLease(f, a)
        let childAdmission = try child(f, a, lease)
        let b = try f.coordinator.create(spec: f.spec, correlationID: UUID().uuidString, admission: childAdmission, confirmed: true)
        XCTAssertEqual(b.lineage.parentEnvironmentID, a.environmentID)
        XCTAssertEqual(b.lineage.parentRuntimeID, a.runtime?.runtimeID)
        XCTAssertEqual(b.lineage.depth, 1)
        XCTAssertThrowsError(try f.coordinator.create(spec: f.spec, correlationID: UUID().uuidString, admission: child(f, a, lease), confirmed: true))
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("create:") }.count, 2)
        XCTAssertThrowsError(try f.coordinator.authenticatedAdmission(executionID: UUID().uuidString, requestDigest: Data(repeating: 4, count: 32),
            subjectPublicKey: a.runtime!.publicKey, runtimeID: a.runtime!.runtimeID, environmentID: b.environmentID, leaseID: lease.body.leaseID))
    }

    func testWorkloadAcceptsThenIndependentFalsePostconditionFailsAndRetryDoesNotExecuteTwice() throws {
        let f = try fixture(), a = try enroll(f, create(f))
        _ = try installLease(f, a)
        let admission = try root(f.coordinator)
        f.provider.configureFaults { $0.observedChallengeOverride = "wrong-nonce" }
        let accepted = try f.coordinator.executeChallenge(environmentID: a.environmentID, challenge: "fresh-nonce", admission: admission, confirmed: true)
        XCTAssertEqual(accepted.state, .accepted)
        XCTAssertEqual(try f.coordinator.verifyChallenge(executionID: admission.executionID).state, .failed)
        _ = try f.coordinator.executeChallenge(environmentID: a.environmentID, challenge: "fresh-nonce", admission: admission, confirmed: true)
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("challenge:") }.count, 1)
        let reopened = try makeCoordinator(f.provider, f.parent, f.clock, f.path, f.manifest, f.spec)
        XCTAssertEqual(try reopened.executionRecord(admission.executionID)?.state, .failed)
    }

    func testRecursiveDestroyIsDeepestFirstRevokesAllAuthorityAndRetainsLedger() throws {
        let f = try fixture()
        let a = try enroll(f, create(f)), lease = try installLease(f, a)
        let admission = try child(f, a, lease)
        let b = try f.coordinator.create(spec: f.spec, correlationID: UUID().uuidString, admission: admission, confirmed: true)
        let enrolledB = try enroll(f, b)
        _ = try delegate(f, parent: a, childRecord: enrolledB, parentLease: lease)
        let result = try f.coordinator.destroy(environmentID: a.environmentID, admission: root(f.coordinator), confirmed: true)
        XCTAssertEqual(result.state, .destroyed)
        XCTAssertEqual(try f.coordinator.record(environmentID: b.environmentID)?.state, .destroyed)
        let deletes = f.provider.operationLog.filter { $0.hasPrefix("destroy:") }
        XCTAssertEqual(deletes, ["destroy:" + b.environmentID, "destroy:" + a.environmentID])
        XCTAssertEqual(f.provider.activeRuntimeCount, 0)
        XCTAssertThrowsError(try child(f, a, lease))
        XCTAssertEqual(try f.coordinator.records().count, 2)
        XCTAssertNotNil(try f.coordinator.executionRecord(admission.executionID))
    }

    func testPartitionedRecursiveDestroyRetainsIntentsAndResumesAfterRestart() throws {
        let f = try fixture()
        let a = try enroll(f, create(f)), lease = try installLease(f, a)
        let b = try f.coordinator.create(spec: f.spec, correlationID: UUID().uuidString, admission: child(f, a, lease), confirmed: true)
        f.provider.configureFaults { $0.partitioned = true }
        let destroyAdmission = try root(f.coordinator)
        let blocked = try f.coordinator.destroy(environmentID: a.environmentID, admission: destroyAdmission, confirmed: true)
        XCTAssertEqual(blocked.state, .unknown)
        XCTAssertTrue(blocked.revoked)
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("destroy:") }.count, 0)
        let reopened = try makeCoordinator(f.provider, f.parent, f.clock, f.path, f.manifest, f.spec)
        f.provider.configureFaults { $0.partitioned = false }
        let records = try reopened.reconcile()
        XCTAssertTrue(records.allSatisfy { $0.state == .destroyed })
        XCTAssertEqual(try reopened.executionRecord(destroyAdmission.executionID)?.state, .succeeded)
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("destroy:") }, ["destroy:" + b.environmentID, "destroy:" + a.environmentID])
    }

    func testDeleteAcceptanceWhileChildPresentCannotDestroyParent() throws {
        let f = try fixture()
        let a = try enroll(f, create(f)), lease = try installLease(f, a)
        let b = try f.coordinator.create(spec: f.spec, correlationID: UUID().uuidString, admission: child(f, a, lease), confirmed: true)
        f.provider.configureFaults { $0.deleteAcceptedStillPresent = true }
        let result = try f.coordinator.destroy(environmentID: a.environmentID, admission: root(f.coordinator), confirmed: true)
        XCTAssertNotEqual(result.state, .destroyed)
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("destroy:") }, ["destroy:" + b.environmentID])
        XCTAssertEqual(try f.coordinator.record(environmentID: b.environmentID)?.observation?.presence, .present)
        f.provider.configureFaults { $0.deleteAcceptedStillPresent = false }
        XCTAssertTrue(try f.coordinator.reconcile().allSatisfy { $0.state == .destroyed })
    }

    func testTTLProviderAndParentReconcilerRemoveExpiredRuntime() throws {
        let f = try fixture()
        let a = try enroll(f, create(f))
        _ = try installLease(f, a)
        f.clock.time = a.intent.expiresAtMilliseconds
        XCTAssertTrue(try f.coordinator.reconcile().allSatisfy { $0.state == .destroyed && $0.revoked })
        XCTAssertEqual(f.provider.activeRuntimeCount, 0)
    }

    func testDependencyOneUseIsDurableAndExactRetryIsIdempotent() throws {
        let f = try fixture(), executionID = UUID().uuidString
        let proof = String(repeating: "a", count: 64), cert = String(repeating: "b", count: 64), request = String(repeating: "c", count: 64)
        try f.coordinator.reserve(dependencyProofDigest: proof, certificateDigest: cert, consumingExecutionID: executionID, consumingRequestDigest: request)
        let reopened = try makeCoordinator(f.provider, f.parent, f.clock, f.path, f.manifest, f.spec)
        XCTAssertNoThrow(try reopened.reserve(dependencyProofDigest: proof, certificateDigest: cert, consumingExecutionID: executionID, consumingRequestDigest: request))
        XCTAssertThrowsError(try reopened.reserve(dependencyProofDigest: proof, certificateDigest: cert, consumingExecutionID: UUID().uuidString, consumingRequestDigest: request))
    }

    func testSignedProofReplayIsRejectedAndEvidenceSurvivesTeardown() throws {
        let f = try fixture(), a = try enroll(f, create(f))
        _ = try installLease(f, a)
        let admission = try root(f.coordinator)
        _ = try f.coordinator.executeChallenge(environmentID: a.environmentID, challenge: "nonce-unique", admission: admission, confirmed: true)
        let expected = try f.coordinator.proofExpectation(executionID: admission.executionID)
        let proof = try ExecutionProof(binding: expected.binding, challengeNonce: expected.challengeNonce,
            issuedAtMilliseconds: f.clock.time, observedAtMilliseconds: f.clock.time,
            expiresAtMilliseconds: expected.deadlineMilliseconds, sequence: 1, predicateID: expected.predicateID,
            providerAccepted: true, reportedOutcome: .succeeded, reportedValue: .string("nonce-unique"), reportBoundary: "simulated-child-assertion")
        let signed = try f.provider.signedExecutionProof(proof)
        let certificate = try f.coordinator.adjudicateProof(signed, hostSigner: f.parent)
        XCTAssertEqual(certificate.verification.outcome, .succeeded)
        XCTAssertThrowsError(try f.coordinator.adjudicateProof(signed, hostSigner: f.parent))
        _ = try f.coordinator.destroy(environmentID: a.environmentID, admission: root(f.coordinator), confirmed: true)
        let reopened = try makeCoordinator(f.provider, f.parent, f.clock, f.path, f.manifest, f.spec)
        XCTAssertNotNil(try reopened.evidence(executionID: admission.executionID).0)
        XCTAssertNotNil(try reopened.evidence(executionID: admission.executionID).1)
    }

    func testBuiltinChallengeSuccessCannotCertifyFullRemoteCallerPredicateDespiteMatchingRequestDigest() throws {
        let f = try fixture(), a = try enroll(f, create(f))
        _ = try installLease(f, a)
        let executionID = UUID().uuidString, item = try XCTUnwrap(a.handle).uri
        let arguments: CapabilityArguments = ["challenge": "narrow-challenge"]
        let verification = VerificationSpec(predicates: [.init(type: .textEquals, value: "required-caller-result")])
        let digest = try EnvironmentContextualInvocation.digest(executionID: executionID, capabilityID: "environment:execute",
            item: item, arguments: arguments, verification: verification, expectedOutput: nil, dependencies: [])
        let admission = try f.coordinator.rootAdmission(executionID: executionID, requestDigest: digest)
        _ = try f.coordinator.executeChallenge(environmentID: a.environmentID, challenge: "narrow-challenge",
            admission: admission, confirmed: true)
        let signed = try reportedProof(f, executionID: executionID, value: "narrow-challenge")
        let certificate = try f.coordinator.adjudicateProof(signed, hostSigner: f.parent)
        XCTAssertEqual(certificate.verification.outcome, .succeeded)
        XCTAssertEqual(try f.coordinator.executionRecord(executionID)?.state, .succeeded)
        XCTAssertEqual(try f.coordinator.proofExpectation(executionID: executionID).binding.requestDigest,
            digest.map { String(format: "%02x", $0) }.joined())
        // The direct broker verified only its challenge; the caller's distinct
        // predicate was compiled into the digest but never evaluated by RCIR.
        XCTAssertThrowsError(try f.coordinator.remoteProofExpectation(executionID: executionID,
            capabilityID: "environment:execute", item: item, arguments: arguments, verification: verification)) { error in
            XCTAssertEqual(error as? EnvironmentEvidenceError, .bindingMismatch)
        }
    }

    func testFinalCallerFailureCannotBeReopenedByObservationProofOrReconciliation() throws {
        let f = try fixture(), a = try enroll(f, create(f))
        _ = try installLease(f, a)
        let admission = try root(f.coordinator)
        var final = try f.coordinator.executeChallenge(environmentID: a.environmentID, challenge: "correct-challenge", admission: admission, confirmed: true)
        let signed = try reportedProof(f, executionID: admission.executionID, value: "correct-challenge")
        final.state = .failed; final.message = "The caller's additional required postcondition failed."
        try f.coordinator.storeExecutionRecord(final)
        XCTAssertNoThrow(try f.coordinator.storeExecutionRecord(final))
        _ = try f.coordinator.observe(environmentID: a.environmentID)
        XCTAssertEqual(try f.coordinator.verifyChallenge(executionID: admission.executionID).state, .failed)
        XCTAssertThrowsError(try f.coordinator.adjudicateProof(signed, hostSigner: f.parent))
        XCTAssertNil(try f.coordinator.auditEvidence(executionID: admission.executionID).1)
        let selector = try dependency(f, executionID: admission.executionID, proof: signed)
        XCTAssertFalse(try f.coordinator.canSatisfyDependencies([selector]))
        XCTAssertThrowsError(try ExecutionDependencyValidator.validate(selector, proof: signed, certificate: nil,
            trustedChildPublicKey: a.runtime!.publicKey, trustedHostPublicKey: f.parent.publicKey,
            consumingExecutionID: UUID().uuidString, consumingRequestDigest: String(repeating: "d", count: 64),
            nowMilliseconds: f.clock.time, using: RCIREd25519Verifier()))
        var promoted = final; promoted.state = .succeeded
        XCTAssertThrowsError(try f.coordinator.storeExecutionRecord(promoted))
        f.clock.time = a.intent.expiresAtMilliseconds
        _ = try f.coordinator.reconcile()
        XCTAssertEqual(try f.coordinator.verifyChallenge(executionID: admission.executionID).state, .failed)
        let reopened = try makeCoordinator(f.provider, f.parent, f.clock, f.path, f.manifest, f.spec)
        XCTAssertEqual(try reopened.executionRecord(admission.executionID)?.state, .failed)
        XCTAssertEqual(try reopened.executionRecord(admission.executionID)?.message, final.message)
    }

    func testFinalUnknownDestroyDoesNotPromoteWhenResourcesLaterDisappear() throws {
        let f = try fixture(), a = try create(f), admission = try root(f.coordinator)
        f.provider.configureFaults { $0.partitioned = true }
        let blocked = try f.coordinator.destroy(environmentID: a.environmentID, admission: admission, confirmed: true)
        XCTAssertEqual(blocked.state, .unknown)
        var final = try XCTUnwrap(f.coordinator.executionRecord(admission.executionID))
        final.state = .unknown; final.message = "Engine finalized the original uncertain caller request."
        try f.coordinator.storeExecutionRecord(final)
        f.provider.configureFaults { $0.partitioned = false }
        XCTAssertTrue(try f.coordinator.reconcile().allSatisfy { $0.state == .destroyed })
        XCTAssertEqual(try f.coordinator.executionRecord(admission.executionID)?.state, .unknown)
        _ = try f.coordinator.destroy(environmentID: a.environmentID, admission: admission, confirmed: true)
        XCTAssertEqual(try f.coordinator.executionRecord(admission.executionID)?.message, final.message)
    }

    func testCreationObservationCannotRewriteFinalCallerFailure() throws {
        let f = try fixture(), created = try create(f)
        var final = try XCTUnwrap(f.coordinator.executionRecord(created.intent.creationExecutionID))
        final.state = .failed; final.message = "Caller expected another resource URI."
        try f.coordinator.storeExecutionRecord(final)
        _ = try f.coordinator.observe(environmentID: created.environmentID)
        XCTAssertEqual(try f.coordinator.executionRecord(final.executionId)?.state, .failed)
        XCTAssertEqual(try f.coordinator.record(environmentID: created.environmentID)?.observation?.presence, .present)
    }

    func testNarrowLeaseCannotClaimResourceIsolationInsideLargerEnvironment() throws {
        let f = try fixture(), a = try enroll(f, create(f))
        let runtime = try XCTUnwrap(a.runtime)
        let body = try CapabilityLease(leaseID: UUID(), issuerPublicKey: f.parent.publicKey, subjectPublicKey: runtime.publicKey,
            subjectRuntimeID: runtime.runtimeID, environmentID: UUID(uuidString: a.environmentID)!,
            issuingExecutionID: a.intent.creationExecutionID, capabilityIDs: ["environment:execute"], profileIDs: ["challenge"],
            issuedAtMilliseconds: f.clock.time, expiresAtMilliseconds: a.intent.expiresAtMilliseconds,
            nonce: Data(repeating: 8, count: 32), limits: .init(maximumExecutions: 1, maximumChildren: 0,
                maximumDescendants: 0, delegationDepth: 0, cpuCount: 1, memoryMiB: 128, maximumCostUnits: 10_000), networkAllowlist: [])
        let signed = try SignedCapabilityLease.sign(body, using: f.parent)
        XCTAssertThrowsError(try f.coordinator.installSignedLease(signed))
        XCTAssertFalse(try f.coordinator.canDiscover(capabilityID: "environment:execute", environmentID: a.environmentID))
        XCTAssertThrowsError(try f.coordinator.executeChallenge(environmentID: a.environmentID, challenge: "understated-memory", admission: root(f.coordinator), confirmed: true))
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("challenge:") }.count, 0)
    }

    func testRuntimeSHAChangeRevokesAuthorityBeforeAnyNewWorkload() throws {
        let f = try fixture(), a = try enroll(f, create(f)), lease = try installLease(f, a)
        let admitted = try child(f, a, lease)
        f.provider.configureFaults { $0.runtimeManifestOverride = try! .init(version: "replacement", executableSHA256: String(repeating: "b", count: 64), architecture: "arm64") }
        XCTAssertThrowsError(try f.coordinator.executeChallenge(environmentID: a.environmentID, challenge: "old-key", admission: admitted, confirmed: true))
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("challenge:") }.count, 0)
        let changed = try XCTUnwrap(f.coordinator.record(environmentID: a.environmentID))
        XCTAssertTrue(changed.revoked)
        XCTAssertNil(changed.runtime)
        XCTAssertNotNil(changed.enrollmentCertificate)
        XCTAssertFalse(try f.coordinator.canDiscover(capabilityID: "environment:execute", environmentID: a.environmentID))
        f.provider.configureFaults { $0.runtimeManifestOverride = nil }
        _ = try f.coordinator.observe(environmentID: a.environmentID)
        XCTAssertNil(try f.coordinator.record(environmentID: a.environmentID)?.runtime)
    }

    func testSuccessorRuntimeKeyRevokesAuthorityButPreservesCompletedOwnerReceipt() throws {
        var proxy: RuntimeObservationProxy!
        let f = try fixture(providerTransform: { provider in proxy = RuntimeObservationProxy(provider); return proxy })
        let a = try enroll(f, create(f)), lease = try installLease(f, a), admitted = try child(f, a, lease)
        _ = try f.coordinator.executeChallenge(environmentID: a.environmentID, challenge: "prior-success", admission: admitted, confirmed: true)
        let final = try f.coordinator.verifyChallenge(executionID: admitted.executionID)
        try f.coordinator.storeExecutionRecord(final)
        proxy.replacementKey = Data(repeating: 9, count: 32)
        _ = try f.coordinator.observe(environmentID: a.environmentID)
        XCTAssertFalse(try f.coordinator.canDiscover(capabilityID: "environment:execute", environmentID: a.environmentID))
        XCTAssertThrowsError(try f.coordinator.executeChallenge(environmentID: a.environmentID, challenge: "replacement-denied", admission: root(f.coordinator), confirmed: true))
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("challenge:") }.count, 1)
        XCTAssertEqual(try f.coordinator.executionRecord(admitted.executionID)?.state, .succeeded)
        XCTAssertTrue(try f.coordinator.canReadExecution(executionID: admitted.executionID,
            subjectPublicKey: a.runtime!.publicKey, runtimeID: a.runtime!.runtimeID, environmentID: a.environmentID))
    }

    func testMissingRuntimeObservationSuspendsUntilOriginalIdentityIsObservedAgain() throws {
        var proxy: RuntimeObservationProxy!
        let f = try fixture(providerTransform: { provider in proxy = RuntimeObservationProxy(provider); return proxy })
        let a = try enroll(f, create(f))
        _ = try installLease(f, a)
        proxy.omitRuntime = true
        _ = try f.coordinator.observe(environmentID: a.environmentID)
        XCTAssertFalse(try f.coordinator.canDiscover(capabilityID: "environment:execute", environmentID: a.environmentID))
        XCTAssertThrowsError(try f.coordinator.executeChallenge(environmentID: a.environmentID, challenge: "missing-denied", admission: root(f.coordinator), confirmed: true))
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("challenge:") }.count, 0)
        proxy.omitRuntime = false
        _ = try f.coordinator.observe(environmentID: a.environmentID)
        XCTAssertTrue(try f.coordinator.canDiscover(capabilityID: "environment:execute", environmentID: a.environmentID))
        XCTAssertEqual(try f.coordinator.record(environmentID: a.environmentID)?.runtime?.publicKey, a.runtime?.publicKey)
    }

    func testAttenuatedLeaseStillMustCoverActualDescendantResources() throws {
        let f = try fixture(), a = try enroll(f, create(f)), lease = try installLease(f, a)
        let b = try f.coordinator.create(spec: f.spec, correlationID: UUID().uuidString, admission: child(f, a, lease), confirmed: true)
        let enrolledB = try enroll(f, b)
        XCTAssertThrowsError(try delegate(f, parent: a, childRecord: enrolledB, parentLease: lease, memoryMiB: 128))
        XCTAssertFalse(try f.coordinator.canDiscover(capabilityID: "environment:execute", environmentID: b.environmentID))
        XCTAssertThrowsError(try f.coordinator.executeChallenge(environmentID: b.environmentID, challenge: "narrow-denied", admission: root(f.coordinator), confirmed: true))
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("challenge:") }.count, 0)
    }

    func testProductionDependencyAdmissionRejectsMissingAndStaleEvidenceBeforeEffects() throws {
        let f = try fixture(), a = try enroll(f, create(f))
        _ = try installLease(f, a)
        let first = try root(f.coordinator)
        _ = try f.coordinator.executeChallenge(environmentID: a.environmentID, challenge: "causal-first", admission: first, confirmed: true)
        let proof = try reportedProof(f, executionID: first.executionID, value: "causal-first")
        _ = try f.coordinator.adjudicateProof(proof, hostSigner: f.parent)
        let selector = try dependency(f, executionID: first.executionID, proof: proof)
        let missing = try ExecutionDependency(executionID: UUID().uuidString, environmentID: a.environmentID,
            requestDigest: String(repeating: "d", count: 64), proofDigest: String(repeating: "e", count: 64),
            predicateID: selector.predicateID, observerID: selector.observerID, maximumAgeMilliseconds: 60_000, oneUse: true)
        XCTAssertThrowsError(try f.coordinator.requiringDependencies([missing], admission: root(f.coordinator)))
        let next = try f.coordinator.requiringDependencies([selector], admission: root(f.coordinator))
        f.clock.time += 60_001
        XCTAssertThrowsError(try f.coordinator.executeChallenge(environmentID: a.environmentID, challenge: "causal-denied", admission: next, confirmed: true))
        XCTAssertFalse(try f.coordinator.canSatisfyDependencies([selector]))
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("challenge:") }.count, 1)
    }

    func testProductionDependencyAdmissionConsumesExactProofBeforeEffectAndRejectsAnotherConsumer() throws {
        let f = try fixture(), a = try enroll(f, create(f))
        _ = try installLease(f, a)
        let first = try root(f.coordinator)
        _ = try f.coordinator.executeChallenge(environmentID: a.environmentID, challenge: "causal-first", admission: first, confirmed: true)
        let proof = try reportedProof(f, executionID: first.executionID, value: "causal-first")
        _ = try f.coordinator.adjudicateProof(proof, hostSigner: f.parent)
        let selector = try dependency(f, executionID: first.executionID, proof: proof)
        XCTAssertTrue(try f.coordinator.canSatisfyDependencies([selector]))
        let nextBase = try root(f.coordinator)
        let next = try f.coordinator.requiringDependencies([selector], admission: nextBase)
        XCTAssertNoThrow(try f.coordinator.requiringDependencies([selector], admission: nextBase))
        XCTAssertThrowsError(try f.coordinator.requiringDependencies([selector], admission: root(f.coordinator)))
        _ = try f.coordinator.executeChallenge(environmentID: a.environmentID, challenge: "causal-second", admission: next, confirmed: true)
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("challenge:") }.count, 2)
    }

    func testDelayedAcceptedCreateReappearsAfterTerminalAbsenceAndIsOnlyCleaned() throws {
        var delayed: DelayedCreationProvider!
        let f = try fixture(maximumEnvironments: 1, providerTransform: { provider in
            delayed = DelayedCreationProvider(provider); return delayed
        })
        let admission = try root(f.coordinator), correlation = UUID().uuidString
        let absent = try f.coordinator.create(spec: f.spec, correlationID: correlation, admission: admission, confirmed: true)
        XCTAssertEqual(absent.state, .destroyed)
        XCTAssertNotNil(absent.handle)
        var final = try XCTUnwrap(f.coordinator.executionRecord(admission.executionID))
        final.state = .failed; final.message = "Caller finalized before the accepted resource became observable."
        try f.coordinator.storeExecutionRecord(final)
        XCTAssertTrue(f.provider.operationLog.isEmpty)
        try delayed.releaseAcceptedCreate()
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("create:") }.count, 1)
        let reopened = try makeCoordinator(delayed, f.parent, f.clock, f.path, f.manifest, f.spec, 1)
        let cleanup = try reopened.observe(environmentID: absent.environmentID)
        XCTAssertEqual(cleanup.state, .stopping)
        XCTAssertTrue(cleanup.revoked)
        XCTAssertNil(cleanup.runtime)
        XCTAssertTrue(cleanup.leaseIDs.isEmpty)
        XCTAssertNotNil(cleanup.stopIntentID)
        XCTAssertNotNil(cleanup.destroyIntentID)
        XCTAssertEqual(cleanup.handle, absent.handle)
        XCTAssertFalse(try reopened.canDiscover(capabilityID: "environment:bootstrap", environmentID: absent.environmentID))
        XCTAssertTrue(try reopened.reconcile().allSatisfy { $0.state == .destroyed && $0.revoked })
        XCTAssertEqual(try f.provider.observe(correlationID: correlation).presence, .absent)
        XCTAssertEqual(delayed.createDispatchCount, 1)
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("destroy:") }, ["destroy:" + absent.environmentID])
        XCTAssertEqual(try reopened.executionRecord(admission.executionID)?.state, .failed)
        XCTAssertEqual(try reopened.executionRecord(admission.executionID)?.message, final.message)
        XCTAssertThrowsError(try reopened.create(spec: f.spec, correlationID: UUID().uuidString, admission: root(reopened), confirmed: true))
        XCTAssertEqual(try reopened.records().count, 1)
        XCTAssertEqual(delayed.createDispatchCount, 1)
    }

    func testTerminalReconciliationCleansExactDelayedResourceAndDeniesChangedResourceIdentity() throws {
        var delayed: DelayedCreationProvider!
        let f = try fixture(maximumEnvironments: 1, providerTransform: { provider in
            delayed = DelayedCreationProvider(provider); return delayed
        })
        let absent = try create(f)
        XCTAssertEqual(absent.state, .destroyed)
        try delayed.releaseAcceptedCreate()
        delayed.observedResourceIDOverride = "mem-different-resource"
        _ = try f.coordinator.reconcile()
        let denied = try XCTUnwrap(f.coordinator.record(environmentID: absent.environmentID))
        XCTAssertEqual(denied.observation?.presence, .unknown)
        XCTAssertEqual(denied.handle, absent.handle)
        XCTAssertTrue(denied.revoked)
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("destroy:") }.count, 0)
        delayed.observedResourceIDOverride = nil
        XCTAssertTrue(try f.coordinator.reconcile().allSatisfy { $0.state == .destroyed && $0.revoked })
        XCTAssertEqual(try f.provider.observe(correlationID: absent.intent.correlationID).presence, .absent)
        XCTAssertEqual(delayed.createDispatchCount, 1)

        var exactDelayed: DelayedCreationProvider!
        let exact = try fixture(providerTransform: { provider in exactDelayed = DelayedCreationProvider(provider); return exactDelayed })
        let terminal = try create(exact)
        try exactDelayed.releaseAcceptedCreate()
        // This enters reconciliation while the durable row is still terminal.
        XCTAssertEqual(try exact.coordinator.record(environmentID: terminal.environmentID)?.state, .destroyed)
        XCTAssertTrue(try exact.coordinator.reconcile().allSatisfy { $0.state == .destroyed && $0.revoked })
        XCTAssertEqual(exact.provider.operationLog.filter { $0.hasPrefix("destroy:") }, ["destroy:" + terminal.environmentID])
        XCTAssertEqual(exactDelayed.createDispatchCount, 1)
    }

    func testUnboundUnknownCreateAbsenceRetainsCleanupIntentUntilOriginalOperationMaterializes() throws {
        var delayed: DelayedCreationProvider!
        let f = try fixture(maximumEnvironments: 1, providerTransform: { provider in
            delayed = DelayedCreationProvider(provider); delayed.omitAcceptedResourceID = true; return delayed
        })
        let admission = try root(f.coordinator), correlation = UUID().uuidString
        let uncertain = try f.coordinator.create(spec: f.spec, correlationID: correlation, admission: admission, confirmed: true)
        XCTAssertEqual(uncertain.state, .unknown)
        XCTAssertTrue(uncertain.revoked)
        XCTAssertNil(uncertain.handle)
        XCTAssertNotNil(uncertain.stopIntentID)
        XCTAssertNotNil(uncertain.destroyIntentID)
        var final = try XCTUnwrap(f.coordinator.executionRecord(admission.executionID))
        final.state = .unknown; final.message = "The original unbound create remained unresolved."
        try f.coordinator.storeExecutionRecord(final)
        _ = try f.coordinator.create(spec: f.spec, correlationID: correlation, admission: admission, confirmed: true)
        XCTAssertEqual(delayed.createDispatchCount, 1)
        XCTAssertEqual(try f.coordinator.reconcile().first?.state, .unknown)
        try delayed.releaseAcceptedCreate()
        XCTAssertTrue(try f.coordinator.reconcile().allSatisfy { $0.state == .destroyed && $0.revoked })
        let cleaned = try XCTUnwrap(f.coordinator.record(environmentID: uncertain.environmentID))
        XCTAssertNotNil(cleaned.handle)
        XCTAssertNil(cleaned.runtime)
        XCTAssertEqual(cleaned.stopIntentID, uncertain.stopIntentID)
        XCTAssertEqual(cleaned.destroyIntentID, uncertain.destroyIntentID)
        XCTAssertEqual(try f.coordinator.executionRecord(admission.executionID)?.state, .unknown)
        XCTAssertEqual(try f.coordinator.executionRecord(admission.executionID)?.message, final.message)
        XCTAssertEqual(delayed.createDispatchCount, 1)
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("create:") }.count, 1)
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("destroy:") }, ["destroy:" + uncertain.environmentID])
        XCTAssertThrowsError(try f.coordinator.create(spec: f.spec, correlationID: UUID().uuidString, admission: root(f.coordinator), confirmed: true))
    }

    func testUnboundDelayedCreateIsPinnedOnlyForCleanupAfterBrokerRecovery() throws {
        var delayed: DelayedCreationProvider!
        let f = try fixture(maximumEnvironments: 1, providerTransform: { provider in
            delayed = DelayedCreationProvider(provider); delayed.omitAcceptedResourceID = true; return delayed
        })
        let admission = try root(f.coordinator)
        let uncertain = try f.coordinator.create(spec: f.spec, correlationID: UUID().uuidString, admission: admission, confirmed: true)
        var final = try XCTUnwrap(f.coordinator.executionRecord(admission.executionID))
        final.state = .unknown
        try f.coordinator.storeExecutionRecord(final)
        let recovered = try makeCoordinator(delayed, f.parent, f.clock, f.path, f.manifest, f.spec, 1)
        XCTAssertEqual(try recovered.record(environmentID: uncertain.environmentID)?.state, .unknown)
        try delayed.releaseAcceptedCreate()
        let pinned = try recovered.observe(environmentID: uncertain.environmentID)
        XCTAssertEqual(pinned.state, .stopping)
        XCTAssertTrue(pinned.revoked)
        XCTAssertNotNil(pinned.handle)
        XCTAssertNil(pinned.runtime)
        XCTAssertTrue(pinned.leaseIDs.isEmpty)
        XCTAssertFalse(try recovered.canDiscover(capabilityID: "environment:bootstrap", environmentID: pinned.environmentID))
        XCTAssertFalse(try recovered.canDiscover(capabilityID: "environment:execute", environmentID: pinned.environmentID))
        XCTAssertTrue(try recovered.reconcile().allSatisfy { $0.state == .destroyed && $0.revoked })
        XCTAssertEqual(delayed.createDispatchCount, 1)
        XCTAssertEqual(try recovered.executionRecord(admission.executionID)?.state, .unknown)
        XCTAssertEqual(try recovered.records().count, 1)
    }
}
