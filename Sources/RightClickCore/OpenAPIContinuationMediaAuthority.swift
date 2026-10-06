import Foundation

enum OpenAPIProviderContinuationMediaAbstentionReason:
    String,
    Sendable
{
    case missingRuntimeContentType =
        "missing_runtime_content_type"

    case invalidRuntimeContentType =
        "invalid_runtime_content_type"

    case noDeclaredRequestMedia =
        "no_declared_request_media"

    case staticDynamicConflict =
        "static_dynamic_conflict"
}

/// Media authority exists only when the provider's runtime Content-Type
/// is compatible with a request media representation declared by the
/// discovered OpenAPI operation.
struct OpenAPIProviderContinuationMediaAuthority:
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    let selectedContentType: String
    let normalizedContentType: String
    let matchingDeclaredMediaType: String

    let source:
        String = "static_and_runtime_agree"

    var description: String {
        "OpenAPIProviderContinuationMediaAuthority("
        + "selectedContentType: \(selectedContentType), "
        + "normalizedContentType: \(normalizedContentType), "
        + "matchingDeclaredMediaType: \(matchingDeclaredMediaType), "
        + "source: \(source))"
    }

    var debugDescription: String {
        description
    }
}

/// An explicit, inspectable fail-closed result.
///
/// It deliberately contains no selected Content-Type.
struct OpenAPIProviderContinuationMediaAbstention:
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    let reason:
        OpenAPIProviderContinuationMediaAbstentionReason

    let runtimeContentType: String?
    let declaredRequestMedia: [String]

    var description: String {
        "OpenAPIProviderContinuationMediaAbstention("
        + "reason: \(reason.rawValue), "
        + "runtimeContentType: \(runtimeContentType ?? "none"), "
        + "declaredRequestMedia: \(declaredRequestMedia))"
    }

    var debugDescription: String {
        description
    }
}

enum OpenAPIProviderContinuationMediaResolution:
    Sendable
{
    case resolved(
        OpenAPIProviderContinuationMediaAuthority
    )

    case abstain(
        OpenAPIProviderContinuationMediaAbstention
    )
}

/// GREEN-007B4B deliberately exposes no caller-supplied media input.
///
/// Both sides of the decision already come from the provider-derived
/// continuation target:
///
/// - runtime Content-Type from the concrete provider response recipe;
/// - declared request media from the discovered OpenAPI operation.
///
/// A runtime value may resolve only when it is compatible with at least
/// one declared OpenAPI request media type/range.
///
/// A conflict never creates precedence implicitly.
enum OpenAPIProviderContinuationMediaAuthorityBinder {
    static func resolve(
        target: OpenAPIProviderContinuationTarget
    ) -> OpenAPIProviderContinuationMediaResolution {
        let declared =
            target
                .declaredRequestMedia
                .map {
                    (
                        original:
                            $0,
                        normalized:
                            normalizeDeclaredMedia(
                                $0
                            )
                    )
                }
                .filter {
                    $0.normalized
                        != nil
                }

        guard
            !declared.isEmpty
        else {
            return .abstain(
                OpenAPIProviderContinuationMediaAbstention(
                    reason:
                        .noDeclaredRequestMedia,
                    runtimeContentType:
                        target
                            .providerReturnedContentType,
                    declaredRequestMedia:
                        target
                            .declaredRequestMedia
                )
            )
        }

        guard
            let runtimeRaw =
                target
                    .providerReturnedContentType?
                    .trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    ),
            !runtimeRaw.isEmpty
        else {
            return .abstain(
                OpenAPIProviderContinuationMediaAbstention(
                    reason:
                        .missingRuntimeContentType,
                    runtimeContentType:
                        target
                            .providerReturnedContentType,
                    declaredRequestMedia:
                        target
                            .declaredRequestMedia
                )
            )
        }

        guard
            let runtime =
                normalizeConcreteMedia(
                    runtimeRaw
                )
        else {
            return .abstain(
                OpenAPIProviderContinuationMediaAbstention(
                    reason:
                        .invalidRuntimeContentType,
                    runtimeContentType:
                        runtimeRaw,
                    declaredRequestMedia:
                        target
                            .declaredRequestMedia
                )
            )
        }

