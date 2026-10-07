import Foundation

/// Exact Automation subset. Narrow integers, variants, arrays, handles,
/// optional/out/by-reference parameters and unknown native types abstain.
enum WindowsCOMValueType: UInt16 {
    case empty = 0, number = 5, string = 8, boolean = 11, integer = 20, void = 24
    var schema: CapabilitySchema {
        switch self {
        case .string: return .string
        case .boolean: return .boolean
        case .integer: return .integer
        case .number: return .number
        case .void, .empty: return .unit
        }
    }
    var inputSupported: Bool { self != .empty && self != .void }
    func encode(_ value: CapabilityValue, into bytes: inout Data) throws {
        bytes.comAppend(UInt64(rawValue), width: 2)
        switch (self, value) {
        case let (.string, .string(text)):
            let encoded = Data(text.utf8)
            guard encoded.count <= 1_048_576 else { throw CapabilityABIError.limitExceeded }
            bytes.comAppend(UInt64(encoded.count), width: 4); bytes.append(encoded)
        case let (.boolean, .boolean(flag)): bytes.append(flag ? 1 : 0)
        case let (.integer, .integer(number)): bytes.comAppend(UInt64(bitPattern: number), width: 8)
        case let (.number, .number(number)):
            guard number.isFinite else { throw CapabilityABIError.invalidWire }
            bytes.comAppend(number.bitPattern, width: 8)
        default: throw CapabilityABIError.schemaMismatch
        }
    }
}

struct WindowsCOMParameter: Decodable {
    let name: String
    let type: UInt16
    let flags: UInt16
}
struct WindowsCOMMember: Decodable {
    let id: Int32
    let name: String
    let kind: UInt16
    let functionKind: UInt16
    let flags: UInt16
    let optional: UInt32
    let result: UInt16
    let resultFlags: UInt16
    let scodes: UInt32
    let parameters: [WindowsCOMParameter]
    var key: String { "method:" + String(id) }
    func operation(acquisition: String, declaration: CapabilityValue) throws -> CapabilityInterfaceOperation {
        guard kind == 1, functionKind == 4, flags == 0, optional == 0, resultFlags == 0, scodes == 0,
              Self.validName(name), parameters.count <= 32,
              Set(parameters.map(\.name)).count == parameters.count,
              let returnType = WindowsCOMValueType(rawValue: result), returnType != .empty else { throw CapabilityABIError.invalidSchema }
        var properties: [String: CapabilitySchema] = [:]
        for parameter in parameters {
            guard Self.validName(parameter.name), parameter.flags == 1,
                  let type = WindowsCOMValueType(rawValue: parameter.type), type.inputSupported else { throw CapabilityABIError.invalidSchema }
            properties[parameter.name] = type.schema
        }
        return .init(name: key, title: name,
            arguments: .object(properties: properties, required: parameters.map(\.name)), result: returnType.schema,
            declaration: .object(["acquisitionID": .string(acquisition), "nativeDeclaration": declaration,
                "dispid": .integer(Int64(id)), "invocationKind": .integer(Int64(kind)),
                "inputOrder": .array(parameters.map { .string($0.name) }),
                "inputNativeTypes": .array(parameters.map { .integer(Int64($0.type)) }),
                "resultNativeType": .integer(Int64(result))]), effect: .execute)
    }
    static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
    func arguments(_ value: CapabilityValue) throws -> Data {
        guard case let .object(values) = value,
              Set(values.keys.map { Data($0.utf8) }) == Set(parameters.map { Data($0.name.utf8) }) else { throw CapabilityABIError.schemaMismatch }
        var result = Data(); result.comAppend(UInt64(parameters.count), width: 4)
        for parameter in parameters {
            guard let supplied = values[parameter.name], let type = WindowsCOMValueType(rawValue: parameter.type), type.inputSupported else { throw CapabilityABIError.schemaMismatch }
            try type.encode(supplied, into: &result)
        }
        guard result.count <= 1_048_576 else { throw CapabilityABIError.limitExceeded }
        return result
    }
    func resultValue(_ bytes: Data) throws -> CapabilityValue {
        var reader = WindowsCOMReader(bytes: bytes)
        let actual = try reader.integer(width: 2)
        guard actual == UInt64(result == WindowsCOMValueType.void.rawValue ? WindowsCOMValueType.empty.rawValue : result) else { throw CapabilityABIError.schemaMismatch }
        let value: CapabilityValue
        switch WindowsCOMValueType(rawValue: UInt16(actual)) {
        case .empty: value = .null
        case .string:
            let length = try reader.integer(width: 4)
            guard length <= 1_048_576, let text = String(data: try reader.data(count: Int(length)), encoding: .utf8) else { throw CapabilityABIError.invalidWire }
            value = .string(text)
        case .boolean:
            let flag = try reader.integer(width: 1); guard flag <= 1 else { throw CapabilityABIError.invalidWire }
            value = .boolean(flag == 1)
        case .integer: value = .integer(Int64(bitPattern: try reader.integer(width: 8)))
        case .number:
            let number = Double(bitPattern: try reader.integer(width: 8)); guard number.isFinite else { throw CapabilityABIError.invalidWire }
            value = .number(number)
        default: throw CapabilityABIError.invalidWire
        }
        guard reader.cursor == bytes.count else { throw CapabilityABIError.invalidWire }
        return value
    }
}
struct WindowsCOMDeclaration: Decodable {
    let format: Int
    let interfaceGUID: String
    let typeKind: Int
    let typeFlags: UInt16
    let major: UInt16
    let minor: UInt16
    let locale: UInt32
    let libraryGUID: String
    let libraryMajor: UInt16
    let libraryMinor: UInt16
    let libraryLocale: UInt32
    let librarySystem: UInt32
    let libraryIndex: UInt32
    let members: [WindowsCOMMember]
}
struct WindowsCOMAcquisition: Decodable {
    let acquisitionID: String
    let moniker: String
    let declaration: WindowsCOMDeclaration
}
struct WindowsCOMTypeLibrary {
    let acquisition: WindowsCOMAcquisition
    let declaration: CapabilityValue
    let operations: [CapabilityInterfaceOperation]
    let members: [String: WindowsCOMMember]
    let omitted: [String]
    let digest: String

