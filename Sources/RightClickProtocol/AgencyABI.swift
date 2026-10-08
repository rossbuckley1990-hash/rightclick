import Foundation

/// Public, credential-free authority view for the opt-in Agency MCP profile.
///
/// This is intentionally a view of the current capability declaration and host
/// admission preconditions. It is not an RCIRLease, bearer credential, approval
/// token, or proof that a later dispatch will still be admissible.
public struct AgencyAuthorityView: Codable, Sendable, Equatable {
    public static let version = 1

    public var capabilityID: String
    public var title: String
    public var reflectorID: String
    public var providerID: String?
    public var safety: String
    public var invocation: String
    public var supportLevel: String
    public var requiresConfirmation: Bool
    public var confirmationOutstanding: Bool
    public var admissionAvailable: Bool
    public var authorityKind: String?
    public var authorityOrigin: String?
    public var authorityScheme: String?
    public var attenuationSupported: Bool
    public var renewalSupported: Bool
    public var delegationSupported: Bool
    public var note: String

    public init(
        capabilityID: String,
        title: String,
        reflectorID: String,
        providerID: String?,
        safety: String,
        invocation: String,
        supportLevel: String,
        requiresConfirmation: Bool,
        confirmationOutstanding: Bool,
        admissionAvailable: Bool,
        authorityKind: String?,
        authorityOrigin: String?,
        authorityScheme: String?,
        attenuationSupported: Bool = false,
        renewalSupported: Bool = false,
        delegationSupported: Bool = false,
        note: String
    ) {
        self.capabilityID = capabilityID
        self.title = title
        self.reflectorID = reflectorID
        self.providerID = providerID
        self.safety = safety
        self.invocation = invocation
        self.supportLevel = supportLevel
        self.requiresConfirmation = requiresConfirmation
        self.confirmationOutstanding = confirmationOutstanding
        self.admissionAvailable = admissionAvailable
        self.authorityKind = authorityKind
        self.authorityOrigin = authorityOrigin
        self.authorityScheme = authorityScheme
        self.attenuationSupported = attenuationSupported
        self.renewalSupported = renewalSupported
        self.delegationSupported = delegationSupported
        self.note = note
    }
}

/// Cursor page over the existing execution ledger.
///
/// Events remain runtime-owned observations. They are not semantic-success proof;
/// callers must continue to inspect execution state/evidence/verification.
public struct AgencyExecutionEventPage: Codable, Sendable, Equatable {
    public static let version = 1

    public var executionId: String
    public var cursor: Int
    public var nextCursor: Int
    public var hasMore: Bool
    public var terminal: Bool
    public var state: ExecutionState
    public var events: [String]

    public init(
        executionId: String,
        cursor: Int,
        nextCursor: Int,
        hasMore: Bool,
        terminal: Bool,
        state: ExecutionState,
        events: [String]
    ) {
        self.executionId = executionId
        self.cursor = cursor
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.terminal = terminal
        self.state = state
        self.events = events
    }
}

public enum AgencyControlCommand: String, Codable, Sendable, CaseIterable {
    case cancel
    case pause
    case resume
    case checkpoint
    case retry
}

/// Truthful result of an Agency control request.
///
/// applied=false means RIGHTCLICK did not claim or simulate provider control.
public struct AgencyControlResult: Codable, Sendable, Equatable {
    public static let version = 1

    public var executionId: String
    public var command: AgencyControlCommand
    public var applied: Bool
    public var state: ExecutionState
    public var message: String

    public init(
        executionId: String,
        command: AgencyControlCommand,
        applied: Bool,
        state: ExecutionState,
        message: String
    ) {
        self.executionId = executionId
        self.command = command
        self.applied = applied
        self.state = state
        self.message = message
    }
}
