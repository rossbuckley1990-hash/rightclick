import Foundation
let marker = URL(fileURLWithPath: CommandLine.arguments[1])
let port = try String(contentsOf: marker, encoding: .utf8)
let address = URL(string: "http://127.0.0.1:" + port)!
print("markerBytes=\(port.utf8.count) hostPresent=\(address.host != nil) portPresent=\(address.port != nil)")
print(address.port!)
