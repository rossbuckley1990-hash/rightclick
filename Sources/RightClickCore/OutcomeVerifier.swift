#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#endif
import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

public enum VerificationPredicateType: String, Codable, Sendable {
    case textEquals = "text_equals"

    case fileExists = "file_exists"
    case fileReadable = "file_readable"

    case fileSHA256Equals = "file_sha256_equals"
    case fileSHA256Differs = "file_sha256_differs"

    case fileSizeLessThan = "file_size_less_than"

    case dimensionsEqual = "dimensions_equal"

    case xattrPresent = "xattr_present"
    case xattrAbsent = "xattr_absent"

    case metadataValuePresent = "metadata_value_present"
    case metadataValueAbsent = "metadata_value_absent"
}

public struct VerificationPredicate: Codable, Sendable, Equatable {
    public var type: VerificationPredicateType

    public var key: String?
    public var value: String?
    public var reference: String?

    public var width: Int?
    public var height: Int?
    public var bytes: Int?

    public init(
        type: VerificationPredicateType,
        key: String? = nil,
        value: String? = nil,
        reference: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        bytes: Int? = nil
    ) {
        self.type = type
        self.key = key
        self.value = value
        self.reference = reference
        self.width = width
        self.height = height
        self.bytes = bytes
    }
}

public struct VerificationSpec: Codable, Sendable, Equatable {
    public var predicates: [VerificationPredicate]

    /// Maximum time to wait for declared postconditions to become true.
    /// Nil or zero performs one immediate observation.
    public var timeoutMilliseconds: Int?

    public init(
        predicates: [VerificationPredicate],
        timeoutMilliseconds: Int? = nil
    ) {
        self.predicates = predicates
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}

public enum OutcomeVerificationStatus: String, Codable, Sendable {
    case verifiedSuccess = "VERIFIED_SUCCESS"
    case verifiedFailure = "VERIFIED_FAILURE"
    case unverified = "UNVERIFIED"
    case abstained = "ABSTAINED"
}

public struct PredicateVerification: Codable, Sendable, Equatable {
    public var predicate: VerificationPredicate

    /// False does not necessarily mean semantic failure:
    /// `evaluated == false` means the verifier lacked sufficient evidence.
    public var evaluated: Bool
    public var passed: Bool

    public var actual: String?
    public var message: String

    public init(
        predicate: VerificationPredicate,
        evaluated: Bool,
        passed: Bool,
        actual: String? = nil,
        message: String
    ) {
        self.predicate = predicate
        self.evaluated = evaluated
        self.passed = passed
        self.actual = actual
        self.message = message
    }
}

public struct OutcomeVerification: Codable, Sendable, Equatable {
    public var status: OutcomeVerificationStatus
    public var predicates: [PredicateVerification]

    public init(
        status: OutcomeVerificationStatus,
        predicates: [PredicateVerification]
    ) {
        self.status = status
        self.predicates = predicates
    }
}

public struct OutcomeSnapshot: Codable, Sendable, Equatable {
    public var path: String?

    public var fileExists: Bool
    public var fileReadable: Bool?

    public var fileSHA256: String?
    public var fileSize: Int?

    public var width: Int?
    public var height: Int?

    /// Nil means the object could not be interpreted as image metadata.
    /// Empty means it was interpreted successfully and had no metadata values.
    public var metadataValues: [String]?

    public init(
        path: String? = nil,
        fileExists: Bool = false,
        fileReadable: Bool? = nil,
        fileSHA256: String? = nil,
        fileSize: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        metadataValues: [String]? = nil
    ) {
        self.path = path
        self.fileExists = fileExists
        self.fileReadable = fileReadable
        self.fileSHA256 = fileSHA256
        self.fileSize = fileSize
        self.width = width
        self.height = height
        self.metadataValues = metadataValues
    }
}

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

