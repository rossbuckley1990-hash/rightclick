import Foundation
import XCTest
@testable import RightClickCore

final class WITComponentContractTests: XCTestCase {
    private func document(parameters: [[String: Any]] = [], result: Any? = "u32", types: [[String: Any]] = []) throws -> Data {
        var function: [String: Any] = ["name": "typed", "kind": "freestanding", "params": parameters]
        if let result { function["result"] = result }
        return try JSONSerialization.data(withJSONObject: ["worlds": [["name": "root", "imports": [:],
            "exports": ["typed": ["function": function]]]], "interfaces": [], "types": types, "packages": []])
    }
    private func operation(parameters: [[String: Any]] = [], result: Any? = "u32", types: [[String: Any]] = []) throws -> WITComponentOperation {
        let compiled = try WITComponentContract.operations(document(parameters: parameters, result: result, types: types))
        return try XCTUnwrap(compiled.first)
    }

    func testExactWITIntegerWidthsRejectUnrepresentableDeclarationsAndWrongValues() throws {
        let domains: [(String, Int64, Int64)] = [("s8", -128, 127), ("s16", -32768, 32767),
            ("s32", -2147483648, 2147483647), ("s64", .min, .max),
            ("u8", 0, 255), ("u16", 0, 65535), ("u32", 0, 4294967295)]
        for (name, minimum, maximum) in domains {
            let op = try operation(parameters: [["name": "value", "type": name]], result: name)
            for value in [minimum, maximum] {
                XCTAssertEqual(try op.invocation(.object(["value": .integer(value)])), "typed(\(value))")
                XCTAssertEqual(try op.returned(Data(String(value).utf8)).canonicalData(), try CapabilityValue.integer(value).canonicalData())
            }
            if minimum != .min {
                XCTAssertThrowsError(try op.invocation(.object(["value": .integer(minimum - 1)])))
                XCTAssertThrowsError(try op.returned(Data(String(minimum - 1).utf8)))
            }
            if maximum != .max {
                XCTAssertThrowsError(try op.invocation(.object(["value": .integer(maximum + 1)])))
                XCTAssertThrowsError(try op.returned(Data(String(maximum + 1).utf8)))
            }
            XCTAssertThrowsError(try op.invocation(.object(["value": .string("1")])))
            XCTAssertThrowsError(try op.invocation(.object(["value": .boolean(true)])))
        }
        for name in ["u64", "f32", "f64", "char", "future", "stream", "unknown"] {
            XCTAssertThrowsError(try operation(parameters: [["name": "value", "type": name]]), name)
            XCTAssertThrowsError(try operation(result: name), name)
        }
    }

    func testTypedRecordsListsAndBooleanDoNotCoerceOrDiscardFields() throws {
        let fields: [[String: Any]] = [["name": "enabled", "type": "bool"], ["name": "values", "type": 1]]
        let types: [[String: Any]] = [["name": "request", "kind": ["record": ["fields": fields]]], ["name": "octets", "kind": ["list": "u8"]]]
        let op = try operation(parameters: [["name": "request", "type": 0]], result: 0, types: types)
        let value = CapabilityValue.object(["enabled": .boolean(true), "values": .array([.integer(0), .integer(255)])])
        XCTAssertEqual(try op.invocation(.object(["request": value])), "typed({%enabled:true,%values:[0,255]})")
        XCTAssertEqual(try op.returned(Data("{%values: [0,255,], enabled: true,}".utf8)).canonicalData(), try value.canonicalData())
        for text in ["{enabled: 1, values: [0]}", "{enabled: true, values: [256]}", "{enabled: true}",
                     "{enabled: true, values: [], extra: 1}", "{enabled: true, enabled: false, values: []}",
                     "{enabled: true, values: []} true", "{enabled: true, values: [0"] {
            XCTAssertThrowsError(try op.returned(Data(text.utf8)), text)
        }
    }

