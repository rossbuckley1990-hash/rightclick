import Foundation

/// Produces a minimal RTF document without placing UTF-8 bytes under an ANSI
/// header. RTF Unicode escapes carry signed UTF-16 code units, including both
/// halves of a supplementary-plane scalar. This is a presentation encoding;
/// authority proofs must continue to use their canonical wire representation.
enum ServiceRTFEncoder {
    static func encode(_ text: String) -> Data {
        var rtf = "{\\rtf1\\ansi\\ansicpg1252\\uc1 "
        for unit in text.utf16 {
            switch unit {
            case 0x5c, 0x7b, 0x7d:
                rtf += "\\" + String(UnicodeScalar(UInt32(unit))!)
            case 0x0a:
                rtf += "\\par "
            case 0x09:
                rtf += "\\tab "
            case 0x20...0x7e:
                rtf += String(UnicodeScalar(UInt32(unit))!)
            default:
                rtf += "\\u\(Int16(bitPattern: unit))?"
            }
        }
        rtf += "}"
        return Data(rtf.utf8)
    }
}
