import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import RightClickCore
@testable import RightClickProviders
@testable import RightClickProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class RCIRDeferredExecutionTests: XCTestCase {
    private func deferredTask() throws -> RCIRTask {
        let abi = CapabilityContract(
            capabilityID:
                "fixture:deferred",
            reflectorID:
                "reflector:deferred",
            providerID:
                "provider:deferred",
            arguments:
                .object(
                    properties: [
                        "target": .string
                    ],
                    required: [
                        "target"
                    ]
                ),
            result:
                .integer,
            declaration:
                .string(
                    "deferred fixture"
                )
        )

        let contract = RCIRContract(
            abi: abi,
            scopes: [],
            task:
                .init(
                    shape: .deferred,
                    maxEvents: 16,
                    maxBytes: 16_384
                )
        )

        let admission =
            RCIRAdmission()

        let binding =
            try admission.publish(
                contract,
                authenticatedPrincipal:
                    "principal:deferred"
            )

        let arguments =
            CapabilityValue.object([
                "target":
                    .string(
                        "urn:deferred:1"
                    )
            ])

        let policy =
            RCIRPolicy(
                revision: "1",
                principals: [
                    "principal:deferred"
                ],
                scopes: []
            )

        let lease =
            try admission.issue(
                binding,
                arguments: arguments,
                authority: [],
                policy: policy,
                now: 100
            )

        try admission.consume(
            lease,
            arguments: arguments,
            authority: [],
            policy: policy,
            now: 101
        )

        return try RCIRTask(
            lease: lease,
            startedAt: 101,
            deadline: 1_000
        )
    }

    func testHostOwnsLiveDeferredTaskUntilTerminalization() throws {
        let executionID =
            "live-deferred-"
            + UUID().uuidString

        let host =
            RCIRExecutionHost()
        host.now = { 103 }

        let task =
            try deferredTask()

        try host.registerActiveTask(
            task,
            executionID: executionID
        )

        // A live task belongs only to the active registry.
        XCTAssertNil(
            try ExecutionStore.shared
                .rcirEventPage(
                    executionId:
                        executionID
                )
        )

        let emptyLivePage =
            try XCTUnwrap(
                host.activeEventPage(
                    executionID:
                        executionID
                )
            )

        XCTAssertTrue(
            emptyLivePage.events.isEmpty
        )

        XCTAssertFalse(
            emptyLivePage.terminal
        )

        let acceptedTerminal =
            try host.recordActiveTaskEvent(
                executionID:
                    executionID,
                event:
                    .accepted,
                now: 102
            )

        XCTAssertNil(
            acceptedTerminal
        )

        let workingTerminal =
            try host.recordActiveTaskEvent(
                executionID:
                    executionID,
                event:
                    .working,
                now: 103
            )

        XCTAssertNil(
            workingTerminal
        )

        let livePage =
            try XCTUnwrap(
                host.activeEventPage(
                    executionID:
                        executionID
                )
            )

        XCTAssertEqual(
            livePage.events.map(\.kind),
            [
                "accepted",
                "working",
            ]
        )

        XCTAssertEqual(
            livePage.nextCursor,
            2
        )

        XCTAssertFalse(
            livePage.hasMore
        )

        XCTAssertFalse(
            livePage.terminal
        )

        // Terminal history must not be published early.
        XCTAssertNil(
            try ExecutionStore.shared
                .rcirEventPage(
                    executionId:
                        executionID
                )
        )

        let terminalTask =
            try XCTUnwrap(
                host.recordActiveTaskEvent(
                    executionID:
                        executionID,
                    event:
                        .completed(
                            .integer(7)
                        ),
                    now: 104
                )
            )

        XCTAssertEqual(
            terminalTask.phase,
            .completed
        )

        XCTAssertEqual(
            terminalTask.outcome,
            .unverified
        )

        // A final receipt becomes legal only now.
        XCTAssertNoThrow(
            try terminalTask.receiptData()
        )

        // Terminalization moves ownership out of the active registry.
        XCTAssertNil(
            try host.activeEventPage(
                executionID:
                    executionID
            )
        )

        let terminalPage =
            try XCTUnwrap(
                ExecutionStore.shared
                    .rcirEventPage(
                        executionId:
                            executionID
                    )
            )

        XCTAssertEqual(
            terminalPage.events.map(\.kind),
            [
                "accepted",
                "working",
                "completed",
            ]
        )

        XCTAssertEqual(
            terminalPage.nextCursor,
            3
        )

        XCTAssertFalse(
            terminalPage.hasMore
        )

        XCTAssertTrue(
            terminalPage.terminal
        )

        guard
            case let .integer(value)? =
                terminalPage
                    .events
                    .last?
                    .value
        else {
            return XCTFail(
                "Expected typed terminal result."
            )
        }

        XCTAssertEqual(
            value,
            7
        )
    }

    func testExecutionStatusTransitionsFromLiveToTerminalRCIRHistory() throws {
        let executionID =
            "engine-live-deferred-"
            + UUID().uuidString

        let host =
            RCIRExecutionHost()
        host.now = { 103 }

        let engine =
            CapabilityEngine(
                reflectors: [],
                experience: nil,
                rcirHost: host
            )

        ExecutionStore.shared.put(
            ExecutionRecord(
                executionId: executionID,
                actionId: "fixture:deferred",
                title: "Deferred fixture",
                state: .started,
                message: "Execution is still running."
            )
        )

        try host.registerActiveTask(
            deferredTask(),
            executionID: executionID
        )

        try host.recordActiveTaskEvent(
            executionID: executionID,
            event: .accepted,
            now: 102
        )

        try host.recordActiveTaskEvent(
            executionID: executionID,
            event: .working,
            now: 103
        )

        let live =
            try engine.executionStatus(
                executionID,
                cursor: 0,
                limit: 64
            )

        let livePage =
            try XCTUnwrap(
                live.rcirEventPage
            )

        XCTAssertEqual(
            livePage.events.map(\.kind),
            [
                "accepted",
                "working",
            ]
        )

        XCTAssertEqual(
            livePage.nextCursor,
            2
        )

        XCTAssertFalse(
            livePage.hasMore
        )

        XCTAssertFalse(
            livePage.terminal
        )

        XCTAssertNil(
            live.rcir
        )

        let terminalTask =
            try XCTUnwrap(
                host.recordActiveTaskEvent(
                    executionID: executionID,
                    event:
                        .completed(
                            .integer(7)
                        ),
                    now: 104
                )
            )

        XCTAssertEqual(
            terminalTask.phase,
            .completed
        )

        let terminal =
            try engine.executionStatus(
                executionID,
                cursor: 0,
                limit: 64
            )

        let terminalPage =
            try XCTUnwrap(
                terminal.rcirEventPage
            )

        XCTAssertEqual(
            terminalPage.events.map(\.kind),
            [
                "accepted",
                "working",
                "completed",
            ]
        )

        XCTAssertEqual(
            terminalPage.nextCursor,
            3
        )

        XCTAssertFalse(
            terminalPage.hasMore
        )

        XCTAssertTrue(
            terminalPage.terminal
        )
    }

    func testHostExecuteCanReturnAGenuinelyLiveDeferredExecution() throws {
        let executionID =
            "host-execute-deferred-"
            + UUID().uuidString

        let host =
            RCIRExecutionHost()
        host.now = { 103 }

        host.now = { 100 }

        let abi =
            CapabilityContract(
                capabilityID:
                    "fixture:host-deferred",
                reflectorID:
                    "reflector:host-deferred",
                providerID:
                    "provider:host-deferred",
                arguments:
                    .string,
                result:
                    .integer,
                declaration:
                    .string(
                        "host deferred fixture"
                    )
            )

        let capability =
            Capability(
                id:
                    "fixture:host-deferred",
                title:
                    "Host deferred fixture",
                source:
                    .system,
                reflectorID:
                    "reflector:host-deferred",
                provider:
                    CapabilityProvider(
                        name:
                            "Deferred fixture"
                    ),
                inputs:
                    ["public.plain-text"],
                output:
                    ["public.json"],
                safety:
                    .localWrite,
                invocation:
                    .direct,
                supportLevel:
                    .experimental,
                requiresConfirmation:
                    false
            )

        let item =
            try ContentParser.parse(
                "deferred fixture"
            )

        let scope =
            RCIRScope(
                "urn:fixture:host-deferred",
                .execute
            )

        var providerStarts = 0

        let record =
            try host.execute(
                abi: abi,
                discovery: abi,
                arguments:
                    .string(
                        "deferred fixture"
                    ),
                scope: scope,
                taskModel:
                    .init(
                        shape:
                            .deferred,
                        maxEvents:
                            16,
                        maxBytes:
                            16_384
                    ),
                capability: capability,
                executionID: executionID,
                argumentStrings: nil,
                item: item,
                verification: nil,
                expectedOutput: nil,
                target:
                    try XCTUnwrap(
                        URL(
                            string:
                                "https://example.invalid/deferred"
                        )
                    ),
                authority: {
                    [scope]
                },
                revalidate: {
                    true
                },
                currentContract: {
                    true
                },
                dispatch: {
                    _,
                    admitStart
                    in

                    try admitStart {
                        providerStarts += 1
                    }

                    return ExecutionRecord(
                        executionId:
                            executionID,
                        actionId:
                            capability.id,
                        title:
                            capability.title,
                        state:
                            .started,
                        message:
                            "Provider is still working."
                    )
                },
                resultValue: {
                    _ in

                    XCTFail(
                        "A live deferred dispatch must not demand a terminal result."
                    )

                    return .integer(0)
                }
            )

        XCTAssertEqual(
            providerStarts,
            1,
            "Deferred execution must still consume and dispatch exactly once."
        )

        XCTAssertEqual(
            record.state,
            .started
        )

        XCTAssertNil(
            record.rcir,
            "No terminal RCIR receipt may exist while the deferred task is live."
        )

        let livePage =
            try XCTUnwrap(
                host.activeEventPage(
                    executionID:
                        executionID
                )
            )

        XCTAssertFalse(
            livePage.terminal
        )

        XCTAssertTrue(
            livePage.events.isEmpty,
            "Provider dispatch alone must not invent a completion event."
        )

        XCTAssertNil(
            try ExecutionStore.shared
                .rcirEventPage(
                    executionId:
                        executionID
                ),
            "Immutable terminal history must not be published before completion."
        )
    }

    func testDeferredTaskExistsBeforeProviderCanCallback() throws {
        let executionID =
            "deferred-callback-race-"
            + UUID().uuidString

        let host =
            RCIRExecutionHost()
        host.now = { 103 }

        host.now = { 100 }

        let abi =
            CapabilityContract(
                capabilityID:
                    "fixture:callback-race",
                reflectorID:
                    "reflector:callback-race",
                providerID:
                    "provider:callback-race",
                arguments:
                    .string,
                result:
                    .integer,
                declaration:
                    .string(
                        "callback race fixture"
                    )
            )

        let capability =
            Capability(
                id:
                    "fixture:callback-race",
                title:
                    "Callback race fixture",
                source:
                    .system,
                reflectorID:
                    "reflector:callback-race",
                provider:
                    CapabilityProvider(
                        name:
                            "Callback race provider"
                    ),
                safety:
                    .localWrite,
                invocation:
                    .direct,
                supportLevel:
                    .experimental,
                requiresConfirmation:
                    false
            )

        let scope =
            RCIRScope(
                "urn:fixture:callback-race",
                .execute
            )

        let item =
            try ContentParser.parse(
                "callback race"
            )

        var callbackError:
            Error?

        var providerStarts =
            0

        let record =
            try host.execute(
                abi: abi,
                discovery: abi,
                arguments:
                    .string(
                        "callback race"
                    ),
                scope: scope,
                taskModel:
                    .init(
                        shape:
                            .deferred,
                        maxEvents:
                            16,
                        maxBytes:
                            16_384
                    ),
                capability:
                    capability,
                executionID:
                    executionID,
                argumentStrings:
                    nil,
                item:
                    item,
                verification:
                    nil,
                expectedOutput:
                    nil,
                target:
                    try XCTUnwrap(
                        URL(
                            string:
                                "https://example.invalid/callback-race"
                        )
                    ),
                authority: {
                    [scope]
                },
                revalidate: {
                    true
                },
                currentContract: {
                    true
                },
                dispatch: {
                    _,
                    admitStart
                    in

                    try admitStart {
                        providerStarts += 1

                        // A real asynchronous API may invoke a delegate or
                        // completion callback synchronously from start().
                        // RCIR must already own the live task at this point.
                        do {
                            try host
                                .recordActiveTaskEvent(
                                    executionID:
                                        executionID,
                                    event:
                                        .accepted,
                                    now:
                                        101
                                )
                        } catch {
                            callbackError =
                                error
                        }
                    }

                    return ExecutionRecord(
                        executionId:
                            executionID,
                        actionId:
                            capability.id,
                        title:
                            capability.title,
                        state:
                            .started,
                        message:
                            "Provider continues asynchronously."
                    )
                },
                resultValue: {
                    _ in

                    XCTFail(
                        "Live deferred execution must not request a terminal result."
                    )

                    return .integer(0)
                }
            )

        XCTAssertEqual(
            providerStarts,
            1
        )

        XCTAssertNil(
            callbackError,
            """
            RCIR must register the deferred task before provider start can
            synchronously report a lifecycle callback.
            """
        )

        XCTAssertEqual(
            record.state,
            .started
        )

        let page =
            try XCTUnwrap(
                host.activeEventPage(
                    executionID:
                        executionID
                )
            )

        XCTAssertEqual(
            page.events.map(\.kind),
            [
                "accepted"
            ]
        )

        XCTAssertFalse(
            page.terminal
        )
    }

    func testDeferredDispatchFailureDoesNotLeaveAnActiveTask() throws {
        let executionID =
            "deferred-dispatch-failure-"
            + UUID().uuidString

        let host =
            RCIRExecutionHost()
        host.now = { 103 }

        host.now = { 100 }

        let abi =
            CapabilityContract(
                capabilityID:
                    "fixture:deferred-dispatch-failure",
                reflectorID:
                    "reflector:deferred-dispatch-failure",
                providerID:
                    "provider:deferred-dispatch-failure",
                arguments:
                    .string,
                result:
                    .integer,
                declaration:
                    .string(
                        "deferred dispatch failure"
                    )
            )

        let capability =
            Capability(
                id:
                    "fixture:deferred-dispatch-failure",
                title:
                    "Deferred dispatch failure",
                source:
                    .system,
                reflectorID:
                    "reflector:deferred-dispatch-failure",
                provider:
                    CapabilityProvider(
                        name:
                            "Deferred failure provider"
                    ),
                safety:
                    .localWrite,
                invocation:
                    .direct,
                supportLevel:
                    .experimental,
                requiresConfirmation:
                    false
            )

        let scope =
            RCIRScope(
                "urn:fixture:deferred-dispatch-failure",
                .execute
            )

        let item =
            try ContentParser.parse(
                "deferred dispatch failure"
            )

        var providerStarts =
            0

        let record =
            try host.execute(
                abi: abi,
                discovery: abi,
                arguments:
                    .string(
                        "deferred dispatch failure"
                    ),
                scope: scope,
                taskModel:
                    .init(
                        shape:
                            .deferred,
                        maxEvents:
                            16,
                        maxBytes:
                            16_384
                    ),
                capability:
                    capability,
                executionID:
                    executionID,
                argumentStrings:
                    nil,
                item:
                    item,
                verification:
                    nil,
                expectedOutput:
                    nil,
                target:
                    try XCTUnwrap(
                        URL(
                            string:
                                "https://example.invalid/deferred-failure"
                        )
                    ),
                authority: {
                    [scope]
                },
                revalidate: {
                    true
                },
                currentContract: {
                    true
                },
                dispatch: {
                    _,
                    admitStart
                    in

                    try admitStart {
                        providerStarts += 1
                    }

                    throw NSError(
                        domain:
                            "fixture.deferred",
                        code:
                            1
                    )
                },
                resultValue: {
                    _ in

                    XCTFail(
                        "Unknown deferred dispatch must not demand a successful terminal result."
                    )

                    return .integer(0)
                }
            )

        XCTAssertEqual(
            providerStarts,
            1
        )

        XCTAssertEqual(
            record.state,
            .unknown
        )

        XCTAssertEqual(
            record.rcir?.outcome,
            "unknown"
        )

        XCTAssertNil(
            try host.activeEventPage(
                executionID:
                    executionID
            ),
            "Post-start transport failure must not leave an orphan live task."
        )

        let terminalPage =
            try XCTUnwrap(
                ExecutionStore.shared
                    .rcirEventPage(
                        executionId:
                            executionID
                    )
            )

        XCTAssertTrue(
            terminalPage.terminal
        )
    }

#if canImport(CryptoKit) || canImport(Crypto)
    func testDeferredCompletionPublishesFinalEvidenceUsingAdmissionTimeSigner() throws {
        let executionID =
            "deferred-signed-evidence-"
            + UUID().uuidString

        let directory =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "rightclick-deferred-signer-"
                    + UUID().uuidString,
                    isDirectory: true
                )

        try FileManager.default
            .createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

        defer {
            try? FileManager.default
                .removeItem(
                    at: directory
                )
        }

        let keyURL =
            directory
                .appendingPathComponent(
                    "receipt.key"
                )

        let admissionKey =
            Curve25519.Signing.PrivateKey()

        try admissionKey
            .rawRepresentation
            .write(
                to: keyURL,
                options: .atomic
            )

        try FileManager.default
            .setAttributes(
                [
                    .posixPermissions:
                        NSNumber(
                            value: Int16(0o600)
                        )
                ],
                ofItemAtPath:
                    keyURL.path
            )

        var config =
            RCIRHostConfiguration()

        config.signingKeyFile =
            keyURL.path

        let host =
            RCIRExecutionHost()
        host.now = { 103 }

        var clock:
            Int64 = 100

        host.now = {
            clock
        }

        host.configuration = {
            config
        }

        let abi =
            CapabilityContract(
                capabilityID:
                    "fixture:deferred-signed-evidence",
                reflectorID:
                    "reflector:deferred-signed-evidence",
                providerID:
                    "provider:deferred-signed-evidence",
                arguments:
                    .string,
                result:
                    .integer,
                declaration:
                    .string(
                        "deferred signed evidence fixture"
                    )
            )

        let capability =
            Capability(
                id:
                    "fixture:deferred-signed-evidence",
                title:
                    "Deferred signed evidence",
                source:
                    .system,
                reflectorID:
                    "reflector:deferred-signed-evidence",
                provider:
                    CapabilityProvider(
                        name:
                            "Deferred signed evidence provider"
                    ),
                safety:
                    .localWrite,
                invocation:
                    .direct,
                supportLevel:
                    .experimental,
                requiresConfirmation:
                    false
            )

        let scope =
            RCIRScope(
                "urn:fixture:deferred-signed-evidence",
                .execute
            )

        let item =
            try ContentParser.parse(
                "deferred signed evidence"
            )

        let started =
            try host.execute(
                abi: abi,
                discovery: abi,
                arguments:
                    .string(
                        "deferred signed evidence"
                    ),
                scope: scope,
                taskModel:
                    .init(
                        shape:
                            .deferred,
                        maxEvents:
                            16,
                        maxBytes:
                            16_384
                    ),
                capability:
                    capability,
                executionID:
                    executionID,
                argumentStrings:
                    nil,
                item:
                    item,
                verification:
                    nil,
                expectedOutput:
                    nil,
                target:
                    try XCTUnwrap(
                        URL(
                            string:
                                "https://example.invalid/deferred-signed-evidence"
                        )
                    ),
                authority: {
                    [scope]
                },
                revalidate: {
                    true
                },
                currentContract: {
                    true
                },
                dispatch: {
                    _,
                    admitStart
                    in

                    try admitStart {
                        // Provider genuinely started.
                    }

                    return ExecutionRecord(
                        executionId:
                            executionID,
                        actionId:
                            capability.id,
                        title:
                            capability.title,
                        state:
                            .started,
                        message:
                            "Provider is still working."
                    )
                },
                resultValue: {
                    _ in

                    XCTFail(
                        "A live deferred execution must not require a terminal result."
                    )

                    return .integer(0)
                }
            )

        XCTAssertEqual(
            started.state,
            .started
        )

        XCTAssertNil(
            started.rcir
        )

        // CapabilityEngine normally stores the provider record after
        // admittedBegin returns. Mirror that production ownership boundary.
        ExecutionStore.shared.put(
            started
        )

        let originalPublicKey =
            admissionKey
                .publicKey
                .rawRepresentation

        // Rotate the on-disk key *after* admission. Deferred completion must
        // not silently reread this new key and sign as a different runtime.
        let replacementKey =
            Curve25519.Signing.PrivateKey()

        try replacementKey
            .rawRepresentation
            .write(
                to: keyURL,
                options: .atomic
            )

        try FileManager.default
            .setAttributes(
                [
                    .posixPermissions:
                        NSNumber(
                            value: Int16(0o600)
                        )
                ],
                ofItemAtPath:
                    keyURL.path
            )

        clock = 101

        let terminalTask =
            try XCTUnwrap(
                host.recordActiveTaskEvent(
                    executionID:
                        executionID,
                    event:
                        .completed(
                            .integer(7)
                        ),
                    now:
                        clock
                )
            )

        XCTAssertEqual(
            terminalTask.phase,
            .completed
        )

        XCTAssertEqual(
            terminalTask.outcome,
            .unverified
        )

        let stored =
            try XCTUnwrap(
                ExecutionStore.shared
                    .get(
                        executionID
                    )
            )

        let evidence =
            try XCTUnwrap(
                stored.rcir,
                """
                Deferred terminalization must attach the same final
                receipt-bearing RCIR evidence contract as unary execution.
                """
            )

        XCTAssertTrue(
            evidence.leaseConsumed
        )

        XCTAssertEqual(
            evidence.phase,
            "completed"
        )

        XCTAssertEqual(
            evidence.outcome,
            "unverified"
        )

        XCTAssertFalse(
            evidence.receipt.isEmpty
        )

        let envelope =
            try XCTUnwrap(
                evidence.signedReceipt,
                "Admission configured a signing key, so deferred final evidence must be signed."
            )

        let payload =
            try XCTUnwrap(
                Data(
                    base64Encoded:
                        envelope.payload
                )
            )

        let signature =
            try XCTUnwrap(
                Data(
                    base64Encoded:
                        envelope.signature
                )
            )

        let publicKey =
            try XCTUnwrap(
                Data(
                    base64Encoded:
                        envelope.publicKey
                )
            )

        XCTAssertEqual(
            publicKey,
            originalPublicKey,
            """
            Deferred receipt signing must preserve the signer loaded at
            admission time, not reread a subsequently rotated key file.
            """
        )

        XCTAssertNotEqual(
            publicKey,
            replacementKey
                .publicKey
                .rawRepresentation
        )

        let signed =
            try RCIRSignedReceipt(
                payload: payload,
                signature: signature,
                publicKey: publicKey
            )

        XCTAssertNoThrow(
            try signed.verify(
                trustedPublicKey:
                    originalPublicKey,
                using:
                    RCIREd25519Verifier()
            )
        )

        let page =
            try XCTUnwrap(
                stored.rcirEventPage
            )

        XCTAssertTrue(
            page.terminal
        )

        XCTAssertEqual(
            page.events.last?.kind,
            "completed"
        )
    }