    func testWAVEStringEscapesPreserveExactUTF8IncludingNulAndUnicode() throws {
        let op = try operation(parameters: [["name": "text", "type": "string"]], result: "string")
        let string = "quotes\" and slash\\\n\r\t\u{0}\u{7f}☃👋e\u{301}"
        let encoded = try WITValueType.string.wave(.string(string))
        XCTAssertTrue(encoded.contains("\\u{0}")); XCTAssertTrue(encoded.contains("\\u{7f}"))
        XCTAssertEqual(try op.invocation(.object(["text": .string(string)])), "typed(" + encoded + ")")
        XCTAssertEqual(try op.returned(Data(encoded.utf8)).canonicalData(), try CapabilityValue.string(string).canonicalData())
        for bad in ["\"\\u0000\"", "\"\\u{d800}\"", "\"\\u{110000}\"", "\"\\x\"", "\"unfinished", "\"first\" \"second\"", "\"raw\u{0}\""] {
            XCTAssertThrowsError(try op.returned(Data(bad.utf8)), bad)
        }
        XCTAssertThrowsError(try op.returned(Data([34, 0xff, 34])))
    }

    func testDeclaredUnitRequiresExactUnitWriterFormAndCannotBecomeNullResult() throws {
        let op = try operation(result: nil)
        XCTAssertEqual(try op.invocation(.object([:])), "typed()")
        XCTAssertEqual(try op.returned(Data("()\n".utf8)).canonicalData(), try CapabilityValue.null.canonicalData())
        XCTAssertEqual(try op.interface.result.canonicalData(), try CapabilitySchema.unit.canonicalData())
        for raw in ["", "null", "0", "false", "() false"] { XCTAssertThrowsError(try op.returned(Data(raw.utf8))) }
    }

    func testCyclesUnknownKindsOutOfRangeReferencesAndAmbiguousFieldsFailClosed() throws {
        for types: [[String: Any]] in [[ ["kind": ["type": 0]] ],
                                     [ ["kind": ["list": 1]], ["kind": ["list": 0]] ],
                                     [ ["kind": ["resource": [:]]] ],
                                     [ ["kind": ["variant": [:]]] ],
                                     [ ["kind": ["record": ["fields": [["name": "same", "type": "string"], ["name": "same", "type": "string"]]]]] ]] {
            XCTAssertThrowsError(try operation(parameters: [["name": "arg", "type": 0]], types: types))
        }
        for reference: Any in [-1, 99, true, 0.5] {
            XCTAssertThrowsError(try operation(parameters: [["name": "arg", "type": reference]], types: [["kind": ["list": "u8"]]]))
        }
        XCTAssertThrowsError(try operation(parameters: [["name": "same", "type": "string"], ["name": "same", "type": "bool"]]))
    }

    func testDepthAndExpandedDAGRemainBoundedBeforeBuildingSchemas() throws {
        var types: [[String: Any]] = [["kind": ["list": "u8"]]]
        for index in 1..<34 { types.append(["kind": ["list": index - 1]]) }
        XCTAssertThrowsError(try operation(parameters: [["name": "arg", "type": 33]], types: types))
        var dag: [[String: Any]] = [["kind": ["list": "u8"]]]
        for index in 1..<16 {
            dag.append(["kind": ["record": ["fields": [["name": "left", "type": index - 1], ["name": "right", "type": index - 1]]]]])
        }
        XCTAssertThrowsError(try operation(parameters: [["name": "arg", "type": 15]], types: dag))
        let list = try operation(result: 0, types: [["kind": ["list": "u8"]]])
        XCTAssertThrowsError(try list.returned(Data(("[" + Array(repeating: "0", count: 4096).joined(separator: ",") + "]").utf8)))
    }

