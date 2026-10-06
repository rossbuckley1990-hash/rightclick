#if canImport(GRPC) && canImport(SwiftProtobuf) && canImport(NIOCore) && canImport(NIOPosix)
import Foundation
import GRPC
import NIOCore
import NIOPosix

public struct GRPCEndpoint:
    Equatable,
    Sendable
{
    public let scheme:
        String

    public let host:
        String

    public let port:
        Int

    public init(
        scheme rawScheme: String,
        host rawHost: String,
        port: Int
    ) throws {
        let scheme =
            rawScheme
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
                .lowercased()

        var host =
            rawHost
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        if host.hasSuffix(".") {
            host.removeLast()
        }

        host =
            host.lowercased()

        guard
            scheme == "grpc"
                || scheme == "grpcs",
            !host.isEmpty,
            !host.contains("/"),
            !host.contains("\\"),
            host.rangeOfCharacter(
                from:
                    .whitespacesAndNewlines
            ) == nil,
            host.rangeOfCharacter(
                from:
                    .controlCharacters
            ) == nil,
            (1...65_535)
                .contains(
                    port
                )
        else {
            throw RightClickError(
                "gRPC endpoint requires grpc or grpcs, a valid host and a TCP port."
            )
        }

        self.scheme =
            scheme

        self.host =
            host

        self.port =
            port
    }

    var usesTLS: Bool {
        scheme == "grpcs"
    }

    public var identity: String {
        let formattedHost =
            host.contains(":")
            ? "[" + host + "]"
            : host

        return
            scheme
            + "://"
            + formattedHost
            + ":"
            + String(port)
    }
}

struct GRPCRawPayload:
    GRPCPayload
{
    let data:
        Data

    init(
        data: Data
    ) {
        self.data =
            data
    }

    init(
        serializedByteBuffer:
            inout ByteBuffer
    ) throws {
        let count =
            serializedByteBuffer
                .readableBytes

        guard
            let bytes =
                serializedByteBuffer
                    .readBytes(
                        length:
                            count
                    )
        else {
            throw RightClickError(
                "Could not decode raw gRPC payload."
            )
        }

        data =
            Data(bytes)
    }

    func serialize(
        into buffer:
            inout ByteBuffer
    ) throws {
        buffer.writeBytes(
            data
        )
    }
}

enum GRPCReflectionTransportError:
    Error,
    LocalizedError
{
    case noResponse
    case status(String)
    case malformedResponse(String)
    case providerTooLarge
    case tooManyServices

    var errorDescription:
        String?
    {
        switch self {
        case .noResponse:
            return
                "gRPC reflection returned no response."

        case let .status(value):
            return
                "gRPC call failed: "
                + value

        case let .malformedResponse(value):
            return
                "Malformed gRPC reflection response: "
                + value

        case .providerTooLarge:
            return
                "gRPC reflection descriptor set exceeded the 16 MiB limit."

        case .tooManyServices:
            return
                "gRPC reflection advertised more than 256 services."
        }
    }
}

enum GRPCReflectionWire {
    static func listServicesRequest()
        -> Data
    {
        var writer =
            GRPCWireWriter()

        writer
            .writeStringField(
                7,
                value:
                    ""
            )

        return writer.data
    }

    static func fileContainingSymbolRequest(
        _ symbol: String
    ) -> Data {
        var writer =
            GRPCWireWriter()

        writer
            .writeStringField(
                4,
                value:
                    symbol
            )

        return writer.data
    }

    static func listServices(
        from data: Data
    ) throws -> [String] {
        var reader =
            GRPCWireReader(
                data
            )

        var services:
            [String] = []

        while
            let key =
                try reader
                    .readKey()
        {
            switch key.fieldNumber {
            case 6:
                guard
                    key.wireType == 2
                else {
                    throw GRPCReflectionTransportError
                        .malformedResponse(
                            "list_services_response has the wrong wire type"
                        )
                }

                let nested =
                    try reader
                        .readLengthDelimited()

                services.append(
                    contentsOf:
                        try parseServiceList(
                            nested
                        )
                )

            case 7:
                guard
                    key.wireType == 2
                else {
                    throw GRPCReflectionTransportError
                        .malformedResponse(
                            "error_response has the wrong wire type"
                        )
                }

                throw
                    parseError(
                        try reader
                            .readLengthDelimited()
                    )

            default:
                try reader
                    .skip(
                        wireType:
                            key.wireType
                    )
            }
        }

        return services
    }

