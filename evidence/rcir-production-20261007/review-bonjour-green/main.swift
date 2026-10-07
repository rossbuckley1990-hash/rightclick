import Foundation
@testable import RightClickCore
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let entered = DispatchSemaphore(value: 0)
let unblock = DispatchSemaphore(value: 0)
let finished = DispatchSemaphore(value: 0)
let loaderLock = NSLock()
var loads = 0
let schema: [String:Any] = ["type":"object", "additionalProperties":false, "required":["id","value"], "properties":["id":["type":"string"],"value":["type":"string"]]]
let content: [String:Any] = ["application/json":["schema":schema]]
let spec = try JSONSerialization.data(withJSONObject: ["openapi":"3.0.3", "info":["title":"race", "version":"1"], "paths":["/records":["post":["operationId":"writeRecord", "requestBody":["required":true, "content":content], "responses":["200":["description":"accepted", "content":content]]]]]], options: [.sortedKeys])
let provider = Process(); provider.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
provider.arguments = [CommandLine.arguments[2], out.path]
provider.standardOutput = FileHandle.nullDevice; provider.standardError = FileHandle.nullDevice
try provider.run()
defer { if provider.isRunning { provider.terminate(); provider.waitUntilExit() } }
let portURL=out.appendingPathComponent("port")
for _ in 0..<300 { if FileManager.default.fileExists(atPath:portURL.path) { break }; Thread.sleep(forTimeInterval:0.01) }
let port=Int(try String(contentsOf:portURL, encoding:.utf8))!
let descriptor=BonjourOpenAPIServiceDescriptor(instanceName:"review-race",serviceType:BonjourOpenAPISource.serviceType,domain:"local.",host:"127.0.0.1",port:port,txt:["kind":"openapi","scheme":"http","spec":"/openapi.json","base":"/"])
let source=BonjourOpenAPISource(startBrowsing:false, specificationLoader: { _ in
    loaderLock.lock(); loads += 1; let count=loads; loaderLock.unlock()
    if count == 2 { entered.signal(); _ = unblock.wait(timeout:.now()+5) }
    return spec
})
source.update(resolved:descriptor)
let host=RCIRExecutionHost()
let engine=CapabilityEngine(reflectorSources:[source],experience:nil,rcirHost:host)
let capability=try engine.capabilities(for:"disposable").capabilities.first!
host.beforeConsume={ _ in
    DispatchQueue.global().async { source.update(resolved:descriptor); finished.signal() }
    precondition(entered.wait(timeout:.now()+5) == .success)
    source.remove(instanceName:descriptor.instanceName,serviceType:descriptor.serviceType,domain:descriptor.domain)
    print("catalog immediately after removal = \(source.reflectors().count)")
    unblock.signal(); precondition(finished.wait(timeout:.now()+5) == .success)
    print("catalog after obsolete acquisition = \(source.reflectors().count)")
}
let result=try engine.begin(id:capability.id,item:"disposable",confirmed:true,arguments:["id":"review-race", "value":"requested"])
print("execution state = \(result.state.rawValue), RCIR outcome = \(result.rcir?.outcome ?? "nil")")
let effects=(try? String(contentsOf:out.appendingPathComponent("effects.jsonl"),encoding:.utf8)) ?? ""
print("actual provider effects = \(effects.split(separator:"\n").count)")
