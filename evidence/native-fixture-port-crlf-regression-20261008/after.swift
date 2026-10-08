import Foundation
private enum NativeHTTPFixture {
 private static let captureLock = NSLock()
 private final class Capture { func requestRetention() {} }
 private static var captures: [ObjectIdentifier: Capture] = [:]
    enum ReadinessError: Error {
        case exitedBeforeReadiness
        case invalidPortBeforeDeadline
    }
    /// A marker's existence is not readiness: a writer can create an empty
    /// file before completing its bytes. Bound both time and input size, and
    /// return only a decimal TCP port; never construct an incomplete URL.
    static func waitForPort(_ file: URL, process: Process, timeout: TimeInterval = 3) throws -> UInt16 {
        var ready = false
        defer {
            captureLock.lock(); let capture = captures.removeValue(forKey: ObjectIdentifier(process)); captureLock.unlock()
            if !ready { capture?.requestRetention() }
        }
        guard timeout > 0, timeout <= 3 else { throw ReadinessError.invalidPortBeforeDeadline }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard process.isRunning else { throw ReadinessError.exitedBeforeReadiness }
            if let handle = try? FileHandle(forReadingFrom: file) {
                defer { try? handle.close() }
                // Five decimal digits plus CRLF is the longest valid marker.
                // Read one more byte so a valid prefix cannot hide trailing data.
                if let bytes = try? handle.read(upToCount: 8) {
                    let digits: Data.SubSequence
                    if bytes.suffix(2).elementsEqual([13, 10]) { digits = bytes.dropLast(2) }
                    else if bytes.last == 10 { digits = bytes.dropLast() }
                    else { digits = bytes[...] }
                    if !digits.isEmpty, digits.count <= 5,
                       digits.allSatisfy({ (48...57).contains($0) }),
                       let port = UInt16(String(decoding: digits, as: UTF8.self)), port > 0 {
                        ready = true; return port
                    }
                }
            }
            Thread.sleep(forTimeInterval: min(0.01, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
        }
        throw ReadinessError.invalidPortBeforeDeadline
    }

}
let temporary = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
let marker=temporary.appendingPathComponent("marker")
let process=Process();process.executableURL=URL(fileURLWithPath:"/bin/sleep");process.arguments=["5"]
try process.run()
defer { if process.isRunning { process.terminate();process.waitUntilExit() };try? FileManager.default.removeItem(at:temporary) }
let cases:[(String,UInt16?)]=[("1",1),("65535",65535),("1\n",1),("65535\n",65535),("1\r\n",1),("65535\r\n",65535),("",nil),("0",nil),("65536",nil),("12345suffix",nil),("-1",nil),("12345\nextra",nil),("65535\r",nil),("65535\r\r\n",nil),("65535\r\nextra",nil),("65535\r\n0",nil),("12345\r\nextra",nil),(" 1",nil),("1 ",nil)]
var results:[[String:Any]]=[]
for (value,expected) in cases {
 try Data(value.utf8).write(to:marker)
 let started=ProcessInfo.processInfo.systemUptime
 var actual:UInt16?=nil
 do { actual=try NativeHTTPFixture.waitForPort(marker,process:process,timeout:0.05) } catch {}
 results.append(["inputHex":value.utf8.map{String(format:"%02x",$0)}.joined(),"expected":expected.map{Int($0)} ?? -1,"actual":actual.map{Int($0)} ?? -1,"pass":actual==expected,"elapsed":ProcessInfo.processInfo.systemUptime-started])
}
let passed=results.filter{$0["pass"] as? Bool==true}.count
let report:[String:Any] = ["cases":results,"pass":passed,"fail":cases.count-passed,"scope":"Exact production fixture waitForPort body extracted with empty capture plumbing; actual native Foundation FileHandle/Process/temp markers. Not full integrated fixture/Windows proof."]
let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([10]))
