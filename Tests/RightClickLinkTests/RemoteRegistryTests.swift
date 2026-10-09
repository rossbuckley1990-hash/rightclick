import Foundation
import XCTest
import RightClickCore
@testable import RightClickLink
@testable import RightClickMCP

private actor HeldCatalogTransport: RemoteLinkTransport {
    let relay: SimulatedLinkRelay
    var held = false
    var continuation: CheckedContinuation<Void, Never>?
    init(_ relay: SimulatedLinkRelay) { self.relay = relay }
    func exchange(_ bytes: Data, targetRuntimeID: String) async throws -> Data {
        let envelope = try RemoteWire.decode(SignedRemoteMessage.self, bytes, maximum: RemoteWire.maximumWireBytes)
        let request = try RemoteWire.decode(RemoteExecutionRequest.self, envelope.payload)
        let response = try await relay.exchange(bytes, targetRuntimeID: targetRuntimeID)
        if request.operation == .actions {
            held = true
            await withCheckedContinuation { continuation = $0 }
        }
        return response
    }
    func isHeld() -> Bool { held }
    func release() { continuation?.resume(); continuation = nil }
}

final class RemoteRegistryTests: XCTestCase {
    @MainActor func testRemovalCancelsInFlightEnrollmentWithoutResurrectingRoutes() async throws {
        let f = try LinkFixture(); try await f.connect()
        let transport = HeldCatalogTransport(f.relay)
        let client = try RemoteLinkClient(identity: f.caller, trustedRuntimeKey: f.identity.publicKey, transport: transport, now: { 1_000 })
        let registry = RemoteRuntimeRegistry(now: { 1_000 })
        let enrollment = Task { try await registry.enroll(client, item: "desired") }
        for _ in 0..<200 {
            if await transport.isHeld() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let held = await transport.isHeld(); XCTAssertTrue(held)
        registry.remove(runtimeID: client.target.runtimeID)
        await transport.release()
        do { try await enrollment.value; XCTFail("Removed runtime was resurrected") }
        catch { XCTAssertEqual(error as? RemoteLinkError, .unauthorized) }
        XCTAssertTrue(registry.registrations().isEmpty)
        XCTAssertTrue(RemoteCapabilitySource(registry: registry).reflectors().isEmpty)
        XCTAssertEqual(f.provider.effects, 0)
    }
    @MainActor func testSharedEngineSerializesLocalMCPAndLinkAdmission() async throws {
        let f = try LinkFixture(); try await f.connect(); let box = EngineBox(f.engine)
        f.provider.entryDelay = 0.003
        let requests = try (0..<12).map { _ in try f.request() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for request in requests {
                group.addTask { _ = try await f.client.send(request) }
                group.addTask {
                    _ = try handleTool("context_actions", arguments: ["item": .string("desired")], engine: box, transport: "stdio")
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(f.provider.effects, 12)
        XCTAssertEqual(f.provider.observations, 12)
        XCTAssertEqual(f.provider.overlappingEntries, 0, "Local MCP discovery raced Link admission/invocation on the same reflector")
    }
}