#endif
    func testSynchronousCompletionBeforeInitialExecutionRecordStorageRetainsReceiptAndTypedResult() throws {
        let id = "fast-terminal-" + UUID().uuidString
        let host = RCIRExecutionHost()
        host.now = { 100 }
        let abi = CapabilityContract(capabilityID: "fixture:fast-terminal", reflectorID: "reflector:fast-terminal",
            providerID: "provider:fast-terminal", arguments: .string, result: .integer,
            declaration: .string("portable synchronous callback"))
        let capability = Capability(id: abi.capabilityID, title: "Portable fast completion", source: .system,
            reflectorID: abi.reflectorID, safety: .localWrite, invocation: .direct,
            supportLevel: .experimental, requiresConfirmation: false)
        let scope = RCIRScope("urn:fixture:fast-terminal", .execute)
        var starts = 0
        var callbackError: Error?
        let record = try host.execute(abi: abi, discovery: abi, arguments: .string("fast"), scope: scope,
            taskModel: .init(shape: .deferred), capability: capability, executionID: id,
            argumentStrings: nil, item: ContentParser.parse("fast"), verification: nil,
            expectedOutput: nil, target: XCTUnwrap(URL(string: "https://example.invalid/fast")),
            authority: { [scope] }, revalidate: { true }, currentContract: { true },
            dispatch: { _, admitStart in
                try admitStart {
                    starts += 1
                    do {
                        try host.recordActiveTaskEvent(executionID: id, event: .completed(.integer(7)), now: 101)
                    } catch { callbackError = error }
                }
                return .init(executionId: id, actionId: capability.id, state: .started,
                             message: "Initial provider response is late.")
            }, resultValue: { _ in XCTFail("Fast completion already carries its typed terminal value"); return .integer(0) })
        XCTAssertEqual(starts, 1)
        XCTAssertNil(callbackError)
        XCTAssertEqual(record.lifecycle?.terminal, true)
        XCTAssertEqual(record.state, .accepted)
        XCTAssertEqual(record.rcir?.phase, "completed")
        XCTAssertEqual(record.rcir?.outcome, "unverified")
        XCTAssertEqual(try record.result?.canonicalData(), try CapabilityValue.integer(7).canonicalData())
        XCTAssertFalse(try XCTUnwrap(record.rcir?.receipt).isEmpty)
        XCTAssertNil(try host.activeEventPage(executionID: id))
        ExecutionStore.shared.put(.init(executionId: id, actionId: capability.id, state: .started, message: "Late storage"))
        let retained = try XCTUnwrap(ExecutionStore.shared.get(id))
        XCTAssertEqual(retained.lifecycle?.terminal, true)
        XCTAssertEqual(retained.rcir?.phase, "completed")
        XCTAssertEqual(try retained.result?.canonicalData(), try CapabilityValue.integer(7).canonicalData())
        XCTAssertEqual(try ExecutionStore.shared.rcirEventPage(executionId: id)?.events.map(\.kind), ["completed"])
    }

    func testAuthenticatedRemoteTerminalAliasSurvivesLateInitialRecordAndAllowsBoundedViews() throws {
        let store = ExecutionStore(), alias = UUID().uuidString, taskID = UUID().uuidString
        let lifecycle = ExecutionLifecycle(executionID: "execution:target", originatingRequestID: "request:caller",
            runtimeID: "runtime:target", taskID: taskID, generation: 3, taskShape: .deferred,
            phase: .completed, semanticOutcome: .unverified, sequence: 2, terminal: true,
            providerAcceptance: .accepted, verification: .unverified, observationBoundary: .none,
            evidenceID: taskID, receiptAvailable: true, signedReceiptAvailable: true)
        let accepted = RCIRExecutionEvent(sequence: 1, time: 101, kind: "accepted", value: .null)
        let completed = RCIRExecutionEvent(sequence: 2, time: 102, kind: "completed", value: .integer(7))
        var terminal = ExecutionRecord(executionId: alias, actionId: "fixture:remote", state: .accepted,
            message: "Authenticated provider completion is unverified.", result: .integer(7),
            rcirEventPage: .init(events: [accepted], nextCursor: 1, hasMore: true, terminal: true), lifecycle: lifecycle)
        try store.putTerminalSnapshot(terminal)
        store.put(.init(executionId: alias, actionId: terminal.actionId, state: .started, message: "Late initial response"))
        XCTAssertEqual(store.get(alias)?.lifecycle?.terminal, true)
        XCTAssertEqual(store.get(alias)?.state, .accepted)
        XCTAssertNil(try store.rcirEventPage(executionId: alias), "A bounded remote view is not complete local RCIR history")
        terminal.rcirEventPage = .init(events: [completed], nextCursor: 2, hasMore: false, terminal: true)
        try store.putTerminalSnapshot(terminal)
        XCTAssertEqual(store.get(alias)?.rcirEventPage?.events.map(\.sequence), [2])
        var substituted = terminal; substituted.result = .integer(8)
        XCTAssertThrowsError(try store.putTerminalSnapshot(substituted))
        XCTAssertEqual(try store.get(alias)?.result?.canonicalData(), try CapabilityValue.integer(7).canonicalData())
    }

    private func assertRepeatedHostIdentityDoesNotDispatch(shape: RCIRTaskShape) throws {
        let id = "duplicate-identity-" + UUID().uuidString, host = RCIRExecutionHost()
        host.now = { 100 }
        let abi = CapabilityContract(capabilityID: "fixture:duplicate", reflectorID: "reflector:duplicate",
            providerID: "provider:duplicate", arguments: .string, result: .integer, declaration: .string("portable duplicate fixture"))
        let capability = Capability(id: abi.capabilityID, title: "Duplicate identity", source: .system,
            reflectorID: abi.reflectorID, safety: .localWrite, invocation: .direct,
            supportLevel: .experimental, requiresConfirmation: false)
        let scope = RCIRScope("urn:fixture:duplicate", .execute)
        var starts = 0
        func invoke() throws -> ExecutionRecord {
            try host.execute(abi: abi, discovery: abi, arguments: .string("same intent"), scope: scope,
                taskModel: .init(shape: shape), capability: capability, executionID: id, argumentStrings: nil,
                item: ContentParser.parse("duplicate"), verification: nil, expectedOutput: nil,
                target: XCTUnwrap(URL(string: "https://example.invalid/duplicate")), authority: { [scope] },
                revalidate: { true }, currentContract: { true }, dispatch: { _, admitStart in
                    try admitStart { starts += 1 }
                    return .init(executionId: id, actionId: capability.id,
                        state: shape == .unary ? .accepted : .started, message: "Provider invoked once.")
                }, resultValue: { _ in .integer(7) })
        }
        let first = try invoke()
        XCTAssertEqual(first.state, shape == .unary ? .accepted : .started)
        XCTAssertEqual(starts, 1)
        let repeated = try invoke()
        XCTAssertEqual(repeated.state, .rejected)
        XCTAssertEqual(starts, 1, "A reused execution identity must fail before provider invocation")
        XCTAssertEqual(repeated.evidence.type, "rcir_execution_identity_denied")
    }

    func testDuplicateUnaryExecutionIdentityCannotDispatchAgain() throws {
        try assertRepeatedHostIdentityDoesNotDispatch(shape: .unary)
    }

    func testDuplicateDeferredExecutionIdentityCannotDispatchAgain() throws {
        try assertRepeatedHostIdentityDoesNotDispatch(shape: .deferred)
    }

    func testActualDeferredHTTPCompletionUsesAdmissionBoundIndependentObserver() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rcir-deferred-observer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let provider = Process()
        provider.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        provider.arguments = [root.appendingPathComponent("scripts/rcir-dispatch-test-provider.py").path, directory.path]
        provider.standardOutput = FileHandle.nullDevice; provider.standardError = FileHandle.nullDevice
        try provider.run()
        defer {
            if provider.isRunning { provider.terminate(); provider.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
        }
        let portFile = directory.appendingPathComponent("port")
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: portFile.path) { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let port = try String(contentsOf: portFile, encoding: .utf8)
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:" + port))
        for matches in [true, false] {
            let id = UUID().uuidString, resourceID = UUID().uuidString, host = RCIRExecutionHost()
            let abi = CapabilityContract(capabilityID: "fixture:deferred-observer", reflectorID: "reflector:deferred-observer",
                providerID: "provider:deferred-observer", arguments: .object(properties: ["id": .string, "value": .string], required: ["id", "value"]),
                result: .integer, declaration: .string("Portable real HTTP deferred observer"))
            let capability = Capability(id: abi.capabilityID, title: "Deferred external observation", source: .system,
                reflectorID: abi.reflectorID, safety: .localWrite, invocation: .direct,
                supportLevel: .experimental, requiresConfirmation: false)
            var configuration = RCIRHostConfiguration()
            configuration.observers = [capability.id: .init(urlTemplate: base.absoluteString + "/records/{id}", expectedArgument: "value")]
            host.configuration = { configuration }
            let target = base.appendingPathComponent("records"), scope = RCIRScope(target.absoluteString + "/" + resourceID, .execute)
            var request = URLRequest(url: target)
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["id": resourceID, "value": matches ? "wanted" : "different"])
            let providerRequest = request
            let completionGate = DispatchSemaphore(value: 0), callback = expectation(description: "Real HTTP provider callback")
            let initial = try host.execute(abi: abi, discovery: abi, arguments: .object(["id": .string(resourceID), "value": .string("wanted")]),
                scope: scope, taskModel: .init(shape: .deferred), capability: capability, executionID: id,
                argumentStrings: ["id": resourceID, "value": "wanted"], item: ContentParser.parse("portable observer"),
                verification: nil, expectedOutput: nil, target: target, authority: { [scope] },
                revalidate: { true }, currentContract: { true }, dispatch: { _, admitStart in
                    let task = URLSession.shared.dataTask(with: providerRequest) { _, response, error in
                        defer { callback.fulfill() }
                        guard completionGate.wait(timeout: .now() + 5) == .success else { XCTFail("Initial response did not release provider callback"); return }
                        guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200 else { XCTFail("Disposable provider HTTP request failed"); return }
                        do {
                            try host.recordActiveTaskEvent(executionID: id, event: .accepted, now: host.now())
                            try host.recordActiveTaskEvent(executionID: id, event: .completed(.integer(7)), now: host.now())
                        } catch { XCTFail("The real provider callback must enter its admitted lifecycle") }
                    }
                    try admitStart { task.resume() }
                    return .init(executionId: id, actionId: capability.id, state: .started, message: "Real provider is live.")
                }, resultValue: { _ in XCTFail("Live provider must not require a terminal result"); return .integer(0) })
            XCTAssertEqual(initial.lifecycle?.terminal, false)
            XCTAssertNil(initial.rcir)
            completionGate.signal()
            wait(for: [callback], timeout: 5)
            let deadline = Date().addingTimeInterval(5)
            while ExecutionStore.shared.get(id)?.lifecycle?.terminal != true, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            let terminal = try XCTUnwrap(ExecutionStore.shared.get(id))
            XCTAssertEqual(terminal.lifecycle?.terminal, true)
            XCTAssertEqual(terminal.lifecycle?.providerAcceptance, .accepted)
            XCTAssertEqual(terminal.lifecycle?.verification, matches ? .verifiedSuccess : .verifiedFailure)
            XCTAssertEqual(terminal.lifecycle?.semanticOutcome, matches ? .succeeded : .failed)
            XCTAssertEqual(terminal.lifecycle?.observationBoundary, .externalState)
            XCTAssertEqual(terminal.evidence.observationBoundary, .externalState)
            XCTAssertEqual(terminal.rcir?.outcome, matches ? "succeeded" : "failed")
            XCTAssertEqual(try terminal.result?.canonicalData(), try CapabilityValue.integer(7).canonicalData())
            XCTAssertEqual(terminal.rcirEvents?.map(\.kind), ["accepted", "completed"])
            XCTAssertNotNil(terminal.rcir?.receipt)
        }
        let effects = try String(contentsOf: directory.appendingPathComponent("effects.jsonl"), encoding: .utf8)
        XCTAssertEqual(effects.split(separator: "\n").count, 2, "Each distinct admitted execution caused exactly one real HTTP effect")
    }

    func testSynchronousCompletionWithTypedPostconditionFinalizesWithoutBlockingAdmissionStart() throws {
        let id = UUID().uuidString, host = RCIRExecutionHost()
        host.now = { 100 }
        let abi = CapabilityContract(capabilityID: "fixture:fast-verified", reflectorID: "reflector:fast-verified",
            providerID: "provider:fast-verified", arguments: .string,
            result: .object(properties: ["state": .string], required: ["state"]), declaration: .string("Synchronous deferred postcondition"))
        let capability = Capability(id: abi.capabilityID, title: "Fast verified completion", source: .system,
            reflectorID: abi.reflectorID, safety: .localWrite, invocation: .direct,
            supportLevel: .experimental, requiresConfirmation: false)
        let scope = RCIRScope("urn:fixture:fast-verified", .execute)
        let returned = CapabilityValue.object(["state": .string("wanted")])
        let specification = VerificationSpec(predicates: [.init(type: .resultPathEquals, key: "state", value: "wanted")])
        var starts = 0
        _ = try host.execute(abi: abi, discovery: abi, arguments: .string("wanted"), scope: scope,
            taskModel: .init(shape: .deferred), capability: capability, executionID: id, argumentStrings: nil,
            item: ContentParser.parse("fast typed result"), verification: specification, expectedOutput: nil,
            target: XCTUnwrap(URL(string: "https://example.invalid/fast-verified")), authority: { [scope] },
            revalidate: { true }, currentContract: { true }, dispatch: { _, admitStart in
                try admitStart {
                    starts += 1
                    XCTAssertNotNil(try? host.activeEventPage(executionID: id))
                    do { try host.recordActiveTaskEvent(executionID: id, event: .completed(returned), now: 101) }
                    catch { XCTFail("The synchronous provider callback must enter its admitted lifecycle") }
                }
                return .init(executionId: id, actionId: capability.id, state: .started, message: "Initial response after synchronous callback")
            }, resultValue: { _ in XCTFail("The completion already owns its typed value"); return .null })
        let deadline = Date().addingTimeInterval(3)
        while ExecutionStore.shared.get(id)?.lifecycle?.terminal != true, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let terminal = try XCTUnwrap(ExecutionStore.shared.get(id))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(terminal.lifecycle?.terminal, true)
        XCTAssertEqual(terminal.lifecycle?.verification, .verifiedSuccess)
        XCTAssertEqual(terminal.lifecycle?.observationBoundary, .returnedValue)
        XCTAssertEqual(terminal.rcir?.outcome, "succeeded")
        XCTAssertEqual(try terminal.result?.canonicalData(), try returned.canonicalData())
        XCTAssertNotNil(terminal.rcir?.receipt)
    }

    func testPendingSynchronousCompletionSurvivesLateAcceptedOrSucceededReturnButUnknownWins() throws {
        for initialState in [ExecutionState.accepted, .succeeded, .unknown] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rcir-late-initial-observer-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let observer = Process(); observer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            observer.arguments = [root.appendingPathComponent("scripts/rcir-observer-gate-test-provider.py").path, "--state-dir", directory.path]
            observer.standardOutput = FileHandle.nullDevice; observer.standardError = FileHandle.nullDevice
            try observer.run()
            defer {
                if observer.isRunning { observer.terminate(); observer.waitUntilExit() }
                try? FileManager.default.removeItem(at: directory)
            }
            func awaitFile(_ name: String) throws {
                let file = directory.appendingPathComponent(name), deadline = Date().addingTimeInterval(3)
                while !FileManager.default.fileExists(atPath: file.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                guard FileManager.default.fileExists(atPath: file.path) else { throw RightClickError("Gated observer did not advance") }
            }
            try awaitFile("port")
            let port = try String(contentsOf: directory.appendingPathComponent("port"), encoding: .utf8)
            let base = "http://127.0.0.1:" + port, host = RCIRExecutionHost(), id = UUID().uuidString
            let abi = CapabilityContract(capabilityID: "fixture:late-initial", reflectorID: "reflector:late-initial",
                providerID: "provider:late-initial", arguments: .string, result: .string,
                declaration: .string("Pending callback owns completion"))
            let capability = Capability(id: abi.capabilityID, title: "Late initial response", source: .system,
                reflectorID: abi.reflectorID, safety: .localWrite, invocation: .direct,
                supportLevel: .experimental, requiresConfirmation: false)
            var configuration = RCIRHostConfiguration()
            configuration.observers = [capability.id: .init(urlTemplate: base + "/observe/{expected}", expectedArgument: "expected")]
            host.configuration = { configuration }
            let scope = RCIRScope("urn:fixture:late-initial", .execute)
            var starts = 0
            let initial = try host.execute(abi: abi, discovery: abi, arguments: .string("wanted"), scope: scope,
                taskModel: .init(shape: .deferred), capability: capability, executionID: id,
                argumentStrings: ["expected": "wanted"], item: ContentParser.parse("late initial response"),
                verification: nil, expectedOutput: nil, target: XCTUnwrap(URL(string: base + "/invoke")),
                authority: { [scope] }, revalidate: { true }, currentContract: { true }, dispatch: { _, admitStart in
                    try admitStart {
                        starts += 1
                        do { try host.recordActiveTaskEvent(executionID: id, event: .completed(.string("provider response")), now: host.now()) }
                        catch { XCTFail("Synchronous completion must enter its admitted lifecycle") }
                    }
                    return .init(executionId: id, actionId: capability.id, state: initialState, message: "Late initial provider return")
                }, resultValue: { _ in XCTFail("Pending typed completion must not be recorded twice"); return .string("wrong duplicate") })
            XCTAssertEqual(starts, 1)
            if initialState == .unknown {
                XCTAssertEqual(initial.lifecycle?.terminal, true)
                XCTAssertEqual(initial.state, .unknown)
                XCTAssertEqual(initial.lifecycle?.verification, .unverified)
                try Data().write(to: directory.appendingPathComponent("release"))
                Thread.sleep(forTimeInterval: 0.15)
                XCTAssertEqual(ExecutionStore.shared.get(id)?.state, .unknown)
                XCTAssertEqual(ExecutionStore.shared.get(id)?.lifecycle?.verification, .unverified)
            } else {
                XCTAssertEqual(initial.lifecycle?.terminal, false)
                XCTAssertNil(initial.rcir)
                try awaitFile("observer-started")
                XCTAssertEqual(host.activeExecutionStatus(executionID: id)?.lifecycle?.terminal, false)
                try Data().write(to: directory.appendingPathComponent("release"))
                let deadline = Date().addingTimeInterval(3)
                while ExecutionStore.shared.get(id)?.lifecycle?.terminal != true, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                let terminal = try XCTUnwrap(ExecutionStore.shared.get(id))
                XCTAssertEqual(terminal.lifecycle?.verification, .verifiedSuccess)
                XCTAssertEqual(terminal.lifecycle?.semanticOutcome, .succeeded)
                XCTAssertEqual(terminal.lifecycle?.observationBoundary, .externalState)
                XCTAssertEqual(terminal.rcirEvents?.map(\.kind), ["completed"])
            }
        }
    }

}
