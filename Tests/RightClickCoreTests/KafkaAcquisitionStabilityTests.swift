import Foundation
import XCTest
@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders

/// Real scoped metadata only: no broker restart, credentials/ACL mutation,
/// record production or timeout widening. A failed invariant retains timings.
final class KafkaAcquisitionStabilityTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var diagnostics: [KafkaCapabilityArtifactResolver.Diagnostic] = []
        var checks: [[String: String]] = []
        func append(_ value: KafkaCapabilityArtifactResolver.Diagnostic) {
            lock.lock(); defer { lock.unlock() }; diagnostics.append(value)
        }
        func check(_ stage: String, _ outcome: String) {
            lock.lock(); defer { lock.unlock() }; checks.append(["stage": stage, "outcome": outcome])
        }
        func failureCount() -> Int {
            lock.lock(); defer { lock.unlock() }; return checks.filter { $0["outcome"] == "failed" }.count
        }
        func persist(_ directory: String, _ name: String) throws {
            lock.lock(); defer { lock.unlock() }
            let output = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let encoded = try JSONEncoder().encode(diagnostics)
            let object: [String: Any] = ["runKind": "REAL_KAFKA_READ_ONLY_ACQUISITION_PROBE",
                "capturedUTC": ISO8601DateFormatter().string(from: Date()), "checks": checks,
                "diagnostics": try JSONSerialization.jsonObject(with: encoded),
                "metadataLoadWorkers": name == "five-client-fresh-acquisition" ? 4 : (name == "fresh-acquisition-concurrent" ? 3 : (name == "metadata-concurrent" ? 2 : 0)),
                "freshSnapshotLoad": name == "fresh-acquisition-concurrent" || name == "five-client-fresh-acquisition",
                "brokerMutation": false, "credentialMutation": false, "processTimeoutSeconds": 5]
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent(name + ".json"))
        }
    }
    private func environment() throws -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        guard env["RIGHTCLICK_KAFKA_STABILITY"] == "1", env["RIGHTCLICK_KAFKA_CLIENT"] != nil,
            env["RIGHTCLICK_KAFKA_PUBLISHER_CONFIG"] != nil, env["RIGHTCLICK_KAFKA_OBSERVER_CONFIG"] != nil else {
            throw XCTSkip("Real scoped Kafka stability probe not provisioned; no stability GREEN claimed.")
        }
        return env
    }
    func testRealMetadataReadinessAndByteBindingCostWithoutConcurrentLoad() throws { try probe(load: false) }
    func testRealMetadataReadinessDuringBoundedConcurrentMetadataLoad() throws { try probe(load: true) }
    func testRealReadinessDuringBoundedConcurrentFreshAcquisition() throws { try probe(load: true, fresh: true) }
    func testRealReadinessDuringFiveFreshClients() throws { try probe(load: true, fresh: true, freshWorkers: 4) }

    private func probe(load: Bool, fresh: Bool = false, freshWorkers: Int = 3) throws {
        let env = try environment(), recorder = Recorder()
        let name = freshWorkers == 4 ? "five-client-fresh-acquisition" : (fresh ? "fresh-acquisition-concurrent" : (load ? "metadata-concurrent" : "metadata-isolated"))
        defer { if let directory = env["RIGHTCLICK_KAFKA_STABILITY_EVIDENCE"] { try? recorder.persist(directory, name) } }
        let resolver = KafkaCapabilityArtifactResolver(environment: env, diagnostic: recorder.append)
        let descriptor = CapabilityArtifactDescriptor(id: "stability", kind: "kafka", endpointURL: "kafka://127.0.0.1:19092")
        let item = try ContentParser.parse("Read-only Kafka metadata stability probe")
        let workers = DispatchGroup()
        if load {
            for _ in 0..<(fresh ? freshWorkers : 2) {
                workers.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { workers.leave() }
                    for _ in 0..<(fresh ? 2 : 4) {
                        do {
                            if fresh {
                                let acquired = try KafkaCapabilityArtifactResolver(environment: env, diagnostic: recorder.append).resolve(descriptor)
                                let ready = try acquired.capabilities(for: item).contains { $0.id.hasSuffix(":publish.rightclick.proof") }
                                recorder.check("load-worker-fresh-acquisition", ready ? "completed" : "failed")
                                continue
                            }
                            _ = try BoundedCapabilityProcess.run(executable: URL(fileURLWithPath: env["RIGHTCLICK_KAFKA_CLIENT"]!),
                                arguments: ["--config", env["RIGHTCLICK_KAFKA_PUBLISHER_CONFIG"]!, "topic", "list", "--format", "json"],
                                diagnostic: { recorder.append(.init(stage: .controlMetadataProcess, elapsedMilliseconds: $0.elapsedMilliseconds,
                                    succeeded: $0.outcome == .completed, process: $0)) })
                            recorder.check("load-worker-metadata", "completed")
                        } catch { recorder.check("load-worker-metadata", "failed") }
                    }
                }
            }
        }
        defer { _ = workers.wait(timeout: .now() + 25) }
        for round in 0..<3 {
            let reflector: any CapabilityReflector
            do { reflector = try resolver.resolve(descriptor); recorder.check("resolve-\(round)", "completed") }
            catch { recorder.check("resolve-\(round)", "failed"); throw error }
            for check in 0..<3 {
                let capabilities = try reflector.capabilities(for: item)
                let ready = capabilities.contains { $0.id.hasSuffix(":publish.rightclick.proof") }
                recorder.check("capabilities-\(round)-\(check)", ready ? "ready" : "missing")
                XCTAssertTrue(ready, "Actual scoped metadata capability disappeared; retained acquisition/process timings establish only this probe's cause.")
                XCTAssertEqual(reflector.providers().count, 1)
            }
        }
        XCTAssertEqual(workers.wait(timeout: .now() + 25), .success)
        XCTAssertEqual(recorder.failureCount(), 0, "Actual bounded metadata worker failed; inspect retained diagnostics without inferring the historical cause.")
    }
}
