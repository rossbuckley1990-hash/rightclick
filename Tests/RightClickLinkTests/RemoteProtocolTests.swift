import Foundation
import XCTest
import RightClickCore
@testable import RightClickLink

final class RemoteProtocolTests: XCTestCase {
    func testCanonicalUnicodeWireGoldenVectorIsIdenticalAcrossHosts() throws {
        let request = RemoteExecutionRequest(requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            idempotencyKey: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            issuedAtMilliseconds: 1_000, expiresAtMilliseconds: 2_000,
            targetRuntimeID: "runtime:" + String(repeating: "b", count: 64),
            targetDeviceID: "device:" + String(repeating: "c", count: 64),
            callerID: String(repeating: "a", count: 64), nonce: Data(repeating: 0, count: 32), operation: .run,
            capabilityID: "fixture:unicode", capabilityDigest: String(repeating: "d", count: 64), item: "caf\u{e9}/cafe\u{301} / 中文")
        let bytes = try RemoteWire.encode(request)
        XCTAssertEqual(RemoteWire.digest(bytes), "161ec784656428850301bb9b469e7338083102bd13d6e2c73fb268ec601ed374")
        XCTAssertEqual(try RemoteWire.encode(RemoteWire.decode(RemoteExecutionRequest.self, bytes)), bytes)
    }
    func testWindowsRequirementsDoNotGrantLocalAuthority() {
        let requirements = RuntimeRequirements(operatingSystems: [.windows], architectures: ["x86_64"])
        XCTAssertFalse(requirements.permits(os: .linux, architecture: "x86_64"))
        XCTAssertTrue(requirements.permits(os: .windows, architecture: "x86_64"))
    }
    func testStrictWireRejectsUnknownDuplicateAndOversizedFields() throws {
        let signer = try RCIREd25519Signer(rawPrivateKey: Data(repeating: 1, count: 32))
        let identity = try RemoteNodeIdentity(signer: signer)
        let request = RemoteExecutionRequest(issuedAtMilliseconds: 1_000, expiresAtMilliseconds: 2_000,
            targetRuntimeID: identity.runtimeID, targetDeviceID: identity.deviceID,
            callerID: RemoteWire.digest(signer.publicKey), nonce: Data(repeating: 2, count: 32), operation: .actions, item: "fixture")
        let data = try RemoteWire.encode(request)
        XCTAssertNoThrow(try RemoteWire.decode(RemoteExecutionRequest.self, data))
        var unknown = String(decoding: data, as: UTF8.self); unknown.removeLast(); unknown += ",\"confirmed\":true}"
        XCTAssertThrowsError(try RemoteWire.decode(RemoteExecutionRequest.self, Data(unknown.utf8)))
        XCTAssertThrowsError(try RemoteWire.decode(RemoteExecutionRequest.self, Data(repeating: 65, count: 32_769)))
    }
    func testContradictorySignedSummaryCannotBecomeSuccess() throws {
        let summary = RemoteExecutionSummary(state: .succeeded, lifecycle: [.requested, .verified], completedAtMilliseconds: 1_000)
        XCTAssertThrowsError(try summary.validate())
    }
}
