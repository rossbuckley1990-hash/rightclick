import Foundation

/// A fail-closed, provider-scoped repair for UTF-8 bytes misread as Windows-1252.
///
/// Some installed macOS text Services emit corrupted pasteboard strings like
/// "cafÃ©" for "café". The caller still sees accurate Unicode before the
/// NSPerformService boundary. This preserves a valid returned-text observation
/// without changing unrelated Services or pretending to fix the external app.
///
/// Deliberately conservative: only the observed Apple text-converter provider,
/// only a complete reverse mapping, only valid UTF-8, and no changes to
/// already-identical input/output. Invalid or ambiguous output passes through.
enum NativeServiceUnicodeBoundary {
    static func repaired(
        _ output: String,
        input: String?,
        bundleIdentifier: String?
    ) -> String {
        guard bundleIdentifier == "com.apple.ChineseTextConverterService" else {
            return output
        }
        if let input, input == output { return output }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(output.utf8.count)

        for scalar in output.unicodeScalars {
            let value = scalar.value
            if value < 0x80 || (value >= 0xA0 && value <= 0xFF)
                || [0x81, 0x8D, 0x8F, 0x90, 0x9D].contains(value) {
                bytes.append(UInt8(value))
            } else if let mapped = specialWindows1252Byte(value) {
                bytes.append(mapped)
            } else {
                return output
            }
        }

        guard let candidate = String(bytes: bytes, encoding: .utf8),
              candidate != output,
              candidate.unicodeScalars.contains(where: { $0.value > 0x7F })
        else {
            return output
        }

        return candidate
    }

    private static func specialWindows1252Byte(_ value: UInt32) -> UInt8? {
        // Undefined Windows-1252 byte values are intentionally not guessed.
        switch value {
        case 0x20AC: return 0x80 // €
        case 0x201A: return 0x82
        case 0x0192: return 0x83
        case 0x201E: return 0x84
        case 0x2026: return 0x85
        case 0x2020: return 0x86
        case 0x2021: return 0x87
        case 0x02C6: return 0x88
        case 0x2030: return 0x89
        case 0x0160: return 0x8A
        case 0x2039: return 0x8B
        case 0x0152: return 0x8C
        case 0x017D: return 0x8E
        case 0x2018: return 0x91
        case 0x2019: return 0x92
        case 0x201C: return 0x93
        case 0x201D: return 0x94
        case 0x2022: return 0x95
        case 0x2013: return 0x96
        case 0x2014: return 0x97
        case 0x02DC: return 0x98
        case 0x2122: return 0x99
        case 0x0161: return 0x9A
        case 0x203A: return 0x9B
        case 0x0153: return 0x9C
        case 0x017E: return 0x9E
        case 0x0178: return 0x9F
        default: return nil
        }
    }
}
