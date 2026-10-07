import Foundation

/// A finite WIT compiler for the existing typed ABI. This owns no admission,
/// authority, lifecycle or verification state. Unsupported declarations abstain.
struct WITComponentOperation {
    let name: String
    let parameters: [(String, WITValueType)]
    let result: WITValueType?
    let declaration: CapabilityValue

    var arguments: CapabilitySchema {
        .object(properties: Dictionary(uniqueKeysWithValues: parameters.map { ($0.0, $0.1.schema) }),
                required: parameters.map(\.0))
    }
    var interface: CapabilityInterfaceOperation {
        .init(name: name, title: name, arguments: arguments, result: result?.schema ?? .unit, declaration: declaration)
    }
    func invocation(_ input: CapabilityValue) throws -> String {
        try arguments.validate(input)
        guard case let .object(values) = input else { throw CapabilityABIError.schemaMismatch }
        return name + "(" + (try parameters.map { try $0.1.wave(values[$0.0]!) }).joined(separator: ",") + ")"
    }
    func returned(_ bytes: Data) throws -> CapabilityValue {
        guard bytes.count <= 1_048_576, let text = String(data: bytes, encoding: .utf8) else { throw CapabilityABIError.invalidWire }
        if let result { return try WITWaveDecoder.decode(text, type: result) }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines) == "()" else { throw CapabilityABIError.invalidWire }
        return .null  // Explicit unit lowering; the common host retains no output.
    }
}

