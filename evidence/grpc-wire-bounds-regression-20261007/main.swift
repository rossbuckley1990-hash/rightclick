import Foundation
let length = CommandLine.arguments.count == 1
var reader = GRPCWireReader(length ? Data(Array(repeating: UInt8(255), count: 8) + [UInt8(127)]) : Data(Array(repeating: UInt8(255), count: 9) + [UInt8(126)]))
do { if length { _ = try reader.readLengthDelimited() } else { _ = try reader.readVarint() }; print("unexpected_success"); exit(2) }
catch { print("bounded_encoding_rejected"); exit(0) }
