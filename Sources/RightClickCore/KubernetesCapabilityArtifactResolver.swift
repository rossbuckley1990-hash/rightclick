import Foundation

/// Narrow acquisition of genuine namespaced ConfigMap declarations. Executable,
/// TLS credential references, namespace and verifier are selected by the host;
/// provider descriptors and model arguments cannot widen those choices.
public final class KubernetesCapabilityArtifactResolver: CapabilityArtifactResolver {
    public let kind = "kubernetes"
    private let environment: [String: String]
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) { self.environment = environment }

    public func resolve(_ descriptor: CapabilityArtifactDescriptor) throws -> any CapabilityReflector {
        guard descriptor.kind == kind, descriptor.inlineData == nil, descriptor.authorityScheme == nil,
              descriptor.specificationURL == nil, descriptor.baseURL == nil,
              let raw = descriptor.endpointURL, let endpoint = URL(string: raw),
              endpoint.scheme == "https", endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil, endpoint.path.isEmpty || endpoint.path == "/",
              let path = environment["RIGHTCLICK_KUBERNETES_CLIENT"], RuntimePlatform.isAbsolutePath(path),
              let writerReference = environment["RIGHTCLICK_KUBERNETES_WRITER_CONFIG"],
              let observerReference = environment["RIGHTCLICK_KUBERNETES_OBSERVER_CONFIG"],
              writerReference != observerReference,
              let namespace = environment["RIGHTCLICK_KUBERNETES_NAMESPACE"], Self.validName(namespace, maximum: 63) else {
            throw CapabilityArtifactResolutionError.invalidDescriptor("Kubernetes requires a TLS endpoint and host-selected client, separate protected credentials and exact namespace.")
        }
        let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let client = try CapabilityArtifactSnapshot(source: executable, maximum: 268_435_456, executable: true)
        let writer = try KubernetesCredential(reference: writerReference, endpoint: endpoint, namespace: namespace)
        let reader = try KubernetesCredential(reference: observerReference, endpoint: endpoint, namespace: namespace)
        func command(_ credential: KubernetesCredential, _ arguments: [String], input: Data? = nil,
                     admit: ((_ start: () -> Void) throws -> Void)? = nil) throws -> Data {
            try BoundedCapabilityProcess.run(executable: client.file,
                arguments: ["--kubeconfig", credential.snapshot.file.path, "--namespace", namespace, "--request-timeout=3s"] + arguments,
                timeout: 5, input: input, admitStart: admit)
        }
        func principal(_ credential: KubernetesCredential) throws -> String {
            let data = try command(credential, ["auth", "whoami", "-o", "json"])
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = object["status"] as? [String: Any], let user = status["userInfo"] as? [String: Any],
                  let name = user["username"] as? String,
                  name.hasPrefix("system:serviceaccount:" + namespace + ":"), name.utf8.count <= 256 else { throw RCIRError.authorityDenied }
            return name
        }
        func permits(_ credential: KubernetesCredential, _ verb: String, namespace requested: String) throws -> Bool {
            // auth can-i exits 1 for a genuine denial. Its bounded process error
            // is therefore a denial, never an inferred grant.
            let data = try? command(credential, ["auth", "can-i", verb, "configmaps", "--namespace", requested])
            return data.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "yes" } ?? false
        }
        func acquire() throws -> [String: Any] {
            let data = try command(writer, ["get", "--raw", "/api/v1"])
            guard let list = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  list["kind"] as? String == "APIResourceList", list["groupVersion"] as? String == "v1",
                  let resources = list["resources"] as? [[String: Any]], resources.count <= 256,
                  let resource = resources.first(where: { $0["name"] as? String == "configmaps" }),
                  resource["kind"] as? String == "ConfigMap", resource["namespaced"] as? Bool == true,
                  let verbs = resource["verbs"] as? [String], verbs.contains("create"), verbs.contains("get") else { throw CapabilityABIError.invalidSchema }
            return resource
        }
        let writerPrincipal = try principal(writer), observerPrincipal = try principal(reader)
        guard writerPrincipal != observerPrincipal, try permits(writer, "create", namespace: namespace),
              try permits(reader, "get", namespace: namespace) else { throw RCIRError.authorityDenied }
        // The observer is independently issued GET-only authority, with no list,
        // watch or mutation authority. Refuse a broader observer credential.
        for verb in ["create", "update", "patch", "delete", "list", "watch"] {
            guard try !permits(reader, verb, namespace: namespace) else { throw RCIRError.authorityDenied }
        }
        guard namespace != "default", try !permits(writer, "create", namespace: "default") else { throw RCIRError.authorityDenied }
        let resource = try acquire()
        let declaration = try JSONSerialization.data(withJSONObject: resource, options: [.sortedKeys])
        let schema = KubernetesConfigMap.schema
        let operation = CapabilityInterfaceOperation(name: "create.configmaps", title: "Create ConfigMap in " + namespace,
            arguments: .object(properties: ["name": .string, "challenge": .string, "value": .string], required: ["name", "challenge", "value"]),
            result: schema, declaration: .object(["apiResource": try CapabilityJSON.value(resource), "apiVersion": .string("v1"),
                "namespace": .string(namespace), "verb": .string("create"),
                "completionBoundary": .string("Stored API resource; controller reconciliation and watch streaming are not claimed")]), effect: .write)
        let target = endpoint.appendingPathComponent("api/v1/namespaces/" + namespace + "/configmaps")
        func unchanged() -> Bool {
            guard client.sourceStillMatches(), writer.valid(), reader.valid(),
                  let current = try? acquire(), let bytes = try? JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]),
                  CapabilityJSON.digest(bytes) == CapabilityJSON.digest(declaration) else { return false }
            return true
        }
        let observerID = "kubernetes:get:" + endpoint.absoluteString + ":" + namespace + ":" + observerPrincipal
        let observer = KubernetesConfigMapObserver(observerID: observerID, client: client, credential: reader,
            namespace: namespace, endpoint: endpoint)
        return try CapabilityInterfaceReflector(id: "kubernetes:" + descriptor.id, provider: descriptor.id, target: target,
            substrate: kind, descriptorDigest: CapabilityJSON.digest(declaration), operations: [operation],
            provenance: ["providerPrincipal": writerPrincipal, "observerPrincipal": observerPrincipal,
                "namespace": namespace, "authorityScheme": "Kubernetes TokenRequest service-account bearer credential with real TLS CA",
                "credentialSourceType": "protected_file_reference", "credentialReference": writerReference,
                "observerCredentialReference": observerReference, "issuerAuthorityExpiresAt": String(writer.expiresAt),
                "runtimeExecutable": executable.path, "runtimeSHA256": client.sha256,
                "executionArtifactBinding": "host-private read-only client and separate protected credential snapshots",
                "verificationRequirement": "independent GET-only service account reads exact desired fields, host invocation annotation and assigned UID/resourceVersion"],
            observerFactory: { name in
                guard name == operation.name else { return nil }
                return { input in
                    let desired = try KubernetesConfigMap.arguments(input, namespace: namespace)
                    let fields: [String: [String]] = ["name": ["name"], "namespace": ["namespace"], "challenge": ["data", "challenge"], "value": ["data", "value"]]
                    let expected = CapabilityValue.object(["name": .string(desired.name), "namespace": .string(namespace),
                        "challenge": .string(desired.challenge), "value": .string(desired.value)])
                    let contract = RCIRVerificationContract(observerID: observerID,
                        schema: .object(properties: ["name": .string, "namespace": .string, "challenge": .string, "value": .string], required: Array(fields.keys)),
                        expected: expected, projection: .init(schema: schema, fields: fields), invocationBindingPath: ["invocationID"])
                    return .init(contract: contract, observer: observer,
                        boundary: "Independent ConfigMap GET under a distinct GET-only namespace service account; real API server TLS CA, desired fields and host invocation marker exact, assigned UID/resourceVersion retained.")
                }
            }, available: unchanged, boundInvoke: { name, input, binding, admit in
                guard name == operation.name, unchanged() else { throw RCIRError.unavailable }
                let desired = try KubernetesConfigMap.arguments(input, namespace: namespace)
                let manifest: [String: Any] = ["apiVersion": "v1", "kind": "ConfigMap", "metadata": ["name": desired.name, "namespace": namespace,
                    "annotations": ["rightclick.io/invocation": binding.id]],
                    "data": ["challenge": desired.challenge, "value": desired.value]]
                let bytes = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
                let output = try withoutActuallyEscaping(admit) { gate in
                    try command(writer, ["create", "-f", "-", "-o", "json"], input: bytes, admit: gate)
                }
                return try KubernetesConfigMap.normalize(output, expectedName: desired.name, namespace: namespace)
            }, invoke: { _, _, _ in throw RCIRError.invalidContract })
    }
    static func validName(_ name: String, maximum: Int = 253) -> Bool {
        name.utf8.count <= maximum && name.range(of: "^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", options: .regularExpression) != nil
    }
}

