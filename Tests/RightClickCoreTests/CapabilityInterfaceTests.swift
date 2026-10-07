import Foundation
import XCTest
@testable import RightClickCore

final class CapabilityInterfaceTests: XCTestCase {
    func testImporterRejectsUnsupportedConstraintsAndOpenObjects() throws {
        XCTAssertThrowsError(try CapabilityJSON.schema(["type": "string", "pattern": "^safe$"]))
        XCTAssertThrowsError(try CapabilityJSON.schema(["type": "object", "properties": [:]]))
        XCTAssertThrowsError(try CapabilityJSON.schema(["type": "array", "items": ["type": "string"], "minItems": 1]))
        XCTAssertThrowsError(try CapabilityJSON.schema(["type": "object", "properties": [:], "required": ["unknown"], "additionalProperties": false]))
    }
    func testImporterPreservesTypedResultAndDoesNotCoerceLegacyStrings() throws {
        let schema = try CapabilityJSON.schema(["type": "object", "properties": ["count": ["type": "integer"]],
                                                "required": ["count"], "additionalProperties": false])
        try schema.validate(.object(["count": .integer(7)]))
        XCTAssertThrowsError(try schema.validate(.object(["count": .string("7")])))
        try CapabilitySchema.boolean.validate(CapabilityJSON.value(true))
        try CapabilitySchema.integer.validate(CapabilityJSON.value(Int64(7)))
    }
    private func reflector(invocations: UnsafeMutablePointer<Int>) throws -> CapabilityInterfaceReflector {
        try .init(id: "interface:controlled", provider: "controlled", target: URL(string: "http://127.0.0.1:19143/mcp")!,
            substrate: "test", descriptorDigest: String(repeating: "a", count: 64),
            operations: [.init(name: "challenge", title: "Controlled challenge",
                arguments: .object(properties: ["challenge": .string], required: ["challenge"]),
                result: .string, declaration: .object(["name": .string("challenge")]))],
            available: { true }, invoke: { _, input, admit in
                try admit { invocations.pointee += 1 }
                guard case let .object(values) = input, let value = values["challenge"] else { throw RCIRError.invalidContract }
                return value
            })
    }
    func testSharedHostPreservesAcceptedVersusVerifiedAndExactPolicyDenial() throws {
        let calls = UnsafeMutablePointer<Int>.allocate(capacity: 1); calls.initialize(to: 0)
        defer { calls.deinitialize(count: 1); calls.deallocate() }
        let reflector = try reflector(invocations: calls)
        let item = try ContentParser.parse("controlled")
        let capability = try reflector.capabilities(for: item)[0]
        let host = RCIRExecutionHost()
        let accepted = try reflector.admittedBegin(capability: capability, admissionOwner: capability, item: item,
            executionID: "accepted", arguments: ["challenge": "unique"], verification: nil, expectedOutput: nil,
            host: host, revalidate: { true })
        XCTAssertEqual(accepted.state, .accepted); XCTAssertFalse(accepted.evidence.outcomeVerified)
        XCTAssertEqual(accepted.rcir?.phase, "completed"); XCTAssertEqual(accepted.rcir?.outcome, "unverified")
        let verified = try reflector.admittedBegin(capability: capability, admissionOwner: capability, item: item,
            executionID: "verified", arguments: ["challenge": "unique"], verification: nil, expectedOutput: "unique",
            host: host, revalidate: { true })
        XCTAssertEqual(verified.state, .succeeded); XCTAssertTrue(verified.evidence.outcomeVerified)
        XCTAssertEqual(verified.rcir?.outcome, "succeeded"); XCTAssertEqual(calls.pointee, 2)
        host.configuration = { RCIRHostConfiguration(deniedCapabilities: [capability.id]) }
        let denied = try reflector.admittedBegin(capability: capability, admissionOwner: capability, item: item,
            executionID: "denied", arguments: ["challenge": "unique"], verification: nil, expectedOutput: nil,
            host: host, revalidate: { true })
        XCTAssertEqual(denied.state, .rejected); XCTAssertEqual(calls.pointee, 2)
    }
    func testCompilerSelectedObserverReachesDefaultSharedHostAndCannotIgnoreCallerConstraint() throws {
        struct IndependentObserver: RCIRObserver {
            let observerID = "host:separate-observer"
            func observe(_ request: RCIRObservationRequest) throws -> CapabilityValue { .string("independently-read") }
        }
        var calls = 0
        let reflector = try CapabilityInterfaceReflector(id: "interface:observed", provider: "controlled",
            target: URL(string: "http://127.0.0.1:19143/mcp")!, substrate: "test", descriptorDigest: "acquired",
            operations: [.init(name: "challenge", title: "Observed challenge", arguments: .object(properties: [:], required: []),
                result: .string, declaration: .string("acquired"))],
            observerFactory: { operation in
                guard operation == "challenge" else { return nil }
                return { _ in .init(contract: .init(observerID: "host:separate-observer", schema: .string, expected: .string("independently-read")),
                    observer: IndependentObserver(), boundary: "Separate read-only identity") }
            }, available: { true }, invoke: { _, _, admit in try admit { calls += 1 }; return .string("provider-claimed") })
        let item = try ContentParser.parse("controlled")
        let capability = try reflector.capabilities(for: item)[0]
        // Ordinary begin creates its normal host without a special registry.
        let result = try reflector.begin(capability: capability, item: item, executionID: "compiler-composed")
        XCTAssertEqual(result.state, .succeeded); XCTAssertEqual(result.rcir?.outcome, "succeeded")
        XCTAssertEqual(result.evidence.boundary, "Separate read-only identity")
        let denied = try reflector.admittedBegin(capability: capability, admissionOwner: capability, item: item,
            executionID: "ambiguous", arguments: nil, verification: nil, expectedOutput: "provider-claimed",
            host: RCIRExecutionHost(), revalidate: { true })
        XCTAssertEqual(denied.state, .rejected); XCTAssertEqual(calls, 1)
    }
    func testPreflightReturnCannotClaimConsumedLeaseOrSemanticSuccess() throws {
        let item = try ContentParser.parse("preflight")
        let capability = Capability(id: "preflight", title: "Preflight", source: .system, reflectorID: "interface:preflight",
            provider: CapabilityProvider(name: "controlled"), inputs: ["text"], output: ["text"], safety: .unknown,
            invocation: .direct, supportLevel: .publicSupported, requiresConfirmation: true)
        let abi = try capability.abiContract(arguments: .string, result: .string)
        let scope = RCIRScope("preflight-exact-resource", .execute)
        for returned: ExecutionState in [.failed, .accepted, .succeeded] {
            let host = RCIRExecutionHost()
            var resultReads = 0
            let record = try host.execute(abi: abi, discovery: abi, arguments: .string("input"), scope: scope,
                capability: capability, executionID: returned.rawValue, argumentStrings: nil, item: item,
                verification: nil, expectedOutput: "claimed", target: URL(string: "http://127.0.0.1:19143")!,
                authority: { [scope] }, revalidate: { true }, dispatch: { _, _ in
                    .init(executionId: returned.rawValue, actionId: capability.id, state: returned, message: "preflight compiler return", output: "claimed", evidence: .init(type: "input_contract_failure", boundary: "Specific compiler failure"))
                }, resultValue: { _ in resultReads += 1; return .string("claimed") })
            XCTAssertEqual(record.rcir?.leaseConsumed, false)
            XCTAssertEqual(record.rcir?.outcome, "unverified")
            XCTAssertFalse(record.evidence.outcomeVerified)
            XCTAssertFalse(record.events.contains { $0.contains("RCIR consumed lease=") })
            XCTAssertEqual(record.state, returned == .failed ? .failed : .unknown)
            XCTAssertEqual(resultReads, 0)
            if returned == .failed {
                XCTAssertEqual(record.evidence.type, "input_contract_failure")
                XCTAssertEqual(record.message, "preflight compiler return")
                XCTAssertTrue(record.evidence.boundary.hasPrefix("Specific compiler failure"))
            }
        }
    }
    func testBoundedExecutorAbstainsForOfflineTool() throws {
        XCTAssertThrowsError(try BoundedCapabilityProcess.run(executable: URL(fileURLWithPath: "/nonexistent/rightclick-runtime"), arguments: []))
    }
    func testBoundedExecutorRejectsInvalidLimitsAndEnforcesMonotonicDeadline() throws {
#if os(Windows)
        let executable = try NativeHTTPFixture.python()
        let wait = ["-c", "import time; time.sleep(2)"]
#else
        let executable = URL(fileURLWithPath: "/bin/sleep")
        let wait = ["2"]
#endif
        XCTAssertThrowsError(try BoundedCapabilityProcess.run(executable: executable, arguments: ["1"], maximumBytes: -1))
        XCTAssertThrowsError(try BoundedCapabilityProcess.run(executable: executable, arguments: ["1"], timeout: .nan))
        let before = DispatchTime.now().uptimeNanoseconds
        XCTAssertThrowsError(try BoundedCapabilityProcess.run(executable: executable, arguments: wait, timeout: 0.05))
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - before, 1_000_000_000)
    }
    func testBoundedExecutorUsesBoundedStdinWithoutShellInterpolation() throws {
        let input = Data("RIGHTCLICK:{\"challenge\":\"literal $(echo never-execute)\"}\n".utf8)
#if os(Windows)
        let executable = try NativeHTTPFixture.python()
        let echo = ["-c", "import sys; sys.stdout.buffer.write(sys.stdin.buffer.read())"]
        let noReadExecutable = executable
        let noRead = ["-c", "pass"]
#else
        let executable = URL(fileURLWithPath: "/bin/cat")
        let echo: [String] = []
        let noReadExecutable = URL(fileURLWithPath: "/usr/bin/true")
        let noRead: [String] = []
#endif
        XCTAssertEqual(try BoundedCapabilityProcess.run(executable: executable, arguments: echo, input: input), input)
        XCTAssertThrowsError(try BoundedCapabilityProcess.run(executable: executable, arguments: echo, input: Data(repeating: 0, count: 1_048_577)))
        // A child may exit without consuming stdin; this must neither signal the
        // RIGHTCLICK process nor strand a blocked writer indefinitely.
        XCTAssertEqual(try BoundedCapabilityProcess.run(executable: noReadExecutable, arguments: noRead, input: Data(repeating: 1, count: 1_048_576)), Data())
    }
    func testProtectedReferenceRejectsReadableAndSymlinkedCredentialFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(directory)
        defer { try? NativeHTTPFixture.remove(directory) }
        let actual = directory.appendingPathComponent("actual")
        try NativeHTTPFixture.createPrivateDirectory(actual)
        let secret = actual.appendingPathComponent("credential")
        try NativeHTTPFixture.writePrivate(Data("private-reference".utf8), to: secret)
        XCTAssertEqual(try CapabilityProtectedReference.read(secret.path), Data("private-reference".utf8))
        let link = directory.appendingPathComponent("link")