    private static func hasXattr(
        path: String,
        key: String
    ) -> Bool? {
#if os(macOS)

        guard
            FileManager.default.fileExists(
                atPath: path
            )
        else {
            return nil
        }

        let size: Int = path.withCString {
            pathPointer in

            key.withCString {
                keyPointer in

                getxattr(
                    pathPointer,
                    keyPointer,
                    nil,
                    0,
                    0,
                    0
                )
            }
        }

        if size >= 0 {
            return true
        }

        if errno == ENOATTR {
            return false
        }

        return nil

#else
        return nil
#endif
}

    private static func imageObservation(
        path: String
    ) -> (
        width: Int?,
        height: Int?,
        metadataValues: [String]?
    ) {
#if canImport(ImageIO)

        let url = URL(
            fileURLWithPath: path
        )

        guard
            let source = CGImageSourceCreateWithURL(
                url as CFURL,
                nil
            ),
            let properties =
                CGImageSourceCopyPropertiesAtIndex(
                    source,
                    0,
                    nil
                )
        else {
            return (
                nil,
                nil,
                nil
            )
        }

        let dictionary =
            properties as NSDictionary

        let width = (
            dictionary[
                kCGImagePropertyPixelWidth
            ] as? NSNumber
        )?.intValue

        let height = (
            dictionary[
                kCGImagePropertyPixelHeight
            ] as? NSNumber
        )?.intValue

        var values: [String] = []

        // Basic ImageIO properties expose dimensions and some metadata,
        // but not every embedded metadata value.
        collectMetadataValues(
            dictionary,
            into: &values
        )

        // CGImageMetadata exposes the richer embedded metadata graph.
        // This is provider-independent: RIGHTCLICK observes whatever
        // metadata ImageIO reports for the file rather than knowing
        // anything about the application that acted on it.
        if let metadata =
            CGImageSourceCopyMetadataAtIndex(
                source,
                0,
                nil
            )
        {
            collectImageMetadata(
                metadata,
                into: &values
            )
        }

        return (
            width,
            height,
            values
        )

#else
        return (nil, nil, nil)
#endif
}

#if canImport(ImageIO)
    private static func collectImageMetadata(
        _ metadata: CGImageMetadata,
        into values: inout [String]
    ) {
        let tags =
            (CGImageMetadataCopyTags(metadata)
                as? [CGImageMetadataTag])
            ?? []

        for tag in tags {
            collectImageMetadataTag(
                tag,
                into: &values
            )
        }
    }

    private static func collectImageMetadataTag(
        _ tag: CGImageMetadataTag,
        into values: inout [String]
    ) {
        guard let value =
            CGImageMetadataTagCopyValue(tag)
        else {
            return
        }

        // Metadata values can themselves be arrays of metadata tags,
        // for example dc:creator. Walk those tags recursively rather
        // than trusting a container's debug description as evidence.
        if let childTags =
            value as? [CGImageMetadataTag]
        {
            for child in childTags {
                collectImageMetadataTag(
                    child,
                    into: &values
                )
            }

            return
        }

        if let array = value as? NSArray {
            // Arrays consisting of CGImageMetadataTag values are handled
            // by the typed [CGImageMetadataTag] branch above. Remaining
            // arrays contain ordinary metadata values and can be flattened.
            for element in array {
                collectMetadataValues(
                    element,
                    into: &values
                )
            }

            return
        }

        collectMetadataValues(
            value,
            into: &values
        )
    }

#endif
    private static func collectMetadataValues(
        _ object: Any,
        into values: inout [String]
    ) {
        if let dictionary =
            object as? NSDictionary
        {
            for (_, value) in dictionary {
                collectMetadataValues(
                    value,
                    into: &values
                )
            }

            return
        }

        if let array =
            object as? NSArray
        {
            for value in array {
                collectMetadataValues(
                    value,
                    into: &values
                )
            }

            return
        }

        values.append(
            String(
                describing: object
            )
        )
    }
}
