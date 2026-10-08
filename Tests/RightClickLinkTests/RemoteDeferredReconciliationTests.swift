import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import XCTest
@testable import RightClickProtocol
@testable import RightClickProviders
@testable import RightClickCore
@testable import RightClickLink
@testable import RightClickMCP

/// Genuine A2A agent and independent observer behind Link, not a second executor.
final class RemoteDeferredReconciliationTests: XCTestCase {
    private final class FixtureApproval: RemoteLocalApproval {
        var ticket: RemoteApprovalTicket?
        var approveLocally = false
        func approval(for request: RemoteExecutionRequest, capabilityDigest: String) -> RemoteApprovalTicket? {
            if approveLocally { return try? .init(approvedRequest: request, capabilityDigest: capabilityDigest) }
            return ticket
        }
    }
    @MainActor private final class Fixture {
        let directory: URL
        let agent: Process
        let observer: Process
        let caller: RemoteNodeIdentity
        let identity: RemoteNodeIdentity
        let host = RCIRExecutionHost()
        let engine: CapabilityEngine
        let capability: Capability
        let ledger: RemoteReplayLedger
        let dispatcher: RemoteExecutionDispatcher
        let relay = SimulatedLinkRelay()
        let approval = FixtureApproval()
        var clock: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
        var configuration = RCIRHostConfiguration()

