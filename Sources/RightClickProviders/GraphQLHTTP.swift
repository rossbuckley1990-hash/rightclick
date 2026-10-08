#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RightClickProtocol
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum GraphQLHTTP {
    static let maximumSchemaBytes =
        16_777_216

    static let maximumResponseBytes =
        16_777_216

    static let introspectionDeadline:
        TimeInterval = 8

    static let invocationDeadline:
        TimeInterval = 10

    private final class ResultBox:
        @unchecked Sendable
    {
        private let lock =
            NSLock()

        private var storedData:
            Data?

        private var storedResponse:
            URLResponse?

        private var storedError:
            Error?

        func store(
            data: Data?,
            response: URLResponse?,
            error: Error?
        ) {
            lock.lock()

            storedData =
                data

            storedResponse =
                response

            storedError =
                error

            lock.unlock()
        }

        func snapshot()
            -> (
                data: Data?,
                response: URLResponse?,
                error: Error?
            )
        {
            lock.lock()

            defer {
                lock.unlock()
            }

            return (
                storedData,
                storedResponse,
                storedError
            )
        }
    }

    static func canonicalEndpointURL(
        _ url: URL
    ) throws -> URL {
        guard
            var components =
                URLComponents(
                    url: url,
                    resolvingAgainstBaseURL:
                        false
                ),
            let rawScheme =
                components.scheme,
            let rawHost =
                components.host
        else {
            throw RightClickError(
                "GraphQL endpoint requires an absolute HTTP or HTTPS URL."
            )
        }

        let scheme =
            rawScheme.lowercased()

        guard
            scheme == "http"
                || scheme == "https",
            components.user == nil,
            components.password == nil,
            components.fragment == nil
        else {
            throw RightClickError(
                "GraphQL endpoint must use HTTP or HTTPS without embedded credentials or fragments."
            )
        }

        components.scheme =
            scheme

        components.host =
            rawHost.lowercased()

        if
            (
                scheme == "http"
                && components.port == 80
            )
            || (
                scheme == "https"
                && components.port == 443
            )
        {
            components.port =
                nil
        }

        if components.path.isEmpty {
            components.path =
                "/"
        }

        guard
            let result =
                components.url
        else {
            throw RightClickError(
                "Could not canonicalize GraphQL endpoint."
            )
        }

        return result
    }

    public static func canonicalOrigin(
        _ url: URL
    ) throws -> String {
        let endpoint =
            try canonicalEndpointURL(
                url
            )

        guard
            var components =
                URLComponents(
                    url: endpoint,
                    resolvingAgainstBaseURL:
                        false
                )
        else {
            throw RightClickError(
                "Could not canonicalize GraphQL authority origin."
            )
        }

        components.path =
            ""

        components.query =
            nil

        guard
            let origin =
                components.url
        else {
            throw RightClickError(
                "Could not construct GraphQL authority origin."
            )
        }

        var value =
            origin.absoluteString

        if value.hasSuffix("/") {
            value.removeLast()
        }

        return value
    }

    public static func validatedAuthoritySchemeName(
        _ raw: String?
    ) -> String? {
        guard
            let raw
        else {
            return nil
        }

        let value =
            raw.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        guard
            !value.isEmpty,
            !value.contains("|"),
            value.rangeOfCharacter(
                from:
                    .controlCharacters
            ) == nil
        else {
            return nil
        }

        return value
    }

    public static func bearerToken(
        origin: String,
        schemeName: String
    ) -> String? {
        // The existing store is already bound to exact HTTP origin +
        // bearer-scheme identity. Its type name predates GraphQL support,
        // but the authority material itself is substrate-independent.
        OpenAPIAuthorityStore
            .bearerToken(
                for:
                    .httpBearer(
                        schemeName:
                            schemeName,
                        origin:
                            origin
                    )
            )
    }

    static func perform(
        _ request: URLRequest,
        template:
            URLSession = .shared,
        deadline: TimeInterval,
        maximumBytes: Int,
        admitStart: ((_ start: () -> Void) throws -> Void)? = nil
    ) throws
        -> (
            response:
                HTTPURLResponse,
            data:
                Data
        )
    {
        if let admitStart {
            let (data, response) = try OriginPinnedHTTP.exchange(request, maximumBytes: maximumBytes,
                template: template, deadline: deadline, successfulStatusRequired: false, admitStart: admitStart)
            return (response, data)
        }
        precondition(
            maximumBytes > 0
        )

        guard
            let requestURL =
                request.url
        else {
            throw RightClickError(
                "GraphQL HTTP request requires an absolute URL."
            )
        }

        let session =
            OriginPinnedHTTP
                .makeSession(
                    template:
                        template
                )

        defer {
            session
                .invalidateAndCancel()
        }

        var boundedRequest =
            request

        boundedRequest.timeoutInterval =
            deadline

        let semaphore =
            DispatchSemaphore(
                value: 0
            )

        let box =
            ResultBox()

        let task =
            session.dataTask(
                with:
                    boundedRequest
            ) {
                data,
                response,
                error in

                box.store(
                    data: data,
                    response: response,
                    error: error
                )

                semaphore.signal()
            }

        task.resume()

        let wait =
            semaphore.wait(
                timeout:
                    .now()
                    + deadline
            )

        if wait == .timedOut {
            task.cancel()

            throw RightClickError(
                "GraphQL HTTP request exceeded the bounded deadline."
            )
        }

        let result =
            box.snapshot()

        if let error =
            result.error
        {
            throw RightClickError(
                "GraphQL HTTP request failed: "
                + error.localizedDescription
            )
        }

        guard
            let response =
                result.response
                    as? HTTPURLResponse
        else {
            throw RightClickError(
                "GraphQL provider returned no HTTP response."
            )
        }

        guard
            OriginPinnedHTTP
                .sameOrigin(
                    requestURL,
                    response.url
                )
        else {
            throw RightClickError(
                "GraphQL provider response escaped the selected origin."
            )
        }

        let data =
            result.data
            ?? Data()

        guard
            data.count
                <= maximumBytes
        else {
            throw RightClickError(
                "GraphQL provider response exceeded the maximum allowed size."
            )
        }

        return (
            response,
            data
        )
    }

    static func mediaType(
        _ response:
            HTTPURLResponse
    ) -> String? {
        response
            .value(
                forHTTPHeaderField:
                    "Content-Type"
            )?
            .split(
                separator: ";",
                maxSplits: 1
            )
            .first
            .map {
                String($0)
                    .trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    )
                    .lowercased()
            }
    }

    static func isSupportedGraphQLMediaType(
        _ response:
            HTTPURLResponse
    ) -> Bool {
        let mediaType =
            mediaType(
                response
            )

        return
            mediaType
                == "application/json"
            || mediaType
                == "application/graphql-response+json"
    }
}

