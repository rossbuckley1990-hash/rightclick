import Foundation
var max = GRPCWireReader(Data(Array(repeating: UInt8(255), count: 9) + [1]))
let maximum = try max.readVarint(); precondition(maximum == UInt64.max)
precondition(max.isAtEnd)
var overlong = GRPCWireReader(Data(Array(repeating: UInt8(255), count: 9) + [0]))
let signedMaximum = try overlong.readVarint(); precondition(signedMaximum == UInt64(Int64.max))
for last in UInt8(2)...UInt8.max {
    var r = GRPCWireReader(Data(Array(repeating: UInt8(255), count: 9) + [last]))
    do { _ = try r.readVarint(); fatalError("Overflowing varint accepted") }
    catch GRPCWireCodecError.malformedVarint { }
}
var large = GRPCWireReader(Data(Array(repeating: UInt8(255), count: 8) + [127]))
do { _ = try large.readLengthDelimited(); fatalError("Unbounded length accepted") }
catch GRPCWireCodecError.truncatedField { }
var valid = GRPCWireReader(Data([0,3,65,66,67,150,1]))
let empty = try valid.readLengthDelimited(); precondition(empty == Data())
let payload = try valid.readLengthDelimited(); precondition(payload == Data("ABC".utf8))
let following = try valid.readVarint(); precondition(following == 150)
precondition(valid.isAtEnd)
print("PASS raw UInt64.max, preserved overlong positive, 254 rejected tenth bytes, Int.max length and following cursor data")
