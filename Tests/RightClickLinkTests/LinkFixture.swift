import Foundation
import RightClickCore
@testable import RightClickLink

/// Synthetic host topology; native Linux binary proof is a separate CI gate.
final class LinkMockReflector: CapabilityVerificationReflector {
    let id = "fixture.host-provider"
    var declaration = Capability(id: "fixture:host-app", title: "Host fixture capability", source: .system,
        safety: .read, invocation: .direct, supportLevel: .experimental, requiresConfirmation: false,
        runtimeRequirements: .init(operatingSystems: [.macOS], architectures: ["arm64"]))
    var effects = 0, credentialReads = 0, observations = 0, discoveryCount = 0
    var state = "initial", changeState = true, observerAvailable = true, contradictory = false, throwAfterEffect = false
    var onDiscovery: ((Int) -> Void)?
    var entryDelay: TimeInterval = 0
    private let activityLock = NSLock()
    private var activeEntries = 0, overlapCount = 0
    var overlappingEntries: Int { activityLock.lock(); defer { activityLock.unlock() }; return overlapCount }
    private func enter() {
        activityLock.lock(); activeEntries += 1; if activeEntries > 1 { overlapCount += 1 }; activityLock.unlock()
        if entryDelay > 0 { Thread.sleep(forTimeInterval: entryDelay) }
    }
    private func leave() { activityLock.lock(); activeEntries -= 1; activityLock.unlock() }
    static let sentinel = "TEST-ONLY-LOCAL-CREDENTIAL-DO-NOT-EXPORT"
    func capabilities(for item: ContentItem) throws -> [Capability] { enter(); defer { leave() }; discoveryCount += 1; onDiscovery?(discoveryCount); return [declaration] }
    func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
        enter(); defer { leave() }
        effects += 1; credentialReads += 1
        if changeState { state = item.text ?? "" }
        if throwAfterEffect { throw RightClickError("Private provider diagnostic " + Self.sentinel) }
        return .init(executionId: executionID, actionId: capability.id, state: .accepted,
            message: "Provider diagnostic " + Self.sentinel, output: "Provider response " + Self.sentinel)
    }
    func begin(capability: Capability, item: ContentItem, executionID: String, arguments: CapabilityArguments?, verification: VerificationSpec) throws -> ExecutionRecord {
        var record = try begin(capability: capability, item: item, executionID: executionID)
        observations += 1
        guard observerAvailable else { record.verification = .init(status: .unverified, predicates: []); return record }
        let passed = verification.predicates.allSatisfy { $0.type == .textEquals && $0.value == state }
        record.state = passed || contradictory ? .succeeded : .failed
        record.verification = .init(status: passed || contradictory ? .verifiedSuccess : .verifiedFailure,
            predicates: verification.predicates.map { .init(predicate: $0, evaluated: true, passed: contradictory ? false : passed, actual: state, message: "Separate fixture state observation.") })
        record.evidence = .init(type: "fixture_independent_state", boundary: "Separate host state observation.",
            outcomeVerified: passed || contradictory, observationBoundary: .externalState)
        return record
    }
}
final class LinkFixtureApproval: RemoteLocalApproval {
    var ticket: RemoteApprovalTicket?
    func approval(for request: RemoteExecutionRequest, capabilityDigest: String) -> RemoteApprovalTicket? { ticket }
}

@MainActor
final class LinkFixture {
    let parent: URL
    let provider = LinkMockReflector()
    let caller: RemoteNodeIdentity
    let identity: RemoteNodeIdentity
    let engine: CapabilityEngine
    let relay = SimulatedLinkRelay()
    let ledger: RemoteReplayLedger
    let dispatcher: RemoteExecutionDispatcher
    let client: RemoteLinkClient
    let approval = LinkFixtureApproval()
    var capability: Capability { get throws { try engine.capabilities(for: "desired").capabilities[0] } }
    init(enabled: Bool = true, maximumRequests: Int = 1024) throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-link-test-" + UUID().uuidString).standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        caller = try .init(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 1, count: 32)))
        identity = try .init(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 2, count: 32)))
        engine = CapabilityEngine(reflectors: [provider], experience: nil, runtimeEnvironment: .init(operatingSystem: .macOS, architecture: "arm64"))
        ledger = try .init(directory: parent.appendingPathComponent("journal"), runtimeID: identity.runtimeID, maximumRequests: maximumRequests)
        let grant = try RemoteCallerGrant(publicKey: caller.publicKey, operations: [.runtime, .actions, .run], capabilityIDs: [provider.declaration.id, "fixture:missing"])
        // Capturing a separate clock box avoids using self before initialization.
        let stamp: () -> Int64 = { 1_000 }
        dispatcher = try .init(engine: engine, identity: identity, ledger: ledger, grants: [grant], enabled: enabled, localApproval: approval, now: stamp)
        client = try .init(identity: caller, trustedRuntimeKey: identity.publicKey, transport: relay, now: stamp)
    }
    deinit { try? FileManager.default.removeItem(at: parent) }
    func connect() async throws { try await dispatcher.establishOutboundConnection(to: relay) }
    func request(verification: Bool = true, key: UUID = UUID()) throws -> RemoteExecutionRequest {
        try client.makeRequest(operation: .run, item: "desired", capabilityID: provider.declaration.id,
            capabilityDigest: RemoteExecutionDispatcher.contractDigest(capability),
            verification: verification ? .init(predicates: [.init(type: .textEquals, value: "desired")]) : nil, idempotencyKey: key)
    }
    func bytes(_ request: RemoteExecutionRequest) throws -> Data { try SignedRemoteMessage.request(request, signer: caller) }
}
