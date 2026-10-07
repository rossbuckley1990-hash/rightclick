import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Protected operator configuration. Paths describe independently acquired JSON;
/// binding sources are the exact admitted arguments or caller expectedOutput.
struct RCIRJSONObservationConfiguration: Codable {
    struct Field: Codable {
        let path: [String]
        var argument: String? = nil
        var expectedOutput: Bool? = nil
    }
    let schemaJSON: String
    let fields: [String: Field]
    var invocationBindingPath: [String]? = nil
    var bindsExpectedOutput: Bool { fields.values.contains { $0.expectedOutput == true } }
}

/// Common authenticated HTTP read-back. The provider/caller cannot choose this
/// origin, credential, schema or field projection. Redirects/cookies/default
/// credentials cannot convey the observer authority elsewhere.
final class RCIRHTTPJSONObserver: RCIRObserver {
    let observerID: String
    private let url: URL
    private let origin: URL
    private let credential: CapabilityArtifactSnapshot?
    private let bearer: String?
    private let sensitiveMaterial: CapabilitySensitiveMaterial?

    init(url: URL, origin: URL, credentialFile: String?) throws {
        self.url = url; self.origin = origin
        guard OriginPinnedHTTP.sameOrigin(origin, url) else { throw RCIRError.authorityDenied }
        if let credentialFile {
            let snapshot = try CapabilityArtifactSnapshot(source: URL(fileURLWithPath: credentialFile), maximum: 8192, protected: true)
            let bytes = try CapabilityProtectedReference.read(snapshot.file.path, maximum: 8192)
            guard let text = String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .newlines),
                  !text.isEmpty, text.utf8.count <= 8192,
                  text.range(of: "^[A-Za-z0-9._~+/-]+=*$", options: .regularExpression) != nil else { throw RCIRError.authorityDenied }
            credential = snapshot; bearer = text
            sensitiveMaterial = try CapabilitySensitiveMaterial([Data(text.utf8)])
        } else { credential = nil; bearer = nil; sensitiveMaterial = nil }
        observerID = "host:http-json:" + url.absoluteString + ":" + (credentialFile ?? "public")
    }
    func observe(_ request: RCIRObservationRequest) throws -> CapabilityValue {
        guard OriginPinnedHTTP.sameOrigin(origin, url), credential?.sourceStillMatches() ?? true else { throw RCIRError.authorityDenied }
        var query = URLRequest(url: url)
        query.httpMethod = "GET"
        query.setValue("application/json", forHTTPHeaderField: "Accept")
        query.setValue(request.taskID.uuidString, forHTTPHeaderField: "X-RightClick-Invocation")
        if let bearer { query.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        let bytes = try OriginPinnedHTTP.loadObservation(query, maximumBytes: 131_072)
        guard credential?.sourceStillMatches() ?? true else { throw RCIRError.authorityDenied }
        let value = try CapabilityJSON.value(JSONSerialization.jsonObject(with: bytes))
        try sensitiveMaterial?.requireAbsent(in: value)
        return value
    }
}

extension RCIRHostConfiguration.Observer {
    func structuredObservation(arguments: CapabilityArguments?, expectedOutput: String?, target: URL) throws -> RCIRHostObservation? {
        guard let jsonObservation else { return nil }
        // Authenticated observation requires an explicit independent host pin.
        // Even public structured observations need a host-selected origin rather
        // than an authority inferred from provider invocation output.
        guard let trustedOrigin, let origin = URL(string: trustedOrigin),
              let parts = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", OriginPinnedHTTP.sameOrigin(origin, origin),
              expectedArgument == nil, !jsonObservation.fields.isEmpty, jsonObservation.fields.count <= 64,
              jsonObservation.schemaJSON.utf8.count <= 65_536,
              let schemaBytes = jsonObservation.schemaJSON.data(using: .utf8) else { throw RCIRError.invalidContract }
        let fullSchema = try CapabilityJSON.schema(JSONSerialization.jsonObject(with: schemaBytes))
        let template = try RCIRObserverPath.interpolate(urlTemplate, arguments: arguments)
        guard !template.contains("{"), !template.contains("}"), let url = URL(string: template),
              let destination = URLComponents(url: url, resolvingAgainstBaseURL: false),
              destination.user == nil, destination.password == nil, destination.query == nil, destination.fragment == nil,
              OriginPinnedHTTP.sameOrigin(origin, url) else { throw RCIRError.authorityDenied }
        var expected: [String: CapabilityValue] = [:], paths: [String: [String]] = [:]
        for (name, field) in jsonObservation.fields {
            let text: String
            if let argument = field.argument {
                guard field.expectedOutput == nil, let value = arguments?[argument] else { throw RCIRError.invalidContract }
                text = value
            } else {
                guard field.expectedOutput == true, let expectedOutput else { throw RCIRError.invalidContract }
                text = expectedOutput
            }
            expected[name] = .string(text); paths[name] = field.path
        }
        let observer = try RCIRHTTPJSONObserver(url: url, origin: origin, credentialFile: credentialFile)
        let contract = RCIRVerificationContract(observerID: observer.observerID,
            schema: .object(properties: expected.mapValues { _ in .string }, required: Array(expected.keys)),
            expected: .object(expected), projection: .init(schema: fullSchema, fields: paths),
            invocationBindingPath: jsonObservation.invocationBindingPath)
        return .init(contract: contract, observer: observer,
            boundary: "Independent host-pinned JSON GET with explicit protected read-only credential reference; no cookies or ambient credentials. "
                + (jsonObservation.invocationBindingPath == nil
                    ? "Exact host-declared state predicate; this does not establish current mutation causality. "
                    : "Exact admitted argument/caller postconditions and independent host task marker establish invocation binding. ")
                + "Protected credential reflection is rejected before retaining the typed observation.")
    }
}

/// Values remain exactly one wire path segment. Printable JSON punctuation is
/// encoded once; separators, encoded-escape syntax and traversal/control inputs
/// cannot change path structure even if a server decodes the segment.
enum RCIRObserverPath {
    static func interpolate(_ raw: String, arguments: CapabilityArguments?) throws -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var template = raw
        for (key, value) in arguments ?? [:] where template.contains("{" + key + "}") {
            guard !value.isEmpty, value.utf8.count <= 131_072, value != ".", value != "..",
                  !value.contains("/"), !value.contains("\\"), !value.contains("%"), !value.contains("?"), !value.contains("#"),
                  value.rangeOfCharacter(from: .controlCharacters) == nil,
                  let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved) else { throw RCIRError.invalidContract }
            template = template.replacingOccurrences(of: "{" + key + "}", with: encoded)
        }
        guard template.utf8.count <= 262_144 else { throw RCIRError.invalidLimit }
        return template
    }
}
