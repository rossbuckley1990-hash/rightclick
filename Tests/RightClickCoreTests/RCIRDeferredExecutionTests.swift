import Foundation
import XCTest
@testable import RightClickCore
@testable import RightClickProviders
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

}