private final class KubernetesCredential {
    let snapshot: CapabilityArtifactSnapshot
    let expiresAt: Int64
    init(reference: String, endpoint: URL, namespace: String) throws {
        snapshot = try CapabilityArtifactSnapshot(source: URL(fileURLWithPath: reference), maximum: 262_144, protected: true)
        // This narrow transport accepts JSON kubeconfigs with embedded CA and
        // short-lived bearer tokens only. It cannot spawn credential plugins or
        // read external certificate/key paths from a provider-owned document.
        let bytes = try CapabilityProtectedReference.read(snapshot.file.path, maximum: 262_144)
        guard let config = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              config["apiVersion"] as? String == "v1", config["kind"] as? String == "Config",
              let clusters = config["clusters"] as? [[String: Any]], clusters.count == 1,
              let cluster = clusters[0]["cluster"] as? [String: Any],
              Set(cluster.keys).isSubset(of: ["server", "certificate-authority-data"]),
              let server = cluster["server"] as? String, URL(string: server)?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              let certificate = cluster["certificate-authority-data"] as? String, let ca = Data(base64Encoded: certificate), !ca.isEmpty,
              let contexts = config["contexts"] as? [[String: Any]], contexts.count == 1,
              config["current-context"] as? String == contexts[0]["name"] as? String,
              let context = contexts[0]["context"] as? [String: Any], context["cluster"] as? String == clusters[0]["name"] as? String,
              context["namespace"] == nil || context["namespace"] as? String == namespace,
              let users = config["users"] as? [[String: Any]], users.count == 1,
              context["user"] as? String == users[0]["name"] as? String,
              let user = users[0]["user"] as? [String: Any], Set(user.keys) == ["token"], let token = user["token"] as? String else { throw RCIRError.authorityDenied }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { throw RCIRError.authorityDenied }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let payload = Data(base64Encoded: encoded),
              let claims = try JSONSerialization.jsonObject(with: payload) as? [String: Any], let expiry = claims["exp"] as? Int64,
              expiry > Int64(Date().timeIntervalSince1970) else { throw RCIRError.authorityDenied }
        // JWT claims do not establish authority by themselves. The actual API
        // authenticates this captured token and returns its principal above.
        expiresAt = expiry
    }
    func valid() -> Bool { snapshot.sourceStillMatches() && Int64(Date().timeIntervalSince1970) < expiresAt }
}