    static func fileDescriptors(
        from data: Data
    ) throws -> [Data] {
        var reader =
            GRPCWireReader(
                data
            )

        var descriptors:
            [Data] = []

        while
            let key =
                try reader
                    .readKey()
        {
            switch key.fieldNumber {
            case 4:
                guard
                    key.wireType == 2
                else {
                    throw GRPCReflectionTransportError
                        .malformedResponse(
                            "file_descriptor_response has the wrong wire type"
                        )
                }

                let nested =
                    try reader
                        .readLengthDelimited()

                descriptors.append(
                    contentsOf:
                        try parseDescriptorList(
                            nested
                        )
                )

            case 7:
                guard
                    key.wireType == 2
                else {
                    throw GRPCReflectionTransportError
                        .malformedResponse(
                            "error_response has the wrong wire type"
                        )
                }

                throw
                    parseError(
                        try reader
                            .readLengthDelimited()
                    )

            default:
                try reader
                    .skip(
                        wireType:
                            key.wireType
                    )
            }
        }

        return descriptors
    }

    private static func parseServiceList(
        _ data: Data
    ) throws -> [String] {
        var reader =
            GRPCWireReader(
                data
            )

        var result:
            [String] = []

        while
            let key =
                try reader
                    .readKey()
        {
            guard
                key.fieldNumber == 1,
                key.wireType == 2
            else {
                try reader
                    .skip(
                        wireType:
                            key.wireType
                    )

                continue
            }

            let serviceData =
                try reader
                    .readLengthDelimited()

            var serviceReader =
                GRPCWireReader(
                    serviceData
                )

            while
                let serviceKey =
                    try serviceReader
                        .readKey()
            {
                if
                    serviceKey.fieldNumber
                        == 1,
                    serviceKey.wireType
                        == 2
                {
                    let rawName =
                        try serviceReader
                            .readLengthDelimited()

                    guard
                        let name =
                            String(
                                data:
                                    rawName,
                                encoding:
                                    .utf8
                            ),
                        !name.isEmpty
                    else {
                        throw GRPCReflectionTransportError
                            .malformedResponse(
                                "service name is not valid UTF-8"
                            )
                    }

                    result.append(
                        name
                    )
                } else {
                    try serviceReader
                        .skip(
                            wireType:
                                serviceKey
                                    .wireType
                        )
                }
            }
        }

        return result
    }

    private static func parseDescriptorList(
        _ data: Data
    ) throws -> [Data] {
        var reader =
            GRPCWireReader(
                data
            )

        var result:
            [Data] = []

        while
            let key =
                try reader
                    .readKey()
        {
            if
                key.fieldNumber == 1,
                key.wireType == 2
            {
                result.append(
                    try reader
                        .readLengthDelimited()
                )
            } else {
                try reader
                    .skip(
                        wireType:
                            key.wireType
                    )
            }
        }

        return result
    }

    private static func parseError(
        _ data: Data
    ) -> GRPCReflectionTransportError {
        var reader =
            GRPCWireReader(
                data
            )

        var code:
            UInt64?

        var message:
            String?

        do {
            while
                let key =
                    try reader
                        .readKey()
            {
                switch key.fieldNumber {
                case 1:
                    if key.wireType == 0 {
                        code =
                            try reader
                                .readVarint()
                    } else {
                        try reader
                            .skip(
                                wireType:
                                    key.wireType
                            )
                    }

                case 2:
                    if key.wireType == 2 {
                        let raw =
                            try reader
                                .readLengthDelimited()

                        message =
                            String(
                                data:
                                    raw,
                                encoding:
                                    .utf8
                            )
                    } else {
                        try reader
                            .skip(
                                wireType:
                                    key.wireType
                            )
                    }

                default:
                    try reader
                        .skip(
                            wireType:
                                key.wireType
                        )
                }
            }
        } catch {
            return .malformedResponse(
                "reflection error payload could not be decoded"
            )
        }

        return .status(
            "reflection error "
            + String(
                code ?? 0
            )
            + (
                message.map {
                    ": " + $0
                }
                ?? ""
            )
        )
    }
}

enum GRPCReflectionTransport {
    static let maximumDescriptorBytes =
        16_777_216

    static let maximumServices =
        256

    static let reflectionTimeoutSeconds:
        Int64 = 8

    static let invocationTimeoutSeconds:
        Int64 = 10

    static func discover(
        endpoint: GRPCEndpoint
    ) throws -> [Data] {
        try withConnection(
            endpoint:
                endpoint
        ) {
            connection in

            var lastError:
                Error?

            for path in [
                "/grpc.reflection.v1.ServerReflection/ServerReflectionInfo",
                "/grpc.reflection.v1alpha.ServerReflection/ServerReflectionInfo",
            ] {
                do {
                    return try discover(
                        connection:
                            connection,
                        reflectionPath:
                            path
                    )
                } catch {
                    lastError =
                        error
                }
            }

            throw
                lastError
                ?? GRPCReflectionTransportError
                    .noResponse
        }
    }