enum WITComponentContract {
    static func operations(_ bytes: Data) throws -> [WITComponentOperation] {
        guard bytes.count <= 1_048_576,
              let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let worlds = json["worlds"] as? [[String: Any]], worlds.count == 1,
              let world = worlds.first, let imports = world["imports"] as? [String: Any], imports.isEmpty,
              let exports = world["exports"] as? [String: Any], !exports.isEmpty, exports.count <= 256,
              let interfaces = json["interfaces"] as? [[String: Any]], interfaces.count <= 256,
              let types = json["types"] as? [[String: Any]], types.count <= 4096,
              let packages = json["packages"] as? [[String: Any]], packages.count <= 256 else {
            throw CapabilityABIError.invalidSchema
        }
        var output: [WITComponentOperation] = []
        var names: Set<String> = []
        var typeNodes = 0
        var referenced: Set<Int> = []
        func index(_ raw: Any, count: Int) throws -> Int {
            guard let number = raw as? NSNumber, !CapabilityJSONNumber.isBoolean(number),
                  number.doubleValue >= 0, number.doubleValue < Double(count),
                  number.doubleValue.rounded(.towardZero) == number.doubleValue else { throw CapabilityABIError.invalidSchema }
            return number.intValue
        }
        func type(_ raw: Any, depth: Int = 0, visiting: Set<Int> = []) throws -> WITValueType {
            guard depth <= 32, typeNodes < 4096 else { throw CapabilityABIError.limitExceeded }
            typeNodes += 1
            if let name = raw as? String { return try WITValueType.primitive(name) }
            let identifier = try index(raw, count: types.count)
            referenced.insert(identifier)
            guard !visiting.contains(identifier), let kind = types[identifier]["kind"] as? [String: Any], kind.count == 1 else {
                throw CapabilityABIError.invalidSchema
            }
            let next = visiting.union([identifier])
            if let alias = kind["type"] { return try type(alias, depth: depth + 1, visiting: next) }
            if let element = kind["list"] { return .list(try type(element, depth: depth + 1, visiting: next)) }
            if let record = kind["record"] as? [String: Any], Set(record.keys) == ["fields"],
               let fields = record["fields"] as? [[String: Any]], fields.count <= 256 {
                var found: Set<String> = []
                let compiled = try fields.map { field -> (String, WITValueType) in
                    guard Set(field.keys).isSubset(of: ["name", "type", "docs"]),
                          let name = field["name"] as? String, WITValueType.label(name), found.insert(name).inserted,
                          let raw = field["type"] else { throw CapabilityABIError.invalidSchema }
                    return (name, try type(raw, depth: depth + 1, visiting: next))
                }
                return .record(compiled)
            }
            // No inferred representation for variants/options/results/tuples,
            // resources, char, floats, future/stream, or an unsafe u64 domain.
            throw CapabilityABIError.invalidSchema
        }
        func add(_ function: [String: Any], prefix: String?, version: String?) throws {
            guard Set(function.keys).isSubset(of: ["name", "kind", "params", "result", "docs", "stability"]),
                  function["kind"] as? String == "freestanding",
                  let name = function["name"] as? String, WITValueType.label(name),
                  let params = function["params"] as? [[String: Any]], params.count <= 32 else { throw CapabilityABIError.invalidSchema }
            var found: Set<String> = []
            referenced = []
            let parameters = try params.map { parameter -> (String, WITValueType) in
                guard Set(parameter.keys) == ["name", "type"], let name = parameter["name"] as? String,
                      WITValueType.label(name), found.insert(name).inserted, let raw = parameter["type"] else { throw CapabilityABIError.invalidSchema }
                return (name, try type(raw))
            }
            let result = try function["result"].map { raw -> WITValueType? in
                if raw is NSNull { return nil }
                return try type(raw)
            } ?? nil
            let invocation = (prefix.map { $0 + "." } ?? "") + name + (version.map { "@" + $0 } ?? "")
            guard invocation.utf8.count <= 256, output.count < 256, names.insert(invocation).inserted else { throw CapabilityABIError.invalidIdentity }
            let operation = WITComponentOperation(name: invocation, parameters: parameters, result: result,
                declaration: .object(["function": try CapabilityJSON.value(function),
                    "types": .array(try referenced.sorted().map { .object(["id": .integer(Int64($0)), "type": try CapabilityJSON.value(types[$0])]) }),
                    "export": .string(invocation)]))
            _ = try operation.arguments.canonicalData(); _ = try operation.interface.result.canonicalData()
            _ = try operation.declaration.canonicalData()
            output.append(operation)
        }
        for name in exports.keys.sorted() {
            guard let export = exports[name] as? [String: Any], export.count == 1 else { throw CapabilityABIError.invalidSchema }
            if let function = export["function"] as? [String: Any] {
                guard function["name"] as? String == name else { throw CapabilityABIError.invalidIdentity }
                try add(function, prefix: nil, version: nil)
            } else if let reference = export["interface"] as? [String: Any], Set(reference.keys) == ["id"], let raw = reference["id"] {
                let interface = interfaces[try index(raw, count: interfaces.count)]
                guard let functions = interface["functions"] as? [String: [String: Any]], !functions.isEmpty,
                      let declaredTypes = interface["types"] as? [String: Any], declaredTypes.count <= 256 else { throw CapabilityABIError.invalidSchema }
                for raw in declaredTypes.values { _ = try type(raw) }
                let prefix: String, version: String?
                if let raw = interface["package"], !(raw is NSNull) {
                    let package = packages[try index(raw, count: packages.count)]
                    guard let identity = package["name"] as? String, let interfaceName = interface["name"] as? String,
                          WITValueType.label(interfaceName) else { throw CapabilityABIError.invalidIdentity }
                    let split = identity.split(separator: "@", omittingEmptySubsequences: false)
                    guard (1...2).contains(split.count), split[0].split(separator: ":").count == 2,
                          split[0].split(separator: ":").allSatisfy({ WITValueType.label(String($0)) }) else { throw CapabilityABIError.invalidIdentity }
                    version = split.count == 2 ? String(split[1]) : nil
                    guard version.map({ $0.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[a-zA-Z0-9.-]+)?(?:\\+[a-zA-Z0-9.-]+)?$", options: .regularExpression) != nil }) ?? true else { throw CapabilityABIError.invalidIdentity }
                    prefix = String(split[0]) + "/" + interfaceName
                } else {
                    guard WITValueType.label(name) else { throw CapabilityABIError.invalidIdentity }
                    prefix = name; version = nil
                }
                for name in functions.keys.sorted() {
                    guard functions[name]?["name"] as? String == name else { throw CapabilityABIError.invalidIdentity }
                    try add(functions[name]!, prefix: prefix, version: version)
                }
            } else { throw CapabilityABIError.invalidSchema }
        }
        guard !output.isEmpty else { throw CapabilityABIError.invalidSchema }
        return output
    }
}

indirect enum WITValueType {
    case string, boolean, integer(Int64, Int64)
    case list(WITValueType), record([(String, WITValueType)])
    var schema: CapabilitySchema {
        switch self {
        case .string: return .string
        case .boolean: return .boolean
        case let .integer(minimum, maximum): return .integerRange(minimum: minimum, maximum: maximum)
        case let .list(element): return .array(element.schema)
        case let .record(fields): return .object(properties: Dictionary(uniqueKeysWithValues: fields.map { ($0.0, $0.1.schema) }), required: fields.map(\.0))
        }
    }
    static func primitive(_ name: String) throws -> Self {
        switch name {
        case "string": return .string
        case "bool": return .boolean
        case "s8": return .integer(-128, 127)
        case "s16": return .integer(-32768, 32767)
        case "s32": return .integer(-2147483648, 2147483647)
        case "s64": return .integer(.min, .max)
        case "u8": return .integer(0, 255)
        case "u16": return .integer(0, 65535)
        case "u32": return .integer(0, 4294967295)
        default: throw CapabilityABIError.invalidSchema
        }
    }
    static func label(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 256 else { return false }
        let words = name.split(separator: "-", omittingEmptySubsequences: false)
        return words.enumerated().allSatisfy { index, word in
            guard !word.isEmpty, index != 0 || word.first?.isASCII == true && word.first?.isLetter == true else { return false }
            let bytes = Array(word.utf8)
            return bytes.allSatisfy { (48...57).contains($0) || (97...122).contains($0) }
                || bytes.allSatisfy { (48...57).contains($0) || (65...90).contains($0) }
        }
    }
    func wave(_ value: CapabilityValue) throws -> String {
        try schema.validate(value)
        func encode(_ type: WITValueType, _ value: CapabilityValue) throws -> String {
            switch (type, value) {
            case let (.string, .string(text)):
                var output = "\""
                for scalar in text.unicodeScalars {
                    switch scalar.value {
                    case 34: output += "\\\""
                    case 92: output += "\\\\"
                    case 9: output += "\\t"
                    case 10: output += "\\n"
                    case 13: output += "\\r"
                    case 0...31, 127: output += "\\u{" + String(scalar.value, radix: 16) + "}"
                    default: output.unicodeScalars.append(scalar)
                    }
                }
                return output + "\""
            case let (.boolean, .boolean(flag)): return flag ? "true" : "false"
            case let (.integer, .integer(integer)): return String(integer)
            case let (.list(element), .array(values)): return "[" + (try values.map { try encode(element, $0) }).joined(separator: ",") + "]"
            case let (.record(fields), .object(values)):
                if fields.isEmpty { return "{:}" }
                return "{" + (try fields.map { "%" + $0.0 + ":" + (try encode($0.1, values[$0.0]!)) }).joined(separator: ",") + "}"
            default: throw CapabilityABIError.schemaMismatch
            }
        }
        let output = try encode(self, value)
        guard output.utf8.count <= 1_048_576 else { throw CapabilityABIError.limitExceeded }
        return output
    }
}

/// Schema-directed finite WAVE reader. JSON is not the component value grammar.
/// This accepts the supported Wasmtime writer forms, never executable syntax.
private struct WITWaveDecoder {
    let input: [Unicode.Scalar]
    var position = 0
    var nodes = 0
    static func decode(_ text: String, type: WITValueType) throws -> CapabilityValue {
        guard text.utf8.count <= 1_048_576 else { throw CapabilityABIError.limitExceeded }
        var decoder = Self(input: Array(text.unicodeScalars))
        let value = try decoder.read(type, depth: 0)
        decoder.space()
        guard decoder.position == decoder.input.count else { throw CapabilityABIError.invalidWire }
        try type.schema.validate(value)
        return value
    }
    mutating func space() {
        while position < input.count, [9, 10, 13, 32].contains(input[position].value) { position += 1 }
    }
    mutating func consume(_ scalar: Unicode.Scalar) -> Bool {
        space()
        guard position < input.count, input[position] == scalar else { return false }
        position += 1; return true
    }
    mutating func require(_ scalar: Unicode.Scalar) throws {
        guard consume(scalar) else { throw CapabilityABIError.invalidWire }
    }
    mutating func read(_ type: WITValueType, depth: Int) throws -> CapabilityValue {
        guard depth <= 32, nodes < 4096 else { throw CapabilityABIError.limitExceeded }
        nodes += 1; space()
        switch type {
        case .string:
            try require("\"")
            var output = String.UnicodeScalarView()
            while position < input.count {
                let scalar = input[position]; position += 1
                if scalar == "\"" { return .string(String(output)) }
                if scalar == "\\" {
                    guard position < input.count else { throw CapabilityABIError.invalidWire }
                    let escaped = input[position]; position += 1
                    switch escaped {
                    case "\"", "'", "\\": output.append(escaped)
                    case "t": output.append("\t")
                    case "n": output.append("\n")
                    case "r": output.append("\r")
                    case "u":
                        guard position < input.count, input[position] == "{" else { throw CapabilityABIError.invalidWire }
                        position += 1; let start = position
                        while position < input.count, input[position] != "}" {
                            guard position - start < 6, (48...57).contains(input[position].value) || (65...70).contains(input[position].value) || (97...102).contains(input[position].value) else { throw CapabilityABIError.invalidWire }
                            position += 1
                        }
                        guard position > start, position < input.count,
                              let code = UInt32(String(String.UnicodeScalarView(input[start..<position])), radix: 16),
                              let value = Unicode.Scalar(code) else { throw CapabilityABIError.invalidWire }
                        position += 1; output.append(value)
                    default: throw CapabilityABIError.invalidWire
                    }
                } else {
                    guard scalar.value >= 32, scalar.value != 127 else { throw CapabilityABIError.invalidWire }
                    output.append(scalar)
                }
            }
            throw CapabilityABIError.invalidWire
        case .boolean:
            let text = token()
            guard text == "true" || text == "false" else { throw CapabilityABIError.invalidWire }
            return .boolean(text == "true")
        case .integer:
            let text = token()
            guard let value = Int64(text), String(value) == text else { throw CapabilityABIError.invalidWire }
            return .integer(value)
        case let .list(element):
            try require("["); var values: [CapabilityValue] = []
            if consume("]") { return .array(values) }
            while true {
                guard values.count < 4096 else { throw CapabilityABIError.limitExceeded }
                values.append(try read(element, depth: depth + 1))
                if consume("]") { return .array(values) }
                try require(",")
                if consume("]") { return .array(values) }
            }
        case let .record(fields):
            try require("{"); var values: [String: CapabilityValue] = [:]
            if fields.isEmpty { try require(":"); try require("}"); return .object([:]) }
            while true {
                _ = consume("%"); space(); let start = position
                while position < input.count, input[position] != ":", ![9, 10, 13, 32].contains(input[position].value) { position += 1 }
                let name = String(String.UnicodeScalarView(input[start..<position]))
                guard WITValueType.label(name), values[name] == nil, let field = fields.first(where: { $0.0 == name }) else { throw CapabilityABIError.invalidWire }
                try require(":"); values[name] = try read(field.1, depth: depth + 1)
                if consume("}") { return .object(values) }
                try require(",")
                if consume("}") { return .object(values) }
            }
        }
    }
    mutating func token() -> String {
        space(); let start = position
        while position < input.count, ![9, 10, 13, 32, 44, 93, 125].contains(input[position].value) { position += 1 }
        return String(String.UnicodeScalarView(input[start..<position]))
    }
}
