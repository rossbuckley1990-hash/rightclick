import Foundation
import XCTest
import RightClickProtocol
@testable import RightClickProviders
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class EnvironmentProviderTests: XCTestCase {
    private let start: Int64 = 1_000_000
    private func intent(lifetime: Int64 = 30_000, correlation: String = UUID().uuidString,
                        environment: String = UUID().uuidString) throws -> EnvironmentCreateIntent {
        let resources = try EnvironmentResources(cpuCount: 1, memoryMiB: 256, maximumCostUnits: 10_000)
        let spec = try EnvironmentSpec(profileID: "test-runtime", lifetimeMilliseconds: lifetime, resources: resources)
        let lineage = try EnvironmentLineage(rootEnvironmentID: environment, parentExecutionID: UUID().uuidString,
            parentRuntimeID: "runtime:" + String(repeating: "1", count: 64), depth: 0)
        return try EnvironmentCreateIntent(environmentID: environment, correlationID: correlation,
            creationExecutionID: UUID().uuidString, spec: spec, lineage: lineage,
            createdAtMilliseconds: start, expiresAtMilliseconds: start + lifetime)
    }
    private func handle(_ intent: EnvironmentCreateIntent, provider: EnvironmentProvider, resourceID: String) throws -> EnvironmentHandle {
        try EnvironmentHandle(environmentID: intent.environmentID, providerID: provider.id, providerResourceID: resourceID,
            correlationID: intent.correlationID, lineage: intent.lineage, spec: intent.spec,
            createdAtMilliseconds: intent.createdAtMilliseconds, expiresAtMilliseconds: intent.expiresAtMilliseconds)
    }
    private func manifest(_ digest: String = "a") throws -> EnvironmentRuntimeManifest {
        try EnvironmentRuntimeManifest(version: "test-v1", executableSHA256: String(repeating: digest, count: 64), architecture: "x86_64")
    }
    func testFakeSeparatesAcceptedCreationBootstrapAndIndependentWorkloadObservation() throws {
        let provider = try InMemoryEnvironmentProvider(clock: { self.start })
        let intent = try intent()
        let accepted = try provider.create(intent)
        XCTAssertEqual(accepted.acceptance, .accepted)
        let before = try provider.observe(correlationID: intent.correlationID)
        XCTAssertEqual(before.presence, .present); XCTAssertEqual(before.state, .bootstrapping); XCTAssertNil(before.runtime)
        let handle = try handle(intent, provider: provider, resourceID: XCTUnwrap(accepted.providerResourceID))
        _ = try provider.bootstrap(handle, manifest: manifest())
        let runtime = try XCTUnwrap(provider.observe(correlationID: intent.correlationID).runtime)
        XCTAssertEqual(runtime.publicKey.count, 32)
        XCTAssertTrue(EnvironmentIdentity.isRuntimeID(runtime.runtimeID))
        let executionID = UUID().uuidString
        provider.configureFaults { $0.suppressChallengeEffect = true }
        XCTAssertEqual(try provider.executeChallenge(handle, executionID: executionID, challenge: "random-challenge").acceptance, .accepted)
        XCTAssertNil(try provider.observeChallenge(handle, executionID: executionID))
        provider.configureFaults { $0.suppressChallengeEffect = false }
        let nextID = UUID().uuidString
        _ = try provider.executeChallenge(handle, executionID: nextID, challenge: "fresh-nonce")
        XCTAssertEqual(try provider.observeChallenge(handle, executionID: nextID), "fresh-nonce")
        // Independent observation may contradict the accepted request.
        provider.configureFaults { $0.observedChallengeOverride = "wrong-challenge" }
        XCTAssertNotEqual(try provider.observeChallenge(handle, executionID: nextID), "fresh-nonce")
    }
    func testFakeCreateCrashReconcilesSameResourceWithoutDuplicateAndConflictingRetryRejects() throws {
        let provider = try InMemoryEnvironmentProvider(clock: { self.start })
        let original = try intent()
        provider.configureFaults { $0.createAcceptedThenCrashOnce = true }
        XCTAssertThrowsError(try provider.create(original))
        let actual = try provider.observe(correlationID: original.correlationID)
        XCTAssertEqual(actual.presence, .present)
        let retry = try provider.create(original)
        XCTAssertEqual(retry.providerResourceID, actual.providerResourceID)
        XCTAssertEqual(try provider.list().count, 1)
        XCTAssertEqual(provider.operationLog.filter { $0.hasPrefix("create:") }.count, 1)
        let modified = try intent(correlation: original.correlationID, environment: original.environmentID)
        XCTAssertThrowsError(try provider.create(modified))
        XCTAssertThrowsError(try provider.observe(correlationID: UUID().uuidString))
    }
    func testFakeDestroyAcceptanceIsNotAbsenceAndPartitionIsUnknown() throws {
        let provider = try InMemoryEnvironmentProvider(clock: { self.start })
        let intent = try intent()
        let accepted = try provider.create(intent)
        let handle = try handle(intent, provider: provider, resourceID: XCTUnwrap(accepted.providerResourceID))
        _ = try provider.bootstrap(handle, manifest: manifest())
        provider.configureFaults { $0.deleteAcceptedStillPresent = true }
        let destroyID = UUID().uuidString
        XCTAssertEqual(try provider.destroy(handle, idempotencyKey: destroyID).acceptance, .accepted)
        XCTAssertEqual(try provider.observe(correlationID: intent.correlationID).presence, .present)
        provider.configureFaults { $0.partitioned = true }
        XCTAssertEqual(try provider.observe(correlationID: intent.correlationID).presence, .unknown)
        XCTAssertThrowsError(try provider.destroy(handle, idempotencyKey: destroyID))
        provider.configureFaults { $0.partitioned = false; $0.deleteAcceptedStillPresent = false }
        _ = try provider.destroy(handle, idempotencyKey: destroyID)
        _ = try provider.destroy(handle, idempotencyKey: destroyID)
        XCTAssertEqual(try provider.observe(correlationID: intent.correlationID).presence, .absent)
        XCTAssertEqual(provider.activeRuntimeCount, 0)
        XCTAssertThrowsError(try provider.bootstrap(handle, manifest: manifest()))
    }
    func testFakeTTLAndExecutionIdempotencyAndIdentityIsolation() throws {
        var now = start
        let provider = try InMemoryEnvironmentProvider(clock: { now })
        let intent = try intent(lifetime: 1_000)
        let accepted = try provider.create(intent)
        let handle = try handle(intent, provider: provider, resourceID: XCTUnwrap(accepted.providerResourceID))
        _ = try provider.bootstrap(handle, manifest: manifest())
        let publicKey = try XCTUnwrap(provider.observe(correlationID: intent.correlationID).runtime?.publicKey)
        _ = try provider.bootstrap(handle, manifest: manifest())
        XCTAssertEqual(try provider.observe(correlationID: intent.correlationID).runtime?.publicKey, publicKey)
        XCTAssertThrowsError(try provider.bootstrap(handle, manifest: manifest("b")))
        let executionID = UUID().uuidString
        _ = try provider.executeChallenge(handle, executionID: executionID, challenge: "nonce")
        _ = try provider.executeChallenge(handle, executionID: executionID, challenge: "nonce")
        XCTAssertThrowsError(try provider.executeChallenge(handle, executionID: executionID, challenge: "modified"))
        XCTAssertThrowsError(try provider.executeChallenge(handle, executionID: UUID().uuidString, challenge: String(repeating: "x", count: 257)))
        let wrongHandle = try self.handle(intent, provider: provider, resourceID: "wrong-resource")
        XCTAssertThrowsError(try provider.destroy(wrongHandle, idempotencyKey: UUID().uuidString))
        now += 1_000
        XCTAssertEqual(try provider.observe(correlationID: intent.correlationID).presence, .absent)
        XCTAssertEqual(provider.activeRuntimeCount, 0)
        XCTAssertThrowsError(try provider.executeChallenge(handle, executionID: UUID().uuidString, challenge: "late"))
        XCTAssertEqual(try provider.create(intent).providerResourceID, accepted.providerResourceID) // Tombstone, no recreation.
    }
    func testFakeTypedSigningProvesKeyPossessionWithExactActiveIdentityOnly() throws {
        let provider = try InMemoryEnvironmentProvider(clock: { self.start })
        let intent = try intent()
        let accepted = try provider.create(intent)
        let handle = try handle(intent, provider: provider, resourceID: XCTUnwrap(accepted.providerResourceID))
        _ = try provider.bootstrap(handle, manifest: manifest())
        let runtime = try XCTUnwrap(provider.observe(correlationID: intent.correlationID).runtime)
        let claim = try ChildRuntimeClaim(enrollmentID: UUID().uuidString, handle: handle, manifest: manifest(),
            publicKey: runtime.publicKey, challenge: Data(repeating: 7, count: 32), issuedAtMilliseconds: start,
            expiresAtMilliseconds: start + 10_000)
        let signedClaim = try provider.signedRuntimeClaim(claim)
        XCTAssertEqual(try signedClaim.verify(trustedPublicKey: runtime.publicKey), claim)
        let forgedKey = try ChildRuntimeClaim(enrollmentID: UUID().uuidString, handle: handle, manifest: manifest(),
            publicKey: Data(repeating: 0, count: 32), challenge: Data(repeating: 7, count: 32), issuedAtMilliseconds: start,
            expiresAtMilliseconds: start + 10_000)
        XCTAssertThrowsError(try provider.signedRuntimeClaim(forgedKey))
        let executionID = UUID().uuidString
        _ = try provider.executeChallenge(handle, executionID: executionID, challenge: "nonce")
        let digest = String(repeating: "a", count: 64)
        func proof(capability: String = "environment:execute", reported: String = "nonce", execution: String? = nil) throws -> ExecutionProof {
            let binding = try ExecutionProofBinding(executionID: execution ?? executionID, environmentID: intent.environmentID,
                parentExecutionID: nil, parentEnvironmentID: nil, parentRuntimeID: nil, runtimeID: runtime.runtimeID,
                executableSHA256: digest, signerID: runtime.runtimeID, keyID: ExecutionEvidenceDigest.sha256(runtime.publicKey),
                leaseDigest: digest, capabilityID: capability, contractDigest: digest, requestDigest: digest, responseDigest: digest)
            return try ExecutionProof(binding: binding, challengeNonce: Data(repeating: 8, count: 32), issuedAtMilliseconds: start,
                observedAtMilliseconds: start, expiresAtMilliseconds: start + 10_000, sequence: 1, predicateID: "exact-challenge",
                providerAccepted: true, reportedOutcome: .succeeded, reportedValue: .string(reported), reportBoundary: "in-memory-child-runtime-report")
        }
        let signedProof = try provider.signedExecutionProof(proof())
        XCTAssertNoThrow(try signedProof.verify(trustedPublicKey: runtime.publicKey, using: RCIREd25519Verifier()))
        XCTAssertThrowsError(try provider.signedExecutionProof(proof(capability: "arbitrary:admin")))
        XCTAssertThrowsError(try provider.signedExecutionProof(proof(execution: UUID().uuidString)))
        XCTAssertThrowsError(try provider.signedExecutionProof(proof(reported: "lie")))
        provider.configureFaults { $0.reportedChallengeOverride = "lie" }
        XCTAssertNoThrow(try provider.signedExecutionProof(proof(reported: "lie")))
        XCTAssertEqual(try provider.observeChallenge(handle, executionID: executionID), "nonce")
        _ = try provider.destroy(handle, idempotencyKey: UUID().uuidString)
        XCTAssertThrowsError(try provider.signedRuntimeClaim(claim))
        XCTAssertThrowsError(try provider.signedExecutionProof(proof(reported: "lie")))
    }
    func testFakeTypedLeaseIssuerCannotSignForSiblingOrUnknownRuntime() throws {
        let provider = try InMemoryEnvironmentProvider(clock: { self.start })
        let parent = try intent()
        let parentAcceptance = try provider.create(parent)
        let parentHandle = try handle(parent, provider: provider, resourceID: XCTUnwrap(parentAcceptance.providerResourceID))
        _ = try provider.bootstrap(parentHandle, manifest: manifest())
        let parentRuntime = try XCTUnwrap(provider.observe(correlationID: parent.correlationID).runtime)
        let childID = UUID().uuidString
        let childLineage = try EnvironmentLineage(rootEnvironmentID: parent.environmentID, parentEnvironmentID: parent.environmentID,
            parentExecutionID: UUID().uuidString, parentRuntimeID: parentRuntime.runtimeID, depth: 1)
        let child = try EnvironmentCreateIntent(environmentID: childID, correlationID: UUID().uuidString,
            creationExecutionID: childLineage.parentExecutionID, spec: parent.spec, lineage: childLineage,
            createdAtMilliseconds: start, expiresAtMilliseconds: parent.expiresAtMilliseconds)
        let childAcceptance = try provider.create(child)
        let childHandle = try handle(child, provider: provider, resourceID: XCTUnwrap(childAcceptance.providerResourceID))
        _ = try provider.bootstrap(childHandle, manifest: manifest())
        let childRuntime = try XCTUnwrap(provider.observe(correlationID: child.correlationID).runtime)
        let limits = try CapabilityLeaseLimits(maximumExecutions: 1, maximumChildren: 0, maximumDescendants: 0,
            delegationDepth: 0, cpuCount: 1, memoryMiB: 256, maximumCostUnits: 1_000)
        func lease(subjectKey: Data, environmentID: String) throws -> CapabilityLease {
            try CapabilityLease(leaseID: UUID(), issuerPublicKey: parentRuntime.publicKey, subjectPublicKey: subjectKey,
                subjectRuntimeID: "runtime:" + ExecutionEvidenceDigest.sha256(subjectKey), environmentID: XCTUnwrap(UUID(uuidString: environmentID)),
                parentLeaseID: UUID(), parentLeaseDigest: Data(repeating: 1, count: 32), issuingExecutionID: childLineage.parentExecutionID,
                capabilityIDs: ["environment:execute"], profileIDs: ["test-runtime"], issuedAtMilliseconds: start,
                expiresAtMilliseconds: start + 10_000, nonce: Data(repeating: 2, count: 32), limits: limits, networkAllowlist: [])
        }
        let body = try lease(subjectKey: childRuntime.publicKey, environmentID: child.environmentID)
        let signed = try provider.signedCapabilityLease(body, issuerEnvironmentID: parent.environmentID)
        XCTAssertNoThrow(try signed.verifySignature(trustedIssuerPublicKey: parentRuntime.publicKey))
        XCTAssertThrowsError(try provider.signedCapabilityLease(lease(subjectKey: Data(repeating: 0, count: 32), environmentID: child.environmentID), issuerEnvironmentID: parent.environmentID))
        XCTAssertThrowsError(try provider.signedCapabilityLease(lease(subjectKey: parentRuntime.publicKey, environmentID: parent.environmentID), issuerEnvironmentID: parent.environmentID))
        _ = try provider.destroy(childHandle, idempotencyKey: UUID().uuidString)
        XCTAssertThrowsError(try provider.signedCapabilityLease(body, issuerEnvironmentID: parent.environmentID))
    }

    private final class Transport: FlyMachinesTransport {
        var requests: [URLRequest] = []
        var handler: (URLRequest) throws -> FlyMachinesResponse = { request in
            FlyMachinesResponse(statusCode: 200, url: request.url!, body: Data("[]".utf8))
        }
        func send(_ request: URLRequest) throws -> FlyMachinesResponse {
            requests.append(request); return try handler(request)
        }
    }
    private final class Guard: FlyEnvironmentCreationGuard {
        let enforcesProviderVisibleLifetime = true
        var reserved = Set<String>()
        func reserveCreation(_ intent: EnvironmentCreateIntent, profile: FlyEnvironmentProfile) throws -> Bool {
            reserved.insert(intent.correlationID).inserted
        }
    }
    private func profile(image: String? = nil, rate: Int64 = 10) throws -> FlyEnvironmentProfile {
        try FlyEnvironmentProfile(app: "rightclick-test", region: "lhr", ownerID: "11111111-1111-4111-8111-111111111111",
            ceiling: intent(lifetime: 60_000).spec, manifest: manifest(),
            image: image ?? "registry.fly.io/rightclick-test@sha256:" + String(repeating: "b", count: 64),
            maximumMicroUSDPerSecond: rate)
    }
    private func flyMachine(_ createRequest: URLRequest, state: String = "created") throws -> Data {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(createRequest.httpBody)) as? [String: Any])
        return try JSONSerialization.data(withJSONObject: ["id": "abcd1234", "state": state, "config": XCTUnwrap(object["config"])])
    }
    func testFlyDefaultFailsClosedWithoutLifetimeAuthorityAndRejectsUnsafeOperatorProfile() throws {
        let transport = Transport()
        let provider = FlyEnvironmentProvider(profile: try profile(), credential: { "test-token-never-live" }, transport: transport, clock: { self.start })
        XCTAssertFalse(provider.support.supportsCreate); XCTAssertFalse(provider.support.enforcesTTL)
        XCTAssertFalse(provider.support.nativeCreateIdempotency)
        XCTAssertThrowsError(try provider.create(intent()))
        XCTAssertEqual(transport.requests.count, 0)
        XCTAssertThrowsError(try profile(image: "registry.fly.io/rightclick-test:latest"))
        XCTAssertThrowsError(try profile(image: "https://user:password@evil.test/path@sha256:" + String(repeating: "a", count: 64)))
        XCTAssertThrowsError(try FlyEnvironmentProfile(app: "test/../../other", region: "lhr", ownerID: UUID().uuidString,
            ceiling: intent().spec, manifest: manifest(), image: "registry.fly.io/test@sha256:" + String(repeating: "a", count: 64), maximumMicroUSDPerSecond: 1))
    }
    func testFlyProductionCreateBuilderDoesNotLeakCredentialToChildAndNeverRetriesUncertainPOST() throws {
        let transport = Transport(); let guardAuthority = Guard()
        let secret = "test-token-only-node-local"
        let provider = FlyEnvironmentProvider(profile: try profile(), credential: { secret }, creationGuard: guardAuthority,
            transport: transport, clock: { self.start })
        transport.handler = { request in
            if request.httpMethod == "POST" { throw EnvironmentError.unavailable }
            return FlyMachinesResponse(statusCode: 200, url: request.url!, body: Data("[]".utf8))
        }
        let intent = try intent()
        XCTAssertEqual(try provider.create(intent).acceptance, .unknown)
        XCTAssertEqual(try provider.create(intent).acceptance, .unknown)
        let creates = transport.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(creates.count, 1)
        let request = try XCTUnwrap(creates.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.machines.dev/v1/apps/rightclick-test/machines")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + secret)
        XCTAssertFalse(try XCTUnwrap(String(data: XCTUnwrap(request.httpBody), encoding: .utf8)).contains(secret))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let config = try XCTUnwrap(body["config"] as? [String: Any])
        XCTAssertEqual(config["auto_destroy"] as? Bool, true)
        XCTAssertEqual((config["restart"] as? [String: String])?["policy"], "no")
        let processes = try XCTUnwrap(config["processes"] as? [[String: Any]])
        XCTAssertEqual(processes[0]["ignore_app_secrets"] as? Bool, true)
        XCTAssertEqual(processes[0]["exec"] as? [String], ["/usr/local/bin/rightclick-environment-runtime", "serve"])
        XCTAssertEqual(try provider.observe(correlationID: intent.correlationID).presence, .unknown)
        // A new adapter sharing durable guard state also refuses a second POST.
        let reopened = FlyEnvironmentProvider(profile: try profile(), credential: { secret }, creationGuard: guardAuthority,
            transport: transport, clock: { self.start })
        XCTAssertEqual(try reopened.create(intent).acceptance, .unknown)
        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }
    func testFlyReconciliationAndExact404AbsenceRequireAuthenticatedCorrelationBinding() throws {
        let transport = Transport(); let provider = FlyEnvironmentProvider(profile: try profile(), credential: { "test-token" },
            creationGuard: Guard(), transport: transport, clock: { self.start })
        let intent = try intent()
        var machineData: Data?
        var machineStatus = 200
        transport.handler = { request in
            if request.httpMethod == "POST" {
                machineData = try self.flyMachine(request)
                return FlyMachinesResponse(statusCode: 201, url: request.url!, body: machineData!)
            }
            let data = request.url!.path.hasSuffix("abcd1234") ? machineData ?? Data() : Data("[]".utf8)
            return FlyMachinesResponse(statusCode: request.url!.path.hasSuffix("abcd1234") ? machineStatus : 200, url: request.url!, body: data)
        }
        let acceptance = try provider.create(intent)
        XCTAssertEqual(acceptance.acceptance, .accepted)
        XCTAssertEqual(try provider.observe(correlationID: intent.correlationID).presence, .present)
        machineStatus = 403
        XCTAssertEqual(try provider.observe(correlationID: intent.correlationID).presence, .unknown)
        machineStatus = 404
        XCTAssertEqual(try provider.observe(correlationID: intent.correlationID).presence, .absent)
        XCTAssertThrowsError(try provider.observe(correlationID: UUID().uuidString))
        let wrong = try handle(intent, provider: provider, resourceID: "abcde")
        XCTAssertThrowsError(try provider.destroy(wrong, idempotencyKey: UUID().uuidString))
    }
    func testFlyRejectsRedirectsResponseOriginEscapeCredentialErrorsAndSpendOverflow() throws {
        let transport = Transport()
        let provider = FlyEnvironmentProvider(profile: try profile(), credential: { "test-token" },
            creationGuard: Guard(), transport: transport, clock: { self.start })
        transport.handler = { request in FlyMachinesResponse(statusCode: 302, url: request.url!, body: Data()) }
        XCTAssertThrowsError(try provider.list())
        transport.handler = { _ in FlyMachinesResponse(statusCode: 200, url: URL(string: "https://evil.test")!, body: Data("[]".utf8)) }
        XCTAssertThrowsError(try provider.list())
        let credentialFailure = FlyEnvironmentProvider(profile: try profile(), credential: { throw EnvironmentError.unavailable }, transport: transport)
        XCTAssertThrowsError(try credentialFailure.list()) { error in XCTAssertEqual(error as? EnvironmentError, .unavailable) }
        let expensive = FlyEnvironmentProvider(profile: try profile(rate: 1_000_000), credential: { "test-token" },
            creationGuard: Guard(), transport: transport, clock: { self.start })
        XCTAssertThrowsError(try expensive.create(intent()))
    }
    func testFlyDeleteAcceptedStillPresentIsObservedAndRecoveryUsesProtectedHistoricalBinding() throws {
        let transport = Transport(); let profile = try profile()
        let provider = FlyEnvironmentProvider(profile: profile, credential: { "test-token" }, creationGuard: Guard(),
            transport: transport, clock: { self.start })
        let intent = try intent()
        var machineData: Data?
        var gone = false
        transport.handler = { request in
            if request.httpMethod == "DELETE" { return FlyMachinesResponse(statusCode: 204, url: request.url!, body: Data()) }
            if request.httpMethod == "POST" {
                machineData = try self.flyMachine(request)
                return FlyMachinesResponse(statusCode: 201, url: request.url!, body: machineData!)
            }
            let exact = request.url!.path.hasSuffix("abcd1234")
            return FlyMachinesResponse(statusCode: exact && gone ? 404 : 200, url: request.url!,
                body: exact ? machineData ?? Data() : Data("[]".utf8))
        }
        let acceptance = try provider.create(intent)
        let historical = try provider.observe(correlationID: intent.correlationID)
        let handle = try handle(intent, provider: provider, resourceID: XCTUnwrap(acceptance.providerResourceID))
        XCTAssertEqual(try provider.destroy(handle, idempotencyKey: UUID().uuidString).acceptance, .accepted)
        XCTAssertEqual(try provider.observe(correlationID: intent.correlationID).presence, .present)
        let reopened = FlyEnvironmentProvider(profile: profile, credential: { "test-token" }, transport: transport, clock: { self.start })
        try reopened.restoreObservedBinding(intent: intent, observation: historical)
        gone = true
        XCTAssertEqual(try reopened.observe(correlationID: intent.correlationID).presence, .absent)
        let untrusted = try EnvironmentObservation(environmentID: intent.environmentID, correlationID: intent.correlationID,
            providerResourceID: "abcd1234", presence: .present, state: .ready, observedAtMilliseconds: start,
            observationBoundary: "child-self-report")
        XCTAssertThrowsError(try reopened.restoreObservedBinding(intent: intent, observation: untrusted))
    }
    func testFlyBootstrapAndChallengeUseFixedArgvAndSeparateObservation() throws {
        let transport = Transport()
        let provider = FlyEnvironmentProvider(profile: try profile(), credential: { "test-token" }, creationGuard: Guard(),
            transport: transport, clock: { self.start })
        let intent = try intent()
        var machineData: Data?
        transport.handler = { request in
            if request.httpMethod == "POST" && request.url!.path.hasSuffix("/machines") {
                machineData = try self.flyMachine(request, state: "started")
                return FlyMachinesResponse(statusCode: 201, url: request.url!, body: machineData!)
            }
            if request.url!.path.hasSuffix("/exec") {
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                let command = try XCTUnwrap(body["command"] as? [String])
                XCTAssertEqual(command[0], "/usr/local/bin/rightclick-environment-runtime")
                XCTAssertEqual(command.count, 2); XCTAssertNil(body["cmd"])
                let input = try XCTUnwrap(body["stdin"] as? String)
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
                var helper: [String: Any] = [:]
                if command[1] == "observe-challenge" {
                    helper = ["environmentID": intent.environmentID, "executionID": try XCTUnwrap(payload["executionID"]),
                        "challenge": "wrong-result"]
                }
                let stdout = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: helper), encoding: .utf8))
                return FlyMachinesResponse(statusCode: 200, url: request.url!, body: try JSONSerialization.data(withJSONObject: [
                    "exit_code": 0, "exit_signal": 0, "stderr": "", "stdout": stdout]))
            }
            return FlyMachinesResponse(statusCode: 200, url: request.url!, body: request.url!.path.hasSuffix("abcd1234") ? machineData ?? Data() : Data("[]".utf8))
        }
        let acceptance = try provider.create(intent)
        let handle = try handle(intent, provider: provider, resourceID: XCTUnwrap(acceptance.providerResourceID))
        XCTAssertEqual(try provider.bootstrap(handle, manifest: manifest()).acceptance, .accepted)
        XCTAssertNil(try provider.observe(correlationID: intent.correlationID).runtime)
        let executionID = UUID().uuidString
        let challenge = "\";$(touch /tmp/should-never-run);"
        XCTAssertEqual(try provider.executeChallenge(handle, executionID: executionID, challenge: challenge).acceptance, .accepted)
        XCTAssertEqual(try provider.observeChallenge(handle, executionID: executionID), "wrong-result")
        XCTAssertNotEqual(try provider.observeChallenge(handle, executionID: executionID), challenge)
        let execs = transport.requests.filter { $0.url?.path.hasSuffix("/exec") == true }
        XCTAssertTrue(execs.allSatisfy { request in
            guard let data = request.httpBody, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let command = object["command"] as? [String] else { return false }
            return !command.contains(challenge)
        })
    }
}
