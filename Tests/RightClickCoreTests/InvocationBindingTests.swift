import Foundation
import XCTest
@testable import RightClickCore

/// Controlled stale observations expose a causal binding deficiency. These are
/// shared-runtime regressions, never claims of genuine Kafka/Kubernetes GREEN.
final class InvocationBindingTests: XCTestCase {
    private func fixture(mode: String, substrate: String) throws -> (URL, [String: String]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("invocation-binding-" + UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(directory)
        try Data(mode.utf8).write(to: directory.appendingPathComponent("mode"))
        let repository = ProcessInfo.processInfo.environment["RIGHTCLICK_BINDING_TEST_ROOT"] ??
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let template = try String(contentsOfFile: repository + "/Tests/Fixtures/invocation-binding-client.py", encoding: .utf8)
        let encoded = Data(directory.path.utf8).base64EncodedString()
        let script = directory.appendingPathComponent("client-script.py")
        try NativeHTTPFixture.writePrivate(Data(template.replacingOccurrences(of: "__STATE_DIRECTORY_BASE64__", with: encoded).utf8), to: script)
#if os(Windows)
        let client = try NativeHTTPFixture.pythonClient(script: script, directory: directory)
#else
        let client = script
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: client.path)
#endif
        var environment: [String: String] = [:]
        for principal in ["writer", "reader"] {
            let reference = directory.appendingPathComponent(principal + ".json")
            let config: [String: Any]
            if substrate == "kafka" {
                config = ["rpk": ["kafka_api": ["brokers": ["127.0.0.1:19092"],
                    "sasl": ["user": principal, "password": "controlled-test-only", "mechanism": "SCRAM-SHA-256"]]]]
            } else {
                let claims = try JSONSerialization.data(withJSONObject: ["exp": Int64(Date().timeIntervalSince1970) + 3_600])
                let token = "fixture." + claims.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".untrusted"
                config = ["apiVersion": "v1", "kind": "Config", "current-context": "proof",
                    "clusters": [["name": "proof", "cluster": ["server": "https://127.0.0.1:16443", "certificate-authority-data": Data("controlled-CA".utf8).base64EncodedString()]]],
                    "contexts": [["name": "proof", "context": ["cluster": "proof", "user": principal, "namespace": "rightclick-proof"]]],
                    "users": [["name": principal, "user": ["token": token]]]]
            }
            try NativeHTTPFixture.writePrivate(JSONSerialization.data(withJSONObject: config), to: reference)
            let key = substrate == "kafka" ? (principal == "writer" ? "RIGHTCLICK_KAFKA_PUBLISHER_CONFIG" : "RIGHTCLICK_KAFKA_OBSERVER_CONFIG") :
                (principal == "writer" ? "RIGHTCLICK_KUBERNETES_WRITER_CONFIG" : "RIGHTCLICK_KUBERNETES_OBSERVER_CONFIG")
            environment[key] = reference.path
        }
        environment[substrate == "kafka" ? "RIGHTCLICK_KAFKA_CLIENT" : "RIGHTCLICK_KUBERNETES_CLIENT"] = client.path
        environment["RIGHTCLICK_KUBERNETES_NAMESPACE"] = "rightclick-proof"
        return (directory, environment)
    }
    private func exercise(_ substrate: String, mode: String) throws -> ExecutionRecord {
        let (directory, environment) = try fixture(mode: mode, substrate: substrate)
        defer { try? NativeHTTPFixture.remove(directory) }
        let endpoint = substrate == "kafka" ? "kafka://127.0.0.1:19092" : "https://127.0.0.1:16443"
        let descriptor = CapabilityArtifactDescriptor(id: "controlled", kind: substrate, endpointURL: endpoint)
        let reflector = try substrate == "kafka" ? KafkaCapabilityArtifactResolver(environment: environment).resolve(descriptor) :
            KubernetesCapabilityArtifactResolver(environment: environment).resolve(descriptor)
        let item = try ContentParser.parse("controlled causality")
        let capability = try XCTUnwrap(reflector.capabilities(for: item).first)
        let arguments = substrate == "kafka" ? ["key": "repeated-challenge", "payload": "matching-prior-value"] :
            ["name": "repeated-name", "challenge": "repeated-challenge", "value": "matching-prior-value"]
        return try reflector.begin(capability: capability, item: item, executionID: UUID().uuidString, arguments: arguments)
    }
    func testMatchingStaleKafkaRecordCannotVerifyCurrentAppend() throws {
        let record = try exercise("kafka", mode: "stale")
        XCTAssertEqual(record.state, .failed)
        XCTAssertEqual(record.rcir?.outcome, "failed")
        XCTAssertFalse(record.evidence.outcomeVerified)
    }
    func testMatchingStaleKubernetesResourceCannotVerifyCurrentCreate() throws {
        let record = try exercise("kubernetes", mode: "stale")
        XCTAssertEqual(record.state, .failed)
        XCTAssertEqual(record.rcir?.outcome, "failed")
        XCTAssertFalse(record.evidence.outcomeVerified)
    }
    func testFreshMarkersVerifyForBothTransports() throws {
        for substrate in ["kafka", "kubernetes"] {
            let record = try exercise(substrate, mode: "fresh")
            XCTAssertEqual(record.state, .succeeded, record.message)
            XCTAssertEqual(record.rcir?.outcome, "succeeded")
            let receipt = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(record.rcir?.receipt)))
            let taskID = try XCTUnwrap(record.rcir?.taskID)
            XCTAssertNotNil(receipt.range(of: Data(taskID.utf8)))
        }
    }
    func testRelativeHostClientPathFailsBeforeNativeDispatch() throws {
        for path in ["client.exe", "C:client.exe", ""] {
            let environment = ["RIGHTCLICK_KUBERNETES_CLIENT": path,
                "RIGHTCLICK_KUBERNETES_WRITER_CONFIG": "unopened-writer", "RIGHTCLICK_KUBERNETES_OBSERVER_CONFIG": "unopened-observer",
                "RIGHTCLICK_KUBERNETES_NAMESPACE": "rightclick-proof"]
            XCTAssertThrowsError(try KubernetesCapabilityArtifactResolver(environment: environment)
                .resolve(.init(id: "relative-denied", kind: "kubernetes", endpointURL: "https://127.0.0.1:16443"))) { error in
                guard case CapabilityArtifactResolutionError.invalidDescriptor = error else {
                    return XCTFail("Relative host selection must fail at the descriptor boundary.")
                }
            }
        }
    }
}
