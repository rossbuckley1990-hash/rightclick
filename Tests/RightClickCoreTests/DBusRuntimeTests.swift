import Foundation
import XCTest
@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders

#if os(macOS) || canImport(FoundationXML)
final class DBusRuntimeTests: XCTestCase {
    private let xml = """
    <node><interface name="org.example.Typed">
    <method name="Store"><arg name="enabled" type="b"/><arg name="invocation" type="s"/><arg type="s" direction="out"/></method>
    <method name="Tags"><arg name="values" type="as"/><arg type="as" direction="out"/></method>
    <method name="Void"/>
    <method name="Numeric"><arg type="u"/></method>
    <method name="Variant"><arg type="v"/></method>
    </interface></node>
    """
    private final class Transport: DBusTransport {
        var xml: String
        var owner = ":1.7"
        var busID = String(repeating: "a", count: 32)
        var present = true
        var effects = 0
        var lastTokens: [String] = []
        var provenance: [String: String] { ["testTransport": "unit control, not native proof"] }
        init(_ xml: String) { self.xml = xml }
        func available() -> Bool { true }
        func call(destination: String, path: String, interface: String, member: String, signature: String,
                  tokens: [String], replySignature: String, admitStart: ((_ start: () -> Void) throws -> Void)?) throws -> [CapabilityValue] {
            switch member {
            case "GetNameOwner": guard present else { throw RCIRError.unavailable }; return [.string(owner)]
            case "GetConnectionUnixUser": return [.integer(1102)]
            case "GetId": return [.string(busID)]
            case "Introspect": guard present, destination == owner else { throw RCIRError.unavailable }; return [.string(xml)]
            case "Store":
                guard destination == owner else { throw RCIRError.staleBinding }
                try admitStart? { self.effects += 1 }; lastTokens = tokens; return [.string("accepted")]
            case "Void": try admitStart? { self.effects += 1 }; return []
            default: throw RCIRError.unavailable
            }
        }
    }
    private func descriptor() -> CapabilityArtifactDescriptor {
        .init(id: "native", kind: "dbus", endpointURL: "dbus://org.example.Typed/org/example/Typed")
    }
    func testNativeIntrospectionPreservesBooleanArrayOrderAndUnit() throws {
        let acquired = try DBusIntrospection.compile(Data(xml.utf8))
        XCTAssertEqual(acquired.methods.map(\.member), ["Store", "Tags", "Void"])
        XCTAssertEqual(acquired.omittedMethods.count, 2)
        let store = try acquired.methods[0].operation(reservedArgument: "invocation")
        try store.arguments.validate(.object(["enabled": .boolean(true)]))
        XCTAssertThrowsError(try store.arguments.validate(.object(["enabled": .string("true")])))
        XCTAssertThrowsError(try store.arguments.validate(.object(["enabled": .boolean(true), "invocation": .string("substitution")])))
        XCTAssertEqual(acquired.methods[0].inputSignature, "bs")
        XCTAssertEqual(try acquired.methods[1].inputs[0].type.tokens(.array([.string("literal $(no-shell)"), .string("x")])), ["2", "literal $(no-shell)", "x"])
        if case .unit = try acquired.methods[2].operation(reservedArgument: nil).result {} else { XCTFail("Void native method is not explicit unit") }
    }
    func testUnknownNativeTypesAndNoReplyAnnotationsAbstain() throws {
        for signature in ["u", "i", "x", "t", "d", "o", "g", "v", "h", "a{ss}", "(ss)"] { XCTAssertThrowsError(try DBusValueType.parse(signature)) }
        let acquired = try DBusIntrospection.compile(Data("<node><interface name=\"org.example.Typed\"><method name=\"NoReply\"><annotation name=\"org.freedesktop.DBus.Method.NoReply\" value=\"true\"/></method></interface></node>".utf8))
        XCTAssertTrue(acquired.methods.isEmpty)
        XCTAssertEqual(acquired.omittedMethods, ["org.example.Typed.NoReply"])
    }
    func testXMLRejectsEntitiesMalformedNamesDuplicateMethodsAndDeepTrees() throws {
        XCTAssertThrowsError(try DBusIntrospection.compile(Data("<!DOCTYPE node [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><node/>".utf8)))
        XCTAssertThrowsError(try DBusIntrospection.compile(Data("<node><interface name=\"broken\"/></node>".utf8)))
        let repeated = "<method name=\"Duplicate\"/>"
        XCTAssertThrowsError(try DBusIntrospection.compile(Data(("<node><interface name=\"org.example.Typed\">" + repeated + repeated + "</interface></node>").utf8)))
        XCTAssertThrowsError(try DBusIntrospection.compile(Data(repeating: 32, count: 131_073)))
        XCTAssertThrowsError(try DBusIntrospection.compile(Data("<node><interface name=\"org.example.Typed\"><method name=\"HiddenConstraint\" unknown=\"constraint\"/></interface></node>".utf8)))
    }
    func testTrustedMarkerIsHiddenAndReplacedOnlyByAdmittedTaskIdentity() throws {
        let transport = Transport(xml)
        let reflector = try DBusCapabilityArtifactResolver(transport: transport, invocationArgument: "invocation").resolve(descriptor())
        let item = try ContentParser.parse("native typed proof")
        let capability = try reflector.capabilities(for: item).first { $0.title == "Store" }!
        XCTAssertEqual(capability.metadata["argumentNames"], "enabled")
        let result = try reflector.begin(capability: capability, item: item, executionID: "admitted", arguments: ["enabled": "[\"boolean\",true]"])
        XCTAssertEqual(result.state, .accepted); XCTAssertEqual(result.rcir?.leaseConsumed, true)
        XCTAssertEqual(transport.effects, 1)
        guard transport.lastTokens.count == 2 else { return XCTFail("Admitted native argument tokens absent: \(result.message)") }
        XCTAssertEqual(transport.lastTokens[0], "true")
        XCTAssertEqual(transport.lastTokens[1], result.rcir?.taskID)
        XCTAssertThrowsError(try reflector.begin(capability: capability, item: item, executionID: "substitution", arguments: ["enabled": "[\"boolean\",true]", "invocation": "substituted"]))
        XCTAssertEqual(transport.effects, 1)
    }
    func testWithdrawalReplacementAndChangedTypedMetadataInvalidateOldReflector() throws {
        let transport = Transport(xml)
        let reflected = try DBusCapabilityArtifactResolver(transport: transport).resolve(descriptor())
        let item = try ContentParser.parse("owner lifecycle")
        XCTAssertEqual(try reflected.capabilities(for: item).count, 3)
        transport.present = false; XCTAssertTrue(try reflected.capabilities(for: item).isEmpty)
        transport.present = true; transport.owner = ":1.8"; XCTAssertTrue(try reflected.capabilities(for: item).isEmpty)
        transport.owner = ":1.7"; transport.xml += "\n"; XCTAssertTrue(try reflected.capabilities(for: item).isEmpty)
    }
    func testBusRestartCannotReuseAnOldUniqueOwnerAndDeclaration() throws {
        let transport = Transport(xml)
        let reflected = try DBusCapabilityArtifactResolver(transport: transport).resolve(descriptor())
        let item = try ContentParser.parse("broker incarnation")
        XCTAssertEqual(try reflected.capabilities(for: item).count, 3)
        // D-Bus unique owner names may be reused after a bus restart.
        transport.busID = String(repeating: "b", count: 32)
        XCTAssertTrue(try reflected.capabilities(for: item).isEmpty)
    }
    func testNativeUnitCompletionIsAcceptedAndNeverInventsJSONNullOutput() throws {
        let transport = Transport(xml)
        let reflector = try DBusCapabilityArtifactResolver(transport: transport).resolve(descriptor())
        let item = try ContentParser.parse("void boundary")
        let capability = try reflector.capabilities(for: item).first { $0.title == "Void" }!
        let result = try reflector.begin(capability: capability, item: item, executionID: "void")
        XCTAssertEqual(result.state, .accepted); XCTAssertNil(result.output)
        XCTAssertEqual(result.rcir?.phase, "completed"); XCTAssertEqual(result.rcir?.outcome, "unverified")
    }
}
#else
final class DBusRuntimeTests: XCTestCase {
    func testAbsentXMLParserCannotClaimDirectNativeCapabilities() throws {
        XCTAssertThrowsError(try DBusIntrospection.compile(Data("<node/>".utf8)))
    }
}
#endif
