import Foundation

enum OpenAPIProviderContinuationRedirectPolicy:
    String,
    Sendable
{
    case reject
}

struct OpenAPIProviderContinuationHTTPResponse:
    Sendable
{
    let statusCode: Int
    let data: Data
}

protocol OpenAPIProviderContinuationHTTPClient {
    func send(
        _ request: URLRequest,
        redirectPolicy:
            OpenAPIProviderContinuationRedirectPolicy
    ) throws
        -> OpenAPIProviderContinuationHTTPResponse
}

enum OpenAPIProviderContinuationTransportBindingFailure:
    String,
    Sendable
{
    case authorityTargetResponseMismatch =
        "authority_target_response_mismatch"

    case authorityTargetOperationMismatch =
        "authority_target_operation_mismatch"

    case authorityTargetOriginMismatch =
        "authority_target_origin_mismatch"

    case bodyTargetMismatch =
        "body_target_mismatch"

    case bodyHashMismatch =
        "body_hash_mismatch"

    case bodySizeMismatch =
        "body_size_mismatch"

    case targetOriginMismatch =
        "target_origin_mismatch"
}

enum OpenAPIProviderContinuationTransportOutcome:
    Sendable
{
    case confirmationRequired

    case bindingRejected(
        OpenAPIProviderContinuationTransportBindingFailure
    )

    case mediaAbstained(
        OpenAPIProviderContinuationMediaAbstentionReason
    )

    case redirectRejected(
        statusCode:
            Int
    )

    case providerRejected(
        statusCode:
            Int,
        responseData:
            Data
    )

    case providerAccepted(
        statusCode:
            Int,
        responseData:
            Data,
        semanticOutcomeVerified:
            Bool
    )
}

/// Materializes and submits one already-bound provider continuation.
///
/// Caller authority is intentionally narrow:
///
/// - caller may choose whether the user confirmed;
/// - caller supplies an injected HTTP client.
///
/// Caller cannot supply URL, method, bearer token, Authorization,
/// Content-Type, raw body bytes, expected hash, expected size, path
/// arguments or redirect targets.
enum OpenAPIProviderContinuationTransport {
    static func execute(
        authority:
            OpenAPIProviderContinuationAuthority,
        target:
            OpenAPIProviderContinuationTarget,
        body:
            OpenAPIProviderContinuationBody,
        confirmed:
            Bool,
        client:
            any OpenAPIProviderContinuationHTTPClient
    ) throws
        -> OpenAPIProviderContinuationTransportOutcome
    {
        // Confirmation is deliberately the first execution gate.
        //
        // An unconfirmed mutation does not resolve private material,
        // construct URLRequest or call the injected client.
        guard
            confirmed
        else {
            return
                .confirmationRequired
        }

        guard
            authority
                .sourceResponseSHA256
            == target
                .sourceResponseSHA256
        else {
            return .bindingRejected(
                .authorityTargetResponseMismatch
            )
        }

        guard
            authority
                .targetOperationID
            == target
                .operationID
        else {
            return .bindingRejected(
                .authorityTargetOperationMismatch
            )
        }

        guard
            authority
                .providerOrigin
            == target
                .providerOrigin
        else {
            return .bindingRejected(
                .authorityTargetOriginMismatch
            )
        }

        guard
            body
                .targetFingerprintSHA256
            == target
                .concreteTargetFingerprintSHA256
        else {
            return .bindingRejected(
                .bodyTargetMismatch
            )
        }

        guard
            body
                .proofSHA256
            == target
                .proofSHA256
        else {
            return .bindingRejected(
                .bodyHashMismatch
            )
        }

        guard
            body
                .proofSize
            == target
                .proofSize
        else {
            return .bindingRejected(
                .bodySizeMismatch
            )
        }

        let mediaResolution =
            OpenAPIProviderContinuationMediaAuthorityBinder
                .resolve(
                    target:
                        target
                )

        let mediaAuthority:
            OpenAPIProviderContinuationMediaAuthority

        switch mediaResolution {
        case let .resolved(
            resolved
        ):
            mediaAuthority =
                resolved

        case let .abstain(
            abstention
        ):
            return .mediaAbstained(
                abstention.reason
            )
        }

        return try target
            .withConcreteURL {
                concreteURL in

                guard
                    canonicalOrigin(
                        concreteURL
                    )
                    == target
                        .providerOrigin
                else {
                    return .bindingRejected(
                        .targetOriginMismatch
                    )
                }

                return try body
                    .withBytes {
                        bodyBytes in

                        return try authority
                            .withBearerToken {
                                bearerToken in

                                var request =
                                    URLRequest(
                                        url:
                                            concreteURL
                                    )

                                request.httpMethod =
                                    target.method

                                request.httpBody =
                                    bodyBytes

                                request.setValue(
                                    "Bearer "
                                    + bearerToken,
                                    forHTTPHeaderField:
                                        "Authorization"
                                )

                                request.setValue(
                                    mediaAuthority
                                        .selectedContentType,
                                    forHTTPHeaderField:
                                        "Content-Type"
                                )

                                let response =
                                    try client.send(
                                        request,
                                        redirectPolicy:
                                            .reject
                                    )

                                if
                                    (300..<400)
                                        .contains(
                                            response
                                                .statusCode
                                        )
                                {
                                    return
                                        .redirectRejected(
                                            statusCode:
                                                response
                                                    .statusCode
                                        )
                                }

                                if
                                    (200..<300)
                                        .contains(
                                            response
                                                .statusCode
                                        )
                                {
                                    return
                                        .providerAccepted(
                                            statusCode:
                                                response
                                                    .statusCode,
                                            responseData:
                                                response
                                                    .data,
                                            semanticOutcomeVerified:
                                                false
                                        )
                                }

                                return
                                    .providerRejected(
                                        statusCode:
                                            response
                                                .statusCode,
                                        responseData:
                                            response
                                                .data
                                    )
                            }
                    }
            }
    }

    private static func canonicalOrigin(
        _ url: URL
    ) -> String? {
        guard
            let components =
                URLComponents(
                    url:
                        url,
                    resolvingAgainstBaseURL:
                        false
                ),

            let rawScheme =
                components.scheme,

            let rawHost =
                components.host
        else {
            return nil
        }

        let scheme =
            rawScheme
                .lowercased()

        guard
            scheme == "http"
            || scheme == "https"
        else {
            return nil
        }

        let host =
            rawHost
                .lowercased()

        let port =
            components.port

        let defaultPort =
            (
                scheme == "https"
                ? 443
                : 80
            )

        if
            let port,
            port != defaultPort
        {
            return
                scheme
                + "://"
                + host
                + ":"
                + String(
                    port
                )
        }

        return
            scheme
            + "://"
            + host
    }
}
