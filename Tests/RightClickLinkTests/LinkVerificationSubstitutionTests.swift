#if os(macOS) || os(Linux)
import Foundation
import XCTest
@testable import RightClickProtocol
@testable import RightClickProviders
@testable import RightClickCore
@testable import RightClickLink

// Regression: the provider supplies a passing predicate for different
// bytes. This must not prove the caller's requested postcondition.
final class LinkVerificationSubstitutionTests: XCTestCase {
    private final class SubstitutingProvider: CapabilityVerificationReflector {
        let id = "fixture.substitution"
        let action = "fixture:mutation"
        var effects = 0
        var forgedRCIR = false
        var failure = false
        func capabilities(for item: ContentItem) throws -> [Capability] {
            [.init(id: action, title: "Effect", source: .system, reflectorID: id,
                   safety: .read, invocation: .direct, supportLevel: .experimental,
                   requiresConfirmation: false)]
        }
        func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
            effects += 1
            return .init(executionId: executionID, actionId: action, state: .accepted, message: "Provider accepted")
        }
        func begin(capability: Capability, item: ContentItem, executionID: String,
                   arguments: CapabilityArguments?, verification: VerificationSpec) throws -> ExecutionRecord {
            var record = try begin(capability: capability, item: item, executionID: executionID)
            record.state = failure ? .failed : .succeeded
            record.evidence = .init(type: "provider_claim", boundary: "Provider asserted another result",
                outcomeVerified: true, observationBoundary: .externalState)
            record.verification = .init(status: failure ? .verifiedFailure : .verifiedSuccess, predicates: [.init(
                predicate: .init(type: .textEquals, value: "different"), evaluated: true,
                passed: !failure, actual: "different", message: "Substituted predicate")])
            if forgedRCIR {
                record.rcir = .init(version: 1, taskID: UUID().uuidString, leaseID: UUID().uuidString,
                    generation: 1, leaseConsumed: true, phase: "completed", outcome: failure ? "failed" : "succeeded",
                    receipt: nil, signedReceipt: nil, observationBoundary: "Forged host observation")
            }
            return record
        }
    }
    @MainActor func testLinkDoesNotAuthenticateVerificationOfSubstitutedPostcondition() async throws {
        try await checkSubstitution()
    }
    @MainActor func testForgedRCIRCannotBypassCallerPredicateValidation() async throws {
        try await checkSubstitution(forgedRCIR: true)
    }
    @MainActor func testSubstitutedFailureCannotVerifyCallerPostcondition() async throws {
        try await checkSubstitution(failure: true)
    }
    @MainActor func testForgedRCIRCannotVerifySubstitutedFailure() async throws {
        try await checkSubstitution(forgedRCIR: true, failure: true)
    }
    @MainActor private func checkSubstitution(forgedRCIR: Bool = false, failure: Bool = false) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("link-predicate-" + UUID().uuidString)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = SubstitutingProvider(), engine = CapabilityEngine(reflectors: [provider], experience: nil)
        provider.forgedRCIR = forgedRCIR; provider.failure = failure
        let node = try RemoteNodeIdentity(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 42, count: 32)))
        let caller = try RemoteNodeIdentity(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 43, count: 32)))
        let ledger = try RemoteReplayLedger(directory: directory.appendingPathComponent("ledger"), runtimeID: node.runtimeID)
        let dispatcher = try RemoteExecutionDispatcher(engine: engine, identity: node, ledger: ledger,
            grants: [.init(publicKey: caller.publicKey, operations: [.run], capabilityIDs: [provider.action])],
            enabled: true, now: { 1000 })
        let relay = SimulatedLinkRelay()
        try await dispatcher.establishOutboundConnection(to: relay)
        let client = try RemoteLinkClient(identity: caller, trustedRuntimeKey: node.publicKey, transport: relay, now: { 1000 })
        let capability = try XCTUnwrap(engine.capabilities(for: "desired").capabilities.first)
        let request = client.makeRequest(operation: .run, item: "desired", capabilityID: provider.action,
            capabilityDigest: try RemoteExecutionDispatcher.contractDigest(capability),
            verification: .init(predicates: [.init(type: .textEquals, value: "desired")]))
        let result = try await client.send(request)
        XCTAssertEqual(result.summary.state, .accepted)
        XCTAssertEqual(result.summary.verification, .unverified)
        XCTAssertEqual(provider.effects, 1)
    }
}

#endif
