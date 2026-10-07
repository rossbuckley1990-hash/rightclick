import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Closed native type compiler. Width-constrained integers, object/signature
/// handles, variants, dictionaries and structs abstain until RCIR represents
/// their exact constraints. Their native declarations are never erased.
indirect enum DBusValueType {
    case string, boolean, array(DBusValueType)
    static func parse(_ raw: String, depth: Int = 0) throws -> Self {
        guard depth < 8, raw.utf8.count <= 16 else { throw CapabilityABIError.invalidSchema }
        switch raw {
        case "s": return .string
        case "b": return .boolean
        default:
            guard raw.hasPrefix("a") else { throw CapabilityABIError.invalidSchema }
            return .array(try parse(String(raw.dropFirst()), depth: depth + 1))
        }
    }
    var schema: CapabilitySchema {
        switch self { case .string: return .string; case .boolean: return .boolean; case let .array(type): return .array(type.schema) }
    }
    func tokens(_ value: CapabilityValue, depth: Int = 0) throws -> [String] {
        guard depth < 8 else { throw CapabilityABIError.limitExceeded }
        switch (self, value) {
        case let (.string, .string(text)):
            guard !text.utf8.contains(0), text.utf8.count <= 131_072 else { throw CapabilityABIError.invalidWire }
            return [text]
        case let (.boolean, .boolean(flag)): return [flag ? "true" : "false"]
        case let (.array(type), .array(values)):
            guard values.count <= 4096 else { throw CapabilityABIError.limitExceeded }
            return try [String(values.count)] + values.flatMap { try type.tokens($0, depth: depth + 1) }
        default: throw CapabilityABIError.schemaMismatch
        }
    }
}

struct DBusMethodDeclaration {
    struct Argument {
        let name: String
        let signature: String
        let type: DBusValueType
    }
    let interface: String
    let member: String
    let inputs: [Argument]
    let outputs: [Argument]
    var key: String { interface + "." + member }
    var inputSignature: String { inputs.map(\.signature).joined() }
    var outputSignature: String { outputs.map(\.signature).joined() }
    func operation(reservedArgument: String?) throws -> CapabilityInterfaceOperation {
        let visible = inputs.filter { $0.name != reservedArgument }
        if let reservedArgument, inputs.contains(where: { $0.name == reservedArgument }) {
            guard let slot = inputs.first(where: { $0.name == reservedArgument }), slot.signature == "s" else { throw CapabilityABIError.invalidSchema }
        }
        let result: CapabilitySchema
        if outputs.isEmpty { result = .unit }
        else if outputs.count == 1 { result = outputs[0].type.schema }
        else { result = .object(properties: Dictionary(uniqueKeysWithValues: outputs.map { ($0.name, $0.type.schema) }), required: outputs.map(\.name)) }
        return .init(name: key, title: member,
            arguments: .object(properties: Dictionary(uniqueKeysWithValues: visible.map { ($0.name, $0.type.schema) }), required: visible.map(\.name)),
            result: result, declaration: .object([
                "interface": .string(interface), "member": .string(member),
                "inputSignature": .string(inputSignature), "outputSignature": .string(outputSignature),
                "inputOrder": .array(inputs.map { .string($0.name) }), "outputOrder": .array(outputs.map { .string($0.name) }),
                "hostInvocationArgument": reservedArgument.flatMap { name in inputs.contains(where: { $0.name == name }) ? .string(name) : nil } ?? .null
            ]), effect: .execute)
    }
    func result(_ values: [CapabilityValue]) throws -> CapabilityValue {
        guard values.count == outputs.count else { throw CapabilityABIError.invalidWire }
        for (argument, value) in zip(outputs, values) { try argument.type.schema.validate(value) }
        if values.isEmpty { return .null }
        if values.count == 1 { return values[0] }
        return .object(Dictionary(uniqueKeysWithValues: zip(outputs, values).map { ($0.name, $1) }))
    }
}

/// Parses actual Introspectable XML. DTD fetching/entity expansion is disabled;
/// the standard external DTD declaration itself does not grant network access.
#if os(macOS) || canImport(FoundationXML)
final class DBusIntrospection: NSObject, XMLParserDelegate {
    private struct RawArgument { let name: String?; let signature: String; let direction: String }
    private var stack: [String] = []
    private var interface: String?
    private var member: String?
    private var arguments: [RawArgument] = []
    private var unsupported = false
    private var invalid = false
    private(set) var methods: [DBusMethodDeclaration] = []
    private(set) var children: [String] = []
    private(set) var omittedMethods: [String] = []

