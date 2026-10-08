#if canImport(GRPC)
import Foundation
import XCTest
@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders

/// Frozen host-boundary pressure tests. The injected unary transport records
/// actual dispatch entry; this is not a genuine remote gRPC acceptance proof.
final class RCIRUnaryAdmissionTests: XCTestCase {
    private let descriptor = "CgpkZW1vLnByb3RvEgRkZW1vIisKDEhlbGxvUmVxdWVzdBIMCgRuYW1lGAEgASgJEg0KBWNvdW50GAIgASgFIh0KCkhlbGxvUmVwbHkSDwoHbWVzc2FnZRgBIAEoCTJsCgdHcmVldGVyEjAKCFNheUhlbGxvEhIuZGVtby5IZWxsb1JlcXVlc3QaEC5kZW1vLkhlbGxvUmVwbHkSLwoFV2F0Y2gSEi5kZW1vLkhlbGxvUmVxdWVzdBoQLmRlbW8uSGVsbG9SZXBseTABYgZwcm90bzM="
    private func setup(_ host: RCIRExecutionHost, invoke: @escaping GRPCReflector.UnaryInvoker) throws -> (CapabilityEngine, Capability) {
        let reflector = try GRPCReflector(descriptorData: [Data(base64Encoded: descriptor)!],
            endpoint: GRPCEndpoint(scheme: "grpc", host: "localhost", port: 50051), invoker: invoke)
        let engine = CapabilityEngine(reflectors: [reflector], rcirHost: host)
        let action = try XCTUnwrap(engine.capabilities(for: "unary pressure").capabilities.first { $0.metadata["method"] == "SayHello" })
        return (engine, action)
    }
    func testCurrentHostPolicyDenialStopsLegacyUnaryTransport() throws {
        let host = RCIRExecutionHost(); var starts = 0
        let (engine, action) = try setup(host) { _, _, _ in starts += 1; return Data([0x42, 0x02, 0x6f, 0x6b]) }
        host.configuration = { RCIRHostConfiguration(deniedCapabilities: [action.id]) }
        let result = try engine.begin(id: action.id, item: "unary pressure", confirmed: true, arguments: ["name": "hello"])
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(result.state, .rejected)
    }
    func testAcceptedLegacyUnaryConsumesOneLeaseAndRetainsUnverifiedReceipt() throws {
        let host = RCIRExecutionHost(); var starts = 0
        let (engine, action) = try setup(host) { _, _, _ in starts += 1; return Data([0x42, 0x02, 0x6f, 0x6b]) }
        let result = try engine.begin(id: action.id, item: "unary pressure", confirmed: true, arguments: ["name": "hello"])
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(result.state, .accepted)
        XCTAssertEqual(result.rcir?.leaseConsumed, true)
        XCTAssertEqual(result.rcir?.outcome, "unverified")
        XCTAssertNotNil(result.rcir?.receipt)
    }
    func testChangedArgumentsAtAdmissionStopLegacyUnaryTransport() throws {
        let host = RCIRExecutionHost(); var starts = 0
        host.consumptionArguments = { _ in .object(["name": .string("different")]) }
        let (engine, action) = try setup(host) { _, _, _ in starts += 1; return Data([0x42, 0x02, 0x6f, 0x6b]) }
        let result = try engine.begin(id: action.id, item: "unary pressure", confirmed: true, arguments: ["name": "hello"])
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(result.state, .rejected)
    }
    func testLostUnaryResponsePreservesUnknownWithoutReplay() throws {
        let host = RCIRExecutionHost(); var starts = 0
        let (engine, action) = try setup(host) { _, _, _ in starts += 1; throw RightClickError("Lost response after invocation start") }
        let result = try engine.begin(id: action.id, item: "unary pressure", confirmed: true, arguments: ["name": "hello"])
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.rcir?.outcome, "unknown")
        XCTAssertNotNil(result.rcir?.receipt)
        _ = engine.executionStatus(result.executionId)
        XCTAssertEqual(starts, 1)
    }
}
#endif
