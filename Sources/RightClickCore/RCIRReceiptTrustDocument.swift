import Foundation

/// A small closed JSON document reader. The raw parser preserves number kinds
/// and detects duplicate decoded keys before dictionaries can discard them.
struct RCIRReceiptTrustDocument {
    static let maximumBytes = 131_072
    let issuerID: String
    let maximumLiveAge: Int64
    let records: [RCIRReceiptKeyRecord]

    static func read(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else { throw RCIRReceiptTrustError.invalidPolicy }
        var parser = ReceiptPolicyJSON(data, policy: true)
        let root = try parser.read()
        let object = try root.object(exact: ["version", "issuerID", "maximumLiveAge", "keys"])
        guard try object["version"]!.integer() == 1 else { throw RCIRReceiptTrustError.invalidPolicy }
        let issuer = try object["issuerID"]!.string()
        let age = try object["maximumLiveAge"]!.integer()
        guard case let .array(keys) = object["keys"]!, !keys.isEmpty,
              keys.count <= RCIRReceiptTrustPolicy.maximumRecords else { throw RCIRReceiptTrustError.invalidPolicy }
        let records = try keys.map { value -> RCIRReceiptKeyRecord in
            let key = try value.object(exact: ["keyID", "publicKey", "notBefore", "notAfter", "retiredAt", "revoked"])
            let encoded = try key["publicKey"]!.string()
            guard encoded.utf8.count == 44, let bytes = Data(base64Encoded: encoded),
                  bytes.count == 32, bytes.base64EncodedString().utf8.elementsEqual(encoded.utf8)
            else { throw RCIRReceiptTrustError.invalidPolicy }
            let retirement: Int64?
            if case .null = key["retiredAt"]! { retirement = nil }
            else { retirement = try key["retiredAt"]!.integer() }
            return try .init(keyID: key["keyID"]!.string(), publicKey: bytes,
                notBefore: key["notBefore"]!.integer(), notAfter: key["notAfter"]!.integer(),
                retiredAt: retirement, revoked: key["revoked"]!.boolean())
        }
        // Validate issuer, freshness, duplicate locators and IDs at the same
        // bounded policy boundary used for retained reconciliation.
        _ = try RCIRReceiptTrustPolicy(issuerID: issuer, records: records, maximumLiveAge: age)
        return .init(issuerID: issuer, maximumLiveAge: age, records: records)
    }
}

/// Shared raw JSON validation before an existing closed host decoder. This is
/// duplicate/syntax validation only; each caller still owns its closed schema.
enum RCIRReceiptTrustJSON {
    static func validateUniqueKeys(_ data: Data) throws {
        guard !data.isEmpty, data.count <= RCIRReceiptTrustDocument.maximumBytes else { throw RCIRReceiptTrustError.invalidPolicy }
        var parser = ReceiptPolicyJSON(data, policy: false)
        _ = try parser.read()
    }
}

private indirect enum ReceiptPolicyValue {
    case object([String: ReceiptPolicyValue]), array([ReceiptPolicyValue])
    case string(String), number(String), boolean(Bool), null

    func object(exact keys: Set<String>) throws -> [String: ReceiptPolicyValue] {
        guard case let .object(value) = self, Set(value.keys) == keys else { throw RCIRReceiptTrustError.invalidPolicy }
        return value
    }
    func string() throws -> String {
        guard case let .string(value) = self else { throw RCIRReceiptTrustError.invalidPolicy }; return value
    }
    func integer() throws -> Int64 {
        guard case let .number(raw) = self, raw.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int64(raw), value >= 0 else { throw RCIRReceiptTrustError.invalidPolicy }; return value
    }
    func boolean() throws -> Bool {
        guard case let .boolean(value) = self else { throw RCIRReceiptTrustError.invalidPolicy }; return value
    }
}

private struct ReceiptPolicyJSON {
    private let bytes: [UInt8]
    private var offset = 0
    private var nodes = 0
    private let policy: Bool
    init(_ data: Data, policy: Bool) { bytes = Array(data); self.policy = policy }