    func testImportsAsyncAndMalformedComponentShapeAbstain() throws {
        let baseline = try document(parameters: [["name": "text", "type": "string"]])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: baseline) as? [String: Any])
        var worlds = try XCTUnwrap(object["worlds"] as? [[String: Any]])
        worlds[0]["imports"] = ["ambient-filesystem": ["interface": ["id": 0]]]
        object["worlds"] = worlds
        XCTAssertThrowsError(try WITComponentContract.operations(JSONSerialization.data(withJSONObject: object)))
        worlds[0]["imports"] = [:]
        worlds[0]["exports"] = ["typed": ["function": ["name": "typed", "kind": "async-freestanding", "params": []]]]
        object["worlds"] = worlds
        XCTAssertThrowsError(try WITComponentContract.operations(JSONSerialization.data(withJSONObject: object)))
    }

    func testQualifiedInterfaceVersionAndResolvedTypeCommitmentsAreExact() throws {
        let function: [String: Any] = ["name": "typed", "kind": "freestanding",
            "params": [["name": "value", "type": 0]], "result": "u32"]
        let type: [String: Any] = ["name": "small", "kind": ["type": "s16"], "owner": ["interface": 0]]
        let document: [String: Any] = ["worlds": [["name": "root", "imports": [:],
            "exports": ["interface-0": ["interface": ["id": 0]]]]],
            "interfaces": [["name": "api", "package": 0, "types": ["small": 0], "functions": ["typed": function]]],
            "types": [type], "packages": [["name": "proof:typed@0.1.0"]]]
        let op = try XCTUnwrap(WITComponentContract.operations(JSONSerialization.data(withJSONObject: document)).first)
        XCTAssertEqual(op.name, "proof:typed/api.typed@0.1.0")
        XCTAssertEqual(try op.invocation(.object(["value": .integer(-32768)])), "proof:typed/api.typed@0.1.0(-32768)")
        XCTAssertThrowsError(try op.invocation(.object(["value": .integer(-32769)])))
        let declaration = String(decoding: try op.declaration.wireData(), as: UTF8.self)
        XCTAssertTrue(declaration.contains("s16")); XCTAssertTrue(declaration.contains("proof:typed/api.typed@0.1.0"))
    }

    func testActualTypedComponentWhenProvisioned() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["RIGHTCLICK_TEST_WIT_TYPED_COMPONENT"], environment["RIGHTCLICK_WASM_TOOLS"] != nil,
              environment["RIGHTCLICK_WASM_RUNTIME"] != nil else {
            throw XCTSkip("Actual typed component absent; this skip establishes no typed-WIT GREEN.")
        }
        let reflector = try WASMCapabilityArtifactResolver(environment: environment)
            .resolve(.init(id: "typed", kind: "wasm", specificationURL: URL(fileURLWithPath: path).absoluteString))
        let item = try ContentParser.parse("typed component"), actions = try reflector.capabilities(for: item)
        XCTAssertEqual(actions.count, 3)
        let record = try XCTUnwrap(actions.first { $0.id.hasSuffix("proof:typed/api.challenge-record") })
        let request = CapabilityValue.object(["enabled": .boolean(true), "offset": .integer(-7), "challenge": .string("RIGHTCLICK:typed")])
        let output = try reflector.begin(capability: record, item: item, executionID: UUID().uuidString,
            arguments: ["request": String(decoding: try request.wireData(), as: UTF8.self)])
        XCTAssertEqual(output.state, .accepted)
        XCTAssertEqual(output.output, "{\"enabled\":true,\"fingerprint\":3680472194}")
        let unit = try XCTUnwrap(actions.first { $0.id.hasSuffix("proof:typed/api.finish") })
        let finish = try reflector.begin(capability: unit, item: item, executionID: UUID().uuidString, arguments: [:])
        XCTAssertEqual(finish.state, .accepted); XCTAssertNil(finish.output)
        XCTAssertEqual(finish.rcir?.phase, "completed"); XCTAssertEqual(finish.rcir?.outcome, "unverified")
        let invalid = CapabilityValue.object(["enabled": .boolean(true), "offset": .integer(2147483648), "challenge": .string("pressure")])
        XCTAssertThrowsError(try reflector.begin(capability: record, item: item, executionID: UUID().uuidString,
            arguments: ["request": String(decoding: try invalid.wireData(), as: UTF8.self)]))
    }
}