    static func compile(_ data: Data) throws -> DBusIntrospection {
        guard data.count <= 131_072, let xml = String(data: data, encoding: .utf8),
              !xml.contains("<!ENTITY"), !xml.contains("<![CDATA[") else { throw CapabilityABIError.invalidWire }
        let compiler = DBusIntrospection()
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = compiler
        guard parser.parse(), !compiler.invalid, compiler.stack.isEmpty else { throw CapabilityABIError.invalidWire }
        guard Set(compiler.methods.map(\.key)).count == compiler.methods.count else { throw CapabilityABIError.invalidSchema }
        return compiler
    }
    static func validMember(_ value: String) -> Bool {
        value.utf8.count <= 255 && value.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }
    static func validInterface(_ value: String) -> Bool {
        value.utf8.count <= 255 && value.contains(".") && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { validMember(String($0)) }
    }
    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard stack.count < 32 else { invalid = true; parser.abortParsing(); return }
        let keys: [String: Set<String>] = ["node": ["name"], "interface": ["name"], "method": ["name"],
            "arg": ["name", "type", "direction"], "annotation": ["name", "value"],
            "signal": ["name"], "property": ["name", "type", "access"]]
        guard let allowed = keys[element], Set(attributes.keys).isSubset(of: allowed) else { invalid = true; parser.abortParsing(); return }
        let parent = stack.last; stack.append(element)
        switch element {
        case "node":
            if parent == "node", stack.count == 2 {
                guard let name = attributes["name"], name.utf8.count <= 255,
                      name.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil, children.count < 64 else { invalid = true; return }
                children.append(name)
            } else if parent != nil { invalid = true }
        case "interface":
            guard parent == "node", stack.count == 2, let name = attributes["name"], Self.validInterface(name) else { invalid = true; return }
            interface = name
        case "method":
            guard parent == "interface", let name = attributes["name"], Self.validMember(name), methods.count + omittedMethods.count < 256 else { invalid = true; return }
            member = name; arguments = []; unsupported = false
        case "arg":
            guard parent == "method" || parent == "signal" else { invalid = true; return }
            if parent == "method" {
                guard let signature = attributes["type"], signature.utf8.count <= 255, arguments.count < 64,
                      attributes["name"].map(Self.validMember) ?? true else { invalid = true; return }
                let direction = attributes["direction"] ?? "in"
                guard direction == "in" || direction == "out" else { invalid = true; return }
                arguments.append(.init(name: attributes["name"], signature: signature, direction: direction))
            }
        case "annotation":
            if member != nil {
                let name = attributes["name"], value = attributes["value"]
                if name == "org.freedesktop.DBus.Deprecated" { if value != "true" && value != "false" { unsupported = true } }
                else if name == "org.freedesktop.DBus.Method.NoReply" { if value != "false" { unsupported = true } }
                else { unsupported = true }
            }
        case "signal", "property":
            guard parent == "interface" else { invalid = true; return }
        default: invalid = true
        }
    }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        guard stack.last == element else { invalid = true; return }
        stack.removeLast()
        if element == "method", let interface, let member {
            defer { self.member = nil; arguments = [] }
            // Protocol control interfaces are infrastructure, never app actions.
            if interface.hasPrefix("org.freedesktop.DBus.") { return }
            do {
                guard !unsupported else { throw CapabilityABIError.invalidSchema }
                func compile(_ direction: String) throws -> [DBusMethodDeclaration.Argument] {
                    let selected = arguments.filter { $0.direction == direction }
                    let result = try selected.enumerated().map { index, argument in
                        DBusMethodDeclaration.Argument(name: argument.name ?? "arg\(index)", signature: argument.signature, type: try DBusValueType.parse(argument.signature))
                    }
                    guard Set(result.map(\.name)).count == result.count else { throw CapabilityABIError.invalidSchema }
                    return result
                }
                methods.append(.init(interface: interface, member: member, inputs: try compile("in"), outputs: try compile("out")))
            } catch { omittedMethods.append(interface + "." + member) }
        }
        if element == "interface" { interface = nil }
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
    func parser(_ parser: XMLParser, foundCharacters text: String) {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { invalid = true }
    }
}
#else
/// No descriptor parser means no native capability claim on this host.
final class DBusIntrospection {
    let methods: [DBusMethodDeclaration] = []
    let children: [String] = []
    let omittedMethods: [String] = []
    static func compile(_ data: Data) throws -> DBusIntrospection { throw RCIRError.unavailable }
    static func validMember(_ value: String) -> Bool {
        value.utf8.count <= 255 && value.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }
    static func validInterface(_ value: String) -> Bool {
        value.utf8.count <= 255 && value.contains(".") && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { validMember(String($0)) }
    }
}
#endif
