import Foundation
import Dispatch

let count = 1000
let scope = RCIRScope("urn:benchmark:resource", .write)
let arguments = CapabilityValue.integer(1)
let contract = RCIRContract(abi:.init(capabilityID:"benchmark:write",reflectorID:"benchmark",providerID:"provider:benchmark",
    arguments:.integer,result:.integer,declaration:.string("fixed benchmark")),scopes:[scope])
let policy = RCIRPolicy(revision:"benchmark-policy",principals:["provider:benchmark"],scopes:[scope])
func run(delegated: Bool) throws -> UInt64 {
    let admission = RCIRAdmission(), binding = try admission.publish(contract,authenticatedPrincipal:"provider:benchmark")
    let alice = try RCIRAuthorityIdentity("agent:alice"), bob = try RCIRAuthorityIdentity("agent:bob"), audience = try RCIRAuthorityIdentity("runtime:benchmark")
    let parentRequest = RCIRAuthorityRequest(subject:alice,audiences:[audience],targets:[try .init(binding)],scopes:[scope],expiresAt:1000,invocationLimit:count,delegationDepth:1)
    let parent = try admission.issueAuthority(parentRequest,issuer:.init("issuer:benchmark"),now:100)
    let childRequest = RCIRAuthorityRequest(subject:bob,audiences:[audience],targets:[try .init(binding)],scopes:[scope],arguments:try .oneOf([arguments]),expiresAt:900,invocationLimit:count,delegationDepth:0)
    let child = try admission.attenuate(parent,request:childRequest,authenticated:.init(authenticatedSubject:alice,audience:audience),now:100)
    let context = RCIRAuthorityContext(authenticatedSubject:bob,audience:audience)
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<count {
        if delegated {
            let lease = try admission.issue(binding,arguments:arguments,grant:child,authenticated:context,policy:policy,now:100)
            try admission.consume(lease,arguments:arguments,grant:child,authenticated:context,policy:policy,now:100)
        } else {
            let lease = try admission.issue(binding,arguments:arguments,authority:[scope],policy:policy,now:100)
            try admission.consume(lease,arguments:arguments,authority:[scope],policy:policy,now:100)
        }
    }
    return DispatchTime.now().uptimeNanoseconds - start
}
let baseline = try (0..<5).map { _ in try run(delegated:false) }.sorted()
let delegated = try (0..<5).map { _ in try run(delegated:true) }.sorted()
let result: [String:Any] = ["scope":"Optimized exact-source in-process lease issue+consume; no transport or signing",
    "invocationsPerSample":count,"samples":5,"baselineTrustedScopeNanoseconds":baseline,
    "delegatedParentChildNanoseconds":delegated,
    "baselineMedianNanosecondsPerInvocation":Double(baseline[2])/Double(count),
    "delegatedMedianNanosecondsPerInvocation":Double(delegated[2])/Double(count)]
print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]),as:UTF8.self))
