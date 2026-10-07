#if canImport(GRPC) && canImport(SwiftProtobuf) && canImport(NIOCore) && canImport(NIOPosix)
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import SwiftProtobuf

public final class GRPCReflector:
    RCIRExecutionReflector
{
    public typealias UnaryInvoker =
        (
            _ endpoint: GRPCEndpoint,
            _ path: String,
            _ request: Data
        ) throws -> Data

    private struct EnumContract {
        let nameToNumber:
            [String: Int32]

        let numberToName:
            [Int32: String]
    }

    private enum FieldKind {
        case double
        case float
        case int64
        case uint64
        case int32
        case fixed64
        case fixed32
        case bool
        case string
        case bytes
        case uint32
        case enumeration(
            EnumContract
        )
        case sfixed32
        case sfixed64
        case sint32
        case sint64

        var wireType: Int {
            switch self {
            case .double,
                 .fixed64,
                 .sfixed64:
                return 1

            case .string,
                 .bytes:
                return 2

            case .float,
                 .fixed32,
                 .sfixed32:
                return 5

            default:
                return 0
            }
        }

        var description: String {
            switch self {
            case .double:
                return "protobuf double"

            case .float:
                return "protobuf float"

            case .int64:
                return "protobuf int64"

            case .uint64:
                return "protobuf uint64"

            case .int32:
                return "protobuf int32"

            case .fixed64:
                return "protobuf fixed64"

            case .fixed32:
                return "protobuf fixed32"

            case .bool:
                return "protobuf bool (true or false)"

            case .string:
                return "protobuf string"

            case .bytes:
                return "protobuf bytes encoded as base64"

            case .uint32:
                return "protobuf uint32"

            case .enumeration:
                return "protobuf enum"

            case .sfixed32:
                return "protobuf sfixed32"

            case .sfixed64:
                return "protobuf sfixed64"

            case .sint32:
                return "protobuf sint32"

            case .sint64:
                return "protobuf sint64"
            }
        }
    }

    private struct FieldContract {
        let name: String
        let number: Int
        let kind: FieldKind
        let required: Bool
    }

    private struct MessageContract {
        let fullName: String
        let fields: [FieldContract]
        let limitation: String?

        var supported: Bool {
            limitation == nil
        }
    }

    private struct MethodContract {
        let capabilityID: String
        let service: String
        let method: String
        let path: String
        let requestType: String
        let responseType: String
        let request: MessageContract
        let response: MessageContract
        let clientStreaming: Bool
        let serverStreaming: Bool
        let limitation: String?

        var callType: String {
            if clientStreaming
                && serverStreaming
            {
                return
                    "bidirectional_streaming"
            }

            if clientStreaming {
                return
                    "client_streaming"
            }

            if serverStreaming {
                return
                    "server_streaming"
            }

            return "unary"
        }

        var supported: Bool {
            limitation == nil
        }
    }

    private let endpoint:
        GRPCEndpoint

    private let providerName:
        String

    private let providerFingerprint:
        String

    private let descriptorSHA256:
        String

    private let methods:
        [MethodContract]

    private let methodByCapabilityID:
        [String: MethodContract]

    private let invoker:
        UnaryInvoker

    private let usesDefaultInvoker: Bool

    public let id:
        String

    public init(
        descriptorData:
            [Data],
        endpoint:
            GRPCEndpoint,
        providerName:
            String? = nil,
        invoker:
            UnaryInvoker? = nil
    ) throws {
        guard
            !descriptorData.isEmpty
        else {
            throw RightClickError(
                "gRPC reflection returned no file descriptors."
            )
        }

        let files =
            try Self
                .parseFiles(
                    descriptorData
                )

        let descriptorSHA256 =
            try Self
                .descriptorFingerprint(
                    files
                )

        let providerFingerprint =
            Self.sha256Hex(
                Data(
                    (
                        endpoint.identity
                        + "\n"
                        + descriptorSHA256
                    )
                    .utf8
                )
            )

        let catalog =
            try Self
                .buildCatalog(
                    files:
                        files,
                    providerFingerprint:
                        providerFingerprint
                )

        let trimmedName =
            providerName?
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        self.endpoint =
            endpoint

        self.providerName =
            (
                trimmedName?
                    .isEmpty == false
            )
            ? trimmedName!
            : "gRPC "
                + endpoint.host
                + ":"
                + String(
                    endpoint.port
                )

        self.providerFingerprint =
            providerFingerprint

        self.descriptorSHA256 =
            descriptorSHA256

        self.methods =
            catalog

        self.methodByCapabilityID =
            Dictionary(
                uniqueKeysWithValues:
                    catalog.map {
                        (
                            $0.capabilityID,
                            $0
                        )
                    }
            )

        self.usesDefaultInvoker = invoker == nil
        self.invoker =
            invoker
            ?? {
                endpoint,
                path,
                request in

                try GRPCReflectionTransport
                    .invokeUnary(
                        endpoint:
                            endpoint,
                        path:
                            path,
                        request:
                            request
                    )
            }

        self.id =
            "grpc-reflector:"
            + providerFingerprint
    }

    public func capabilities(
        for item: ContentItem
    ) throws -> [Capability] {
        guard
            item.text != nil
        else {
            return []
        }

        return methods.map {
            method in

            let title =
                "gRPC "
                + method.service
                + "/"
                + method.method

            let policy =
                SafetyPolicy.classify(
                    title:
                        title,
                    source:
                        .system,
                    sendTypes: [
                        "public.plain-text"
                    ],
                    returnTypes: [
                        "public.json"
                    ]
                )

            var metadata:
                [String: String] = [
                    "substrate":
                        "grpc",
                    "service":
                        method.service,
                    "method":
                        method.method,
                    "rpcPath":
                        method.path,
                    "callType":
                        method.callType,
                    "requestType":
                        method.requestType,
                    "responseType":
                        method.responseType,
                    "providerIdentity":
                        providerFingerprint,
                    "descriptorSHA256":
                        descriptorSHA256,
                    "endpoint":
                        endpoint.identity,
                    "resultValidation":
                        "protobuf_descriptor",
                ]

            if
                method.supported,
                !method
                    .request
                    .fields
                    .isEmpty
            {
                metadata[
                    "argumentsSchema"
                ] =
                    Self.argumentsSchema(
                        method
                            .request
                    )
            }

            if let limitation =
                method.limitation
            {
                metadata[
                    "invocationLimitation"
                ] =
                    limitation
            }

            return Capability(
                id:
                    method.capabilityID,
                title:
                    title,
                source:
                    .system,
                provider:
                    CapabilityProvider(
                        name:
                            providerName
                    ),
                inputs: [
                    "public.plain-text"
                ],
                output: [
                    "public.json"
                ],
                safety:
                    policy.safety,
                invocation:
                    method.supported
                    ? policy.invocation
                    : .unsupported,
                supportLevel:
                    .experimental,
                requiresConfirmation:
                    true,
                metadata:
                    metadata
            )
        }
    }

    public func providers()
        -> [ProviderSummary]
    {
        guard
            !methods.isEmpty
        else {
            return []
        }

        return [
            ProviderSummary(
                name:
                    providerName,
                bundleIdentifier:
                    nil,
                source:
                    "grpc",
                capabilityTitles:
                    methods
                        .map {
                            "gRPC "
                            + $0.service
                            + "/"
                            + $0.method
                        }
                        .sorted {
                            $0
                                .localizedCaseInsensitiveCompare(
                                    $1
                                )
                                == .orderedAscending
                        }
            )
        ]
    }

    public func begin(
        capability: Capability,
        item: ContentItem,
        executionID: String
    ) throws
        -> ExecutionRecord
    {
        try begin(
            capability:
                capability,
            item:
                item,
            executionID:
                executionID,
            arguments:
                nil
        )
    }

    public func begin(
        capability: Capability,
        item: ContentItem,
        executionID: String,
        arguments:
            CapabilityArguments?
    ) throws
        -> ExecutionRecord
    {
        try performBegin(capability: capability, item: item, executionID: executionID,
                         arguments: arguments, admitStart: nil)
    }

    public func admittedBegin(capability: Capability, admissionOwner: Capability, item: ContentItem,
                              executionID: String, arguments: CapabilityArguments?, verification: VerificationSpec?,
                              expectedOutput: String?, host: RCIRExecutionHost, revalidate: @escaping () -> Bool) throws -> ExecutionRecord {
        guard let method = methodByCapabilityID[capability.id], method.supported,
              let target = URL(string: endpoint.identity) else { throw RCIRError.unsupportedTaskShape }
        return try RCIRUnaryInvocation.execute(capability: capability, owner: admissionOwner, item: item,
            executionID: executionID, arguments: arguments, names: method.request.fields.map(\.name),
            required: method.request.fields.filter(\.required).map(\.name), target: target,
            verification: verification, expectedOutput: expectedOutput, host: host, available: { true }, revalidate: revalidate,
            invoke: { admit in
                try withoutActuallyEscaping(admit) { gate in
                    try self.performBegin(capability: capability, item: item, executionID: executionID,
                                          arguments: arguments, admitStart: gate)
                }
            })
    }

    private func performBegin(capability: Capability, item: ContentItem, executionID: String,
                              arguments: CapabilityArguments?,
                              admitStart: ((_ start: () -> Void) throws -> Void)?) throws -> ExecutionRecord
    {
        guard
            let method =
                methodByCapabilityID[
                    capability.id
                ]
        else {
            return ExecutionRecord(
                executionId:
                    executionID,
                actionId:
                    capability.id,
                title:
                    capability.title,
                state:
                    .unavailable,
                message:
                    "The reflected gRPC method is no longer available.",
                evidence:
                    OutcomeEvidence(
                        type:
                            "provider_unavailable",
                        boundary:
                            "No method matching this capability exists in the current gRPC reflector."
                    )
            )
        }

        guard
            method.supported
        else {
            return ExecutionRecord(
                executionId:
                    executionID,
                actionId:
                    capability.id,
                title:
                    capability.title,
                state:
                    .unsupported,
                message:
                    method.limitation
                    ?? "The reflected gRPC method is not safely invokable in the current slice.",
                evidence:
                    OutcomeEvidence(
                        type:
                            "invocation_unsupported",
                        boundary:
                            "RIGHTCLICK reflected the gRPC contract but abstained from provider transport because the method shape is outside the closed unary protobuf subset."
                    )
            )
        }

        let supplied =
            arguments
            ?? [:]

        let knownNames =
            Set(
                method
                    .request
                    .fields
                    .map(
                        \.name
                    )
            )

        let unknownNames =
            Set(
                supplied.keys
            )
            .subtracting(
                knownNames
            )

        guard
            unknownNames.isEmpty
        else {
            return inputFailure(
                executionID:
                    executionID,
                capability:
                    capability,
                message:
                    "Unknown gRPC arguments: "
                    + unknownNames
                        .sorted()
                        .joined(
                            separator:
                                ", "
                        )
            )
        }

        let requiredNames =
            Set(
                method
                    .request
                    .fields
                    .filter(
                        \.required
                    )
                    .map(
                        \.name
                    )
            )

        let missing =
            requiredNames
                .subtracting(
                    Set(
                        supplied.keys
                    )
                )

        guard
            missing.isEmpty
        else {
            return inputFailure(
                executionID:
                    executionID,
                capability:
                    capability,
                message:
                    "Missing required gRPC arguments: "
                    + missing
                        .sorted()
                        .joined(
                            separator:
                                ", "
                        )
            )
        }

        let request:
            Data

        do {
            request =
                try Self
                    .encode(
                        supplied,
                        message:
                            method.request
                    )
        } catch {
            return inputFailure(
                executionID:
                    executionID,
                capability:
                    capability,
                message:
                    "Invalid gRPC arguments: "
                    + error.localizedDescription
            )
        }

        let response:
            Data

        do {
            if usesDefaultInvoker, let admitStart {
                response = try GRPCReflectionTransport.invokeUnary(endpoint: endpoint,
                    path: method.path, request: request, admitStart: admitStart)
            } else if let admitStart {
                var captured: Result<Data, Error>?
                try admitStart { captured = Result { try self.invoker(self.endpoint, method.path, request) } }
                guard let captured else { throw RCIRError.unavailable }
                response = try captured.get()
            } else {
                response = try invoker(
                    endpoint,
                    method.path,
                    request
                )
            }
        } catch {
            if admitStart != nil { throw error }
            return ExecutionRecord(
                executionId:
                    executionID,
                actionId:
                    capability.id,
                title:
                    capability.title,
                state:
                    .failed,
                message:
                    "The gRPC provider request failed: "
                    + String(
                        describing:
                            error
                    ),
                evidence:
                    OutcomeEvidence(
                        type:
                            "provider_transport_failure",
                        boundary:
                            "The gRPC transport failed before provider acceptance could be established."
                    )
            )
        }

        let output:
            String

        do {
            output =
                try Self
                    .decode(
                        response,
                        message:
                            method.response
                    )
        } catch {
            return ExecutionRecord(
                executionId:
                    executionID,
                actionId:
                    capability.id,
                title:
                    capability.title,
                state:
                    .failed,
                message:
                    "The gRPC provider returned a response that violated the reflected protobuf contract: "
                    + String(
                        describing:
                            error
                    ),
                evidence:
                    OutcomeEvidence(
                        type:
                            "provider_contract_failure",
                        boundary:
                            "The gRPC transport completed, but RIGHTCLICK could not decode the response against the reflected protobuf descriptor."
                    )
            )
        }

        return ExecutionRecord(
            executionId:
                executionID,
            actionId:
                capability.id,
            title:
                capability.title,
            state:
                .accepted,
            message:
                "The gRPC provider returned OK and a protobuf response matching the reflected descriptor. Semantic outcome is unverified.",
            output:
                output,
            events: [
                "gRPC unary "
                + method.path,
                "provider returned OK",
            ],
            evidence:
                OutcomeEvidence(
                    type:
                        "provider_acceptance",
                    boundary:
                        "gRPC status OK plus successful protobuf decoding establishes provider acceptance only. It does not independently verify the user's intended external outcome."
                )
        )
    }

    private func inputFailure(
        executionID: String,
        capability: Capability,
        message: String
    ) -> ExecutionRecord {
        ExecutionRecord(
            executionId:
                executionID,
            actionId:
                capability.id,
            title:
                capability.title,
            state:
                .failed,
            message:
                message,
            evidence:
                OutcomeEvidence(
                    type:
                        "input_contract_failure",
                    boundary:
                        "RIGHTCLICK rejected gRPC arguments before provider transport."
                )
        )
    }

    private static func parseFiles(
        _ descriptorData:
            [Data]
    ) throws
        -> [
            Google_Protobuf_FileDescriptorProto
        ]
    {
        var filesByName:
            [
                String:
                    (
                        file:
                            Google_Protobuf_FileDescriptorProto,
                        data:
                            Data
                    )
            ] = [:]

        for data in descriptorData {
            let file =
                try Google_Protobuf_FileDescriptorProto(
                    serializedBytes:
                        data
                )

            guard
                !file.name.isEmpty
            else {
                throw RightClickError(
                    "Reflected gRPC file descriptor has no name."
                )
            }

            if let existing =
                filesByName[
                    file.name
                ]
            {
                guard
                    existing.data
                        == data
                else {
                    throw RightClickError(
                        "Conflicting reflected gRPC file descriptors share the name "
                        + file.name
                        + "."
                    )
                }

                continue
            }

            filesByName[
                file.name
            ] =
                (
                    file,
                    data
                )
        }

        return filesByName
            .values
            .map(
                \.file
            )
            .sorted {
                $0.name < $1.name
            }
    }

    private static func descriptorFingerprint(
        _ files:
            [
                Google_Protobuf_FileDescriptorProto
            ]
    ) throws -> String {
        var rows:
            [String] = []

        for file in files {
            let data:
                Data =
                try file
                    .serializedBytes()

            rows.append(
                file.name
                + ":"
                + sha256Hex(
                    data
                )
            )
        }

        return sha256Hex(
            Data(
                rows
                    .sorted()
                    .joined(
                        separator:
                            "\n"
                    )
                    .utf8
            )
        )
    }

    private static func buildCatalog(
        files:
            [
                Google_Protobuf_FileDescriptorProto
            ],
        providerFingerprint:
            String
    ) throws -> [MethodContract] {
        var messages:
            [
                String:
                    Google_Protobuf_DescriptorProto
            ] = [:]

        var enums:
            [
                String:
                    Google_Protobuf_EnumDescriptorProto
            ] = [:]

        for file in files {
            let prefix =
                file.package

            for message in
                file.messageType
            {
                try collect(
                    message:
                        message,
                    prefix:
                        prefix,
                    messages:
                        &messages,
                    enums:
                        &enums
                )
            }

            for enumeration in
                file.enumType
            {
                let fullName =
                    joinedName(
                        prefix:
                            prefix,
                        name:
                            enumeration.name
                    )

                guard
                    enums[
                        fullName
                    ] == nil
                else {
                    throw RightClickError(
                        "Duplicate reflected protobuf enum: "
                        + fullName
                    )
                }

                enums[
                    fullName
                ] =
                    enumeration
            }
        }

        var result:
            [MethodContract] = []

        for file in
            files.sorted(
                by: {
                    $0.name < $1.name
                }
            )
        {
            for service in
                file.service
            {
                guard
                    !service.name.isEmpty
                else {
                    continue
                }

                let serviceName =
                    joinedName(
                        prefix:
                            file.package,
                        name:
                            service.name
                    )

                for method in
                    service.method
                {
                    guard
                        !method.name.isEmpty
                    else {
                        continue
                    }

                    let requestType =
                        normalizeTypeName(
                            method.inputType
                        )

                    let responseType =
                        normalizeTypeName(
                            method.outputType
                        )

                    let request =
                        messageContract(
                            name:
                                requestType,
                            messages:
                                messages,
                            enums:
                                enums
                        )

                    let response =
                        messageContract(
                            name:
                                responseType,
                            messages:
                                messages,
                            enums:
                                enums
                        )

                    let path =
                        "/"
                        + serviceName
                        + "/"
                        + method.name

                    let limitation:
                        String?

                    if
                        method.clientStreaming
                        || method.serverStreaming
                    {
                        limitation =
                            "Streaming gRPC methods are reflected but not executable in the current bounded unary slice."
                    } else if
                        let value =
                            request.limitation
                    {
                        limitation =
                            "Unsupported gRPC request type "
                            + requestType
                            + ": "
                            + value
                    } else if
                        let value =
                            response.limitation
                    {
                        limitation =
                            "Unsupported gRPC response type "
                            + responseType
                            + ": "
                            + value
                    } else {
                        limitation =
                            nil
                    }

                    let capabilityID =
                        "grpc:"
                        + providerFingerprint
                        + ":"
                        + String(
                            sha256Hex(
                                Data(
                                    path.utf8
                                )
                            )
                            .prefix(
                                16
                            )
                        )
                        + ":"
                        + serviceName
                        + "."
                        + method.name

                    result.append(
                        MethodContract(
                            capabilityID:
                                capabilityID,
                            service:
                                serviceName,
                            method:
                                method.name,
                            path:
                                path,
                            requestType:
                                requestType,
                            responseType:
                                responseType,
                            request:
                                request,
                            response:
                                response,
                            clientStreaming:
                                method
                                    .clientStreaming,
                            serverStreaming:
                                method
                                    .serverStreaming,
                            limitation:
                                limitation
                        )
                    )
                }
            }
        }

        return result.sorted {
            if $0.service == $1.service {
                return
                    $0.method < $1.method
            }

            return
                $0.service < $1.service
        }
    }

    private static func collect(
        message:
            Google_Protobuf_DescriptorProto,
        prefix: String,
        messages:
            inout [
                String:
                    Google_Protobuf_DescriptorProto
            ],
        enums:
            inout [
                String:
                    Google_Protobuf_EnumDescriptorProto
            ]
    ) throws {
        guard
            !message.name.isEmpty
        else {
            throw RightClickError(
                "Reflected protobuf message has no name."
            )
        }

        let fullName =
            joinedName(
                prefix:
                    prefix,
                name:
                    message.name
            )

        guard
            messages[
                fullName
            ] == nil
        else {
            throw RightClickError(
                "Duplicate reflected protobuf message: "
                + fullName
            )
        }

        messages[
            fullName
        ] =
            message

        for enumeration in
            message.enumType
        {
            let enumName =
                joinedName(
                    prefix:
                        fullName,
                    name:
                        enumeration.name
                )

            guard
                enums[
                    enumName
                ] == nil
            else {
                throw RightClickError(
                    "Duplicate reflected protobuf enum: "
                    + enumName
                )
            }

            enums[
                enumName
            ] =
                enumeration
        }

        for nested in
            message.nestedType
        {
            try collect(
                message:
                    nested,
                prefix:
                    fullName,
                messages:
                    &messages,
                enums:
                    &enums
            )
        }
    }

    private static func messageContract(
        name: String,
        messages:
            [
                String:
                    Google_Protobuf_DescriptorProto
            ],
        enums:
            [
                String:
                    Google_Protobuf_EnumDescriptorProto
            ]
    ) -> MessageContract {
        guard
            let descriptor =
                messages[
                    name
                ]
        else {
            return MessageContract(
                fullName:
                    name,
                fields:
                    [],
                limitation:
                    "message descriptor was not supplied by reflection"
            )
        }

        var fields:
            [FieldContract] = []

        var names =
            Set<String>()

        var numbers =
            Set<Int>()

        for field in
            descriptor.field
            .sorted(
                by: {
                    $0.number
                        < $1.number
                }
            )
        {
            guard
                !field.name.isEmpty,
                field.number > 0,
                names
                    .insert(
                        field.name
                    )
                    .inserted,
                numbers
                    .insert(
                        Int(
                            field.number
                        )
                    )
                    .inserted
            else {
                return MessageContract(
                    fullName:
                        name,
                    fields:
                        [],
                    limitation:
                        "field names or numbers are invalid or duplicated"
                )
            }

            if field.label
                == .repeated
            {
                return MessageContract(
                    fullName:
                        name,
                    fields:
                        [],
                    limitation:
                        "repeated fields are outside the current closed protobuf subset"
                )
            }

            if
                field.hasOneofIndex,
                !field.proto3Optional
            {
                return MessageContract(
                    fullName:
                        name,
                    fields:
                        [],
                    limitation:
                        "oneof fields are outside the current closed protobuf subset"
                )
            }

            guard
                let kind =
                    fieldKind(
                        field,
                        enums:
                            enums
                    )
            else {
                return MessageContract(
                    fullName:
                        name,
                    fields:
                        [],
                    limitation:
                        "nested messages, groups or unresolved enum types are outside the current closed protobuf subset"
                )
            }

            fields.append(
                FieldContract(
                    name:
                        field.name,
                    number:
                        Int(
                            field.number
                        ),
                    kind:
                        kind,
                    required:
                        field.label
                        == .required
                )
            )
        }

        return MessageContract(
            fullName:
                name,
            fields:
                fields,
            limitation:
                nil
        )
    }

    private static func fieldKind(
        _ field:
            Google_Protobuf_FieldDescriptorProto,
        enums:
            [
                String:
                    Google_Protobuf_EnumDescriptorProto
            ]
    ) -> FieldKind? {
        switch field.type {
        case .double:
            return .double

        case .float:
            return .float

        case .int64:
            return .int64

        case .uint64:
            return .uint64

        case .int32:
            return .int32

        case .fixed64:
            return .fixed64

        case .fixed32:
            return .fixed32

        case .bool:
            return .bool

        case .string:
            return .string

        case .bytes:
            return .bytes

        case .uint32:
            return .uint32

        case .`enum`:
            let typeName =
                normalizeTypeName(
                    field.typeName
                )

            guard
                let descriptor =
                    enums[
                        typeName
                    ]
            else {
                return nil
            }

            var nameToNumber:
                [String: Int32] = [:]

            var numberToName:
                [Int32: String] = [:]

            for value in
                descriptor.value
            {
                guard
                    !value.name.isEmpty
                else {
                    continue
                }

                nameToNumber[
                    value.name
                ] =
                    value.number

                if numberToName[
                    value.number
                ] == nil
                {
                    numberToName[
                        value.number
                    ] =
                        value.name
                }
            }

            return .enumeration(
                EnumContract(
                    nameToNumber:
                        nameToNumber,
                    numberToName:
                        numberToName
                )
            )

        case .sfixed32:
            return .sfixed32

        case .sfixed64:
            return .sfixed64

        case .sint32:
            return .sint32

        case .sint64:
            return .sint64

        case .message,
             .group:
            return nil
        }
    }

    private static func argumentsSchema(
        _ message:
            MessageContract
    ) -> String {
        var properties:
            [String: Any] = [:]

        var required:
            [String] = []

        for field in
            message.fields
        {
            var property:
                [String: Any] = [
                    "type":
                        "string",
                    "description":
                        field
                            .kind
                            .description,
                ]

            if case let .enumeration(
                contract
            ) =
                field.kind
            {
                property[
                    "enum"
                ] =
                    contract
                        .nameToNumber
                        .keys
                        .sorted()
            }

            properties[
                field.name
            ] =
                property

            if field.required {
                required.append(
                    field.name
                )
            }
        }

        let schema:
            [String: Any] = [
                "type":
                    "object",
                "additionalProperties":
                    false,
                "properties":
                    properties,
                "required":
                    required.sorted(),
            ]

        guard
            let data =
                try? JSONSerialization
                    .data(
                        withJSONObject:
                            schema,
                        options: [
                            .sortedKeys
                        ]
                    ),
            let text =
                String(
                    data:
                        data,
                    encoding:
                        .utf8
                )
        else {
            return "{}"
        }

        return text
    }

    private static func encode(
        _ arguments:
            CapabilityArguments,
        message:
            MessageContract
    ) throws -> Data {
        var writer =
            GRPCWireWriter()

        for field in
            message
                .fields
                .sorted(
                    by: {
                        $0.number
                            < $1.number
                    }
                )
        {
            guard
                let raw =
                    arguments[
                        field.name
                    ]
            else {
                continue
            }

            try encode(
                raw,
                field:
                    field,
                writer:
                    &writer
            )
        }

        return writer.data
    }

    private static func encode(
        _ raw: String,
        field: FieldContract,
        writer:
            inout GRPCWireWriter
    ) throws {
        switch field.kind {
        case .double:
            guard
                let value =
                    Double(raw),
                value.isFinite
            else {
                throw RightClickError(
                    field.name
                    + " must be a finite protobuf double."
                )
            }

            writer
                .writeFixed64Field(
                    field.number,
                    value:
                        value.bitPattern
                )

        case .float:
            guard
                let value =
                    Float(raw),
                value.isFinite
            else {
                throw RightClickError(
                    field.name
                    + " must be a finite protobuf float."
                )
            }

            writer
                .writeFixed32Field(
                    field.number,
                    value:
                        value.bitPattern
                )

        case .int64:
            guard
                let value =
                    Int64(raw)
            else {
                throw invalidInteger(
                    field
                )
            }

            writer
                .writeVarintField(
                    field.number,
                    value:
                        UInt64(
                            bitPattern:
                                value
                        )
                )

        case .uint64:
            guard
                let value =
                    UInt64(raw)
            else {
                throw invalidInteger(
                    field
                )
            }

            writer
                .writeVarintField(
                    field.number,
                    value:
                        value
                )

        case .int32:
            guard
                let value =
                    Int32(raw)
            else {
                throw invalidInteger(
                    field
                )
            }

            writer
                .writeVarintField(
                    field.number,
                    value:
                        UInt64(
                            bitPattern:
                                Int64(
                                    value
                                )
                        )
                )

        case .fixed64:
            guard
                let value =
                    UInt64(raw)
            else {
                throw invalidInteger(
                    field
                )
            }

            writer
                .writeFixed64Field(
                    field.number,
                    value:
                        value
                )

        case .fixed32:
            guard
                let value =
                    UInt32(raw)
            else {
                throw invalidInteger(
                    field
                )
            }

            writer
                .writeFixed32Field(
                    field.number,
                    value:
                        value
                )

        case .bool:
            let value:
                Bool

            if raw == "true" {
                value = true
            } else if raw == "false" {
                value = false
            } else {
                throw RightClickError(
                    field.name
                    + " must be true or false."
                )
            }

            writer
                .writeVarintField(
                    field.number,
                    value:
                        value
                        ? 1
                        : 0
                )

        case .string:
            writer
                .writeStringField(
                    field.number,
                    value:
                        raw
                )

        case .bytes:
            guard
                let data =
                    Data(
                        base64Encoded:
                            raw
                    )
            else {
                throw RightClickError(
                    field.name
                    + " must be base64."
                )
            }

            writer
                .writeLengthDelimitedField(
                    field.number,
                    data:
                        data
                )

        case .uint32:
            guard
                let value =
                    UInt32(raw)
            else {
                throw invalidInteger(
                    field
                )
            }

            writer
                .writeVarintField(
                    field.number,
                    value:
                        UInt64(
                            value
                        )
                )

        case let .enumeration(
            contract
        ):
            guard
                let value =
                    contract
                        .nameToNumber[
                            raw
                        ]
            else {
                throw RightClickError(
                    field.name
                    + " must be one of: "
                    + contract
                        .nameToNumber
                        .keys
                        .sorted()
                        .joined(
                            separator:
                                ", "
                        )
                )
            }

            writer
                .writeVarintField(
                    field.number,
                    value:
                        UInt64(
                            bitPattern:
                                Int64(
                                    value
                                )
                        )
                )

        case .sfixed32:
            guard
                let value =
                    Int32(raw)
            else {
                throw invalidInteger(
                    field
                )
            }

            writer
                .writeFixed32Field(
                    field.number,
                    value:
                        UInt32(
                            bitPattern:
                                value
                        )
                )

        case .sfixed64:
            guard
                let value =
                    Int64(raw)
            else {
                throw invalidInteger(
                    field
                )
            }

            writer
                .writeFixed64Field(
                    field.number,
                    value:
                        UInt64(
                            bitPattern:
                                value
                        )
                )

        case .sint32:
            guard
                let value =
                    Int32(raw)
            else {
                throw invalidInteger(
                    field
                )
            }

            let encoded =
                UInt32(
                    bitPattern:
                        (value &<< 1)
                        ^ (value >> 31)
                )

            writer
                .writeVarintField(
                    field.number,
                    value:
                        UInt64(
                            encoded
                        )
                )

        case .sint64:
            guard
                let value =
                    Int64(raw)
            else {
                throw invalidInteger(
                    field
                )
            }

            let encoded =
                UInt64(
                    bitPattern:
                        (value &<< 1)
                        ^ (value >> 63)
                )

            writer
                .writeVarintField(
                    field.number,
                    value:
                        encoded
                )
        }
    }

    private static func decode(
        _ data: Data,
        message:
            MessageContract
    ) throws -> String {
        let fieldsByNumber =
            Dictionary(
                uniqueKeysWithValues:
                    message
                        .fields
                        .map {
                            (
                                $0.number,
                                $0
                            )
                        }
            )

        var reader =
            GRPCWireReader(
                data
            )

        var object:
            [String: Any] = [:]

        while
            let key =
                try reader
                    .readKey()
        {
            guard
                let field =
                    fieldsByNumber[
                        key.fieldNumber
                    ]
            else {
                try reader
                    .skip(
                        wireType:
                            key.wireType
                    )

                continue
            }

            guard
                key.wireType
                    == field
                        .kind
                        .wireType
            else {
                throw RightClickError(
                    "Field "
                    + field.name
                    + " used an unexpected protobuf wire type."
                )
            }

            object[
                field.name
            ] =
                try decodeValue(
                    reader:
                        &reader,
                    kind:
                        field.kind
                )
        }

        guard
            JSONSerialization
                .isValidJSONObject(
                    object
                ),
            let encoded =
                try? JSONSerialization
                    .data(
                        withJSONObject:
                            object,
                        options: [
                            .sortedKeys
                        ]
                    ),
            let output =
                String(
                    data:
                        encoded,
                    encoding:
                        .utf8
                )
        else {
            throw RightClickError(
                "Decoded protobuf response could not be represented as JSON."
            )
        }

        return output
    }

    private static func decodeValue(
        reader:
            inout GRPCWireReader,
        kind:
            FieldKind
    ) throws -> Any {
        switch kind {
        case .double:
            let value =
                Double(
                    bitPattern:
                        try reader
                            .readFixed64()
                )

            if value.isNaN {
                return "NaN"
            }

            if value
                == .infinity
            {
                return "Infinity"
            }

            if value
                == -.infinity
            {
                return "-Infinity"
            }

            return NSNumber(
                value:
                    value
            )

        case .float:
            let value =
                Float(
                    bitPattern:
                        try reader
                            .readFixed32()
                )

            if value.isNaN {
                return "NaN"
            }

            if value
                == .infinity
            {
                return "Infinity"
            }

            if value
                == -.infinity
            {
                return "-Infinity"
            }

            return NSNumber(
                value:
                    value
            )

        case .int64:
            return String(
                Int64(
                    bitPattern:
                        try reader
                            .readVarint()
                )
            )

        case .uint64:
            return String(
                try reader
                    .readVarint()
            )

        case .int32:
            let raw =
                UInt32(
                    truncatingIfNeeded:
                        try reader
                            .readVarint()
                )

            return NSNumber(
                value:
                    Int32(
                        bitPattern:
                            raw
                    )
            )

        case .fixed64:
            return String(
                try reader
                    .readFixed64()
            )

        case .fixed32:
            return NSNumber(
                value:
                    try reader
                        .readFixed32()
            )

        case .bool:
            return
                try reader
                    .readVarint()
                != 0

        case .string:
            let data =
                try reader
                    .readLengthDelimited()

            guard
                let value =
                    String(
                        data:
                            data,
                        encoding:
                            .utf8
                    )
            else {
                throw RightClickError(
                    "Protobuf string response is not valid UTF-8."
                )
            }

            return value

        case .bytes:
            return
                try reader
                    .readLengthDelimited()
                    .base64EncodedString()

        case .uint32:
            return NSNumber(
                value:
                    UInt32(
                        truncatingIfNeeded:
                            try reader
                                .readVarint()
                    )
            )

        case let .enumeration(
            contract
        ):
            let raw =
                UInt32(
                    truncatingIfNeeded:
                        try reader
                            .readVarint()
                )

            let number =
                Int32(
                    bitPattern:
                        raw
                )

            return
                contract
                    .numberToName[
                        number
                    ]
                ?? String(
                    number
                )

        case .sfixed32:
            return NSNumber(
                value:
                    Int32(
                        bitPattern:
                            try reader
                                .readFixed32()
                    )
            )

        case .sfixed64:
            return String(
                Int64(
                    bitPattern:
                        try reader
                            .readFixed64()
                )
            )

        case .sint32:
            let raw =
                UInt32(
                    truncatingIfNeeded:
                        try reader
                            .readVarint()
                )

            let decoded =
                Int32(
                    bitPattern:
                        raw >> 1
                )
                ^ -Int32(
                    raw & 1
                )

            return NSNumber(
                value:
                    decoded
            )

        case .sint64:
            let raw =
                try reader
                    .readVarint()

            let decoded =
                Int64(
                    bitPattern:
                        raw >> 1
                )
                ^ -Int64(
                    raw & 1
                )

            return String(
                decoded
            )
        }
    }

    private static func invalidInteger(
        _ field:
            FieldContract
    ) -> RightClickError {
        RightClickError(
            field.name
            + " is outside the supported range for "
            + field.kind.description
            + "."
        )
    }

    private static func joinedName(
        prefix: String,
        name: String
    ) -> String {
        if prefix.isEmpty {
            return name
        }

        return
            prefix
            + "."
            + name
    }

    private static func normalizeTypeName(
        _ raw: String
    ) -> String {
        raw.hasPrefix(".")
        ? String(
            raw.dropFirst()
        )
        : raw
    }

    private static func sha256Hex(
        _ data: Data
    ) -> String {
        SHA256
            .hash(
                data:
                    data
            )
            .map {
                String(
                    format:
                        "%02x",
                    $0
                )
            }
            .joined()
    }
}
#endif