        init() throws {
            guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw RightClickError("Missing physical scratch directory") }
            let scratch = String(cString: physical); free(physical)
            let directory = URL(fileURLWithPath: scratch).appendingPathComponent("rightclick-link-a2a-" + UUID().uuidString).standardizedFileURL.resolvingSymlinksInPath()
            self.directory = directory
            var started: [Process] = [], initialized = false
            defer {
                if !initialized {
                    for process in started where process.isRunning { process.terminate(); process.waitUntilExit() }
                    try? FileManager.default.removeItem(at: directory)
                }
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            func launch(_ script: String, hold: Bool = false) throws -> Process {
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["python3", root.appendingPathComponent("scripts/" + script).path, directory.path] + (hold ? ["--hold-until-file"] : [])
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); started.append(process); return process
            }
            let agent = try launch("a2a-proof-agent.py", hold: true); self.agent = agent
            let observer = try launch("a2a-proof-observer.py"); self.observer = observer
            func port(_ name: String) throws -> String {
                let file = directory.appendingPathComponent(name), deadline = Date().addingTimeInterval(5)
                while !FileManager.default.fileExists(atPath: file.path), Date() < deadline {
                    guard agent.isRunning, observer.isRunning else { throw RightClickError("A2A fixture exited") }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                return try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let base = "http://127.0.0.1:" + (try port("port"))
            let observerBase = "http://127.0.0.1:" + (try port("observer-port"))
            let providers = directory.appendingPathComponent("providers.json")
            try JSONSerialization.data(withJSONObject: ["version": 1, "agentCards": [base + "/.well-known/agent.json"]]).write(to: providers)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: providers.path)
            engine = CapabilityEngine(reflectorSources: [ConfiguredA2ASource(configurationFile: providers)], experience: nil, rcirHost: host)
            capability = try XCTUnwrap(engine.capabilities(for: "delegated proof").capabilities.first)
            caller = try .init(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 51, count: 32)))
            identity = try .init(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 52, count: 32)))
            let signer = directory.appendingPathComponent("receipt-key.raw")
            try Data(repeating: 53, count: 32).write(to: signer)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: signer.path)
            var check = RCIRHostConfiguration.Observer(urlTemplate: observerBase + "/observations/{message}", expectedArgument: "message")
            check.trustedOrigin = observerBase
            configuration.observers = [capability.id: check]; configuration.signingKeyFile = signer.path
            // Link preserves Foundation's native system-alias representation;
            // protected provider references above retain physical POSIX paths.
            let journalDirectory = directory.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("journal")
            ledger = try .init(directory: journalDirectory, runtimeID: identity.runtimeID)
            let grant = try RemoteCallerGrant(publicKey: caller.publicKey, operations: [.runtime, .actions, .run, .status], capabilityIDs: [capability.id])
            // Both closures use boxes, assigned after all stored properties exist.
            let clockBox = ClockBox(clock)
            dispatcher = try .init(engine: engine, identity: identity, ledger: ledger, grants: [grant], enabled: true,
                localApproval: approval, now: { clockBox.value })
            self.clockBox = clockBox
            host.configuration = { [weak self] in self?.configuration ?? RCIRHostConfiguration() }
            initialized = true
        }
        private var clockBox: ClockBox? = nil
        private final class ClockBox { var value: Int64; init(_ value: Int64) { self.value = value } }
        func advanceClock() { clock += 60_001; clockBox?.value = clock }
        func client(identity caller: RemoteNodeIdentity? = nil) throws -> RemoteLinkClient {
            try .init(identity: caller ?? self.caller, trustedRuntimeKey: identity.publicKey, transport: relay, now: { self.clock })
        }
        func run(client: RemoteLinkClient, key: UUID = UUID()) throws -> RemoteExecutionRequest {
            let message = String(data: try JSONSerialization.data(withJSONObject: ["challenge": UUID().uuidString, "value": "requested"], options: [.sortedKeys]), encoding: .utf8)!
            return client.makeRequest(operation: .run, item: "delegated proof", capabilityID: capability.id,
                capabilityDigest: try RemoteExecutionDispatcher.contractDigest(capability), arguments: ["message": message], idempotencyKey: key)
        }
        func status(client: RemoteLinkClient, executionID: String) throws -> RemoteExecutionRequest {
            client.makeRequest(operation: .status, item: "delegated proof", capabilityID: capability.id,
                capabilityDigest: try RemoteExecutionDispatcher.contractDigest(capability), executionID: executionID)
        }
        func rows(_ filename: String) throws -> Int {
            let file = directory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
            return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").count
        }
        func close() {
            for process in [agent, observer] where process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor func testSevenOperationRoutedA2ATaskRefreshesThroughItsOriginalExecutionNode() async throws {
        let f = try Fixture(); defer { f.close() }
        f.approval.approveLocally = true // Explicit fixture-side user approval, never supplied by the caller.
        try await f.dispatcher.establishOutboundConnection(to: f.relay)
        let registry = RemoteRuntimeRegistry(now: { f.clock })
        try await registry.enroll(f.client(), item: "delegated proof")
        let callerEngine = CapabilityEngine(reflectorSources: [RemoteCapabilitySource(registry: registry)], experience: nil,
            runtimeEnvironment: .init(operatingSystem: .linux, architecture: "x86_64"))
        let box = EngineBox(callerEngine)
        XCTAssertEqual(RightClickMCPContract.toolNames().count, 7)
        let catalog = try JSONSerialization.jsonObject(with: Data(handleTool("context_actions", arguments: ["item": .string("delegated proof")], engine: box, transport: "stdio").utf8)) as! [String: Any]
        let action = try XCTUnwrap((catalog["actions"] as? [[String: Any]])?.first?["id"] as? String)
        let message = String(data: try JSONSerialization.data(withJSONObject: ["challenge": UUID().uuidString, "value": "requested"]), encoding: .utf8)!
        let text = try handleTool("context_run", arguments: ["item": .string("delegated proof"), "actionId": .string(action),
            "confirmed": .bool(true), "arguments": .object(["message": .string(message)])], engine: box, transport: "stdio")
        let initial = try JSONDecoder().decode(ExecutionRecord.self, from: Data(text.utf8))
        XCTAssertEqual(initial.state, .started)
        for _ in 0..<100 {
            if try f.rows("requests.jsonl") == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        for _ in 0..<100 {
            if ExecutionStore.shared.get(initial.executionId)?.message.hasPrefix("Authenticated node result:") == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(ExecutionStore.shared.get(initial.executionId)?.message.hasPrefix("Authenticated node result:") == true)
        f.advanceClock() // Fresh owned status remains valid after the catalog/delivery TTL.
        try Data().write(to: f.directory.appendingPathComponent("release"))
        var final = initial
        for _ in 0..<100 {
            let status = try handleTool("context_run_status", arguments: ["executionId": .string(initial.executionId)], engine: box, transport: "stdio")
            final = try JSONDecoder().decode(ExecutionRecord.self, from: Data(status.utf8))
            if final.state == .succeeded || final.state == .failed || final.state == .unknown { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(final.state, .succeeded, final.message)
        XCTAssertTrue(final.evidence.outcomeVerified)
        XCTAssertEqual(final.evidence.observationBoundary, .externalState)
        XCTAssertEqual(try f.rows("requests.jsonl"), 1); XCTAssertEqual(try f.rows("effects.jsonl"), 1)
        XCTAssertEqual(final.actionId, action); XCTAssertEqual(final.executionId, initial.executionId)
        print("SEVEN-OP ROUTED A2A: simulated Linux caller -> enrolled node -> one Core/RCIR admission -> deferred task -> context_run_status -> signed owned Link status -> independent VERIFIED; effects=1")
    }

    @MainActor func testRoutedTaskRecoversAfterLostStatusReplyWithoutAnotherRun() async throws {
        let f = try Fixture(); defer { f.close() }
        f.approval.approveLocally = true
        try await f.dispatcher.establishOutboundConnection(to: f.relay)
        let client = try f.client(), registry = RemoteRuntimeRegistry(now: { f.clock })
        try await registry.enroll(client, item: "delegated proof")
        let callerEngine = CapabilityEngine(reflectorSources: [RemoteCapabilitySource(registry: registry)], experience: nil)
        let action = try XCTUnwrap(callerEngine.capabilities(for: "delegated proof").capabilities.first)
        let message = String(data: try JSONSerialization.data(withJSONObject: ["challenge": UUID().uuidString, "value": "requested"]), encoding: .utf8)!
        let initial = try callerEngine.begin(id: action.id, item: "delegated proof", confirmed: true, arguments: ["message": message])
        for _ in 0..<100 {
            if ExecutionStore.shared.get(initial.executionId)?.message.hasPrefix("Authenticated node result:") == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(ExecutionStore.shared.get(initial.executionId)?.message.hasPrefix("Authenticated node result:") == true)
        await f.relay.loseNextResponse()
        _ = callerEngine.executionStatus(initial.executionId)
        for _ in 0..<100 {
            if ExecutionStore.shared.get(initial.executionId)?.state == .unknown { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(ExecutionStore.shared.get(initial.executionId)?.state, .unknown)
        try await registry.enroll(client, item: "delegated proof") // Same authenticated node/client only.
        try Data().write(to: f.directory.appendingPathComponent("release"))
        var final = initial
        for _ in 0..<100 {
            final = callerEngine.executionStatus(initial.executionId)
            if final.state == .succeeded { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(final.state, .succeeded, final.message)
        XCTAssertTrue(final.evidence.outcomeVerified)
        XCTAssertEqual(try f.rows("requests.jsonl"), 1); XCTAssertEqual(try f.rows("effects.jsonl"), 1)
        print("STATUS RECOVERY: known owned task -> dropped status reply -> UNKNOWN -> same enrollment reconnect -> status only -> VERIFIED; sends=1 effects=1")
    }

    @MainActor func testActualA2ALinkStatusSurvivesClientRestartAndOriginalExpiryWithoutAnotherEffect() async throws {
        let f = try Fixture(); defer { f.close() }
        try await f.dispatcher.establishOutboundConnection(to: f.relay)
        let client = try f.client(), run = try f.run(client: client)
        f.approval.ticket = try .init(approvedRequest: run, capabilityDigest: run.capabilityDigest!)
        let initial = try await client.send(run)
        XCTAssertEqual(initial.summary.state, .started); XCTAssertEqual(initial.summary.taskPhase, "accepted")
        XCTAssertEqual(initial.summary.verification, .unverified); XCTAssertEqual(try f.rows("requests.jsonl"), 1)
        XCTAssertEqual(try f.rows("effects.jsonl"), 0)
        let id = try XCTUnwrap(initial.summary.evidenceExecutionID)
        f.advanceClock() // The original delivery expires; admitted work is not dispatched again.
        let restartedClient = try f.client()
        try Data().write(to: f.directory.appendingPathComponent("release"))
        var final = initial
        for _ in 0..<80 {
            final = try await restartedClient.send(f.status(client: restartedClient, executionID: id))
            if final.summary.state != .started { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(final.summary.state, .succeeded); XCTAssertEqual(final.summary.verification, .verifiedSuccess)
        XCTAssertEqual(final.summary.observationBoundary, .externalState)
        XCTAssertEqual(try f.rows("requests.jsonl"), 1); XCTAssertEqual(try f.rows("effects.jsonl"), 1)
        XCTAssertEqual(f.engine.executionStatus(id).rcir?.outcome, "succeeded")
        XCTAssertNotNil(f.engine.executionStatus(id).rcir?.signedReceipt)
        print("RECONCILIATION A2A: signed Link -> normal Core -> one RCIR lease -> deferred task -> fresh owned status after caller restart/expiry -> independent observation -> VERIFIED; sends=1 effects=1")
    }

    @MainActor func testOwnedStatusRejectsContextContractAndExecutionSubstitutionWithoutPolling() async throws {
        let f = try Fixture(); defer { f.close() }; try await f.dispatcher.establishOutboundConnection(to: f.relay)
        let client = try f.client(), run = try f.run(client: client)
        f.approval.ticket = try .init(approvedRequest: run, capabilityDigest: run.capabilityDigest!)
        let initial = try await client.send(run), id = try XCTUnwrap(initial.summary.evidenceExecutionID)
        let before = try f.rows("polls.jsonl")
        for change in 0..<4 {
            var status = try f.status(client: client, executionID: id)
            switch change {
            case 0: status.item = "other context"
            case 1: status.capabilityDigest = String(repeating: "a", count: 64)
            case 2: status.executionID = UUID().uuidString
            default: status.arguments = ["confirmed": "true"]
            }
            XCTAssertThrowsError(try f.dispatcher.handle(SignedRemoteMessage.request(status, signer: f.caller)))
        }
        f.dispatcher.revoke(callerID: run.callerID)
        XCTAssertThrowsError(try f.dispatcher.handle(SignedRemoteMessage.request(f.status(client: client, executionID: id), signer: f.caller)))
        XCTAssertEqual(try f.rows("polls.jsonl"), before); XCTAssertEqual(try f.rows("requests.jsonl"), 1)
    }

    @MainActor func testLostAcceptanceReplyRetryIsCachedAndCanReadTheOwnedTask() async throws {
        let f = try Fixture(); defer { f.close() }; try await f.dispatcher.establishOutboundConnection(to: f.relay)
        let client = try f.client(); let run = try f.run(client: client)
        f.approval.ticket = try .init(approvedRequest: run, capabilityDigest: run.capabilityDigest!)
        await f.relay.loseNextResponse()
        do { _ = try await client.send(run); XCTFail("Dropped Link response must be uncertain") }
        catch { XCTAssertEqual(error as? RemoteLinkError, .connectionLost) }
        var retry = run; retry.requestID = UUID(); retry.nonce = Data(repeating: 77, count: 32)
        let cached = try await client.send(retry)
        XCTAssertTrue(cached.reused); XCTAssertEqual(cached.summary.state, .started)
        let id = try XCTUnwrap(cached.summary.evidenceExecutionID)
        let pending = try await client.send(f.status(client: client, executionID: id))
        XCTAssertEqual(pending.summary.state, .started); XCTAssertEqual(try f.rows("requests.jsonl"), 1)
    }
}
