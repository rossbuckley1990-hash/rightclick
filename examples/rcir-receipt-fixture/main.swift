import Foundation

// Compile with the exact Foundation-only ABI/RCIR sources. This fixture is NOT
// the production RIGHTCLICK engine and is not the seven-operation agent demo.
struct FileObserver: RCIRObserver {
    let observerID = "observer:fixture-file"
    func observe(_ request: RCIRObservationRequest) throws -> CapabilityValue {
        guard case let .object(arguments) = request.arguments,
              case let .string(path)? = arguments["target"] else { throw RCIRError.invalidContract }
        return .string(try String(contentsOfFile: path, encoding: .utf8))
    }
}

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 5 else { throw RCIRError.invalidContract }
    let python = args[0], producer = args[1], target = args[2], output = args[3], actual = args[4]
    let expected = "RCIR external result verified"
    let arguments = CapabilityValue.object(["target": .string(target), "value": .string(actual)])
    let scope = RCIRScope(target, .write)
    let abi = CapabilityContract(capabilityID: "local-fixture:write", reflectorID: "local-fixture",
                                 providerID: "local-fixture-process",
                                 arguments: .object(properties: ["target": .string, "value": .string], required: ["target", "value"]),
                                 result: .string, declaration: .string("Explicit local process fixture; no live protocol claim"))
    let contract = RCIRContract(abi: abi, scopes: [scope], task: .init(shape: .deferred),
                                verification: .init(observerID: "observer:fixture-file", schema: .string, expected: .string(expected)))
    let admission = RCIRAdmission()
    let binding = try admission.publish(contract, authenticatedPrincipal: "fixture:host-owned-child")
    let policy = RCIRPolicy(revision: "fixture-policy-1", principals: ["fixture:host-owned-child"], scopes: [scope])
    func now() -> Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }
    let issued = now()
    let lease = try admission.issue(binding, arguments: arguments, authority: [scope], policy: policy, now: issued)
    try admission.consume(lease, arguments: arguments, authority: [scope], policy: policy, now: now())
    var task = try RCIRTask(lease: lease, startedAt: now(), deadline: issued + 60_000)
    try task.record(.accepted, sequence: 1, now: now())
    try task.record(.working, sequence: 2, now: now())
    let process = Process()
    process.executableURL = URL(fileURLWithPath: python)
    process.arguments = [producer, target, actual]
    // The only child is the bundled bounded fixture, not an arbitrary provider command.
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw RCIRError.invalidTransition }
    // An exit code or provider statement alone must remain semantically unverified.
    try task.record(.completed(.string("provider accepted")), sequence: 3, now: now())
    guard task.outcome == .unverified else { throw RCIRError.invalidTransition }
    let before = task.outcome.rawValue
    try task.verify(using: FileObserver(), now: now())
    try task.receiptData().write(to: URL(fileURLWithPath: output), options: .atomic)
    admission.withdraw(providerID: "local-fixture-process")
    var staleRejected = false
    do { _ = try admission.issue(binding, arguments: arguments, authority: [scope], policy: policy, now: now()) }
    catch { staleRejected = true }
    let report: [String: Any] = [
        "scope": "Local fixture: separate producer process and independent file observation",
        "providerCompletionOutcome": before, "externalObservationOutcome": task.outcome.rawValue,
        "graphCountAfterRemoval": admission.discover().count, "staleBindingRejected": staleRejected,
        "productionEngine": false, "elevenSubstrateProof": "NOT_RUN", "sevenOperationAgentProof": "NOT_RUN"
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
    print(String(decoding: data, as: UTF8.self))
}

do { try run() } catch {
    FileHandle.standardError.write(Data("Fixture failed: \(error)\n".utf8))
    exit(1)
}
