import Foundation

/// Advisory facts about the declared operation, never permission to invoke it.
/// HTTP/GraphQL semantics are provider claims, not proof of actual side effects.
public struct CapabilityEffectAssessment: Codable, Equatable, Sendable {
    public let stateAccess: String
    public let executionBoundary: String
    public let basis: String
    public let dataSensitivity: String
    public let verified: Bool
    public let grantsAuthority: Bool

    public static func assess(_ capability: Capability) -> Self {
        var access = "unknown"
        var boundary = "unknown"
        var basis = "unknown"
        let substrate = capability.metadata["substrate"]

        if capability.source == .system, substrate == "openapi" {
            boundary = "network_endpoint"
            basis = "http_method_declaration"
            switch capability.metadata["method"]?.uppercased() {
            case "GET", "HEAD", "OPTIONS": access = "declared_read"
            case "POST", "PUT", "PATCH": access = "may_write"
            case "DELETE": access = "may_delete"
            default: break
            }
        } else if capability.source == .system, substrate == "graphql" {
            boundary = "network_endpoint"
            basis = "graphql_operation_declaration"
            switch capability.metadata["operationKind"] {
            case "query": access = "declared_read"
            case "mutation": access = "may_write"
            default: break
            }
        } else if capability.source == .system, substrate == "grpc" {
            boundary = "network_endpoint"
            // Unary/streaming and names such as GetFoo do not establish effects.
            basis = "grpc_transport_only"
        } else if capability.source == .service || capability.source == .actionExtension {
            boundary = "local_provider"
            // A local application can still transmit, delete, or execute code.
        } else if capability.source == .sharingService {
            boundary = "external_share_possible"
        }

        // Existing elevated risk signals can raise concern, but never turn an
        // unknown operation into an authorized one or waive confirmation.
        switch capability.safety {
        case .destructive: access = "may_delete"; basis = "legacy_risk_classification"
        case .codeExecution: access = "may_execute_code"; basis = "legacy_risk_classification"
        case .externalShare: boundary = "external_share_possible"
        default: break
        }
        return .init(
            stateAccess: access,
            executionBoundary: boundary,
            basis: basis,
            dataSensitivity: "unknown",
            verified: false,
            grantsAuthority: false
        )
    }
}

/// A presentation-only wrapper. Raw Capability serialization and its contract
/// fingerprints stay unchanged; discovery lists gain no extra per-row fields.
/// Existing decoders can still decode this flat response as Capability.
public struct CapabilityExplanationView: Encodable {
    public let capability: Capability
    public init(_ capability: Capability) { self.capability = capability }
    private enum CodingKeys: String, CodingKey { case effectAssessment }
    public func encode(to encoder: Encoder) throws {
        try capability.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(CapabilityEffectAssessment.assess(capability), forKey: .effectAssessment)
    }
}
