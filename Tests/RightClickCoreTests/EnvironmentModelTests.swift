import Foundation
import XCTest
@testable import RightClickProtocol

final class EnvironmentModelTests: XCTestCase {
    private let root = "11111111-1111-4111-8111-111111111111"
    private let child = "22222222-2222-4222-8222-222222222222"
    private let grandchild = "33333333-3333-4333-8333-333333333333"
    private let execution = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let runtime = "runtime:" + String(repeating: "a", count: 64)

    private func spec(lifetime: Int64 = 900_000, profile: String = "challenge-linux") throws -> EnvironmentSpec {
        try .init(profileID: profile, lifetimeMilliseconds: lifetime, resources: .init())
    }
    private func lineage() throws -> EnvironmentLineage {
        try .init(rootEnvironmentID: root, parentExecutionID: execution, parentRuntimeID: runtime, depth: 0)
    }
    private func intent() throws -> EnvironmentCreateIntent {
        try .init(environmentID: root, correlationID: child, creationExecutionID: execution, spec: spec(), lineage: lineage(),
                  createdAtMilliseconds: 1000, expiresAtMilliseconds: 901_000)
    }
    private func manifest() throws -> EnvironmentRuntimeManifest {
        try .init(version: "0.2.2", executableSHA256: String(repeating: "b", count: 64), architecture: "arm64")
    }
    private func alteredJSON<T: Encodable>(_ value: T, alter: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        alter(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testEnvironmentURIsRequireExactCanonicalIdentity() throws {
        let id = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        XCTAssertEqual(try EnvironmentIdentity.environmentID(from: "rcenv://" + id), id)
        for alias in [id.lowercased(), id + "/", id + "?x=1", id + "#fragment", "user@" + id,
                      id + ":443", "%41" + String(id.dropFirst()), "{" + id + "}"] {
            XCTAssertThrowsError(try EnvironmentIdentity.environmentID(from: "rcenv://" + alias))
        }
        XCTAssertThrowsError(try EnvironmentIdentity.environmentID(from: "https://" + id))
        XCTAssertThrowsError(try EnvironmentIdentity.environmentID(from: EnvironmentIdentity.factoryURI))
    }
    func testResourceAndLifetimeHardCeilingsRejectOverflowOrUnboundedInputs() throws {
        XCTAssertThrowsError(try EnvironmentResources(cpuCount: 0))
        XCTAssertThrowsError(try EnvironmentResources(cpuCount: EnvironmentLimits.maximumCPUCount + 1))
        XCTAssertThrowsError(try EnvironmentResources(memoryMiB: 127))
        XCTAssertThrowsError(try EnvironmentResources(memoryMiB: EnvironmentLimits.maximumMemoryMiB + 1))
        XCTAssertThrowsError(try EnvironmentResources(maximumCostUnits: 0))
        XCTAssertThrowsError(try EnvironmentResources(maximumCostUnits: Int64.max))
        XCTAssertThrowsError(try EnvironmentResources(costUnit: "usd"))
        XCTAssertThrowsError(try spec(lifetime: 0))
        XCTAssertThrowsError(try spec(lifetime: Int64.max))
    }
    func testResourceAttenuationPreservesExactProfileAndCostUnits() throws {
        let ceiling = try EnvironmentResources(cpuCount: 2, memoryMiB: 1024, maximumCostUnits: 100_000)
        XCTAssertTrue(try EnvironmentResources(cpuCount: 1, memoryMiB: 512, maximumCostUnits: 50_000).isWithin(ceiling))
        XCTAssertFalse(try EnvironmentResources(cpuCount: 3).isWithin(ceiling))
        XCTAssertFalse(try EnvironmentResources(maximumCostUnits: 100_001).isWithin(ceiling))
        XCTAssertTrue(try spec(lifetime: 1).isWithin(spec()))
        XCTAssertFalse(try spec(profile: "other-profile").isWithin(spec()))
    }
    func testIdentifiersExcludePathsShellAndOriginInjection() throws {
        for profile in ["", ".", "..", "../profile", "https://host", "profile;touch", "$(secret)", "profile\n", "profile space"] {
            XCTAssertThrowsError(try spec(profile: profile))
        }
        for id in ["/vm", "../vm", "a?token=secret", "vm;rm", "vm with space", ".", ".."] {
            XCTAssertFalse(EnvironmentIdentity.isResourceID(id))
        }
    }
    func testLineageRejectsImpossibleRootParentDepthAndCycles() throws {
        XCTAssertThrowsError(try EnvironmentLineage(rootEnvironmentID: root, parentEnvironmentID: child,
            parentExecutionID: execution, parentRuntimeID: runtime, depth: 0))
        XCTAssertThrowsError(try EnvironmentLineage(rootEnvironmentID: root,
            parentExecutionID: execution, parentRuntimeID: runtime, depth: 1))
        XCTAssertThrowsError(try EnvironmentLineage(rootEnvironmentID: root, parentEnvironmentID: child,
            parentExecutionID: execution, parentRuntimeID: runtime, depth: 1))
        XCTAssertThrowsError(try EnvironmentLineage(rootEnvironmentID: root, parentEnvironmentID: child,
            parentExecutionID: execution, parentRuntimeID: runtime, depth: EnvironmentLimits.maximumDepth + 1))
        XCTAssertThrowsError(try lineage().validate(environmentID: child))
        let second = try EnvironmentLineage(rootEnvironmentID: root, parentEnvironmentID: root,
            parentExecutionID: execution, parentRuntimeID: runtime, depth: 1)
        XCTAssertThrowsError(try second.validate(environmentID: root))
        XCTAssertNoThrow(try second.validate(environmentID: child))
        let third = try EnvironmentLineage(rootEnvironmentID: root, parentEnvironmentID: child,
            parentExecutionID: execution, parentRuntimeID: runtime, depth: 2)
        XCTAssertNoThrow(try third.validate(environmentID: grandchild))
        XCTAssertThrowsError(try third.validate(environmentID: child))
    }
    func testLineageRequiresAuthenticatedRuntimeAndCanonicalExecutionID() throws {
        XCTAssertThrowsError(try EnvironmentLineage(rootEnvironmentID: root, parentExecutionID: execution,
            parentRuntimeID: "friendly-provider-title", depth: 0))
        XCTAssertThrowsError(try EnvironmentLineage(rootEnvironmentID: root, parentExecutionID: execution.lowercased(),
            parentRuntimeID: runtime, depth: 0))
    }
    func testIntentRejectsClockOverflowAndLifetimeMismatch() throws {
        XCTAssertThrowsError(try EnvironmentCreateIntent(environmentID: root, correlationID: child, creationExecutionID: execution,
            spec: spec(), lineage: lineage(), createdAtMilliseconds: -1, expiresAtMilliseconds: Int64.max))
        XCTAssertThrowsError(try EnvironmentCreateIntent(environmentID: root, correlationID: child, creationExecutionID: execution,
            spec: spec(), lineage: lineage(), createdAtMilliseconds: Int64.max, expiresAtMilliseconds: 1))
        XCTAssertThrowsError(try EnvironmentCreateIntent(environmentID: root, correlationID: child, creationExecutionID: execution,
            spec: spec(), lineage: lineage(), createdAtMilliseconds: 1000, expiresAtMilliseconds: 1001))
    }
    func testCanonicalIntentBindsEnvironmentCorrelationSpecExecutionAndTime() throws {
        let original = try intent()
        XCTAssertEqual(try original.digest(), try original.digest())
        XCTAssertTrue(try original.canonicalData().starts(with: Data("RIGHTCLICK-ENVIRONMENT-INTENT-1\0".utf8)))
        let changed = try EnvironmentCreateIntent(environmentID: root, correlationID: grandchild, creationExecutionID: execution,
            spec: spec(), lineage: lineage(), createdAtMilliseconds: 1000, expiresAtMilliseconds: 901_000)
        XCTAssertNotEqual(try original.digest(), try changed.digest())
        let changedProfile = try EnvironmentCreateIntent(environmentID: root, correlationID: child, creationExecutionID: execution,
            spec: spec(profile: "different"), lineage: lineage(), createdAtMilliseconds: 1000, expiresAtMilliseconds: 901_000)
        XCTAssertNotEqual(try original.digest(), try changedProfile.digest())
        let changedTime = try EnvironmentCreateIntent(environmentID: root, correlationID: child, creationExecutionID: execution,
            spec: spec(), lineage: lineage(), createdAtMilliseconds: 1001, expiresAtMilliseconds: 901_001)
        XCTAssertNotEqual(try original.digest(), try changedTime.digest())
    }
    func testDecodedModelCannotBypassResourceLimitValidation() throws {
        let data = try alteredJSON(EnvironmentResources()) { $0["cpuCount"] = 999 }
        XCTAssertThrowsError(try JSONDecoder().decode(EnvironmentResources.self, from: data))
        let data2 = try alteredJSON(spec()) { $0["lifetimeMilliseconds"] = -1 }
        XCTAssertThrowsError(try JSONDecoder().decode(EnvironmentSpec.self, from: data2))
    }
    func testDecodedIntentCannotBypassIdentityLineageOrExtraFields() throws {
        let original = try intent()
        XCTAssertEqual(try JSONDecoder().decode(EnvironmentCreateIntent.self, from: JSONEncoder().encode(original)), original)
        for field in ["environmentID", "correlationID", "creationExecutionID"] {
            let data = try alteredJSON(original) { $0[field] = "not-a-UUID" }
            XCTAssertThrowsError(try JSONDecoder().decode(EnvironmentCreateIntent.self, from: data))
        }
        let data = try alteredJSON(original) { $0["cloudToken"] = "untrusted" }
        XCTAssertThrowsError(try JSONDecoder().decode(EnvironmentCreateIntent.self, from: data))
    }
    func testRuntimeManifestRequiresPinnedSHAAndPortableLinuxArchitecture() throws {
        XCTAssertThrowsError(try EnvironmentRuntimeManifest(version: "0.2.2", executableSHA256: "not-a-hash", architecture: "arm64"))
        XCTAssertThrowsError(try EnvironmentRuntimeManifest(version: "0.2.2", executableSHA256: String(repeating: "B", count: 64), architecture: "arm64"))
        XCTAssertThrowsError(try EnvironmentRuntimeManifest(version: "0.2.2", executableSHA256: String(repeating: "b", count: 64), operatingSystem: .macOS, architecture: "arm64"))
        XCTAssertThrowsError(try EnvironmentRuntimeManifest(version: "0.2.2", executableSHA256: String(repeating: "b", count: 64), architecture: "other"))
    }
    func testRuntimePublicIdentityMatchesExistingLinkHashConvention() throws {
        let observed = try EnvironmentRuntimeObservation(manifest: manifest(), publicKey: Data(repeating: 7, count: 32),
            observedAtMilliseconds: 1000, observationBoundary: "independent fixture process")
        XCTAssertTrue(EnvironmentIdentity.isRuntimeID(observed.runtimeID))
        XCTAssertThrowsError(try EnvironmentRuntimeObservation(manifest: manifest(), publicKey: Data(repeating: 7, count: 31),
            observedAtMilliseconds: 1000, observationBoundary: "independent fixture process"))
    }
    func testAbsentAndUnknownObservationCannotCarryActiveRuntimeOrSuccessState() throws {
        let runtimeObservation = try EnvironmentRuntimeObservation(manifest: manifest(), publicKey: Data(repeating: 7, count: 32),
            observedAtMilliseconds: 1000, observationBoundary: "fixture")
        XCTAssertThrowsError(try EnvironmentObservation(environmentID: root, correlationID: child, presence: .absent,
            state: .ready, observedAtMilliseconds: 1000, observationBoundary: "fixture"))
        XCTAssertThrowsError(try EnvironmentObservation(environmentID: root, correlationID: child, presence: .absent,
            state: .destroyed, observedAtMilliseconds: 1000, runtime: runtimeObservation, observationBoundary: "fixture"))
        XCTAssertThrowsError(try EnvironmentObservation(environmentID: root, correlationID: child, presence: .unknown,
            state: .destroyed, observedAtMilliseconds: 1000, observationBoundary: "fixture"))
        XCTAssertNoThrow(try EnvironmentObservation(environmentID: root, correlationID: child, presence: .unknown,
            state: .unknown, observedAtMilliseconds: 1000, observationBoundary: "partition"))
    }
    func testPresentObservationRequiresLocatorAndNonFutureRuntimeFacts() throws {
        XCTAssertThrowsError(try EnvironmentObservation(environmentID: root, correlationID: child, presence: .present,
            state: .ready, observedAtMilliseconds: 1000, observationBoundary: "fixture"))
        let later = try EnvironmentRuntimeObservation(manifest: manifest(), publicKey: Data(repeating: 7, count: 32),
            observedAtMilliseconds: 1001, observationBoundary: "fixture")
        XCTAssertThrowsError(try EnvironmentObservation(environmentID: root, correlationID: child, providerResourceID: "resource",
            presence: .present, state: .ready, observedAtMilliseconds: 1000, runtime: later, observationBoundary: "fixture"))
    }
    func testDecodedObservationCannotConvertPresenceIntoVerifiedAbsence() throws {
        let observation = try EnvironmentObservation(environmentID: root, correlationID: child, providerResourceID: "resource",
            presence: .present, state: .ready, observedAtMilliseconds: 1000, observationBoundary: "fixture")
        let data = try alteredJSON(observation) { $0["presence"] = "absent" }
        XCTAssertThrowsError(try JSONDecoder().decode(EnvironmentObservation.self, from: data))
    }
    func testProviderSupportDefaultsFailClosedAndAcceptanceRemainsSeparate() throws {
        let support = EnvironmentProviderSupport()
        XCTAssertFalse(support.supportsCreate)
        XCTAssertFalse(support.supportsChallenge)
        XCTAssertFalse(support.enforcesTTL)
        let accepted = try EnvironmentProviderAcceptance(acceptance: .accepted, providerResourceID: "fixture-resource")
        XCTAssertEqual(accepted.acceptance, .accepted)
        XCTAssertThrowsError(try EnvironmentProviderAcceptance(acceptance: .accepted, providerResourceID: "../../secret"))
    }
    func testDestroyedIsTerminalAndAcceptanceCannotSkipLifecycle() {
        XCTAssertFalse(EnvironmentState.creating.permitsTransition(to: .ready))
        XCTAssertFalse(EnvironmentState.ready.permitsTransition(to: .destroyed))
        XCTAssertTrue(EnvironmentState.destroying.permitsTransition(to: .destroyed))
        XCTAssertFalse(EnvironmentState.destroyed.permitsTransition(to: .creating))
        XCTAssertFalse(EnvironmentState.destroyed.permitsTransition(to: .ready))
        XCTAssertTrue(EnvironmentState.destroyed.permitsTransition(to: .destroyed))
    }
}