#if os(Windows)
        try NativeHTTPFixture.junction(link, target: actual)
        defer { try? FileManager.default.removeItem(at: link) }
        XCTAssertThrowsError(try CapabilityProtectedReference.read(link.appendingPathComponent("credential").path))
        try NativeHTTPFixture.nativeCommand("icacls.exe", [secret.path, "/grant", "*S-1-1-0:(R)"])
        XCTAssertThrowsError(try CapabilityProtectedReference.read(secret.path))
        // Restore only this synthetic fixture's ACL for bounded cleanup.
        try NativeHTTPFixture.protect(secret)
#else
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        XCTAssertThrowsError(try CapabilityProtectedReference.read(link.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: secret.path)
        XCTAssertThrowsError(try CapabilityProtectedReference.read(secret.path))
#endif
    }
    func testPrivateSnapshotDoesNotFollowSourceReplacementAndWithdrawsStaleIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        try Data("acquired bytes".utf8).write(to: source)
        let snapshot = try CapabilityArtifactSnapshot(source: source, maximum: 100)
        XCTAssertTrue(snapshot.sourceStillMatches())
        try Data("replacement bytes".utf8).write(to: source, options: .atomic)
        XCTAssertFalse(snapshot.sourceStillMatches())
        XCTAssertEqual(try CapabilityArtifactSnapshot.read(source: snapshot.file, maximum: 100), Data("acquired bytes".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: snapshot.file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o400)
        XCTAssertThrowsError(try CapabilityArtifactSnapshot(source: source, maximum: 2))
    }
    func testWASMSourceReplacementCannotExecuteNewBytesUnderOldCapability() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["RIGHTCLICK_TEST_WASM_COMPONENT"],
              environment["RIGHTCLICK_WASM_TOOLS"] != nil, environment["RIGHTCLICK_WASM_RUNTIME"] != nil else {
            throw XCTSkip("Real component not provisioned; no source-race GREEN claimed by this skip.")
        }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wasm")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let reflector = try WASMCapabilityArtifactResolver(environment: environment)
            .resolve(.init(id: "replaced", kind: "wasm", specificationURL: source.absoluteString))
        let item = try ContentParser.parse("proof")
        let capability = try reflector.capabilities(for: item)[0]
        try Data("malformed replacement".utf8).write(to: source, options: .atomic)
        XCTAssertEqual(try reflector.capabilities(for: item).count, 0)
        XCTAssertThrowsError(try reflector.begin(capability: capability, item: item, executionID: "stale", arguments: ["challenge": "proof"]))
    }
    func testTypedBridgeRejectsOutOfRangeIntegersAndDeepValues() throws {
        XCTAssertThrowsError(try CapabilityJSON.value(NSNumber(value: UInt64.max)))
        var raw: Any = "leaf"
        for _ in 0..<34 { raw = [raw] }
        XCTAssertThrowsError(try CapabilityJSON.value(raw))
    }
    func testDuplicateInterfaceNamesFailClosed() throws {
        let operation = CapabilityInterfaceOperation(name: "duplicate", title: "duplicate",
            arguments: .object(properties: [:], required: []), result: .string, declaration: .null)
        XCTAssertThrowsError(try CapabilityInterfaceReflector(id: "duplicate", provider: "controlled",
            target: URL(string: "http://127.0.0.1:19143/mcp")!, substrate: "test", descriptorDigest: "proof",
            operations: [operation, operation], available: { true }, invoke: { _, _, _ in .null }))
    }
    func testRealWASMComponentWhenProvisioned() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["RIGHTCLICK_TEST_WASM_COMPONENT"],
              environment["RIGHTCLICK_WASM_TOOLS"] != nil, environment["RIGHTCLICK_WASM_RUNTIME"] != nil else {
            throw XCTSkip("Real component toolchain not provisioned; no WASM GREEN claimed by this skip.")
        }
        let resolver = WASMCapabilityArtifactResolver(environment: environment)
        let reflector = try resolver.resolve(.init(id: "real", kind: "wasm", specificationURL: URL(fileURLWithPath: path).absoluteString))
        let item = try ContentParser.parse("RIGHTCLICK:independent")
        let capability = try reflector.capabilities(for: item)[0]
        var expected: UInt32 = 2166136261
        for byte in "RIGHTCLICK:independent".utf8 { expected = (expected ^ UInt32(byte)) &* 16777619 }
        let host = RCIRExecutionHost()
        let result = try (reflector as! RCIRExecutionReflector).admittedBegin(capability: capability,
            admissionOwner: capability, item: item, executionID: "real", arguments: ["challenge": "RIGHTCLICK:independent"],
            verification: nil, expectedOutput: String(expected), host: host, revalidate: { true })
        XCTAssertEqual(result.output, String(expected)); XCTAssertEqual(result.state, .succeeded)
        XCTAssertEqual(result.rcir?.outcome, "succeeded")
        XCTAssertEqual(capability.metadata["hostImports"], "none")
        XCTAssertNotNil(capability.metadata["componentSHA256"])
    }
}