        let matches =
            declared
                .compactMap {
                    candidate
                    -> (
                        original:
                            String,
                        specificity:
                            Int
                    )?
                    in

                    guard
                        let normalized =
                            candidate.normalized,
                        let specificity =
                            matchSpecificity(
                                runtime:
                                    runtime,
                                declared:
                                    normalized
                            )
                    else {
                        return nil
                    }

                    return (
                        original:
                            candidate.original,
                        specificity:
                            specificity
                    )
                }
                .sorted {
                    if
                        $0.specificity
                        != $1.specificity
                    {
                        return
                            $0.specificity
                            > $1.specificity
                    }

                    return
                        $0.original
                        < $1.original
                }

        guard
            let best =
                matches.first
        else {
            return .abstain(
                OpenAPIProviderContinuationMediaAbstention(
                    reason:
                        .staticDynamicConflict,
                    runtimeContentType:
                        runtimeRaw,
                    declaredRequestMedia:
                        target
                            .declaredRequestMedia
                )
            )
        }

        return .resolved(
            OpenAPIProviderContinuationMediaAuthority(
                selectedContentType:
                    runtimeRaw,
                normalizedContentType:
                    runtime,
                matchingDeclaredMediaType:
                    best.original
            )
        )
    }

    private static func normalizeConcreteMedia(
        _ raw: String
    ) -> String? {
        let base =
            raw
                .split(
                    separator:
                        ";",
                    maxSplits:
                        1,
                    omittingEmptySubsequences:
                        false
                )
                .first
                .map(
                    String.init
                )?
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
                .lowercased()

        guard
            let base,
            !base.isEmpty
        else {
            return nil
        }

        let pieces =
            base.split(
                separator:
                    "/",
                omittingEmptySubsequences:
                    false
            )

        guard
            pieces.count == 2
        else {
            return nil
        }

        let type =
            String(
                pieces[0]
            )

        let subtype =
            String(
                pieces[1]
            )

        guard
            validToken(
                type
            ),
            validToken(
                subtype
            ),
            type != "*",
            subtype != "*"
        else {
            return nil
        }

        return
            type
            + "/"
            + subtype
    }

    private static func normalizeDeclaredMedia(
        _ raw: String
    ) -> String? {
        let base =
            raw
                .split(
                    separator:
                        ";",
                    maxSplits:
                        1,
                    omittingEmptySubsequences:
                        false
                )
                .first
                .map(
                    String.init
                )?
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
                .lowercased()

        guard
            let base,
            !base.isEmpty
        else {
            return nil
        }

        let pieces =
            base.split(
                separator:
                    "/",
                omittingEmptySubsequences:
                    false
            )

        guard
            pieces.count == 2
        else {
            return nil
        }

        let type =
            String(
                pieces[0]
            )

        let subtype =
            String(
                pieces[1]
            )

        let typeValid =
            type == "*"
            || validToken(
                type
            )

        let subtypeValid =
            subtype == "*"
            || validToken(
                subtype
            )

        guard
            typeValid,
            subtypeValid
        else {
            return nil
        }

        if
            type == "*",
            subtype != "*"
        {
            return nil
        }

        return
            type
            + "/"
            + subtype
    }

    private static func matchSpecificity(
        runtime: String,
        declared: String
    ) -> Int? {
        let runtimePieces =
            runtime.split(
                separator:
                    "/",
                omittingEmptySubsequences:
                    false
            )

        let declaredPieces =
            declared.split(
                separator:
                    "/",
                omittingEmptySubsequences:
                    false
            )

        guard
            runtimePieces.count == 2,
            declaredPieces.count == 2
        else {
            return nil
        }

        let runtimeType =
            String(
                runtimePieces[0]
            )

        let runtimeSubtype =
            String(
                runtimePieces[1]
            )

        let declaredType =
            String(
                declaredPieces[0]
            )

        let declaredSubtype =
            String(
                declaredPieces[1]
            )

        if
            runtimeType
            == declaredType,
            runtimeSubtype
            == declaredSubtype
        {
            return 2
        }

        if
            runtimeType
            == declaredType,
            declaredSubtype
            == "*"
        {
            return 1
        }

        if
            declaredType
            == "*",
            declaredSubtype
            == "*"
        {
            return 0
        }

        return nil
    }

    private static func validToken(
        _ value: String
    ) -> Bool {
        guard
            !value.isEmpty
        else {
            return false
        }

        let allowed =
            CharacterSet(
                charactersIn:
                    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                    + "abcdefghijklmnopqrstuvwxyz"
                    + "0123456789"
                    + "!#$&^_.+-"
            )

        return
            value
                .unicodeScalars
                .allSatisfy {
                    allowed
                        .contains(
                            $0
                        )
                }
    }
}
