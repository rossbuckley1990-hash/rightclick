import Foundation
import XCTest
@testable import RightClickCore

private final class ObservedEnvironmentReflector: RCIRExecutionReflector {
    let id = "environment.observer-test"
    var effects = 0
    var observation: () throws -> CapabilityValue = { .boolean(true) }
    var output = "reported-success"
    func capabilities(for item: ContentItem) throws -> [Capability] {
        [.init(id: "environment:test", title: "Execute approved workload", source: .system,
            safety: .codeExecution, invocation: .direct, supportLevel: .publicSupported, requiresConfirmation: true)]
    }
    func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
        throw EnvironmentError.unsupported
    }
    func admittedBegin(capability: Capability, admissionOwner: Capability, item: ContentItem, executionID: String,
        arguments: CapabilityArguments?, verification: VerificationSpec?, expectedOutput: String?, host: RCIRExecutionHost,
        revalidate: @escaping () -> Bool) throws -> ExecutionRecord {
        let contract = CapabilityContract(capabilityID: capability.id, reflectorID: id, providerID: "test-node",
            arguments: .object(properties: [:], required: []), result: .string, declaration: .string("approved challenge"))
        let scope = RCIRScope(item.display, .execute)
        return try host.execute(abi: contract, discovery: contract, arguments: .object([:]), scope: scope,
            capability: capability, executionID: executionID, argumentStrings: arguments, item: item,
            verification: verification, expectedOutput: expectedOutput, target: URL(string: item.display)!,
            independentObserver: .init(contract: .init(observerID: "host:environment-reality", schema: .boolean, expected: .boolean(true)),
                boundary: "Independent provider resource observation, separate from child report.", observe: observation),
            authority: { [scope] }, revalidate: revalidate, currentContract: { true },
            dispatch: { _, admit in
                try admit { self.effects += 1 }
                return .init(executionId: executionID, actionId: capability.id, state: .succeeded,
                    message: "Malicious child claims success", output: self.output)
            }, resultValue: { .string($0.output ?? "") })
    }
}

final class EnvironmentObserverHostTests: XCTestCase {
    let item = "rcenv://00000000-0000-4000-8000-000000000001"
    func testChildSuccessCannotOverrideIndependentFalseReality() throws {
        let reflector = ObservedEnvironmentReflector(); reflector.observation = { .boolean(false) }
        let engine = CapabilityEngine(reflectors: [reflector], experience: nil)
        let result = try engine.run(id: "environment:test", item: item, confirmed: true)
        XCTAssertEqual(result.status, .failed); XCTAssertEqual(result.rcir?.outcome, "failed")
        XCTAssertEqual(result.evidence.observationBoundary, .externalState)
        XCTAssertFalse(result.evidence.outcomeVerified); XCTAssertEqual(reflector.effects, 1)
    }
    func testPartitionAfterAcceptanceRemainsUnknown() throws {
        let reflector = ObservedEnvironmentReflector(); reflector.observation = { throw EnvironmentError.unavailable }
        let engine = CapabilityEngine(reflectors: [reflector], experience: nil)
        let result = try engine.run(id: "environment:test", item: item, confirmed: true)
        XCTAssertEqual(result.status, .unknown); XCTAssertNotEqual(result.rcir?.outcome, "succeeded")
        XCTAssertEqual(reflector.effects, 1)
    }
    func testIndependentObservationAndCallerPostconditionBothRequired() throws {
        let reflector = ObservedEnvironmentReflector()
        let engine = CapabilityEngine(reflectors: [reflector], experience: nil)
        let result = try engine.run(id: "environment:test", item: item, confirmed: true, expectedOutput: "different")
        XCTAssertEqual(result.status, .failed); XCTAssertEqual(result.rcir?.outcome, "failed")
        XCTAssertEqual(reflector.effects, 1)
    }
    func testMatchingIndependentAndReturnedConditionsProduceSignedTaskSemantics() throws {
        let reflector = ObservedEnvironmentReflector()
        let engine = CapabilityEngine(reflectors: [reflector], experience: nil)
        let result = try engine.run(id: "environment:test", item: item, confirmed: true, expectedOutput: "reported-success")
        XCTAssertEqual(result.status, .verified); XCTAssertEqual(result.rcir?.outcome, "succeeded")
        XCTAssertTrue(result.evidence.outcomeVerified); XCTAssertTrue(result.rcir?.leaseConsumed == true)
    }
    func testConfirmationDenialPreventsProviderAndObserverEffects() throws {
        let reflector = ObservedEnvironmentReflector(); var observations = 0
        reflector.observation = { observations += 1; return .boolean(true) }
        let engine = CapabilityEngine(reflectors: [reflector], experience: nil)
        let result = try engine.run(id: "environment:test", item: item, confirmed: false)
        XCTAssertEqual(result.status, .confirmationRequired)
        XCTAssertEqual(reflector.effects, 0); XCTAssertEqual(observations, 0)
    }
    func testEnvironmentURIsAreStrictAndDoNotBecomeFilesOrURLs() throws {
        XCTAssertEqual(try ContentParser.parse(item, allowFileInputs: false).kind, "environment")
        for raw in [item + "/", item + "?x=y", "RCENV://fabric", "rcenv://user@fabric", "rcenv://../other"] {
            XCTAssertThrowsError(try ContentParser.parse(raw, allowFileInputs: false))
        }
    }
}
