import Foundation

/// Exact bytes for contract fingerprints; NOT a replacement for provider JSON.
/// Implements ACTENON-JCS-STRICT-1's wire rules, with an additional 8 MiB
/// input bound. See docs/PROTOCOL-REUSE.md for the pinned source and test scope.
public enum ContractCanonicalJSON {
    public static let profile = "ACTENON-JCS-STRICT-1"
    public static let maximumBytes = 1_048_576
    public static let maximumInputBytes = 8 * maximumBytes

    public enum Failure: Error {
        case malformed, duplicateKey, invalidUnicode, nonInteger, tooDeep, tooLarge
    }

    public static func canonicalize(_ data: Data) throws -> Data {
        guard data.count <= maximumInputBytes else { throw Failure.tooLarge }
        // Never repair invalid UTF-8 before hashing it.
        guard String(data: data, encoding: .utf8) != nil else { throw Failure.invalidUnicode }
        var parser = Parser(bytes: Array(data))
        let result = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.index == parser.bytes.count else { throw Failure.malformed }
        return Data(result)
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var next: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func whitespace() {
            while let byte = next, [9, 10, 13, 32].contains(byte) { index += 1 }
        }

        mutating func take(_ byte: UInt8) -> Bool {
            guard next == byte else { return false }
            index += 1
            return true
        }

        func bounded(_ bytes: [UInt8]) throws -> [UInt8] {
            guard bytes.count <= maximumBytes else { throw Failure.tooLarge }
            return bytes
        }

        mutating func value(depth: Int) throws -> [UInt8] {
            guard depth <= 32 else { throw Failure.tooDeep }
            whitespace()
            guard let byte = next else { throw Failure.malformed }
            switch byte {
            case 34:
                let decoded = try string()
                return try quoted(decoded)
            case 123: return try object(depth: depth)
            case 91:
                index += 1
                whitespace()
                var output: [UInt8] = [91]
                if take(93) { return [91, 93] }
                while true {
                    output += try value(depth: depth + 1)
                    _ = try bounded(output)
                    whitespace()
                    if take(93) { output.append(93); return try bounded(output) }
                    guard take(44) else { throw Failure.malformed }
                    output.append(44)
                }
            case 116: return try literal("true")
            case 102: return try literal("false")
            case 110: return try literal("null")
            case 45, 48...57: return try integer()
            default: throw Failure.malformed
            }
        }

        mutating func literal(_ text: String) throws -> [UInt8] {
            let token = Array(text.utf8)
            guard index + token.count <= bytes.count,
                  bytes[index..<(index + token.count)].elementsEqual(token) else {
                throw Failure.malformed
            }
            index += token.count
            return token
        }

        mutating func integer() throws -> [UInt8] {
            let start = index
            let negative = take(45)
            if take(48) {
                guard !negative else { throw Failure.nonInteger }
                if let byte = next, (48...57).contains(byte) { throw Failure.malformed }
            } else {
                guard let byte = next, (49...57).contains(byte) else { throw Failure.malformed }
                while let byte = next, (48...57).contains(byte) {
                    index += 1
                    guard index - start <= maximumBytes else { throw Failure.tooLarge }
                }
            }
            if let byte = next, [46, 69, 101].contains(byte) { throw Failure.nonInteger }
            // Decimal digits never pass through Double, Int64 or NSNumber.
            return try bounded(Array(bytes[start..<index]))
        }

        mutating func object(depth: Int) throws -> [UInt8] {
            index += 1
            whitespace()
            if take(125) { return [123, 125] }
            var members: [(key: [UInt8], encodedKey: [UInt8], value: [UInt8])] = []
            var seen = Set<Data>()
            var size = 2
            while true {
                whitespace()
                let key = try string()
                // Swift String/Dictionary equality normalizes Unicode. Data does not.
                guard seen.insert(Data(key)).inserted else { throw Failure.duplicateKey }
                let encodedKey = try quoted(key)
                whitespace()
                guard take(58) else { throw Failure.malformed }
                let child = try value(depth: depth + 1)
                size += encodedKey.count + 1 + child.count + (members.isEmpty ? 0 : 1)
                guard size <= maximumBytes else { throw Failure.tooLarge }
                members.append((key, encodedKey, child))
                whitespace()
                if take(125) { break }
                guard take(44) else { throw Failure.malformed }
            }
            members.sort { $0.key.lexicographicallyPrecedes($1.key) }
            var output: [UInt8] = [123]
            for (offset, member) in members.enumerated() {
                if offset > 0 { output.append(44) }
                output += member.encodedKey
                output.append(58)
                output += member.value
            }
            output.append(125)
            return output
        }

        mutating func hexQuad() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let byte = next else { throw Failure.malformed }
                index += 1
                let digit: UInt32
                switch byte {
                case 48...57: digit = UInt32(byte - 48)
                case 65...70: digit = UInt32(byte - 55)
                case 97...102: digit = UInt32(byte - 87)
                default: throw Failure.malformed
                }
                value = value * 16 + digit
            }
            return value
        }

        mutating func string() throws -> [UInt8] {
            guard take(34) else { throw Failure.malformed }
            var output: [UInt8] = []
            while let byte = next {
                index += 1
                if byte == 34 { return try bounded(output) }
                guard byte >= 32 else { throw Failure.malformed }
                if byte == 92 {
                    guard let escape = next else { throw Failure.malformed }
                    index += 1
                    switch escape {
                    case 34, 47, 92: output.append(escape)
                    case 98: output.append(8)
                    case 116: output.append(9)
                    case 110: output.append(10)
                    case 102: output.append(12)
                    case 114: output.append(13)
                    case 117:
                        var scalar = try hexQuad()
                        if (0xD800...0xDBFF).contains(scalar) {
                            guard take(92), take(117) else { throw Failure.invalidUnicode }
                            let low = try hexQuad()
                            guard (0xDC00...0xDFFF).contains(low) else { throw Failure.invalidUnicode }
                            scalar = 0x10000 + (scalar - 0xD800) * 1024 + low - 0xDC00
                        }
                        guard let character = UnicodeScalar(scalar) else { throw Failure.invalidUnicode }
                        output += String(character).utf8
                    default: throw Failure.malformed
                    }
                } else {
                    output.append(byte)
                }
                guard output.count <= maximumBytes else { throw Failure.tooLarge }
            }
            throw Failure.malformed
        }

        func quoted(_ string: [UInt8]) throws -> [UInt8] {
            let hex = Array("0123456789abcdef".utf8)
            var output: [UInt8] = [34]
            for byte in string {
                switch byte {
                case 34, 92: output += [92, byte]
                case 8: output += [92, 98]
                case 9: output += [92, 116]
                case 10: output += [92, 110]
                case 12: output += [92, 102]
                case 13: output += [92, 114]
                case 0...31: output += [92, 117, 48, 48, hex[Int(byte / 16)], hex[Int(byte % 16)]]
                default: output.append(byte)
                }
                guard output.count < maximumBytes else { throw Failure.tooLarge }
            }
            output.append(34)
            return try bounded(output)
        }
    }
}