    static func invokeUnary(
        endpoint: GRPCEndpoint,
        path: String,
        request: Data
    ) throws -> Data {
        try withConnection(
            endpoint:
                endpoint
        ) {
            connection in

            let options =
                CallOptions(
                    timeLimit:
                        .timeout(
                            .seconds(
                                invocationTimeoutSeconds
                            )
                        )
                )

            let call:
                UnaryCall<
                    GRPCRawPayload,
                    GRPCRawPayload
                > =
                connection
                    .makeUnaryCall(
                        path:
                            path,
                        request:
                            GRPCRawPayload(
                                data:
                                    request
                            ),
                        callOptions:
                            options
                    )

            let response =
                try call
                    .response
                    .wait()

            let status =
                try call
                    .status
                    .wait()

            guard
                status.code == .ok
            else {
                throw GRPCReflectionTransportError
                    .status(
                        String(
                            describing:
                                status
                        )
                    )
            }

            return response.data
        }
    }

    private static func discover(
        connection: ClientConnection,
        reflectionPath: String
    ) throws -> [Data] {
        let serviceResponse =
            try exchange(
                connection:
                    connection,
                path:
                    reflectionPath,
                request:
                    GRPCReflectionWire
                        .listServicesRequest()
            )

        let services =
            try GRPCReflectionWire
                .listServices(
                    from:
                        serviceResponse
                )
                .filter {
                    !$0.hasPrefix(
                        "grpc.reflection."
                    )
                }

        guard
            services.count
                <= maximumServices
        else {
            throw GRPCReflectionTransportError
                .tooManyServices
        }

        var descriptors =
            Set<Data>()

        var totalBytes =
            0

        for service in
            services.sorted()
        {
            let response =
                try exchange(
                    connection:
                        connection,
                    path:
                        reflectionPath,
                    request:
                        GRPCReflectionWire
                            .fileContainingSymbolRequest(
                                service
                            )
                )

            let reflected =
                try GRPCReflectionWire
                    .fileDescriptors(
                        from:
                            response
                    )

            for descriptor in reflected {
                guard
                    !descriptors
                        .contains(
                            descriptor
                        )
                else {
                    continue
                }

                totalBytes +=
                    descriptor.count

                guard
                    totalBytes
                        <= maximumDescriptorBytes
                else {
                    throw GRPCReflectionTransportError
                        .providerTooLarge
                }

                descriptors.insert(
                    descriptor
                )
            }
        }

        return descriptors.sorted {
            $0.lexicographicallyPrecedes(
                $1
            )
        }
    }

    private static func exchange(
        connection: ClientConnection,
        path: String,
        request: Data
    ) throws -> Data {
        final class ResponseBox:
            @unchecked Sendable
        {
            private let lock =
                NSLock()

            private var values:
                [Data] = []

            func append(
                _ value: Data
            ) {
                lock.lock()

                values.append(
                    value
                )

                lock.unlock()
            }

            func first()
                -> Data?
            {
                lock.lock()

                defer {
                    lock.unlock()
                }

                return values.first
            }
        }

        let box =
            ResponseBox()

        let options =
            CallOptions(
                timeLimit:
                    .timeout(
                        .seconds(
                            reflectionTimeoutSeconds
                        )
                    )
            )

        let call:
            BidirectionalStreamingCall<
                GRPCRawPayload,
                GRPCRawPayload
            > =
            connection
                .makeBidirectionalStreamingCall(
                    path:
                        path,
                    callOptions:
                        options
                ) {
                    response in

                    box.append(
                        response.data
                    )
                }

        call.sendMessage(
            GRPCRawPayload(
                data:
                    request
            ),
            promise:
                nil
        )

        call.sendEnd(
            promise:
                nil
        )

        let status =
            try call
                .status
                .wait()

        guard
            status.code == .ok
        else {
            throw GRPCReflectionTransportError
                .status(
                    String(
                        describing:
                            status
                    )
                )
        }

        guard
            let response =
                box.first()
        else {
            throw GRPCReflectionTransportError
                .noResponse
        }

        return response
    }

    private static func withConnection<T>(
        endpoint: GRPCEndpoint,
        _ body:
            (ClientConnection) throws -> T
    ) throws -> T {
        let group =
            MultiThreadedEventLoopGroup(
                numberOfThreads:
                    1
            )

        defer {
            try? group
                .syncShutdownGracefully()
        }

        let connection:
            ClientConnection

        if endpoint.usesTLS {
            connection =
                ClientConnection
                    .usingPlatformAppropriateTLS(
                        for:
                            group
                    )
                    .connect(
                        host:
                            endpoint.host,
                        port:
                            endpoint.port
                    )
        } else {
            connection =
                ClientConnection
                    .insecure(
                        group:
                            group
                    )
                    .connect(
                        host:
                            endpoint.host,
                        port:
                            endpoint.port
                    )
        }

        defer {
            try? connection
                .close()
                .wait()
        }

        return try body(
            connection
        )
    }
}
#endif
