import Foundation
import XCTest
import RightClickCore
import RightClickProtocol
@testable import RightClickLink

/// Synthetic provider measurements; actual signed Link/dispatcher/Core paths.
/// These controls do not claim a VM, cloud operation, or Linux child process.
final class RemoteEnvironmentEvidenceTests: XCTestCase {
    private final class Provider: CapabilityVerificationReflector {
        let id = "fixture.environment-proof"
        let identity: RemoteNodeIdentity
        let hostSigner: RCIREd25519Signer
        let handle: EnvironmentHandle
        let manifest: EnvironmentRuntimeManifest
        let stamp: Int64
        var effects = 0
        var observedValue = ""
        var independentlyObservedValueOverride: String?
        let declaration: Capability
        init(identity: RemoteNodeIdentity, hostSigner: RCIREd25519Signer, handle: EnvironmentHandle,
             manifest: EnvironmentRuntimeManifest, stamp: Int64) {
            self.identity = identity; self.hostSigner = hostSigner; self.handle = handle; self.manifest = manifest; self.stamp = stamp
            declaration = .init(id: "environment:execute", title: "Synthetic enrolled environment challenge", source: .system,
                reflectorID: id, safety: .read, invocation: .direct, supportLevel: .experimental, requiresConfirmation: false)
        }
        func capabilities(for item: ContentItem) throws -> [Capability] { [declaration] }
        func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
            try record(capability: capability, item: item, executionID: executionID, arguments: nil, verification: nil)
        }
        func begin(capability: Capability, item: ContentItem, executionID: String, arguments: CapabilityArguments?, verification: VerificationSpec) throws -> ExecutionRecord {
            try record(capability: capability, item: item, executionID: executionID, arguments: arguments, verification: verification)
        }
        private func record(capability: Capability, item: ContentItem, executionID: String,
                            arguments: CapabilityArguments?, verification: VerificationSpec?) throws -> ExecutionRecord {
            effects += 1; observedValue = independentlyObservedValueOverride ?? "observable-challenge"
            let succeeded = observedValue == (arguments?["challenge"] ?? "observable-challenge")
            let complete = try makeAudit(executionID: executionID, arguments: arguments, verification: verification)
            let audit: EnvironmentExecutionEvidence
            if succeeded { audit = complete }
            else { audit = try .init(environmentID: handle.environmentID, runtimeEnrollment: complete.runtimeEnrollment,
                signedProof: nil, verificationCertificate: nil) }
            let live = ExecutionLifecycle(executionID: executionID, originatingRequestID: executionID, runtimeID: identity.runtimeID,
                taskID: UUID().uuidString, generation: 1, taskShape: .unary, phase: .completed, semanticOutcome: succeeded ? .succeeded : .failed,
                sequence: 1, terminal: true, providerAcceptance: .accepted, verification: succeeded ? .verifiedSuccess : .verifiedFailure,
                observationBoundary: .externalState, evidenceID: executionID)
            return .init(executionId: executionID, actionId: capability.id, state: succeeded ? .succeeded : .failed, message: "Synthetic independently observed challenge.",
                output: observedValue, result: .string(observedValue), evidence: .init(type: "fixture_external_state",
                    boundary: "Independent synthetic provider state readback.", outcomeVerified: succeeded, observationBoundary: .externalState),
                verification: .init(status: succeeded ? .verifiedSuccess : .verifiedFailure, predicates: (verification?.predicates ?? [.init(type: .textEquals, value: observedValue)]).map {
                    .init(predicate: $0, evaluated: true, passed: succeeded, actual: observedValue, message: "Synthetic state observed.")
                }), rcirEvents: [.init(sequence: 1, time: stamp, kind: "completed", value: .string(observedValue))],
                lifecycle: live, environmentEvidence: audit)
        }
        func makeAudit(executionID: String, selectedHandle: EnvironmentHandle? = nil, signer: RemoteNodeIdentity? = nil,
                       certificateSigner: RCIREd25519Signer? = nil,
                       challengeNonce: Data = Data(repeating: 2, count: 32), sequence: Int64 = 1,
                       arguments: CapabilityArguments? = ["challenge": "observable-challenge"],
                       verification: VerificationSpec? = .init(predicates: [.init(type: .textEquals, value: "observable-challenge")])) throws -> EnvironmentExecutionEvidence {
            let environment = selectedHandle ?? handle, child = signer ?? identity
            let claim = try ChildRuntimeClaim(enrollmentID: UUID().uuidString, handle: environment, manifest: manifest,
                publicKey: child.publicKey, challenge: Data(repeating: 1, count: 32), issuedAtMilliseconds: stamp - 100,
                expiresAtMilliseconds: stamp + 59_900)
            let observation = try EnvironmentObservation(environmentID: environment.environmentID, correlationID: environment.correlationID,
                providerResourceID: environment.providerResourceID, presence: .present, state: .ready, observedAtMilliseconds: stamp - 50,
                runtime: .init(manifest: manifest, publicKey: child.publicKey, observedAtMilliseconds: stamp - 50,
                    observationBoundary: "Independent synthetic image/process metadata."), observationBoundary: "Synthetic resource presence.")
            let enrollment = try ChildRuntimeEnrollmentVerifier.verify(signedClaim: .sign(claim, using: child),
                expectedHandle: environment, expectedManifest: manifest, expectedEnrollmentID: claim.enrollmentID,
                expectedChallenge: claim.challenge, trustedBootstrapPublicKey: child.publicKey, observation: observation,
                now: stamp).certificate(using: hostSigner)
            let compiled = try EnvironmentContextualInvocation.digest(executionID: executionID, capabilityID: declaration.id,
                item: environment.uri, arguments: arguments, verification: verification, expectedOutput: nil, dependencies: [])
            let binding = try ExecutionProofBinding(executionID: executionID, environmentID: environment.environmentID,
                parentExecutionID: nil, parentEnvironmentID: nil, parentRuntimeID: nil, runtimeID: child.runtimeID,
                executableSHA256: manifest.executableSHA256, signerID: child.runtimeID, keyID: ExecutionEvidenceDigest.sha256(child.publicKey),
                leaseDigest: String(repeating: "b", count: 64), capabilityID: declaration.id,
                contractDigest: String(repeating: "c", count: 64), requestDigest: compiled.map { String(format: "%02x", $0) }.joined(),
                responseDigest: try ExecutionEvidenceDigest.capabilityValue(.string("observable-challenge")))
            let nonce = challengeNonce
            let proof = try ExecutionProof(binding: binding, challengeNonce: nonce, issuedAtMilliseconds: stamp,
                observedAtMilliseconds: stamp, expiresAtMilliseconds: stamp + 60_000, sequence: sequence,
                predicateID: "environment.challenge.equals", providerAccepted: true, reportedOutcome: .succeeded,
                reportedValue: .string("observable-challenge"), reportBoundary: "Child assertion, not independent reality.")
            let signed = try SignedExecutionProof.sign(proof, using: child)
            let expectation = try ExecutionProofExpectation(binding: binding, challengeNonce: nonce, expectedSequence: sequence,
                minimumIssuedAtMilliseconds: stamp, deadlineMilliseconds: stamp + 60_000, maximumAgeMilliseconds: 60_000,
                predicateID: proof.predicateID, expectedValue: .string("observable-challenge"))
            let verified = try ExecutionProofAdjudicator.adjudicate(signed, expectation: expectation, trustedPublicKey: child.publicKey,
                observerID: "fixture:independent-provider", observationBoundary: "Independent synthetic provider state.",
                nowMilliseconds: stamp, using: RCIREd25519Verifier(), observe: { _ in .string("observable-challenge") })
            return try .init(environmentID: environment.environmentID, runtimeEnrollment: enrollment, signedProof: signed,
                verificationCertificate: .sign(verified, using: certificateSigner ?? hostSigner))
        }
    }
    private final class ChildControlledTransport: RemoteLinkTransport {
        let relay: SimulatedLinkRelay
        let signer: RemoteNodeIdentity
        var transform: ((RemoteExecutionRequest, RemoteExecutionResult) throws -> RemoteExecutionSummary)?
        init(relay: SimulatedLinkRelay, signer: RemoteNodeIdentity) { self.relay = relay; self.signer = signer }
        func exchange(_ request: Data, targetRuntimeID: String) async throws -> Data {
            let response = try await relay.exchange(request, targetRuntimeID: targetRuntimeID)
            let requestEnvelope = try RemoteWire.decode(SignedRemoteMessage.self, request, maximum: RemoteWire.maximumWireBytes)
            let original = try RemoteWire.decode(RemoteExecutionRequest.self, requestEnvelope.payload)
            guard original.operation == .run || original.operation == .status, let transform else { return response }
            let responseEnvelope = try RemoteWire.decode(SignedRemoteMessage.self, response, maximum: RemoteWire.maximumWireBytes)
            let result = try RemoteWire.decode(RemoteExecutionResult.self, responseEnvelope.payload)
            let summary = try transform(original, result)
            return try SignedRemoteMessage.seal(RemoteExecutionResult(version: result.version, requestID: result.requestID,
                requestDigest: result.requestDigest, callerID: result.callerID, runtimeID: result.runtimeID, deviceID: result.deviceID,
                idempotencyKey: result.idempotencyKey, reused: result.reused, summary: summary), domain: RemoteWire.resultDomain, signer: signer)
        }
    }
    @MainActor private final class Fixture {
        let directory: URL
        let stamp: Int64 = 1_800_000_000_000
        let caller: RemoteNodeIdentity
        let target: RemoteNodeIdentity
        let hostSigner: RCIREd25519Signer
        let rogue: RemoteNodeIdentity
        let provider: Provider
        let engine: CapabilityEngine
        let ledger: RemoteReplayLedger
        let dispatcher: RemoteExecutionDispatcher
        let relay = SimulatedLinkRelay()
        let transport: ChildControlledTransport
        let client: RemoteLinkClient
        init(exportsEvidence: Bool = true) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-environment-proof-link-" + UUID().uuidString)
                .standardizedFileURL.resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            caller = try .init(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 11, count: 32)))
            target = try .init(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 12, count: 32)))
            hostSigner = try .init(rawPrivateKey: Data(repeating: 13, count: 32))
            rogue = try .init(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 14, count: 32)))
            let id = UUID().uuidString
            let handle = try EnvironmentHandle(environmentID: id, providerID: "fake", providerResourceID: "fake-resource",
                correlationID: UUID().uuidString,
                lineage: .init(rootEnvironmentID: id, parentExecutionID: UUID().uuidString,
                    parentRuntimeID: RemoteNodeIdentity(signer: hostSigner).runtimeID, depth: 0),
                spec: .init(profileID: "challenge-only", lifetimeMilliseconds: 120_000, resources: .init()),
                createdAtMilliseconds: stamp - 1_000, expiresAtMilliseconds: stamp + 119_000)
            provider = Provider(identity: target, hostSigner: hostSigner, handle: handle,
                manifest: try .init(version: "test", executableSHA256: String(repeating: "a", count: 64), architecture: "arm64"), stamp: stamp)
            engine = CapabilityEngine(reflectors: [provider], experience: nil, runtimeEnvironment: .init(operatingSystem: .linux, architecture: "arm64"))
            ledger = try .init(directory: directory.appendingPathComponent("journal"), runtimeID: target.runtimeID)
            let grant = try RemoteCallerGrant(publicKey: caller.publicKey, operations: [.runtime, .actions, .run, .status],
                capabilityIDs: [provider.declaration.id], exportValueCapabilityIDs: exportsEvidence ? [provider.declaration.id] : [])
            let now = stamp
            dispatcher = try .init(engine: engine, identity: target, ledger: ledger, grants: [grant], enabled: true, now: { now })
            transport = ChildControlledTransport(relay: relay, signer: target)
            client = try .init(identity: caller, trustedRuntimeKey: target.publicKey, transport: transport, now: { now })
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func connect() async throws { try await dispatcher.establishOutboundConnection(to: relay) }
        func request(key: UUID = UUID()) throws -> RemoteExecutionRequest {
            try client.makeRequest(operation: .run, item: provider.handle.uri, capabilityID: provider.declaration.id,
                capabilityDigest: RemoteExecutionDispatcher.contractDigest(provider.declaration), arguments: ["challenge": "observable-challenge"],
                verification: .init(predicates: [.init(type: .textEquals, value: "observable-challenge")]), idempotencyKey: key)
        }
        func raw(_ request: RemoteExecutionRequest) throws -> (Data, Data, RemoteExecutionResult) {
            let bytes = try SignedRemoteMessage.request(request, signer: caller)
            let result = try dispatcher.handle(bytes)
            return (bytes, result, try SignedRemoteMessage.verifiedResult(result, for: bytes, trustedRuntimeKey: target.publicKey))
        }
        func replacingAudit(_ result: RemoteExecutionResult, with audit: EnvironmentExecutionEvidence?) throws -> Data {
            var summary = result.summary; summary.environmentEvidence = audit
            return try SignedRemoteMessage.seal(RemoteExecutionResult(version: result.version, requestID: result.requestID,
                requestDigest: result.requestDigest, callerID: result.callerID, runtimeID: result.runtimeID, deviceID: result.deviceID,
                idempotencyKey: result.idempotencyKey, reused: result.reused, summary: summary), domain: RemoteWire.resultDomain, signer: target)
        }
        func expectation(_ request: RemoteExecutionRequest) throws -> ExecutionProofExpectation {
            guard request.arguments?.count == 1, let challenge = request.arguments?["challenge"],
                  request.verification?.predicates.count == 1,
                  request.verification?.predicates.first?.type == .textEquals,
                  request.verification?.predicates.first?.value == challenge else { throw EnvironmentEvidenceError.bindingMismatch }
            let compiled = try EnvironmentContextualInvocation.digest(executionID: request.requestID.uuidString,
                capabilityID: provider.declaration.id, item: provider.handle.uri, arguments: request.arguments,
                verification: request.verification, expectedOutput: nil, dependencies: [])
            let binding = try ExecutionProofBinding(executionID: request.requestID.uuidString, environmentID: provider.handle.environmentID,
                parentExecutionID: nil, parentEnvironmentID: nil, parentRuntimeID: nil, runtimeID: target.runtimeID,
                executableSHA256: provider.manifest.executableSHA256, signerID: target.runtimeID,
                keyID: ExecutionEvidenceDigest.sha256(target.publicKey), leaseDigest: String(repeating: "b", count: 64),
                capabilityID: provider.declaration.id, contractDigest: String(repeating: "c", count: 64),
                requestDigest: compiled.map { String(format: "%02x", $0) }.joined(),
                responseDigest: try ExecutionEvidenceDigest.capabilityValue(.string(challenge)))
            return try .init(binding: binding, challengeNonce: Data(repeating: 2, count: 32), expectedSequence: 1,
                minimumIssuedAtMilliseconds: stamp, deadlineMilliseconds: stamp + 60_000,
                maximumAgeMilliseconds: 60_000, predicateID: "environment.challenge.equals", expectedValue: .string(challenge))
        }
        func parent(policy: Bool = true, hostKey: Data? = nil, policyNow: Int64? = nil,
                    failureResolver: ((RemoteExecutionRequest) throws -> Bool)? = nil) async throws -> CapabilityEngine {
            try await connect()
            let registry = RemoteRuntimeRegistry(now: { self.stamp }); try await registry.enroll(client, item: provider.handle.uri)
            let installed: RemoteEnvironmentVerificationPolicy?
            if policy {
                installed = try RemoteEnvironmentVerificationPolicy(trustedHostPublicKey: hostKey ?? hostSigner.publicKey,
                    now: { policyNow ?? self.stamp }, expectationResolver: expectation, failureResolver: failureResolver)
            } else { installed = nil }
            return CapabilityEngine(reflectors: [], reflectorSources: [RemoteCapabilitySource(registry: registry,
                environmentVerificationPolicy: installed)], experience: nil)
        }
        func routed(_ parent: CapabilityEngine, challenge: String = "observable-challenge", predicate: String? = nil) async throws -> ExecutionRecord {
            let capability = try XCTUnwrap(parent.capabilities(for: provider.handle.uri).capabilities.first)
            let initial = try parent.begin(id: capability.id, item: provider.handle.uri, confirmed: false,
                arguments: ["challenge": challenge], verification: .init(predicates: [.init(type: .textEquals, value: predicate ?? challenge)]))
            return try await parent.refreshedExecutionStatus(initial.executionId)
        }
        func assertUnverified(_ record: ExecutionRecord, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(record.state == .accepted || record.state == .unknown, file: file, line: line)
            XCTAssertNotEqual(record.verification?.status, .verifiedSuccess, file: file, line: line)
            XCTAssertFalse(record.evidence.outcomeVerified, file: file, line: line)
            XCTAssertNotEqual(record.lifecycle?.semanticOutcome, .succeeded, file: file, line: line)
            XCTAssertNotEqual(record.lifecycle?.verification, .verifiedSuccess, file: file, line: line)
        }
        func childClaimsSuccess(_ original: RemoteExecutionSummary) -> RemoteExecutionSummary {
            var summary = original
            summary.state = .succeeded; summary.policy = .evaluated; summary.providerAcceptance = .accepted
            summary.verification = .verifiedSuccess; summary.observationBoundary = .externalState; summary.error = nil
            summary.lifecycle = [.requested, .authorized, .delivered, .executing, .providerAccepted, .verified]
            if let live = summary.executionLifecycle {
                summary.executionLifecycle = .init(version: live.version, executionID: live.executionID,
                    originatingRequestID: live.originatingRequestID, runtimeID: live.runtimeID, taskID: live.taskID,
                    generation: live.generation, taskShape: live.taskShape, phase: .completed, semanticOutcome: .succeeded,
                    sequence: live.sequence, terminal: true, providerAcceptance: .accepted, verification: .verifiedSuccess,
                    observationBoundary: .externalState, evidenceID: live.evidenceID,
                    receiptAvailable: live.receiptAvailable, signedReceiptAvailable: live.signedReceiptAvailable)
            }
            return summary
        }
    }

    @MainActor func testSignedLinkCarriesCompleteProofAndRetainsItOnRetryAndPoll() async throws {
        let f = try Fixture(); try await f.connect()
        let run = try f.request(), initial = try await f.client.send(run)
        let audit = try XCTUnwrap(initial.summary.environmentEvidence), proof = try XCTUnwrap(audit.signedProof)
        XCTAssertEqual(proof.proof.binding.executionID, initial.summary.evidenceExecutionID)
        XCTAssertEqual(proof.proof.binding.executionID, run.requestID.uuidString)
        XCTAssertEqual(audit.environmentID, f.provider.handle.environmentID)
        try proof.verify(trustedPublicKey: f.target.publicKey, using: RCIREd25519Verifier())
        try XCTUnwrap(audit.verificationCertificate).verify(trustedHostPublicKey: f.hostSigner.publicKey, using: RCIREd25519Verifier())
        let retry = try await f.client.send(f.request(key: run.idempotencyKey))
        XCTAssertTrue(retry.reused)
        XCTAssertEqual(try RemoteWire.encode(retry.summary.environmentEvidence), try RemoteWire.encode(initial.summary.environmentEvidence))
        let id = try XCTUnwrap(initial.summary.executionLifecycle).executionID
        let poll = try await f.client.send(f.client.makeStatusRequest(for: run, executionID: id))
        XCTAssertEqual(try RemoteWire.encode(poll.summary.environmentEvidence), try RemoteWire.encode(initial.summary.environmentEvidence))
        XCTAssertEqual(f.provider.effects, 1)
    }

    @MainActor func testPrivateGrantWithholdsProofAndParentCannotPromoteChildOutcome() async throws {
        let f = try Fixture(exportsEvidence: false), response = try f.raw(f.request())
        XCTAssertNil(response.2.summary.environmentEvidence)
        XCTAssertNil(response.2.summary.result)
        XCTAssertEqual(response.2.summary.state, .succeeded)
        XCTAssertNotNil(f.engine.executionStatus(response.2.summary.evidenceExecutionID!).environmentEvidence)
        let parent = try await f.parent(), final = try await f.routed(parent)
        f.assertUnverified(final); XCTAssertEqual(final.state, .accepted)
        XCTAssertEqual(final.state, .accepted); XCTAssertEqual(final.verification?.status, .unverified)
        XCTAssertNil(final.environmentEvidence)
    }

    @MainActor func testAuthenticatedChildCannotSubstituteProofKeyOrEnvironment() throws {
        let f = try Fixture(), raw = try f.raw(f.request()), id = try XCTUnwrap(raw.2.summary.evidenceExecutionID)
        let wrongKey = try f.provider.makeAudit(executionID: id, signer: f.rogue)
        XCTAssertThrowsError(try SignedRemoteMessage.verifiedResult(f.replacingAudit(raw.2, with: wrongKey), for: raw.0, trustedRuntimeKey: f.target.publicKey)) {
            XCTAssertEqual($0 as? RemoteLinkError, .inconsistentResult)
        }
        let original = f.provider.handle, otherID = UUID().uuidString
        let other = try EnvironmentHandle(environmentID: otherID, providerID: original.providerID, providerResourceID: "other-resource",
            correlationID: UUID().uuidString, lineage: .init(rootEnvironmentID: otherID, parentExecutionID: original.lineage.parentExecutionID,
                parentRuntimeID: original.lineage.parentRuntimeID, depth: 0), spec: original.spec,
            createdAtMilliseconds: original.createdAtMilliseconds, expiresAtMilliseconds: original.expiresAtMilliseconds)
        let wrongEnvironment = try f.provider.makeAudit(executionID: id, selectedHandle: other)
        XCTAssertThrowsError(try SignedRemoteMessage.verifiedResult(f.replacingAudit(raw.2, with: wrongEnvironment), for: raw.0, trustedRuntimeKey: f.target.publicKey)) {
            XCTAssertEqual($0 as? RemoteLinkError, .inconsistentResult)
        }
    }

    @MainActor func testModifiedNestedProofCannotHideInsideAValidOuterNodeSignature() throws {
        let f = try Fixture(), raw = try f.raw(f.request()), audit = try XCTUnwrap(raw.2.summary.environmentEvidence)
        let original = try XCTUnwrap(audit.signedProof), proof = original.proof
        let altered = try ExecutionProof(binding: proof.binding, challengeNonce: Data(repeating: 9, count: 32),
            issuedAtMilliseconds: proof.issuedAtMilliseconds, observedAtMilliseconds: proof.observedAtMilliseconds,
            expiresAtMilliseconds: proof.expiresAtMilliseconds, sequence: proof.sequence, predicateID: proof.predicateID,
            providerAccepted: proof.providerAccepted, reportedOutcome: proof.reportedOutcome,
            reportedValue: proof.reportedValue, reportBoundary: proof.reportBoundary)
        let forged = try EnvironmentExecutionEvidence(environmentID: audit.environmentID, runtimeEnrollment: audit.runtimeEnrollment,
            signedProof: .init(proof: altered, signature: original.signature, publicKey: original.publicKey), verificationCertificate: audit.verificationCertificate)
        XCTAssertThrowsError(try SignedRemoteMessage.verifiedResult(f.replacingAudit(raw.2, with: forged), for: raw.0, trustedRuntimeKey: f.target.publicKey)) {
            XCTAssertEqual($0 as? RemoteLinkError, .inconsistentResult)
        }
    }

    @MainActor func testEmbeddedObserverKeyIsAuditAndNotIndependentAuthority() async throws {
        let f = try Fixture(), raw = try f.raw(f.request()), id = try XCTUnwrap(raw.2.summary.evidenceExecutionID)
        let untrustedObserver = try RCIREd25519Signer(rawPrivateKey: Data(repeating: 22, count: 32))
        let audit = try f.provider.makeAudit(executionID: id, certificateSigner: untrustedObserver)
        let transported = try SignedRemoteMessage.verifiedResult(f.replacingAudit(raw.2, with: audit), for: raw.0, trustedRuntimeKey: f.target.publicKey)
        let certificate = try XCTUnwrap(transported.summary.environmentEvidence?.verificationCertificate)
        XCTAssertThrowsError(try certificate.verify(trustedHostPublicKey: f.hostSigner.publicKey, using: RCIREd25519Verifier())) {
            XCTAssertEqual($0 as? EnvironmentEvidenceError, .untrustedKey)
        }
        // Only transport integrity accepted the embedded-key signature. The
        // parent's separately configured authority explicitly refused it.
        XCTAssertNotEqual(certificate.publicKey, f.hostSigner.publicKey)
        var substituted: EnvironmentExecutionEvidence?
        f.transport.transform = { request, result in
            var summary = result.summary
            if substituted == nil {
                substituted = try f.provider.makeAudit(executionID: summary.evidenceExecutionID!,
                    certificateSigner: untrustedObserver, arguments: request.arguments, verification: request.verification)
            }
            summary.environmentEvidence = substituted
            return summary
        }
        let parent = try await f.parent(), final = try await f.routed(parent)
        f.assertUnverified(final); XCTAssertEqual(final.state, .accepted)
    }

    @MainActor func testRoutedGenericStatusKeepsRemoteProofExecutionDespiteLocalAlias() async throws {
        let f = try Fixture(); try await f.connect()
        let parent = try await f.parent()
        let capability = try XCTUnwrap(parent.capabilities(for: f.provider.handle.uri).capabilities.first)
        let initial = try parent.begin(id: capability.id, item: f.provider.handle.uri, confirmed: false,
            arguments: ["challenge": "observable-challenge"], verification: .init(predicates: [.init(type: .textEquals, value: "observable-challenge")]))
        let final = try await parent.refreshedExecutionStatus(initial.executionId)
        let proof = try XCTUnwrap(final.environmentEvidence?.signedProof)
        XCTAssertNotEqual(initial.executionId, proof.proof.binding.executionID)
        XCTAssertEqual(proof.proof.binding.executionID, final.lifecycle?.executionID)
        XCTAssertEqual(final.executionId, initial.executionId)
        XCTAssertEqual(final.state, .succeeded); XCTAssertEqual(final.verification?.status, .verifiedSuccess)
        try proof.verify(trustedPublicKey: f.target.publicKey, using: RCIREd25519Verifier())
    }

    @MainActor func testMaliciousSignedSuccessWithoutAuditOrParentPolicyRemainsUnverified() async throws {
        let missing = try Fixture()
        missing.transport.transform = { _, result in var summary = result.summary; summary.environmentEvidence = nil; return summary }
        let parent = try await missing.parent(), final = try await missing.routed(parent)
        missing.assertUnverified(final); XCTAssertEqual(final.state, .accepted)
        let unconfigured = try Fixture(), noPolicy = try await unconfigured.parent(policy: false)
        let unpinned = try await unconfigured.routed(noPolicy)
        unconfigured.assertUnverified(unpinned); XCTAssertEqual(unpinned.state, .accepted)
        XCTAssertNotNil(unpinned.environmentEvidence?.signedProof)
    }

    @MainActor func testChildCannotBeItsOwnIndependentObserverEvenIfConfigured() async throws {
        let f = try Fixture(), childSigner = try RCIREd25519Signer(rawPrivateKey: Data(repeating: 12, count: 32))
        var substituted: EnvironmentExecutionEvidence?
        f.transport.transform = { request, result in
            var summary = result.summary
            if substituted == nil {
                substituted = try f.provider.makeAudit(executionID: summary.evidenceExecutionID!, certificateSigner: childSigner,
                    arguments: request.arguments, verification: request.verification)
            }
            summary.environmentEvidence = substituted
            return summary
        }
        let parent = try await f.parent(hostKey: f.target.publicKey), final = try await f.routed(parent)
        f.assertUnverified(final); XCTAssertEqual(final.state, .accepted)
    }

    @MainActor func testOldValidProofCannotCertifyANewSignedRequest() async throws {
        let f = try Fixture(), old = try f.raw(f.request()).2.summary
        XCTAssertEqual(old.state, .succeeded); XCTAssertEqual(old.verification, .verifiedSuccess)
        try XCTUnwrap(old.environmentEvidence?.verificationCertificate).verify(trustedHostPublicKey: f.hostSigner.publicKey,
            using: RCIREd25519Verifier())
        f.transport.transform = { request, _ in
            var summary = old
            if let live = old.executionLifecycle {
                summary.executionLifecycle = .init(version: live.version, executionID: live.executionID,
                    originatingRequestID: request.operation == .run ? request.requestID.uuidString : request.status!.originatingRequestID.uuidString,
                    runtimeID: live.runtimeID, taskID: live.taskID, generation: live.generation, taskShape: live.taskShape,
                    phase: live.phase, semanticOutcome: live.semanticOutcome, sequence: live.sequence, terminal: live.terminal,
                    providerAcceptance: live.providerAcceptance, verification: live.verification, observationBoundary: live.observationBoundary,
                    evidenceID: live.evidenceID, receiptAvailable: live.receiptAvailable, signedReceiptAvailable: live.signedReceiptAvailable)
            }
            return summary
        }
        let parent = try await f.parent(), capability = try XCTUnwrap(parent.capabilities(for: f.provider.handle.uri).capabilities.first)
        let initial = try parent.begin(id: capability.id, item: f.provider.handle.uri, confirmed: false,
            arguments: ["challenge": "observable-challenge"], verification: .init(predicates: [.init(type: .textEquals, value: "observable-challenge")]))
        do {
            let final = try await parent.refreshedExecutionStatus(initial.executionId)
            f.assertUnverified(final)
        } catch {
            // The real dispatcher also refuses the borrowed execution under the
            // fresh request's idempotency owner before returning a status body.
            XCTAssertEqual(error as? RemoteLinkError, .unauthorized)
            f.assertUnverified(parent.executionStatus(initial.executionId))
        }
    }

    @MainActor func testParentIndependentlyAdjudicatesFailureWithoutIssuingProofAuthority() async throws {
        let f = try Fixture(); f.provider.independentlyObservedValueOverride = "wrong-independent-value"
        let parent = try await f.parent(failureResolver: { request in
            _ = try f.expectation(request) // Recompile the exact original caller contract.
            let local = f.engine.executionStatus(request.requestID.uuidString)
            // Explicit fake provider state readback, separate from transported
            // child fields. The real host uses its immutable broker journal.
            return local.state == .failed && local.verification?.status == .verifiedFailure &&
                local.evidence.observationBoundary == .externalState &&
                f.provider.observedValue == "wrong-independent-value"
        })
        let final = try await f.routed(parent)
        XCTAssertEqual(final.state, .failed); XCTAssertEqual(final.verification?.status, .verifiedFailure)
        XCTAssertEqual(final.lifecycle?.semanticOutcome, .failed)
        XCTAssertNil(final.environmentEvidence?.signedProof); XCTAssertNil(final.environmentEvidence?.verificationCertificate)
        let assertion = try Fixture(); assertion.provider.independentlyObservedValueOverride = "wrong-independent-value"
        let unconfigured = try await assertion.parent(), rawFailure = try await assertion.routed(unconfigured)
        XCTAssertEqual(rawFailure.state, .failed); XCTAssertEqual(rawFailure.verification?.status, .unverified)
        XCTAssertEqual(rawFailure.lifecycle?.semanticOutcome, .unverified)
        XCTAssertFalse(rawFailure.evidence.outcomeVerified)
    }

    @MainActor func testValidOldChallengeAndPredicatesCannotCertifyChangedArguments() async throws {
        let f = try Fixture()
        var substituted: EnvironmentExecutionEvidence?
        f.transport.transform = { _, result in
            var summary = f.childClaimsSuccess(result.summary)
            // The child signs the old challenge under the current execution UUID.
            // Its outer result and inner host certificate are both authentic.
            if substituted == nil { substituted = try f.provider.makeAudit(executionID: summary.evidenceExecutionID!) }
            summary.environmentEvidence = substituted
            return summary
        }
        let parent = try await f.parent(), final = try await f.routed(parent, challenge: "new-challenge")
        f.assertUnverified(final); XCTAssertEqual(final.state, .accepted)
        let predicates = try Fixture(), predicatesParent = try await predicates.parent()
        var predicateAudit: EnvironmentExecutionEvidence?
        predicates.transport.transform = { _, result in
            var summary = predicates.childClaimsSuccess(result.summary)
            if predicateAudit == nil { predicateAudit = try predicates.provider.makeAudit(executionID: summary.evidenceExecutionID!) }
            summary.environmentEvidence = predicateAudit
            return summary
        }
        let wrongPredicate = try await predicates.routed(predicatesParent, predicate: "different-postcondition")
        predicates.assertUnverified(wrongPredicate); XCTAssertEqual(wrongPredicate.state, .accepted)
    }

    @MainActor func testValidObserverCertificateMustMatchParentNonceAndSequence() async throws {
        for wrongSequence in [false, true] {
            let f = try Fixture()
            var substituted: EnvironmentExecutionEvidence?
            f.transport.transform = { request, result in
                var summary = result.summary
                if substituted == nil {
                    substituted = try f.provider.makeAudit(executionID: summary.evidenceExecutionID!,
                        challengeNonce: Data(repeating: wrongSequence ? 2 : 9, count: 32), sequence: wrongSequence ? 2 : 1,
                        arguments: request.arguments, verification: request.verification)
                }
                summary.environmentEvidence = substituted
                return summary
            }
            let parent = try await f.parent(), final = try await f.routed(parent)
            f.assertUnverified(final); XCTAssertEqual(final.state, .accepted)
        }
    }

    @MainActor func testParentClockRejectsExpiredIndependentCertificate() async throws {
        let f = try Fixture(), parent = try await f.parent(policyNow: f.stamp + 60_001)
        let final = try await f.routed(parent)
        f.assertUnverified(final); XCTAssertEqual(final.state, .accepted)
    }

    @MainActor func testEvidenceDecoderRejectsUnboundEnvironmentAndUnknownFields() throws {
        let f = try Fixture(), raw = try f.raw(f.request()), audit = try XCTUnwrap(raw.2.summary.environmentEvidence)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(audit)) as? [String: Any])
        object["environmentID"] = UUID().uuidString
        XCTAssertThrowsError(try JSONDecoder().decode(EnvironmentExecutionEvidence.self, from: JSONSerialization.data(withJSONObject: object)))
        object["environmentID"] = audit.environmentID; object["trusted"] = true
        XCTAssertThrowsError(try JSONDecoder().decode(EnvironmentExecutionEvidence.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
