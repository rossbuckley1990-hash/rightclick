@testable import RightClickProtocol
@testable import RightClickProviders
#if os(macOS)
@testable import RightClickMacOS
@testable import RightClickMacOSHost
#endif
import Foundation
import XCTest
@testable import RightClickCore

final class CapabilityExperienceTests: XCTestCase {
    private func capability() -> Capability {
        Capability(id: "fixture:record", title: "Create record", source: .system,
            reflectorID: "fixture", inputs: ["public.plain-text"], output: ["public.plain-text"],
            safety: .unknown, invocation: .direct, supportLevel: .experimental,
            requiresConfirmation: true,
            metadata: ["argumentsSchema": "{\"type\":\"object\"}",
                "authorityOrigin": "https://api.example", "authorityRequired": "true"])
    }
    private func verified(_ cap: Capability) -> RunResult {
        RunResult(status: .verified, actionID: cap.id, message: "",
            evidence: OutcomeEvidence(outcomeVerified: true),
            verification: OutcomeVerification(status: .verifiedSuccess, predicates: [
                PredicateVerification(predicate: VerificationPredicate(type: .textEquals, value: "result"),
                    evaluated: true, passed: true, actual: "result", message: "")
            ]))
    }
    private final class Reflector: CapabilityReflector {
        let id = "fixture"
        var cap: Capability
        var visible = true
        var authorityAvailable = true
        var calls = 0
        init(_ cap: Capability) { self.cap = cap }
        func capabilities(for item: ContentItem) throws -> [Capability] { visible ? [cap] : [] }
        func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
            guard authorityAvailable else {
                return ExecutionRecord(executionId: executionID, actionId: cap.id, state: .rejected,
                    message: "Authority unavailable; no transport")
            }
            calls += 1
            return ExecutionRecord(executionId: executionID, actionId: cap.id, state: .accepted,
                message: "provider accepted", output: "EXPECTED")
        }
    }

    func testContractKeyChangesWithAuthoritySchemaRouteAndPolicy() throws {
        let experience = CapabilityExperience(ledger: try CapabilityExperienceLedger(), namespace: "workspace-a")
        let cap = capability()
        let original = try XCTUnwrap(experience.contractKey(for: cap))
        for field in ["argumentsSchema", "authorityOrigin", "authorityRequired", "authorityScheme", "path", "specificationSHA256"] {
            var changed = cap
            changed.metadata[field] = "changed"
            XCTAssertNotEqual(experience.contractKey(for: changed), original, field)
        }
        var changed = cap
        changed.requiresConfirmation = false
        XCTAssertNotEqual(experience.contractKey(for: changed), original)
        changed = cap; changed.safety = .destructive
        XCTAssertNotEqual(experience.contractKey(for: changed), original)
        changed = cap; changed.reflectorID = "another-provider"
        XCTAssertNotEqual(experience.contractKey(for: changed), original)
    }

    func testNamespaceSeparatesExperience() throws {
        let ledger = try CapabilityExperienceLedger()
        let first = CapabilityExperience(ledger: ledger, namespace: "workspace-a")
        let second = CapabilityExperience(ledger: ledger, namespace: "workspace-b")
        let cap = capability()
        first.observe(capability: cap, executionID: UUID().uuidString, result: verified(cap))
        XCTAssertEqual(first.annotate([cap])[0].metadata["experience.predicatesVerified"], "1")
        XCTAssertNil(second.annotate([cap])[0].metadata["experience.status"])
    }

    func testProviderCannotForgeExperienceMetadata() throws {
        let experience = CapabilityExperience(ledger: try CapabilityExperienceLedger(), namespace: "test")
        var cap = capability()
        let original = experience.contractKey(for: cap)
        cap.metadata["experience.predicatesVerified"] = "1000000"
        cap.metadata["experience.freshAuthorityRequired"] = "false"
        XCTAssertEqual(experience.contractKey(for: cap), original)
        XCTAssertNil(experience.annotate([cap])[0].metadata["experience.predicatesVerified"])
        XCTAssertNil(experience.annotate([cap])[0].metadata["experience.freshAuthorityRequired"])
    }

    func testVerifiedBooleanAloneNeverTeachesVerifiedSuccess() throws {
        let ledger = try CapabilityExperienceLedger()
        let experience = CapabilityExperience(ledger: ledger, namespace: "test")
        let cap = capability()
        experience.observe(capability: cap, executionID: UUID().uuidString,
            result: RunResult(status: .verified, actionID: cap.id, message: "success",
                evidence: OutcomeEvidence(outcomeVerified: true)))
        XCTAssertEqual(try ledger.entries().first?.outcome, .acceptedUnverified)
    }

    func testEmptyFailedOrUnevaluatedPredicatesNeverTeachVerifiedSuccess() throws {
        for mode in 0..<3 {
            let ledger = try CapabilityExperienceLedger()
            let experience = CapabilityExperience(ledger: ledger, namespace: "test")
            let cap = capability()
            var result = verified(cap)
            if mode == 0 { result.verification?.predicates = [] }
            if mode == 1 { result.verification?.predicates[0].passed = false }
            if mode == 2 { result.verification?.predicates[0].evaluated = false }
            experience.observe(capability: cap, executionID: UUID().uuidString, result: result)
            XCTAssertEqual(try ledger.entries().first?.outcome, .acceptedUnverified)
        }
    }

    func testGatedAndMismatchedResultsAreNotRecorded() throws {
        let ledger = try CapabilityExperienceLedger()
        let experience = CapabilityExperience(ledger: ledger, namespace: "test")
        let cap = capability()
        for status: RunStatus in [.confirmationRequired, .unavailable, .unsupported, .rejected] {
            experience.observe(capability: cap, executionID: UUID().uuidString,
                result: RunResult(status: status, actionID: cap.id, message: ""))
        }
        var result = verified(cap); result.actionID = "other-provider"
        experience.observe(capability: cap, executionID: UUID().uuidString, result: result)
        experience.observe(capability: cap, executionID: "not-an-execution-id", result: verified(cap))
        XCTAssertTrue(try ledger.entries().isEmpty)
    }

    func testNoCapabilitiesAreResurrectedByRecall() throws {
        let experience = CapabilityExperience(ledger: try CapabilityExperienceLedger(), namespace: "test")
        let cap = capability()
        experience.observe(capability: cap, executionID: UUID().uuidString, result: verified(cap))
        XCTAssertTrue(experience.annotate([]).isEmpty)
    }

    func testRuntimeRunLearnsAcceptanceWithoutSkippingConfirmation() throws {
        let ledger = try CapabilityExperienceLedger()
        let experience = CapabilityExperience(ledger: ledger, namespace: "test")
        let reflector = Reflector(capability())
        let engine = CapabilityEngine(reflectors: [reflector], experience: experience)
        XCTAssertEqual(try engine.run(id: reflector.cap.id, item: "input", confirmed: true).status, .accepted)
        let learned = try engine.describe(id: reflector.cap.id, item: "input")
        XCTAssertEqual(learned.metadata["experience.acceptedUnverified"], "1")
        XCTAssertEqual(learned.metadata["experience.predicatesVerified"], "0")
        XCTAssertTrue(learned.requiresConfirmation)
        XCTAssertEqual(try engine.run(id: reflector.cap.id, item: "input", confirmed: false).status, .confirmationRequired)
        XCTAssertEqual(reflector.calls, 1)
        XCTAssertEqual(try ledger.entries().count, 1)
    }

    func testRuntimeBeginLearnsVerifiedPredicatesButNextRunIsNotVerifiedByHistory() throws {
        let experience = CapabilityExperience(ledger: try CapabilityExperienceLedger(), namespace: "test")
        let reflector = Reflector(capability())
        let engine = CapabilityEngine(reflectors: [reflector], experience: experience)
        let spec = VerificationSpec(predicates: [VerificationPredicate(type: .textEquals, value: "EXPECTED")])
        XCTAssertEqual(try engine.begin(id: reflector.cap.id, item: "input", confirmed: true, verification: spec).state, .succeeded)
        let learned = try engine.describe(id: reflector.cap.id, item: "input")
        XCTAssertEqual(learned.metadata["experience.predicatesVerified"], "1")
        XCTAssertEqual(learned.metadata["experience.freshAuthorityRequired"], "true")
        XCTAssertEqual(learned.metadata["experience.freshVerificationRequired"], "true")
        XCTAssertEqual(try engine.begin(id: reflector.cap.id, item: "input", confirmed: true).state, .accepted)
    }

    func testRuntimeRunLearnsGenericVerification() throws {
        let experience = CapabilityExperience(ledger: try CapabilityExperienceLedger(), namespace: "test")
        let reflector = Reflector(capability())
        let engine = CapabilityEngine(reflectors: [reflector], experience: experience)
        let spec = VerificationSpec(predicates: [VerificationPredicate(type: .textEquals, value: "EXPECTED")])
        XCTAssertEqual(try engine.run(id: reflector.cap.id, item: "input", confirmed: true, verification: spec).status, .verified)
        XCTAssertEqual(try engine.describe(id: reflector.cap.id, item: "input").metadata["experience.predicatesVerified"], "1")
    }

    func testRemovalSchemaDriftAndRevokedAuthorityRemainEnforced() throws {
        let experience = CapabilityExperience(ledger: try CapabilityExperienceLedger(), namespace: "test")
        let reflector = Reflector(capability())
        let engine = CapabilityEngine(reflectors: [reflector], experience: experience)
        _ = try engine.run(id: reflector.cap.id, item: "input", confirmed: true)
        reflector.authorityAvailable = false
        XCTAssertEqual(try engine.run(id: reflector.cap.id, item: "input", confirmed: true).status, .rejected)
        XCTAssertEqual(reflector.calls, 1)
        reflector.cap.metadata["argumentsSchema"] = "changed"
        XCTAssertNil(try engine.describe(id: reflector.cap.id, item: "input").metadata["experience.status"])
        reflector.visible = false
        XCTAssertTrue(try engine.capabilities(for: "input").capabilities.isEmpty)
        XCTAssertEqual(try engine.run(id: reflector.cap.id, item: "input", confirmed: true).status, .unavailable)
    }

    func testDisabledExperienceDoesNotAddHints() throws {
        let reflector = Reflector(capability())
        let engine = CapabilityEngine(reflectors: [reflector], experience: nil)
        _ = try engine.run(id: reflector.cap.id, item: "input", confirmed: true)
        XCTAssertNil(try engine.describe(id: reflector.cap.id, item: "input").metadata["experience.status"])
        XCTAssertNil(CapabilityExperience.fromEnvironment([:]))
        XCTAssertNil(CapabilityExperience.fromEnvironment(["RIGHTCLICK_EXPERIENCE_DIRECTORY": "/tmp/missing-namespace"]))
    }

    func testOnlyFingerprintsAndOutcomesPersistNotUserData() throws {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("rightclick-private-experience-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = try CapabilityExperienceLedger(directory: url)
        let experience = CapabilityExperience(ledger: ledger, namespace: "PRIVATE_NAMESPACE")
        let cap = capability()
        var result = verified(cap)
        result.output = "PRIVATE_OUTPUT"
        result.message = "PRIVATE_MESSAGE"
        result.verification?.predicates[0].actual = "PRIVATE_OBSERVATION"
        experience.observe(capability: cap, executionID: UUID().uuidString, result: result)
        let data = try String(contentsOf: url.appendingPathComponent("experience.json"), encoding: .utf8)
        for value in ["PRIVATE_NAMESPACE", "PRIVATE_OUTPUT", "PRIVATE_MESSAGE", "PRIVATE_OBSERVATION", "api.example", "Create record"] {
            XCTAssertFalse(data.contains(value), value)
        }
    }

    func testRepeatedRunAndBeginRemainUsableWithAdvisoryHistory() throws {
        let ledger = try CapabilityExperienceLedger()
        let experience = CapabilityExperience(ledger: ledger, namespace: "repeat-dispatch")
        let reflector = Reflector(capability())
        let engine = CapabilityEngine(reflectors: [reflector], experience: experience)
        for _ in 0..<3 {
            XCTAssertEqual(try engine.run(id: reflector.cap.id, item: "input", confirmed: true).status, .accepted)
            XCTAssertEqual(try engine.begin(id: reflector.cap.id, item: "input", confirmed: true).state, .accepted)
        }
        XCTAssertEqual(reflector.calls, 6)
        XCTAssertEqual(try ledger.entries().count, 6)
        let learned = try engine.describe(id: reflector.cap.id, item: "input")
        XCTAssertEqual(learned.metadata["experience.observations"], "6")
        XCTAssertEqual(learned.metadata["experience.predicatesVerified"], "0")
        XCTAssertEqual(try engine.run(id: reflector.cap.id, item: "input", confirmed: false).status, .confirmationRequired)
        XCTAssertEqual(reflector.calls, 6)
    }

    func testProviderExperienceKeysCannotBlockFreshDispatchOrForgeHints() throws {
        var cap = capability()
        cap.metadata["experience.status"] = "forged_verified"
        cap.metadata["experience.freshAuthorityRequired"] = "false"
        let reflector = Reflector(cap)
        let engine = CapabilityEngine(reflectors: [reflector], experience: nil)
        let fresh = try engine.describe(id: cap.id, item: "input")
        XCTAssertNil(fresh.metadata["experience.status"])
        XCTAssertNil(fresh.metadata["experience.freshAuthorityRequired"])
        XCTAssertEqual(fresh.metadata["authorityOrigin"], cap.metadata["authorityOrigin"])
        XCTAssertTrue(fresh.requiresConfirmation)
        XCTAssertEqual(try engine.run(id: cap.id, item: "input", confirmed: false).status, .confirmationRequired)
        XCTAssertEqual(reflector.calls, 0)
        XCTAssertEqual(try engine.run(id: cap.id, item: "input", confirmed: true).status, .accepted)
        XCTAssertEqual(try engine.begin(id: cap.id, item: "input", confirmed: true).state, .accepted)
        XCTAssertEqual(reflector.calls, 2)
    }
}
