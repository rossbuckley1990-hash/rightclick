import Foundation
import XCTest
@testable import RightClickCore

final class KubernetesCapabilityArtifactTests: XCTestCase {
    private let descriptor = CapabilityArtifactDescriptor(id: "proof-cluster", kind: "kubernetes", endpointURL: "https://127.0.0.1:16443")

    func testProviderDescriptorCannotSelectExecutableCredentialOrNamespace() throws {
        let resolver = KubernetesCapabilityArtifactResolver(environment: [:])
        XCTAssertThrowsError(try resolver.resolve(descriptor))
        XCTAssertThrowsError(try resolver.resolve(.init(id: "provider", kind: "kubernetes", endpointURL: "http://127.0.0.1:16443")))
        XCTAssertThrowsError(try resolver.resolve(.init(id: "provider", kind: "kubernetes", endpointURL: "https://user:secret@127.0.0.1:16443")))
        XCTAssertThrowsError(try resolver.resolve(.init(id: "provider", kind: "kubernetes", endpointURL: "https://127.0.0.1:16443", authorityScheme: "admin")))
    }

    func testCredentialPluginsAndTLSBypassAreRejectedBeforeAcquisition() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kube-negative-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for malicious: [String: Any] in [["user": ["exec": ["command": "/bin/echo", "args": ["never-authorized"]]]],
                                        ["cluster": ["server": "https://127.0.0.1:16443", "insecure-skip-tls-verify": true]]] {
            var config: [String: Any] = ["apiVersion": "v1", "kind": "Config", "current-context": "proof",
                "clusters": [["name": "proof", "cluster": ["server": "https://127.0.0.1:16443", "certificate-authority-data": Data("not-a-real-CA".utf8).base64EncodedString()]]],
                "contexts": [["name": "proof", "context": ["cluster": "proof", "user": "proof", "namespace": "rightclick-proof"]]],
                "users": [["name": "proof", "user": ["token": "never-authenticated"]]]]
            if let user = malicious["user"] { config["users"] = [["name": "proof", "user": user]] }
            if let cluster = malicious["cluster"] { config["clusters"] = [["name": "proof", "cluster": cluster]] }
            let writer = directory.appendingPathComponent("writer.json"), reader = directory.appendingPathComponent("reader.json")
            let bytes = try JSONSerialization.data(withJSONObject: config)
            try bytes.write(to: writer); try bytes.write(to: reader)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: writer.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reader.path)
            let resolver = KubernetesCapabilityArtifactResolver(environment: ["RIGHTCLICK_KUBERNETES_CLIENT": "/usr/bin/true",
                "RIGHTCLICK_KUBERNETES_WRITER_CONFIG": writer.path, "RIGHTCLICK_KUBERNETES_OBSERVER_CONFIG": reader.path,
                "RIGHTCLICK_KUBERNETES_NAMESPACE": "rightclick-proof"])
            XCTAssertThrowsError(try resolver.resolve(descriptor))
        }
    }

    func testRealNamespaceResourceIsVerifiedThroughIndependentGETIdentity() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let writerPath = environment["RIGHTCLICK_TEST_KUBERNETES_WRITER_CONFIG"],
              let readerPath = environment["RIGHTCLICK_TEST_KUBERNETES_OBSERVER_CONFIG"],
              let client = environment["RIGHTCLICK_KUBERNETES_CLIENT"] else {
            throw XCTSkip("Genuine scoped Kubernetes provider not provisioned; this skip is not substrate GREEN.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kube-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = directory.appendingPathComponent("writer.json"), reader = directory.appendingPathComponent("reader.json")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: writerPath), to: writer)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: readerPath), to: reader)
        let reflector = try KubernetesCapabilityArtifactResolver(environment: ["RIGHTCLICK_KUBERNETES_CLIENT": client,
            "RIGHTCLICK_KUBERNETES_WRITER_CONFIG": writer.path, "RIGHTCLICK_KUBERNETES_OBSERVER_CONFIG": reader.path,
            "RIGHTCLICK_KUBERNETES_NAMESPACE": "rightclick-proof"]).resolve(descriptor)
        let item = try ContentParser.parse("genuine namespace pressure")
        let capability = try XCTUnwrap(reflector.capabilities(for: item).first)
        let name = "rightclick-native-" + UUID().uuidString.lowercased()
        let nonce = UUID().uuidString
        let literal = "literal $(echo never-executed) and `not-a-shell` " + nonce
        let record = try reflector.begin(capability: capability, item: item, executionID: UUID().uuidString,
            arguments: ["name": name, "challenge": nonce, "value": literal])
        XCTAssertEqual(record.state, .succeeded, record.message)
        XCTAssertEqual(record.rcir?.outcome, "succeeded"); XCTAssertEqual(record.rcir?.leaseConsumed, true)
        XCTAssertTrue(record.evidence.outcomeVerified)
        let encoded = try XCTUnwrap(record.rcir?.receipt)
        let payload = try XCTUnwrap(Data(base64Encoded: encoded))
        XCTAssertNotNil(payload.range(of: Data(literal.utf8)))
        XCTAssertNotNil(payload.range(of: Data("resourceVersion".utf8)))
        XCTAssertNotNil(payload.range(of: Data("uid".utf8)))
        try FileManager.default.removeItem(at: reader)
        XCTAssertTrue(try reflector.capabilities(for: item).isEmpty)
    }
}