public enum GraphQLIntrospection {
    static var query: String {
        let typeRef =
            typeRefSelection(
                depth: 8
            )

        return
            """
            query RightClickIntrospection {
              __schema {
                queryType { name }
                mutationType { name }
                types {
                  kind
                  name
                  enumValues { name }
                  inputFields {
                    name
                    defaultValue
                    type { \(typeRef) }
                  }
                  fields {
                    name
                    description
                    args {
                      name
                      defaultValue
                      type { \(typeRef) }
                    }
                    type { \(typeRef) }
                  }
                }
              }
            }
            """
    }

    private static func typeRefSelection(
        depth: Int
    ) -> String {
        var value =
            "kind name"

        guard depth > 0 else {
            return value
        }

        for _ in 0..<depth {
            value +=
                " ofType { kind name"
        }

        value +=
            String(
                repeating:
                    " }",
                count:
                    depth
            )

        return value
    }

    public static func load(
        endpointURL: URL,
        bearerToken: String?,
        session:
            URLSession = .shared
    ) throws -> Data {
        let endpoint =
            try GraphQLHTTP
                .canonicalEndpointURL(
                    endpointURL
                )

        let body:
            [String: Any] = [
                "query":
                    query,
                "operationName":
                    "RightClickIntrospection",
                "variables":
                    [String: Any](),
            ]

        let bodyData =
            try JSONSerialization
                .data(
                    withJSONObject:
                        body,
                    options:
                        [.sortedKeys]
                )

        var request =
            URLRequest(
                url:
                    endpoint
            )

        request.httpMethod =
            "POST"

        request.httpBody =
            bodyData

        request.setValue(
            "application/json",
            forHTTPHeaderField:
                "Content-Type"
        )

        request.setValue(
            "application/graphql-response+json, application/json",
            forHTTPHeaderField:
                "Accept"
        )

        if let bearerToken {
            request.setValue(
                "Bearer "
                    + bearerToken,
                forHTTPHeaderField:
                    "Authorization"
            )
        }

        let result =
            try GraphQLHTTP
                .perform(
                    request,
                    template:
                        session,
                    deadline:
                        GraphQLHTTP
                            .introspectionDeadline,
                    maximumBytes:
                        GraphQLHTTP
                            .maximumSchemaBytes
                )

        guard
            (200...299)
                .contains(
                    result
                        .response
                        .statusCode
                )
        else {
            throw RightClickError(
                "GraphQL introspection returned HTTP "
                + String(
                    result
                        .response
                        .statusCode
                )
                + "."
            )
        }

        guard
            GraphQLHTTP
                .isSupportedGraphQLMediaType(
                    result.response
                )
        else {
            throw RightClickError(
                "GraphQL introspection returned an unsupported content type."
            )
        }

        return result.data
    }
}
