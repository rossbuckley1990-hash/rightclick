import Foundation
import NIOPosix
import RightClickCore
import RightClickLink
import RightClickMCP
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Explicit acceptance composition. Never installed by normal startup. The
// capability and credential are disposable proof fixtures, not provider tools.
private final class FabricProofProvider: RCIRExecutionReflector {
    let id = "fixture:portable-deferred-owner"
    let effectFile: URL
    private let lock = NSLock()
    init(effectFile: URL) { self.effectFile = effectFile }
    var declaration: Capability {
        Capability(id: "fixture:portable-deferred", title: "Portable deferred acceptance fixture",
            source: .system, reflectorID: id, safety: .localReversible, invocation: .direct,
            supportLevel: .publicSupported, requiresConfirmation: false,
            metadata: ["fixture": "bounded-local-counter"])
    }
    func capabilities(for item: ContentItem) throws -> [Capability] { [declaration] }
    func providers() -> [ProviderSummary] {
        [.init(name: "Portable deferred acceptance fixture", source: "proof-fixture", capabilityTitles: [declaration.title])]
    }
    func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
        throw RightClickError("Fixture requires the ordinary RCIR admission host.")
    }
    func admittedBegin(capability: Capability, admissionOwner: Capability, item: ContentItem, executionID: String,
        arguments: CapabilityArguments?, verification: VerificationSpec?, expectedOutput: String?,
        host: RCIRExecutionHost, revalidate: @escaping () -> Bool) throws -> ExecutionRecord {
        guard ProcessInfo.processInfo.environment["RIGHTCLICK_FABRIC_PROOF_SECRET"] != nil else {
            throw RightClickError("Fixture credential is not provisioned on the execution node.")
        }
        let contract = try admissionOwner.abiContract(arguments: .string, result: .integer)
        let scope = RCIRScope("urn:rightclick:acceptance:counter", .execute)
        return try host.execute(abi: contract, discovery: contract, arguments: .string(item.text ?? ""), scope: scope,
            taskModel: .init(shape: .deferred, maxEvents: 16, maxBytes: 16_384),
            capability: admissionOwner, executionID: executionID, argumentStrings: arguments, item: item,
            verification: verification, expectedOutput: expectedOutput,
            target: URL(string: "https://example.invalid/portable-deferred-proof")!, authority: { [scope] },
            revalidate: revalidate, currentContract: { true }, dispatch: { _, start in
                var startError: Error?
                try start {
                    self.lock.lock()
                    let count = (try? String(contentsOf: self.effectFile, encoding: .utf8)).flatMap { Int($0) } ?? 0
                    do { try String(count + 1).write(to: self.effectFile, atomically: true, encoding: .utf8) }
                    catch { startError = error; self.lock.unlock(); return }
                    self.lock.unlock()
                    _ = try? host.recordActiveTaskEvent(executionID: executionID, event: .accepted, now: Self.now())
                    Task.detached {
                        try await Task.sleep(for: .milliseconds(300))
                        _ = try host.recordActiveTaskEvent(executionID: executionID, event: .working, now: Self.now())
                        try await Task.sleep(for: .milliseconds(1400))
                        _ = try host.recordActiveTaskEvent(executionID: executionID, event: .completed(.integer(7)), now: Self.now())
                    }
                }
                if let startError { throw startError }
                return ExecutionRecord(executionId: executionID, actionId: capability.id, title: capability.title,
                    state: .started, message: "Portable fixture is running.")
            }, resultValue: { record in
                guard let result = record.result else { throw RightClickError("Live fixture has no terminal result.") }
                return result
            })
    }
    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

