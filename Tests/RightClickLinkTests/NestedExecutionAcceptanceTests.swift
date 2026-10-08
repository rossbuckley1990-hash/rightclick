import Foundation
import XCTest
import MCP
import RightClickProtocol
import RightClickProviders
import RightClickCore
@testable import RightClickLink
@testable import RightClickMCP

/// Real Core/MCP/Link paths over an explicitly simulated environment substrate.
/// No cloud credential, Linux VM, child process, or live bootstrap is implied.
final class NestedExecutionAcceptanceTests: XCTestCase {
    private final class Clock { var now: Int64 = 1_800_000_000_000 }
    private final class Proofs {
        var signed: [String: SignedExecutionProof] = [:]
        var certificates: [String: SignedExecutionVerificationCertificate] = [:]
    }
    private final class Approval: RemoteLocalApproval {
        var exactTicket: RemoteApprovalTicket?
        var reviewedChallenge: String?
        var approvedRequests: [RemoteExecutionRequest] = []
        func approval(for request: RemoteExecutionRequest, capabilityDigest: String) -> RemoteApprovalTicket? {
            if let exactTicket { return exactTicket }
            // The fixture represents the local host reviewing this exact narrow
            // request. Caller confirmation and a signed grant do not approve it.
            guard request.capabilityID == "environment:execute",
                  request.arguments == ["challenge": reviewedChallenge ?? ""], reviewedChallenge != nil else { return nil }
            guard let ticket = try? RemoteApprovalTicket(approvedRequest: request, capabilityDigest: capabilityDigest) else { return nil }
            approvedRequests.append(request)
            return ticket
        }
    }
    @MainActor private final class Endpoint {
        let identity: RemoteNodeIdentity
        let approval = Approval()
        let dispatcher: RemoteExecutionDispatcher
        init(engine: CapabilityEngine, caller: RemoteNodeIdentity, directory: URL, clock: Clock,
             identity: RemoteNodeIdentity, capabilities: Set<String>) throws {
            self.identity = identity
            let ledger = try RemoteReplayLedger(directory: directory, runtimeID: identity.runtimeID)
            let grant = try RemoteCallerGrant(publicKey: caller.publicKey, operations: [.runtime, .actions, .run, .status],
                capabilityIDs: capabilities, exportValueCapabilityIDs: capabilities)
            dispatcher = try RemoteExecutionDispatcher(engine: engine, identity: identity, ledger: ledger,
                grants: [grant], enabled: true, localApproval: approval, now: { clock.now })
        }
        func request(caller: RemoteNodeIdentity, clock: Clock, operation: RemoteOperation, item: String,
                     capability: RemoteCapabilityDescriptor? = nil, arguments: CapabilityArguments? = nil) -> RemoteExecutionRequest {
            var random = SystemRandomNumberGenerator()
            return .init(issuedAtMilliseconds: clock.now, expiresAtMilliseconds: clock.now + 60_000,
                targetRuntimeID: identity.runtimeID, targetDeviceID: identity.deviceID,
                callerID: RemoteWire.digest(caller.publicKey),
                nonce: Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }),
                operation: operation, capabilityID: capability?.id, capabilityDigest: capability?.contractDigest,
                item: item, arguments: arguments)
        }
        func send(_ request: RemoteExecutionRequest, caller: RemoteNodeIdentity) throws -> RemoteExecutionResult {
            let bytes = try SignedRemoteMessage.request(request, signer: caller)
            return try SignedRemoteMessage.verifiedResult(dispatcher.handle(bytes), for: bytes, trustedRuntimeKey: identity.publicKey)
        }
    }
    @MainActor private final class Fixture {
        let directory: URL
        let clock = Clock()
        let proofs = Proofs()
        let provider: InMemoryEnvironmentProvider
        let rootSigner: RCIREd25519Signer
        let rootIdentity: RemoteNodeIdentity
        let manifest: EnvironmentRuntimeManifest
        let parentSpec: EnvironmentSpec
        let childSpec: EnvironmentSpec
        let coordinator: EnvironmentCoordinator
        let parentEngine: CapabilityEngine
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-nested-acceptance-" + UUID().uuidString)
                .standardizedFileURL.resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let clock = clock
            provider = try InMemoryEnvironmentProvider(clock: { clock.now })
            rootSigner = try RCIREd25519Signer(rawPrivateKey: Data(repeating: 1, count: 32))
            rootIdentity = try RemoteNodeIdentity(signer: rootSigner)
            manifest = try EnvironmentRuntimeManifest(version: "nested-acceptance-1", executableSHA256: String(repeating: "a", count: 64), architecture: "arm64")
            parentSpec = try EnvironmentSpec(profileID: "approved-challenge", lifetimeMilliseconds: 300_000,
                resources: .init(cpuCount: 1, memoryMiB: 512, maximumCostUnits: 10_000))
            childSpec = try EnvironmentSpec(profileID: "approved-challenge", lifetimeMilliseconds: 120_000,
                resources: .init(cpuCount: 1, memoryMiB: 256, maximumCostUnits: 5_000))
            coordinator = try Self.makeCoordinator(provider: provider, signer: rootSigner, clock: clock,
                journal: directory.appendingPathComponent("environment-journal"), manifest: manifest, spec: parentSpec)
            let source = try Self.source(coordinator: coordinator, provider: provider, signer: rootSigner, clock: clock,
                proofs: proofs, manifest: manifest, spec: parentSpec)
            parentEngine = CapabilityEngine(reflectorSources: [source], experience: nil)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        static func makeCoordinator(provider: InMemoryEnvironmentProvider, signer: RCIREd25519Signer, clock: Clock,
                                    journal: URL, manifest: EnvironmentRuntimeManifest, spec: EnvironmentSpec) throws -> EnvironmentCoordinator {
            try EnvironmentCoordinator(provider: provider, journalDirectory: journal,
                hostRuntimeID: "runtime:" + ExecutionEvidenceDigest.sha256(signer.publicKey), trustedRootIssuerPublicKeys: [signer.publicKey],
                profiles: [spec.profileID: manifest], profileCeilings: [spec.profileID: spec], operatorPublicKey: signer.publicKey,
                maximumEnvironments: 2, maximumTotalCostUnits: 20_000,
                enrollmentVerifier: { handle, expected, challenge, observation, bytes in
                    let independentlyObserved = try XCTUnwrap(observation.runtime)
                    return try ChildRuntimeEnrollmentVerifier.verify(signedClaim: bytes, expectedHandle: handle,
                        expectedManifest: expected, expectedEnrollmentID: challenge.enrollmentID, expectedChallenge: challenge.challenge,
                        trustedBootstrapPublicKey: independentlyObserved.publicKey, observation: observation, now: clock.now)
                        .certificate(using: signer)
                }, now: { clock.now })
        }
        static func source(coordinator: EnvironmentCoordinator, provider: InMemoryEnvironmentProvider,
                           signer: RCIREd25519Signer, clock: Clock, proofs: Proofs, manifest: EnvironmentRuntimeManifest,
                           spec: EnvironmentSpec, caller: EnvironmentCallerIdentity? = nil,
                           prerequisites: [String: [ExecutionDependency]] = [:]) throws -> EnvironmentCapabilitySource {
            try EnvironmentCapabilitySource(coordinator: coordinator, spec: spec, caller: caller, prerequisites: prerequisites, afterBootstrap: { record in
                let challenge = try XCTUnwrap(record.enrollmentChallenge), handle = try XCTUnwrap(record.handle)
                let observation = try provider.observe(correlationID: record.intent.correlationID)
                let runtime = try XCTUnwrap(observation.runtime)
                let claim = try ChildRuntimeClaim(enrollmentID: challenge.enrollmentID, handle: handle, manifest: manifest,
                    publicKey: runtime.publicKey, challenge: challenge.challenge, issuedAtMilliseconds: clock.now,
                    expiresAtMilliseconds: challenge.expiresAtMilliseconds)
                let signed = try provider.signedRuntimeClaim(claim)
                _ = try coordinator.enroll(environmentID: record.environmentID, response: signed.wireData())
            }, afterWorkload: { executionID in
                let expectation = try coordinator.proofExpectation(executionID: executionID)
                let proof = try ExecutionProof(binding: expectation.binding, challengeNonce: expectation.challengeNonce,
                    issuedAtMilliseconds: clock.now, observedAtMilliseconds: clock.now,
                    expiresAtMilliseconds: expectation.deadlineMilliseconds, sequence: expectation.expectedSequence,
                    predicateID: expectation.predicateID, providerAccepted: true, reportedOutcome: .succeeded,
                    reportedValue: expectation.expectedValue, reportBoundary: "Simulated child assertion; no VM or process proof.")
                let signed = try provider.signedExecutionProof(proof)
                proofs.signed[executionID] = signed
                proofs.certificates[executionID] = try coordinator.adjudicateProof(signed, hostSigner: signer)
            })
        }
        func rootLease(for record: EnvironmentRecord) throws -> SignedCapabilityLease {
            let runtime = try XCTUnwrap(record.runtime)
            let body = try CapabilityLease(leaseID: UUID(), issuerPublicKey: rootSigner.publicKey, subjectPublicKey: runtime.publicKey,
                subjectRuntimeID: runtime.runtimeID, environmentID: XCTUnwrap(UUID(uuidString: record.environmentID)),
                issuingExecutionID: record.intent.creationExecutionID,
                capabilityIDs: ["environment:execute", "environment:create-child", "environment:destroy", "environment:observe"],
                profileIDs: [parentSpec.profileID], issuedAtMilliseconds: clock.now, expiresAtMilliseconds: clock.now + 240_000,
                nonce: Data(repeating: 7, count: 32), limits: .init(maximumExecutions: 12, maximumChildren: 1,
                    maximumDescendants: 1, delegationDepth: 1, cpuCount: 1, memoryMiB: 512, maximumCostUnits: 20_000), networkAllowlist: [])
            let signed = try SignedCapabilityLease.sign(body, using: rootSigner)
            try coordinator.installSignedLease(signed)
            return signed
        }
        func childLease(parent: EnvironmentRecord, child: EnvironmentRecord, parentLease: SignedCapabilityLease) throws -> SignedCapabilityLease {
            let a = try XCTUnwrap(parent.runtime), b = try XCTUnwrap(child.runtime)
            let body = try CapabilityLease(leaseID: UUID(), issuerPublicKey: a.publicKey, subjectPublicKey: b.publicKey,
                subjectRuntimeID: b.runtimeID, environmentID: XCTUnwrap(UUID(uuidString: child.environmentID)),
                parentLeaseID: parentLease.body.leaseID, parentLeaseDigest: parentLease.body.digest(),
                issuingExecutionID: child.intent.creationExecutionID, capabilityIDs: ["environment:execute", "environment:observe", "environment:destroy"],
                profileIDs: [childSpec.profileID], issuedAtMilliseconds: clock.now, expiresAtMilliseconds: child.intent.expiresAtMilliseconds,
                nonce: Data(repeating: 8, count: 32), limits: .init(maximumExecutions: 3, maximumChildren: 0,
                    maximumDescendants: 0, delegationDepth: 0, cpuCount: 1, memoryMiB: 256, maximumCostUnits: 5_000), networkAllowlist: [])
            let signed = try provider.signedCapabilityLease(body, issuerEnvironmentID: parent.environmentID)
            try coordinator.delegateSignedLease(signed, parentLeaseID: parentLease.body.leaseID,
                admission: coordinator.authenticatedAdmission(executionID: UUID().uuidString, requestDigest: Data(repeating: 9, count: 32),
                    subjectPublicKey: a.publicKey, runtimeID: a.runtimeID, environmentID: parent.environmentID, leaseID: parentLease.body.leaseID))
            return signed
        }
        func caller(_ record: EnvironmentRecord, _ lease: SignedCapabilityLease) throws -> EnvironmentCallerIdentity {
            let runtime = try XCTUnwrap(record.runtime)
            return try .init(publicKey: runtime.publicKey, runtimeID: runtime.runtimeID,
                environmentID: record.environmentID, leaseID: lease.body.leaseID)
        }
    }
    private struct Actions: Decodable {
        struct Action: Decodable { let id: String; let requiresConfirmation: Bool }
        let kind: String
        let actions: [Action]
    }
    @MainActor private func actions(_ engine: CapabilityEngine, _ item: String) throws -> Actions {
        let json = try handleTool("context_actions", arguments: ["item": .string(item)], engine: EngineBox(engine), transport: "stdio")
        return try JSONDecoder().decode(Actions.self, from: Data(json.utf8))
    }
    @MainActor private func run(_ engine: CapabilityEngine, _ item: String, _ action: String,
                                confirmed: Bool = true, arguments: CapabilityArguments? = nil,
                                verification: VerificationSpec? = nil) throws -> ExecutionRecord {
        var input: [String: Value] = ["item": .string(item), "actionId": .string(action), "confirmed": .bool(confirmed)]
        if let arguments { input["arguments"] = .object(arguments.mapValues(Value.string)) }
        if let verification { input["verification"] = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(verification)) }
        let json = try handleTool("context_run", arguments: input, engine: EngineBox(engine), transport: "stdio")
        return try JSONDecoder().decode(ExecutionRecord.self, from: Data(json.utf8))
    }
    @MainActor private func refreshed(_ engine: CapabilityEngine, _ id: String, cursor: Int = 0,
                                      limit: Int = 64, maximumBytes: Int = 262_144) async throws -> ExecutionRecord {
        let json = try await handleToolRefreshing("context_run_status", arguments: ["executionId": .string(id), "cursor": .int(cursor),
            "limit": .int(limit), "maximumBytes": .int(maximumBytes)], engine: EngineBox(engine), transport: "stdio")
        return try JSONDecoder().decode(ExecutionRecord.self, from: Data(json.utf8))
    }
    @MainActor private func ready(_ f: Fixture) throws -> (EnvironmentRecord, SignedCapabilityLease) {
        let created = try run(f.parentEngine, EnvironmentIdentity.factoryURI, "environment:create", arguments: ["correlationID": UUID().uuidString])
        XCTAssertEqual(created.state, .succeeded)
        let uri = try XCTUnwrap(created.output)
        XCTAssertEqual(try run(f.parentEngine, uri, "environment:bootstrap").state, .succeeded)
        let record = try XCTUnwrap(f.coordinator.record(environmentID: EnvironmentIdentity.environmentID(from: uri)))
        return (record, try f.rootLease(for: record))
    }
    @MainActor private func reopen(_ f: Fixture, caller: EnvironmentCallerIdentity? = nil,
                                   prerequisites: [String: [ExecutionDependency]] = [:]) throws -> (EnvironmentCoordinator, CapabilityEngine) {
        let coordinator = try Fixture.makeCoordinator(provider: f.provider, signer: f.rootSigner, clock: f.clock,
            journal: f.directory.appendingPathComponent("environment-journal"), manifest: f.manifest, spec: f.parentSpec)
        let source = try Fixture.source(coordinator: coordinator, provider: f.provider, signer: f.rootSigner, clock: f.clock,
            proofs: Proofs(), manifest: f.manifest, spec: f.parentSpec, caller: caller, prerequisites: prerequisites)
        return (coordinator, CapabilityEngine(reflectorSources: [source], experience: nil))
    }
    @MainActor private func simulatedChildProof(_ f: Fixture, executionID: String) throws -> SignedExecutionProof {
        let expected = try f.coordinator.proofExpectation(executionID: executionID)
        let body = try ExecutionProof(binding: expected.binding, challengeNonce: expected.challengeNonce,
            issuedAtMilliseconds: f.clock.now, observedAtMilliseconds: f.clock.now, expiresAtMilliseconds: expected.deadlineMilliseconds,
            sequence: expected.expectedSequence, predicateID: expected.predicateID, providerAccepted: true,
            reportedOutcome: .succeeded, reportedValue: expected.expectedValue, reportBoundary: "Simulated child claiming success; no process or cloud evidence.")
        return try f.provider.signedExecutionProof(body)
    }
    @MainActor private func dependency(_ f: Fixture, proof: SignedExecutionProof,
                                      maximumAge: Int64 = 60_000, oneUse: Bool = true) throws -> ExecutionDependency {
        try .init(executionID: proof.proof.binding.executionID, environmentID: proof.proof.binding.environmentID,
            requestDigest: proof.proof.binding.requestDigest, proofDigest: proof.proof.digest,
            predicateID: proof.proof.predicateID, observerID: f.coordinator.hostRuntimeID,
            maximumAgeMilliseconds: maximumAge, oneUse: oneUse)
    }

    @MainActor func testMCPCreateCallerFailureCannotBePromotedByObservationReconciliationOrRecovery() async throws {
        let f = try Fixture()
        let failed = try run(f.parentEngine, EnvironmentIdentity.factoryURI, "environment:create",
            arguments: ["correlationID": UUID().uuidString],
            verification: .init(predicates: [.init(type: .textEquals, value: "deliberately-impossible-create-result")]))
        XCTAssertEqual(failed.state, .failed); XCTAssertEqual(failed.rcir?.outcome, "failed")
        XCTAssertEqual(failed.verification?.status, .verifiedFailure)
        XCTAssertFalse(failed.evidence.outcomeVerified)
        let resource = try XCTUnwrap(f.coordinator.records().first)
        XCTAssertEqual(try f.provider.observe(correlationID: resource.intent.correlationID).presence, .present)
        _ = try f.coordinator.observe(environmentID: resource.environmentID)
        _ = try f.coordinator.reconcile()
        let retained = try XCTUnwrap(f.coordinator.executionRecord(failed.executionId))
        XCTAssertEqual(retained.state, .failed); XCTAssertEqual(retained.rcir?.outcome, "failed")
        XCTAssertEqual(retained.rcir?.receipt, failed.rcir?.receipt)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(retained.rcir?.signedReceipt), try encoder.encode(failed.rcir?.signedReceipt))
        let (recovered, engine) = try reopen(f)
        XCTAssertEqual(try recovered.executionRecord(failed.executionId)?.state, .failed)
        let throughMCP = try await refreshed(engine, failed.executionId)
        XCTAssertEqual(throughMCP.state, .failed); XCTAssertEqual(throughMCP.rcir?.outcome, "failed")
        XCTAssertFalse(throughMCP.evidence.outcomeVerified)
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("create:") }.count, 1)
    }

    @MainActor func testMCPWorkloadCallerFailureCannotIssueProofAuthorityOrBecomeSucceeded() async throws {
        let f = try Fixture(), (a, _) = try ready(f)
        let uri = try XCTUnwrap(a.handle).uri, challenge = UUID().uuidString
        let failed = try run(f.parentEngine, uri, "environment:execute", arguments: ["challenge": challenge],
            verification: .init(predicates: [.init(type: .textEquals, value: "different-caller-postcondition")]))
        XCTAssertEqual(failed.state, .failed); XCTAssertEqual(failed.rcir?.outcome, "failed")
        XCTAssertEqual(failed.verification?.status, .verifiedFailure)
        XCTAssertEqual(try f.provider.observeChallenge(XCTUnwrap(a.handle), executionID: failed.executionId), challenge)
        XCTAssertTrue(f.proofs.signed.isEmpty); XCTAssertTrue(f.proofs.certificates.isEmpty)
        XCTAssertNil(failed.environmentEvidence?.signedProof); XCTAssertNil(failed.environmentEvidence?.verificationCertificate)
        let malicious = try simulatedChildProof(f, executionID: failed.executionId)
        try malicious.verify(trustedPublicKey: XCTUnwrap(a.runtime).publicKey, using: RCIREd25519Verifier())
        XCTAssertEqual(malicious.proof.reportedOutcome, .succeeded)
        XCTAssertThrowsError(try f.coordinator.adjudicateProof(malicious, hostSigner: f.rootSigner)) {
            XCTAssertEqual($0 as? EnvironmentEvidenceError, .unsuccessfulDependency)
        }
        XCTAssertEqual(try f.coordinator.verifyChallenge(executionID: failed.executionId).state, .failed)
        let audit = try f.coordinator.auditEvidence(executionID: failed.executionId)
        XCTAssertNil(audit.0); XCTAssertNil(audit.1); XCTAssertEqual(audit.2?.state, .failed)
        let (recovered, engine) = try reopen(f)
        XCTAssertEqual(try recovered.verifyChallenge(executionID: failed.executionId).state, .failed)
        let throughMCP = try await refreshed(engine, failed.executionId)
        XCTAssertEqual(throughMCP.state, .failed); XCTAssertNil(throughMCP.environmentEvidence?.verificationCertificate)
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("challenge:") }.count, 1)
    }

    @MainActor func testHostInstalledMissingFailedAndStaleDependenciesPreventMCPDispatch() throws {
        enum InvalidPrerequisite: CaseIterable { case missing, failed, stale }
        for invalid in InvalidPrerequisite.allCases {
            let f = try Fixture(), (a, _) = try ready(f)
            let uri = try XCTUnwrap(a.handle).uri
            let required: ExecutionDependency
            switch invalid {
            case .missing:
                required = try .init(executionID: UUID().uuidString, environmentID: a.environmentID,
                    requestDigest: String(repeating: "b", count: 64), proofDigest: String(repeating: "c", count: 64),
                    predicateID: "environment.challenge.equals", observerID: f.coordinator.hostRuntimeID,
                    maximumAgeMilliseconds: 60_000, oneUse: true)
            case .failed:
                let producer = try run(f.parentEngine, uri, "environment:execute", arguments: ["challenge": UUID().uuidString],
                    verification: .init(predicates: [.init(type: .textEquals, value: "false-producer-postcondition")]))
                XCTAssertEqual(producer.state, .failed)
                let malicious = try simulatedChildProof(f, executionID: producer.executionId)
                required = try dependency(f, proof: malicious)
                XCTAssertThrowsError(try f.coordinator.adjudicateProof(malicious, hostSigner: f.rootSigner)) {
                    XCTAssertEqual($0 as? EnvironmentEvidenceError, .unsuccessfulDependency)
                }
            case .stale:
                let producer = try run(f.parentEngine, uri, "environment:execute", arguments: ["challenge": UUID().uuidString])
                XCTAssertEqual(producer.state, .succeeded)
                required = try dependency(f, proof: XCTUnwrap(f.proofs.signed[producer.executionId]), maximumAge: 1)
                XCTAssertNotNil(try f.coordinator.evidence(executionID: producer.executionId).1)
                f.clock.now += 2
            }
            let source = try Fixture.source(coordinator: f.coordinator, provider: f.provider, signer: f.rootSigner, clock: f.clock,
                proofs: f.proofs, manifest: f.manifest, spec: f.parentSpec, prerequisites: ["environment:execute": [required]])
            let dependent = CapabilityEngine(reflectorSources: [source], experience: nil)
            let before = f.provider.operationLog.filter { $0.hasPrefix("challenge:") }.count
            let result = try run(dependent, uri, "environment:execute", arguments: ["challenge": UUID().uuidString])
            XCTAssertNotEqual(result.state, .succeeded, "Invalid prerequisite \(invalid) granted semantic success")
            XCTAssertFalse(result.evidence.outcomeVerified)
            XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("challenge:") }.count, before,
                "Invalid prerequisite \(invalid) dispatched a workload")
            XCTAssertTrue(try actions(f.parentEngine, uri).actions.contains { $0.id == "environment:execute" },
                "The unrestricted source must remain ready; resource state cannot explain the refused dependency")
        }
    }

    @MainActor func testHostInstalledVerifiedDependencyConsumesOnceBeforeActualMCPWorkload() throws {
        let f = try Fixture(), (a, _) = try ready(f)
        let uri = try XCTUnwrap(a.handle).uri
        let producer = try run(f.parentEngine, uri, "environment:execute", arguments: ["challenge": UUID().uuidString])
        XCTAssertEqual(producer.state, .succeeded)
        let proof = try XCTUnwrap(f.proofs.signed[producer.executionId])
        let required = try dependency(f, proof: proof)
        let source = try Fixture.source(coordinator: f.coordinator, provider: f.provider, signer: f.rootSigner, clock: f.clock,
            proofs: f.proofs, manifest: f.manifest, spec: f.parentSpec, prerequisites: ["environment:execute": [required]])
        let dependent = CapabilityEngine(reflectorSources: [source], experience: nil)
        XCTAssertTrue(try actions(dependent, uri).actions.contains { $0.id == "environment:execute" })
        let consumer = try run(dependent, uri, "environment:execute", arguments: ["challenge": UUID().uuidString])
        XCTAssertEqual(consumer.state, .succeeded); XCTAssertTrue(consumer.evidence.outcomeVerified)
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("challenge:") }.count, 2)
        XCTAssertTrue(try actions(f.parentEngine, uri).actions.contains { $0.id == "environment:execute" })
        let reused = try run(dependent, uri, "environment:execute", arguments: ["challenge": UUID().uuidString])
        XCTAssertNotEqual(reused.state, .succeeded); XCTAssertFalse(reused.evidence.outcomeVerified)
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("challenge:") }.count, 2)
        let (recovered, recoveredEngine) = try reopen(f, prerequisites: ["environment:execute": [required]])
        XCTAssertFalse(try recovered.canSatisfyDependencies([required]))
        let afterReopen = try run(recoveredEngine, uri, "environment:execute", arguments: ["challenge": UUID().uuidString])
        XCTAssertNotEqual(afterReopen.state, .succeeded)
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("challenge:") }.count, 2)
    }

    @MainActor func testRecoveredRevokedChildMCPStatusPagesHistoryAndExposesRetainedSignedEvidence() async throws {
        let f = try Fixture(), (a, lease) = try ready(f)
        let caller = try f.caller(a, lease), uri = try XCTUnwrap(a.handle).uri
        let source = try Fixture.source(coordinator: f.coordinator, provider: f.provider, signer: f.rootSigner, clock: f.clock,
            proofs: f.proofs, manifest: f.manifest, spec: f.parentSpec, caller: caller)
        let child = CapabilityEngine(reflectorSources: [source], experience: nil)
        let producer = try run(child, uri, "environment:execute", arguments: ["challenge": UUID().uuidString])
        XCTAssertEqual(producer.state, .succeeded)
        let proof = try XCTUnwrap(f.proofs.signed[producer.executionId])
        let certificate = try XCTUnwrap(f.proofs.certificates[producer.executionId])
        let history = try XCTUnwrap(f.coordinator.executionRecord(producer.executionId)?.rcirEvents)
        XCTAssertEqual(history.count, 1) // Unary RCIR retains one terminal event.
        XCTAssertEqual(try run(f.parentEngine, uri, "environment:destroy").state, .succeeded)
        let (recovered, recoveredChild) = try reopen(f, caller: caller)
        XCTAssertTrue(try recovered.canReadExecution(executionID: producer.executionId, subjectPublicKey: caller.publicKey,
            runtimeID: caller.runtimeID, environmentID: caller.environmentID))
        XCTAssertFalse(try recovered.canDiscover(capabilityID: "environment:execute", environmentID: caller.environmentID,
            subjectPublicKey: caller.publicKey, runtimeID: caller.runtimeID, leaseID: caller.leaseID))
        let first = try await refreshed(recoveredChild, producer.executionId, limit: 1)
        let page1 = try XCTUnwrap(first.rcirEventPage)
        XCTAssertEqual(page1.events.map(\.sequence), [1]); XCTAssertEqual(page1.nextCursor, 1)
        XCTAssertFalse(page1.hasMore); XCTAssertTrue(page1.terminal); XCTAssertNil(first.rcirEvents)
        let second = try await refreshed(recoveredChild, producer.executionId, cursor: 1, limit: 1)
        XCTAssertEqual(second.rcirEventPage?.events.map(\.sequence), []); XCTAssertEqual(second.rcirEventPage?.nextCursor, 1)
        let byteLimit = try XCTUnwrap(history.first).canonicalData().count
        let bounded = try await refreshed(recoveredChild, producer.executionId, limit: 64, maximumBytes: byteLimit)
        let boundedPage = try XCTUnwrap(bounded.rcirEventPage)
        XCTAssertEqual(boundedPage.events.map(\.sequence), [1]); XCTAssertEqual(boundedPage.nextCursor, 1)
        XCTAssertFalse(boundedPage.hasMore)
        let publicEvidence = try XCTUnwrap(first.environmentEvidence)
        XCTAssertEqual(publicEvidence.environmentID, a.environmentID)
        XCTAssertEqual(try publicEvidence.signedProof?.wireData(), try proof.wireData())
        XCTAssertEqual(try publicEvidence.verificationCertificate?.wireData(), try certificate.wireData())
        let enrollment = try XCTUnwrap(publicEvidence.runtimeEnrollment).verify(trustedPublicKey: f.rootSigner.publicKey, now: f.clock.now)
        XCTAssertEqual(enrollment.claim.runtimeID, caller.runtimeID); XCTAssertEqual(enrollment.claim.publicKey, caller.publicKey)
        try XCTUnwrap(publicEvidence.signedProof).verify(trustedPublicKey: caller.publicKey, using: RCIREd25519Verifier())
        try XCTUnwrap(publicEvidence.verificationCertificate).verify(trustedHostPublicKey: f.rootSigner.publicKey, using: RCIREd25519Verifier())
        do {
            _ = try await refreshed(recoveredChild, producer.executionId, cursor: history.count + 1)
            XCTFail("A cursor beyond retained history was accepted")
        } catch { XCTAssertEqual(error as? RCIRError, .invalidSequence) }
        do {
            _ = try await refreshed(recoveredChild, producer.executionId, maximumBytes: 1)
            XCTFail("An event exceeding the requested byte bound was exported")
        } catch { XCTAssertEqual(error as? RCIRError, .invalidLimit) }
        let end = try await refreshed(recoveredChild, producer.executionId, cursor: history.count, limit: 1, maximumBytes: 1)
        XCTAssertTrue(try XCTUnwrap(end.rcirEventPage).events.isEmpty)
        XCTAssertEqual(end.rcirEventPage?.nextCursor, Int64(history.count)); XCTAssertFalse(try XCTUnwrap(end.rcirEventPage).hasMore)
        let foreignPins = try EnvironmentCallerIdentity(publicKey: f.rootIdentity.publicKey, runtimeID: f.rootIdentity.runtimeID,
            environmentID: a.environmentID, leaseID: lease.body.leaseID)
        let (_, foreignChild) = try reopen(f, caller: foreignPins)
        let denied = try await refreshed(foreignChild, producer.executionId)
        XCTAssertEqual(denied.state, .unknown); XCTAssertEqual(denied.actionId, "")
        XCTAssertNil(denied.result); XCTAssertNil(denied.rcir); XCTAssertNil(denied.environmentEvidence)
        XCTAssertNil(denied.rcirEventPage)
        XCTAssertEqual(f.provider.activeRuntimeCount, 0)
    }

    @MainActor func testNestedGenericMCPAuthenticatedLinkProofRealityAndDurableTeardown() async throws {
        let f = try Fixture()
        let expectedNames = ["context_actions", "context_explain", "context_inspect", "context_providers", "context_run", "context_run_status", "context_runtime"]
        XCTAssertEqual(RightClickMCPContract.toolNames(), expectedNames)
        XCTAssertEqual(RightClickMCPContract.schemaVersion, 1)
        // The exact candidate-baseline digest is recorded independently of the
        // names. Changing fields while retaining seven names must also fail.
        XCTAssertEqual(RightClickMCPContract.toolSchemaSHA256(), "57758dc2cd5be92e1dc4dfbcd20b2bcffede88b4520a6197f17850d688105cbd")
        let factory = try actions(f.parentEngine, EnvironmentIdentity.factoryURI)
        XCTAssertEqual(factory.kind, "environment"); XCTAssertEqual(factory.actions.map(\.id), ["environment:create"])
        XCTAssertTrue(try XCTUnwrap(factory.actions.first).requiresConfirmation)
        let pending = try run(f.parentEngine, EnvironmentIdentity.factoryURI, "environment:create", confirmed: false)
        XCTAssertEqual(pending.state, .awaitingUser); XCTAssertTrue(f.provider.operationLog.isEmpty)
        let createdA = try run(f.parentEngine, EnvironmentIdentity.factoryURI, "environment:create", arguments: ["correlationID": UUID().uuidString])
        XCTAssertEqual(createdA.state, .succeeded); XCTAssertTrue(createdA.evidence.outcomeVerified)
        let uriA = try XCTUnwrap(createdA.output), idA = try EnvironmentIdentity.environmentID(from: uriA)
        XCTAssertEqual(try f.provider.observe(correlationID: XCTUnwrap(f.coordinator.record(environmentID: idA)).intent.correlationID).presence, .present)
        let inspect = try handleTool("context_inspect", arguments: ["item": .string(uriA)], engine: EngineBox(f.parentEngine), transport: "stdio")
        XCTAssertEqual(try JSONDecoder().decode(ContentItem.self, from: Data(inspect.utf8)).kind, "environment")
        XCTAssertFalse(try actions(f.parentEngine, uriA).actions.contains { $0.id == "environment:execute" })
        let bootA = try run(f.parentEngine, uriA, "environment:bootstrap")
        XCTAssertEqual(bootA.state, .succeeded)
        let a = try XCTUnwrap(f.coordinator.record(environmentID: idA)), runtimeA = try XCTUnwrap(a.runtime)
        XCTAssertEqual(a.state, .ready); XCTAssertTrue(a.enrollmentConsumed)
        let certificateA = try XCTUnwrap(a.enrollmentCertificate).verify(trustedPublicKey: f.rootSigner.publicKey, now: f.clock.now)
        XCTAssertEqual(certificateA.claim.handle, a.handle); XCTAssertEqual(certificateA.claim.manifest, f.manifest)
        XCTAssertEqual(certificateA.claim.publicKey, runtimeA.publicKey)
        XCTAssertEqual(runtimeA.manifest.operatingSystem, .linux); XCTAssertEqual(runtimeA.manifest.architecture, "arm64")
        let leaseA = try f.rootLease(for: a)
        try leaseA.verifySignature(trustedIssuerPublicKey: f.rootSigner.publicKey)
        XCTAssertEqual(leaseA.body.limits.maximumChildren, 1); XCTAssertEqual(leaseA.body.limits.delegationDepth, 1)
        let registryB = RemoteRuntimeRegistry(now: { f.clock.now })
        let sourceA = try Fixture.source(coordinator: f.coordinator, provider: f.provider, signer: f.rootSigner, clock: f.clock,
            proofs: f.proofs, manifest: f.manifest, spec: f.childSpec, caller: f.caller(a, leaseA))
        let parentVerification = try RemoteEnvironmentVerificationPolicy(trustedHostPublicKey: f.rootSigner.publicKey,
            now: { f.clock.now }, expectationResolver: { request in
            try f.coordinator.remoteProofExpectation(executionID: request.requestID.uuidString,
                capabilityID: try XCTUnwrap(request.capabilityID), item: request.item,
                arguments: request.arguments, verification: request.verification, expectedOutput: nil)
        }, failureResolver: { request in
            try f.coordinator.remoteFailureAdjudication(executionID: request.requestID.uuidString,
                capabilityID: try XCTUnwrap(request.capabilityID), targetRuntimeID: request.targetRuntimeID,
                item: request.item, arguments: request.arguments, verification: request.verification)
        })
        let engineA = CapabilityEngine(reflectorSources: [sourceA,
            RemoteCapabilitySource(registry: registryB, environmentVerificationPolicy: parentVerification)], experience: nil,
            runtimeEnvironment: .init(operatingSystem: .linux, architecture: "arm64"))
        XCTAssertTrue(try actions(engineA, uriA).actions.contains { $0.id == "environment:create-child" })
        XCTAssertTrue(try actions(engineA, EnvironmentIdentity.factoryURI).actions.isEmpty)
        let identityA = try f.provider.withSimulatedRuntimeSigner(environmentID: a.environmentID) { try RemoteNodeIdentity(signer: $0) }
        XCTAssertEqual(identityA.publicKey, runtimeA.publicKey); XCTAssertEqual(identityA.runtimeID, runtimeA.runtimeID)
        let endpointA = try Endpoint(engine: engineA, caller: f.rootIdentity, directory: f.directory.appendingPathComponent("link-a"),
            clock: f.clock, identity: identityA, capabilities: Set(leaseA.body.capabilityIDs))
        XCTAssertThrowsError(try Endpoint(engine: engineA, caller: f.rootIdentity,
            directory: f.directory.appendingPathComponent("link-wrong-runtime"), clock: f.clock,
            identity: f.rootIdentity, capabilities: Set(leaseA.body.capabilityIDs))) {
            XCTAssertEqual($0 as? RemoteLinkError, .wrongRuntime)
        }
        let discoveryA = try endpointA.send(endpointA.request(caller: f.rootIdentity, clock: f.clock, operation: .actions, item: uriA), caller: f.rootIdentity)
        let createChild = try XCTUnwrap(discoveryA.summary.capabilities.first { $0.id == "environment:create-child" })
        let unsignedApproval = endpointA.request(caller: f.rootIdentity, clock: f.clock, operation: .run, item: uriA,
            capability: createChild, arguments: ["correlationID": UUID().uuidString])
        XCTAssertEqual(try endpointA.send(unsignedApproval, caller: f.rootIdentity).summary.state, .awaitingUser)
        XCTAssertEqual(try f.coordinator.records().count, 1)
        let createRequest = endpointA.request(caller: f.rootIdentity, clock: f.clock, operation: .run, item: uriA,
            capability: createChild, arguments: ["correlationID": UUID().uuidString])
        endpointA.approval.exactTicket = try RemoteApprovalTicket(approvedRequest: createRequest, capabilityDigest: createChild.contractDigest)
        let createdB = try endpointA.send(createRequest, caller: f.rootIdentity)
        XCTAssertEqual(createdB.summary.state, .succeeded); XCTAssertEqual(createdB.summary.verification, .verifiedSuccess)
        let createExecutionB = try XCTUnwrap(createdB.summary.evidenceExecutionID)
        let b0 = try XCTUnwrap(f.coordinator.records().first { $0.lineage.parentEnvironmentID == idA })
        let uriB = try XCTUnwrap(b0.handle).uri
        XCTAssertEqual(b0.intent.creationExecutionID, createExecutionB); XCTAssertEqual(b0.creatingLeaseID, leaseA.body.leaseID)
        XCTAssertEqual(b0.lineage.depth, 1); XCTAssertEqual(b0.lineage.parentRuntimeID, runtimeA.runtimeID)
        XCTAssertEqual(b0.lineage.parentExecutionID, createExecutionB)
        XCTAssertFalse(try actions(engineA, uriA).actions.contains { $0.id == "environment:create-child" })
        let bootB = try run(f.parentEngine, uriB, "environment:bootstrap")
        XCTAssertEqual(bootB.state, .succeeded)
        let b = try XCTUnwrap(f.coordinator.record(environmentID: b0.environmentID)), runtimeB = try XCTUnwrap(b.runtime)
        XCTAssertNotEqual(runtimeA.publicKey, runtimeB.publicKey)
        XCTAssertEqual(try XCTUnwrap(b.enrollmentCertificate).verify(trustedPublicKey: f.rootSigner.publicKey, now: f.clock.now).claim.manifest, f.manifest)
        let leaseB = try f.childLease(parent: a, child: b, parentLease: leaseA)
        try leaseB.body.validateAttenuation(from: leaseA.body); try leaseB.verifySignature(trustedIssuerPublicKey: runtimeA.publicKey)
        XCTAssertEqual(leaseB.body.parentLeaseID, leaseA.body.leaseID); XCTAssertEqual(leaseB.body.limits.delegationDepth, 0)
        XCTAssertEqual(leaseB.body.limits.maximumChildren, 0); XCTAssertLessThan(leaseB.body.expiresAtMilliseconds, leaseA.body.expiresAtMilliseconds)
        let sourceB = try Fixture.source(coordinator: f.coordinator, provider: f.provider, signer: f.rootSigner, clock: f.clock,
            proofs: f.proofs, manifest: f.manifest, spec: f.childSpec, caller: f.caller(b, leaseB))
        let engineB = CapabilityEngine(reflectorSources: [sourceB], experience: nil,
            runtimeEnvironment: .init(operatingSystem: .linux, architecture: "arm64"))
        XCTAssertEqual(Set(try actions(engineB, uriB).actions.map(\.id)), Set(["environment:observe", "environment:execute", "environment:destroy"]))
        XCTAssertTrue(try actions(engineB, uriA).actions.isEmpty)
        let identityB = try f.provider.withSimulatedRuntimeSigner(environmentID: b.environmentID) { try RemoteNodeIdentity(signer: $0) }
        XCTAssertEqual(identityB.publicKey, runtimeB.publicKey); XCTAssertEqual(identityB.runtimeID, runtimeB.runtimeID)
        let endpointB = try Endpoint(engine: engineB, caller: endpointA.identity, directory: f.directory.appendingPathComponent("link-b"),
            clock: f.clock, identity: identityB, capabilities: Set(leaseB.body.capabilityIDs))
        let relay = SimulatedLinkRelay()
        try await endpointB.dispatcher.establishOutboundConnection(to: relay)
        let clientB = try RemoteLinkClient(identity: endpointA.identity, trustedRuntimeKey: endpointB.identity.publicKey,
            transport: relay, now: { f.clock.now })
        try await registryB.enroll(clientB, item: uriB)
        let route = try XCTUnwrap(try actions(engineA, uriB).actions.first { $0.id.hasPrefix("remote:") && $0.id ==
            "remote:" + RemoteWire.digest(endpointB.identity.publicKey) + ":" + RemoteWire.digest(Data("environment:execute".utf8)) })
        let challenge = UUID().uuidString + UUID().uuidString
        endpointB.approval.reviewedChallenge = challenge
        let dispatched = try run(engineA, uriB, route.id, arguments: ["challenge": challenge])
        let reportedByA = try await refreshed(engineA, dispatched.executionId)
        XCTAssertEqual(reportedByA.state, .succeeded); XCTAssertTrue(reportedByA.evidence.outcomeVerified)
        XCTAssertEqual(endpointB.approval.approvedRequests.count, 1)
        let workID = try XCTUnwrap(f.proofs.signed.keys.first), proof = try XCTUnwrap(f.proofs.signed[workID])
        XCTAssertEqual(proof.proof.reportedOutcome, .succeeded); XCTAssertTrue(proof.proof.providerAccepted)
        XCTAssertEqual(proof.publicKey, runtimeB.publicKey); XCTAssertEqual(proof.proof.binding.environmentID, b.environmentID)
        XCTAssertEqual(proof.proof.binding.parentEnvironmentID, a.environmentID)
        XCTAssertEqual(proof.proof.binding.parentRuntimeID, runtimeA.runtimeID)
        XCTAssertEqual(try f.provider.observeChallenge(XCTUnwrap(b.handle), executionID: workID), challenge)
        let hostCertificate = try XCTUnwrap(f.proofs.certificates[workID])
        try hostCertificate.verify(trustedHostPublicKey: f.rootSigner.publicKey, using: RCIREd25519Verifier())
        XCTAssertEqual(hostCertificate.verification.outcome, .succeeded)
        XCTAssertEqual(hostCertificate.verification.observedValueDigest, try ExecutionEvidenceDigest.capabilityValue(.string(challenge)))
        let actual = try XCTUnwrap(f.coordinator.executionRecord(workID))
        XCTAssertEqual(actual.state, .succeeded); XCTAssertEqual(actual.rcir?.outcome, "succeeded")
        XCTAssertEqual(actual.evidence.observationBoundary, .externalState); XCTAssertTrue(actual.evidence.outcomeVerified)
        XCTAssertThrowsError(try f.coordinator.adjudicateProof(proof, hostSigner: f.rootSigner)) {
            XCTAssertEqual($0 as? EnvironmentEvidenceError, .invalidSequence)
        }
        let requestBytes = try SignedRemoteMessage.request(createRequest, signer: f.rootIdentity)
        XCTAssertThrowsError(try endpointA.dispatcher.handle(requestBytes)) { XCTAssertEqual($0 as? RemoteLinkError, .replay) }
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("create:") }.count, 2)
        f.provider.configureFaults { $0.observedChallengeOverride = "wrong-independent-value" }
        let badChallenge = UUID().uuidString
        endpointB.approval.reviewedChallenge = badChallenge
        let failedDispatch = try run(engineA, uriB, route.id, arguments: ["challenge": badChallenge])
        let failedByA = try await refreshed(engineA, failedDispatch.executionId)
        XCTAssertEqual(failedByA.state, .failed); XCTAssertEqual(failedByA.verification?.status, .verifiedFailure)
        let badOperation = try XCTUnwrap(f.provider.operationLog.last { $0.hasPrefix("challenge:" + b.environmentID + ":") })
        let badID = String(badOperation.suffix(36))
        XCTAssertNotEqual(badID, workID); XCTAssertEqual(f.proofs.signed.count, 1); XCTAssertEqual(f.proofs.certificates.count, 1)
        let malicious = try simulatedChildProof(f, executionID: badID)
        XCTAssertTrue(malicious.proof.providerAccepted); XCTAssertEqual(malicious.proof.reportedOutcome, .succeeded)
        XCTAssertThrowsError(try f.coordinator.adjudicateProof(malicious, hostSigner: f.rootSigner)) {
            XCTAssertEqual($0 as? EnvironmentEvidenceError, .unsuccessfulDependency)
        }
        let failedActual = try XCTUnwrap(f.coordinator.executionRecord(badID))
        XCTAssertEqual(failedActual.state, .failed); XCTAssertEqual(failedActual.rcir?.outcome, "failed")
        XCTAssertFalse(failedActual.evidence.outcomeVerified)
        XCTAssertNil(try f.coordinator.evidence(executionID: badID).1)
        XCTAssertNil(try f.coordinator.auditEvidence(executionID: badID).1)
        f.provider.configureFaults { $0.observedChallengeOverride = nil }
        let destroyed = try run(f.parentEngine, uriA, "environment:destroy")
        XCTAssertEqual(destroyed.state, .succeeded); XCTAssertTrue(destroyed.evidence.outcomeVerified)
        XCTAssertEqual(f.provider.operationLog.filter { $0.hasPrefix("destroy:") }, ["destroy:" + b.environmentID, "destroy:" + a.environmentID])
        for (record, lease) in [(a, leaseA), (b, leaseB)] {
            let after = try XCTUnwrap(f.coordinator.record(environmentID: record.environmentID))
            XCTAssertEqual(after.state, .destroyed); XCTAssertTrue(after.revoked); XCTAssertNil(after.runtime)
            XCTAssertEqual(try f.provider.observe(correlationID: record.intent.correlationID).presence, .absent)
            let runtime = try XCTUnwrap(record.runtime)
            XCTAssertThrowsError(try f.coordinator.authenticatedAdmission(executionID: UUID().uuidString, requestDigest: Data(repeating: 10, count: 32),
                subjectPublicKey: runtime.publicKey, runtimeID: runtime.runtimeID, environmentID: record.environmentID, leaseID: lease.body.leaseID))
            XCTAssertFalse(try f.coordinator.canDiscover(capabilityID: "environment:execute", environmentID: record.environmentID,
                subjectPublicKey: runtime.publicKey, runtimeID: runtime.runtimeID, leaseID: lease.body.leaseID))
        }
        XCTAssertEqual(f.provider.activeRuntimeCount, 0)
        XCTAssertThrowsError(try identityA.sign(Data("after-teardown".utf8)))
        XCTAssertThrowsError(try identityB.sign(Data("after-teardown".utf8)))
        registryB.remove(runtimeID: endpointB.identity.runtimeID)
        await relay.disconnect(runtimeID: endpointB.identity.runtimeID)
        XCTAssertTrue(registryB.registrations().isEmpty)
        let recovered = try Fixture.makeCoordinator(provider: f.provider, signer: f.rootSigner, clock: f.clock,
            journal: f.directory.appendingPathComponent("environment-journal"), manifest: f.manifest, spec: f.parentSpec)
        let recoveredSource = try Fixture.source(coordinator: recovered, provider: f.provider, signer: f.rootSigner,
            clock: f.clock, proofs: Proofs(), manifest: f.manifest, spec: f.parentSpec)
        let recoveredEngine = CapabilityEngine(reflectorSources: [recoveredSource], experience: nil)
        // This recovery owner reads the journal before any shared in-memory
        // ExecutionStore entry, proving that a retained cache cannot satisfy it.
        let owner = try XCTUnwrap(recoveredEngine.executionStatusReflector(workID))
        let durableStatus = try await owner.executionStatus(executionID: workID, cursor: 0, limit: 64, maximumBytes: 262_144)
        let recoveredSuccess = try await refreshed(recoveredEngine, workID)
        let recoveredFailure = try await refreshed(recoveredEngine, badID)
        let recoveredDestroy = try await refreshed(recoveredEngine, destroyed.executionId)
        XCTAssertEqual(durableStatus?.state, .succeeded); XCTAssertEqual(recoveredSuccess.state, .succeeded)
        XCTAssertEqual(recoveredFailure.state, .failed); XCTAssertEqual(recoveredDestroy.state, .succeeded)
        XCTAssertEqual(try recovered.records().count, 2)
        let retained = try recovered.evidence(executionID: workID)
        XCTAssertEqual(try retained.0?.wireData(), try proof.wireData()); XCTAssertEqual(try retained.1?.wireData(), try hostCertificate.wireData())
        XCTAssertEqual(RightClickMCPContract.toolNames(), expectedNames)
        XCTAssertEqual(RightClickMCPContract.toolSchemaSHA256(), "57758dc2cd5be92e1dc4dfbcd20b2bcffede88b4520a6197f17850d688105cbd")
    }
}