private enum KubernetesConfigMap {
    static let schema = CapabilitySchema.object(properties: ["name": .string, "namespace": .string, "uid": .string,
        "resourceVersion": .string, "invocationID": .string,
        "data": .object(properties: ["challenge": .string, "value": .string], required: ["challenge", "value"])],
        required: ["name", "namespace", "uid", "resourceVersion", "invocationID", "data"])
    static func arguments(_ input: CapabilityValue, namespace: String) throws -> (name: String, challenge: String, value: String) {
        guard case let .object(fields) = input, case let .string(name)? = fields["name"], KubernetesCapabilityArtifactResolver.validName(name),
              case let .string(challenge)? = fields["challenge"], challenge.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
              case let .string(value)? = fields["value"], value.utf8.count <= 131_072 else { throw CapabilityABIError.invalidWire }
        return (name, challenge, value)
    }
    static func normalize(_ data: Data, expectedName: String, namespace: String) throws -> CapabilityValue {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["apiVersion"] as? String == "v1",
              object["kind"] as? String == "ConfigMap", let metadata = object["metadata"] as? [String: Any],
              metadata["name"] as? String == expectedName, metadata["namespace"] as? String == namespace,
              let uid = metadata["uid"] as? String, !uid.isEmpty, uid.utf8.count <= 128,
              let version = metadata["resourceVersion"] as? String, !version.isEmpty, version.utf8.count <= 128,
              let annotations = metadata["annotations"] as? [String: Any],
              let marker = annotations["rightclick.io/invocation"] as? String, marker.utf8.count == 36,
              (try? RCIRInvocationBinding(taskID: marker)) != nil,
              let fields = object["data"] as? [String: String], Set(fields.keys) == ["challenge", "value"] else { throw CapabilityABIError.invalidWire }
        let value = CapabilityValue.object(["name": .string(expectedName), "namespace": .string(namespace), "uid": .string(uid),
            "resourceVersion": .string(version), "invocationID": .string(marker), "data": .object(fields.mapValues { .string($0) })])
        try schema.validate(value); return value
    }
}

private final class KubernetesConfigMapObserver: RCIRObserver {
    let observerID: String
    private let client: CapabilityArtifactSnapshot
    private let credential: KubernetesCredential
    private let namespace: String
    private let endpoint: URL
    init(observerID: String, client: CapabilityArtifactSnapshot, credential: KubernetesCredential, namespace: String, endpoint: URL) {
        self.observerID = observerID; self.client = client; self.credential = credential; self.namespace = namespace; self.endpoint = endpoint
    }
    func observe(_ request: RCIRObservationRequest) throws -> CapabilityValue {
        guard credential.valid(), client.sourceStillMatches() else { throw RCIRError.authorityDenied }
        let desired = try KubernetesConfigMap.arguments(request.arguments, namespace: namespace)
        // Name and namespace come from the admitted caller arguments/host grant;
        // provider result UID/version/data never determine the desired outcome.
        let data = try BoundedCapabilityProcess.run(executable: client.file,
            arguments: ["--kubeconfig", credential.snapshot.file.path, "--namespace", namespace, "--request-timeout=3s",
                "get", "configmap", desired.name, "-o", "json"], timeout: 5)
        return try KubernetesConfigMap.normalize(data, expectedName: desired.name, namespace: namespace)
    }
}