    mutating func read() throws -> ReceiptPolicyValue {
        guard !bytes.isEmpty, bytes.count <= RCIRReceiptTrustDocument.maximumBytes else { throw RCIRReceiptTrustError.invalidPolicy }
        let result = try value(depth: 0); whitespace()
        guard offset == bytes.count else { throw RCIRReceiptTrustError.invalidPolicy }; return result
    }
    private mutating func whitespace() {
        while offset < bytes.count, [9,10,13,32].contains(bytes[offset]) { offset += 1 }
    }
    private mutating func consume(_ byte: UInt8) -> Bool {
        whitespace()
        guard offset < bytes.count, bytes[offset] == byte else { return false }; offset += 1; return true
    }
    private mutating func literal(_ text: String) throws {
        let literal = Array(text.utf8)
        guard bytes.count - offset >= literal.count, Array(bytes[offset..<(offset + literal.count)]) == literal else { throw RCIRReceiptTrustError.invalidPolicy }
        offset += literal.count
    }
    private mutating func value(depth: Int) throws -> ReceiptPolicyValue {
        whitespace(); nodes += 1
        guard depth <= (policy ? 4 : 32), nodes <= (policy ? 1024 : 65_536), offset < bytes.count else { throw RCIRReceiptTrustError.invalidPolicy }
        switch bytes[offset] {
        case 123:
            offset += 1; var result: [String: ReceiptPolicyValue] = [:]; var seen: Set<Data> = []
            if consume(125) { return .object(result) }
            repeat {
                whitespace()
                let key = try string()
                guard seen.insert(Data(key.utf8)).inserted, result[key] == nil, consume(58) else { throw RCIRReceiptTrustError.invalidPolicy }
                result[key] = try value(depth: depth + 1)
                if consume(125) { return .object(result) }
            } while consume(44)
            throw RCIRReceiptTrustError.invalidPolicy
        case 91:
            offset += 1; var result: [ReceiptPolicyValue] = []
            if consume(93) { return .array(result) }
            repeat {
                result.append(try value(depth: depth + 1))
                guard result.count <= (policy ? 64 : 65_536) else { throw RCIRReceiptTrustError.invalidPolicy }
                if consume(93) { return .array(result) }
            } while consume(44)
            throw RCIRReceiptTrustError.invalidPolicy
        case 34: return .string(try string())
        case 116: try literal("true"); return .boolean(true)
        case 102: try literal("false"); return .boolean(false)
        case 110: try literal("null"); return .null
        case 45, 48...57:
            let start = offset
            if bytes[offset] == 45 { offset += 1 }
            guard offset < bytes.count else { throw RCIRReceiptTrustError.invalidPolicy }
            if bytes[offset] == 48 { offset += 1 }
            else {
                guard (49...57).contains(bytes[offset]) else { throw RCIRReceiptTrustError.invalidPolicy }
                while offset < bytes.count, (48...57).contains(bytes[offset]) { offset += 1 }
            }
            if offset < bytes.count, bytes[offset] == 46 {
                offset += 1; let digits = offset
                while offset < bytes.count, (48...57).contains(bytes[offset]) { offset += 1 }
                guard offset > digits else { throw RCIRReceiptTrustError.invalidPolicy }
            }
            if offset < bytes.count, bytes[offset] == 101 || bytes[offset] == 69 {
                offset += 1
                if offset < bytes.count, bytes[offset] == 43 || bytes[offset] == 45 { offset += 1 }
                let digits = offset
                while offset < bytes.count, (48...57).contains(bytes[offset]) { offset += 1 }
                guard offset > digits else { throw RCIRReceiptTrustError.invalidPolicy }
            }
            return .number(String(decoding: bytes[start..<offset], as: UTF8.self))
        default: throw RCIRReceiptTrustError.invalidPolicy
        }
    }
    private mutating func string() throws -> String {
        guard offset < bytes.count, bytes[offset] == 34 else { throw RCIRReceiptTrustError.invalidPolicy }
        let start = offset; offset += 1
        while offset < bytes.count {
            let byte = bytes[offset]; offset += 1
            if byte == 34 {
                // Foundation decodes JSON escapes/Unicode; this raw reader owns
                // syntax, bounded nesting and duplicate-key rejection.
                let data = Data(bytes[start..<offset])
                guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String,
                      value.utf8.count <= (policy ? 2048 : RCIRReceiptTrustDocument.maximumBytes) else { throw RCIRReceiptTrustError.invalidPolicy }
                return value
            }
            if byte == 92 {
                guard offset < bytes.count else { throw RCIRReceiptTrustError.invalidPolicy }
                offset += 1
            } else if byte < 32 { throw RCIRReceiptTrustError.invalidPolicy }
            guard offset - start <= (policy ? 8192 : RCIRReceiptTrustDocument.maximumBytes) else { throw RCIRReceiptTrustError.invalidPolicy }
        }
        throw RCIRReceiptTrustError.invalidPolicy
    }
}