@main
struct FabricProcessMain {
    @MainActor static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch { fputs("Fabric acceptance process failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor private static func run(_ args: [String]) async throws {
        guard let mode = args.first else { throw RightClickError("A proof process role is required.") }
        func flag(_ name: String) throws -> String {
            guard let index = args.firstIndex(of: name), index + 1 < args.count else { throw RightClickError("Missing \(name).") }
            return args[index + 1]
        }
        func number(_ name: String) throws -> Int {
            guard let value = Int(try flag(name)), (1...65535).contains(value) else { throw RightClickError("Invalid port.") }
            return value
        }
        func identity() throws -> RemoteNodeIdentity {
            let path = try flag("--key")
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw RightClickError("Proof identity unavailable.") }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
                info.st_mode & 0o077 == 0, info.st_size == 32 else { throw RightClickError("Proof identity must be protected.") }
            var key = [UInt8](repeating: 0, count: 32)
            guard read(fd, &key, 32) == 32 else { throw RightClickError("Proof identity read failed.") }
            return try RemoteNodeIdentity(signer: RCIREd25519Signer(rawPrivateKey: Data(key)))
        }
        if mode == "identity" {
            let node = try identity()
            print(RightClickJSON.encode(IdentityOutput(publicKey: node.publicKey.base64EncodedString(), runtimeID: node.runtimeID, deviceID: node.deviceID)))
            return
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        if mode == "broker" {
            let broker = EncryptedOutboundLinkBroker(group: group)
            let port = try await broker.start(host: "127.0.0.1", port: number("--port"))
            print("{\"ready\":true,\"role\":\"broker\",\"port\":\(port)}"); fflush(stdout)
            try await Task.sleep(for: .seconds(3600)); await broker.shutdown(); return
        }
        let node = try identity()
        if mode == "retry-proof" {
            guard let targetKey = Data(base64Encoded: try flag("--target-public-key")) else { throw RightClickError("Invalid target key.") }
            let transport = try EncryptedOutboundLinkTransport(identity: node, trustedRuntimeKey: targetKey,
                host: "127.0.0.1", port: number("--broker-port"), group: group)
            let client = try RemoteLinkClient(identity: node, trustedRuntimeKey: targetKey, transport: transport)
            let discovered = try await client.send(client.makeRequest(operation: .actions, item: "portable proof"))
            guard let capability = discovered.summary.capabilities.first(where: { $0.id == "fixture:portable-deferred" }) else {
                throw RightClickError("Acceptance capability was not discovered.")
            }
            let key = UUID()
            func fresh() -> RemoteExecutionRequest {
                client.makeRequest(operation: .run, item: "portable proof", capabilityID: capability.id,
                    capabilityDigest: capability.contractDigest, idempotencyKey: key)
            }
            let original = fresh()
            let first = try await client.send(original)
            guard let live = first.summary.executionLifecycle, !live.terminal else { throw RightClickError("Retry proof did not begin live.") }
            var replayRejected = false
            do { _ = try await client.send(original) }
            catch { replayRejected = true }
            guard replayRejected else { throw RightClickError("Exact signed request replay was accepted.") }
            let retry = try await client.send(fresh())
            guard retry.reused, retry.summary.executionLifecycle?.executionID == live.executionID else {
                throw RightClickError("Fresh same-intent retry did not retain the original execution.")
            }
            var terminal: RemoteExecutionResult?
            for _ in 0..<100 {
                let status = try await client.send(client.makeStatusRequest(for: original, executionID: live.executionID))
                if status.summary.executionLifecycle?.terminal == true { terminal = status; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let terminal, terminal.summary.executionLifecycle?.phase == .completed,
                terminal.summary.executionLifecycle?.signedReceiptAvailable == true,
                try terminal.summary.result?.canonicalData() == CapabilityValue.integer(7).canonicalData() else {
                throw RightClickError("Retry proof did not retain typed terminal evidence.")
            }
            let retained = try await client.send(fresh())
            guard retained.reused, retained.summary.executionLifecycle?.executionID == live.executionID,
                retained.summary.executionLifecycle?.terminal == true else { throw RightClickError("Terminal retry was not reused.") }
            print(RightClickJSON.encode(RetryOutput(first: first, retry: retry, terminal: terminal,
                retained: retained, exactReplayRejected: replayRejected)))
            try await group.shutdownGracefully()
            return
        }
        let mcpPort = try number("--mcp-port")
        let engine: CapabilityEngine
        if mode == "local" || mode == "target" {
            let provider = FabricProofProvider(effectFile: URL(fileURLWithPath: try flag("--effects")))
            engine = CapabilityEngine(reflectors: [provider], experience: nil)
            if mode == "target" {
                guard let callerKey = Data(base64Encoded: try flag("--caller-public-key")) else { throw RightClickError("Invalid caller key.") }
                let ledger = try RemoteReplayLedger(directory: URL(fileURLWithPath: try flag("--ledger")), runtimeID: node.runtimeID)
                let grant = try RemoteCallerGrant(publicKey: callerKey, operations: [.runtime, .actions, .run, .status],
                    capabilityIDs: [provider.declaration.id], exportValueCapabilityIDs: [provider.declaration.id])
                let dispatcher = try RemoteExecutionDispatcher(engine: engine, identity: node, ledger: ledger, grants: [grant], enabled: true)
                let session = EncryptedOutboundLinkHostSession(dispatcher: dispatcher, identity: node, group: group)
                try await session.connect(host: "127.0.0.1", port: number("--broker-port"))
                // Session is retained by its channel handler throughout MCP's run loop.
                print("{\"ready\":true,\"role\":\"target\"}"); fflush(stdout)
                try await RightClickMCPMain.serveHTTP(engine: engine, port: UInt16(mcpPort),
                    token: ProcessInfo.processInfo.environment["RIGHTCLICK_MCP_TOKEN"] ?? "")
                await session.shutdown()
                return
            }
        } else if mode == "caller" {
            guard let targetKey = Data(base64Encoded: try flag("--target-public-key")) else { throw RightClickError("Invalid target key.") }
            let transport = try EncryptedOutboundLinkTransport(identity: node, trustedRuntimeKey: targetKey,
                host: "127.0.0.1", port: number("--broker-port"), group: group)
            let client = try RemoteLinkClient(identity: node, trustedRuntimeKey: targetKey, transport: transport)
            let registry = RemoteRuntimeRegistry()
            try await registry.enroll(client, item: "portable proof")
            engine = CapabilityEngine(reflectors: [], reflectorSources: [RemoteCapabilitySource(registry: registry)], experience: nil)
        } else { throw RightClickError("Unknown proof role.") }
        print("{\"ready\":true,\"role\":\"\(mode)\"}"); fflush(stdout)
        try await RightClickMCPMain.serveHTTP(engine: engine, port: UInt16(mcpPort),
            token: ProcessInfo.processInfo.environment["RIGHTCLICK_MCP_TOKEN"] ?? "")
    }
    private struct IdentityOutput: Codable { let publicKey: String; let runtimeID: String; let deviceID: String }
    private struct RetryOutput: Codable {
        let first: RemoteExecutionResult
        let retry: RemoteExecutionResult
        let terminal: RemoteExecutionResult
        let retained: RemoteExecutionResult
        let exactReplayRejected: Bool
    }
}
