import Foundation
import RightClickProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum OutcomeVerifier {
    public static func snapshot(
        item: ContentItem
    ) throws -> OutcomeSnapshot {
        guard let path = item.path else {
            return OutcomeSnapshot()
        }

        let manager = FileManager.default
        let exists = manager.fileExists(atPath: path)

        guard exists else {
            return OutcomeSnapshot(
                path: path,
                fileExists: false,
                fileReadable: false
            )
        }

        let readable = manager.isReadableFile(
            atPath: path
        )

        let attributes = try? manager.attributesOfItem(
            atPath: path
        )

        let size = (
            attributes?[.size] as? NSNumber
        )?.intValue

        let digest = readable
            ? sha256(path: path)
            : nil

        let image = imageObservation(
            path: path
        )

        return OutcomeSnapshot(
            path: path,
            fileExists: true,
            fileReadable: readable,
            fileSHA256: digest,
            fileSize: size,
            width: image.width,
            height: image.height,
            metadataValues: image.metadataValues
        )
    }

    public static func verify(
        spec: VerificationSpec,
        item: ContentItem,
        before: OutcomeSnapshot,
        returnedText: String?
    ) throws -> OutcomeVerification {
        guard !spec.predicates.isEmpty else {
            return OutcomeVerification(
                status: .unverified,
                predicates: []
            )
        }

        let after = try snapshot(
            item: item
        )

        let results = spec.predicates.map {
            evaluate(
                predicate: $0,
                before: before,
                after: after,
                returnedText: returnedText
            )
        }

        if results.contains(
            where: {
                $0.evaluated && !$0.passed
            }
        ) {
            return OutcomeVerification(
                status: .verifiedFailure,
                predicates: results
            )
        }

        if results.allSatisfy(
            {
                $0.evaluated && $0.passed
            }
        ) {
            return OutcomeVerification(
                status: .verifiedSuccess,
                predicates: results
            )
        }

        return OutcomeVerification(
            status: .unverified,
            predicates: results
        )
    }

    public static func verifyEventually(
        spec: VerificationSpec,
        item: ContentItem,
        before: OutcomeSnapshot,
        returnedText: String?
    ) throws -> OutcomeVerification {
        let requested = spec.timeoutMilliseconds ?? 0

        // Agent-supplied waits are bounded. RIGHTCLICK must never
        // become an unbounded sleep primitive.
        let timeoutMilliseconds = max(
            0,
            min(requested, 60_000)
        )

        let deadline = Date().addingTimeInterval(
            Double(timeoutMilliseconds) / 1000.0
        )

        var latest = try verify(
            spec: spec,
            item: item,
            before: before,
            returnedText: returnedText
        )

        guard timeoutMilliseconds > 0 else {
            return latest
        }

        while latest.status != .verifiedSuccess,
              Date() < deadline
        {
            let next = min(
                deadline,
                Date().addingTimeInterval(0.10)
            )

            if Thread.isMainThread {
                _ = RunLoop.current.run(
                    mode: .default,
                    before: next
                )
            } else {
                let interval = max(
                    0,
                    next.timeIntervalSinceNow
                )

                if interval > 0 {
                    Thread.sleep(
                        forTimeInterval: interval
                    )
                }
            }

            latest = try verify(
                spec: spec,
                item: item,
                before: before,
                returnedText: returnedText
            )
        }

        return latest
    }

    private static func evaluate(
        predicate: VerificationPredicate,
        before: OutcomeSnapshot,
        after: OutcomeSnapshot,
        returnedText: String?
    ) -> PredicateVerification {
        switch predicate.type {
        case .textEquals:
            guard let expected = predicate.value else {
                return unknown(
                    predicate,
                    "text_equals requires value"
                )
            }

            guard let returnedText else {
                return unknown(
                    predicate,
                    "Provider returned no text to compare"
                )
            }

            return result(
                predicate,
                passed: returnedText == expected,
                actual: returnedText,
                message: "Compared exact provider-returned text."
            )

        case .fileExists:
            guard after.path != nil else {
                return unknown(
                    predicate,
                    "Input has no file path"
                )
            }

            return result(
                predicate,
                passed: after.fileExists,
                actual: String(after.fileExists),
                message: "Observed filesystem existence."
            )

        case .fileReadable:
            guard
                after.path != nil,
                let readable = after.fileReadable
            else {
                return unknown(
                    predicate,
                    "File readability was not observable"
                )
            }

            return result(
                predicate,
                passed: readable,
                actual: String(readable),
                message: "Observed filesystem readability."
            )

        case .fileSHA256Equals:
            guard predicate.reference == nil
                    || predicate.reference == "before"
            else {
                return unknown(
                    predicate,
                    "Only reference=before is supported"
                )
            }

            guard
                let prior = before.fileSHA256,
                let current = after.fileSHA256
            else {
                return unknown(
                    predicate,
                    "Before/after SHA256 evidence unavailable"
                )
            }

            return result(
                predicate,
                passed: current == prior,
                actual: current,
                message: "Compared file SHA256 with before snapshot."
            )

        case .fileSHA256Differs:
            guard predicate.reference == nil
                    || predicate.reference == "before"
            else {
                return unknown(
                    predicate,
                    "Only reference=before is supported"
                )
            }

            guard
                let prior = before.fileSHA256,
                let current = after.fileSHA256
            else {
                return unknown(
                    predicate,
                    "Before/after SHA256 evidence unavailable"
                )
            }

            return result(
                predicate,
                passed: current != prior,
                actual: current,
                message: "Compared file SHA256 with before snapshot."
            )

        case .fileSizeLessThan:
            guard let limit = predicate.bytes else {
                return unknown(
                    predicate,
                    "file_size_less_than requires bytes"
                )
            }

            guard let size = after.fileSize else {
                return unknown(
                    predicate,
                    "File size was not observable"
                )
            }

            return result(
                predicate,
                passed: size < limit,
                actual: String(size),
                message: "Compared observed file size with limit."
            )

        case .dimensionsEqual:
            let expectedWidth =
                predicate.width ?? before.width

            let expectedHeight =
                predicate.height ?? before.height

            guard
                let expectedWidth,
                let expectedHeight
            else {
                return unknown(
                    predicate,
                    "Expected dimensions unavailable"
                )
            }

            guard
                let width = after.width,
                let height = after.height
            else {
                return unknown(
                    predicate,
                    "Image dimensions were not observable"
                )
            }

            let passed =
                width == expectedWidth
                && height == expectedHeight

            return result(
                predicate,
                passed: passed,
                actual: "\(width)x\(height)",
                message:
                    "Compared observed image dimensions with expected dimensions."
            )

        case .xattrPresent:
            guard
                let path = after.path,
                let key = predicate.key
            else {
                return unknown(
                    predicate,
                    "xattr_present requires file path and key"
                )
            }

            guard let present = hasXattr(
                path: path,
                key: key
            ) else {
                return unknown(
                    predicate,
                    "Extended attribute state was not observable"
                )
            }

            return result(
                predicate,
                passed: present,
                actual: String(present),
                message: "Observed extended attribute presence."
            )

        case .xattrAbsent:
            guard
                let path = after.path,
                let key = predicate.key
            else {
                return unknown(
                    predicate,
                    "xattr_absent requires file path and key"
                )
            }

            guard let present = hasXattr(
                path: path,
                key: key
            ) else {
                return unknown(
                    predicate,
                    "Extended attribute state was not observable"
                )
            }

            return result(
                predicate,
                passed: !present,
                actual: String(present),
                message: "Observed extended attribute absence."
            )

        case .metadataValuePresent:
            guard let expected = predicate.value else {
                return unknown(
                    predicate,
                    "metadata_value_present requires value"
                )
            }

            guard let values = after.metadataValues else {
                return unknown(
                    predicate,
                    "Image metadata was not observable"
                )
            }

            let present = values.contains {
                $0 == expected
                || $0.contains(expected)
            }

            return result(
                predicate,
                passed: present,
                actual: present ? expected : nil,
                message: "Searched observable image metadata values."
            )

        case .metadataValueAbsent:
            guard let expected = predicate.value else {
                return unknown(
                    predicate,
                    "metadata_value_absent requires value"
                )
            }

            guard let values = after.metadataValues else {
                return unknown(
                    predicate,
                    "Image metadata was not observable"
                )
            }

            let present = values.contains {
                $0 == expected
                || $0.contains(expected)
            }

            return result(
                predicate,
                passed: !present,
                actual: present ? expected : nil,
                message: "Searched observable image metadata values."
            )
        }
    }

    private static func result(
        _ predicate: VerificationPredicate,
        passed: Bool,
        actual: String?,
        message: String
    ) -> PredicateVerification {
        PredicateVerification(
            predicate: predicate,
            evaluated: true,
            passed: passed,
            actual: actual,
            message: message
        )
    }

    private static func unknown(
        _ predicate: VerificationPredicate,
        _ message: String
    ) -> PredicateVerification {
        PredicateVerification(
            predicate: predicate,
            evaluated: false,
            passed: false,
            actual: nil,
            message: message
        )
    }

    private static func sha256(
        path: String
    ) -> String? {
        guard
            let data = try? Data(
                contentsOf: URL(
                    fileURLWithPath: path
                )
            )
        else {
            return nil
        }

        let digest = SHA256.hash(
            data: data
        )

        return digest.map {
            String(
                format: "%02x",
                $0
            )
        }
        .joined()
    }

    private static func hasXattr(path: String, key: String) -> Bool? {
        PlatformHostDefaults.host.hasXattr(path: path, key: key)
    }
    private static func imageObservation(path: String) -> PlatformImageObservation {
        PlatformHostDefaults.host.imageObservation(path: path)
    }
}
