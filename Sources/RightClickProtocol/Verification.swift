import Foundation

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

/// Shared validation of delegated predicate evidence. A remote assertion must
/// establish the caller's exact postcondition, not a substituted passing value.
extension OutcomeVerification {
    package func validatesSuccess(expected: VerificationSpec? = nil) -> Bool {
        guard status == .verifiedSuccess, !predicates.isEmpty,
              predicates.allSatisfy({ $0.evaluated && $0.passed }) else { return false }
        return matches(expected: expected)
    }

    package func validatesFailure(expected: VerificationSpec? = nil) -> Bool {
        guard status == .verifiedFailure, !predicates.isEmpty,
              predicates.allSatisfy(\.evaluated), predicates.contains(where: { !$0.passed }) else { return false }
        return matches(expected: expected)
    }

    private func matches(expected: VerificationSpec?) -> Bool {
        guard let expected else { return true }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let wanted = try? encoder.encode(expected.predicates),
              let observed = try? encoder.encode(predicates.map(\.predicate)) else { return false }
        return wanted == observed
    }
}