    static func compile(_ raw: Data) throws -> [Self] {
        guard raw.count <= 1_048_576,
              let native = try JSONSerialization.jsonObject(with: raw) as? [[String: Any]], native.count <= 64 else { throw CapabilityABIError.invalidWire }
        let acquisitions = try JSONDecoder().decode([WindowsCOMAcquisition].self, from: raw)
        guard Set(acquisitions.map(\.acquisitionID)).count == acquisitions.count else { throw CapabilityABIError.invalidIdentity }
        return try zip(acquisitions, native).map { acquisition, value in
            guard UUID(uuidString: acquisition.acquisitionID) != nil, acquisition.acquisitionID.utf8.count == 36,
                  !acquisition.moniker.isEmpty, acquisition.moniker.utf8.count <= 4096,
                  acquisition.moniker.rangeOfCharacter(from: .controlCharacters) == nil,
                  acquisition.declaration.format == 1, acquisition.declaration.typeKind == 4,
                  UUID(uuidString: acquisition.declaration.interfaceGUID) != nil,
                  UUID(uuidString: acquisition.declaration.libraryGUID) != nil,
                  acquisition.declaration.members.count <= 256 else { throw CapabilityABIError.invalidIdentity }
            let declaration = try CapabilityJSON.value(value)
            var operations: [CapabilityInterfaceOperation] = [], members: [String: WindowsCOMMember] = [:], omitted: [String] = []
            for member in acquisition.declaration.members {
                do {
                    let operation = try member.operation(acquisition: acquisition.acquisitionID, declaration: declaration)
                    guard members[member.key] == nil else { throw CapabilityABIError.invalidSchema }
                    members[member.key] = member; operations.append(operation)
                } catch { omitted.append(member.key) }
            }
            // Ambiguous native DISPIDs are never resolved by first-match order.
            let ambiguous = Dictionary(grouping: acquisition.declaration.members, by: \.id).filter { $0.value.count > 1 }.keys
            for id in ambiguous { let key = "method:" + String(id); members.removeValue(forKey: key); operations.removeAll { $0.name == key }; omitted.append(key) }
            return Self(acquisition: acquisition, declaration: declaration, operations: operations,
                members: members, omitted: omitted.sorted(), digest: CapabilityJSON.digest(try declaration.canonicalData()))
        }
    }
}
private extension Data {
    mutating func comAppend(_ value: UInt64, width: Int) {
        for n in 0..<width { append(UInt8(truncatingIfNeeded: value >> (n * 8))) }
    }
}
private struct WindowsCOMReader {
    let bytes: Data
    var cursor = 0
    mutating func data(count: Int) throws -> Data {
        guard count >= 0, cursor <= bytes.count, count <= bytes.count - cursor else { throw CapabilityABIError.invalidWire }
        let result = bytes.subdata(in: cursor..<(cursor + count)); cursor += count; return result
    }
    mutating func integer(width: Int) throws -> UInt64 {
        guard (1...8).contains(width) else { throw CapabilityABIError.invalidWire }
        let data = try self.data(count: width)
        return data.enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
    }
}
