import Foundation
import XCTest
@testable import RightClickCore

final class WindowsCOMTypeLibraryTests: XCTestCase {
    private let acquisition = "B891A751-6CCC-4EB6-AB6A-A37E136E7F55"
    private func compile(_ members: [[String: Any]], acquisition: String? = nil) throws -> WindowsCOMTypeLibrary {
        let entry: [String: Any] = ["acquisitionID": acquisition ?? self.acquisition, "moniker": "!unseen-native-provider",
            "declaration": ["format": 1, "interfaceGUID": "A28ACF9E-7B2B-43C9-80E5-E45396699455", "typeKind": 4, "typeFlags": 0,
                "major": 1, "minor": 0, "locale": 1033, "libraryGUID": "5F53A0CA-8C70-41CB-B79B-10860CD65DEA",
                "libraryMajor": 1, "libraryMinor": 0, "libraryLocale": 0, "librarySystem": 3, "libraryIndex": 0, "members": members]]
        return try XCTUnwrap(WindowsCOMTypeLibrary.compile(JSONSerialization.data(withJSONObject: [entry])).first)
    }
    private func member(_ id: Int = 41, type: Int = 20, result: Int = 8, flags: Int = 1) -> [String: Any] {
        ["id": id, "name": "Unseen_\(id)", "kind": 1, "functionKind": 4, "flags": 0, "optional": 0,
         "result": result, "resultFlags": 0, "scodes": 0, "parameters": [["name": "count", "type": type, "flags": flags]]]
    }
    func testExactInt64ContractAndBitsBeyondDoublePrecision() throws {
        let library = try compile([member()]), operation = try XCTUnwrap(library.operations.first)
        XCTAssertEqual(operation.effect, .execute)
        try operation.arguments.validate(.object(["count": .integer(9_007_199_254_740_993)]))
        XCTAssertThrowsError(try operation.arguments.validate(.object(["count": .number(9_007_199_254_740_992)])))
        let bytes = try XCTUnwrap(library.members["method:41"]).arguments(.object(["count": .integer(9_007_199_254_740_993)]))
        XCTAssertEqual(Array(bytes), [1, 0, 0, 0, 20, 0, 1, 0, 0, 0, 0, 0, 32, 0])
    }
    func testUnsupportedWidthsVariantsArraysAndByReferenceDoNotBroadenSchema() throws {
        let types = [3, 12, 0x2008, 0x4008]
        let library = try compile([member()] + types.enumerated().map { member(42 + $0.offset, type: $0.element) })
        XCTAssertEqual(library.operations.map(\.name), ["method:41"])
        XCTAssertEqual(library.omitted.count, 4)
    }
    func testOutOptionalAndUnknownFunctionFlagsAbstain() throws {
        var optional = member(42); optional["optional"] = 1
        var hidden = member(43); hidden["flags"] = 64
        let library = try compile([member(), member(44, flags: 2), optional, hidden])
        XCTAssertEqual(library.operations.map(\.name), ["method:41"])
    }
    func testDuplicateDISPIDDoesNotSelectSupportedFirstMatch() throws {
        let library = try compile([member(), member(41, type: 12)])
        XCTAssertTrue(library.operations.isEmpty); XCTAssertTrue(library.members.isEmpty)
    }
    func testAcquisitionIdentityAndNativeMetadataBindDigest() throws {
        let original = try compile([member()])
        XCTAssertNotEqual(original.digest, try compile([member()], acquisition: "B891A751-6CCC-4EB6-AB6A-A37E136E7F56").digest)
        XCTAssertNotEqual(original.digest, try compile([member(result: 20)]).digest)
        XCTAssertEqual(original.digest, try compile([member()]).digest)
    }
    func testBSTRUnicodeAndEmbeddedNULRemainExactAndMalformedResultRejects() throws {
        let member = try XCTUnwrap(compile([member(type: 8)]).members["method:41"])
        let text = "café\0世界", encoded = Data(text.utf8)
        var reply = Data([8, 0, UInt8(encoded.count), 0, 0, 0]); reply.append(encoded)
        guard case let .string(returned) = try member.resultValue(reply) else { return XCTFail("typed string absent") }
        XCTAssertEqual(Data(returned.utf8), encoded)
        XCTAssertThrowsError(try member.resultValue(reply + Data([0])))
        XCTAssertThrowsError(try member.resultValue(Data([8, 0, 1, 0, 0, 0, 255])))
    }
    func testBoolFiniteNumberAndUnitCompletionRemainDistinct() throws {
        let boolean = try XCTUnwrap(compile([member(result: 11)]).members["method:41"])
        guard case .boolean(false) = try boolean.resultValue(Data([11, 0, 0])) else { return XCTFail("false was lost") }
        XCTAssertThrowsError(try boolean.resultValue(Data([11, 0, 2])))
        let number = try XCTUnwrap(compile([member(result: 5)]).members["method:41"])
        XCTAssertThrowsError(try number.resultValue(Data([5, 0, 0, 0, 0, 0, 0, 0, 240, 127])))
        let unit = try compile([member(result: 24)])
        XCTAssertEqual(try unit.operations[0].result.canonicalData(), try CapabilitySchema.unit.canonicalData())
        let completion = try XCTUnwrap(unit.members["method:41"])
        guard case .null = try completion.resultValue(Data([0, 0])) else { return XCTFail("unit completion absent") }
        XCTAssertThrowsError(try completion.resultValue(Data([8, 0, 0, 0, 0, 0])))
    }
#if os(Windows)
    /// Actual native provider supplied by the CI infrastructure, not a metadata fixture.
    func testDefaultNativeResolversShareCurrentTokenAndRejectWithdrawal() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["RIGHTCLICK_NATIVE_COM_CONTROL_DIRECTORY"],
              let moniker = environment["RIGHTCLICK_NATIVE_COM_CONTROL_MONIKER"] else {
            throw XCTSkip("Real native COM provider was not supplied for this integration control")
        }
        let path = URL(fileURLWithPath: directory, isDirectory: true)
        let first = WindowsCOMCapabilityArtifactResolver()
        let library = try XCTUnwrap(first.catalog().first { $0.acquisition.moniker == moniker })
        let token = library.acquisition.acquisitionID
        let descriptor = CapabilityArtifactDescriptor(id: "native-live-control", kind: "windows.com",
            endpointURL: "windows-com://running/" + token)
        let second = WindowsCOMCapabilityArtifactResolver()
        XCTAssertEqual(try second.resolve(descriptor).id, "windows.com:" + token)
        let registry = CapabilityArtifactResolverRegistry()
        XCTAssertEqual(try registry.resolve(descriptor).id, "windows.com:" + token)
        let source = WindowsCOMRunningObjectSource()
        XCTAssertTrue(source.reflectors().contains { $0.id == "windows.com:" + token })
        XCTAssertThrowsError(try second.resolve(.init(id: "invented", kind: "windows.com",
            endpointURL: "windows-com://running/" + UUID().uuidString)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent("effect-count").path))
        try Data().write(to: path.appendingPathComponent("withdraw"))
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: path.appendingPathComponent("withdrawn").path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent("withdrawn").path))
        XCTAssertThrowsError(try first.resolve(descriptor))
        XCTAssertThrowsError(try second.resolve(descriptor))
        XCTAssertThrowsError(try registry.resolve(descriptor))
        XCTAssertFalse(source.reflectors().contains { $0.id == "windows.com:" + token })
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent("effect-count").path))
    }
#endif
#if !os(Windows)
    func testUnsupportedHostFabricatesNoNativeCapabilities() throws {
        XCTAssertTrue(WindowsCOMRunningObjectSource().reflectors().isEmpty)
        XCTAssertThrowsError(try WindowsCOMCapabilityArtifactResolver().resolve(.init(id: "native", kind: "windows.com", endpointURL: "windows-com://running/" + acquisition)))
    }
#endif
}
