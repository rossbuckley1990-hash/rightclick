import Foundation
@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders

func semanticFixture(
    id: String = "capability:alpha",
    title: String = "Publish report",
    owner: String = "reflector:alpha",
    schema: String? = nil
) -> Capability {
    var metadata: [String: String] = ["substrate": "openapi", "method": "POST"]
    if let schema { metadata["argumentsSchema"] = schema }
    return Capability(
        id: id, title: title, source: .system, reflectorID: owner,
        provider: CapabilityProvider(name: "Synthetic provider"),
        inputs: ["public.plain-text"], output: ["public.json"],
        safety: .unknown, invocation: .direct, supportLevel: .experimental,
        requiresConfirmation: true, metadata: metadata
    )
}

let semanticClosedSchema = #"{"type":"object","properties":{"owner":{"type":"string"},"report":{"type":"string"}},"required":["owner","report"],"additionalProperties":false}"#
